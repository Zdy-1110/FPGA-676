`timescale 1ns/1ps

module tb_rt_lane_det;

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
        .out_frame_cnt     (out_frame_cnt)
    );

    // 148.5 MHz clock
    always #3.367 clk = ~clk;

    // Golden frame references from frames.csv
    integer exp_n_l   [0:2];
    integer exp_a_l   [0:2];
    integer exp_b_l   [0:2];
    integer exp_val_l [0:2];
    integer exp_sol_l [0:2];

    integer exp_n_r   [0:2];
    integer exp_a_r   [0:2];
    integer exp_b_r   [0:2];
    integer exp_val_r [0:2];
    integer exp_sol_r [0:2];

    initial begin
        exp_n_l[0]   = 119;    exp_a_l[0]   = -64058; exp_b_l[0]   = 6412; exp_val_l[0] = 1; exp_sol_l[0] = 0;
        exp_n_r[0]   = 128;    exp_a_r[0]   = 58451;  exp_b_r[0]   = 8960; exp_val_r[0] = 1; exp_sol_r[0] = 0;

        exp_n_l[1]   = 136;    exp_a_l[1]   = -65041; exp_b_l[1]   = 6402; exp_val_l[1] = 1; exp_sol_l[1] = 0;
        exp_n_r[1]   = 122;    exp_a_r[1]   = 58241;  exp_b_r[1]   = 8965; exp_val_r[1] = 1; exp_sol_r[1] = 0;

        exp_n_l[2]   = 136;    exp_a_l[2]   = -66425; exp_b_l[2]   = 6398; exp_val_l[2] = 1; exp_sol_l[2] = 0;
        exp_n_r[2]   = 126;    exp_a_r[2]   = 59434;  exp_b_r[2]   = 8944; exp_val_r[2] = 1; exp_sol_r[2] = 0;
    end

    // Storage for rows.csv (60 frames * 241 lines = 14460)
    integer fd_rows, r_cnt, c_frm, c_y, c_lx, c_lh, c_ld, c_rx, c_rh, c_rd;
    integer exp_row_lx   [0:1000];
    integer exp_row_lh   [0:1000];
    integer exp_row_ld   [0:1000];
    integer exp_row_rx   [0:1000];
    integer exp_row_rh   [0:1000];
    integer exp_row_rd   [0:1000];
    integer total_row_entries;

    // Load rows.csv
    initial begin
        string dummy_line;
        fd_rows = $fopen("E:/Project/nesai2026/log/lane_fpga/vectors/seg_A_solid/rows.csv", "r");
        if (fd_rows == 0) begin
            $display("ERROR: Cannot open rows.csv!");
            $finish;
        end
        // read header
        void'($fgets(dummy_line, fd_rows));
        total_row_entries = 0;
        while (!$feof(fd_rows) && total_row_entries < 1000) begin
            if ($fscanf(fd_rows, "%d,%d,%d,%d,%d,%d,%d,%d\n",
                        c_frm, c_y, c_lx, c_lh, c_ld, c_rx, c_rh, c_rd) == 8) begin
                exp_row_lx[total_row_entries] = c_lx;
                exp_row_lh[total_row_entries] = c_lh;
                exp_row_ld[total_row_entries] = c_ld;
                exp_row_rx[total_row_entries] = c_rx;
                exp_row_rh[total_row_entries] = c_rh;
                exp_row_rd[total_row_entries] = c_rd;
                total_row_entries = total_row_entries + 1;
            end
        end
        $fclose(fd_rows);
        $display("Loaded %0d rows from rows.csv for row-by-row comparison.", total_row_entries);
    end

    integer fd, f_idx, row, col, ret, bi;
    reg [7:0] raw_bytes [0:960*540*2-1];
    reg [15:0] rgb565_val;

    integer total_frame_mismatches = 0;
    integer total_row_mismatches = 0;
    integer row_print_count = 0;
    integer cur_row_ptr;

    // Row-by-row checker
    integer debug_si;
    always @(posedge clk) begin
        if (uut.in_roi && (uut.lb_fsm == 3'd2)) begin
            if (f_idx == 1 && uut.y_pos == 12'd344) begin
                $display("RTL Frame 1 row 344: d_y=%0d, W_y=%0d, w_max=%0d, x_pred_l=%0d, best_x_l=%0d",
                         uut.cur_dy, uut.cur_Wy, uut.cur_w_max, uut.x_pred_l, uut.best_x_l);
                $write("  RTL runs: ");
                for (debug_si = 0; debug_si < uut.run_cnt; debug_si = debug_si + 1)
                    $write("%0d ", uut.run_buf[debug_si]);
                $write("\n");
            end
            cur_row_ptr = f_idx * 241 + (uut.y_pos - 260);

            if (cur_row_ptr < total_row_entries) begin

                // Check left & right
                integer rtl_lx, rtl_lh, rtl_ld;
                integer rtl_rx, rtl_rh, rtl_rd;
                rtl_lh = uut.l_found;
                rtl_lx = rtl_lh ? uut.best_x_l : -1;
                rtl_ld = uut.dbl_l_reg;
                rtl_rh = uut.r_found;
                rtl_rx = rtl_rh ? uut.best_x_r : -1;
                rtl_rd = uut.dbl_r_reg;

                if ((rtl_lh != exp_row_lh[cur_row_ptr]) ||
                    (rtl_lh && (rtl_lx != exp_row_lx[cur_row_ptr])) ||
                    (rtl_ld != exp_row_ld[cur_row_ptr]) ||
                    (rtl_rh != exp_row_rh[cur_row_ptr]) ||
                    (rtl_rh && (rtl_rx != exp_row_rx[cur_row_ptr])) ||
                    (rtl_rd != exp_row_rd[cur_row_ptr])) begin
                    total_row_mismatches = total_row_mismatches + 1;
                    if (row_print_count < 20) begin
                        $display("ROW MISMATCH [f=%0d y=%0d]: RTL(L:{hit=%0d,x=%0d,dbl=%0d} R:{hit=%0d,x=%0d,dbl=%0d}) vs EXP(L:{hit=%0d,x=%0d,dbl=%0d} R:{hit=%0d,x=%0d,dbl=%0d})",
                                 f_idx, uut.y_pos,
                                 rtl_lh, rtl_lx, rtl_ld, rtl_rh, rtl_rx, rtl_rd,
                                 exp_row_lh[cur_row_ptr], exp_row_lx[cur_row_ptr], exp_row_ld[cur_row_ptr],
                                 exp_row_rh[cur_row_ptr], exp_row_rx[cur_row_ptr], exp_row_rd[cur_row_ptr]);
                        row_print_count = row_print_count + 1;
                    end
                end
            end
        end
    end

    initial begin
        clk = 0;
        rst_n = 0;
        de = 0;
        vs = 0;
        hs = 0;
        r = 0; g = 0; b = 0;

        fd = $fopen("E:/Project/nesai2026/log/lane_fpga/vectors/seg_A_solid/frames.bin", "rb");
        if (fd == 0) begin
            $display("ERROR: Cannot open frames.bin!");
            $finish;
        end

        #50;
        rst_n = 1;
        #50;

        $display("=== Starting Lane Detection 3-Frame Simulation ===");

        for (f_idx = 0; f_idx < 3; f_idx = f_idx + 1) begin
            ret = $fread(raw_bytes, fd);
            if (ret != 960*540*2) begin
                $display("ERROR: Read error at frame %0d (read %0d bytes)", f_idx, ret);
                $finish;
            end

            // Vertical blanking
            vs = 1'b1;
            repeat (20) @(posedge clk);
            vs = 1'b0;
            repeat (50) @(posedge clk);

            // Active frame: 540 lines
            for (row = 0; row < 540; row = row + 1) begin
                for (col = 0; col < 960; col = col + 1) begin
                    bi = (row * 960 + col) * 2;
                    rgb565_val = {raw_bytes[bi+1], raw_bytes[bi]};
                    r = {rgb565_val[15:11], 3'b000};
                    g = {rgb565_val[10:5], 2'b00};
                    b = {rgb565_val[4:0], 3'b000};
                    de = 1'b1;
                    @(posedge clk);
                end
                de = 1'b0;
                // Line blanking (280 clocks)
                repeat (280) @(posedge clk);
            end

            repeat (20) @(posedge clk);

            $display("--- Frame %0d Results ---", f_idx);
            // Compare Left
            $display("  LEFT:  n=%0d (exp %0d), a_q16=%0d (exp %0d), b_q4=%0d (exp %0d), valid=%0d, solid=%0d",
                     out_l_n, exp_n_l[f_idx],
                     $signed(out_l_a_q16), exp_a_l[f_idx],
                     $signed(out_l_b_q4), exp_b_l[f_idx],
                     out_l_valid, out_l_solid);
            if ((out_l_n != exp_n_l[f_idx]) || ($signed(out_l_a_q16) != exp_a_l[f_idx]) ||
                ($signed(out_l_b_q4) != exp_b_l[f_idx]) || (out_l_valid != exp_val_l[f_idx]) ||
                (out_l_solid != exp_sol_l[f_idx])) begin
                $display("  --> LEFT MISMATCH! diff_a=%0d, diff_b=%0d, diff_n=%0d",
                         $signed(out_l_a_q16) - exp_a_l[f_idx],
                         $signed(out_l_b_q4) - exp_b_l[f_idx],
                         out_l_n - exp_n_l[f_idx]);
                total_frame_mismatches = total_frame_mismatches + 1;
            end else begin
                $display("  --> LEFT MATCH!");
            end

            // Compare Right
            $display("  RIGHT: n=%0d (exp %0d), a_q16=%0d (exp %0d), b_q4=%0d (exp %0d), valid=%0d, solid=%0d",
                     out_r_n, exp_n_r[f_idx],
                     $signed(out_r_a_q16), exp_a_r[f_idx],
                     $signed(out_r_b_q4), exp_b_r[f_idx],
                     out_r_valid, out_r_solid);
            if ((out_r_n != exp_n_r[f_idx]) || ($signed(out_r_a_q16) != exp_a_r[f_idx]) ||
                ($signed(out_r_b_q4) != exp_b_r[f_idx]) || (out_r_valid != exp_val_r[f_idx]) ||
                (out_r_solid != exp_sol_r[f_idx])) begin
                $display("  --> RIGHT MISMATCH! diff_a=%0d, diff_b=%0d, diff_n=%0d",
                         $signed(out_r_a_q16) - exp_a_r[f_idx],
                         $signed(out_r_b_q4) - exp_b_r[f_idx],
                         out_r_n - exp_n_r[f_idx]);
                total_frame_mismatches = total_frame_mismatches + 1;
            end else begin
                $display("  --> RIGHT MATCH!");
            end
        end

        $fclose(fd);
        $display("==================================================");
        $display("ROW MISMATCHES: %0d / %0d", total_row_mismatches, 3 * 241);
        $display("FRAME MISMATCHES: %0d / 6", total_frame_mismatches);
        if ((total_row_mismatches == 0) && (total_frame_mismatches == 0)) begin
            $display("ALL 3 FRAMES EXACTLY MATCH! Testbench PASSED.");
        end else begin
            $display("Testbench FAILED.");
        end
        $display("==================================================");
        $finish;
    end

endmodule
