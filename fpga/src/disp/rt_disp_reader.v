`timescale 1ns/1ps
//////////////////////////////////////////////////////////////////////////////
// rt_disp_reader.v  (20261018 disp)
// Read an NV12 frame out of DDR3 through the display port and scan it out as
// RGB video.  Also generates the built-in test pattern when VIDEO_EN=0 or
// PAT_FORCE=1.
//
//   pixel domain: frame start / timing / line-buffer read / CSC / pattern
//   core  domain: DDR3 AXI read master feeding the line buffers
//
// Line buffers : Y and UV each 4 slots x 64 words x 256 bit (dual clock).
//                line y is stored in slot y[1:0].
//////////////////////////////////////////////////////////////////////////////
module rt_disp_reader #(
    parameter H_ACT = 1920,
    parameter V_ACT = 1080
)(
    input               pix_clk         ,
    input               pix_rst_n       ,
    // config (pclk domain)
    input               cfg_tgl         ,
    input       [15:0]  cfg_ctrl        ,
    input       [31:0]  cfg_fb_base     ,
    input       [31:0]  cfg_slot_size   ,
    input       [31:0]  cfg_stride      ,
    input       [31:0]  cfg_uv_off      ,
    // commit
    input               commit_tgl      ,
    input       [1:0]   commit_slot     ,
    input       [15:0]  commit_frame_id ,
    // status (to rt_ext_regs)
    output reg          stat_tgl        ,
    output reg  [159:0] stat_bus        ,
    output wire         video_active_o  ,
    // timing from sync_vg
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

    localparam integer WPL  = H_ACT/32;          // words per line per plane
    localparam [6:0]   WPL7 = WPL;               // 7-bit copy for compares
    localparam integer BARW = H_ACT/8;           // test-bar width
    localparam integer FMOD = ((H_ACT-64)/8);    // square x period

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
    function [127:0] dwrev; input [127:0] x;
        begin dwrev = {x[31:0], x[63:32], x[95:64], x[127:96]}; end
    endfunction
    function [31:0] byrev; input [31:0] x;
        begin byrev = {x[7:0], x[15:8], x[23:16], x[31:24]}; end
    endfunction
    function [7:0] clip8; input signed [31:0] v; reg signed [31:0] s;
        begin s = v >>> 8; clip8 = (s<0)?8'd0:((s>255)?8'd255:s[7:0]); end
    endfunction

    //========================================================================
    // line buffers (dual clock)
    //========================================================================
    reg [255:0] ybuf [0:255];
    reg [255:0] uvbuf[0:255];

    //========================================================================
    //  P I X E L   D O M A I N
    //========================================================================

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

    reg [15:0] sh_ctrl; reg [31:0] sh_base, sh_slotsz, sh_stride, sh_uvoff;
    always @(posedge pix_clk or negedge pix_rst_n)
        if (!pix_rst_n) begin sh_ctrl<=0; sh_base<=0; sh_slotsz<=0; sh_stride<=0; sh_uvoff<=0; end
        else if (cfg_latch) begin
            sh_ctrl<=cfg_ctrl; sh_base<=cfg_fb_base; sh_slotsz<=cfg_slot_size;
            sh_stride<=cfg_stride; sh_uvoff<=cfg_uv_off;
        end

    reg        ac_video_en, ac_pat_force, ac_osd_en, ac_csc, ac_byte, ac_dw, ac_half;
    reg [31:0] ac_base, ac_slotsz, ac_stride, ac_uvoff;

    // ---- commit sync ---------------------------------------------------
    reg cm_s1, cm_s2, cm_s2d;
    always @(posedge pix_clk or negedge pix_rst_n)
        if (!pix_rst_n) begin cm_s1<=0; cm_s2<=0; cm_s2d<=0; end
        else            begin cm_s1<=commit_tgl; cm_s2<=cm_s1; cm_s2d<=cm_s2; end
    wire cm_edge = cm_s2 ^ cm_s2d;

    reg        have_commit;
    reg [1:0]  pend_slot; reg [15:0] pend_fid;

    // ---- frame start ---------------------------------------------------
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
    reg [11:0] frame_mod, sqx;
    reg        fs_tgl; reg [99:0] fs_bus;

    // 20261018 review: core acknowledges each frame start (fa_tgl) after it has reset its
    // fetched count; until then the pixel side treats every line as not ready, so a stale
    // count from the previous frame is never trusted.
    reg        fs_pend, fa_int, fa_d1, fa_tgl;   // core domain (logic in the core section)
    reg        fa_px1, fa_px2;
    always @(posedge pix_clk or negedge pix_rst_n)
        if (!pix_rst_n) begin fa_px1<=0; fa_px2<=0; end
        else            begin fa_px1<=fa_tgl; fa_px2<=fa_px1; end
    wire frame_acked = (fa_px2 == fs_tgl);

    wire use_video = ac_video_en && !ac_pat_force && have_commit;
    wire [1:0] slot_next = use_video ? pend_slot : cur_slot;

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
            consumed_bin<=0; frame_mod<=0; sqx<=0;
            fs_tgl<=0; fs_bus<=100'd0;
            ac_video_en<=0; ac_pat_force<=0; ac_osd_en<=0; ac_csc<=0;
            ac_byte<=0; ac_dw<=0; ac_half<=0;
            ac_base<=0; ac_slotsz<=0; ac_stride<=0; ac_uvoff<=0;
        end
        else
        begin
            if (cm_edge) begin have_commit<=1'b1; pend_slot<=commit_slot; pend_fid<=commit_frame_id; end

            if ((~de & de_d) && (line_cnt!=(V_ACT-1)))
                consumed_bin <= consumed_bin + 1'b1;

            if ((de & ~de_d) && video_active && !(frame_acked && (fetched_bin > {4'd0,y_act})))
                disp_underflow <= disp_underflow + 1'b1;

            if (frame_start)
            begin
                // apply shadow config
                ac_video_en <= sh_ctrl[0]; ac_pat_force<=sh_ctrl[1];
                ac_osd_en   <= sh_ctrl[2]; ac_csc      <=sh_ctrl[4];
                ac_byte     <= sh_ctrl[12]; ac_dw      <=sh_ctrl[13];
                ac_half     <= sh_ctrl[14];
                ac_base     <= sh_base; ac_slotsz<=sh_slotsz;
                ac_stride   <= sh_stride; ac_uvoff<=sh_uvoff;

                disp_frames <= disp_frames + 1'b1;
                consumed_bin<= 12'd0;
                sqx         <= {frame_mod[8:0], 3'b000};  // frame_mod*8 = (DISP_FRAMES*8) mod (H_ACT-64)
                if (frame_mod == (FMOD-1)) frame_mod<=0; else frame_mod<=frame_mod+1'b1;

                if (use_video)
                begin
                    video_active <= 1'b1;
                    if ((pend_slot!=cur_slot) || (pend_fid!=cur_fid)) begin
                        cur_slot <= pend_slot; cur_fid <= pend_fid;
                        disp_newfr <= disp_newfr + 1'b1;
                    end
                end
                else video_active <= 1'b0;

                fs_bus <= { ac_byte, ac_dw, ac_half, use_video,   // 20261018 review: same flag as video_active<=use_video
                            ac_uvoff, ac_stride,
                            (ac_base + ({30'd0, slot_next} * ac_slotsz)) };
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

    // square x = (DISP_FRAMES*8) mod (H_ACT-64) = frame_mod*8
    // (assigned at frame start above via frame_mod)
    assign video_active_o = video_active;

    // ---- line ready / black -------------------------------------------
    reg line_ready;
    always @(posedge pix_clk or negedge pix_rst_n)
        if (!pix_rst_n) line_ready<=0;
        else if (de & ~de_d) line_ready <= frame_acked && (fetched_bin > {4'd0, y_act});

    // ---- buffer read (stage0 -> stage1) --------------------------------
    reg [255:0] y_word, uv_word;
    reg [11:0]  x_d1, y_d1;
    wire [5:0]  ywadr = x_act[10:5];

    always @(posedge pix_clk)
    begin
        y_word  <= ybuf [{y_act[1:0], ywadr}];
        uv_word <= uvbuf[{y_act[1:0], ywadr}];
    end
    always @(posedge pix_clk or negedge pix_rst_n)
        if (!pix_rst_n) begin x_d1<=0; y_d1<=0; end
        else            begin x_d1<=x_act; y_d1<=y_act; end

    // ---- control pipeline (5 deep) ------------------------------------
    reg [4:0] de_sr, hs_sr, vs_sr, va_sr, rd_sr;
    always @(posedge pix_clk or negedge pix_rst_n)
        if (!pix_rst_n) begin de_sr<=0; hs_sr<=0; vs_sr<=0; va_sr<=0; rd_sr<=0; end
        else begin
            de_sr <= {de_sr[3:0], de};
            hs_sr <= {hs_sr[3:0], hs};
            vs_sr <= {vs_sr[3:0], vs};
            va_sr <= {va_sr[3:0], video_active};
            rd_sr <= {rd_sr[3:0], line_ready};
        end

    // stage1: swap the 256-bit word then select bytes + test pattern
    function [255:0] swapw;
        input [255:0] x; input h, dw, by;
        reg [255:0] a, b, c;
        begin
            a = h ? {x[127:0], x[255:128]} : x;
            b = dw ? { dwrev(a[255:128]), dwrev(a[127:0]) } : a;
            c = by ? { byrev(b[255:224]), byrev(b[223:192]), byrev(b[191:160]),
                       byrev(b[159:128]), byrev(b[127:96]),  byrev(b[95:64]),
                       byrev(b[63:32]),   byrev(b[31:0]) } : b;
            swapw = c;
        end
    endfunction

    wire [255:0] y_sw = swapw(y_word , ac_half, ac_dw, ac_byte);
    wire [255:0] u_sw = swapw(uv_word, ac_half, ac_dw, ac_byte);

    wire [4:0] xb = x_d1[4:0];
    wire [4:0] ub = {x_d1[4:1],1'b0};
    wire [4:0] vb = ub + 5'd1;
    wire [7:0] yb_v = y_sw [ {xb,3'b000} +: 8];
    wire [7:0] ub_v = u_sw [ {ub,3'b000} +: 8];
    wire [7:0] vb_v = u_sw [ {vb,3'b000} +: 8];

    wire [11:0] th1=BARW, th2=BARW*2, th3=BARW*3, th4=BARW*4,
                th5=BARW*5, th6=BARW*6, th7=BARW*7;
    wire [2:0] bar = (x_d1<th1)?3'd0:(x_d1<th2)?3'd1:(x_d1<th3)?3'd2:
                     (x_d1<th4)?3'd3:(x_d1<th5)?3'd4:(x_d1<th6)?3'd5:
                     (x_d1<th7)?3'd6:3'd7;
    reg [7:0] bar_r, bar_g, bar_b;
    always @(*)
        case (bar)
            3'd0: begin bar_r=8'd255; bar_g=8'd255; bar_b=8'd255; end
            3'd1: begin bar_r=8'd255; bar_g=8'd255; bar_b=8'd0;   end
            3'd2: begin bar_r=8'd0;   bar_g=8'd255; bar_b=8'd255; end
            3'd3: begin bar_r=8'd0;   bar_g=8'd255; bar_b=8'd0;   end
            3'd4: begin bar_r=8'd255; bar_g=8'd0;   bar_b=8'd255; end
            3'd5: begin bar_r=8'd255; bar_g=8'd0;   bar_b=8'd0;   end
            3'd6: begin bar_r=8'd0;   bar_g=8'd0;   bar_b=8'd255; end
            default:begin bar_r=8'd0; bar_g=8'd0; bar_b=8'd0;      end
        endcase

    wire in_grid1 = ((x_d1 % 12'd120)==12'd0) || ((y_d1 % 12'd120)==12'd0);
    wire in_sq1   = (y_d1>=(V_ACT-120)) && (y_d1<(V_ACT-120+64)) &&
                    (x_d1>=sqx) && (x_d1<(sqx+12'd64));
    wire [7:0] pr1 = in_sq1?8'd255:(in_grid1?8'd128:bar_r);
    wire [7:0] pg1 = in_sq1?8'd255:(in_grid1?8'd128:bar_g);
    wire [7:0] pb1 = in_sq1?8'd255:(in_grid1?8'd128:bar_b);

    reg [7:0] by1, bu1, bv1, pr1r, pg1r, pb1r;
    always @(posedge pix_clk or negedge pix_rst_n)
        if (!pix_rst_n) begin by1<=0; bu1<=0; bv1<=0; pr1r<=0; pg1r<=0; pb1r<=0; end
        else begin
            by1<=yb_v; bu1<=ub_v; bv1<=vb_v;
            pr1r<=pr1; pg1r<=pg1; pb1r<=pb1;
        end

    // stage2: differences + pattern delay
    reg signed [15:0] C2, D2, E2;
    reg [7:0] pr2, pg2, pb2;
    always @(posedge pix_clk or negedge pix_rst_n)
        if (!pix_rst_n) begin C2<=0; D2<=0; E2<=0; pr2<=0; pg2<=0; pb2<=0; end
        else begin
            C2 <= {8'd0,by1} - 16'sd16;
            D2 <= {8'd0,bu1} - 16'sd128;
            E2 <= {8'd0,bv1} - 16'sd128;
            pr2<=pr1r; pg2<=pg1r; pb2<=pb1r;
        end

    // stage3: products (coefficients selected by CSC mode)
    wire signed [15:0] kD  = ac_csc ? 16'sd100 : 16'sd55;
    wire signed [15:0] kD2 = ac_csc ? 16'sd516 : 16'sd541;
    wire signed [15:0] kE  = ac_csc ? 16'sd409 : 16'sd459;
    wire signed [15:0] kE2 = ac_csc ? 16'sd208 : 16'sd136;

    reg signed [31:0] pY3, pDD3, pD2D3, pEE3, pE2E3;
    reg [7:0] pr3, pg3, pb3;
    always @(posedge pix_clk or negedge pix_rst_n)
        if (!pix_rst_n) begin pY3<=0; pDD3<=0; pD2D3<=0; pEE3<=0; pE2E3<=0;
                              pr3<=0; pg3<=0; pb3<=0; end
        else begin
            pY3   <= 32'sd298 * C2;
            pDD3  <= kD  * D2;
            pD2D3 <= kD2 * D2;
            pEE3  <= kE  * E2;
            pE2E3 <= kE2 * E2;
            pr3<=pr2; pg3<=pg2; pb3<=pb2;
        end

    // stage4 final : sum + clip (combinational) -> registered output
    wire [7:0] vid_r = clip8(pY3 + pEE3  + 32'sd128);
    wire [7:0] vid_g = clip8(pY3 - pDD3  - pE2E3 + 32'sd128);
    wire [7:0] vid_b = clip8(pY3 + pD2D3 + 32'sd128);

    wire [7:0] out_r = va_sr[3] ? (rd_sr[3]?vid_r:8'd0) : pr3;
    wire [7:0] out_g = va_sr[3] ? (rd_sr[3]?vid_g:8'd0) : pg3;
    wire [7:0] out_b = va_sr[3] ? (rd_sr[3]?vid_b:8'd0) : pb3;

    always @(posedge pix_clk or negedge pix_rst_n)
        if (!pix_rst_n) begin r_out<=0; g_out<=0; b_out<=0; end
        else            begin r_out<=out_r; g_out<=out_g; b_out<=out_b; end

    assign de_out = de_sr[4];
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

    // consumed (pixel -> core)
    // 20261018 review: gray code registered in the source (pixel) domain before crossing
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
    reg        c_plane;
    reg [6:0]  c_word;
    reg [3:0]  c_arlen;
    reg [31:0] c_pbase;
    reg [31:0] c_slotstart, c_stride, c_uvoff;
    reg        c_video, c_half, c_dw, c_byte;
    reg [11:0] fetched_bin_reg;
    reg [7:0]  inflight;

    // 20261018 review: gray code registered in the source (core) domain before crossing
    reg [11:0] fetched_gray_r;
    reg [7:0]  infl_gray_r;
    always @(posedge core_clk or negedge core_rst_n)
        if (!core_rst_n) begin fetched_gray_r<=0; infl_gray_r<=0; end
        else             begin fetched_gray_r<=b2g12(fetched_bin_reg); infl_gray_r<=b2g8(inflight); end
    assign fetched_c_gray = fetched_gray_r;
    assign infl_c_gray    = infl_gray_r;
    assign cst_c          = cst;

    // 20261018 review: ack toggle delayed 2 cycles so it never overtakes the fetched_gray_r reset
    always @(posedge core_clk or negedge core_rst_n)
        if (!core_rst_n) begin fa_d1<=0; fa_tgl<=0; end
        else             begin fa_d1<=fa_int; fa_tgl<=fa_d1; end

    always @(posedge core_clk or negedge core_rst_n)
    begin
        if (!core_rst_n)
        begin
            cst<=C_IDLE; cy<=0; c_plane<=0; c_word<=0; c_pbase<=0;
            c_slotstart<=0; c_stride<=0; c_uvoff<=0;
            c_video<=0; c_half<=0; c_dw<=0; c_byte<=0;
            fetched_bin_reg<=0; inflight<=0;
            fs_pend<=0; fa_int<=0;
        end
        else
        begin
            case (cst)
                C_IDLE: if (cfs_edge || fs_pend) cst <= C_DRAIN;

                C_DRAIN: if ((inflight==8'd0) && (consumed_c==12'd0)) begin
                             fs_pend<=1'b0; fa_int<=~fa_int;   // 20261018 review
                             c_slotstart<=fs_bus[31:0];
                             c_stride   <=fs_bus[63:32];
                             c_uvoff    <=fs_bus[95:64];
                             c_video    <=fs_bus[96];
                             c_half     <=fs_bus[97];
                             c_dw       <=fs_bus[98];
                             c_byte     <=fs_bus[99];
                             fetched_bin_reg<=12'd0;
                             cy<=12'd0;
                             cst <= fs_bus[96] ? C_LINE : C_IDLE;
                         end

                C_LINE: if (fs_pend || cfs_edge) cst <= C_DRAIN;   // 20261018 review: abandon an unfinished frame
                        else if (cy>=V_ACT) cst <= C_IDLE;
                        else if ({4'd0,cy} < (consumed_c + 12'd4)) begin
                             c_plane<=1'b0; c_word<=0;
                             c_pbase<=c_slotstart + cy*c_stride;
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
                                 if (c_plane==1'b0) begin
                                     c_plane<=1'b1; c_word<=0;
                                     c_pbase<=c_slotstart + c_uvoff
                                              + ({20'd0,cy[11:1]})*c_stride;
                                     cst<=C_AR;
                                 end
                                 else begin
                                     fetched_bin_reg<=fetched_bin_reg+12'd1;
                                     cy<=cy+12'd1;
                                     cst<=C_LINE;
                                 end
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
            if (cfs_edge) fs_pend <= 1'b1;   // 20261018 review: after the case so a new edge wins over the clear
        end
    end

    always @(*)
        if ((WPL - c_word) > 16) c_arlen = 4'd15;
        else                     c_arlen = (WPL - c_word - 1);

    wire [31:0] c_byteaddr = c_pbase + {c_word, 5'b0};
    assign m_araddr  = c_byteaddr[29:2];
    assign m_arlen   = c_arlen;
    assign m_arvalid = (cst==C_AR);

    // ---- store (raw; swap is applied in the pixel read path) -----------
    always @(posedge core_clk)
    begin
        if (m_rvalid && (cst==C_R)) begin
            if (c_plane==1'b0) ybuf [{cy[1:0], c_word[5:0]}] <= m_rdata;
            else               uvbuf[{cy[1:0], c_word[5:0]}] <= m_rdata;
        end
    end

endmodule
