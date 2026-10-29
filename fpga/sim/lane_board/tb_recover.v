`timescale 1ns/1ps

module tb_recover;

    reg        clk;
    reg        rst_n;
    reg        de;
    reg        vs;
    reg        hs;
    reg [7:0]  r, g, b;

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

    // Instantiate UUT
    rt_lane_det uut (
        .pix_clk           (clk),
        .rst_n             (rst_n),
        .de                (de),
        .vs                (vs),
        .hs                (hs),
        .r                 (r),
        .g                 (g),
        .b                 (b),
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
        .out_frame_cnt     (out_frame_cnt),
        .dbg_row           (10'd0),
        .dbg_x             (10'd0),
        .dbg_bus           ()
    );

    always #3.367 clk = ~clk;

    string seg_name = "seg_recover";
    integer total_frames = 40;

    reg [31:0] frames_ref_mem [0:60*38-1];
    reg [15:0] rows_ref_mem [0:14460*6-1];

    integer row_mismatch_cnt = 0;
    integer frame_field_mismatch_cnt = 0;
    integer first_err = 0;
    integer f_idx, row, col, ret, bi;
    integer cur_row_ptr;
    string frames_ref_path, rows_ref_path, bin_path;
    integer fd_bin;
    reg [7:0] raw_bytes [0:960*540*2-1];
    reg [15:0] rgb565_val;

    // Row-by-row checker
    always @(posedge clk) begin
        if (uut.in_roi && (uut.lb_fsm == 3'd2)) begin
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
                end
            end
        end
    end

    task check_field;
        input integer f;
        input string name;
        input [31:0] rtl_val;
        input [31:0] exp_val;
        begin
            if (rtl_val != exp_val) begin
                if (first_err < 10) begin
                    $display("MISMATCH [Frame %0d] %s: RTL=0x%08x (%0d), EXP=0x%08x (%0d)",
                             f, name, rtl_val, $signed(rtl_val), exp_val, $signed(exp_val));
                    first_err = first_err + 1;
                end
                frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1;
            end
        end
    endtask

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

            check_field(f, "left_n", uut.acc_n_l, frames_ref_mem[f_ptr + 0]);
            check_field(f, "left_sum_y", uut.acc_sy_l, frames_ref_mem[f_ptr + 1]);
            check_field(f, "left_sum_yy", uut.acc_syy_l, frames_ref_mem[f_ptr + 2]);
            check_field(f, "left_sum_x", uut.acc_sx_l, frames_ref_mem[f_ptr + 3]);
            check_field(f, "left_sum_xy", uut.acc_sxy_l, frames_ref_mem[f_ptr + 4]);
            check_field(f, "left_sum_xx", uut.acc_sxx_l, frames_ref_mem[f_ptr + 5]);
            check_field(f, "left_raw_valid", uut.raw_valid_l, frames_ref_mem[f_ptr + 6]);
            check_field(f, "left_raw_a_q16", uut.raw_a_l, frames_ref_mem[f_ptr + 7]);
            check_field(f, "left_raw_b_q4", uut.raw_b_l, frames_ref_mem[f_ptr + 8]);
            check_field(f, "left_ema_a_q16", uut.ema_a_l, frames_ref_mem[f_ptr + 9]);
            check_field(f, "left_ema_b_q4", uut.ema_b_l, frames_ref_mem[f_ptr + 10]);
            check_field(f, "left_track_valid", uut.track_valid_l, frames_ref_mem[f_ptr + 11]);
            check_field(f, "left_lost_cnt", uut.lost_cnt_l, frames_ref_mem[f_ptr + 12]);
            check_field(f, "left_max_consec", uut.max_consec_l, frames_ref_mem[f_ptr + 13]);
            check_field(f, "left_double_cnt", uut.double_cnt_l, frames_ref_mem[f_ptr + 14]);
            check_field(f, "left_frame_type", rtl_f_type_l, frames_ref_mem[f_ptr + 15]);
            check_field(f, "left_vote_type", rtl_v_type_l, frames_ref_mem[f_ptr + 16]);
            check_field(f, "left_out_x_bot", {16'd0, uut.out_l_x_bot}, {16'd0, frames_ref_mem[f_ptr + 17][15:0]});

            check_field(f, "right_n", uut.acc_n_r, frames_ref_mem[f_ptr + 19]);
            check_field(f, "right_sum_y", uut.acc_sy_r, frames_ref_mem[f_ptr + 20]);
            check_field(f, "right_sum_yy", uut.acc_syy_r, frames_ref_mem[f_ptr + 21]);
            check_field(f, "right_sum_x", uut.acc_sx_r, frames_ref_mem[f_ptr + 22]);
            check_field(f, "right_sum_xy", uut.acc_sxy_r, frames_ref_mem[f_ptr + 23]);
            check_field(f, "right_sum_xx", uut.acc_sxx_r, frames_ref_mem[f_ptr + 24]);
            check_field(f, "right_raw_valid", uut.raw_valid_r, frames_ref_mem[f_ptr + 25]);
            check_field(f, "right_raw_a_q16", uut.raw_a_r, frames_ref_mem[f_ptr + 26]);
            check_field(f, "right_raw_b_q4", uut.raw_b_r, frames_ref_mem[f_ptr + 27]);
            check_field(f, "right_ema_a_q16", uut.ema_a_r, frames_ref_mem[f_ptr + 28]);
            check_field(f, "right_ema_b_q4", uut.ema_b_r, frames_ref_mem[f_ptr + 29]);
            check_field(f, "right_track_valid", uut.track_valid_r, frames_ref_mem[f_ptr + 30]);
            check_field(f, "right_lost_cnt", uut.lost_cnt_r, frames_ref_mem[f_ptr + 31]);
            check_field(f, "right_max_consec", uut.max_consec_r, frames_ref_mem[f_ptr + 32]);
            check_field(f, "right_double_cnt", uut.double_cnt_r, frames_ref_mem[f_ptr + 33]);
            check_field(f, "right_frame_type", rtl_f_type_r, frames_ref_mem[f_ptr + 34]);
            check_field(f, "right_vote_type", rtl_v_type_r, frames_ref_mem[f_ptr + 35]);
            check_field(f, "right_out_x_bot", {16'd0, uut.out_r_x_bot}, {16'd0, frames_ref_mem[f_ptr + 36][15:0]});
        end
    endtask

    initial begin
        clk = 0;
        rst_n = 0;
        de = 0;
        vs = 0;
        hs = 0;
        r = 0;
        g = 0;
        b = 0;

        if (!$value$plusargs("SEG=%s", seg_name)) seg_name = "seg_recover";

        bin_path = {"E:/Project/nesai2026/log/lane_fpga/vectors/", seg_name, "/frames.bin"};
        frames_ref_path = {"D:/pango_build/4_15_PCIE_DMA/sim/lane/", seg_name, "/frames_ref.hex"};
        rows_ref_path = {"D:/pango_build/4_15_PCIE_DMA/sim/lane/", seg_name, "/rows_ref.hex"};

        $readmemh(frames_ref_path, frames_ref_mem);
        $readmemh(rows_ref_path, rows_ref_mem);

        fd_bin = $fopen(bin_path, "rb");
        if (fd_bin == 0) begin
            $display("ERROR: Cannot open %s", bin_path);
            $finish;
        end

        #50; rst_n = 1; #50;

        for (f_idx = 0; f_idx < total_frames; f_idx = f_idx + 1) begin
            ret = $fread(raw_bytes, fd_bin);
            if (ret != 960*540*2) begin
                $display("ERROR: Premature EOF at frame %0d", f_idx);
                $finish;
            end

            // Vertical blanking: vs pulse
            vs = 1'b1;
            repeat (20) @(posedge clk);
            vs = 1'b0;
            repeat (50) @(posedge clk);

            // Active frame: 540 lines
            bi = 0;
            for (row = 0; row < 540; row = row + 1) begin
                for (col = 0; col < 960; col = col + 1) begin
                    rgb565_val = {raw_bytes[bi+1], raw_bytes[bi]};
                    bi = bi + 2;
                    r = {rgb565_val[15:11], 3'b000};
                    g = {rgb565_val[10:5], 2'b00};
                    b = {rgb565_val[4:0], 3'b000};
                    de = 1'b1;
                    @(posedge clk);
                end
                de = 1'b0;
                repeat (280) @(posedge clk);
            end

            repeat (20) @(posedge clk);
            check_frame_fields(f_idx);
        end

        $fclose(fd_bin);

        $display("SEG %s: row_mismatch=%0d frame_field_mismatch=%0d", seg_name, row_mismatch_cnt, frame_field_mismatch_cnt);
        $finish;
    end

endmodule
