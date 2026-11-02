`timescale 1ns/1ps
////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 2026/10/27
// Design Name: rt_lane_det
// Module Name: rt_lane_det
// Target Device: Logos2 PG2L100H
// Tool Versions: PDS 2025.2 / Questa FSE
// Description:
//   FPGA streaming lane detection module.
//   Strictly aligned with Python Golden Model (model.py & params.json):
//   - RGB565 quantize and 8-bit expand
//   - Grayscale and yellow channel synthesis
//   - d(y) ridge detection with shift registers (no BRAM line buffer)
//   - Continuous run extraction and width filter
//   - Dynamic tracking window W(y) and cold start closest selection
//   - Double yellow line detection
//   - Per-line accumulation (n, sum_y, sum_yy, sum_x, sum_xy, sum_xx)
//   - Blanking serial divider for least squares fitting a (Q16) and b (Q4)
//   - Multiplierless RMS integer verification
//   - Fixed-point EMA tracking (alpha = 1/2) and 12-frame lost counter
//   - Consecutive run solid/dashed classification and 24-frame majority voting
//   - Bottom row x_bot projection and lane departure warning
////////////////////////////////////////////////////////////////////////////////

module rt_lane_det #(
    parameter [9:0] DEF_Y_TOP          = 10'd260,
    parameter [9:0] DEF_Y_BOT          = 10'd500,
    parameter [9:0] DEF_X_C            = 10'd480,
    parameter [9:0] DEF_EGO_X          = 10'd480,
    parameter [7:0] DEF_WHITE_DELTA    = 8'd18,
    parameter [7:0] DEF_WHITE_G_MIN    = 8'd120,
    parameter [7:0] DEF_YELLOW_DELTA   = 8'd14,
    parameter [7:0] DEF_DEPART_MARGIN  = 8'd60,
    parameter [7:0] DEF_SOLID_ROWS     = 8'd61,
    parameter [7:0] DEF_DBL_ROWS       = 8'd61
)(
    input  wire        pix_clk,
    input  wire        rst_n,

    // Video stream (window 0, 960x540)
    input  wire        de,
    input  wire        vs,
    input  wire        hs,
    input  wire [7:0]  r,
    input  wire [7:0]  g,
    input  wire [7:0]  b,

    // Runtime configuration inputs (in pix_clk domain)
    input  wire        cfg_det_en,
    input  wire [9:0]  cfg_xc,
    input  wire [9:0]  cfg_ego_x,
    input  wire [9:0]  cfg_y_top,
    input  wire [9:0]  cfg_y_bot,
    input  wire [7:0]  cfg_white_delta,
    input  wire [7:0]  cfg_white_g_min,
    input  wire [7:0]  cfg_yellow_delta,
    input  wire [7:0]  cfg_depart_margin,
    input  wire [7:0]  cfg_solid_rows,
    input  wire [7:0]  cfg_dbl_rows,
    input  wire [3:0]  cfg_gap_tol,       // 20261104: 0x8F0[11:8] solid-run gap tolerance (rows), 0 = off (cam20 behaviour)

    // Lane line detection outputs (to OSD and Registers)
    output reg         out_l_valid,
    output reg         out_l_solid,
    output reg         out_l_double,
    output reg  [31:0] out_l_a_q16,
    output reg  [31:0] out_l_b_q4,
    output reg  [31:0] out_l_x_at_ytop_q16,
    output reg  [31:0] out_l_dx_q16,
    output reg  [15:0] out_l_x_bot,
    output reg  [7:0]  out_l_n,

    output reg         out_r_valid,
    output reg         out_r_solid,
    output reg         out_r_double,
    output reg  [31:0] out_r_a_q16,
    output reg  [31:0] out_r_b_q4,
    output reg  [31:0] out_r_x_at_ytop_q16,
    output reg  [31:0] out_r_dx_q16,
    output reg  [15:0] out_r_x_bot,
    output reg  [7:0]  out_r_n,

    output reg         out_depart,
    output reg         out_frame_done,
    output reg  [7:0]  out_frame_cnt,

    output reg  [7:0]  out_max_consec_l,
    output reg  [7:0]  out_max_consec_r,
    output reg  [7:0]  out_dbl_cnt_l,
    output reg  [7:0]  out_dbl_cnt_r,

    // Debug interface
    input       [9:0]  dbg_row,
    input       [9:0]  dbg_x,
    output wire [223:0] dbg_bus
) /* synthesis syn_hier = "fixed" */;


    // Initial constants from params.json
    localparam signed [31:0] INIT_A_LEFT  = -32'sd62259; // -0.95 * 65536
    localparam signed [31:0] INIT_B_LEFT  = 32'sd6400;  // 400.0 * 16
    localparam signed [31:0] INIT_A_RIGHT = 32'sd58982;  // 0.9 * 65536
    localparam signed [31:0] INIT_B_RIGHT = 32'sd8960;  // 560.0 * 16


    // Synchronize vsync edge
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

    reg [9:0] y_top_eff, y_bot_eff, xc_eff, ego_eff;
    reg [7:0] w_delta, w_gmin, y_delta, dep_margin;
    reg [7:0] solid_rows_eff, dbl_rows_eff;
    reg [3:0] gap_eff;

    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            y_top_eff      <= DEF_Y_TOP;
            y_bot_eff      <= DEF_Y_BOT;
            xc_eff         <= DEF_X_C;
            ego_eff        <= DEF_EGO_X;
            w_delta        <= DEF_WHITE_DELTA;
            w_gmin         <= DEF_WHITE_G_MIN;
            y_delta        <= DEF_YELLOW_DELTA;
            dep_margin     <= DEF_DEPART_MARGIN;
            solid_rows_eff <= DEF_SOLID_ROWS;
            dbl_rows_eff   <= DEF_DBL_ROWS;
            gap_eff        <= 4'd0;
        end else begin
            y_top_eff      <= (cfg_y_top != 10'd0) ? cfg_y_top : DEF_Y_TOP;
            y_bot_eff      <= (cfg_y_bot != 10'd0) ? cfg_y_bot : DEF_Y_BOT;
            xc_eff         <= (cfg_xc != 10'd0)    ? cfg_xc    : DEF_X_C;
            ego_eff        <= (cfg_ego_x != 10'd0) ? cfg_ego_x : DEF_EGO_X;
            w_delta        <= (cfg_white_delta != 8'd0) ? cfg_white_delta : DEF_WHITE_DELTA;
            w_gmin         <= (cfg_white_g_min != 8'd0) ? cfg_white_g_min : DEF_WHITE_G_MIN;
            y_delta        <= (cfg_yellow_delta != 8'd0)? cfg_yellow_delta: DEF_YELLOW_DELTA;
            dep_margin     <= (cfg_depart_margin!= 8'd0)? cfg_depart_margin:DEF_DEPART_MARGIN;
            solid_rows_eff <= (cfg_solid_rows != 8'd0)  ? cfg_solid_rows : DEF_SOLID_ROWS;
            dbl_rows_eff   <= (cfg_dbl_rows != 8'd0)    ? cfg_dbl_rows   : DEF_DBL_ROWS;
            gap_eff        <= cfg_gap_tol;
        end
    end


    reg [11:0] x_pos;
    reg [11:0] y_pos;
    reg [2:0]  lb_fsm;
    reg        in_roi_reg;

    wire in_roi = in_roi_reg;
    wire [8:0] y_roi = (y_pos >= y_top_eff) ? (y_pos[9:0] - y_top_eff) : 9'd0;

    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            x_pos <= 12'd0;
        end else if (vs_rise) begin
            x_pos <= 12'd0;
        end else if (de) begin
            x_pos <= x_pos + 1'b1;
        end else if (de_fall) begin
            x_pos <= 12'd0;
        end
    end



    //==========================================================================
    // Stage 0: RGB565 quantize & 8-bit expand + Color synthesis
    //==========================================================================
    wire [7:0] rq = {r[7:3], 3'b000};
    wire [7:0] gq = {g[7:2], 2'b00};
    wire [7:0] bq = {b[7:3], 3'b000};

    wire [7:0] G  = ({2'b00, rq} + {1'b0, gq, 1'b0} + {2'b00, bq}) >> 2;
    wire [7:0] Gy = ({1'b0, rq} + {1'b0, gq}) >> 1;
    wire [7:0] min_rg = (rq < gq) ? rq : gq;

    wire [47:0] px_pack = {min_rg, bq, gq, rq, Gy, G};

    //==========================================================================
    // Dynamic perspective scale d(y), search window W(y), w_max, w_pred
    // Pipeline registers for line blanking multi-stage calculation (timing closure)
    //==========================================================================
    reg [3:0] cur_dy;
    reg [5:0] cur_Wy;
    reg [5:0] cur_w_max;
    reg [4:0] cur_dbl_thr;

    reg [13:0] pipe_num_d;
    reg [14:0] pipe_num_W;
    reg [8:0]  pipe_y_roi;
    reg [3:0]  calc_dy_reg;
    reg [5:0]  calc_Wy_reg;

    // w_max banker's rounding exact match (synthesis safe, zero un-driven warnings):
    function [5:0] get_w_max;
        input [3:0] d;
        begin
            case (d)
                4'd1:    get_w_max = 6'd4;
                4'd2:    get_w_max = 6'd5;
                4'd3:    get_w_max = 6'd6;
                4'd4:    get_w_max = 6'd8;
                4'd5:    get_w_max = 6'd10;
                4'd6:    get_w_max = 6'd11;
                4'd7:    get_w_max = 6'd12;
                4'd8:    get_w_max = 6'd14;
                4'd9:    get_w_max = 6'd16;
                4'd10:   get_w_max = 6'd17;
                4'd11:   get_w_max = 6'd18;
                4'd12:   get_w_max = 6'd20;
                4'd13:   get_w_max = 6'd22;
                4'd14:   get_w_max = 6'd23;
                default: get_w_max = 6'd6;
            endcase
        end
    endfunction




    //==========================================================================
    // Shift register: 29 individual registers (0..28) to prevent PDS 2D RAM bugs
    //==========================================================================
    reg [47:0] sr_0,  sr_1,  sr_2,  sr_3,  sr_4,  sr_5,  sr_6,  sr_7;
    reg [47:0] sr_8,  sr_9,  sr_10, sr_11, sr_12, sr_13, sr_14, sr_15;
    reg [47:0] sr_16, sr_17, sr_18, sr_19, sr_20, sr_21, sr_22, sr_23;
    reg [47:0] sr_24, sr_25, sr_26, sr_27, sr_28;
    reg        de_pipe [0:28];

    integer si;
    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            sr_0  <= 48'd0; sr_1  <= 48'd0; sr_2  <= 48'd0; sr_3  <= 48'd0;
            sr_4  <= 48'd0; sr_5  <= 48'd0; sr_6  <= 48'd0; sr_7  <= 48'd0;
            sr_8  <= 48'd0; sr_9  <= 48'd0; sr_10 <= 48'd0; sr_11 <= 48'd0;
            sr_12 <= 48'd0; sr_13 <= 48'd0; sr_14 <= 48'd0; sr_15 <= 48'd0;
            sr_16 <= 48'd0; sr_17 <= 48'd0; sr_18 <= 48'd0; sr_19 <= 48'd0;
            sr_20 <= 48'd0; sr_21 <= 48'd0; sr_22 <= 48'd0; sr_23 <= 48'd0;
            sr_24 <= 48'd0; sr_25 <= 48'd0; sr_26 <= 48'd0; sr_27 <= 48'd0;
            sr_28 <= 48'd0;
            for (si = 0; si < 29; si = si + 1) de_pipe[si] <= 1'b0;
        end else begin
            sr_0  <= px_pack;
            sr_1  <= sr_0;  sr_2  <= sr_1;  sr_3  <= sr_2;  sr_4  <= sr_3;
            sr_5  <= sr_4;  sr_6  <= sr_5;  sr_7  <= sr_6;  sr_8  <= sr_7;
            sr_9  <= sr_8;  sr_10 <= sr_9;  sr_11 <= sr_10; sr_12 <= sr_11;
            sr_13 <= sr_12; sr_14 <= sr_13; sr_15 <= sr_14; sr_16 <= sr_15;
            sr_17 <= sr_16; sr_18 <= sr_17; sr_19 <= sr_18; sr_20 <= sr_19;
            sr_21 <= sr_20; sr_22 <= sr_21; sr_23 <= sr_22; sr_24 <= sr_23;
            sr_25 <= sr_24; sr_26 <= sr_25; sr_27 <= sr_26; sr_28 <= sr_27;

            de_pipe[0] <= de;
            for (si = 1; si < 29; si = si + 1) de_pipe[si] <= de_pipe[si-1];
        end
    end

    // Tap MUX based on cur_dy
    reg [47:0] center_px;
    reg [47:0] left_px;
    reg        center_de;
    always @(*) begin
        case (cur_dy)
            4'd3:  begin center_px = sr_3;  left_px = sr_6;  center_de = de_pipe[3];  end
            4'd4:  begin center_px = sr_4;  left_px = sr_8;  center_de = de_pipe[4];  end
            4'd5:  begin center_px = sr_5;  left_px = sr_10; center_de = de_pipe[5];  end
            4'd6:  begin center_px = sr_6;  left_px = sr_12; center_de = de_pipe[6];  end
            4'd7:  begin center_px = sr_7;  left_px = sr_14; center_de = de_pipe[7];  end
            4'd8:  begin center_px = sr_8;  left_px = sr_16; center_de = de_pipe[8];  end
            4'd9:  begin center_px = sr_9;  left_px = sr_18; center_de = de_pipe[9];  end
            4'd10: begin center_px = sr_10; left_px = sr_20; center_de = de_pipe[10]; end
            4'd11: begin center_px = sr_11; left_px = sr_22; center_de = de_pipe[11]; end
            4'd12: begin center_px = sr_12; left_px = sr_24; center_de = de_pipe[12]; end
            4'd13: begin center_px = sr_13; left_px = sr_26; center_de = de_pipe[13]; end
            4'd14: begin center_px = sr_14; left_px = sr_28; center_de = de_pipe[14]; end
            default: begin center_px = sr_3; left_px = sr_6; center_de = de_pipe[3];  end
        endcase
    end

    wire [7:0] right_G       = sr_0[7:0];
    wire [7:0] right_Gy      = sr_0[15:8];
    wire [7:0] center_G      = center_px[7:0];
    wire [7:0] center_Gy     = center_px[15:8];
    wire [7:0] center_rq     = center_px[23:16];
    wire [7:0] center_gq     = center_px[31:24];
    wire [7:0] center_bq     = center_px[39:32];
    wire [7:0] center_min_rg = center_px[47:40];
    wire [7:0] left_G        = left_px[7:0];
    wire [7:0] left_Gy       = left_px[15:8];


    // Pipeline stage 1: coordinate & max
    reg [11:0] x_center_s1;
    reg [7:0]  max_G_s1, max_Gy_s1;
    reg [7:0]  cG_s1, cGy_s1, crq_s1, cgq_s1, cbq_s1, cmin_rg_s1;
    reg        in_range_s1;

    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            x_center_s1 <= 12'd0;
            max_G_s1    <= 8'd0;
            max_Gy_s1   <= 8'd0;
            cG_s1       <= 8'd0;
            cGy_s1      <= 8'd0;
            crq_s1      <= 8'd0;
            cgq_s1      <= 8'd0;
            cbq_s1      <= 8'd0;
            cmin_rg_s1  <= 8'd0;
            in_range_s1 <= 1'b0;
        end else begin
            x_center_s1 <= (x_pos > {8'd0, cur_dy}) ? (x_pos - {8'd0, cur_dy} - 12'd1) : 12'd0;
            max_G_s1    <= (left_G > right_G)   ? left_G  : right_G;
            max_Gy_s1   <= (left_Gy > right_Gy) ? left_Gy : right_Gy;
            cG_s1       <= center_G;
            cGy_s1      <= center_Gy;
            crq_s1      <= center_rq;
            cgq_s1      <= center_gq;
            cbq_s1      <= center_bq;
            cmin_rg_s1  <= center_min_rg;
            in_range_s1 <= center_de && in_roi &&
                           ((x_pos > {8'd0, cur_dy}) ? (x_pos - {8'd0, cur_dy} - 12'd1) : 12'd0) >= {8'd0, cur_dy} &&
                           ((x_pos > {8'd0, cur_dy}) ? (x_pos - {8'd0, cur_dy} - 12'd1) : 12'd0) < (12'd960 - {8'd0, cur_dy});
        end
    end

    // Pipeline stage 2: Ridge & Color comparison
    wire signed [9:0] R_w = $signed({2'b00, cG_s1})  - $signed({2'b00, max_G_s1});
    wire signed [9:0] R_y = $signed({2'b00, cGy_s1}) - $signed({2'b00, max_Gy_s1});
    wire is_white = in_range_s1 && (R_w >= $signed({2'b00, w_delta})) && (cG_s1 >= w_gmin);
    wire is_yellow= in_range_s1 && (crq_s1 >= 8'd130) && (cgq_s1 >= 8'd120) &&
                    (({1'b0, cbq_s1} + 9'd20) <= {1'b0, cmin_rg_s1}) &&
                    (R_y >= $signed({2'b00, y_delta}));
    wire is_lane  = is_white | is_yellow;


    reg        is_lane_s2;
    reg        is_white_s2;
    reg        is_yellow_s2;
    reg [11:0] x_center_s2;
    reg        in_roi_s2;
    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            is_lane_s2   <= 1'b0;
            is_white_s2  <= 1'b0;
            is_yellow_s2 <= 1'b0;
            x_center_s2  <= 12'd0;
            in_roi_s2    <= 1'b0;
        end else begin
            is_lane_s2   <= is_lane;
            is_white_s2  <= is_white;
            is_yellow_s2 <= is_yellow;
            x_center_s2  <= x_center_s1;
            in_roi_s2    <= in_range_s1;
        end
    end




    //==========================================================================
    // Run Extraction and Width Filter
    //==========================================================================
    reg is_lane_prev;
    reg [9:0] run_len;
    reg [9:0] run_start;
    reg       run_valid;
    reg [9:0] run_center;

    wire [10:0] run_end_val = {1'b0, x_center_s2[9:0]};
    wire [10:0] run_sum     = {1'b0, run_start} + run_end_val - 11'd1;

    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            is_lane_prev <= 1'b0;
            run_len      <= 10'd0;
            run_start    <= 10'd0;
            run_valid    <= 1'b0;
            run_center   <= 10'd0;
        end else if (!in_roi_s2) begin
            if (is_lane_prev) begin
                if ((run_len >= 10'd1) && (run_len <= {4'd0, cur_w_max})) begin
                    run_valid  <= 1'b1;
                    run_center <= run_sum[10:1];
                end
            end else begin
                run_valid <= 1'b0;
            end
            is_lane_prev <= 1'b0;
            run_len      <= 10'd0;
        end else begin
            run_valid <= 1'b0;
            is_lane_prev <= is_lane_s2;
            if (is_lane_s2) begin
                if (!is_lane_prev) begin
                    run_start <= x_center_s2[9:0];
                    run_len   <= 10'd1;
                end else begin
                    run_len   <= run_len + 10'd1;
                end
            end else if (is_lane_prev) begin
                if ((run_len >= 10'd1) && (run_len <= {4'd0, cur_w_max})) begin
                    run_valid  <= 1'b1;
                    run_center <= run_sum[10:1];
                end
                run_len <= 10'd0;
            end
        end
    end


    //==========================================================================
    // Run buffer and on-the-fly candidate tracking
    //==========================================================================
    reg [9:0] run_buf [0:127];
    reg [6:0] run_cnt;

    // Track states from EMA
    reg track_valid_l, track_valid_r;
    reg signed [31:0] ema_a_l, ema_b_l;
    reg signed [31:0] ema_a_r, ema_b_r;

    // Line predicted positions
    reg signed [15:0] x_pred_l;
    reg signed [15:0] x_pred_r;

    // On-the-fly best candidate selection
    reg [9:0] best_x_l, best_x_r;
    reg [9:0] best_dist_l, best_dist_r;
    reg       l_found, r_found;

    wire [9:0] dist_pred_l = (run_center > x_pred_l[9:0]) ? (run_center - x_pred_l[9:0]) : (x_pred_l[9:0] - run_center);
    wire [9:0] dist_pred_r = (run_center > x_pred_r[9:0]) ? (run_center - x_pred_r[9:0]) : (x_pred_r[9:0] - run_center);

    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            run_cnt      <= 7'd0;
            best_x_l     <= 10'd0;
            best_dist_l  <= 10'd1023;
            l_found      <= 1'b0;
            best_x_r     <= 10'd0;
            best_dist_r  <= 10'd1023;
            r_found      <= 1'b0;
        end else if (de_fall) begin
            // Prepared for blanking evaluation, reset during blanking FSM
        end else if (de && (x_pos == 12'd0)) begin
            run_cnt      <= 7'd0;
            best_dist_l  <= 10'd1023;
            best_dist_r  <= 10'd1023;
            l_found      <= 1'b0;
            r_found      <= 1'b0;
        end else if (run_valid) begin
            if (run_cnt < 7'd127) begin
                run_buf[run_cnt] <= run_center;
                run_cnt          <= run_cnt + 7'd1;
            end

            // Left side candidate
            if (run_center < xc_eff) begin
                if (track_valid_l) begin
                    if (dist_pred_l <= {4'd0, cur_Wy}) begin
                        if (!l_found || (dist_pred_l < best_dist_l)) begin
                            best_x_l    <= run_center;
                            best_dist_l <= dist_pred_l;
                            l_found     <= 1'b1;
                        end
                    end
                end else begin
                    // Cold start: pick max(left_runs) (last one before xc)
                    best_x_l <= run_center;
                    l_found  <= 1'b1;
                end
            end

            // Right side candidate
            if (run_center >= xc_eff) begin
                if (track_valid_r) begin
                    if (dist_pred_r <= {4'd0, cur_Wy}) begin
                        if (!r_found || (dist_pred_r < best_dist_r)) begin
                            best_x_r    <= run_center;
                            best_dist_r <= dist_pred_r;
                            r_found     <= 1'b1;
                        end
                    end
                end else begin
                    // Cold start: pick min(right_runs) (first one >= xc)
                    if (!r_found) begin
                        best_x_r <= run_center;
                        r_found  <= 1'b1;
                    end
                end
            end
        end
    end

    //==========================================================================
    // Line Blanking FSM: Double flag evaluation & Accumulator updates
    //==========================================================================
    reg [6:0] lb_idx;
    reg       dbl_l_reg, dbl_r_reg;


    // Accumulators for Left & Right
    reg [7:0]  acc_n_l,   acc_n_r;
    reg [15:0] acc_sy_l,  acc_sy_r;
    reg [23:0] acc_syy_l, acc_syy_r;
    reg [17:0] acc_sx_l,  acc_sx_r;
    reg [25:0] acc_sxy_l, acc_sxy_r;
    reg [27:0] acc_sxx_l, acc_sxx_r;

    reg [7:0]  cur_consec_l, max_consec_l;
    reg [7:0]  cur_consec_r, max_consec_r;
    reg [7:0]  double_cnt_l, double_cnt_r;
    reg [3:0]  cur_gap_l, cur_gap_r;      // missed rows inside the current run (gap tolerance)

    wire [9:0] dbl_dist_l = (run_buf[lb_idx] > best_x_l) ? (run_buf[lb_idx] - best_x_l) : (best_x_l - run_buf[lb_idx]);


    wire [9:0] dbl_dist_r = (run_buf[lb_idx] > best_x_r) ? (run_buf[lb_idx] - best_x_r) : (best_x_r - run_buf[lb_idx]);

    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            lb_fsm       <= 3'd0;
            lb_idx       <= 7'd0;
            dbl_l_reg    <= 1'b0;
            dbl_r_reg    <= 1'b0;
            acc_n_l      <= 8'd0;
            acc_sy_l     <= 16'd0;
            acc_syy_l    <= 24'd0;
            acc_sx_l     <= 18'd0;
            acc_sxy_l    <= 26'd0;
            acc_sxx_l    <= 28'd0;
            acc_n_r      <= 8'd0;
            acc_sy_r     <= 16'd0;
            acc_syy_r    <= 24'd0;
            acc_sx_r     <= 18'd0;
            acc_sxy_r    <= 26'd0;
            acc_sxx_r    <= 28'd0;
            cur_consec_l <= 8'd0;
            max_consec_l <= 8'd0;
            cur_consec_r <= 8'd0;
            max_consec_r <= 8'd0;
            cur_gap_l    <= 4'd0;
            cur_gap_r    <= 4'd0;
            double_cnt_l <= 8'd0;
            double_cnt_r <= 8'd0;
            cur_dy       <= 4'd3;
            cur_Wy       <= 6'd12;
            cur_w_max    <= 6'd6;
            cur_dbl_thr  <= 5'd6;
            pipe_num_d   <= 14'd0;
            pipe_num_W   <= 15'd0;
            pipe_y_roi   <= 9'd0;
            calc_dy_reg  <= 4'd3;
            calc_Wy_reg  <= 6'd12;
            y_pos        <= 12'd0;
            in_roi_reg   <= 1'b0;
            x_pred_l     <= (INIT_B_LEFT + 32'sd8) >>> 4;
            x_pred_r     <= (INIT_B_RIGHT + 32'sd8) >>> 4;
        end else if (vs_rise) begin


            lb_fsm       <= 3'd0;
            acc_n_l      <= 8'd0;
            acc_sy_l     <= 16'd0;
            acc_syy_l    <= 24'd0;
            acc_sx_l     <= 18'd0;
            acc_sxy_l    <= 26'd0;
            acc_sxx_l    <= 28'd0;
            acc_n_r      <= 8'd0;
            acc_sy_r     <= 16'd0;
            acc_syy_r    <= 24'd0;
            acc_sx_r     <= 18'd0;
            acc_sxy_r    <= 26'd0;
            acc_sxx_r    <= 28'd0;
            cur_consec_l <= 8'd0;
            max_consec_l <= 8'd0;
            cur_consec_r <= 8'd0;
            max_consec_r <= 8'd0;
            cur_gap_l    <= 4'd0;
            cur_gap_r    <= 4'd0;
            double_cnt_l <= 8'd0;
            double_cnt_r <= 8'd0;
            cur_dy       <= 4'd3;
            cur_Wy       <= 6'd12;
            cur_w_max    <= 6'd6;
            cur_dbl_thr  <= 5'd6;
            calc_dy_reg  <= 4'd3;
            calc_Wy_reg  <= 6'd12;
            x_pred_l     <= (ema_b_l + 32'sd8) >>> 4;
            x_pred_r     <= (ema_b_r + 32'sd8) >>> 4;
            y_pos        <= 12'd0;
            in_roi_reg   <= 1'b0;
        end else begin
            case (lb_fsm)
                3'd0: begin
                    if (de_fall) begin
                        if (in_roi_reg) begin
                            lb_idx    <= 7'd0;
                            dbl_l_reg <= 1'b0;
                            dbl_r_reg <= 1'b0;
                            if (run_cnt != 7'd0)
                                lb_fsm <= 3'd1;
                            else
                                lb_fsm <= 3'd2;
                        end else begin
                            y_pos      <= y_pos + 1'b1;
                            in_roi_reg <= ((y_pos + 10'd1) >= y_top_eff) && ((y_pos + 10'd1) <= y_bot_eff);
                        end
                    end
                end


                3'd1: begin
                    if (l_found && (run_buf[lb_idx] < xc_eff)) begin
                        if ((dbl_dist_l >= 10'd3) && (dbl_dist_l <= {5'd0, cur_dbl_thr}))
                            dbl_l_reg <= 1'b1;
                    end
                    if (r_found && (run_buf[lb_idx] >= xc_eff)) begin
                        if ((dbl_dist_r >= 10'd3) && (dbl_dist_r <= {5'd0, cur_dbl_thr}))
                            dbl_r_reg <= 1'b1;
                    end

                    if (lb_idx + 7'd1 < run_cnt) begin
                        lb_idx <= lb_idx + 7'd1;
                    end else begin
                        lb_fsm <= 3'd2;
                    end
                end

                3'd2: begin
                    // Accumulate Left






                    if (l_found) begin
                        acc_n_l   <= acc_n_l + 8'd1;
                        acc_sy_l  <= acc_sy_l + {7'd0, y_roi};
                        acc_syy_l <= acc_syy_l + ({15'd0, y_roi} * {15'd0, y_roi});
                        acc_sx_l  <= acc_sx_l + {8'd0, best_x_l};
                        acc_sxy_l <= acc_sxy_l + ({16'd0, best_x_l} * {17'd0, y_roi});
                        acc_sxx_l <= acc_sxx_l + ({18'd0, best_x_l} * {18'd0, best_x_l});
                        if (dbl_l_reg) double_cnt_l <= double_cnt_l + 8'd1;

                        cur_consec_l <= cur_consec_l + 8'd1;
                        cur_gap_l    <= 4'd0;
                        if (cur_consec_l + 8'd1 > max_consec_l)
                            max_consec_l <= cur_consec_l + 8'd1;
                    end else if (cur_gap_l < gap_eff) begin
                        cur_gap_l    <= cur_gap_l + 4'd1;   // tolerated miss: keep the run, do not count
                    end else begin
                        cur_consec_l <= 8'd0;
                        cur_gap_l    <= 4'd0;
                    end

                    // Accumulate Right
                    if (r_found) begin
                        acc_n_r   <= acc_n_r + 8'd1;
                        acc_sy_r  <= acc_sy_r + {7'd0, y_roi};
                        acc_syy_r <= acc_syy_r + ({15'd0, y_roi} * {15'd0, y_roi});
                        acc_sx_r  <= acc_sx_r + {8'd0, best_x_r};
                        acc_sxy_r <= acc_sxy_r + ({16'd0, best_x_r} * {17'd0, y_roi});
                        acc_sxx_r <= acc_sxx_r + ({18'd0, best_x_r} * {18'd0, best_x_r});
                        if (dbl_r_reg) double_cnt_r <= double_cnt_r + 8'd1;

                        cur_consec_r <= cur_consec_r + 8'd1;
                        cur_gap_r    <= 4'd0;
                        if (cur_consec_r + 8'd1 > max_consec_r)
                            max_consec_r <= cur_consec_r + 8'd1;
                    end else if (cur_gap_r < gap_eff) begin
                        cur_gap_r    <= cur_gap_r + 4'd1;   // tolerated miss: keep the run, do not count
                    end else begin
                        cur_consec_r <= 8'd0;
                        cur_gap_r    <= 4'd0;
                    end

                    // Pipeline Stage 1 for next row (timing closure)
                    pipe_num_d <= 14'd720 + (y_roi + 9'd1) * 14'd11 + 14'd120;
                    pipe_num_W <= 15'd2880 + (y_roi + 9'd1) * 15'd28 + 15'd120;
                    pipe_y_roi <= y_roi + 9'd1;
                    y_pos      <= y_pos + 1'b1;
                    in_roi_reg <= ((y_pos + 10'd1) >= y_top_eff) && ((y_pos + 10'd1) <= y_bot_eff);
                    lb_fsm     <= 3'd3;
                end

                // Pipeline Stage 2: 14-bit dividers for dy and Wy
                3'd3: begin
                    calc_dy_reg <= pipe_num_d / 14'd240;
                    calc_Wy_reg <= pipe_num_W / 15'd240;
                    lb_fsm      <= 3'd4;
                end

                // Pipeline Stage 3: update line registers and predict x
                3'd4: begin
                    cur_dy      <= calc_dy_reg;
                    cur_Wy      <= calc_Wy_reg;
                    cur_w_max   <= get_w_max(calc_dy_reg);
                    cur_dbl_thr <= {calc_dy_reg, 1'b0};
                    x_pred_l    <= ((ema_a_l * $signed({23'd0, pipe_y_roi}) + 32'sd32768) >>> 16) +
                                   ((ema_b_l + 32'sd8) >>> 4);
                    x_pred_r    <= ((ema_a_r * $signed({23'd0, pipe_y_roi}) + 32'sd32768) >>> 16) +
                                   ((ema_b_r + 32'sd8) >>> 4);
                    lb_fsm      <= 3'd0;
                end




                default: lb_fsm <= 3'd0;
            endcase
        end
    end

    //==========================================================================
    // Debug registers capture
    //==========================================================================
    reg [11:0] lb_row;
    reg [23:0] dbg_px_rgb;
    reg [10:0] line_white_cnt, line_yellow_cnt;
    reg [9:0]  line_first_ridge_x, line_last_ridge_x;
    reg        line_has_ridge;
    reg [7:0]  line_run_cnt_full;
    reg [9:0]  line_run_0, line_run_1, line_run_2, line_run_last;
    reg [31:0] dbg_reg_0xA04, dbg_reg_0xA08, dbg_reg_0xA0C, dbg_reg_0xA10, dbg_reg_0xA14, dbg_reg_0xA18, dbg_reg_0xA1C;
    assign dbg_bus = { dbg_reg_0xA1C, dbg_reg_0xA18, dbg_reg_0xA14, dbg_reg_0xA10, dbg_reg_0xA0C, dbg_reg_0xA08, dbg_reg_0xA04 };

    wire lb_in_roi = (lb_row >= y_top_eff) && (lb_row <= y_bot_eff);
    wire dbg_row_match = (lb_row == {2'd0, dbg_row});
    wire dbg_latch_now = dbg_row_match && ((lb_in_roi && (lb_fsm == 3'd4)) || (!lb_in_roi && de_fall));

    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            lb_row              <= 12'd0;
            dbg_px_rgb          <= 24'd0;
            line_white_cnt      <= 11'd0;
            line_yellow_cnt     <= 11'd0;
            line_first_ridge_x  <= 10'd0;
            line_last_ridge_x   <= 10'd0;
            line_has_ridge      <= 1'b0;
            line_run_cnt_full   <= 8'd0;
            line_run_0          <= 10'd0;
            line_run_1          <= 10'd0;
            line_run_2          <= 10'd0;
            line_run_last       <= 10'd0;
            dbg_reg_0xA04       <= 32'd0;
            dbg_reg_0xA08       <= 32'd0;
            dbg_reg_0xA0C       <= 32'd0;
            dbg_reg_0xA10       <= 32'd0;
            dbg_reg_0xA14       <= 32'd0;
            dbg_reg_0xA18       <= 32'd0;
            dbg_reg_0xA1C       <= 32'd0;
        end else begin
            if (de && (x_pos == 12'd0)) begin
                lb_row              <= y_pos;
                line_white_cnt      <= 11'd0;
                line_yellow_cnt     <= 11'd0;
                line_first_ridge_x  <= 10'd0;
                line_last_ridge_x   <= 10'd0;
                line_has_ridge      <= 1'b0;
                line_run_cnt_full   <= 8'd0;
                line_run_0          <= 10'd0;
                line_run_1          <= 10'd0;
                line_run_2          <= 10'd0;
                line_run_last       <= 10'd0;
            end else begin
                if (de_fall) lb_row <= y_pos;

                if (de && (y_pos == {2'd0, dbg_row}) && (x_pos == {2'd0, dbg_x})) begin
                    dbg_px_rgb <= {r, g, b};
                end

                if (is_lane_s2 && in_roi_s2) begin
                    if (is_white_s2)  line_white_cnt  <= line_white_cnt + 11'd1;
                    if (is_yellow_s2) line_yellow_cnt <= line_yellow_cnt + 11'd1;
                    if (!line_has_ridge) begin
                        line_first_ridge_x <= x_center_s2[9:0];
                        line_has_ridge     <= 1'b1;
                    end
                    line_last_ridge_x <= x_center_s2[9:0];
                end

                if (run_valid) begin
                    if (line_run_cnt_full < 8'hFF)
                        line_run_cnt_full <= line_run_cnt_full + 8'd1;
                    if (line_run_cnt_full == 8'd0) line_run_0 <= run_center;
                    if (line_run_cnt_full == 8'd1) line_run_1 <= run_center;
                    if (line_run_cnt_full == 8'd2) line_run_2 <= run_center;
                    line_run_last <= run_center;
                end
            end

            if (dbg_latch_now) begin
                dbg_reg_0xA04 <= { 4'd0, in_roi_reg ? track_valid_r : 1'b0, in_roi_reg ? r_found : 1'b0, in_roi_reg ? best_x_r : 10'd0,
                                   4'd0, in_roi_reg ? track_valid_l : 1'b0, in_roi_reg ? l_found : 1'b0, in_roi_reg ? best_x_l : 10'd0 };
                dbg_reg_0xA08 <= { 2'd0, cur_Wy, 2'd0, cur_w_max, 4'd0, cur_dy, 1'b0, (line_run_cnt_full > 8'd127 ? 7'd127 : line_run_cnt_full[6:0]) };
                dbg_reg_0xA0C <= { 6'd0, line_run_1, 6'd0, line_run_0 };
                dbg_reg_0xA10 <= { 6'd0, line_run_last, 6'd0, line_run_2 };
                dbg_reg_0xA14 <= { 8'd0, dbg_px_rgb };
                dbg_reg_0xA18 <= { 5'd0, line_yellow_cnt, 5'd0, line_white_cnt };
                dbg_reg_0xA1C <= { 6'd0, line_last_ridge_x, 6'd0, line_first_ridge_x };
            end
        end
    end

    //==========================================================================
    // Frame End Solver FSM: Least squares fit, serial divider, RMS, EMA, voting
    //==========================================================================
    reg [4:0]  fe_fsm;
    reg        side_sel; // 0: left, 1: right

    // Multipliers for Least Squares
    reg signed [31:0] cur_D;
    reg signed [63:0] cur_Na_shift;
    reg signed [63:0] cur_Nb_shift;
    reg signed [63:0] cur_Sxx;
    reg signed [31:0] cur_Sxy;
    reg signed [31:0] cur_Sx;
    reg [7:0]         cur_n;

    // Pipeline registers for FE solver DSP multipliers (timing closure)
    reg signed [31:0] p_n_Syy, p_Sy_Sy;
    reg signed [34:0] p_n_Sxy, p_Sx_Sy;
    reg signed [42:0] p_Sx_Syy, p_Sy_Sxy;
    reg signed [31:0] cur_a_op, cur_b_op;
    reg signed [48:0] part_a_low;
    reg signed [47:0] part_a_high;
    reg signed [63:0] term_a_reg, term_b_reg;
    reg signed [31:0] term_xbot_reg;
    reg signed [63:0] sse_reg;
    reg signed [31:0] x_bot_raw_reg, x_top_raw_reg;
    reg               slope_ok_reg, range_ok_reg, rms_ok_reg;
    reg               cur_valid_fit_reg;
    reg               solid_flag_reg, dbl_flag_reg;
    reg [1:0]         cur_f_type_reg;
    reg signed [31:0] x_bot_l_reg, x_bot_r_reg;
    reg               dep_l_reg, dep_r_reg;
    reg [1:0]         vote_l_reg, vote_r_reg;




    // Serial Restoring Divider
    reg [5:0]  div_cnt;
    reg [55:0] div_rem;
    reg [55:0] div_num;
    reg [31:0] div_den;
    reg [31:0] div_quot;
    reg        div_is_neg;
    reg        div_busy;

    reg signed [31:0] raw_a_l, raw_b_l;
    reg signed [31:0] raw_a_r, raw_b_r;
    reg               raw_valid_l, raw_valid_r;

    reg [3:0] lost_cnt_l, lost_cnt_r;
    reg [1:0] frame_type_l, frame_type_r; // 0: none, 1: dashed, 2: solid, 3: double_yellow
    reg [47:0] hist_types_l, hist_types_r; // 24 entries x 2 bits

    // Majority voting helper
    function [1:0] vote_24;
        input [47:0] h;
        integer vi;
        reg [4:0] n_solid, n_dash, n_dbl;
        reg [1:0] t;
        begin
            n_solid = 5'd0; n_dash = 5'd0; n_dbl = 5'd0;
            for (vi = 0; vi < 24; vi = vi + 1) begin
                t = h[vi*2 +: 2];
                if ((t == 2'd2) || (t == 2'd3)) n_solid = n_solid + 5'd1;
                if (t == 2'd1) n_dash = n_dash + 5'd1;
                if (t == 2'd3) n_dbl = n_dbl + 5'd1;
            end
            if ((n_solid + n_dash) == 5'd0)
                vote_24 = 2'd0;
            else if (n_solid >= n_dash) begin
                if ({n_dbl, 1'b0} > n_solid)
                    vote_24 = 2'd3;
                else
                    vote_24 = 2'd2;
            end else begin
                vote_24 = 2'd1;
            end
        end
    endfunction

    // Serial Restoring Divider Core: div_num / div_den -> div_quot
    wire [55:0] next_rem_shift = {div_rem[54:0], div_num[55]};
    wire        div_sub_ok = (next_rem_shift >= {24'd0, div_den});
    wire [55:0] next_rem = div_sub_ok ? (next_rem_shift - {24'd0, div_den}) : next_rem_shift;

    wire frame_trigger = (y_pos == (y_bot_eff + 10'd1));

    always @(posedge pix_clk or negedge rst_n) begin


        if (!rst_n) begin
            fe_fsm         <= 5'd0;
            side_sel       <= 1'b0;
            div_busy       <= 1'b0;
            div_cnt        <= 6'd0;
            div_rem        <= 56'd0;
            div_num        <= 56'd0;
            div_den        <= 32'd0;
            div_quot       <= 32'd0;
            div_is_neg     <= 1'b0;
            raw_a_l        <= 32'd0;
            raw_b_l        <= 32'd0;
            raw_valid_l    <= 1'b0;
            raw_a_r        <= 32'd0;
            raw_b_r        <= 32'd0;
            raw_valid_r    <= 1'b0;
            track_valid_l  <= 1'b1; // cold start valid
            track_valid_r  <= 1'b1;
            ema_a_l        <= INIT_A_LEFT;
            ema_b_l        <= INIT_B_LEFT;
            ema_a_r        <= INIT_A_RIGHT;
            ema_b_r        <= INIT_B_RIGHT;
            lost_cnt_l     <= 4'd0;
            lost_cnt_r     <= 4'd0;
            hist_types_l   <= 48'd0;
            hist_types_r   <= 48'd0;
            frame_type_l   <= 2'd0;
            frame_type_r   <= 2'd0;
            cur_D          <= 32'sd0;
            cur_Na_shift   <= 64'sd0;
            cur_Nb_shift   <= 64'sd0;
            cur_Sxx        <= 64'sd0;
            cur_Sxy        <= 32'sd0;
            cur_Sx         <= 32'sd0;
            cur_n          <= 8'd0;
            p_n_Syy        <= 32'sd0;
            p_Sy_Sy        <= 32'sd0;
            p_n_Sxy        <= 35'sd0;
            p_Sx_Sy        <= 35'sd0;
            p_Sx_Syy       <= 43'sd0;
            p_Sy_Sxy       <= 43'sd0;
            cur_a_op          <= 32'sd0;
            cur_b_op          <= 32'sd0;
            part_a_low        <= 49'sd0;
            part_a_high       <= 48'sd0;
            term_a_reg        <= 64'sd0;
            term_b_reg        <= 64'sd0;
            term_xbot_reg     <= 32'sd0;
            sse_reg           <= 64'sd0;
            x_bot_raw_reg     <= 32'sd0;
            x_top_raw_reg     <= 32'sd0;
            slope_ok_reg      <= 1'b0;
            range_ok_reg      <= 1'b0;
            rms_ok_reg        <= 1'b0;
            cur_valid_fit_reg <= 1'b0;
            solid_flag_reg    <= 1'b0;
            dbl_flag_reg      <= 1'b0;
            cur_f_type_reg    <= 2'd0;
            x_bot_l_reg       <= 32'sd0;
            x_bot_r_reg       <= 32'sd0;
            dep_l_reg         <= 1'b0;
            dep_r_reg         <= 1'b0;
            vote_l_reg        <= 2'd0;
            vote_r_reg        <= 2'd0;
            out_l_valid       <= 1'b0;


            out_l_solid    <= 1'b0;

            out_l_double   <= 1'b0;
            out_l_a_q16    <= INIT_A_LEFT;
            out_l_b_q4     <= INIT_B_LEFT;
            out_l_x_at_ytop_q16 <= (INIT_B_LEFT << 12) + 32'sd32768;
            out_l_dx_q16   <= INIT_A_LEFT;
            out_l_x_bot    <= 16'd172;
            out_l_n        <= 8'd0;
            out_r_valid    <= 1'b0;
            out_r_solid    <= 1'b0;
            out_r_double   <= 1'b0;
            out_r_a_q16    <= INIT_A_RIGHT;
            out_r_b_q4     <= INIT_B_RIGHT;
            out_r_x_at_ytop_q16 <= (INIT_B_RIGHT << 12) + 32'sd32768;
            out_r_dx_q16   <= INIT_A_RIGHT;
            out_r_x_bot    <= 16'd776;
            out_r_n        <= 8'd0;
            out_depart          <= 1'b0;
            out_frame_done      <= 1'b0;
            out_frame_cnt       <= 8'd0;
            out_max_consec_l    <= 8'd0;
            out_max_consec_r    <= 8'd0;
            out_dbl_cnt_l       <= 8'd0;
            out_dbl_cnt_r       <= 8'd0;
        end else begin
            out_frame_done <= 1'b0;

            case (fe_fsm)
                5'd0: begin
                    if (frame_trigger) begin
                        side_sel <= 1'b0; // Start Left
                        fe_fsm   <= 5'd1;
                    end
                end

                // Step 1: Calculate products for D, Na, Nb
                5'd1: begin
                    if (side_sel == 1'b0) begin
                        cur_n   <= acc_n_l;
                        cur_Sxx <= {36'd0, acc_sxx_l};
                        cur_Sxy <= {6'd0, acc_sxy_l};
                        cur_Sx  <= {14'd0, acc_sx_l};
                        p_n_Syy <= $signed({1'b0, acc_n_l}) * $signed({1'b0, acc_syy_l});
                        p_Sy_Sy <= $signed({1'b0, acc_sy_l}) * $signed({1'b0, acc_sy_l});
                        p_n_Sxy <= $signed({1'b0, acc_n_l}) * $signed({1'b0, acc_sxy_l});
                        p_Sx_Sy <= $signed({1'b0, acc_sx_l}) * $signed({1'b0, acc_sy_l});
                        p_Sx_Syy<= $signed({1'b0, acc_sx_l}) * $signed({1'b0, acc_syy_l});
                        p_Sy_Sxy<= $signed({1'b0, acc_sy_l}) * $signed({1'b0, acc_sxy_l});
                    end else begin
                        cur_n   <= acc_n_r;
                        cur_Sxx <= {36'd0, acc_sxx_r};
                        cur_Sxy <= {6'd0, acc_sxy_r};
                        cur_Sx  <= {14'd0, acc_sx_r};
                        p_n_Syy <= $signed({1'b0, acc_n_r}) * $signed({1'b0, acc_syy_r});
                        p_Sy_Sy <= $signed({1'b0, acc_sy_r}) * $signed({1'b0, acc_sy_r});
                        p_n_Sxy <= $signed({1'b0, acc_n_r}) * $signed({1'b0, acc_sxy_r});
                        p_Sx_Sy <= $signed({1'b0, acc_sx_r}) * $signed({1'b0, acc_sy_r});
                        p_Sx_Syy<= $signed({1'b0, acc_sx_r}) * $signed({1'b0, acc_syy_r});
                        p_Sy_Sxy<= $signed({1'b0, acc_sy_r}) * $signed({1'b0, acc_sxy_r});
                    end
                    fe_fsm <= 5'd11;
                end

                // Step 1B: Subtract products to obtain D, Na, Nb
                5'd11: begin
                    cur_D        <= p_n_Syy - p_Sy_Sy;
                    cur_Na_shift <= (p_n_Sxy - p_Sx_Sy) <<< 16;
                    cur_Nb_shift <= (p_Sx_Syy - p_Sy_Sxy) <<< 4;
                    fe_fsm       <= 5'd2;
                end


                // Step 2: Check conditions and start divider for a_q16
                5'd2: begin
                    if ((cur_n >= 8'd25) && (cur_D > 32'sd0)) begin
                        // Load serial divider for Na << 16
                        div_is_neg <= (cur_Na_shift < 64'sd0);
                        if (cur_Na_shift < 64'sd0) begin
                            // is_neg: abs_num + (D>>1) + D - 1
                            div_num <= (-cur_Na_shift) + {24'd0, cur_D[31:1]} + {24'd0, cur_D} - 56'd1;
                        end else begin
                            div_num <= cur_Na_shift[55:0] + {24'd0, cur_D[31:1]};
                        end
                        div_den  <= cur_D;
                        div_rem  <= 56'd0;
                        div_quot <= 32'd0;
                        div_cnt  <= 6'd0;
                        fe_fsm   <= 5'd3;
                    end else begin
                        // Ineligible for fit
                        if (side_sel == 1'b0) raw_valid_l <= 1'b0;
                        else                  raw_valid_r <= 1'b0;
                        fe_fsm <= 5'd7; // Skip to EMA update
                    end
                end

                // Step 3: Run serial divider for a_q16 (56 cycles)
                5'd3: begin
                    div_rem  <= next_rem;
                    div_num  <= {div_num[54:0], 1'b0};
                    div_quot <= {div_quot[30:0], div_sub_ok};
                    div_cnt  <= div_cnt + 6'd1;
                    if (div_cnt == 6'd55) begin
                        fe_fsm <= 5'd4;
                    end
                end

                // Step 4: Save a_q16 and start divider for b_q4
                5'd4: begin
                    if (side_sel == 1'b0)
                        raw_a_l <= div_is_neg ? (-$signed(div_quot)) : $signed(div_quot);
                    else
                        raw_a_r <= div_is_neg ? (-$signed(div_quot)) : $signed(div_quot);

                    // Setup b_q4
                    div_is_neg <= (cur_Nb_shift < 64'sd0);
                    if (cur_Nb_shift < 64'sd0) begin
                        div_num <= (-cur_Nb_shift) + {24'd0, cur_D[31:1]} + {24'd0, cur_D} - 56'd1;
                    end else begin
                        div_num <= cur_Nb_shift[55:0] + {24'd0, cur_D[31:1]};
                    end
                    div_den  <= cur_D;
                    div_rem  <= 56'd0;
                    div_quot <= 32'd0;
                    div_cnt  <= 6'd0;
                    fe_fsm   <= 5'd5;
                end

                // Step 5: Run serial divider for b_q4 (56 cycles)
                5'd5: begin
                    div_rem  <= next_rem;
                    div_num  <= {div_num[54:0], 1'b0};
                    div_quot <= {div_quot[30:0], div_sub_ok};
                    div_cnt  <= div_cnt + 6'd1;
                    if (div_cnt == 6'd55) begin
                        fe_fsm <= 5'd13;
                    end
                end

                // Step 5B: Register multiplier operands (timing closure)
                5'd13: begin
                    cur_a_op <= (side_sel == 1'b0) ? raw_a_l : raw_a_r;
                    cur_b_op <= div_is_neg ? (-$signed(div_quot)) : $signed(div_quot);
                    if (side_sel == 1'b0) raw_b_l <= div_is_neg ? (-$signed(div_quot)) : $signed(div_quot);
                    else                  raw_b_r <= div_is_neg ? (-$signed(div_quot)) : $signed(div_quot);
                    fe_fsm   <= 5'd6;
                end

                // Step 6: Pipeline DSP multipliers for RMS and geometry (split wide multiply)
                5'd6: begin
                    part_a_low    <= cur_a_op * $signed({1'b0, cur_Sxy[15:0]});
                    part_a_high   <= cur_a_op * $signed(cur_Sxy[31:16]);
                    term_b_reg    <= cur_b_op * cur_Sx;
                    term_xbot_reg <= cur_a_op * 32'sd240;
                    fe_fsm        <= 5'd17;
                end

                // Step 6A: Accumulate partial products
                5'd17: begin
                    term_a_reg    <= $signed({{15{part_a_low[48]}}, part_a_low}) + $signed({part_a_high, 16'd0});
                    fe_fsm        <= 5'd10;
                end

                // Step 6B: Calculate SSE and x_bot projections
                5'd10: begin
                    if (cur_Sxx - (term_a_reg >>> 16) - (term_b_reg >>> 4) < 64'sd0)
                        sse_reg <= 64'sd0;
                    else
                        sse_reg <= cur_Sxx - (term_a_reg >>> 16) - (term_b_reg >>> 4);
                    x_bot_raw_reg <= ((term_xbot_reg + 32'sd32768) >>> 16) + ((cur_b_op + 32'sd8) >>> 4);
                    x_top_raw_reg <= (cur_b_op + 32'sd8) >>> 4;
                    fe_fsm        <= 5'd14;
                end

                // Step 6C: Check slope, range and RMS
                5'd14: begin
                    slope_ok_reg <= (side_sel == 1'b0) ? (cur_a_op < 32'sd0) : (cur_a_op > 32'sd0);
                    range_ok_reg <= (x_bot_raw_reg >= 32'sd0) && (x_bot_raw_reg < 32'sd960) &&
                                    (x_top_raw_reg >= 32'sd0) && (x_top_raw_reg < 32'sd960);
                    rms_ok_reg   <= (sse_reg <= $signed({48'd0, cur_n, 8'd0}));
                    fe_fsm       <= 5'd15;
                end

                // Step 6D: Register valid and classification flags
                5'd15: begin
                    cur_valid_fit_reg <= slope_ok_reg && range_ok_reg && rms_ok_reg;
                    if (side_sel == 1'b0) raw_valid_l <= slope_ok_reg && range_ok_reg && rms_ok_reg;
                    else                  raw_valid_r <= slope_ok_reg && range_ok_reg && rms_ok_reg;

                    solid_flag_reg <= (side_sel == 1'b0 ? max_consec_l : max_consec_r) >= solid_rows_eff;
                    dbl_flag_reg   <= (side_sel == 1'b0 ? double_cnt_l : double_cnt_r) >= dbl_rows_eff;

                    cur_f_type_reg <= !(slope_ok_reg && range_ok_reg && rms_ok_reg) ? 2'd0 :
                                      ((side_sel == 1'b0 ? double_cnt_l : double_cnt_r) >= dbl_rows_eff) ? 2'd3 :
                                      ((side_sel == 1'b0 ? max_consec_l : max_consec_r) >= solid_rows_eff) ? 2'd2 : 2'd1;
                    fe_fsm         <= 5'd7;
                end

                // Step 7: Frame type, EMA update & History shift
                5'd7: begin
                    if (side_sel == 1'b0) begin
                        frame_type_l <= cur_f_type_reg;
                        hist_types_l <= {hist_types_l[45:0], cur_f_type_reg};
                        if (cur_valid_fit_reg) begin
                            lost_cnt_l <= 4'd0;
                            if (!track_valid_l) begin
                                ema_a_l <= raw_a_l;
                                ema_b_l <= raw_b_l;
                            end else begin
                                ema_a_l <= ema_a_l + ((raw_a_l - ema_a_l) >>> 1);
                                ema_b_l <= ema_b_l + ((raw_b_l - ema_b_l) >>> 1);
                            end
                            track_valid_l <= 1'b1;
                        end else begin
                            if (lost_cnt_l >= 4'd11) begin
                                track_valid_l <= 1'b1;
                                ema_a_l       <= INIT_A_LEFT;
                                ema_b_l       <= INIT_B_LEFT;
                                lost_cnt_l    <= 4'd0;
                            end else begin
                                lost_cnt_l    <= lost_cnt_l + 4'd1;
                            end
                        end
                    end else begin
                        frame_type_r <= cur_f_type_reg;
                        hist_types_r <= {hist_types_r[45:0], cur_f_type_reg};
                        if (cur_valid_fit_reg) begin
                            lost_cnt_r <= 4'd0;
                            if (!track_valid_r) begin
                                ema_a_r <= raw_a_r;
                                ema_b_r <= raw_b_r;
                            end else begin
                                ema_a_r <= ema_a_r + ((raw_a_r - ema_a_r) >>> 1);
                                ema_b_r <= ema_b_r + ((raw_b_r - ema_b_r) >>> 1);
                            end
                            track_valid_r <= 1'b1;
                        end else begin
                            if (lost_cnt_r >= 4'd11) begin
                                track_valid_r <= 1'b1;
                                ema_a_r       <= INIT_A_RIGHT;
                                ema_b_r       <= INIT_B_RIGHT;
                                lost_cnt_r    <= 4'd0;
                            end else begin
                                lost_cnt_r    <= lost_cnt_r + 4'd1;
                            end
                        end
                    end

                    if (side_sel == 1'b0) begin
                        side_sel <= 1'b1; // Proceed to Right side
                        fe_fsm   <= 5'd1;
                    end else begin
                        fe_fsm   <= 5'd8; // Both done, update outputs
                    end
                end

                // Step 8A: Calculate x_bot projections (timing closure pipeline)
                5'd8: begin
                    x_bot_l_reg <= ((ema_a_l * 32'sd240 + 32'sd32768) >>> 16) + ((ema_b_l + 32'sd8) >>> 4);
                    x_bot_r_reg <= ((ema_a_r * 32'sd240 + 32'sd32768) >>> 16) + ((ema_b_r + 32'sd8) >>> 4);
                    fe_fsm      <= 5'd12;
                end

                // Step 8B: Calculate departure and majority voting
                5'd12: begin
                    dep_l_reg   <= track_valid_l && (($signed({22'd0, ego_eff}) - x_bot_l_reg) < $signed({24'd0, dep_margin}));
                    dep_r_reg   <= track_valid_r && ((x_bot_r_reg - $signed({22'd0, ego_eff})) < $signed({24'd0, dep_margin}));
                    vote_l_reg  <= vote_24(hist_types_l);
                    vote_r_reg  <= vote_24(hist_types_r);
                    fe_fsm      <= 5'd16;
                end

                // Step 8C: Update final outputs, frame pulse
                5'd16: begin
                    out_l_valid         <= track_valid_l && (vote_l_reg != 2'd0);
                    out_l_solid         <= (vote_l_reg == 2'd2) || (vote_l_reg == 2'd3);
                    out_l_double        <= (vote_l_reg == 2'd3);
                    out_l_a_q16         <= ema_a_l;
                    out_l_b_q4          <= ema_b_l;
                    out_l_x_at_ytop_q16 <= (ema_b_l << 12) + 32'sd32768;
                    out_l_dx_q16        <= ema_a_l;
                    out_l_x_bot         <= track_valid_l ? x_bot_l_reg[15:0] : 16'hFFFF;
                    out_l_n             <= acc_n_l;

                    out_r_valid         <= track_valid_r && (vote_r_reg != 2'd0);
                    out_r_solid         <= (vote_r_reg == 2'd2) || (vote_r_reg == 2'd3);
                    out_r_double        <= (vote_r_reg == 2'd3);
                    out_r_a_q16         <= ema_a_r;
                    out_r_b_q4          <= ema_b_r;
                    out_r_x_at_ytop_q16 <= (ema_b_r << 12) + 32'sd32768;
                    out_r_dx_q16        <= ema_a_r;
                    out_r_x_bot         <= track_valid_r ? x_bot_r_reg[15:0] : 16'hFFFF;
                    out_r_n             <= acc_n_r;

                    out_depart          <= dep_l_reg | dep_r_reg;
                    out_frame_done      <= 1'b1;
                    out_frame_cnt       <= out_frame_cnt + 8'd1;
                    out_max_consec_l    <= max_consec_l;
                    out_max_consec_r    <= max_consec_r;
                    out_dbl_cnt_l       <= double_cnt_l;
                    out_dbl_cnt_r       <= double_cnt_r;
                    fe_fsm              <= 5'd9;
                end




                5'd9: begin
                    if (vs_rise) fe_fsm <= 5'd0;
                end

                default: fe_fsm <= 5'd0;
            endcase
        end
    end


endmodule

