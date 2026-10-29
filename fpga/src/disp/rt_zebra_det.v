`timescale 1ns/1ps
////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 2026/10/29
// Design Name: rt_zebra_det
// Module Name: rt_zebra_det
// Target Device: Logos2 PG2L100H
// Tool Versions: PDS 2025.2 / Questa FSE
// Description:
//   FPGA streaming zebra crossing detection module (window 0, 960x540 RGB565).
//   Strictly aligned with Python Golden Model (model.py & params.json):
//   - Zero line buffer, pure single-pass raster stream
//   - White pixel classifier with RGB565 quantization mask
//   - 1D run-length state machine with dark gap merging (<= gap_max)
//   - Edge margin run clipping and width bandpass [w_min, w_max]
//   - Multi-physical constraints: regularity, span ratio, duty cycle, adjacent gap
//   - Multi-stage pipelined blanking decision (zero long combinational multiplier chains)
//   - Shift-and-add conversion for all constant multipliers to guarantee timing closure
//   - Frame ROI [y_top, y_bot) continuity tracking (tolerating <= 2 line gaps)
//   - Temporal hysteresis filter (hyst_pos set, hyst_neg clear)
////////////////////////////////////////////////////////////////////////////////

module rt_zebra_det #(
    parameter [9:0]  IMG_W           = 10'd960,
    parameter [9:0]  IMG_H           = 10'd540,
    parameter [9:0]  Y_TOP           = 10'd300,
    parameter [9:0]  Y_BOT           = 10'd480,
    parameter [7:0]  V_MIN           = 8'd140,
    parameter [7:0]  C_MAX           = 8'd30,
    parameter [3:0]  GAP_MAX         = 4'd4,
    parameter [9:0]  EDGE_MARGIN     = 10'd10,
    parameter [7:0]  W_MIN           = 8'd10,
    parameter [7:0]  W_MAX           = 8'd70,
    parameter [7:0]  DEF_N_MIN       = 8'd7,
    parameter [7:0]  DEF_REG_PCT     = 8'd120,
    parameter [15:0] DEF_SPAN_Q10    = 16'd550, // round(0.55 * 1000)
    parameter [7:0]  DEF_GAP_MIN_W   = 8'd5,
    parameter [7:0]  DEF_GAP_MAX_W   = 8'd100,
    parameter [7:0]  DEF_DUTY_MIN    = 8'd20,   // 0.20 * 100
    parameter [7:0]  DEF_DUTY_MAX    = 8'd60,   // 0.60 * 100
    parameter [7:0]  DEF_R_MIN       = 8'd3,
    parameter [7:0]  DEF_CONT_MIN    = 8'd3,
    parameter [7:0]  DEF_HYST_POS    = 8'd3,
    parameter [7:0]  DEF_HYST_NEG    = 8'd6,
    parameter        CFG_SPAN_EN     = 1'b1,
    parameter        CFG_DUTY_EN     = 1'b1,
    parameter        CFG_GAP_EN      = 1'b1
)(
    input  wire        pix_clk,
    input  wire        rst_n,
    input  wire        de,
    input  wire        hs,
    input  wire        vs,
    input  wire [7:0]  r,
    input  wire [7:0]  g,
    input  wire [7:0]  b,

    // Runtime configurable threshold inputs (if 0, fallback to params.json defaults)
    input  wire [7:0]  n_min,
    input  wire [7:0]  reg_pct,
    input  wire [15:0] span_q10,
    input  wire [7:0]  gap_max_w,

    // Detection outputs
    output reg         zebra,
    output reg         zebra_raw,
    output reg  [7:0]  n_rows,
    output reg  [9:0]  y_min,
    output reg  [9:0]  y_max,
    output reg  [7:0]  max_cont,
    output reg         frame_done
) /* synthesis syn_hier = "fixed" */;

    // Effective thresholds
    wire [7:0]  eff_n_min     = (n_min != 8'd0)     ? n_min     : DEF_N_MIN;
    wire [7:0]  eff_reg_pct   = (reg_pct != 8'd0)   ? reg_pct   : DEF_REG_PCT;
    wire [15:0] eff_span_q10  = (span_q10 != 16'd0) ? span_q10 : DEF_SPAN_Q10;
    wire [7:0]  eff_gap_max_w = (gap_max_w != 8'd0) ? gap_max_w : DEF_GAP_MAX_W;
    wire [7:0]  eff_gap_min_w = DEF_GAP_MIN_W;
    wire [7:0]  eff_r_min     = DEF_R_MIN;
    wire [7:0]  eff_cont_min  = DEF_CONT_MIN;

    // Synchronize vsync and de edges
    reg vs_d1, vs_d2;
    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            vs_d1 <= 1'b0;
            vs_d2 <= 1'b0;
        end else begin
            vs_d1 <= vs;
            vs_d2 <= vs_d1;
        end
    end
    wire vs_rise = vs_d1 & ~vs_d2;

    reg de_d;
    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) de_d <= 1'b0;
        else        de_d <= de;
    end
    wire de_fall = ~de & de_d;
    wire de_rise = de & ~de_d;

    // Raster coordinate counters
    reg [11:0] x_pos;
    reg [11:0] y_pos;
    reg [9:0]  cur_line_y;

    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            x_pos      <= 12'd0;
            y_pos      <= 12'd0;
            cur_line_y <= 10'd0;
        end else if (vs_rise) begin
            x_pos      <= 12'd0;
            y_pos      <= 12'd0;
            cur_line_y <= 10'd0;
        end else if (de) begin
            x_pos      <= x_pos + 1'b1;
            cur_line_y <= y_pos[9:0];
        end else if (de_fall) begin
            x_pos      <= 12'd0;
            y_pos      <= y_pos + 1'b1;
        end
    end

    //==========================================================================
    // Step 1: Pixel-level White Classifier
    //==========================================================================
    wire [7:0] rq = r & 8'hF8;
    wire [7:0] gq = g & 8'hFC;
    wire [7:0] bq = b & 8'hF8;

    wire [7:0] max_rg = (rq > gq) ? rq : gq;
    wire [7:0] max_c  = (max_rg > bq) ? max_rg : bq;

    wire [7:0] min_rg = (rq < gq) ? rq : gq;
    wire [7:0] min_c  = (min_rg < bq) ? min_rg : bq;

    wire is_white = (rq >= V_MIN) && (gq >= V_MIN) && (bq >= V_MIN) &&
                    ((max_c - min_c) <= C_MAX);

    //==========================================================================
    // Step 2 & 3: Run-length state machine & Line feature accumulation
    //==========================================================================
    reg [9:0] cur_w;
    reg [3:0] gap_cnt;
    reg [9:0] start_x;

    reg [7:0]  runs_cnt;
    reg [7:0]  runs_valid;
    reg [11:0] sum_w;
    reg [7:0]  min_w;
    reg [7:0]  max_w;
    reg [9:0]  first_s;
    reg [9:0]  last_e;
    reg [9:0]  prev_e;
    reg        gap_invalid;
    reg [9:0]  white_px_cnt;

    // Blanking pipelined state machine (3-bit, 7 reachable states)
    localparam FSM_ACTIVE       = 3'd0;
    localparam FSM_FINISH_RUN   = 3'd1;
    localparam FSM_PIPE_STAGE1  = 3'd2;
    localparam FSM_PIPE_STAGE2  = 3'd3;
    localparam FSM_EVAL_ROW     = 3'd4;
    localparam FSM_UPDATE_FRAME = 3'd5;
    localparam FSM_FRAME_DONE   = 3'd6;
    localparam FSM_IDLE         = 3'd7;

    reg [2:0] blank_fsm;

    // Stage 1 Pipeline Registers (Shift-and-add conversions)
    reg [7:0]  diff_w_q1;
    reg [7:0]  runs_valid_q1;
    reg [11:0] sum_w_q1;
    reg [7:0]  min_w_q1;
    reg [7:0]  max_w_q1;
    reg        cond_n_q1;
    reg        gap_invalid_q1;
    reg [9:0]  span_q1;
    reg [17:0] mult_diff_q1;        // diff_w * 100 = (x<<6) + (x<<5) + (x<<2)
    reg [19:0] term_reg2_q1;        // eff_reg_pct * sum_w (DSP)
    reg [19:0] term_span_lhs_q1;    // span * 1000 = (span<<10) - (span<<4) - (span<<3)
    reg [25:0] term_span_rhs_q1;    // eff_span_q10 * 960 = (x<<10) - (x<<6)
    reg [17:0] term_duty_lhs_q1;    // sum_w * 100 = (x<<6) + (x<<5) + (x<<2)
    reg [15:0] term_duty_min_rhs_q1;// 20 * span = (span<<4) + (span<<2)
    reg [15:0] term_duty_max_rhs_q1;// 60 * span = (span<<6) - (span<<2)
    reg [7:0]  runs_cnt_q1;
    reg [9:0]  white_px_cnt_q1;
    reg [9:0]  cur_line_y_q1;

    // Stage 2 Pipeline Registers (Multiplier output & condition evaluations)
    reg [25:0] term_reg1_q2;        // mult_diff_q1 * runs_valid_q1 (DSP)
    reg [19:0] term_reg2_q2;
    reg        cond_n_q2;
    reg        cond_span_q2;
    reg        cond_duty_q2;
    reg        cond_gap_q2;
    reg [7:0]  min_w_q2;
    reg [7:0]  max_w_q2;
    reg [7:0]  runs_valid_q2;
    reg [7:0]  runs_cnt_q2;
    reg [9:0]  white_px_cnt_q2;
    reg [9:0]  cur_line_y_q2;

    // Row evaluation latches (for TB verification and frame tracking)
    reg       row_cand;
    reg [7:0] row_runs_valid;
    reg [7:0] row_max_w;
    reg [7:0] row_min_w;
    reg [7:0] row_runs;
    reg [9:0] row_white_px;
    reg [9:0] row_y;
    reg       row_done;

    // Frame tracking registers
    reg [7:0] cur_cont;
    reg [7:0] gap_rows;
    reg [7:0] max_cont_acc;
    reg [7:0] n_rows_acc;
    reg [9:0] y_min_acc;
    reg [9:0] y_max_acc;

    // Temporal hysteresis counters
    reg [7:0] consec_pos;
    reg [7:0] consec_neg;

    // Run completion helper wires for active stream
    wire       run_finish_active = de && (!is_white) && (cur_w > 10'd0) && (gap_cnt == GAP_MAX);
    wire [9:0] run_s_act = start_x;
    wire [9:0] run_e_act = x_pos[9:0] - 10'd5;
    wire [9:0] run_w_act = cur_w;
    wire       run_valid_act = (run_s_act > EDGE_MARGIN) &&
                               (run_e_act < (IMG_W - 10'd1 - EDGE_MARGIN)) &&
                               (run_w_act >= {2'd0, W_MIN}) &&
                               (run_w_act <= {2'd0, W_MAX});

    // Run completion helper wires for line blanking (pending run at end of line)
    wire [9:0] run_s_blk = start_x;
    wire [9:0] run_e_blk = (IMG_W - 10'd1) - {6'd0, gap_cnt};
    wire [9:0] run_w_blk = cur_w;
    wire       run_valid_blk = (cur_w > 10'd0) &&
                               (run_s_blk > EDGE_MARGIN) &&
                               (run_e_blk < (IMG_W - 10'd1 - EDGE_MARGIN)) &&
                               (run_w_blk >= {2'd0, W_MIN}) &&
                               (run_w_blk <= {2'd0, W_MAX});

    // Calculations for Stage 1 inputs
    wire [7:0] diff_w_calc = max_w - min_w;
    wire [9:0] span_calc   = (runs_valid > 8'd0) ? (last_e - first_s) : 10'd0;

    // Stage 3 condition check
    wire cond_reg_stage3 = (term_reg1_q2 <= {6'd0, term_reg2_q2});

    // Frame raw decision helper wire
    wire raw_comb = (n_rows_acc >= eff_r_min) && (max_cont_acc >= eff_cont_min);

    //==========================================================================
    // Main Sequential Process
    //==========================================================================
    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            cur_w               <= 10'd0;
            gap_cnt             <= 4'd0;
            start_x             <= 10'd0;
            runs_cnt            <= 8'd0;
            runs_valid          <= 8'd0;
            sum_w               <= 12'd0;
            min_w               <= 8'd0;
            max_w               <= 8'd0;
            first_s             <= 10'd0;
            last_e              <= 10'd0;
            prev_e              <= 10'd0;
            gap_invalid         <= 1'b0;
            white_px_cnt        <= 10'd0;
            blank_fsm           <= FSM_IDLE;
            diff_w_q1           <= 8'd0;
            runs_valid_q1       <= 8'd0;
            sum_w_q1            <= 12'd0;
            min_w_q1            <= 8'd0;
            max_w_q1            <= 8'd0;
            cond_n_q1           <= 1'b0;
            gap_invalid_q1      <= 1'b0;
            span_q1             <= 10'd0;
            mult_diff_q1        <= 18'd0;
            term_reg2_q1        <= 20'd0;
            term_span_lhs_q1    <= 20'd0;
            term_span_rhs_q1    <= 26'd0;
            term_duty_lhs_q1    <= 18'd0;
            term_duty_min_rhs_q1<= 16'd0;
            term_duty_max_rhs_q1<= 16'd0;
            runs_cnt_q1         <= 8'd0;
            white_px_cnt_q1     <= 10'd0;
            cur_line_y_q1       <= 10'd0;
            term_reg1_q2        <= 26'd0;
            term_reg2_q2        <= 20'd0;
            cond_n_q2           <= 1'b0;
            cond_span_q2        <= 1'b0;
            cond_duty_q2        <= 1'b0;
            cond_gap_q2         <= 1'b0;
            min_w_q2            <= 8'd0;
            max_w_q2            <= 8'd0;
            runs_valid_q2       <= 8'd0;
            runs_cnt_q2         <= 8'd0;
            white_px_cnt_q2     <= 10'd0;
            cur_line_y_q2       <= 10'd0;
            row_cand            <= 1'b0;
            row_runs_valid      <= 8'd0;
            row_max_w           <= 8'd0;
            row_min_w           <= 8'd0;
            row_runs            <= 8'd0;
            row_white_px        <= 10'd0;
            row_y               <= 10'd0;
            row_done            <= 1'b0;
            cur_cont            <= 8'd0;
            gap_rows            <= 8'd0;
            max_cont_acc        <= 8'd0;
            n_rows_acc          <= 8'd0;
            y_min_acc           <= 10'd0;
            y_max_acc           <= 10'd0;
            consec_pos          <= 8'd0;
            consec_neg          <= 8'd0;
            zebra               <= 1'b0;
            zebra_raw           <= 1'b0;
            n_rows              <= 8'd0;
            y_min               <= 10'h3FF;
            y_max               <= 10'h3FF;
            max_cont            <= 8'd0;
            frame_done          <= 1'b0;
        end else if (vs_rise) begin
            cur_w          <= 10'd0;
            gap_cnt        <= 4'd0;
            start_x        <= 10'd0;
            runs_cnt       <= 8'd0;
            runs_valid     <= 8'd0;
            sum_w          <= 12'd0;
            min_w          <= 8'd0;
            max_w          <= 8'd0;
            first_s        <= 10'd0;
            last_e         <= 10'd0;
            prev_e         <= 10'd0;
            gap_invalid    <= 1'b0;
            white_px_cnt   <= 10'd0;
            blank_fsm      <= FSM_IDLE;
            row_done       <= 1'b0;
            cur_cont       <= 8'd0;
            gap_rows       <= 8'd0;
            max_cont_acc   <= 8'd0;
            n_rows_acc     <= 8'd0;
            y_min_acc      <= 10'd0;
            y_max_acc      <= 10'd0;
            frame_done     <= 1'b0;
        end else begin
            case (blank_fsm)
                FSM_IDLE: begin
                    row_done   <= 1'b0;
                    frame_done <= 1'b0;
                    if (de_rise || de) begin
                        cur_w        <= 10'd0;
                        gap_cnt      <= 4'd0;
                        start_x      <= 10'd0;
                        runs_cnt     <= 8'd0;
                        runs_valid   <= 8'd0;
                        sum_w        <= 12'd0;
                        min_w        <= 8'd0;
                        max_w        <= 8'd0;
                        first_s      <= 10'd0;
                        last_e       <= 10'd0;
                        prev_e       <= 10'd0;
                        gap_invalid  <= 1'b0;
                        white_px_cnt <= 10'd0;
                        blank_fsm    <= FSM_ACTIVE;

                        // Process first pixel if de is high
                        if (is_white) begin
                            start_x      <= x_pos[9:0];
                            cur_w        <= 10'd1;
                            gap_cnt      <= 4'd0;
                            white_px_cnt <= 10'd1;
                        end
                    end
                end

                FSM_ACTIVE: begin
                    row_done   <= 1'b0;
                    frame_done <= 1'b0;
                    if (de) begin
                        if (is_white) begin
                            if (cur_w == 10'd0) begin
                                start_x <= x_pos[9:0];
                            end
                            cur_w        <= cur_w + {6'd0, gap_cnt} + 10'd1;
                            gap_cnt      <= 4'd0;
                            white_px_cnt <= white_px_cnt + 1'b1;
                        end else begin
                            if (cur_w > 10'd0) begin
                                if (gap_cnt == GAP_MAX) begin
                                    // Run completes at x_pos - 5
                                    runs_cnt <= runs_cnt + 1'b1;
                                    if (run_valid_act) begin
                                        runs_valid <= runs_valid + 1'b1;
                                        sum_w      <= sum_w + run_w_act;
                                        if (runs_valid == 8'd0 || run_w_act[7:0] < min_w)
                                            min_w <= run_w_act[7:0];
                                        if (runs_valid == 8'd0 || run_w_act[7:0] > max_w)
                                            max_w <= run_w_act[7:0];
                                        if (runs_valid == 8'd0)
                                            first_s <= run_s_act;
                                        last_e <= run_e_act;
                                        if (runs_valid > 8'd0) begin
                                            if ((run_s_act - prev_e) < {2'd0, eff_gap_min_w} ||
                                                (run_s_act - prev_e) > {2'd0, eff_gap_max_w})
                                                gap_invalid <= 1'b1;
                                        end
                                        prev_e <= run_e_act;
                                    end
                                    cur_w   <= 10'd0;
                                    gap_cnt <= 4'd0;
                                end else begin
                                    gap_cnt <= gap_cnt + 1'b1;
                                end
                            end
                        end
                    end else if (de_fall) begin
                        blank_fsm <= FSM_FINISH_RUN;
                    end
                end

                FSM_FINISH_RUN: begin
                    if (cur_w > 10'd0) begin
                        runs_cnt <= runs_cnt + 1'b1;
                        if (run_valid_blk) begin
                            runs_valid <= runs_valid + 1'b1;
                            sum_w      <= sum_w + run_w_blk;
                            if (runs_valid == 8'd0 || run_w_blk[7:0] < min_w)
                                min_w <= run_w_blk[7:0];
                            if (runs_valid == 8'd0 || run_w_blk[7:0] > max_w)
                                max_w <= run_w_blk[7:0];
                            if (runs_valid == 8'd0)
                                first_s <= run_s_blk;
                            last_e <= run_e_blk;
                            if (runs_valid > 8'd0) begin
                                if ((run_s_blk - prev_e) < {2'd0, eff_gap_min_w} ||
                                    (run_s_blk - prev_e) > {2'd0, eff_gap_max_w})
                                    gap_invalid <= 1'b1;
                            end
                            prev_e <= run_e_blk;
                        end
                        cur_w   <= 10'd0;
                        gap_cnt <= 4'd0;
                    end
                    blank_fsm <= FSM_PIPE_STAGE1;
                end

                // Pipeline Stage 1: Latch row features & calculate terms with shift-and-add
                FSM_PIPE_STAGE1: begin
                    diff_w_q1            <= diff_w_calc;
                    runs_valid_q1        <= runs_valid;
                    sum_w_q1             <= sum_w;
                    min_w_q1             <= min_w;
                    max_w_q1             <= max_w;
                    cond_n_q1            <= (runs_valid >= eff_n_min);
                    gap_invalid_q1       <= gap_invalid;
                    span_q1              <= span_calc;
                    // diff_w * 100 via shifts: (diff_w << 6) + (diff_w << 5) + (diff_w << 2)
                    mult_diff_q1         <= ({10'd0, diff_w_calc} << 6) +
                                            ({10'd0, diff_w_calc} << 5) +
                                            ({10'd0, diff_w_calc} << 2);
                    // eff_reg_pct * sum_w (DSP)
                    term_reg2_q1         <= eff_reg_pct * sum_w;
                    // span * 1000 via shifts: (span << 10) - (span << 4) - (span << 3)
                    term_span_lhs_q1     <= ({10'd0, span_calc} << 10) -
                                            ({10'd0, span_calc} << 4) -
                                            ({10'd0, span_calc} << 3);
                    // eff_span_q10 * 960 via shifts: (eff_span_q10 << 10) - (eff_span_q10 << 6)
                    term_span_rhs_q1     <= ({10'd0, eff_span_q10} << 10) -
                                            ({10'd0, eff_span_q10} << 6);
                    // sum_w * 100 via shifts: (sum_w << 6) + (sum_w << 5) + (sum_w << 2)
                    term_duty_lhs_q1     <= ({6'd0, sum_w} << 6) +
                                            ({6'd0, sum_w} << 5) +
                                            ({6'd0, sum_w} << 2);
                    // 20 * span via shifts: (span << 4) + (span << 2)
                    term_duty_min_rhs_q1 <= ({6'd0, span_calc} << 4) +
                                            ({6'd0, span_calc} << 2);
                    // 60 * span via shifts: (span << 6) - (span << 2)
                    term_duty_max_rhs_q1 <= ({6'd0, span_calc} << 6) -
                                            ({6'd0, span_calc} << 2);
                    runs_cnt_q1          <= runs_cnt;
                    white_px_cnt_q1      <= white_px_cnt;
                    cur_line_y_q1        <= cur_line_y;
                    blank_fsm            <= FSM_PIPE_STAGE2;
                end

                // Pipeline Stage 2: Multiply mult_diff_q1 * runs_valid_q1 and evaluate condition flags
                FSM_PIPE_STAGE2: begin
                    term_reg1_q2    <= mult_diff_q1 * runs_valid_q1;
                    term_reg2_q2    <= term_reg2_q1;
                    cond_n_q2       <= cond_n_q1;
                    cond_span_q2    <= (!CFG_SPAN_EN) || ({6'd0, term_span_lhs_q1} >= term_span_rhs_q1);
                    cond_duty_q2    <= (!CFG_DUTY_EN) ||
                                       ((term_duty_lhs_q1 >= {2'd0, term_duty_min_rhs_q1}) &&
                                        (term_duty_lhs_q1 <= {2'd0, term_duty_max_rhs_q1}));
                    cond_gap_q2     <= (!CFG_GAP_EN) || (!gap_invalid_q1);
                    min_w_q2        <= min_w_q1;
                    max_w_q2        <= max_w_q1;
                    runs_valid_q2   <= runs_valid_q1;
                    runs_cnt_q2     <= runs_cnt_q1;
                    white_px_cnt_q2 <= white_px_cnt_q1;
                    cur_line_y_q2   <= cur_line_y_q1;
                    blank_fsm       <= FSM_EVAL_ROW;
                end

                // Pipeline Stage 3: Cand Decision & Row Result Latch
                FSM_EVAL_ROW: begin
                    row_cand       <= cond_n_q2 && cond_reg_stage3 && cond_span_q2 && cond_duty_q2 && cond_gap_q2;
                    row_runs_valid <= runs_valid_q2;
                    row_max_w      <= cond_n_q2 ? max_w_q2 : 8'd0;
                    row_min_w      <= cond_n_q2 ? min_w_q2 : 8'd0;
                    row_runs       <= runs_cnt_q2;
                    row_white_px   <= white_px_cnt_q2;
                    row_y          <= cur_line_y_q2;
                    row_done       <= 1'b1;
                    blank_fsm      <= FSM_UPDATE_FRAME;
                end

                // Pipeline Stage 4: Update Frame Tracking
                FSM_UPDATE_FRAME: begin
                    row_done <= 1'b0;
                    if ((cur_line_y_q2 >= Y_TOP) && (cur_line_y_q2 < Y_BOT)) begin
                        if (row_cand) begin
                            if (n_rows_acc == 8'd0) begin
                                y_min_acc <= cur_line_y_q2;
                            end
                            y_max_acc  <= cur_line_y_q2;
                            n_rows_acc <= n_rows_acc + 1'b1;

                            if (gap_rows <= 8'd2) begin
                                cur_cont <= cur_cont + 1'b1;
                                if ((cur_cont + 1'b1) > max_cont_acc)
                                    max_cont_acc <= cur_cont + 1'b1;
                            end else begin
                                cur_cont <= 8'd1;
                                if (8'd1 > max_cont_acc)
                                    max_cont_acc <= 8'd1;
                            end
                            gap_rows <= 8'd0;
                        end else begin
                            gap_rows <= gap_rows + 1'b1;
                            if ((gap_rows + 1'b1) > 8'd2) begin
                                cur_cont <= 8'd0;
                            end
                        end
                    end

                    if (cur_line_y_q2 == (Y_BOT - 10'd1)) begin
                        blank_fsm <= FSM_FRAME_DONE;
                    end else begin
                        blank_fsm <= FSM_IDLE;
                    end
                end

                // Pipeline Stage 5: Finalize Frame Outputs
                FSM_FRAME_DONE: begin
                    zebra_raw <= raw_comb;
                    n_rows    <= n_rows_acc;
                    max_cont  <= max_cont_acc;
                    y_min     <= (n_rows_acc > 8'd0) ? y_min_acc : 10'h3FF;
                    y_max     <= (n_rows_acc > 8'd0) ? y_max_acc : 10'h3FF;

                    // Update temporal hysteresis filter
                    if (raw_comb) begin
                        consec_pos <= consec_pos + 1'b1;
                        consec_neg <= 8'd0;
                        if ((consec_pos + 1'b1) >= DEF_HYST_POS)
                            zebra <= 1'b1;
                    end else begin
                        consec_neg <= consec_neg + 1'b1;
                        consec_pos <= 8'd0;
                        if ((consec_neg + 1'b1) >= DEF_HYST_NEG)
                            zebra <= 1'b0;
                    end

                    frame_done <= 1'b1;
                    blank_fsm  <= FSM_IDLE;
                end

                default: blank_fsm <= FSM_IDLE;
            endcase
        end
    end

endmodule
