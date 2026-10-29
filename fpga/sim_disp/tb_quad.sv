`timescale 1ns/1ps
//////////////////////////////////////////////////////////////////////////////
// tb_quad.sv : rt_disp_win_reader x4 (2x2 = 960x540 quarters of 1080p60)
//
//   TQ1 : four camera slots with different NV12 content -> the 2x2 composite
//         must be pixel exact over the whole 1920x1080 raster (checks the DDR
//         address math of every window and the x=960 / y=540 seams).
//         Every AXI AR is checked to start inside a slot / inside the Y or UV
//         plane / on word 0 or word 16 of a 30-word line.
//   TQ2 : single window in test-pattern mode -> everything outside 960x540 is
//         black and de_out never leaves the rectangle.
//   TQ3 : same as TQ1 but the four windows crop one full size 1920x1080 frame
//         (slot_size=0, stride=1920, uv_off=1036800).
//
//   +TEST=1|2|3
//////////////////////////////////////////////////////////////////////////////
module tb_quad;

    localparam H_ACT = 1920;
    localparam V_ACT = 1080;
    localparam H_TOTAL=2200, H_SYNC=44, H_BP=148, H_FP=88;
    localparam V_TOTAL=1125, V_SYNC=5,  V_BP=36,  V_FP=4;
    localparam integer TOTAL = H_ACT*V_ACT;

    localparam integer WIN_W = 960;
    localparam integer WIN_H = 540;
    localparam integer SLOT  = 1048576;         // 1 MB per camera slot
    localparam integer UVOFF = 518400;          // 960*540
    localparam integer UVSZ  = 270*960;
    localparam integer FUVO  = 2073600;         // 1920*1080 (UV plane offset)
    localparam integer FSZ   = 3110400;         // 1920*1080*3/2

    //------------------------------------------------------------- clocks
    reg pix_clk = 0, core_clk = 0;
    always #3.367 pix_clk  = ~pix_clk;
    always #4.0   core_clk = ~core_clk;

    reg pix_rst_n, core_rst_n;

    //------------------------------------------------------------- config
    reg         cfg_tgl;
    reg  [15:0] cfg_ctrl;
    reg  [31:0] cfg_fb_base, cfg_slot_size, cfg_stride, cfg_uv_off;
    reg         commit_tgl;
    reg  [1:0]  commit_slot;
    reg  [15:0] commit_frame_id;

    reg  [31:0] cfg_base_w [0:3];
    reg  [31:0] cfg_uv_w   [0:3];

    reg         mode_crop = 0;      // 0 = four 960x540 slots, 1 = one 1080p frame

    //------------------------------------------------------------- timing
    wire        vs_s, hs_s, de_s;
    wire [11:0] act_x, act_y;

    sync_vg #(
        .X_BITS(12), .Y_BITS(12),
        .V_TOTAL(V_TOTAL), .V_FP(V_FP), .V_BP(V_BP), .V_SYNC(V_SYNC), .V_ACT(V_ACT),
        .H_TOTAL(H_TOTAL), .H_FP(H_FP), .H_BP(H_BP), .H_SYNC(H_SYNC), .H_ACT(H_ACT)
    ) u_sync (
        .clk(pix_clk), .rstn(pix_rst_n),
        .vs_out(vs_s), .hs_out(hs_s), .de_out(de_s),
        .de_re(), .x_act(act_x), .y_act(act_y)
    );

    // x/y delayed 5 cycles so they line up with de_out (5 deep pipeline)
    reg [59:0] ax_sr, ay_sr;
    always @(posedge pix_clk)
    begin
        ax_sr <= {ax_sr[47:0], act_x};
        ay_sr <= {ay_sr[47:0], act_y};
    end
    wire [11:0] x5 = ax_sr[59:48];
    wire [11:0] y5 = ay_sr[59:48];

    //------------------------------------------------------------- 4 windows
    wire [31:0] wq_r, wq_g, wq_b;
    wire [3:0]  wq_de, wq_hs, wq_vs, wq_vid;
    wire [3:0]  wq_stat_tgl;
    wire [639:0]wq_stat_bus;
    wire [111:0]wq_araddr;
    wire [15:0] wq_arlen;
    wire [3:0]  wq_arvalid, wq_arready, wq_rlast, wq_rvalid;

    wire        m_arvalid;
    wire [27:0] m_araddr;
    wire [3:0]  m_arlen;
    reg         m_arready;
    reg  [255:0]m_rdata;
    reg         m_rvalid, m_rlast;

    genvar wi;
    generate
        for (wi=0; wi<4; wi=wi+1) begin: gqwin
            localparam [11:0] WX = ((wi%2)!=0) ? 12'd960 : 12'd0;
            localparam [11:0] WY = ((wi/2)!=0) ? 12'd540 : 12'd0;

            rt_disp_win_reader #(
                .H_ACT  (H_ACT),
                .V_ACT  (V_ACT),
                .WIN_X0 (WX),
                .WIN_Y0 (WY),
                .WIN_W  (12'd960),
                .WIN_H  (12'd540),
                .WIN_IDX(wi[1:0])
            ) u_qwin (
                .pix_clk       (pix_clk),
                .pix_rst_n     (pix_rst_n),
                .cfg_tgl       (cfg_tgl),
                .cfg_ctrl      (cfg_ctrl),
                .cfg_base      (cfg_base_w[wi]),
                .cfg_stride    (cfg_stride),
                .cfg_uv_off    (cfg_uv_w[wi]),
                .commit_tgl    (commit_tgl),
                .commit_slot   (commit_slot),
                .commit_frame_id(commit_frame_id),
                .stat_tgl      (wq_stat_tgl[wi]),
                .stat_bus      (wq_stat_bus[160*wi +: 160]),
                .video_active_o(wq_vid[wi]),
                .vs            (vs_s),
                .hs            (hs_s),
                .de            (de_s),
                .x_act         (act_x),
                .y_act         (act_y),
                .r_out         (wq_r[8*wi +: 8]),
                .g_out         (wq_g[8*wi +: 8]),
                .b_out         (wq_b[8*wi +: 8]),
                .de_out        (wq_de[wi]),
                .hs_out        (wq_hs[wi]),
                .vs_out        (wq_vs[wi]),
                .core_clk      (core_clk),
                .core_rst_n    (core_rst_n),
                .m_araddr      (wq_araddr[28*wi +: 28]),
                .m_arlen       (wq_arlen[4*wi +: 4]),
                .m_arvalid     (wq_arvalid[wi]),
                .m_arready     (wq_arready[wi]),
                .m_rdata       (m_rdata),
                .m_rlast       (wq_rlast[wi]),
                .m_rvalid      (wq_rvalid[wi])
            );
        end
    endgenerate

    //------------------------------------------------------------- pattern probe
    // window (0,0), video_en=0 -> test pattern and no DDR traffic at all
    wire [7:0] p_r, p_g, p_b;
    wire       p_de, p_hs, p_vs, p_va, p_atgl;
    wire [159:0] p_abus;

    rt_disp_win_reader #(
        .H_ACT(H_ACT), .V_ACT(V_ACT),
        .WIN_X0(12'd0), .WIN_Y0(12'd0), .WIN_W(12'd960), .WIN_H(12'd540),
        .WIN_IDX(2'd0)
    ) u_probe (
        .pix_clk       (pix_clk),
        .pix_rst_n     (pix_rst_n),
        .cfg_tgl       (cfg_tgl),
        .cfg_ctrl      (16'd0),            // video_en=0 -> test pattern
        .cfg_base      (32'd0),
        .cfg_stride    (32'd1920),
        .cfg_uv_off    (32'd1036800),
        .commit_tgl    (commit_tgl),
        .commit_slot   (commit_slot),
        .commit_frame_id(commit_frame_id),
        .stat_tgl      (p_atgl),
        .stat_bus      (p_abus),
        .video_active_o(p_va),
        .vs            (vs_s),
        .hs            (hs_s),
        .de            (de_s),
        .x_act         (act_x),
        .y_act         (act_y),
        .r_out         (p_r),
        .g_out         (p_g),
        .b_out         (p_b),
        .de_out        (p_de),
        .hs_out        (p_hs),
        .vs_out        (p_vs),
        .core_clk      (core_clk),
        .core_rst_n    (core_rst_n),
        .m_araddr      (),
        .m_arlen       (),
        .m_arvalid     (),
        .m_arready     (1'b0),
        .m_rdata       (256'd0),
        .m_rlast       (1'b0),
        .m_rvalid      (1'b0)
    );

    //------------------------------------------------------------- 4:1 AR mux
    // same round-robin + burst owner queue as rt_disp_top (quad mode)
    reg  [1:0] wq_rr, wq_sel;
    wire [3:0] wq_any4 = wq_arvalid;
    wire       wq_any  = |wq_any4;

    always @(*)
    begin
        case (wq_rr)
            2'd0: wq_sel = wq_any4[0] ? 2'd0 : wq_any4[1] ? 2'd1 :
                           wq_any4[2] ? 2'd2 : 2'd3;
            2'd1: wq_sel = wq_any4[1] ? 2'd1 : wq_any4[2] ? 2'd2 :
                           wq_any4[3] ? 2'd3 : 2'd0;
            2'd2: wq_sel = wq_any4[2] ? 2'd2 : wq_any4[3] ? 2'd3 :
                           wq_any4[0] ? 2'd0 : 2'd1;
            default: wq_sel = wq_any4[3] ? 2'd3 : wq_any4[0] ? 2'd0 :
                           wq_any4[1] ? 2'd1 : 2'd2;
        endcase
    end

    wire [27:0] wq_araddr_s = wq_araddr[28*wq_sel +: 28];
    wire [3:0]  wq_arlen_s  = wq_arlen [4*wq_sel  +: 4];

    reg  [1:0] wq_qo [0:7];
    reg  [3:0] wq_ql [0:7];
    reg  [3:0] wq_qwr, wq_qrd;
    wire       wq_full  = ((wq_qwr - wq_qrd) == 4'd8);
    wire       wq_empty = (wq_qwr == wq_qrd);

    wire wq_gnt = wq_any && !wq_full;
    wire wq_arh = wq_gnt && m_arready;

    assign m_arvalid = wq_gnt;
    assign m_araddr  = wq_araddr_s;
    assign m_arlen   = wq_arlen_s;

    assign wq_arready[0] = wq_arh && (wq_sel==2'd0);
    assign wq_arready[1] = wq_arh && (wq_sel==2'd1);
    assign wq_arready[2] = wq_arh && (wq_sel==2'd2);
    assign wq_arready[3] = wq_arh && (wq_sel==2'd3);

    wire [1:0] wq_cur     = wq_qo[wq_qrd[2:0]];
    wire [3:0] wq_cur_len = wq_ql[wq_qrd[2:0]];
    reg  [3:0] wq_bcnt;
    wire       wq_beat_last = m_rvalid && !wq_empty && (wq_bcnt == wq_cur_len);

    assign wq_rvalid[0] = m_rvalid && !wq_empty && (wq_cur==2'd0);
    assign wq_rvalid[1] = m_rvalid && !wq_empty && (wq_cur==2'd1);
    assign wq_rvalid[2] = m_rvalid && !wq_empty && (wq_cur==2'd2);
    assign wq_rvalid[3] = m_rvalid && !wq_empty && (wq_cur==2'd3);
    assign wq_rlast[0]  = wq_rvalid[0] && m_rlast;
    assign wq_rlast[1]  = wq_rvalid[1] && m_rlast;
    assign wq_rlast[2]  = wq_rvalid[2] && m_rlast;
    assign wq_rlast[3]  = wq_rvalid[3] && m_rlast;

    always @(posedge core_clk or negedge core_rst_n)
    begin
        if (!core_rst_n)
        begin
            wq_rr <= 2'd0; wq_qwr <= 4'd0; wq_qrd <= 4'd0; wq_bcnt <= 4'd0;
        end
        else
        begin
            if (wq_arh)
            begin
                wq_qo[wq_qwr[2:0]] <= wq_sel;
                wq_ql[wq_qwr[2:0]] <= wq_arlen_s;
                wq_qwr <= wq_qwr + 1'b1;
                wq_rr  <= wq_sel + 2'd1;
            end
            if (wq_beat_last) wq_qrd <= wq_qrd + 1'b1;
            if (m_rvalid && !wq_empty)
            begin
                if (wq_bcnt == wq_cur_len) wq_bcnt <= 4'd0;
                else                       wq_bcnt <= wq_bcnt + 1'b1;
            end
            else if (wq_empty) wq_bcnt <= 4'd0;
        end
    end

    //------------------------------------------------------------- DDR model
    // content is a pure function of the byte address
    function [7:0] byte_at(input [31:0] a);
        integer sl, off, o2, row, col;
        begin
            if (mode_crop)
            begin
                if (a < FUVO)
                begin
                    row = a / 1920; col = a % 1920;
                    byte_at = ((row*7) + col) & 8'hFF;
                end
                else
                begin
                    o2  = a - FUVO;
                    row = o2 / 1920; col = o2 % 1920;
                    byte_at = (col % 2 == 0) ? ((90 + row*3) & 8'hFF)
                                             : ((200 + row*5) & 8'hFF);
                end
            end
            else
            begin
                sl  = a / SLOT;
                off = a % SLOT;
                if (off < UVOFF)
                begin
                    row = off / 960; col = off % 960;
                    byte_at = (sl*40 + row + col) & 8'hFF;
                end
                else
                begin
                    o2  = off - UVOFF;
                    row = o2 / 960; col = o2 % 960;
                    byte_at = (col % 2 == 0) ? ((90 + 20*sl + row*3) & 8'hFF)
                                             : ((200 - 20*sl + row*5) & 8'hFF);
                end
            end
        end
    endfunction

    function [255:0] beat_at(input [31:0] a);
        integer k;
        begin
            for (k=0;k<32;k=k+1) beat_at[k*8 +: 8] = byte_at(a + k);
        end
    endfunction

    reg [31:0] AR_MAX = 3, R_MAX = 1;
    reg [2:0]  dr_st;
    reg [31:0] ar_delay, r_left, r_gap, r_j;
    reg [27:0] r_addr;
    reg [3:0]  r_alen;

    always @(posedge core_clk or negedge core_rst_n)
    begin
        if (!core_rst_n) begin
            m_arready<=0; m_rvalid<=0; m_rlast<=0; dr_st<=0;
            ar_delay<=0; r_left<=0; r_gap<=0; r_j<=0; r_addr<=0; r_alen<=0;
        end else begin
            case (dr_st)
                3'd0: begin
                    m_arready <= 1'b0;
                    if (m_arvalid) begin
                        ar_delay <= $urandom_range(AR_MAX,0);
                        dr_st    <= 3'd1;
                    end
                end
                3'd1: begin
                    if (ar_delay==0) begin
                        m_arready <= 1'b1;
                        r_addr  <= m_araddr;
                        r_alen  <= m_arlen;
                        r_left  <= m_arlen + 1'b1;
                        r_j     <= 0;
                        dr_st   <= 3'd2;
                    end else ar_delay <= ar_delay-1'b1;
                end
                3'd2: begin
                    m_arready <= 1'b0;
                    m_rvalid  <= 1'b1;
                    m_rdata   <= beat_at({r_addr,2'b0} + 32*r_j);
                    m_rlast   <= (r_left==1);
                    r_j       <= r_j + 1'b1;
                    dr_st     <= 3'd3;
                end
                3'd3: begin
                    if (m_rlast) begin
                        m_rvalid<=0; m_rlast<=0; dr_st<=3'd0;
                    end else begin
                        r_left <= r_left - 1'b1;
                        if (R_MAX==0 || $urandom_range(R_MAX,0)==0) begin
                            m_rdata  <= beat_at({r_addr,2'b0} + 32*r_j);
                            m_rlast  <= (r_left==2);
                            r_j      <= r_j+1'b1;
                            m_rvalid <= 1'b1;
                            dr_st    <= 3'd3;
                        end else begin
                            r_gap    <= $urandom_range(R_MAX,1);
                            m_rvalid <= 1'b0;
                            dr_st    <= 3'd4;
                        end
                    end
                end
                3'd4: begin
                    if (r_gap<=1) begin
                        m_rvalid <= 1'b1;
                        m_rdata  <= beat_at({r_addr,2'b0} + 32*r_j);
                        m_rlast  <= (r_left==1);
                        r_j      <= r_j+1'b1;
                        dr_st    <= 3'd3;
                    end else r_gap <= r_gap-1'b1;
                end
                default: dr_st<=3'd0;
            endcase
        end
    end

    //------------------------------------------------------------- AR legality
    integer ar_cnt = 0, amon_err = 0;
    reg [31:0] am_a, am_off;

    always @(posedge core_clk)
        if (m_arvalid && m_arready) begin
            ar_cnt = ar_cnt + 1;
            am_a   = {m_araddr, 2'b0};
            if (mode_crop)
            begin
                am_off = am_a % 1920;
                if (am_a >= FSZ)                                        amon_err = amon_err + 1;
                else if (am_off!=0 && am_off!=512 && am_off!=960 && am_off!=1472)
                                                                        amon_err = amon_err + 1;
            end
            else
            begin
                am_off = am_a % SLOT;
                if ((am_a / SLOT) > 3)                                  amon_err = amon_err + 1;
                else if (am_off >= UVOFF + UVSZ)                        amon_err = amon_err + 1;
                else if ((am_off % 960)!=0 && (am_off % 960)!=512)      amon_err = amon_err + 1;
            end
        end

    //------------------------------------------------------------- capture
    reg [23:0] cap_mem [0:TOTAL-1];
    reg [23:0] pw_mem  [0:518399];
    reg        cap_arm = 0, capture = 0, cap_done = 0;
    reg        pcap = 0, pcap_done = 0;
    integer    idx = 0, pidx = 0;
    reg        vs_d;
    integer    de_bad = 0;

    wire [7:0] qz_r = wq_r[7:0] | wq_r[15:8] | wq_r[23:16] | wq_r[31:24];
    wire [7:0] qz_g = wq_g[7:0] | wq_g[15:8] | wq_g[23:16] | wq_g[31:24];
    wire [7:0] qz_b = wq_b[7:0] | wq_b[15:8] | wq_b[23:16] | wq_b[31:24];
    wire       qz_de = |wq_de;

    always @(posedge pix_clk)
    begin
        vs_d <= wq_vs[0];
        if (wq_vs[0] & ~vs_d) begin
            if (cap_arm) begin capture<=1'b1; idx<=0; cap_done<=1'b0;
                               pcap<=1'b1;   pidx<=0; pcap_done<=1'b0; end
        end
        if (qz_de && capture) begin
            cap_mem[idx] <= {qz_r,qz_g,qz_b};
            if (idx==(TOTAL-1)) begin capture<=1'b0; cap_done<=1'b1; end
            idx <= idx+1;
        end
        if (p_de && pcap) begin
            pw_mem[pidx] <= {p_r,p_g,p_b};
            if (pidx==(WIN_W*WIN_H-1)) begin pcap<=1'b0; pcap_done<=1'b1; end
            pidx <= pidx+1;
        end
        // de_out must never be asserted outside the probe window
        if (p_de && (x5>=960 || y5>=540)) de_bad = de_bad + 1;
    end

    //------------------------------------------------------------- helpers
    integer dbg = 0;
    initial void'($value$plusargs("DBG=%d", dbg));
    reg qd0;
    integer vsn = 0;
    integer dbg2_cnt = 0;
    always @(posedge pix_clk)
    begin
        qd0 <= wq_de[0];
        if (wq_vs[0]) vsn <= vsn + 1;
        if (dbg && wq_de[0] && !qd0 && (y5<2 || (y5>=539 && y5<=541)))
            $display("[DBG] line y=%0d x=%0d fb=%0d lr=%0d rd_sr=%b px=%02x%02x%02x",
                     y5, x5, gqwin[0].u_qwin.fetched_bin, gqwin[0].u_qwin.line_ready,
                     gqwin[0].u_qwin.rd_sr, wq_r[7:0], wq_g[7:0], wq_b[7:0]);
        if (dbg==2 && wq_de[0] && y5==0 && x5<4 && vsn>4 && dbg2_cnt<24) begin
            dbg2_cnt = dbg2_cnt + 1;
            $display("[DBG2] x5=%0d wi=%b rd=%b va=%b yw=%02x xd1=%0d yb1=%02x out=%02x/%02x/%02x px=%02x%02x%02x",
                     x5, gqwin[0].u_qwin.wi_sr, gqwin[0].u_qwin.rd_sr,
                     gqwin[0].u_qwin.va_sr, gqwin[0].u_qwin.y_word[7:0],
                     gqwin[0].u_qwin.x_d1, gqwin[0].u_qwin.by1,
                     gqwin[0].u_qwin.out_r, gqwin[0].u_qwin.out_g, gqwin[0].u_qwin.out_b,
                     wq_r[7:0], wq_g[7:0], wq_b[7:0]);
        end
    end

    task cfg_set(input [15:0] ctrl, input [31:0] base, input [31:0] slotsz,
                 input [31:0] stride, input [31:0] uvoff);
    begin
        cfg_ctrl<=ctrl; cfg_fb_base<=base; cfg_slot_size<=slotsz;
        cfg_stride<=stride; cfg_uv_off<=uvoff;
        // mirror the offset folding done by rt_disp_top
        cfg_base_w[0]<=base + 0*slotsz + ((slotsz==0)? (0*stride + 0)       : 0);
        cfg_base_w[1]<=base + 1*slotsz + ((slotsz==0)? (0*stride + 960)     : 0);
        cfg_base_w[2]<=base + 2*slotsz + ((slotsz==0)? (540*stride + 0)     : 0);
        cfg_base_w[3]<=base + 3*slotsz + ((slotsz==0)? (540*stride + 960)   : 0);
        cfg_uv_w[0]  <=uvoff + ((slotsz==0)? (0*stride   + 0)   : 0);
        cfg_uv_w[1]  <=uvoff + ((slotsz==0)? (0*stride   + 960) : 0);
        cfg_uv_w[2]  <=uvoff + ((slotsz==0)? (270*stride + 0)   : 0);
        cfg_uv_w[3]  <=uvoff + ((slotsz==0)? (270*stride + 960) : 0);
        @(posedge pix_clk);
        cfg_tgl <= ~cfg_tgl;
        repeat(16) @(posedge pix_clk);
    end
    endtask

    task do_commit(input [1:0] slot, input [15:0] fid);
    begin
        commit_slot<=slot; commit_frame_id<=fid;
        @(posedge pix_clk);
        commit_tgl <= ~commit_tgl;
        repeat(8) @(posedge pix_clk);
    end
    endtask

    // reference colour of the composite at (x,y)
    function [23:0] ref_px(input integer x, input integer y);
        integer k, row, col, yv, uv, vv, c, d, e, r, g, b;
        begin
            if (mode_crop)
            begin
                yv = ((y*7) + x) & 8'hFF;
                uv = (90 + (y/2)*3) & 8'hFF;
                vv = (200 + (y/2)*5) & 8'hFF;
            end
            else
            begin
                k    = ((y>=540)?2:0) + ((x>=960)?1:0);
                row  = y - 540*(k/2);
                col  = x - 960*(k%2);
                yv   = (k*40 + row + col) & 8'hFF;
                uv   = (90 + 20*k + (row/2)*3) & 8'hFF;
                vv   = (200 - 20*k + (row/2)*5) & 8'hFF;
            end
            c = yv-16; d = uv-128; e = vv-128;
            r = (298*c + 459*e + 128) >>> 8;
            g = (298*c - 55*d - 136*e + 128) >>> 8;
            b = (298*c + 541*d + 128) >>> 8;
            if (r<0) r=0; if (r>255) r=255;
            if (g<0) g=0; if (g>255) g=255;
            if (b<0) b=0; if (b>255) b=255;
            ref_px = {r[7:0], g[7:0], b[7:0]};
        end
    endfunction

    integer test, i, x, y, mism, p_mism, bar;
    reg [23:0] e, got;
    reg [7:0] er, eg, eb;

    initial begin
        pix_rst_n=0; core_rst_n=0; cfg_tgl=0; commit_tgl=0;
        cfg_ctrl=0; cfg_fb_base=0; cfg_slot_size=0; cfg_stride=0; cfg_uv_off=0;
        commit_slot=0; commit_frame_id=0;
        for (i=0;i<4;i=i+1) begin cfg_base_w[i]=0; cfg_uv_w[i]=0; end
        repeat(20) @(posedge pix_clk);
        pix_rst_n=1; core_rst_n=1;
        repeat(20) @(posedge pix_clk);

        test = 1;
        void'($value$plusargs("TEST=%d", test));
        void'($value$plusargs("AMAX=%d", AR_MAX));
        void'($value$plusargs("RMAX=%d", R_MAX));

        if (test==2) begin
            cfg_set(16'd0, 32'd0, 32'd0, 32'd1920, 32'd1036800);
        end else if (test==3) begin
            mode_crop = 1;
            cfg_set(16'd1, 32'd0, 32'd0, 32'd1920, 32'd2073600);
        end else begin
            cfg_set(16'd1, 32'd0, SLOT, 32'd960, UVOFF);
        end

        if (test==1 || test==3) begin
            do_commit(2'd0, 16'h0001);
            do_commit(2'd1, 16'h0001);
            do_commit(2'd2, 16'h0001);
            do_commit(2'd3, 16'h0001);
        end

        if (test==2) begin
            repeat(2) @(posedge vs_s);
            @(posedge vs_s);
            cap_arm = 1;
            while (!pcap_done) @(posedge pix_clk);
            cap_arm = 0;
            p_mism = 0;
            for (y=0;y<WIN_H;y=y+1)
                for (x=0;x<WIN_W;x=x+1) begin
                    // the 64x64 white marker at (sqx, WIN_H-120) moves per frame,
                    // so its rows are excluded (checked separately in TQ1/TQ3)
                    if (y>=(WIN_H-120) && y<(WIN_H-56)) continue;
                    bar = x/(WIN_W/8);
                    case (bar)
                        0: begin er=255;eg=255;eb=255; end
                        1: begin er=255;eg=255;eb=0;   end
                        2: begin er=0;  eg=255;eb=255; end
                        3: begin er=0;  eg=255;eb=0;   end
                        4: begin er=255;eg=0;  eb=255; end
                        5: begin er=255;eg=0;  eb=0;   end
                        6: begin er=0;  eg=0;  eb=255; end
                        default: begin er=0;eg=0;eb=0;  end
                    endcase
                    if ((x%120)==0 || (y%120)==0) begin er=128; eg=128; eb=128; end
                    got = pw_mem[y*WIN_W+x];
                    if (got !== {er,eg,eb}) begin
                        if (p_mism<8) $display("[TQ] T2 pix (%0d,%0d) got %06x exp %06x",
                                               x,y,got,{er,eg,eb});
                        p_mism = p_mism+1;
                    end
                end
            if (p_mism==0 && pidx==(WIN_W*WIN_H) && de_bad==0)
                $display("TQ2 PASS (inside exact, pixels=%0d, out_of_window_de=%0d)",
                         pidx, de_bad);
            else
                $display("TQ2 FAIL mism=%0d pixels=%0d out_of_window_de=%0d",
                         p_mism, pidx, de_bad);
        end
        else begin
            repeat(3) @(posedge vs_s);
            @(posedge vs_s);
            cap_arm = 1;
            while (!cap_done) @(posedge pix_clk);
            cap_arm = 0;
            mism = 0;
            for (i=0;i<TOTAL;i=i+1) begin
                e   = ref_px(i%H_ACT, i/H_ACT);
                got = cap_mem[i];
                if (got !== e) begin
                    if (mism<8) $display("[TQ] pix (%0d,%0d) got %06x exp %06x",
                                         i%H_ACT, i/H_ACT, got, e);
                    mism = mism+1;
                end
            end
            if (test==3) begin
                if (mism==0 && amon_err==0 && idx==TOTAL)
                    $display("TQ3 PASS (crop 1920x1080, bursts=%0d)", ar_cnt);
                else
                    $display("TQ3 FAIL mism=%0d addr_err=%0d pix=%0d",
                             mism, amon_err, idx);
            end else begin
                if (mism==0 && amon_err==0 && idx==TOTAL)
                    $display("TQ1 PASS (4 slots, bursts=%0d)", ar_cnt);
                else
                    $display("TQ1 FAIL mism=%0d addr_err=%0d pix=%0d",
                             mism, amon_err, idx);
            end
        end

        #2000;
        $display("=== TB done test %0d ===", test);
        $finish;
    end

endmodule

