`timescale 1ns/1ps
//////////////////////////////////////////////////////////////////////////////
// rt_disp_stats.v
// Read-only bypass statistics for FPGA window 0 (RGB565, 960x540).
//   - Grayscale conversion: gray = (r + (g<<1) + b) >> 2
//   - 3x3 horizontal Sobel (gx) with 2-line buffer (lb0, lb1) + column shift reg
//   - Thresholding: |gx| > thr counted as edge pixel
//   - Statistics output:
//       * frame_cnt[15:0]: vsync rising edge count
//       * edge_cnt[15:0] : edge pixel count of last frame (saturated to 65535)
//       * Sampling rows (y = 90, 180, 360, 450): leftmost & rightmost edge x>>2
//   - Pipeline: 2 stages of Sobel math (shift-and-add) to meet 148.5 MHz timing
//   - When enable=0: all stats cleared to 0, completely inactive
//////////////////////////////////////////////////////////////////////////////
module rt_disp_stats (
    input               pix_clk         ,
    input               rst_n           ,
    input               de              ,
    input               vs              ,
    input       [7:0]   r               ,
    input       [7:0]   g               ,
    input       [7:0]   b               ,
    input               enable          ,
    input       [7:0]   thr             ,
    output wire [95:0]  stats_bus       ,
    output wire         stats_tgl
);

    //------------------------------------------------------------------------
    // Vsync rising edge detection
    //------------------------------------------------------------------------
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

    // Delayed pulse to toggle stats_tgl 1 cycle AFTER stats_bus is latched
    reg vs_rise_d1;
    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) vs_rise_d1 <= 1'b0;
        else        vs_rise_d1 <= vs_rise;
    end

    //------------------------------------------------------------------------
    // Raster coordinate counters (960 x 540)
    //------------------------------------------------------------------------
    reg de_d;
    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) de_d <= 1'b0;
        else        de_d <= de;
    end
    wire de_fall = ~de & de_d;

    reg [11:0] x_pos;
    reg [11:0] y_pos;
    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            x_pos <= 12'd0;
            y_pos <= 12'd0;
        end else if (vs_rise) begin
            x_pos <= 12'd0;
            y_pos <= 12'd0;
        end else if (de) begin
            x_pos <= x_pos + 1'b1;
        end else if (de_fall) begin
            x_pos <= 12'd0;
            y_pos <= y_pos + 1'b1;
        end
    end

    //------------------------------------------------------------------------
    // Stage 0: Grayscale calculation
    //   gray = (r + 2*g + b) >> 2
    //------------------------------------------------------------------------
    reg [7:0]  gray_s0;
    reg        de_s0;
    reg [11:0] x_s0;
    reg [11:0] y_s0;

    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            gray_s0 <= 8'd0;
            de_s0   <= 1'b0;
            x_s0    <= 12'd0;
            y_s0    <= 12'd0;
        end else begin
            gray_s0 <= ({2'b00, r} + {1'b0, g, 1'b0} + {2'b00, b}) >> 2;
            de_s0   <= de;
            x_s0    <= x_pos;
            y_s0    <= y_pos;
        end
    end

    //------------------------------------------------------------------------
    // Stage 1: Line buffers (2 lines x 960 pixels, inferred as BRAM)
    //   lb1 stores line y-1, lb0 stores line y-2.
    //   Read at address x_s0, write at address x_s1 (x_s0 - 1).
    //------------------------------------------------------------------------
    (* syn_ramstyle = "block_ram" *) reg [7:0] lb0 [0:959];
    (* syn_ramstyle = "block_ram" *) reg [7:0] lb1 [0:959];

    reg [7:0]  p0_s1;
    reg [7:0]  p1_s1;
    reg [7:0]  p2_s1;
    reg        de_s1;
    reg [11:0] x_s1;
    reg [11:0] y_s1;

    // Synchronous write (simple dual-port write port)
    always @(posedge pix_clk) begin
        if (de_s1 && (x_s1 < 12'd960)) begin
            lb0[x_s1] <= p1_s1;    // line y-1 shifts into lb0
            lb1[x_s1] <= p2_s1;    // line y shifts into lb1
        end
    end

    // Synchronous read (simple dual-port read port) + stage 1 registers
    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            p0_s1 <= 8'd0;
            p1_s1 <= 8'd0;
            p2_s1 <= 8'd0;
            de_s1 <= 1'b0;
            x_s1  <= 12'd0;
            y_s1  <= 12'd0;
        end else begin
            p0_s1 <= (x_s0 < 12'd960) ? lb0[x_s0] : 8'd0;
            p1_s1 <= (x_s0 < 12'd960) ? lb1[x_s0] : 8'd0;
            p2_s1 <= gray_s0;
            de_s1 <= de_s0;
            x_s1  <= x_s0;
            y_s1  <= y_s0;
        end
    end

    //------------------------------------------------------------------------
    // Stage 2: 3x3 Window shift registers
    //   [ c00 c01 c02 ]   (row y-2)
    //   [ c10 c11 c12 ]   (row y-1, center is c11)
    //   [ c20 c21 c22 ]   (row y)
    //------------------------------------------------------------------------
    reg [7:0] c00, c01, c02;
    reg [7:0] c10, c11, c12;
    reg [7:0] c20, c21, c22;
    reg        de_s2;
    reg [11:0] x_s2;
    reg [11:0] y_s2;

    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            c00 <= 8'd0; c01 <= 8'd0; c02 <= 8'd0;
            c10 <= 8'd0; c11 <= 8'd0; c12 <= 8'd0;
            c20 <= 8'd0; c21 <= 8'd0; c22 <= 8'd0;
            de_s2 <= 1'b0;
            x_s2  <= 12'd0;
            y_s2  <= 12'd0;
        end else begin
            if (de_s1) begin
                c02 <= p0_s1; c01 <= c02; c00 <= c01;
                c12 <= p1_s1; c11 <= c12; c10 <= c11;
                c22 <= p2_s1; c21 <= c22; c20 <= c21;
            end
            de_s2 <= de_s1;
            x_s2  <= x_s1;
            y_s2  <= y_s1;
        end
    end

    //------------------------------------------------------------------------
    // Stage 3: Sobel horizontal addition (shift & add, no multipliers)
    //   Right column: c02 + 2*c12 + c22
    //   Left column : c00 + 2*c10 + c20
    //   Center coordinate: x_center = x_s2 - 1, y_center = y_s2 - 1
    //------------------------------------------------------------------------
    reg [10:0] r_sum_s3;
    reg [10:0] l_sum_s3;
    reg        valid_s3;
    reg [11:0] xc_s3;
    reg [11:0] yc_s3;

    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            r_sum_s3 <= 11'd0;
            l_sum_s3 <= 11'd0;
            valid_s3 <= 1'b0;
            xc_s3    <= 12'd0;
            yc_s3    <= 12'd0;
        end else begin
            r_sum_s3 <= {3'b000, c02} + {2'b00, c12, 1'b0} + {3'b00, c22};
            l_sum_s3 <= {3'b000, c00} + {2'b00, c10, 1'b0} + {3'b00, c20};
            // 3x3 window is valid only when center pixel is within [1..958] x [1..538]
            valid_s3 <= de_s2 && (x_s2 >= 12'd2) && (y_s2 >= 12'd2);
            xc_s3    <= (x_s2 >= 12'd1) ? (x_s2 - 12'd1) : 12'd0;
            yc_s3    <= (y_s2 >= 12'd1) ? (y_s2 - 12'd1) : 12'd0;
        end
    end

    //------------------------------------------------------------------------
    // Stage 4: Sobel horizontal magnitude & threshold comparison
    //   |gx| = |r_sum - l_sum|
    //   is_edge = |gx| > thr
    //------------------------------------------------------------------------
    reg        edge_s4;
    reg        valid_s4;
    reg [11:0] xc_s4;
    reg [11:0] yc_s4;

    wire [10:0] diff_s3 = (r_sum_s3 >= l_sum_s3) ? (r_sum_s3 - l_sum_s3)
                                                  : (l_sum_s3 - r_sum_s3);

    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            edge_s4  <= 1'b0;
            valid_s4 <= 1'b0;
            xc_s4    <= 12'd0;
            yc_s4    <= 12'd0;
        end else begin
            edge_s4  <= (diff_s3 > {3'b000, thr});
            valid_s4 <= valid_s3;
            xc_s4    <= xc_s3;
            yc_s4    <= yc_s3;
        end
    end

    wire is_edge_pix = valid_s4 && edge_s4 && enable;

    //------------------------------------------------------------------------
    // Stage 5: Frame statistics accumulators
    //------------------------------------------------------------------------
    reg [15:0] edge_cnt_acc;
    reg [7:0]  row90_L_acc,  row90_R_acc;  reg row90_fnd;
    reg [7:0]  row180_L_acc, row180_R_acc; reg row180_fnd;
    reg [7:0]  row360_L_acc, row360_R_acc; reg row360_fnd;
    reg [7:0]  row450_L_acc, row450_R_acc; reg row450_fnd;

    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            edge_cnt_acc <= 16'd0;
            row90_L_acc  <= 8'd0; row90_R_acc  <= 8'd0; row90_fnd  <= 1'b0;
            row180_L_acc <= 8'd0; row180_R_acc <= 8'd0; row180_fnd <= 1'b0;
            row360_L_acc <= 8'd0; row360_R_acc <= 8'd0; row360_fnd <= 1'b0;
            row450_L_acc <= 8'd0; row450_R_acc <= 8'd0; row450_fnd <= 1'b0;
        end else if (!enable || vs_rise) begin
            edge_cnt_acc <= 16'd0;
            row90_L_acc  <= 8'd0; row90_R_acc  <= 8'd0; row90_fnd  <= 1'b0;
            row180_L_acc <= 8'd0; row180_R_acc <= 8'd0; row180_fnd <= 1'b0;
            row360_L_acc <= 8'd0; row360_R_acc <= 8'd0; row360_fnd <= 1'b0;
            row450_L_acc <= 8'd0; row450_R_acc <= 8'd0; row450_fnd <= 1'b0;
        end else if (is_edge_pix) begin
            if (edge_cnt_acc != 16'hFFFF)
                edge_cnt_acc <= edge_cnt_acc + 1'b1;

            if (yc_s4 == 12'd90) begin
                if (!row90_fnd) begin
                    row90_L_acc <= xc_s4[9:2];
                    row90_fnd   <= 1'b1;
                end
                row90_R_acc <= xc_s4[9:2];
            end

            if (yc_s4 == 12'd180) begin
                if (!row180_fnd) begin
                    row180_L_acc <= xc_s4[9:2];
                    row180_fnd   <= 1'b1;
                end
                row180_R_acc <= xc_s4[9:2];
            end

            if (yc_s4 == 12'd360) begin
                if (!row360_fnd) begin
                    row360_L_acc <= xc_s4[9:2];
                    row360_fnd   <= 1'b1;
                end
                row360_R_acc <= xc_s4[9:2];
            end

            if (yc_s4 == 12'd450) begin
                if (!row450_fnd) begin
                    row450_L_acc <= xc_s4[9:2];
                    row450_fnd   <= 1'b1;
                end
                row450_R_acc <= xc_s4[9:2];
            end
        end
    end

    //------------------------------------------------------------------------
    // Frame boundary latching & stats_bus / stats_tgl output
    //------------------------------------------------------------------------
    reg [15:0] frame_cnt_r;
    reg [95:0] stats_bus_r;
    reg        stats_tgl_r;

    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_cnt_r <= 16'd0;
            stats_bus_r <= 96'd0;
            stats_tgl_r <= 1'b0;
        end else if (!enable) begin
            frame_cnt_r <= 16'd0;
            stats_bus_r <= 96'd0;
            stats_tgl_r <= 1'b0;
        end else begin
            if (vs_rise) begin
                frame_cnt_r <= frame_cnt_r + 1'b1;
                // Latch stats_bus at vs_rise (1 cycle before stats_tgl flips)
                stats_bus_r <= {
                    row450_R_acc, row450_L_acc,
                    row360_R_acc, row360_L_acc,
                    row180_R_acc, row180_L_acc,
                    row90_R_acc,  row90_L_acc,
                    edge_cnt_acc,
                    (frame_cnt_r + 16'd1)
                };
            end

            if (vs_rise_d1) begin
                stats_tgl_r <= ~stats_tgl_r;
            end
        end
    end

    assign stats_bus = stats_bus_r;
    assign stats_tgl = stats_tgl_r;

endmodule
