`timescale 1ns/1ps

module tb_osd_lane;

    localparam H_ACT = 960;
    localparam V_ACT = 540;
    localparam CLK_PERIOD = 10;

    reg pix_clk = 0;
    always #(CLK_PERIOD / 2) pix_clk = ~pix_clk;

    reg rst_n = 0;

    // Direct generator outputs
    reg [7:0]  sync_r, sync_g, sync_b;
    reg        sync_de, sync_hs, sync_vs;
    reg [11:0] sync_x, sync_y;

    // 5-stage shift register for video data/sync to match rt_disp_reader latency
    reg [4:0]  sr_de = 0, sr_hs = 0, sr_vs = 0;
    reg [7:0]  sr_r [0:4];
    reg [7:0]  sr_g [0:4];
    reg [7:0]  sr_b [0:4];
    integer    si;

    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            sr_de <= 5'b0;
            sr_hs <= 5'b0;
            sr_vs <= 5'b0;
            for (si = 0; si < 5; si = si + 1) begin
                sr_r[si] <= 8'd0;
                sr_g[si] <= 8'd0;
                sr_b[si] <= 8'd0;
            end
        end else begin
            sr_de <= {sr_de[3:0], sync_de};
            sr_hs <= {sr_hs[3:0], sync_hs};
            sr_vs <= {sr_vs[3:0], sync_vs};
            sr_r[0] <= sync_r;
            sr_g[0] <= sync_g;
            sr_b[0] <= sync_b;
            for (si = 1; si < 5; si = si + 1) begin
                sr_r[si] <= sr_r[si-1];
                sr_g[si] <= sr_g[si-1];
                sr_b[si] <= sr_b[si-1];
            end
        end
    end

    wire [7:0]  r_in  = sr_r[4];
    wire [7:0]  g_in  = sr_g[4];
    wire [7:0]  b_in  = sr_b[4];
    wire        de_in = sr_de[4];
    wire        hs_in = sr_hs[4];
    wire        vs_in = sr_vs[4];
    wire [11:0] x_act = sync_x;
    wire [11:0] y_act = sync_y;

    // DUT Control & Lane configuration
    reg         osd_en;
    reg         lane_draw_en;
    reg         lane_l_valid, lane_l_solid;
    reg [11:0]  lane_l_ytop, lane_l_ybot;
    reg [31:0]  lane_l_x_top, lane_l_dx;
    reg         lane_r_valid, lane_r_solid;
    reg [11:0]  lane_r_ytop, lane_r_ybot;
    reg [31:0]  lane_r_x_top, lane_r_dx;

    // DUT outputs
    wire [7:0]  r_out, g_out, b_out;
    wire        de_out, hs_out, vs_out;

    // DUT Instantiation
    rt_osd #(
        .H_ACT (H_ACT),
        .V_ACT (V_ACT)
    ) u_dut (
        .pix_clk        (pix_clk),
        .rst_n          (rst_n),
        .r_in           (r_in),
        .g_in           (g_in),
        .b_in           (b_in),
        .de_in          (de_in),
        .hs_in          (hs_in),
        .vs_in          (vs_in),
        .x_act          (x_act),
        .y_act          (y_act),
        .osd_en         (osd_en),
        .dec            (32'd0),
        .osdctrl        (32'd0),
        .box            (832'd0),
        .vp_x           (12'd0),
        .vp_y           (12'd0),
        .y_top          (12'd0),
        .y_bot          (12'd0),
        .g              (12'd0),
        .cal_mode       (1'b0),
        .obj            (2'd0),
        .cal_blink      (1'b0),
        .status_line    (512'd0),
        .tram_wclk      (1'b0),
        .tram_we        (1'b0),
        .tram_addr      (6'd0),
        .tram_wdata     (32'd0),
        .lane_draw_en   (lane_draw_en),
        .lane_l_valid   (lane_l_valid),
        .lane_l_solid   (lane_l_solid),
        .lane_l_ytop    (lane_l_ytop),
        .lane_l_ybot    (lane_l_ybot),
        .lane_l_x_top   (lane_l_x_top),
        .lane_l_dx      (lane_l_dx),
        .lane_r_valid   (lane_r_valid),
        .lane_r_solid   (lane_r_solid),
        .lane_r_ytop    (lane_r_ytop),
        .lane_r_ybot    (lane_r_ybot),
        .lane_r_x_top   (lane_r_x_top),
        .lane_r_dx      (lane_r_dx),
        .r_out          (r_out),
        .g_out          (g_out),
        .b_out          (b_out),
        .de_out         (de_out),
        .hs_out         (hs_out),
        .vs_out         (vs_out)
    );

    // Expected Model parameters
    reg [31:0] exp_l_xtop;
    reg [31:0] exp_l_dx;
    reg [11:0] exp_l_ytop, exp_l_ybot;
    reg        exp_l_valid, exp_l_solid;

    reg [31:0] exp_r_xtop;
    reg [31:0] exp_r_dx;
    reg [11:0] exp_r_ytop, exp_r_ybot;
    reg        exp_r_valid, exp_r_solid;

    reg        exp_osd_en;
    reg        exp_lane_draw_en;

    // Expected Model computation
    function automatic void calc_expected(
        input integer x,
        input integer y,
        output reg [7:0] exp_r,
        output reg [7:0] exp_g,
        output reg [7:0] exp_b,
        output reg is_hit
    );
        reg signed [31:0] X_l, X_r;
        integer x_int_l, x_int_r;
        reg hit_l, hit_r;
    begin
        exp_r = 8'd10;
        exp_g = 8'd20;
        exp_b = 8'd30;
        is_hit = 1'b0;
        hit_l = 1'b0;
        hit_r = 1'b0;

        if (exp_osd_en && exp_lane_draw_en) begin
            // Left lane
            if (exp_l_valid && (y >= exp_l_ytop) && (y <= exp_l_ybot) && (y >= 0) && (y < 540) && (x >= 0) && (x < 960)) begin
                X_l = exp_l_xtop + (y - exp_l_ytop) * exp_l_dx;
                x_int_l = $signed(X_l) >>> 16;
                if ((x - x_int_l >= -1) && (x - x_int_l <= 1)) begin
                    hit_l = 1'b1;
                end
            end

            // Right lane
            if (exp_r_valid && (y >= exp_r_ytop) && (y <= exp_r_ybot) && (y >= 0) && (y < 540) && (x >= 0) && (x < 960)) begin
                X_r = exp_r_xtop + (y - exp_r_ytop) * exp_r_dx;
                x_int_r = $signed(X_r) >>> 16;
                if ((x - x_int_r >= -1) && (x - x_int_r <= 1)) begin
                    hit_r = 1'b1;
                end
            end

            if (hit_l) begin
                exp_r = exp_l_solid ? 8'd255 : 8'd0;
                exp_g = 8'd220;
                exp_b = 8'd0;
                is_hit = 1'b1;
            end
            if (hit_r) begin
                exp_r = exp_r_solid ? 8'd255 : 8'd0;
                exp_g = 8'd220;
                exp_b = 8'd0;
                is_hit = 1'b1;
            end
        end
    end
    endfunction

    // Checker tracking
    integer out_x = 0;
    integer out_y = 0;
    integer test_hits = 0;
    integer test_exp_hits = 0;
    integer test_mismatches = 0;
    integer mismatch_prints = 0;
    reg test_active = 0;

    reg [7:0] cur_exp_r, cur_exp_g, cur_exp_b;
    reg cur_is_hit;

    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            out_x <= 0;
            out_y <= 0;
        end else if (vs_out) begin
            out_x <= 0;
            out_y <= 0;
        end else if (de_out) begin
            if (test_active) begin
                calc_expected(out_x, out_y, cur_exp_r, cur_exp_g, cur_exp_b, cur_is_hit);
                if (cur_is_hit) begin
                    test_exp_hits = test_exp_hits + 1;
                end
                if ({r_out, g_out, b_out} != {8'd10, 8'd20, 8'd30}) begin
                    test_hits = test_hits + 1;
                end
                if ({r_out, g_out, b_out} !== {cur_exp_r, cur_exp_g, cur_exp_b}) begin
                    test_mismatches = test_mismatches + 1;
                    if (mismatch_prints < 10) begin
                        $display("  MISMATCH at (x=%0d, y=%0d): got=(%0d,%0d,%0d) exp=(%0d,%0d,%0d)",
                                 out_x, out_y, r_out, g_out, b_out, cur_exp_r, cur_exp_g, cur_exp_b);
                        mismatch_prints = mismatch_prints + 1;
                    end
                end
            end
            if (out_x == 959) begin
                out_x <= 0;
                out_y <= out_y + 1;
            end else begin
                out_x <= out_x + 1;
            end
        end
    end

    // Task to apply reset
    task do_reset;
    begin
        rst_n   = 1'b0;
        sync_vs = 1'b0;
        sync_hs = 1'b0;
        sync_de = 1'b0;
        sync_x  = 12'd0;
        sync_y  = 12'd0;
        sync_r  = 8'd0;
        sync_g  = 8'd0;
        sync_b  = 8'd0;
        repeat (10) @(posedge pix_clk);
        rst_n   = 1'b1;
        repeat (10) @(posedge pix_clk);
    end
    endtask

    // Task to drive one frame
    task drive_frame(input integer mid_change_row, input [31:0] mid_new_xtop);
        integer r, c;
    begin
        // Vertical blanking: pulse VS to latch parameters in DUT
        sync_vs = 1'b1;
        repeat (10) @(posedge pix_clk);
        sync_vs = 1'b0;
        repeat (20) @(posedge pix_clk);

        // Active frame: 540 rows x 960 cols
        for (r = 0; r < 540; r = r + 1) begin
            if (mid_change_row >= 0 && r == mid_change_row) begin
                lane_l_x_top = mid_new_xtop;
            end
            for (c = 0; c < 960; c = c + 1) begin
                sync_x  = c;
                sync_y  = r;
                sync_de = 1'b1;
                sync_r  = 8'd10;
                sync_g  = 8'd20;
                sync_b  = 8'd30;
                @(posedge pix_clk);
            end
            sync_de = 1'b0;
            sync_x  = 0;
            sync_r  = 8'd0;
            sync_g  = 8'd0;
            sync_b  = 8'd0;
            repeat (20) @(posedge pix_clk);
        end
        repeat (30) @(posedge pix_clk);
    end
    endtask

    // Global pass tracker
    reg all_passed = 1'b1;

    initial begin
        pix_clk = 0;
        rst_n = 0;
        sync_vs = 0;
        sync_hs = 0;
        sync_de = 0;
        sync_x  = 0;
        sync_y  = 0;
        sync_r  = 0;
        sync_g  = 0;
        sync_b  = 0;

        osd_en        = 1'b0;
        lane_draw_en  = 1'b0;
        lane_l_valid  = 1'b0;
        lane_l_solid  = 1'b0;
        lane_l_ytop   = 12'd260;
        lane_l_ybot   = 12'd500;
        lane_l_x_top  = 32'd0;
        lane_l_dx     = 32'd0;
        lane_r_valid  = 1'b0;
        lane_r_solid  = 1'b0;
        lane_r_ytop   = 12'd260;
        lane_r_ybot   = 12'd500;
        lane_r_x_top  = 32'd0;
        lane_r_dx     = 32'd0;

        exp_osd_en        = 1'b0;
        exp_lane_draw_en  = 1'b0;
        exp_l_valid       = 1'b0;
        exp_l_solid       = 1'b0;
        exp_l_ytop        = 12'd260;
        exp_l_ybot        = 12'd500;
        exp_l_xtop        = 32'd0;
        exp_l_dx          = 32'd0;
        exp_r_valid       = 1'b0;
        exp_r_solid       = 1'b0;
        exp_r_ytop        = 12'd260;
        exp_r_ybot        = 12'd500;
        exp_r_xtop        = 32'd0;
        exp_r_dx          = 32'd0;

        #20;

        //-------------------------------------------------------------
        // Case (a): Left Solid Yellow
        // ytop=260, ybot=500, x_top = 400<<16, dx = 0.5<<16
        //-------------------------------------------------------------
        do_reset();
        osd_en        = 1'b1;
        lane_draw_en  = 1'b1;
        lane_l_valid  = 1'b1;
        lane_l_solid  = 1'b1;
        lane_l_ytop   = 12'd260;
        lane_l_ybot   = 12'd500;
        lane_l_x_top  = 32'd400 << 16;
        lane_l_dx     = 32'sd32768; // 0.5 << 16
        lane_r_valid  = 1'b0;

        exp_osd_en       = osd_en;
        exp_lane_draw_en = lane_draw_en;
        exp_l_valid      = lane_l_valid;
        exp_l_solid      = lane_l_solid;
        exp_l_ytop       = lane_l_ytop;
        exp_l_ybot       = lane_l_ybot;
        exp_l_xtop       = lane_l_x_top;
        exp_l_dx         = lane_l_dx;
        exp_r_valid      = 1'b0;

        test_hits = 0; test_exp_hits = 0; test_mismatches = 0; mismatch_prints = 0;
        test_active = 1;
        drive_frame(-1, 0);
        test_active = 0;

        if (test_mismatches == 0 && test_hits == test_exp_hits && test_hits > 0) begin
            $display("(a) PASS: hits=%0d expected=%0d mismatches=%0d", test_hits, test_exp_hits, test_mismatches);
        end else begin
            $display("(a) FAIL: hits=%0d expected=%0d mismatches=%0d", test_hits, test_exp_hits, test_mismatches);
            all_passed = 1'b0;
        end

        //-------------------------------------------------------------
        // Case (b): Left Dashed Green
        // Same params as (a), but solid=0
        //-------------------------------------------------------------
        do_reset();
        osd_en        = 1'b1;
        lane_draw_en  = 1'b1;
        lane_l_valid  = 1'b1;
        lane_l_solid  = 1'b0;
        lane_l_ytop   = 12'd260;
        lane_l_ybot   = 12'd500;
        lane_l_x_top  = 32'd400 << 16;
        lane_l_dx     = 32'sd32768;
        lane_r_valid  = 1'b0;

        exp_osd_en       = osd_en;
        exp_lane_draw_en = lane_draw_en;
        exp_l_valid      = lane_l_valid;
        exp_l_solid      = lane_l_solid;
        exp_l_ytop       = lane_l_ytop;
        exp_l_ybot       = lane_l_ybot;
        exp_l_xtop       = lane_l_x_top;
        exp_l_dx         = lane_l_dx;
        exp_r_valid      = 1'b0;

        test_hits = 0; test_exp_hits = 0; test_mismatches = 0; mismatch_prints = 0;
        test_active = 1;
        drive_frame(-1, 0);
        test_active = 0;

        if (test_mismatches == 0 && test_hits == test_exp_hits && test_hits > 0) begin
            $display("(b) PASS: hits=%0d expected=%0d mismatches=%0d", test_hits, test_exp_hits, test_mismatches);
        end else begin
            $display("(b) FAIL: hits=%0d expected=%0d mismatches=%0d", test_hits, test_exp_hits, test_mismatches);
            all_passed = 1'b0;
        end

        //-------------------------------------------------------------
        // Case (c): Right Line Decreasing x_int
        // x_top = 560<<16, dx = -0.5<<16, solid=0
        //-------------------------------------------------------------
        do_reset();
        osd_en        = 1'b1;
        lane_draw_en  = 1'b1;
        lane_l_valid  = 1'b0;
        lane_r_valid  = 1'b1;
        lane_r_solid  = 1'b0;
        lane_r_ytop   = 12'd260;
        lane_r_ybot   = 12'd500;
        lane_r_x_top  = 32'd560 << 16;
        lane_r_dx     = -32'sd32768; // -0.5 << 16

        exp_osd_en       = osd_en;
        exp_lane_draw_en = lane_draw_en;
        exp_l_valid      = 1'b0;
        exp_r_valid      = lane_r_valid;
        exp_r_solid      = lane_r_solid;
        exp_r_ytop       = lane_r_ytop;
        exp_r_ybot       = lane_r_ybot;
        exp_r_xtop       = lane_r_x_top;
        exp_r_dx         = lane_r_dx;

        test_hits = 0; test_exp_hits = 0; test_mismatches = 0; mismatch_prints = 0;
        test_active = 1;
        drive_frame(-1, 0);
        test_active = 0;

        if (test_mismatches == 0 && test_hits == test_exp_hits && test_hits > 0) begin
            $display("(c) PASS: hits=%0d expected=%0d mismatches=%0d", test_hits, test_exp_hits, test_mismatches);
        end else begin
            $display("(c) FAIL: hits=%0d expected=%0d mismatches=%0d", test_hits, test_exp_hits, test_mismatches);
            all_passed = 1'b0;
        end

        //-------------------------------------------------------------
        // Case (d): Fractional Pixel
        // x_top = (400.7)<<16, dx = (0.3)<<16
        //-------------------------------------------------------------
        do_reset();
        osd_en        = 1'b1;
        lane_draw_en  = 1'b1;
        lane_l_valid  = 1'b1;
        lane_l_solid  = 1'b1;
        lane_l_ytop   = 12'd260;
        lane_l_ybot   = 12'd500;
        lane_l_x_top  = 32'd26259948; // round(400.7 * 65536)
        lane_l_dx     = 32'd19661;    // round(0.3 * 65536)
        lane_r_valid  = 1'b0;

        exp_osd_en       = osd_en;
        exp_lane_draw_en = lane_draw_en;
        exp_l_valid      = lane_l_valid;
        exp_l_solid      = lane_l_solid;
        exp_l_ytop       = lane_l_ytop;
        exp_l_ybot       = lane_l_ybot;
        exp_l_xtop       = lane_l_x_top;
        exp_l_dx         = lane_l_dx;
        exp_r_valid      = 1'b0;

        test_hits = 0; test_exp_hits = 0; test_mismatches = 0; mismatch_prints = 0;
        test_active = 1;
        drive_frame(-1, 0);
        test_active = 0;

        if (test_mismatches == 0 && test_hits == test_exp_hits && test_hits > 0) begin
            $display("(d) PASS: hits=%0d expected=%0d mismatches=%0d", test_hits, test_exp_hits, test_mismatches);
        end else begin
            $display("(d) FAIL: hits=%0d expected=%0d mismatches=%0d", test_hits, test_exp_hits, test_mismatches);
            all_passed = 1'b0;
        end

        //-------------------------------------------------------------
        // Case (e): Out of Bounds
        // ytop=500, ybot=600, x_top=940<<16, dx=1<<16
        //-------------------------------------------------------------
        do_reset();
        osd_en        = 1'b1;
        lane_draw_en  = 1'b1;
        lane_l_valid  = 1'b1;
        lane_l_solid  = 1'b1;
        lane_l_ytop   = 12'd500;
        lane_l_ybot   = 12'd600;
        lane_l_x_top  = 32'd940 << 16;
        lane_l_dx     = 32'd1 << 16;
        lane_r_valid  = 1'b0;

        exp_osd_en       = osd_en;
        exp_lane_draw_en = lane_draw_en;
        exp_l_valid      = lane_l_valid;
        exp_l_solid      = lane_l_solid;
        exp_l_ytop       = lane_l_ytop;
        exp_l_ybot       = lane_l_ybot;
        exp_l_xtop       = lane_l_x_top;
        exp_l_dx         = lane_l_dx;
        exp_r_valid      = 1'b0;

        test_hits = 0; test_exp_hits = 0; test_mismatches = 0; mismatch_prints = 0;
        test_active = 1;
        drive_frame(-1, 0);
        test_active = 0;

        if (test_mismatches == 0 && test_hits == test_exp_hits && test_hits > 0) begin
            $display("(e) PASS: hits=%0d expected=%0d mismatches=%0d", test_hits, test_exp_hits, test_mismatches);
        end else begin
            $display("(e) FAIL: hits=%0d expected=%0d mismatches=%0d", test_hits, test_exp_hits, test_mismatches);
            all_passed = 1'b0;
        end

        //-------------------------------------------------------------
        // Case (f): Disables
        // lane_draw_en=0, lane_l_valid=0, osd_en=0
        //-------------------------------------------------------------
        begin : test_f_block
            integer f_hits, f_exp, f_mis;
            f_hits = 0; f_exp = 0; f_mis = 0;

            // f1: lane_draw_en = 0
            do_reset();
            osd_en = 1'b1; lane_draw_en = 1'b0; lane_l_valid = 1'b1; lane_l_solid = 1'b1;
            lane_l_ytop = 12'd260; lane_l_ybot = 12'd500; lane_l_x_top = 32'd400 << 16; lane_l_dx = 32'sd32768;
            lane_r_valid = 1'b0;
            exp_osd_en = osd_en; exp_lane_draw_en = lane_draw_en; exp_l_valid = lane_l_valid;
            exp_l_solid = lane_l_solid; exp_l_ytop = lane_l_ytop; exp_l_ybot = lane_l_ybot;
            exp_l_xtop = lane_l_x_top; exp_l_dx = lane_l_dx; exp_r_valid = 1'b0;
            test_hits = 0; test_exp_hits = 0; test_mismatches = 0; mismatch_prints = 0;
            test_active = 1;
            drive_frame(-1, 0);
            test_active = 0;
            f_hits = f_hits + test_hits; f_exp = f_exp + test_exp_hits; f_mis = f_mis + test_mismatches;

            // f2: lane_l_valid = 0
            do_reset();
            osd_en = 1'b1; lane_draw_en = 1'b1; lane_l_valid = 1'b0; lane_l_solid = 1'b1;
            lane_l_ytop = 12'd260; lane_l_ybot = 12'd500; lane_l_x_top = 32'd400 << 16; lane_l_dx = 32'sd32768;
            lane_r_valid = 1'b0;
            exp_osd_en = osd_en; exp_lane_draw_en = lane_draw_en; exp_l_valid = lane_l_valid;
            exp_l_solid = lane_l_solid; exp_l_ytop = lane_l_ytop; exp_l_ybot = lane_l_ybot;
            exp_l_xtop = lane_l_x_top; exp_l_dx = lane_l_dx; exp_r_valid = 1'b0;
            test_hits = 0; test_exp_hits = 0; test_mismatches = 0; mismatch_prints = 0;
            test_active = 1;
            drive_frame(-1, 0);
            test_active = 0;
            f_hits = f_hits + test_hits; f_exp = f_exp + test_exp_hits; f_mis = f_mis + test_mismatches;

            // f3: osd_en = 0
            do_reset();
            osd_en = 1'b0; lane_draw_en = 1'b1; lane_l_valid = 1'b1; lane_l_solid = 1'b1;
            lane_l_ytop = 12'd260; lane_l_ybot = 12'd500; lane_l_x_top = 32'd400 << 16; lane_l_dx = 32'sd32768;
            lane_r_valid = 1'b0;
            exp_osd_en = osd_en; exp_lane_draw_en = lane_draw_en; exp_l_valid = lane_l_valid;
            exp_l_solid = lane_l_solid; exp_l_ytop = lane_l_ytop; exp_l_ybot = lane_l_ybot;
            exp_l_xtop = lane_l_x_top; exp_l_dx = lane_l_dx; exp_r_valid = 1'b0;
            test_hits = 0; test_exp_hits = 0; test_mismatches = 0; mismatch_prints = 0;
            test_active = 1;
            drive_frame(-1, 0);
            test_active = 0;
            f_hits = f_hits + test_hits; f_exp = f_exp + test_exp_hits; f_mis = f_mis + test_mismatches;

            if (f_mis == 0 && f_hits == 0 && f_exp == 0) begin
                $display("(f) PASS: hits=%0d expected=%0d mismatches=%0d", f_hits, f_exp, f_mis);
            end else begin
                $display("(f) FAIL: hits=%0d expected=%0d mismatches=%0d", f_hits, f_exp, f_mis);
                all_passed = 1'b0;
            end
        end

        //-------------------------------------------------------------
        // Case (g): Parameter Latches at vs_rise
        // Mid-frame change from 400<<16 to 300<<16
        //-------------------------------------------------------------
        begin : test_g_block
            integer g_hits, g_exp, g_mis;
            g_hits = 0; g_exp = 0; g_mis = 0;

            do_reset();
            osd_en        = 1'b1;
            lane_draw_en  = 1'b1;
            lane_l_valid  = 1'b1;
            lane_l_solid  = 1'b1;
            lane_l_ytop   = 12'd260;
            lane_l_ybot   = 12'd500;
            lane_l_x_top  = 32'd400 << 16;
            lane_l_dx     = 32'sd32768;
            lane_r_valid  = 1'b0;

            // Frame 1: Latches 400<<16, changes wire to 300<<16 at row 100
            exp_osd_en       = 1'b1;
            exp_lane_draw_en = 1'b1;
            exp_l_valid      = 1'b1;
            exp_l_solid      = 1'b1;
            exp_l_ytop       = 12'd260;
            exp_l_ybot       = 12'd500;
            exp_l_xtop       = 32'd400 << 16;
            exp_l_dx         = 32'sd32768;
            exp_r_valid      = 1'b0;

            test_hits = 0; test_exp_hits = 0; test_mismatches = 0; mismatch_prints = 0;
            test_active = 1;
            drive_frame(100, 32'd300 << 16);
            test_active = 0;
            g_hits = g_hits + test_hits; g_exp = g_exp + test_exp_hits; g_mis = g_mis + test_mismatches;

            // Frame 2: Latches the new 300<<16 on VS
            exp_l_xtop       = 32'd300 << 16;

            test_hits = 0; test_exp_hits = 0; test_mismatches = 0; mismatch_prints = 0;
            test_active = 1;
            drive_frame(-1, 0);
            test_active = 0;
            g_hits = g_hits + test_hits; g_exp = g_exp + test_exp_hits; g_mis = g_mis + test_mismatches;

            if (g_mis == 0 && g_hits == g_exp && g_hits > 0) begin
                $display("(g) PASS: hits=%0d expected=%0d mismatches=%0d", g_hits, g_exp, g_mis);
            end else begin
                $display("(g) FAIL: hits=%0d expected=%0d mismatches=%0d", g_hits, g_exp, g_mis);
                all_passed = 1'b0;
            end
        end

        //-------------------------------------------------------------
        // Final Summary
        //-------------------------------------------------------------
        $display("----------------------------------------");
        if (all_passed) begin
            $display("ALL OSD LANE TESTS PASSED");
        end else begin
            $display("SOME OSD LANE TESTS FAILED");
        end
        $display("----------------------------------------");

        $finish;
    end

endmodule
