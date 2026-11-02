`timescale 1ns/1ps
//////////////////////////////////////////////////////////////////////////////
// rt_disp_win_reader_rgb.v  (20261026 cam)
//
// Window variant of rt_disp_reader for ONE RGB565 plane (window 0 of the quad
// display: the cam1 / FMC view).  Same DDR3 AXI read engine, the same 5 stage
// scan-out pipeline, the same cfg shadow latch / commit lock / frame ack
// handshake as rt_disp_win_reader.v (NV12); only the pixel format differs:
//
//   - one plane : 960 pixels x 2 byte = 1920 byte per line
//                 = 60 words of 32 byte (16 pixels per 256 bit word)
//   - stride    : 1920 byte, fixed to the RGB plane (the cfg_stride input is
//                 kept for pin compatibility but is NOT used here, so the
//                 NV12 quad windows can keep 0x80C = 960)
//   - no UV plane : cfg_uv_off is unused
//   - 565 -> 888 : high bit replication only (no multiply, no divide)
//   - address   : cfg_base + row*1920 + word*32   (folded crop offsets are
//                 done by rt_disp_top exactly as for the NV12 windows)
//
// Line buffers : 4 slots x 64 words x 256 bit (single clock domain pair), the
//                line row lives in slot row[1:0].
//////////////////////////////////////////////////////////////////////////////
module rt_disp_win_reader_rgb #(
    parameter H_ACT   = 1920,       // full raster width  (timing only)
    parameter V_ACT   = 1080,       // full raster height (timing only)
    parameter [11:0] WIN_X0 = 12'd0,   // window left edge, multiple of 16
    parameter [11:0] WIN_Y0 = 12'd0,   // window top edge,  multiple of 4
    parameter [11:0] WIN_W  = 12'd960, // window width,     multiple of 16
    parameter [11:0] WIN_H  = 12'd540, // window height,    multiple of 4
    parameter [1:0]  WIN_IDX= 2'd0,    // commit slot this window listens to
    // The verified OV5640 chain of the source project swaps R and B when it
    // expands 565 (hdmi_ddr_ov5640_top.v:298), i.e. the sensor delivers the
    // blue field in the high bits.  Keep the same mapping so the FMC picture
    // has the same colours as the reference design.
    parameter        RB_SWAP = 1'b1
)(
    input               pix_clk         ,
    input               pix_rst_n       ,
    // config (pclk domain)
    input               cfg_tgl         ,
    input       [15:0]  cfg_ctrl        ,
    input       [31:0]  cfg_base        ,   // DDR base of this window's slot
    input       [31:0]  cfg_stride      ,   // unused (fixed 1920 for RGB565)
    input       [31:0]  cfg_uv_off      ,   // unused (single plane)
    // commit
    input               commit_tgl      ,
    input       [1:0]   commit_slot     ,
    input       [15:0]  commit_frame_id ,
    // status (to rt_ext_regs)
    output reg          stat_tgl        ,
    output reg  [159:0] stat_bus        ,
    output wire         video_active_o  ,
    output wire         zoom_o          ,
    // timing from sync_vg (full raster)
    input               vs              ,
    input               hs              ,
    input               de              ,
    input       [11:0]  x_act           ,
    input       [11:0]  y_act           ,
    // pixel output
    output reg  [7:0]   r_out           ,
    output reg  [7:0]   g_out           ,
    output reg  [7:0]   b_out           ,
    output wire         de_out          ,
    output wire         hs_out          ,
    output wire         vs_out          ,
    // core domain
    input               core_clk        ,
    input               core_rst_n      ,
    output wire [27:0]  m_araddr        ,
    output wire [3:0]   m_arlen         ,
    output wire         m_arvalid       ,
    input               m_arready       ,
    input       [255:0] m_rdata         ,
    input               m_rlast         ,
    input               m_rvalid
);

    localparam integer WPL  = WIN_W/16;          // 60 words of 32 byte (16 px)
    localparam [6:0]   WPL7 = WPL;
    localparam [31:0]  STRIDE = WIN_W * 2;       // 1920 byte

    localparam [11:0]  X0   = WIN_X0;            // window left   (pixels)
    localparam [11:0]  X1   = WIN_X0 + WIN_W;    // window right  (exclusive)
    localparam [11:0]  Y0   = WIN_Y0;            // window top    (lines)
    localparam [11:0]  Y1   = WIN_Y0 + WIN_H;    // window bottom (exclusive)

    //------------------------------------------------------------------------
    // helpers
    //------------------------------------------------------------------------
    function [11:0] b2g12; input [11:0] b; begin b2g12 = b ^ (b>>1); end endfunction
    function [11:0] g2b12; input [11:0] g;
        begin g2b12 = g ^ (g>>1) ^ (g>>2) ^ (g>>3) ^ (g>>4) ^ (g>>5)
                        ^ (g>>6) ^ (g>>7) ^ (g>>8) ^ (g>>9) ^ (g>>10) ^ (g>>11);
        end
    endfunction
    function [7:0] b2g8; input [7:0] b; begin b2g8 = b ^ (b>>1); end endfunction
    function [7:0] g2b8; input [7:0] g;
        begin g2b8 = g ^ (g>>1) ^ (g>>2) ^ (g>>3) ^ (g>>4) ^ (g>>5) ^ (g>>6) ^ (g>>7);
        end
    endfunction

    //========================================================================
    // line buffer (dual clock) : 4 rows x 64 words
    //========================================================================
    reg [255:0] rgbuf [0:255];

    //========================================================================
    //  P I X E L   D O M A I N
    //========================================================================

    // window coordinates (full raster -> window local, wraps outside)
    reg        ac_zoom;
    wire [11:0] xw_norm = x_act - X0;
    wire [11:0] yw_norm = y_act - Y0;
    wire in_win_norm   = (x_act >= X0) && (x_act < X1) &&
                         (y_act >= Y0) && (y_act < Y1);
    wire in_win_y_norm = (y_act >= Y0) && (y_act < Y1);

    wire [11:0] xw_zoom = x_act >> 1;
    wire [11:0] yw_zoom = y_act >> 1;
    wire in_win_zoom   = (x_act < H_ACT) && (y_act < V_ACT);
    wire in_win_y_zoom = (y_act < V_ACT);

    wire [11:0] xw = ac_zoom ? xw_zoom : xw_norm;
    wire [11:0] yw = ac_zoom ? yw_zoom : yw_norm;
    wire in_win    = ac_zoom ? in_win_zoom : in_win_norm;
    wire in_win_y  = ac_zoom ? in_win_y_zoom : in_win_y_norm;

    // cross-domain debug/status wires exported from the core domain
    wire [11:0] fetched_c_gray;
    wire [7:0]  infl_c_gray;
    wire [2:0]  cst_c;

    // ---- config toggle sync + 4-cycle delayed latch + frame apply ------
    reg cfg_s1, cfg_s2, cfg_s2d;
    always @(posedge pix_clk or negedge pix_rst_n)
        if (!pix_rst_n) begin cfg_s1<=0; cfg_s2<=0; cfg_s2d<=0; end
        else            begin cfg_s1<=cfg_tgl; cfg_s2<=cfg_s1; cfg_s2d<=cfg_s2; end
    wire cfg_edge = cfg_s2 ^ cfg_s2d;

    reg [2:0] cfg_wait; reg cfg_latch;
    always @(posedge pix_clk or negedge pix_rst_n)
        if (!pix_rst_n) begin cfg_wait<=0; cfg_latch<=0; end
        else begin
            if (cfg_edge) begin cfg_wait<=3'd4; cfg_latch<=1'b1; end
            else if (cfg_wait!=0) begin cfg_wait<=cfg_wait-1; cfg_latch<=0; end
            else cfg_latch<=0;
        end

    reg [15:0] sh_ctrl; reg [31:0] sh_base;
    always @(posedge pix_clk or negedge pix_rst_n)
        if (!pix_rst_n) begin sh_ctrl<=0; sh_base<=0; end
        else if (cfg_latch) begin sh_ctrl<=cfg_ctrl; sh_base<=cfg_base; end

    reg        ac_video_en;
    reg [31:0] ac_base;

    // ---- commit sync ---------------------------------------------------
    reg cm_s1, cm_s2, cm_s2d;
    always @(posedge pix_clk or negedge pix_rst_n)
        if (!pix_rst_n) begin cm_s1<=0; cm_s2<=0; cm_s2d<=0; end
        else            begin cm_s1<=commit_tgl; cm_s2<=cm_s1; cm_s2d<=cm_s2; end
    wire cm_edge = cm_s2 ^ cm_s2d;

    reg        have_commit;
    reg [1:0]  pend_slot; reg [15:0] pend_fid;

    // ---- frame start (full raster, same instant for every window) ------
    reg de_d; reg [11:0] line_cnt; reg frame_start;
    always @(posedge pix_clk or negedge pix_rst_n)
        if (!pix_rst_n) begin de_d<=0; line_cnt<=0; frame_start<=0; end
        else begin
            de_d        <= de;
            frame_start <= 1'b0;
            if (de & ~de_d) begin
                if (y_act==12'd0) line_cnt<=12'd0;
                else              line_cnt<=line_cnt+1'b1;
            end
            else if (~de & de_d) begin
                if (line_cnt==(V_ACT-1)) frame_start<=1'b1;
            end
        end

    // ---- frame level regs ----------------------------------------------
    reg        video_active;
    reg [1:0]  cur_slot;  reg [15:0] cur_fid;
    reg [31:0] disp_frames, disp_newfr, disp_underflow;
    reg [11:0] consumed_bin;
    reg        fs_tgl; reg [99:0] fs_bus;

    reg        fs_pend, fa_int, fa_d1, fa_tgl;   // core domain
    reg        fa_px1, fa_px2;
    always @(posedge pix_clk or negedge pix_rst_n)
        if (!pix_rst_n) begin fa_px1<=0; fa_px2<=0; end
        else            begin fa_px1<=fa_tgl; fa_px2<=fa_px1; end
    wire frame_acked = (fa_px2 == fs_tgl);

    wire use_video = ac_video_en && have_commit;

    // synced debug inputs from core (declared before use)
    reg [11:0] fetched_px_g1, fetched_px_g2;
    reg [7:0]  infl_px_g1, infl_px_g2;
    reg [2:0]  cst_px1, cst_px2;
    wire [11:0] fetched_bin = g2b12(fetched_px_g2);
    wire [7:0]  inflight_bin= g2b8 (infl_px_g2);

    always @(posedge pix_clk or negedge pix_rst_n)
        if (!pix_rst_n) begin fetched_px_g1<=0; fetched_px_g2<=0; end
        else            begin fetched_px_g1<=fetched_c_gray; fetched_px_g2<=fetched_px_g1; end
    always @(posedge pix_clk or negedge pix_rst_n)
        if (!pix_rst_n) begin infl_px_g1<=0; infl_px_g2<=0; end
        else            begin infl_px_g1<=infl_c_gray; infl_px_g2<=infl_px_g1; end
    always @(posedge pix_clk or negedge pix_rst_n)
        if (!pix_rst_n) begin cst_px1<=0; cst_px2<=0; end
        else            begin cst_px1<=cst_c; cst_px2<=cst_px1; end

    wire [31:0] dbg_word = { 5'd0, cst_px2, consumed_bin[7:0],
                             fetched_bin[7:0], inflight_bin };

    always @(posedge pix_clk or negedge pix_rst_n)
    begin
        if (!pix_rst_n)
        begin
            have_commit<=0; pend_slot<=0; pend_fid<=0;
            video_active<=0; cur_slot<=0; cur_fid<=0;
            disp_frames<=0; disp_newfr<=0; disp_underflow<=0;
            consumed_bin<=0;
            fs_tgl<=0; fs_bus<=100'd0;
            ac_video_en<=0; ac_base<=0;
            ac_zoom<=1'b0;
        end
        else
        begin
            // only the commit addressed to this window switches the frame
            if (cm_edge && (commit_slot == WIN_IDX))
                begin have_commit<=1'b1; pend_slot<=commit_slot; pend_fid<=commit_frame_id; end

            if ((~de & de_d) && in_win_y && (yw != (WIN_H-12'd1)) && (!ac_zoom || y_act[0]))
                consumed_bin <= consumed_bin + 1'b1;

            if ((de & ~de_d) && in_win_y && video_active &&
                !(frame_acked && (fetched_bin > yw)))
                disp_underflow <= disp_underflow + 1'b1;

            if (frame_start)
            begin
                ac_video_en <= sh_ctrl[0];
                ac_base     <= sh_base;
                ac_zoom     <= sh_ctrl[7];

                disp_frames <= disp_frames + 1'b1;
                consumed_bin<= 12'd0;

                if (use_video)
                begin
                    video_active <= 1'b1;
                    if ((pend_slot!=cur_slot) || (pend_fid!=cur_fid)) begin
                        cur_slot <= pend_slot; cur_fid <= pend_fid;
                        disp_newfr <= disp_newfr + 1'b1;
                    end
                end
                else video_active <= 1'b0;

                // same 100 bit layout as the NV12 reader : [99:97]=0,
                // [96]=use_video, [95:64]=uv_off (unused), [63:32]=stride
                // (unused, fixed 1920), [31:0]=base
                // 20261027 cam : fs_bus must carry the just-latched shadow base (ac_base is one frame late)
                fs_bus <= { 3'b0, (sh_ctrl[0] && have_commit), 32'd0, 32'd0, sh_base };
                fs_tgl <= ~fs_tgl;

                stat_bus <= { 13'd0, dbg_word,
                              disp_underflow, disp_newfr, disp_frames,
                              (use_video?pend_fid:cur_fid),
                              (use_video?1'b1:1'b0),
                              (use_video?pend_slot:cur_slot) };
                stat_tgl <= ~stat_tgl;
            end
        end
    end

    assign video_active_o = video_active;
    assign zoom_o         = ac_zoom;

    // ---- line ready / black -------------------------------------------
    reg line_ready;
    always @(posedge pix_clk or negedge pix_rst_n)
        if (!pix_rst_n) line_ready<=0;
        else if ((de & ~de_d) && in_win_y) line_ready <= frame_acked && (fetched_bin > yw);

    // ---- buffer read (stage0 -> stage1) --------------------------------
    reg [255:0] rgb_word;
    reg [11:0]  x_d1, y_d1;
    wire [5:0]  ywadr = xw[9:4];                 // 32 byte word 0..59

    always @(posedge pix_clk)
        rgb_word <= rgbuf [{yw[1:0], ywadr}];

    always @(posedge pix_clk or negedge pix_rst_n)
        if (!pix_rst_n) begin x_d1<=0; y_d1<=0; end
        else            begin x_d1<=xw; y_d1<=yw; end

    // ---- control pipeline (5 deep) ------------------------------------
    reg [4:0] de_sr, hs_sr, vs_sr, va_sr, rd_sr, wi_sr;
    always @(posedge pix_clk or negedge pix_rst_n)
        if (!pix_rst_n) begin de_sr<=0; hs_sr<=0; vs_sr<=0; va_sr<=0; rd_sr<=0; wi_sr<=0; end
        else begin
            de_sr <= {de_sr[3:0], de};
            hs_sr <= {hs_sr[3:0], hs};
            vs_sr <= {vs_sr[3:0], vs};
            va_sr <= {va_sr[3:0], video_active};
            rd_sr <= {rd_sr[3:0], line_ready};
            wi_sr <= {wi_sr[3:0], in_win};
        end

    // stage1: pick the 16 bit RGB565 pixel (little endian, 2 byte per pixel)
    wire [15:0] px1 = rgb_word [ {x_d1[3:0], 4'b0000} +: 16];

    // stage2: 565 -> 888 by high bit replication (r:5->8, g:6->8, b:5->8)
    wire [7:0] r1 = RB_SWAP ? {px1[4:0],  px1[4:2]}  : {px1[15:11], px1[15:13]};
    wire [7:0] g1 =            {px1[10:5], px1[10:9]};
    wire [7:0] b1 = RB_SWAP ? {px1[15:11], px1[15:13]} : {px1[4:0],  px1[4:2]};

    reg [7:0] r2, g2, b2;
    reg [7:0] r3, g3, b3;
    reg [7:0] r4, g4, b4;
    always @(posedge pix_clk or negedge pix_rst_n)
        if (!pix_rst_n) begin r2<=0; g2<=0; b2<=0; r3<=0; g3<=0; b3<=0;
                               r4<=0; g4<=0; b4<=0; end
        else begin
            r2 <= r1; g2 <= g1; b2 <= b1;
            r3 <= r2; g3 <= g2; b3 <= b2;
            r4 <= r3; g4 <= g3; b4 <= b3;
        end

    // stage4 : output register (window gate + line ready, same phase as the
    // NV12 reader : outside the window or before the line is fetched -> black)
    always @(posedge pix_clk or negedge pix_rst_n)
        if (!pix_rst_n)  begin r_out<=0; g_out<=0; b_out<=0; end
        else if (wi_sr[3]) begin
            r_out <= rd_sr[3] ? r4 : 8'd0;
            g_out <= rd_sr[3] ? g4 : 8'd0;
            b_out <= rd_sr[3] ? b4 : 8'd0;
        end
        else             begin r_out<=8'd0; g_out<=8'd0; b_out<=8'd0; end

    assign de_out = de_sr[4] && wi_sr[4];
    assign hs_out = hs_sr[4];
    assign vs_out = vs_sr[4];

    //========================================================================
    //  C O R E   D O M A I N
    //========================================================================
    reg cfs_s1, cfs_s2, cfs_s2d;
    always @(posedge core_clk or negedge core_rst_n)
        if (!core_rst_n) begin cfs_s1<=0; cfs_s2<=0; cfs_s2d<=0; end
        else             begin cfs_s1<=fs_tgl; cfs_s2<=cfs_s1; cfs_s2d<=cfs_s2; end
    wire cfs_edge = cfs_s2 ^ cfs_s2d;

    // consumed (pixel -> core), gray code registered in the source domain
    reg  [11:0] consumed_gray_r;
    always @(posedge pix_clk or negedge pix_rst_n)
        if (!pix_rst_n) consumed_gray_r <= 0;
        else            consumed_gray_r <= b2g12(consumed_bin);
    reg  [11:0] cons_s1, cons_s2;
    always @(posedge core_clk or negedge core_rst_n)
        if (!core_rst_n) begin cons_s1<=0; cons_s2<=0; end
        else             begin cons_s1<=consumed_gray_r; cons_s2<=cons_s1; end
    wire [11:0] consumed_c = g2b12(cons_s2);

    // core state / counters (also exported to pixel)
    localparam C_IDLE=3'd0, C_DRAIN=3'd1, C_LINE=3'd2, C_AR=3'd3, C_R=3'd4;
    reg [2:0]  cst;
    reg [11:0] cy;
    reg [6:0]  c_word;
    reg [3:0]  c_arlen;
    reg [31:0] c_pbase;
    reg [31:0] c_slotstart;
    reg        c_video;
    reg [11:0] fetched_bin_reg;
    reg [7:0]  inflight;

    // gray code registered in the source (core) domain before crossing
    reg [11:0] fetched_gray_r;
    reg [7:0]  infl_gray_r;
    always @(posedge core_clk or negedge core_rst_n)
        if (!core_rst_n) begin fetched_gray_r<=0; infl_gray_r<=0; end
        else             begin fetched_gray_r<=b2g12(fetched_bin_reg); infl_gray_r<=b2g8(inflight); end
    assign fetched_c_gray = fetched_gray_r;
    assign infl_c_gray    = infl_gray_r;
    assign cst_c          = cst;

    // ack toggle delayed 2 cycles so it never overtakes the fetched_gray_r reset
    always @(posedge core_clk or negedge core_rst_n)
        if (!core_rst_n) begin fa_d1<=0; fa_tgl<=0; end
        else             begin fa_d1<=fa_int; fa_tgl<=fa_d1; end

    // row * stride, stride = WIN_W*2 (1920 byte for the 960 pixel window).
    // A constant multiply, so it folds into shifts/adds (no multiplier/DSP).
    wire [31:0] cy_off = cy * STRIDE;

    always @(posedge core_clk or negedge core_rst_n)
    begin
        if (!core_rst_n)
        begin
            cst<=C_IDLE; cy<=0; c_word<=0; c_pbase<=0;
            c_slotstart<=0;
            c_video<=0;
            fetched_bin_reg<=0; inflight<=0;
            fs_pend<=0; fa_int<=0;
        end
        else
        begin
            case (cst)
                C_IDLE: if (cfs_edge || fs_pend) cst <= C_DRAIN;

                C_DRAIN: if ((inflight==8'd0) && (consumed_c==12'd0)) begin
                             fs_pend<=1'b0; fa_int<=~fa_int;
                             c_slotstart<=fs_bus[31:0];
                             c_video    <=fs_bus[96];
                             fetched_bin_reg<=12'd0;
                             cy<=12'd0;
                             cst <= fs_bus[96] ? C_LINE : C_IDLE;
                         end

                C_LINE: if (fs_pend || cfs_edge) cst <= C_DRAIN;   // abandon an unfinished frame
                        else if (cy>=WIN_H) cst <= C_IDLE;
                        else if ({4'd0,cy} < (consumed_c + 12'd4)) begin
                             c_word<=0;
                             c_pbase<=c_slotstart + cy_off;
                             cst<=C_AR;
                         end

                C_AR: if (m_arready) begin
                          inflight <= inflight + {4'd0,c_arlen} + 8'd1;
                          cst <= C_R;
                      end

                C_R: if (m_rvalid) begin
                         inflight <= inflight - 8'd1;
                         if (m_rlast) begin
                             if ((c_word + 7'd1) == WPL7) begin
                                 fetched_bin_reg<=fetched_bin_reg+12'd1;
                                 cy<=cy+12'd1;
                                 cst<=C_LINE;
                             end
                             else begin
                                 c_word <= c_word + 7'd1;
                                 cst    <= C_AR;
                             end
                         end
                         else c_word <= c_word + 7'd1;
                     end
                default: cst<=C_IDLE;
            endcase
            if (cfs_edge) fs_pend <= 1'b1;   // after the case so a new edge wins over the clear
        end
    end

    always @(*)
        if ((WPL - c_word) > 16) c_arlen = 4'd15;
        else                     c_arlen = (WPL - c_word - 1);

    wire [31:0] c_byteaddr = c_pbase + {c_word, 5'b0};
    assign m_araddr  = c_byteaddr[29:2];
    assign m_arlen   = c_arlen;
    assign m_arvalid = (cst==C_AR);

    // ---- store ---------------------------------------------------------
    always @(posedge core_clk)
    begin
        if (m_rvalid && (cst==C_R))
            rgbuf [{cy[1:0], c_word[5:0]}] <= m_rdata;
    end

endmodule
