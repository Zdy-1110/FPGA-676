`timescale 1ns/1ps
//////////////////////////////////////////////////////////////////////////////
// rt_zoom_ana.v  (20261102 zoom)
// Analysis stream extraction module for ZOOM2X mode.
//
// In ZOOM2X mode (zoom=1), slot0 is 2x zoomed (1920x1080) on the display, but
// downstream analytics (rt_night, rt_lane_det, rt_zebra_det, rt_disp_stats)
// require a standard continuous 960x540 frame (540 lines x 960 pixels).
//
// Mechanism:
// - A 1024x24-bit dual-port line buffer (infers DRM on Pango PG2L100H).
// - On even raster lines (line_parity=0, y_act=0,2,...):
//   When de_in is high, sample one source pixel on every even pixel clock
//   (x_in_cnt[0]==0), writing 960 pixels into line_buf[0..959].
// - On odd raster lines (line_parity=1, y_act=1,3,...):
//   Starting at de_rise, read out line_buf[0..959] consecutively for 960
//   clocks, generating ana_r/g/b and ana_de (exactly 960 active clocks).
// - Exactly 540 lines per frame, 960 pixels per line.
// - When zoom=0, pass-through with zero latency (bit-for-bit identical).
//////////////////////////////////////////////////////////////////////////////
module rt_zoom_ana #(
    parameter SRC_W = 960,
    parameter SRC_H = 540,
    parameter DST_W = 1920,
    parameter DST_H = 1080
)(
    input  wire        pix_clk   ,
    input  wire        pix_rst_n ,
    input  wire        zoom      ,
    // display stream in (slot0)
    input  wire [7:0]  r_in      ,
    input  wire [7:0]  g_in      ,
    input  wire [7:0]  b_in      ,
    input  wire        de_in     ,
    input  wire        hs_in     ,
    input  wire        vs_in     ,
    // analysis stream out (to rt_night / lane / zebra / stats)
    output wire [7:0]  r_out     ,
    output wire [7:0]  g_out     ,
    output wire [7:0]  b_out     ,
    output wire        de_out    ,
    output wire        hs_out    ,
    output wire        vs_out
);

    // 1024 x 24 bit RAM (inferred Block RAM / DRM)
    reg [23:0] line_buf [0:1023];
    reg [23:0] ram_rdata;

    // Edge detections
    reg vs_d;
    reg de_d;
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            vs_d <= 1'b0;
            de_d <= 1'b0;
        end else begin
            vs_d <= vs_in;
            de_d <= de_in;
        end
    end
    wire vs_rise = vs_in & ~vs_d;
    wire de_rise = de_in & ~de_d;
    wire de_fall = ~de_in & de_d;

    // Raster line tracking
    reg        line_parity; // 0: even raster line (write), 1: odd raster line (read)
    reg [11:0] line_cnt;

    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            line_parity <= 1'b0;
            line_cnt    <= 12'd0;
        end else if (vs_rise) begin
            line_parity <= 1'b0;
            line_cnt    <= 12'd0;
        end else if (de_fall) begin
            line_parity <= ~line_parity;
            line_cnt    <= line_cnt + 1'b1;
        end
    end

    // Pixel counter along active line
    reg [11:0] x_in_cnt;
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            x_in_cnt <= 12'd0;
        end else if (!de_in) begin
            x_in_cnt <= 12'd0;
        end else begin
            x_in_cnt <= x_in_cnt + 1'b1;
        end
    end

    // Write to line buffer on even raster lines (x_in_cnt[0]==0)
    wire        wr_en   = zoom && de_in && (!line_parity) && (!x_in_cnt[0]) && (x_in_cnt < (SRC_W * 2));
    wire [9:0]  wr_addr = x_in_cnt[10:1]; // 0..959
    wire [23:0] wr_data = {r_in, g_in, b_in};

    always @(posedge pix_clk) begin
        if (wr_en)
            line_buf[wr_addr] <= wr_data;
    end

    // Read from line buffer on odd raster lines
    reg [9:0] rd_addr;
    reg       rd_active;
    reg       rd_valid;

    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            rd_addr   <= 10'd0;
            rd_active <= 1'b0;
            rd_valid  <= 1'b0;
        end else if (zoom) begin
            if (de_rise && line_parity) begin
                rd_addr   <= 10'd0;
                rd_active <= 1'b1;
                rd_valid  <= 1'b0;
            end else if (rd_active) begin
                if (rd_addr == (SRC_W - 1)) begin
                    rd_active <= 1'b0;
                end else begin
                    rd_addr   <= rd_addr + 1'b1;
                end
                rd_valid  <= 1'b1;
            end else begin
                rd_valid  <= 1'b0;
            end
        end else begin
            rd_addr   <= 10'd0;
            rd_active <= 1'b0;
            rd_valid  <= 1'b0;
        end
    end

    always @(posedge pix_clk) begin
        if (rd_active)
            ram_rdata <= line_buf[rd_addr];
    end

    // Mux outputs: zoom=1 selects analysis stream; zoom=0 passes through q0
    wire [7:0] ana_r_z  = rd_valid ? ram_rdata[23:16] : 8'd0;
    wire [7:0] ana_g_z  = rd_valid ? ram_rdata[15:8]  : 8'd0;
    wire [7:0] ana_b_z  = rd_valid ? ram_rdata[7:0]   : 8'd0;
    wire       ana_de_z = rd_valid;

    assign r_out  = zoom ? ana_r_z  : r_in;
    assign g_out  = zoom ? ana_g_z  : g_in;
    assign b_out  = zoom ? ana_b_z  : b_in;
    assign de_out = zoom ? ana_de_z : de_in;
    assign hs_out = hs_in;
    assign vs_out = vs_in;

endmodule
