`timescale 1ns/1ps

module tb_dbg_frame;

    reg        clk;
    reg        rst_n;
    reg        de;
    reg        vs;
    reg        hs;
    reg [7:0]  r, g, b;

    reg [9:0]  dbg_row;
    wire [9:0] dbg_x = 10'd480;
    wire [223:0] dbg_bus;

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
        .dbg_row           (dbg_row),
        .dbg_x             (dbg_x),
        .dbg_bus           (dbg_bus)
    );

    always #3.367 clk = ~clk;

    string frame_path;
    string out_csv_path;
    integer fd_in, fd_csv;
    reg [7:0] raw_bytes [0:960*540*2-1];
    reg [15:0] rgb565_val;
    integer ret, f_idx, row, col, bi;

    initial begin
        clk = 0;
        rst_n = 0;
        de = 0;
        vs = 0;
        hs = 0;
        r = 0;
        g = 0;
        b = 0;
        dbg_row = 10'd0;

        if (!$value$plusargs("FRAME=%s", frame_path)) begin
            $display("ERROR: +FRAME=<path> required");
            $finish;
        end

        if (!$value$plusargs("OUT=%s", out_csv_path)) begin
            $display("ERROR: +OUT=<path> required");
            $finish;
        end

        fd_in = $fopen(frame_path, "rb");
        if (fd_in == 0) begin
            $display("ERROR: Cannot open FRAME file %s", frame_path);
            $finish;
        end

        ret = $fread(raw_bytes, fd_in);
        $fclose(fd_in);
        if (ret != 960*540*2) begin
            $display("ERROR: Expected %0d bytes, got %0d bytes from %s", 960*540*2, ret, frame_path);
            $finish;
        end

        fd_csv = $fopen(out_csv_path, "w");
        if (fd_csv == 0) begin
            $display("ERROR: Cannot open OUT file %s", out_csv_path);
            $finish;
        end

        $fdisplay(fd_csv, "frame,y,A04,A08,A0C,A10,A14,A18,A1C");

        #50; rst_n = 1; #50;

        // Feed the same frame twice
        for (f_idx = 0; f_idx < 2; f_idx = f_idx + 1) begin
            // Vertical blanking: vs pulse
            vs = 1'b1;
            repeat (20) @(posedge clk);
            vs = 1'b0;
            repeat (50) @(posedge clk);

            // Active frame: 540 lines
            bi = 0;
            for (row = 0; row < 540; row = row + 1) begin
                dbg_row = row[9:0];
                @(posedge clk);
                for (col = 0; col < 960; col = col + 1) begin
                    rgb565_val = {raw_bytes[bi+1], raw_bytes[bi]};
                    bi = bi + 2;
                    r = {rgb565_val[4:0], 3'b000};
                    g = {rgb565_val[10:5], 2'b00};
                    b = {rgb565_val[15:11], 3'b000};
                    de = 1'b1;
                    @(posedge clk);
                end
                de = 1'b0;
                r = 8'd0;
                g = 8'd0;
                b = 8'd0;
                repeat (280) @(posedge clk);

                $fdisplay(fd_csv, "%0d,%0d,%08x,%08x,%08x,%08x,%08x,%08x,%08x",
                          f_idx, row,
                          uut.dbg_reg_0xA04,
                          uut.dbg_reg_0xA08,
                          uut.dbg_reg_0xA0C,
                          uut.dbg_reg_0xA10,
                          uut.dbg_reg_0xA14,
                          uut.dbg_reg_0xA18,
                          uut.dbg_reg_0xA1C);
            end

            repeat (100) @(posedge clk);
            $display("FRAME %0d: out_l_n=%0d out_r_n=%0d out_l_valid=%0d out_r_valid=%0d",
                     f_idx, out_l_n, out_r_n, out_l_valid, out_r_valid);
        end

        $fclose(fd_csv);
        $display("Simulation completed successfully.");
        $finish;
    end

endmodule
