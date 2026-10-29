`timescale 1ns/1ps

module tb_gl_board;

    reg        clk;
    reg        rst_n;
    reg        grs_n;
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

    // Pango Global Reset - must be named GRS_INST
    GTP_GRS GRS_INST (.GRS_N(grs_n));

    // Instantiate gate-level netlist UUT (r4)
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
        .out_frame_cnt     (out_frame_cnt)
    );

    always #3.367 clk = ~clk;

    string seg_name;
    integer total_frames = 2;

    reg [31:0] frames_ref_mem [0:60*38-1];
    reg [15:0] rows_ref_mem   [0:14460*6-1];

    integer row_mismatch_cnt = 0;
    integer frame_field_mismatch_cnt = 0;
    integer f_idx, row, col, ret, bi;
    reg [7:0] raw_bytes [0:960*540*2-1];
    reg [15:0] rgb565_val;
    integer fd_bin;
    string bin_path, frames_ref_path, rows_ref_path;
    integer cur_row_ptr;
    integer row_print_count = 0;

    // Row-by-row checker
    always @(posedge clk) begin
        if (rst_n && uut.in_roi && uut.lb_fsm_reg[2]) begin
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
                        $display("MISMATCH [Row #%0d] frame=%0d y=%0d: NET L=(found=%0d,x=%0d,dbl=%0d) R=(found=%0d,x=%0d,dbl=%0d) | EXP L=(found=%0d,x=%0d,dbl=%0d) R=(found=%0d,x=%0d,dbl=%0d)",
                            row_mismatch_cnt, f_idx, uut.y_pos,
                            rtl_lh, rtl_lx, rtl_ld, rtl_rh, rtl_rx, rtl_rd,
                            exp_lh, exp_lx, exp_ld, exp_rh, exp_rx, exp_rd);
                    end
                    if (row_mismatch_cnt == 1) begin
                        $display("--- FIRST MISMATCH DIAGNOSTICS ---");
                        $display("  frame=%0d y_pos=%0d in_roi=%0b lb_fsm_reg[2]=%0b run_cnt=%0d", f_idx, uut.y_pos, uut.in_roi, uut.lb_fsm_reg[2], uut.run_cnt);
                        $display("  L: best_x_l=%0d l_found=%0b | R: best_x_r=%0d r_found=%0b", uut.best_x_l, uut.l_found, uut.best_x_r, uut.r_found);
                        $display("  cur_w_max=%0d dbl_l_reg=%0b dbl_r_reg=%0b", uut.cur_w_max, uut.dbl_l_reg, uut.dbl_r_reg);
                        $display("----------------------------------");
                    end
                end
            end
        end
    end

    // Check frame fields
    task check_frame_fields;
        input integer f;
        integer f_ptr;
        integer rtl_f_type_l, rtl_v_type_l;
        integer rtl_f_type_r, rtl_v_type_r;
        integer exp_l_out_valid, exp_r_out_valid;
        begin
            f_ptr = f * 38;

            rtl_f_type_l = 0;
            rtl_v_type_l = out_l_double ? 3 : out_l_solid ? 2 : out_l_valid ? 1 : 0;
            rtl_v_type_r = out_r_double ? 3 : out_r_solid ? 2 : out_r_valid ? 1 : 0;

            // 20261028: RTL out_*_valid is now gated by the vote (track_valid && vote!=0),
            // while frames_ref stores the model's track_valid. Compare against the gated value.
            exp_l_out_valid = (frames_ref_mem[f_ptr + 11] != 0) && (frames_ref_mem[f_ptr + 16] != 0);
            exp_r_out_valid = (frames_ref_mem[f_ptr + 30] != 0) && (frames_ref_mem[f_ptr + 35] != 0);

            $display("[FRAME %0d] out_l_n=%0d (exp %0d), out_r_n=%0d (exp %0d), out_l_valid=%0d (exp %0d), out_l_a_q16=%0d (exp %0d), out_l_b_q4=%0d (exp %0d)",
                f, out_l_n, frames_ref_mem[f_ptr+0], out_r_n, frames_ref_mem[f_ptr+19], out_l_valid, exp_l_out_valid,
                $signed(out_l_a_q16), $signed(frames_ref_mem[f_ptr+9]), $signed(out_l_b_q4), $signed(frames_ref_mem[f_ptr+10]));

            if (out_l_n         != frames_ref_mem[f_ptr + 0])  begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("  F%0d MISMATCH l_n: %0d vs %0d", f, out_l_n, frames_ref_mem[f_ptr+0]); end
            if (out_l_a_q16     != frames_ref_mem[f_ptr + 9])  begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("  F%0d MISMATCH l_a: %0d vs %0d", f, $signed(out_l_a_q16), $signed(frames_ref_mem[f_ptr+9])); end
            if (out_l_b_q4      != frames_ref_mem[f_ptr + 10]) begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("  F%0d MISMATCH l_b: %0d vs %0d", f, $signed(out_l_b_q4), $signed(frames_ref_mem[f_ptr+10])); end
            if (out_l_valid     != exp_l_out_valid) begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("  F%0d MISMATCH l_val: %0d vs %0d", f, out_l_valid, exp_l_out_valid); end
            if (rtl_v_type_l    != frames_ref_mem[f_ptr + 16]) begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("  F%0d MISMATCH l_vtype: %0d vs %0d", f, rtl_v_type_l, frames_ref_mem[f_ptr+16]); end
            if (out_l_x_bot     != frames_ref_mem[f_ptr + 17][15:0]) begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("  F%0d MISMATCH l_xbot: %0d vs %0d", f, out_l_x_bot, frames_ref_mem[f_ptr+17][15:0]); end

            if (out_r_n         != frames_ref_mem[f_ptr + 19]) begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("  F%0d MISMATCH r_n: %0d vs %0d", f, out_r_n, frames_ref_mem[f_ptr+19]); end
            if (out_r_a_q16     != frames_ref_mem[f_ptr + 28]) begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("  F%0d MISMATCH r_a: %0d vs %0d", f, $signed(out_r_a_q16), $signed(frames_ref_mem[f_ptr+28])); end
            if (out_r_b_q4      != frames_ref_mem[f_ptr + 29]) begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("  F%0d MISMATCH r_b: %0d vs %0d", f, $signed(out_r_b_q4), $signed(frames_ref_mem[f_ptr+29])); end
            if (out_r_valid     != exp_r_out_valid) begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("  F%0d MISMATCH r_val: %0d vs %0d", f, out_r_valid, exp_r_out_valid); end
            if (rtl_v_type_r    != frames_ref_mem[f_ptr + 35]) begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("  F%0d MISMATCH r_vtype: %0d vs %0d", f, rtl_v_type_r, frames_ref_mem[f_ptr+35]); end
            if (out_r_x_bot     != frames_ref_mem[f_ptr + 36][15:0]) begin frame_field_mismatch_cnt = frame_field_mismatch_cnt + 1; $display("  F%0d MISMATCH r_xbot: %0d vs %0d", f, out_r_x_bot, frames_ref_mem[f_ptr+36][15:0]); end
        end
    endtask

    initial begin
        clk = 0; rst_n = 0; grs_n = 0; de = 0; vs = 0; hs = 0; r = 0; g = 0; b = 0;

        if (!$value$plusargs("SEG=%s", seg_name)) begin
            seg_name = "seg_board";
        end

        if (!$value$plusargs("NFRAMES=%d", total_frames)) begin
            total_frames = 2;
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

        #100;
        grs_n = 1;
        #100;
        rst_n = 1;
        #100;

        $display("=== Starting Gate-Level Netlist Simulation for %s (%0d frames) ===", seg_name, total_frames);

        for (f_idx = 0; f_idx < total_frames; f_idx = f_idx + 1) begin
            ret = $fread(raw_bytes, fd_bin);
            if (ret != 960*540*2) begin
                $display("ERROR: Premature EOF at frame %0d", f_idx);
                $finish;
            end

            // Vertical blanking
            vs = 1'b1;
            repeat (20) @(posedge clk);
            vs = 1'b0;
            repeat (50) @(posedge clk);

            // Active frame: 540 lines
            bi = 0;
            for (row = 0; row < 540; row = row + 1) begin
                if (row >= 260 && row <= 500) begin
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
                end else begin
                    // Outside ROI: advance y_pos
                    bi = bi + 960 * 2;
                    de = 1'b1;
                    repeat (2) @(posedge clk);
                    de = 1'b0;
                    repeat (20) @(posedge clk);
                end
            end

            repeat (1000) @(posedge clk);
            check_frame_fields(f_idx);
        end

        $fclose(fd_bin);
        $display("==================================================");
        $display("SEG %s: row_mismatch=%0d frame_field_mismatch=%0d", seg_name, row_mismatch_cnt, frame_field_mismatch_cnt);
        $display("==================================================");
        $finish;

    end

endmodule
