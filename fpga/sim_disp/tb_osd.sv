`timescale 1ns/1ps
//////////////////////////////////////////////////////////////////////////////
// tb_osd.sv : T7 - full-resolution OSD overlay image test.
//   video = T1 frame, all OSD layers on, one frame dumped to t7_frame.raw and
//   a set of pixel checks performed.
//////////////////////////////////////////////////////////////////////////////
module tb_osd;
    localparam H_ACT = 1920;
    localparam V_ACT = 1080;
    localparam H_TOTAL=2200, H_SYNC=44, H_BP=148, H_FP=88;
    localparam V_TOTAL=1125, V_SYNC=5,  V_BP=36,  V_FP=4;
    localparam integer TOTAL = H_ACT*V_ACT;

    reg pix_clk = 0, core_clk = 0;
    always #3.367 pix_clk  = ~pix_clk;
    always #4.0   core_clk = ~core_clk;

    reg pix_rst_n, core_rst_n;

    reg         cfg_tgl;
    reg  [15:0] cfg_ctrl;
    reg  [31:0] cfg_fb_base, cfg_slot_size, cfg_stride, cfg_uv_off;
    reg         commit_tgl; reg [1:0] commit_slot; reg [15:0] commit_frame_id;
    wire        stat_tgl; wire [159:0] stat_bus; wire vid_active;

    wire        vs_s, hs_s, de_s; wire [11:0] act_x, act_y;
    wire [7:0]  r_out, g_out, b_out; wire de_out, hs_out, vs_out;

    wire [27:0] dsp_araddr; wire [3:0] dsp_arlen; wire dsp_arvalid; wire dsp_arready;
    wire [255:0]dsp_rdata; wire dsp_rlast; wire dsp_rvalid;
    reg  [27:0] hub_araddr; reg [3:0] hub_arlen; reg hub_arvalid; wire hub_arready;
    wire [255:0]hub_rdata; wire hub_rlast; wire hub_rvalid;
    wire [27:0] ddr_araddr; wire [3:0] ddr_arlen; wire ddr_arvalid;
    reg         ddr_arready; reg [255:0]ddr_rdata; reg ddr_rlast; reg ddr_rvalid;
    wire [3:0]  ddr_aruser_id;

    // osd config interface (driven directly)
    reg          osd_cfg_tgl;
    reg  [1065:0] osd_cfg;
    reg          tram_we; reg [5:0] tram_addr; reg [31:0] tram_wdata;
    reg          evt_tgl; reg [2:0] evt_key; reg [1:0] evt_type; reg [5:0] evt_step;
    wire         drv_tgl; wire [9:0] drv_bus;
    wire         cal_tgl; wire [59:0] cal_bus;
    wire         repeat_en_w, pause_req_w;
    wire         cal_mode_w; wire [1:0] obj_w;
    wire [11:0]  eff_vpx, eff_vpy, eff_yt, eff_yb, eff_g;
    wire [511:0] status_line_w; wire cal_blink_w;
    wire [31:0]  dec_w, osdctrl_w; wire [831:0] box_w;

    wire [7:0]   osd_r, osd_g, osd_b; wire osd_de, osd_hs, osd_vs;

    //------------------------------------------------------------- DDR model
    reg [255:0] ddr [0:262143];
    reg [31:0]  AR_MAX = 3, R_MAX = 1;
    reg [2:0]   dr_st; reg [31:0] ar_delay, r_left, r_gap, r_j;
    reg [27:0]  r_addr; reg [3:0] r_alen;
    always @(posedge core_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            ddr_arready<=0; ddr_rvalid<=0; ddr_rlast<=0; dr_st<=0;
            ar_delay<=0; r_left<=0; r_gap<=0; r_j<=0; r_addr<=0; r_alen<=0;
        end else begin
            case (dr_st)
                3'd0: begin ddr_arready<=1'b0;
                    if (ddr_arvalid) begin ar_delay<=$urandom_range(AR_MAX,0); dr_st<=3'd1; end end
                3'd1: begin
                    if (ar_delay==0) begin ddr_arready<=1'b1; r_addr<=ddr_araddr; r_alen<=ddr_arlen;
                        r_left<=ddr_arlen+1'b1; r_j<=0; dr_st<=3'd2; end
                    else ar_delay<=ar_delay-1'b1; end
                3'd2: begin ddr_arready<=1'b0; ddr_rvalid<=1'b1; ddr_rdata<=ddr[(r_addr>>3)+r_j];
                    ddr_rlast<=(r_left==1); r_j<=r_j+1'b1; dr_st<=3'd3; end
                3'd3: begin
                    if (ddr_rlast) begin ddr_rvalid<=0; ddr_rlast<=0; dr_st<=3'd0; end
                    else begin r_left<=r_left-1'b1;
                        if (R_MAX==0 || $urandom_range(R_MAX,0)==0) begin
                            ddr_rdata<=ddr[(r_addr>>3)+r_j]; ddr_rlast<=(r_left==2);
                            r_j<=r_j+1'b1; ddr_rvalid<=1'b1; dr_st<=3'd3; end
                        else begin r_gap<=$urandom_range(R_MAX,1); ddr_rvalid<=1'b0; dr_st<=3'd4; end
                    end end
                3'd4: begin
                    if (r_gap<=1) begin ddr_rvalid<=1'b1; ddr_rdata<=ddr[(r_addr>>3)+r_j];
                        ddr_rlast<=(r_left==1); r_j<=r_j+1'b1; dr_st<=3'd3; end
                    else r_gap<=r_gap-1'b1; end
                default: dr_st<=3'd0;
            endcase
        end
    end

    //------------------------------------------------------------- DUTs
    sync_vg #(.X_BITS(12), .Y_BITS(12),
        .V_TOTAL(V_TOTAL), .V_FP(V_FP), .V_BP(V_BP), .V_SYNC(V_SYNC), .V_ACT(V_ACT),
        .H_TOTAL(H_TOTAL), .H_FP(H_FP), .H_BP(H_BP), .H_SYNC(H_SYNC), .H_ACT(H_ACT)
    ) u_sync (.clk(pix_clk), .rstn(pix_rst_n), .vs_out(vs_s), .hs_out(hs_s),
        .de_out(de_s), .de_re(), .x_act(act_x), .y_act(act_y));

    rt_disp_reader #(.H_ACT(H_ACT), .V_ACT(V_ACT)) u_reader (
        .pix_clk(pix_clk), .pix_rst_n(pix_rst_n),
        .cfg_tgl(cfg_tgl), .cfg_ctrl(cfg_ctrl), .cfg_fb_base(cfg_fb_base),
        .cfg_slot_size(cfg_slot_size), .cfg_stride(cfg_stride), .cfg_uv_off(cfg_uv_off),
        .commit_tgl(commit_tgl), .commit_slot(commit_slot), .commit_frame_id(commit_frame_id),
        .stat_tgl(stat_tgl), .stat_bus(stat_bus), .video_active_o(vid_active),
        .vs(vs_s), .hs(hs_s), .de(de_s), .x_act(act_x), .y_act(act_y),
        .r_out(r_out), .g_out(g_out), .b_out(b_out),
        .de_out(de_out), .hs_out(hs_out), .vs_out(vs_out),
        .core_clk(core_clk), .core_rst_n(core_rst_n),
        .m_araddr(dsp_araddr), .m_arlen(dsp_arlen), .m_arvalid(dsp_arvalid),
        .m_arready(dsp_arready), .m_rdata(dsp_rdata), .m_rlast(dsp_rlast), .m_rvalid(dsp_rvalid));

    rt_ddr_rd_arb u_arb (
        .clk(core_clk), .rst_n(core_rst_n),
        .s0_araddr(hub_araddr), .s0_arlen(hub_arlen), .s0_arvalid(hub_arvalid),
        .s0_arready(hub_arready), .s0_rdata(hub_rdata), .s0_rlast(hub_rlast), .s0_rvalid(hub_rvalid),
        .s1_araddr(dsp_araddr), .s1_arlen(dsp_arlen), .s1_arvalid(dsp_arvalid),
        .s1_arready(dsp_arready), .s1_rdata(dsp_rdata), .s1_rlast(dsp_rlast), .s1_rvalid(dsp_rvalid),
        .ddr_araddr(ddr_araddr), .ddr_arlen(ddr_arlen), .ddr_arvalid(ddr_arvalid),
        .ddr_arready(ddr_arready), .ddr_rdata(ddr_rdata), .ddr_rlast(ddr_rlast),
        .ddr_rvalid(ddr_rvalid), .ddr_aruser_id(ddr_aruser_id));

    rt_osd_ctl u_ctl (
        .pix_clk(pix_clk), .rst_n(pix_rst_n),
        .osd_cfg_tgl(osd_cfg_tgl), .osd_cfg(osd_cfg),
        .evt_tgl(evt_tgl), .evt_key(evt_key), .evt_type(evt_type), .evt_step(evt_step),
        .drv_tgl(drv_tgl), .drv_bus(drv_bus),
        .cal_tgl(cal_tgl), .cal_bus(cal_bus),
        .repeat_en(repeat_en_w), .pause_req(pause_req_w),
        .vs(vs_s), .cal_mode(cal_mode_w), .obj(obj_w),
        .eff_vp_x(eff_vpx), .eff_vp_y(eff_vpy), .eff_y_top(eff_yt), .eff_y_bot(eff_yb),
        .eff_g(eff_g), .status_line(status_line_w), .cal_blink(cal_blink_w),
        .dec_out(dec_w), .osdctrl_out(osdctrl_w), .box_out(box_w));

    rt_osd #(.H_ACT(H_ACT), .V_ACT(V_ACT)) u_osd (
        .pix_clk(pix_clk), .rst_n(pix_rst_n),
        .r_in(r_out), .g_in(g_out), .b_in(b_out), .de_in(de_out), .hs_in(hs_out), .vs_in(vs_out),
        .x_act(act_x), .y_act(act_y),
        .osd_en(cfg_ctrl[2]), .dec(dec_w), .osdctrl(osdctrl_w), .box(box_w),
        .vp_x(eff_vpx), .vp_y(eff_vpy), .y_top(eff_yt), .y_bot(eff_yb), .g(eff_g),
        .cal_mode(cal_mode_w), .obj(obj_w), .cal_blink(cal_blink_w), .status_line(status_line_w),
        .tram_wclk(pix_clk), .tram_we(tram_we), .tram_addr(tram_addr), .tram_wdata(tram_wdata),
        .r_out(osd_r), .g_out(osd_g), .b_out(osd_b),
        .de_out(osd_de), .hs_out(osd_hs), .vs_out(osd_vs));

    //------------------------------------------------------------- capture
    reg [23:0] cap_mem [0:TOTAL-1];
    reg [23:0] exp_mem [0:TOTAL-1];
    reg        cap_arm=0, capture=0, cap_done=0; integer idx=0;
    reg        vs_d;
    always @(posedge pix_clk) begin
        vs_d <= osd_vs;
        if (osd_vs & ~vs_d) if (cap_arm) begin capture<=1'b1; idx<=0; cap_done<=1'b0; end
        if (osd_de && capture) begin
            cap_mem[idx] <= {osd_r,osd_g,osd_b};
            if (idx==TOTAL-1) begin capture<=1'b0; cap_done<=1'b1; end
            idx <= idx+1;
        end
    end

    //------------------------------------------------------------- helpers
    task cfg_set(input [15:0] ctrl, input [31:0] base, input [31:0] slotsz,
                 input [31:0] stride, input [31:0] uvoff);
    begin
        cfg_ctrl<=ctrl; cfg_fb_base<=base; cfg_slot_size<=slotsz;
        cfg_stride<=stride; cfg_uv_off<=uvoff;
        @(posedge pix_clk); cfg_tgl <= ~cfg_tgl; repeat(16) @(posedge pix_clk);
    end endtask

    task do_commit(input [1:0] slot, input [15:0] fid);
    begin
        commit_slot<=slot; commit_frame_id<=fid;
        @(posedge pix_clk); commit_tgl <= ~commit_tgl; repeat(8) @(posedge pix_clk);
    end endtask

    // osd_cfg field builder
    function [1065:0] build_cfg(input [31:0] dec, input [31:0] octl,
        input [31:0] calvp, input [31:0] calband, input [31:0] calg,
        input [31:0] autovp, input [31:0] autoband, input cvalid, input [7:0] cseq,
        input [831:0] bx);
    begin
        build_cfg = { bx, cseq, 1'b0, cvalid, autoband, autovp, calg, calband, calvp, octl, dec };
    end endfunction

    task osd_apply(input [1065:0] c);
    begin
        osd_cfg <= c; @(posedge pix_clk); osd_cfg_tgl <= ~osd_cfg_tgl;
        repeat(8) @(posedge pix_clk);
    end endtask

    integer i, k, mism, nerr, nwhite, ndim;
    reg [23:0] e; reg [7:0] er,eg,eb;
    reg [831:0] boxbus;
    string dfile, efile;
    integer fd;

    function [23:0] expat; input integer x; input integer y; begin expat = exp_mem[y*H_ACT+x]; end endfunction
    function [23:0] capat; input integer x; input integer y; begin capat = cap_mem[y*H_ACT+x]; end endfunction

    task chk; input [255:0] nm; input [23:0] got; input [23:0] exp;
    begin
        if (got !== exp) begin nerr=nerr+1; $display("[T7] FAIL %0s got %06x exp %06x", nm, got, exp); end
        else $display("[T7] ok   %0s = %06x", nm, got);
    end endtask

    integer scanx, scany; reg found;

    initial begin
        pix_rst_n=0; core_rst_n=0; cfg_tgl=0; commit_tgl=0;
        cfg_ctrl=0; cfg_fb_base=0; cfg_slot_size=0; cfg_stride=0; cfg_uv_off=0;
        commit_slot=0; commit_frame_id=0; hub_arvalid=0; hub_araddr=0; hub_arlen=0;
        osd_cfg_tgl=0; osd_cfg=0; tram_we=0; tram_addr=0; tram_wdata=0;
        evt_tgl=0; evt_key=0; evt_type=0; evt_step=0;
        nerr=0;
        repeat(20) @(posedge pix_clk);
        pix_rst_n=1; core_rst_n=1;
        repeat(20) @(posedge pix_clk);

        dfile=""; efile="";
        $value$plusargs("DFILE=%s", dfile);
        $value$plusargs("EFILE=%s", efile);
        if (dfile != "") $readmemh(dfile, ddr);
        if (efile != "") $readmemh(efile, exp_mem);

        // video config identical to T1
        cfg_set(16'd5, 32'd0, 32'h0040_0000, 32'd1920, 32'd2073600);
        do_commit(2'd0, 16'h0001);

        // ---- write status? no : text RAM row0 "OSD1 TEST 0123456789 ABCDEFG"
        begin
            reg [7:0] msg [0:31];
            msg[0]="O";msg[1]="S";msg[2]="D";msg[3]="1";msg[4]=" ";
            msg[5]="T";msg[6]="E";msg[7]="S";msg[8]="T";msg[9]=" ";
            msg[10]="0";msg[11]="1";msg[12]="2";msg[13]="3";msg[14]="4";
            msg[15]="5";msg[16]="6";msg[17]="7";msg[18]="8";msg[19]="9";
            msg[20]=" ";msg[21]="A";msg[22]="B";msg[23]="C";msg[24]="D";
            msg[25]="E";msg[26]="F";msg[27]="G";msg[28]=" ";
            for (i=0;i<8;i=i+1) begin
                tram_addr <= i[5:0];
                tram_wdata <= { msg[4*i+3], msg[4*i+2], msg[4*i+1], msg[4*i] };
                @(posedge pix_clk); tram_we <= 1'b1;
                @(posedge pix_clk); tram_we <= 1'b0;
                @(posedge pix_clk);
            end
        end

        // ---- boxes : box0 red (100,200)-(500,700), box1 green (1300,300)-(1800,800)
        boxbus = 832'd0;
        boxbus[52*0 +: 52] = { 4'd1, 12'd700, 12'd500, 12'd200, 12'd100 };
        boxbus[52*1 +: 52] = { 4'd2, 12'd800, 12'd1800, 12'd300, 12'd1300 };

        // DECISION: left=2(green) straight=3(red) right=1(gray) alarm=1
        // OSD_CTRL: text|arrow|box|ytop|ybot|ray|cross = 0x7F
        osd_apply(build_cfg(32'h0000_011E, 32'h0000_007F,
                            32'h02BC_0384, 32'h03D4_0310, 32'h0000_0240,
                            32'd0, 32'd0, 1'b1, 8'd0, boxbus));

        // settle a few frames
        repeat(4) @(posedge vs_s);
        @(posedge vs_s);
        cap_arm = 1;
        while (!cap_done) @(posedge pix_clk);
        cap_arm = 0;
        repeat(4) @(posedge pix_clk);

        // evaluate eff latched values (sanity)
        $display("[T7] eff vp=(%0d,%0d) ytop=%0d ybot=%0d g=%0d cal=%0d",
                 eff_vpx, eff_vpy, eff_yt, eff_yb, eff_g, cal_mode_w);

        // ---- checks
        chk("cross center",  capat(900,700), 24'hFF0000);
        chk("box0 edge L",   capat(100,400), 24'hFF0000);
        chk("box0 edge T",   capat(300,200), 24'hFF0000);
        chk("box1 edge L",   capat(1300,500),24'h00DC00);
        chk("box0 interior", capat(300,400), expat(300,400));
        chk("box1 interior", capat(1500,500),expat(1500,500));
        chk("y_bot line",    capat(400,980), 24'hFFDC00);
        chk("y_top line",    capat(400,784), 24'h808080);
        // ray : scan a 11px window at y=800
        found=0;
        for (scanx=690; scanx<=700; scanx=scanx+1)
            if (capat(scanx,800)===24'h00FF00) found=1;
        if (found) $display("[T7] ok   ray pixel green"); else begin nerr=nerr+1; $display("[T7] FAIL ray"); end
        chk("alarm border",  capat(5,5),     24'hFF0000);
        chk("arrow left",    capat(840,1008),24'h00DC00);
        chk("arrow straight",capat(960,1008),24'hE60000);
        chk("arrow right",   capat(1080,1008),24'h606060);
        // text : white glyph pixel + dimmed background pixel in 'O' cell
        nwhite=0; ndim=0;
        for (scany=16; scany<48; scany=scany+1)
            for (scanx=16; scanx<32; scanx=scanx+1) begin
                e = expat(scanx,scany);
                if (capat(scanx,scany)===24'hFFFFFF) nwhite=nwhite+1;
                else if ((capat(scanx,scany)[23:16]===e[23:16]>>1) &&
                         (capat(scanx,scany)[15:8]===e[15:8]>>1) &&
                         (capat(scanx,scany)[7:0]===e[7:0]>>1)) ndim=ndim+1;
            end
        if (nwhite>0) $display("[T7] ok   text white pixels=%0d", nwhite);
        else begin nerr=nerr+1; $display("[T7] FAIL no white text pixel"); end
        if (ndim>0) $display("[T7] ok   text dim pixels=%0d", ndim);
        else begin nerr=nerr+1; $display("[T7] FAIL no dimmed text bg"); end

        // ---- dump frame for python conversion
        fd = $fopen("t7_frame.raw","wb");
        for (i=0;i<TOTAL;i=i+1)
            $fwrite(fd, "%c%c%c", cap_mem[i][23:16], cap_mem[i][15:8], cap_mem[i][7:0]);
        $fclose(fd);

        if (nerr==0) $display("T7 PASS"); else $display("T7 FAIL nerr=%0d", nerr);
        #2000;
        $display("=== TB done T7 ===");
        $finish;
    end
endmodule
