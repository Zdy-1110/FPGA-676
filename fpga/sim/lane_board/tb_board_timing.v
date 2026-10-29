`timescale 1ns/1ps

module tb_board_timing;

    reg        clk;
    reg        rst_n;

    wire        out_l_valid;
    wire        out_l_solid;
    wire        out_l_double;
    wire [31:0] out_l_a_q16;
    wire [31:0] out_l_b_q4;
    wire [31:0] out_l_x_at_ytop_q16;
    wire [31:0] out_l_dx_q16;
    wire [15:0] out_l_x_bot;
    wire [7:0]  out_l_n;

    wire        out_r_valid;
    wire        out_r_solid;
    wire        out_r_double;
    wire [31:0] out_r_a_q16;
    wire [31:0] out_r_b_q4;
    wire [31:0] out_r_x_at_ytop_q16;
    wire [31:0] out_r_dx_q16;
    wire [15:0] out_r_x_bot;
    wire [7:0]  out_r_n;

    wire        out_depart;
    wire        out_frame_done;
    wire [7:0]  out_frame_cnt;

    // Timing parameters: 1080p60 (sync_vg.v & rt_disp_top.v:154-171)
    localparam [11:0] V_TOTAL   = 12'd1125;
    localparam [11:0] V_FP      = 12'd4;
    localparam [11:0] V_BP      = 12'd36;
    localparam [11:0] V_SYNC    = 12'd5;
    localparam [11:0] V_ACT     = 12'd1080;
    localparam [11:0] H_TOTAL   = 12'd2200;
    localparam [11:0] H_FP      = 12'd88;
    localparam [11:0] H_BP      = 12'd148;
    localparam [11:0] H_SYNC    = 12'd44;
    localparam [11:0] H_ACT     = 12'd1920;
    localparam [11:0] HV_OFFSET = 12'd0;

    // Window 0 parameters (rt_disp_top.v:363-366)
    localparam [11:0] WIN_W = 12'd960;
    localparam [11:0] WIN_H = 12'd540;

    // sync_vg raster generator
    reg [11:0] h_cnt;
    reg [11:0] v_cnt;
    reg        vg_hs, vg_vs, vg_de;
    reg [11:0] vg_x, vg_y;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            h_cnt <= 12'd0;
            v_cnt <= 12'd0;
            vg_hs <= 1'b0;
            vg_vs <= 1'b0;
            vg_de <= 1'b0;
            vg_x  <= 12'd0;
            vg_y  <= 12'd0;
        end else begin
            if (h_cnt < H_TOTAL - 12'd1)
                h_cnt <= h_cnt + 12'd1;
            else
                h_cnt <= 12'd0;

            if (h_cnt == H_TOTAL - 12'd1) begin
                if (v_cnt == V_TOTAL - 12'd1)
                    v_cnt <= 12'd0;
                else
                    v_cnt <= v_cnt + 12'd1;
            end

            vg_hs <= (h_cnt < H_SYNC);

            if ((v_cnt == 0) && (h_cnt == HV_OFFSET))
                vg_vs <= 1'b1;
            else if ((v_cnt == V_SYNC) && (h_cnt == HV_OFFSET))
                vg_vs <= 1'b0;

            vg_de <= (((v_cnt >= V_SYNC + V_BP) && (v_cnt <= V_TOTAL - V_FP - 12'd1)) &&
                      ((h_cnt >= H_SYNC + H_BP) && (h_cnt <= H_TOTAL - H_FP - 12'd1)));

            if (h_cnt > (H_SYNC + H_BP - 12'd1))
                vg_x <= h_cnt - (H_SYNC + H_BP);
            else
                vg_x <= 12'd0;

            if (v_cnt > (V_SYNC + V_BP - 12'd1))
                vg_y <= v_cnt - (V_SYNC + V_BP);
            else
                vg_y <= 12'd0;
        end
    end

    // Window 0 active flag
    wire in_win = (vg_x < WIN_W) && (vg_y < WIN_H);

    // Pixel storage for current frame (960x540 RGB565)
    reg [7:0] raw_bytes [0:960*540*2-1];

    // Combinational fetch of RGB565 and expand to RGB888 (same unpack as tb_board.v)
    wire [19:0] pix_idx = (vg_y * 12'd960 + vg_x) * 2;
    wire [15:0] rgb565_raw = {raw_bytes[pix_idx + 1], raw_bytes[pix_idx]};
    wire [7:0] r_raw = {rgb565_raw[15:11], 3'b000};
    wire [7:0] g_raw = {rgb565_raw[10:5],  2'b00};
    wire [7:0] b_raw = {rgb565_raw[4:0],   3'b000};

    // 5-stage pipeline reproducing u_qwin0 (rt_disp_win_reader_rgb.v:288-334)
    reg [4:0] de_sr, hs_sr, vs_sr, wi_sr;
    reg [7:0] r_pipe [0:4];
    reg [7:0] g_pipe [0:4];
    reg [7:0] b_pipe [0:4];
    integer pi;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_sr <= 5'd0;
            hs_sr <= 5'd0;
            vs_sr <= 5'd0;
            wi_sr <= 5'd0;
            for (pi = 0; pi < 5; pi = pi + 1) begin
                r_pipe[pi] <= 8'd0;
                g_pipe[pi] <= 8'd0;
                b_pipe[pi] <= 8'd0;
            end
        end else begin
            de_sr <= {de_sr[3:0], vg_de};
            hs_sr <= {hs_sr[3:0], vg_hs};
            vs_sr <= {vs_sr[3:0], vg_vs};
            wi_sr <= {wi_sr[3:0], in_win};

            if (vg_de && in_win) begin
                r_pipe[0] <= r_raw;
                g_pipe[0] <= g_raw;
                b_pipe[0] <= b_raw;
            end else begin
                r_pipe[0] <= 8'd0;
                g_pipe[0] <= 8'd0;
                b_pipe[0] <= 8'd0;
            end
            for (pi = 1; pi < 5; pi = pi + 1) begin
                r_pipe[pi] <= r_pipe[pi-1];
                g_pipe[pi] <= g_pipe[pi-1];
                b_pipe[pi] <= b_pipe[pi-1];
            end
        end
    end

    wire win_de = de_sr[4] && wi_sr[4];
    wire win_hs = hs_sr[4];
    wire win_vs = vs_sr[4];
    wire [7:0] win_r = win_de ? r_pipe[4] : 8'd0;
    wire [7:0] win_g = win_de ? g_pipe[4] : 8'd0;
    wire [7:0] win_b = win_de ? b_pipe[4] : 8'd0;

    // Instantiate UUT (rt_lane_det_gl1.v)
    rt_lane_det uut (
        .pix_clk           (clk),
        .rst_n             (rst_n),
        .de                (win_de),
        .vs                (win_vs),
        .hs                (win_hs),
        .r                 (win_r),
        .g                 (win_g),
        .b                 (win_b),
        .cfg_det_en        (1'b1),
        .cfg_xc            (10'd480),
        .cfg_ego_x         (10'd480),
        .cfg_y_top         (10'd260),
        .cfg_y_bot         (10'd500),
        .cfg_white_delta   (8'd18),
        .cfg_white_g_min   (8'd120),
        .cfg_yellow_delta  (8'd14),
        .cfg_depart_margin (8'd60),
        .out_l_valid       (out_l_valid),
        .out_l_solid       (out_l_solid),
        .out_l_double      (out_l_double),
        .out_l_a_q16       (out_l_a_q16),
        .out_l_b_q4        (out_l_b_q4),
        .out_l_x_at_ytop_q16(out_l_x_at_ytop_q16),
        .out_l_dx_q16      (out_l_dx_q16),
        .out_l_x_bot       (out_l_x_bot),
        .out_l_n           (out_l_n),
        .out_r_valid       (out_r_valid),
        .out_r_solid       (out_r_solid),
        .out_r_double      (out_r_double),
        .out_r_a_q16       (out_r_a_q16),
        .out_r_b_q4        (out_r_b_q4),
        .out_r_x_at_ytop_q16(out_r_x_at_ytop_q16),
        .out_r_dx_q16      (out_r_dx_q16),
        .out_r_x_bot       (out_r_x_bot),
        .out_r_n           (out_r_n),
        .out_depart        (out_depart),
        .out_frame_done    (out_frame_done),
        .out_frame_cnt     (out_frame_cnt)
    );

    // 148.5 MHz pixel clock
    always #3.367 clk = ~clk;

    string seg_name;
    integer total_frames = 4;
    integer f_idx;

    // Storage for frames_ref (60 frames x 38 DWORDs)
    reg [31:0] frames_ref_mem [0:60*38-1];

    // Storage for rows_ref (14460 rows x 6 WORDs)
    reg [15:0] rows_ref_mem [0:14460*6-1];

    integer row_mismatch_cnt = 0;
    integer frame_field_mismatch_cnt = 0;
    integer row_checked_cnt = 0;
    integer ret, bi;
    integer fd_bin;
    string bin_path, frames_ref_path, rows_ref_path;
    integer cur_row_ptr;

    // Row-by-row checker (identical comparison to tb_board.v)
    always @(posedge clk) begin
        if (uut.in_roi && (uut.lb_fsm == 3'd2)) begin
            row_checked_cnt = row_checked_cnt + 1;
            cur_row_ptr = (f_idx * 241 + (uut.y_pos - 260)) * 6;
            if (cur_row_ptr < 14460 * 6) begin
                integer rtl_lx, rtl_lh, rtl_ld;
                integer rtl_rx, rtl_rh, rtl_rd;
                integer exp_lx, exp_lh, exp_ld;
                integer exp_rx, exp_rh, exp_rd;

                rtl_lh = uut.l_found;
                rtl_lx = rtl_lh ? uut.best_x_l : 16'hFFFF;
                rtl_ld = uut.dbl_l_reg;
                rtl_rh = uut.r_found;
                rtl_rx = rtl_rh ? uut.best_x_r : 16'hFFFF;
                rtl_rd = uut.dbl_r_reg;

                exp_lx = rows_ref_mem[cur_row_ptr + 0];
                exp_lh = rows_ref_mem[cur_row_ptr + 1];
                exp_ld = rows_ref_mem[cur_row_ptr + 2];
                exp_rx = rows_ref_mem[cur_row_ptr + 3];
                exp_rh = rows_ref_mem[cur_row_ptr + 4];
                exp_rd = rows_ref_mem[cur_row_ptr + 5];

                if ((rtl_lh != exp_lh) ||
                    (rtl_lh && (rtl_lx != exp_lx)) ||
                    (rtl_ld != exp_ld) ||
                    (rtl_rh != exp_rh) ||
                    (rtl_rh && (rtl_rx != exp_rx)) ||
                    (rtl_rd != exp_rd)) begin
                    row_mismatch_cnt = row_mismatch_cnt + 1;
                    if (row_mismatch_cnt <= 20) begin
                        $display("MISMATCH [Row #%0d] frame=%0d y=%0d: RTL L=(%0d,%0d,%0d) R=(%0d,%0d,%0d) | EXP L=(%0d,%0d,%0d) R=(%0d,%0d,%0d)",
                            row_mismatch_cnt, f_idx, uut.y_pos, rtl_lx, rtl_lh, rtl_ld, rtl_rx, rtl_rh, rtl_rd,
                            exp_lx, exp_lh, exp_ld, exp_rx, exp_rh, exp_rd);
                    end
                    if (row_mismatch_cnt == 1) begin
                        $display("--- FIRST MISMATCH DIAGNOSTICS ---");
                        $display("  frame=%0d y_pos=%0d in_roi_reg=%0b lb_fsm=%0d", f_idx, uut.y_pos, uut.in_roi_reg, uut.lb_fsm);
                        $display("  run_cnt=%0d", uut.run_cnt);
                        for (bi = 0; bi < uut.run_cnt && bi < 16; bi = bi + 1) begin
                            $display("    run[%0d] center=%0d", bi, uut.run_buf[bi]);
                        end
                        $display("  L: best_x_l=%0d l_found=%0b track_valid_l=%0b x_pred_l=%0d", uut.best_x_l, uut.l_found, uut.track_valid_l, uut.x_pred_l);
                        $display("  R: best_x_r=%0d r_found=%0b track_valid_r=%0b x_pred_r=%0d", uut.best_x_r, uut.r_found, uut.track_valid_r, uut.x_pred_r);
                        $display("  cur_dy=%0d cur_Wy=%0d cur_w_max=%0d cur_dbl_thr=%0d", uut.cur_dy, uut.cur_Wy, uut.cur_w_max, uut.cur_dbl_thr);
                        $display("  EMA L: ema_a_l=%0d ema_b_l=%0d", uut.ema_a_l, uut.ema_b_l);
                        $display("  EMA R: ema_a_r=%0d ema_b_r=%0d", uut.ema_a_r, uut.ema_b_r);
                        $display("----------------------------------");
                    end
                end
            end
        end
    end

    // Frame field comparison task (identical to tb_board.v)
    task check_frame_fields;
        input integer f;
        integer f_ptr;
        integer rtl_f_type_l, rtl_v_type_l;
        integer rtl_f_type_r, rtl_v_type_r;
        begin
            f_ptr = f * 38;

            rtl_f_type_l = uut.frame_type_l;
            rtl_v_type_l = uut.out_l_double ? 3 : uut.out_l_solid ? 2 : uut.out_l_valid ? 1 : 0;
            rtl_f_type_r = uut.frame_type_r;
            rtl_v_type_r = uut.out_r_double ? 3 : uut.out_r_solid ? 2 : uut.out_r_valid ? 1 : 0;

            // Left side 19 fields
            if (uut.acc_n_l     != frames_ref_mem[f_ptr + 0])  begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("MISMATCH [F%0d acc_n_l]: RTL=%0d EXP=%0d", f, uut.acc_n_l, frames_ref_mem[f_ptr+0]); end
            if (uut.acc_sy_l    != frames_ref_mem[f_ptr + 1])  begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("MISMATCH [F%0d acc_sy_l]: RTL=%0d EXP=%0d", f, uut.acc_sy_l, frames_ref_mem[f_ptr+1]); end
            if (uut.acc_syy_l   != frames_ref_mem[f_ptr + 2])  begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("MISMATCH [F%0d acc_syy_l]: RTL=%0d EXP=%0d", f, uut.acc_syy_l, frames_ref_mem[f_ptr+2]); end
            if (uut.acc_sx_l    != frames_ref_mem[f_ptr + 3])  begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("MISMATCH [F%0d acc_sx_l]: RTL=%0d EXP=%0d", f, uut.acc_sx_l, frames_ref_mem[f_ptr+3]); end
            if (uut.acc_sxy_l   != frames_ref_mem[f_ptr + 4])  begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("MISMATCH [F%0d acc_sxy_l]: RTL=%0d EXP=%0d", f, uut.acc_sxy_l, frames_ref_mem[f_ptr+4]); end
            if (uut.acc_sxx_l   != frames_ref_mem[f_ptr + 5])  begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("MISMATCH [F%0d acc_sxx_l]: RTL=%0d EXP=%0d", f, uut.acc_sxx_l, frames_ref_mem[f_ptr+5]); end
            if (uut.raw_valid_l != frames_ref_mem[f_ptr + 6])  begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("MISMATCH [F%0d raw_valid_l]: RTL=%0d EXP=%0d", f, uut.raw_valid_l, frames_ref_mem[f_ptr+6]); end
            if (uut.raw_a_l     != frames_ref_mem[f_ptr + 7])  begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("MISMATCH [F%0d raw_a_l]: RTL=%0d EXP=%0d", f, uut.raw_a_l, frames_ref_mem[f_ptr+7]); end
            if (uut.raw_b_l     != frames_ref_mem[f_ptr + 8])  begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("MISMATCH [F%0d raw_b_l]: RTL=%0d EXP=%0d", f, uut.raw_b_l, frames_ref_mem[f_ptr+8]); end
            if (uut.ema_a_l     != frames_ref_mem[f_ptr + 9])  begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("MISMATCH [F%0d ema_a_l]: RTL=%0d EXP=%0d", f, uut.ema_a_l, frames_ref_mem[f_ptr+9]); end
            if (uut.ema_b_l     != frames_ref_mem[f_ptr + 10]) begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("MISMATCH [F%0d ema_b_l]: RTL=%0d EXP=%0d", f, uut.ema_b_l, frames_ref_mem[f_ptr+10]); end
            if (uut.track_valid_l != frames_ref_mem[f_ptr + 11]) begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("MISMATCH [F%0d track_valid_l]: RTL=%0d EXP=%0d", f, uut.track_valid_l, frames_ref_mem[f_ptr+11]); end
            if (uut.lost_cnt_l  != frames_ref_mem[f_ptr + 12]) begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("MISMATCH [F%0d lost_cnt_l]: RTL=%0d EXP=%0d", f, uut.lost_cnt_l, frames_ref_mem[f_ptr+12]); end
            if (uut.max_consec_l!= frames_ref_mem[f_ptr + 13]) begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("MISMATCH [F%0d max_consec_l]: RTL=%0d EXP=%0d", f, uut.max_consec_l, frames_ref_mem[f_ptr+13]); end
            if (uut.double_cnt_l!= frames_ref_mem[f_ptr + 14]) begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("MISMATCH [F%0d double_cnt_l]: RTL=%0d EXP=%0d", f, uut.double_cnt_l, frames_ref_mem[f_ptr+14]); end
            if (rtl_f_type_l    != frames_ref_mem[f_ptr + 15]) begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("MISMATCH [F%0d rtl_f_type_l]: RTL=%0d EXP=%0d", f, rtl_f_type_l, frames_ref_mem[f_ptr+15]); end
            if (rtl_v_type_l    != frames_ref_mem[f_ptr + 16]) begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("MISMATCH [F%0d rtl_v_type_l]: RTL=%0d EXP=%0d", f, rtl_v_type_l, frames_ref_mem[f_ptr+16]); end
            if (uut.out_l_x_bot != frames_ref_mem[f_ptr + 17][15:0]) begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("MISMATCH [F%0d out_l_x_bot]: RTL=%0d EXP=%0d", f, uut.out_l_x_bot, frames_ref_mem[f_ptr+17][15:0]); end

            // Right side 19 fields
            if (uut.acc_n_r     != frames_ref_mem[f_ptr + 19]) begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("MISMATCH [F%0d acc_n_r]: RTL=%0d EXP=%0d", f, uut.acc_n_r, frames_ref_mem[f_ptr+19]); end
            if (uut.acc_sy_r    != frames_ref_mem[f_ptr + 20]) begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("MISMATCH [F%0d acc_sy_r]: RTL=%0d EXP=%0d", f, uut.acc_sy_r, frames_ref_mem[f_ptr+20]); end
            if (uut.acc_syy_r   != frames_ref_mem[f_ptr + 21]) begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("MISMATCH [F%0d acc_syy_r]: RTL=%0d EXP=%0d", f, uut.acc_syy_r, frames_ref_mem[f_ptr+21]); end
            if (uut.acc_sx_r    != frames_ref_mem[f_ptr + 22]) begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("MISMATCH [F%0d acc_sx_r]: RTL=%0d EXP=%0d", f, uut.acc_sx_r, frames_ref_mem[f_ptr+22]); end
            if (uut.acc_sxy_r   != frames_ref_mem[f_ptr + 23]) begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("MISMATCH [F%0d acc_sxy_r]: RTL=%0d EXP=%0d", f, uut.acc_sxy_r, frames_ref_mem[f_ptr+23]); end
            if (uut.acc_sxx_r   != frames_ref_mem[f_ptr + 24]) begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("MISMATCH [F%0d acc_sxx_r]: RTL=%0d EXP=%0d", f, uut.acc_sxx_r, frames_ref_mem[f_ptr+24]); end
            if (uut.raw_valid_r != frames_ref_mem[f_ptr + 25]) begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("MISMATCH [F%0d raw_valid_r]: RTL=%0d EXP=%0d", f, uut.raw_valid_r, frames_ref_mem[f_ptr+25]); end
            if (uut.raw_a_r     != frames_ref_mem[f_ptr + 26]) begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("MISMATCH [F%0d raw_a_r]: RTL=%0d EXP=%0d", f, uut.raw_a_r, frames_ref_mem[f_ptr+26]); end
            if (uut.raw_b_r     != frames_ref_mem[f_ptr + 27]) begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("MISMATCH [F%0d raw_b_r]: RTL=%0d EXP=%0d", f, uut.raw_b_r, frames_ref_mem[f_ptr+27]); end
            if (uut.ema_a_r     != frames_ref_mem[f_ptr + 28]) begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("MISMATCH [F%0d ema_a_r]: RTL=%0d EXP=%0d", f, uut.ema_a_r, frames_ref_mem[f_ptr+28]); end
            if (uut.ema_b_r     != frames_ref_mem[f_ptr + 29]) begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("MISMATCH [F%0d ema_b_r]: RTL=%0d EXP=%0d", f, uut.ema_b_r, frames_ref_mem[f_ptr+29]); end
            if (uut.track_valid_r != frames_ref_mem[f_ptr + 30]) begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("MISMATCH [F%0d track_valid_r]: RTL=%0d EXP=%0d", f, uut.track_valid_r, frames_ref_mem[f_ptr+30]); end
            if (uut.lost_cnt_r  != frames_ref_mem[f_ptr + 31]) begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("MISMATCH [F%0d lost_cnt_r]: RTL=%0d EXP=%0d", f, uut.lost_cnt_r, frames_ref_mem[f_ptr+31]); end
            if (uut.max_consec_r!= frames_ref_mem[f_ptr + 32]) begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("MISMATCH [F%0d max_consec_r]: RTL=%0d EXP=%0d", f, uut.max_consec_r, frames_ref_mem[f_ptr+32]); end
            if (uut.double_cnt_r!= frames_ref_mem[f_ptr + 33]) begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("MISMATCH [F%0d double_cnt_r]: RTL=%0d EXP=%0d", f, uut.double_cnt_r, frames_ref_mem[f_ptr+33]); end
            if (rtl_f_type_r    != frames_ref_mem[f_ptr + 34]) begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("MISMATCH [F%0d rtl_f_type_r]: RTL=%0d EXP=%0d", f, rtl_f_type_r, frames_ref_mem[f_ptr+34]); end
            if (rtl_v_type_r    != frames_ref_mem[f_ptr + 35]) begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("MISMATCH [F%0d rtl_v_type_r]: RTL=%0d EXP=%0d", f, rtl_v_type_r, frames_ref_mem[f_ptr+35]); end
            if (uut.out_r_x_bot != frames_ref_mem[f_ptr + 36][15:0]) begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("MISMATCH [F%0d out_r_x_bot]: RTL=%0d EXP=%0d", f, uut.out_r_x_bot, frames_ref_mem[f_ptr+36][15:0]); end
        end
    endtask

    // Simulation stimulus control
    initial begin
        clk   = 0;
        rst_n = 0;
        f_idx = 0;

        if (!$value$plusargs("SEG=%s", seg_name)) begin
            seg_name = "seg_board";
        end
        if (!$value$plusargs("FRAMES=%0d", total_frames)) begin
            total_frames = 4;
        end

        bin_path        = {"E:/Project/nesai2026/log/lane_fpga/vectors/", seg_name, "/frames.bin"};
        frames_ref_path = {"D:/pango_build/4_15_PCIE_DMA/sim/lane/", seg_name, "/frames_ref.hex"};
        rows_ref_path   = {"D:/pango_build/4_15_PCIE_DMA/sim/lane/", seg_name, "/rows_ref.hex"};

        $readmemh(frames_ref_path, frames_ref_mem);
        $readmemh(rows_ref_path, rows_ref_mem);

        fd_bin = $fopen(bin_path, "rb");
        if (fd_bin == 0) begin
            $display("ERROR: Cannot open %s", bin_path);
            $finish;
        end

        // Read initial frame 0
        ret = $fread(raw_bytes, fd_bin);
        if (ret != 960*540*2) begin
            $display("ERROR: Premature EOF reading frame 0 from %s", bin_path);
            $finish;
        end

        #50;
        @(negedge clk);
        rst_n = 1;
        $display("[TB] Reset released, starting board timing simulation: SEG=%s total_frames=%0d", seg_name, total_frames);
    end

    // Frame stepper & check trigger
    // After line 539 of active window finishes (v_cnt reaches 41+540 = 581), check frame at v_cnt == 582
    always @(posedge clk) begin
        if (rst_n) begin
            if ((v_cnt == 12'd582) && (h_cnt == 12'd0)) begin
                $display("[TB] Frame %0d active scan finished. Checking frame fields...", f_idx);
                check_frame_fields(f_idx);

                if (f_idx + 1 < total_frames) begin
                    f_idx = f_idx + 1;
                    ret = $fread(raw_bytes, fd_bin);
                    if (ret != 960*540*2) begin
                        $display("ERROR: Premature EOF reading frame %0d from %s", f_idx, bin_path);
                        $finish;
                    end
                end else begin
                    $fclose(fd_bin);
                    $display("SEG %s: row_mismatch=%0d frame_field_mismatch=%0d", seg_name, row_mismatch_cnt, frame_field_mismatch_cnt);
                    $display("[TB] rows_checked=%0d (expected %0d)", row_checked_cnt, total_frames * 241);
                    $finish;
                end
            end
        end
    end

endmodule
