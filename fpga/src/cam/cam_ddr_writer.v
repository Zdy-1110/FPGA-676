`timescale 1ns/1ps
//////////////////////////////////////////////////////////////////////////////
// cam_ddr_writer.v  (20261026 cam)
//
// OV5640 (cam1, 1280x720 RGB565) -> DDR slot0 (window 0 of the quad display).
//
//   crop   : rows    90..629  and columns 160..1119  (exactly 960 x 540,
//            no scaling - the crop is centered in the 1280x720 raster)
//   pack   : 8 pixels (8 x 16 bit = 128 bit) per word, 120 words per row
//   addr   : slot0_base + row*1920 + word*16   (byte address,
//            slot0_base = cfg_fb_base = 0x0400_0000)
//   cdc    : 2048 x 146 async FIFO, 42 MHz write side -> 125 MHz read side
//            entry = {row_in[9:0], word[6:0], data[127:0]}
//   output : o_wr_* / i_wr_ready handshake into rt_ddr_hub's camera write port
//
// The camera delivers one 16 bit RGB565 pixel per pclk_16bit cycle (the OV5640
// 8 bit port is packed 2:1 by cmos_8_16bit), so a source line is 1280 entries
// and columns 160..1119 select 960 of them.
//////////////////////////////////////////////////////////////////////////////
module cam_ddr_writer #(
    parameter integer DEPTH_AW  = 11,          // 2048 entries (was 512)
    parameter [10:0]  COL_FIRST = 11'd160,     // crop left   (pixel, inclusive)
    parameter [10:0]  COL_LAST  = 11'd1119,    // crop right  (pixel, inclusive)
    parameter [10:0]  ROW_FIRST = 11'd90,      // crop top    (line,  inclusive)
    parameter [10:0]  ROW_LAST  = 11'd629      // crop bottom (line,  inclusive)
)(
    // ---------------- control / enable (1=work, 0=off (~CAM_OFF)) -----------
    input  wire         i_cam_en,
    input  wire         i_ddr_en,
    // ---------------- camera pixel domain (pclk_16bit, ~42 MHz) -------------
    input  wire         pclk,
    input  wire         pclk_rst_n,
    input  wire         vsync,
    input  wire         de,
    input  wire [15:0]  data,
    // ---------------- DDR / hub domain (pclk_div2, 125 MHz) ----------------
    input  wire         core_clk,
    input  wire         core_rst_n,
    input  wire [31:0]  cfg_base,       // slot0 base = cfg_fb_base
    output wire         o_wr_en,
    output wire [31:0]  o_wr_addr,
    output wire [127:0] o_wr_data,
    output wire [15:0]  o_wr_be,
    input  wire         i_wr_ready,     // beat accepted by rt_ddr_hub
    // ---------------- frame boundary commit (core / hub domain) ------------
    output reg          o_commit_tgl,   // toggles once per camera frame
    output reg  [15:0]  o_commit_fid,   // camera frame counter
    output reg          o_commit_buf,   // buffer that frame was written into
    // ---------------- urgent -> hub MRd pause (core / hub domain) -----------
    output wire         o_cam_urgent,   // camera FIFO >= 128 (clear below 32)
    // ---------------- status (debug) --------------------------------------
    //   [31:20] frames that lost at least one beat (saturating)
    //   [19:10] current FIFO level / 4, [9:0] peak level of the last frame / 4
    output reg  [31:0]  o_stat
);

    //========================================================================
    // async FIFO : 2048 x {buf, row_in[9:0], word[6:0], data[127:0]}
    //========================================================================
    wire              fifo_wr_full;
    wire [DEPTH_AW:0] fifo_wr_level;
    wire              fifo_rd_empty;
    wire [145:0]      fifo_rd_data;
    wire              fifo_rd_valid;
    wire [DEPTH_AW:0] fifo_rd_level;
    reg               fifo_rd_en;

    //========================================================================
    // write side : line/column counters, crop window, 8-pixel packer
    //========================================================================
    localparam [10:0] COL_START_PX = COL_FIRST + 11'd7;  // last pixel of group 0

    reg          vs_d, de_d;
    reg  [10:0]  row;               // source line   (0..719)
    reg  [10:0]  col;               // source column (0..1279), cleared in blanking
    reg  [2:0]   ph;                // position inside the 8 pixel group
    reg  [127:0] grp;               // shift register, d0 in bits [15:0]
    reg  [6:0]   widx;              // crop word index 0..119
    reg          wr_buf;            // 20261026 cam : slot0 double buffer in use

    //------------------------------------------------------------------------
    // 20261027 cam : vsync glitch filter (pclk domain, 42 MHz)
    //   cam1's VSYNC carries 10..30 spurious rising edges per frame, each
    //   <= 37 ns wide (measured with the st1d diagnostic firmware).  Any of
    //   them would reset "row", flip "wr_buf" and fire an extra commit, which
    //   splits one frame over both buffers and tears the picture.
    //   Same scheme as the source project's vsync_filt (N_STABLE = 64), here
    //   N_STABLE = 32 : the level has to stay constant for 32 pclk cycles
    //   (32 / 42 MHz = 0.76 us) before it is accepted.  A real VSYNC is about
    //   90 us wide, a glitch <= 37 ns, so there is a > 1000x margin.
    //   Latency to the frame start : 2 sync + 32 stable = 34 pclk = 0.81 us.
    //------------------------------------------------------------------------
    localparam integer VS_STABLE = 32;

    reg  [1:0] vs_sync;             // 2 stage synchroniser (vsync_d0 is 84 MHz)
    reg  [4:0] vs_cnt;
    reg        vsync_f;             // filtered vsync
    wire       vs_synced = vs_sync[1];

    always @(posedge pclk or negedge pclk_rst_n)
        if (!pclk_rst_n) begin
            vs_sync <= 2'b00;
            vs_cnt  <= 5'd0;
            vsync_f <= 1'b0;
        end else begin
            vs_sync <= {vs_sync[0], vsync};
            if (vs_synced != vsync_f) begin
                if (vs_cnt >= (VS_STABLE-1)) begin
                    vsync_f <= vs_synced;
                    vs_cnt  <= 5'd0;
                end else begin
                    vs_cnt <= vs_cnt + 1'b1;
                end
            end else begin
                vs_cnt <= 5'd0;
            end
        end

    // 20261027 cam : sync i_cam_en from register domain to pclk domain (2-stage)
    reg  [1:0]   cam_en_sync;
    always @(posedge pclk or negedge pclk_rst_n)
        if (!pclk_rst_n) cam_en_sync <= 2'b00;
        else             cam_en_sync <= {cam_en_sync[0], i_cam_en};
    wire cam_en_p = cam_en_sync[1];

    // word = { px(n), px(n-1) ... px(n-7) } -> ascending byte order in DDR :
    // px(n-7) in bits [15:0], px(n) in bits [127:112]
    wire [127:0] word_now = {data, grp[127:16]};
    wire         in_col   = (col >= COL_START_PX) && (col <= COL_LAST);
    wire         in_row   = (row >= ROW_FIRST)    && (row <= ROW_LAST);
    wire         push_now = cam_en_p && de && (ph == 3'd7) && in_col && in_row;
    wire [9:0]   row_in   = row[9:0] - ROW_FIRST[9:0];   // 0..539, 10 bit
    wire         vs_rise  = vsync_f & ~vs_d;             // filtered frame start

    always @(posedge pclk or negedge pclk_rst_n)
        if (!pclk_rst_n) begin
            vs_d <= 1'b0; de_d <= 1'b0;
            row  <= 11'd0; col <= 11'd0; ph <= 3'd0; grp <= 128'd0; widx <= 7'd0;
            wr_buf <= 1'b0;
        end else begin
            vs_d <= vsync_f;
            de_d <= de;

            // source line counter : frame start at the FILTERED vsync rising
            // edge, one line per de falling edge, so "row" is the line being
            // received
            if (vs_rise) begin
                row    <= 11'd0;
                wr_buf <= ~wr_buf;      // next frame goes to the other buffer
            end
            else if (~de & de_d)    row <= row + 1'b1;

            // column counter and 8-pixel packer, cleared during h-blanking
            if (!de) begin
                col  <= 11'd0;
                ph   <= 3'd0;
                widx <= 7'd0;
            end else begin
                col <= col + 1'b1;
                grp <= {data, grp[127:16]};
                if (ph == 3'd7) begin
                    ph <= 3'd0;
                    if (push_now) widx <= widx + 1'b1;
                end else begin
                    ph <= ph + 1'b1;
                end
            end
        end

    rt_async_fifo #(.DW(146), .AW(DEPTH_AW)) u_cam_fifo (
        .wr_clk     (pclk),
        .wr_rst_n   (pclk_rst_n),
        .wr_en      (push_now & ~fifo_wr_full),
        .wr_data    ({wr_buf, row_in, widx, word_now}),
        .wr_full    (fifo_wr_full),
        .wr_level   (fifo_wr_level),
        .rd_clk     (core_clk),
        .rd_rst_n   (core_rst_n),
        .rd_en      (fifo_rd_en),
        .rd_data    (fifo_rd_data),
        .rd_valid   (fifo_rd_valid),
        .rd_empty   (fifo_rd_empty),
        .rd_level   (fifo_rd_level)
    );

    //========================================================================
    // read side : beat handshake to the DDR hub write port
    //========================================================================
    localparam [1:0] R_IDLE = 2'd0, R_GETA = 2'd1, R_GETB = 2'd2, R_SEND = 2'd3;

    reg  [1:0]   st;
    reg  [31:0]  addr_r;
    reg  [127:0] data_r;

    // 20261027 cam9 : sync i_cam_en & i_ddr_en to core_clk domain (2-stage)
    reg  [1:0]   cam_en_c_sync;
    reg  [1:0]   ddr_en_c_sync;
    always @(posedge core_clk or negedge core_rst_n)
        if (!core_rst_n) begin
            cam_en_c_sync <= 2'b00;
            ddr_en_c_sync <= 2'b00;
        end else begin
            cam_en_c_sync <= {cam_en_c_sync[0], i_cam_en};
            ddr_en_c_sync <= {ddr_en_c_sync[0], i_ddr_en};
        end
    wire cam_en_c   = cam_en_c_sync[1];
    wire ddr_en_c   = ddr_en_c_sync[1];
    wire drain_mode = !cam_en_c || !ddr_en_c;

    // 20261026 cam : slot0 is double buffered
    //   buf0 = cfg_base, buf1 = cfg_base + 0x00100000 (1 MB each, 2 MB total,
    //   both inside the 4 MB slot0).  Every FIFO entry carries the buffer it
    //   was captured in, so a beat can never be written into the wrong buffer.
    //   addr = cfg_base + {buf,20'b0} + row*1920 + word*16
    //        = base + (row<<11) - (row<<7) + (word<<4)
    wire        rd_buf  = fifo_rd_data[145];
    wire [31:0] rd_row  = {22'd0, fifo_rd_data[144:135]};
    wire [31:0] rd_word = {25'd0, fifo_rd_data[134:128]};
    wire [31:0] rd_addr = cfg_base + (rd_buf ? 32'h0010_0000 : 32'd0)
                          + (rd_row << 11) - (rd_row << 7) + (rd_word << 4);

    always @(posedge core_clk or negedge core_rst_n)
        if (!core_rst_n) begin
            st <= R_IDLE; fifo_rd_en <= 1'b0;
            addr_r <= 32'd0; data_r <= 128'd0;
        end else begin
            fifo_rd_en <= 1'b0;
            case (st)
                R_IDLE: begin
                    if (drain_mode) begin
                        if (!fifo_rd_empty) begin
                            fifo_rd_en <= 1'b1;
                        end
                    end else begin
                        if (!fifo_rd_empty) begin
                            fifo_rd_en <= 1'b1;
                            st         <= R_GETA;
                        end
                    end
                end
                R_GETA: st <= R_GETB;                    // fifo samples rd_en here
                R_GETB: if (fifo_rd_valid) begin
                            addr_r <= rd_addr;
                            data_r <= fifo_rd_data[127:0];
                            st     <= R_SEND;
                        end
                R_SEND: if (i_wr_ready) st <= R_IDLE;
                default: st <= R_IDLE;
            endcase
        end

    assign o_wr_en   = (st == R_SEND);
    assign o_wr_addr = addr_r;
    assign o_wr_data = data_r;
    assign o_wr_be   = 16'hFFFF;

    //========================================================================
    // 20261026 cam : frame boundary commit for display window 0 (double buffer)
    //   The camera has no host 0x814 commit, so the writer generates its own :
    //   a vsync rising edge in the pclk domain is turned into a toggle, synced
    //   into the DDR (pclk_div2) domain and turned into a commit pulse with a
    //   frame counter and the buffer that frame was written into.
    //   o_commit_buf is the buffer of the frame that just ENDED (the complete
    //   one), never the one that is about to be written : it is captured from
    //   wr_buf in the pclk domain at the vsync edge and crosses with its own
    //   2 stage synchroniser next to the frame toggle.
    //   rt_disp_top feeds the commit and the buffer base to window 0 only.
    //========================================================================
    reg  frame_tgl_p;                       // pclk domain, one toggle per frame
    reg  frame_buf_p;                       // pclk domain, buffer just finished
    reg  ft_s1, ft_s2, ft_s2d;              // pclk_div2 domain
    reg  fb_s1, fb_s2;                      // pclk_div2 domain
    reg  [1:0] ft_edge_d;
    wire ft_edge = ft_s2 ^ ft_s2d;

    always @(posedge pclk or negedge pclk_rst_n)
        if (!pclk_rst_n) begin
            frame_tgl_p <= 1'b0; frame_buf_p <= 1'b0;
        end else if (cam_en_p && vs_rise) begin     // filtered vsync only
            frame_tgl_p <= ~frame_tgl_p;
            frame_buf_p <= wr_buf;          // wr_buf still holds the old frame
        end

    // 20261027 cam : drop / FIFO peak statistics (pclk domain)
    //   drop_sticky   : a beat of this frame hit a full FIFO (beat is lost)
    //   peak_r        : highest write level since the last frame boundary
    //   last_peak_p   : the same, latched at the frame boundary
    //   drop_tgl_p    : toggles once per frame that lost at least one beat
    //                   (crosses to pclk_div2 as a toggle, no multi bit CDC)
    reg [DEPTH_AW:0] peak_r, last_peak_p;
    reg              drop_sticky;
    reg              drop_tgl_p;

    always @(posedge pclk or negedge pclk_rst_n)
        if (!pclk_rst_n) begin
            peak_r      <= {(DEPTH_AW+1){1'b0}};
            last_peak_p <= {(DEPTH_AW+1){1'b0}};
            drop_sticky <= 1'b0;
            drop_tgl_p  <= 1'b0;
        end else if (!cam_en_p) begin
            peak_r      <= {(DEPTH_AW+1){1'b0}};
            last_peak_p <= {(DEPTH_AW+1){1'b0}};
            drop_sticky <= 1'b0;
            drop_tgl_p  <= 1'b0;
        end else begin
            if (push_now && fifo_wr_full) drop_sticky <= 1'b1;
            if (fifo_wr_level > peak_r)   peak_r <= fifo_wr_level;
            if (vs_rise) begin
                if (drop_sticky) drop_tgl_p <= ~drop_tgl_p;
                drop_sticky <= 1'b0;
                last_peak_p <= (fifo_wr_level > peak_r) ? fifo_wr_level : peak_r;
                peak_r      <= {(DEPTH_AW+1){1'b0}};
            end
        end

    always @(posedge core_clk or negedge core_rst_n)
        if (!core_rst_n) begin
            ft_s1 <= 1'b0; ft_s2 <= 1'b0; ft_s2d <= 1'b0;
            fb_s1 <= 1'b0; fb_s2 <= 1'b0;
            ft_edge_d <= 2'b0;
            o_commit_tgl <= 1'b0; o_commit_fid <= 16'd0; o_commit_buf <= 1'b0;
        end else begin
            ft_s1  <= frame_tgl_p;
            ft_s2  <= ft_s1;
            ft_s2d <= ft_s2;
            fb_s1  <= frame_buf_p;
            fb_s2  <= fb_s1;
            ft_edge_d <= {ft_edge_d[0], ft_edge};
            // 20261027 cam : wait 2 core_clk after the toggle edge, fb_s2 must be settled
            if (cam_en_c && ft_edge_d[1]) begin
                o_commit_tgl <= ~o_commit_tgl;
                o_commit_fid <= o_commit_fid + 16'd1;
                o_commit_buf <= fb_s2;      // buffer the finished frame used
            end
        end

    //========================================================================
    // 20261027 cam : urgent flag to the DDR hub + statistics
    //   o_cam_urgent is raised when the camera FIFO holds >= 128 beats and is
    //   only released below 32 (hysteresis).  The hub turns it into
    //   o_issue_hold, which pauses NEW PCIe MRd requests so the DDR write
    //   FIFO drains and the camera admission opens again.
    //   o_stat : [31:20] frames that lost a beat (saturating)
    //            [19:10] current level / 4   [9:0] last frame peak / 4
    //========================================================================
    localparam [DEPTH_AW:0] CAM_URG_SET = 128;
    localparam [DEPTH_AW:0] CAM_URG_CLR = 32;

    reg cam_urgent_r;
    always @(posedge core_clk or negedge core_rst_n)
        if (!core_rst_n) cam_urgent_r <= 1'b0;
        else if (drain_mode) cam_urgent_r <= 1'b0;
        else if (fifo_rd_level >= CAM_URG_SET) cam_urgent_r <= 1'b1;
        else if (fifo_rd_level <  CAM_URG_CLR) cam_urgent_r <= 1'b0;

    assign o_cam_urgent = cam_urgent_r;

    // drop toggle + last frame peak sync
    reg              dt_s1, dt_s2, dt_s2d;
    reg [DEPTH_AW:0] pk_s1, pk_s2;
    reg [11:0]       drop_frames;

    always @(posedge core_clk or negedge core_rst_n)
        if (!core_rst_n) begin
            dt_s1 <= 1'b0; dt_s2 <= 1'b0; dt_s2d <= 1'b0;
            pk_s1 <= {(DEPTH_AW+1){1'b0}}; pk_s2 <= {(DEPTH_AW+1){1'b0}};
            drop_frames <= 12'd0;
        end else if (!cam_en_c) begin
            dt_s1 <= 1'b0; dt_s2 <= 1'b0; dt_s2d <= 1'b0;
            pk_s1 <= {(DEPTH_AW+1){1'b0}}; pk_s2 <= {(DEPTH_AW+1){1'b0}};
            drop_frames <= 12'd0;
        end else begin
            dt_s1  <= drop_tgl_p;
            dt_s2  <= dt_s1;
            dt_s2d <= dt_s2;
            pk_s1  <= last_peak_p;
            pk_s2  <= pk_s1;
            if (dt_s2 ^ dt_s2d)
                if (drop_frames != 12'hFFF) drop_frames <= drop_frames + 1'b1;
        end

    always @(posedge core_clk or negedge core_rst_n)
        if (!core_rst_n) o_stat <= 32'd0;
        else             o_stat <= { drop_frames,                // [31:20]
                                     fifo_rd_level[DEPTH_AW:2],  // [19:10] /4
                                     pk_s2[DEPTH_AW:2] };        // [9:0]   /4

endmodule
