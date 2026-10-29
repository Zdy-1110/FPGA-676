`timescale 1ns/1ps
//////////////////////////////////////////////////////////////////////////////
// tb_disp.sv : rt_disp_reader + rt_ddr_rd_arb + DDR3 behavioural model
//   T1 byte-exact 1080p video frame
//   T2 stride + BYTE_SWAP32
//   T3 test pattern
//   T4 underflow + recovery
//   T5 arbiter concurrency (port0 stub)
// Compile with +define+SMALL for the 256x128 geometry.
//////////////////////////////////////////////////////////////////////////////
module tb_disp;

`ifdef SMALL
    localparam H_ACT = 256;
    localparam V_ACT = 128;
    localparam H_TOTAL=320, H_SYNC=8, H_BP=24, H_FP=32;
    localparam V_TOTAL=160, V_SYNC=4, V_BP=14, V_FP=14;
`else
    localparam H_ACT = 1920;
    localparam V_ACT = 1080;
    localparam H_TOTAL=2200, H_SYNC=44, H_BP=148, H_FP=88;
    localparam V_TOTAL=1125, V_SYNC=5,  V_BP=36,  V_FP=4;
`endif
    localparam integer TOTAL = H_ACT*V_ACT;

    //------------------------------------------------------------- clocks
    reg pix_clk = 0, core_clk = 0;
    always #3.367 pix_clk  = ~pix_clk;
    always #4.0   core_clk = ~core_clk;

    reg pix_rst_n, core_rst_n;

    //------------------------------------------------------------- DUT reader sigs
    reg         cfg_tgl;
    reg  [15:0] cfg_ctrl;
    reg  [31:0] cfg_fb_base, cfg_slot_size, cfg_stride, cfg_uv_off;
    reg         commit_tgl;
    reg  [1:0]  commit_slot;
    reg  [15:0] commit_frame_id;
    wire        stat_tgl;
    wire [159:0]stat_bus;
    wire        vid_active;

    wire        vs_s, hs_s, de_s;
    wire [11:0] act_x, act_y;

    wire [7:0]  r_out, g_out, b_out;
    wire        de_out, hs_out, vs_out;

    // arbiter ports
    wire [27:0] dsp_araddr; wire [3:0] dsp_arlen; wire dsp_arvalid; wire dsp_arready;
    wire [255:0]dsp_rdata; wire dsp_rlast; wire dsp_rvalid;

    reg  [27:0] hub_araddr; reg [3:0] hub_arlen; reg hub_arvalid; wire hub_arready;
    wire [255:0]hub_rdata; wire hub_rlast; wire hub_rvalid;

    wire [27:0] ddr_araddr; wire [3:0] ddr_arlen; wire ddr_arvalid;
    reg         ddr_arready;
    reg  [255:0]ddr_rdata; reg ddr_rlast; reg ddr_rvalid;
    wire [3:0]  ddr_aruser_id;

    //------------------------------------------------------------- DDR model
    reg [255:0] ddr [0:262143];
    reg [31:0]  AR_MAX = 3;      // max arready delay
    reg [31:0]  R_MAX  = 1;      // max rvalid gap
    reg [2:0]   dr_st;
    reg [31:0]  ar_delay, r_left, r_gap, r_j;
    reg [27:0]  r_addr;
    reg [3:0]   r_alen;

    always @(posedge core_clk or negedge core_rst_n)
    begin
        if (!core_rst_n) begin
            ddr_arready<=0; ddr_rvalid<=0; ddr_rlast<=0; dr_st<=0;
            ar_delay<=0; r_left<=0; r_gap<=0; r_j<=0; r_addr<=0; r_alen<=0;
        end else begin
            case (dr_st)
                3'd0: begin
                    ddr_arready <= 1'b0;
                    if (ddr_arvalid) begin
                        ar_delay <= $urandom_range(AR_MAX,0);
                        dr_st    <= 3'd1;
                    end
                end
                3'd1: begin
                    if (ar_delay==0) begin
                        ddr_arready <= 1'b1;
                        r_addr  <= ddr_araddr;
                        r_alen  <= ddr_arlen;
                        r_left  <= ddr_arlen + 1'b1;
                        r_j     <= 0;
                        dr_st   <= 3'd2;
                    end else ar_delay <= ar_delay-1'b1;
                end
                3'd2: begin
                    ddr_arready <= 1'b0;
                    ddr_rvalid  <= 1'b1;
                    ddr_rdata   <= ddr[(r_addr>>3) + r_j];
                    ddr_rlast   <= (r_left==1);
                    r_j         <= r_j + 1'b1;
                    dr_st       <= 3'd3;
                end
                3'd3: begin
                    if (ddr_rlast) begin
                        ddr_rvalid<=0; ddr_rlast<=0; dr_st<=3'd0;
                    end else begin
                        r_left <= r_left - 1'b1;
                        if (R_MAX==0 || $urandom_range(R_MAX,0)==0) begin
                            ddr_rdata  <= ddr[(r_addr>>3)+r_j];
                            ddr_rlast  <= (r_left==2);
                            r_j        <= r_j+1'b1;
                            ddr_rvalid <= 1'b1;
                            dr_st      <= 3'd3;
                        end else begin
                            r_gap      <= $urandom_range(R_MAX,1);
                            ddr_rvalid <= 1'b0;
                            dr_st      <= 3'd4;
                        end
                    end
                end
                3'd4: begin
                    if (r_gap<=1) begin
                        ddr_rvalid <= 1'b1;
                        ddr_rdata  <= ddr[(r_addr>>3)+r_j];
                        ddr_rlast  <= (r_left==1);
                        r_j        <= r_j+1'b1;
                        dr_st      <= 3'd3;
                    end else r_gap <= r_gap-1'b1;
                end
                default: dr_st<=3'd0;
            endcase
        end
    end

    //------------------------------------------------------------- DUTs
    sync_vg #(
        .X_BITS(12), .Y_BITS(12),
        .V_TOTAL(V_TOTAL), .V_FP(V_FP), .V_BP(V_BP), .V_SYNC(V_SYNC), .V_ACT(V_ACT),
        .H_TOTAL(H_TOTAL), .H_FP(H_FP), .H_BP(H_BP), .H_SYNC(H_SYNC), .H_ACT(H_ACT)
    ) u_sync (
        .clk(pix_clk), .rstn(pix_rst_n),
        .vs_out(vs_s), .hs_out(hs_s), .de_out(de_s),
        .de_re(), .x_act(act_x), .y_act(act_y)
    );

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
        .m_arready(dsp_arready), .m_rdata(dsp_rdata), .m_rlast(dsp_rlast), .m_rvalid(dsp_rvalid)
    );

    rt_ddr_rd_arb u_arb (
        .clk(core_clk), .rst_n(core_rst_n),
        .s0_araddr(hub_araddr), .s0_arlen(hub_arlen), .s0_arvalid(hub_arvalid),
        .s0_arready(hub_arready), .s0_rdata(hub_rdata), .s0_rlast(hub_rlast), .s0_rvalid(hub_rvalid),
        .s1_araddr(dsp_araddr), .s1_arlen(dsp_arlen), .s1_arvalid(dsp_arvalid),
        .s1_arready(dsp_arready), .s1_rdata(dsp_rdata), .s1_rlast(dsp_rlast), .s1_rvalid(dsp_rvalid),
        .ddr_araddr(ddr_araddr), .ddr_arlen(ddr_arlen), .ddr_arvalid(ddr_arvalid),
        .ddr_arready(ddr_arready), .ddr_rdata(ddr_rdata), .ddr_rlast(ddr_rlast),
        .ddr_rvalid(ddr_rvalid), .ddr_aruser_id(ddr_aruser_id)
    );

    //------------------------------------------------------------- capture
    reg [23:0] cap_mem [0:TOTAL-1];
    reg [23:0] exp_mem [0:TOTAL-1];
    reg        cap_arm = 0, capture = 0, cap_done = 0;
    integer    idx = 0;
    reg        vs_d;
    always @(posedge pix_clk)
    begin
        vs_d <= vs_out;
        if (vs_out & ~vs_d) begin
            if (cap_arm) begin capture<=1'b1; idx<=0; cap_done<=1'b0; end
        end
        if (de_out && capture) begin
            cap_mem[idx] <= {r_out,g_out,b_out};
            if (idx==(TOTAL-1)) begin capture<=1'b0; cap_done<=1'b1; end
            idx <= idx+1;
        end
    end

    //------------------------------------------------------------- config tasks
    task cfg_set(input [15:0] ctrl, input [31:0] base, input [31:0] slotsz,
                 input [31:0] stride, input [31:0] uvoff);
    begin
        cfg_ctrl<=ctrl; cfg_fb_base<=base; cfg_slot_size<=slotsz;
        cfg_stride<=stride; cfg_uv_off<=uvoff;
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

    //------------------------------------------------------------- misc
    integer test;
    integer i, j, n, mism, x, y;
    integer frame_mod;
    reg [23:0] e; integer r,g,b;
    reg [31:0] stride_v, uvoff_v, base_v, slotsz_v;
    reg [15:0] ctrl_v;
    string dfile, efile;

    // pattern helpers (mirror rtl)
    function [7:0] clp; input integer v;
        begin clp = (v<0)?8'd0:((v>255)?8'd255:v[7:0]); end
    endfunction

    // T5 stub
    integer stub_err = 0;
    reg     run_stub = 0;
    integer stub_base = 150000;

    initial begin
        // ------------------------------------------------ reset
        pix_rst_n=0; core_rst_n=0; cfg_tgl=0; commit_tgl=0;
        cfg_ctrl=0; cfg_fb_base=0; cfg_slot_size=0; cfg_stride=0; cfg_uv_off=0;
        commit_slot=0; commit_frame_id=0;
        hub_arvalid=0; hub_araddr=0; hub_arlen=0;
        repeat(20) @(posedge pix_clk);
        pix_rst_n=1; core_rst_n=1;
        repeat(20) @(posedge pix_clk);

        test = 1;
        stride_v = 1920; uvoff_v = 1920*1080; ctrl_v = 16'd1;
        AR_MAX = 3; R_MAX = 1;
        void'($value$plusargs("TEST=%d", test));
        void'($value$plusargs("STRIDE=%d", stride_v));
        void'($value$plusargs("UVOFF=%d", uvoff_v));
        void'($value$plusargs("CTRL=%d", ctrl_v));
        void'($value$plusargs("AMAX=%d", AR_MAX));
        void'($value$plusargs("RMAX=%d", R_MAX));
        base_v = 32'd0;
        slotsz_v = 32'h0040_0000;
        dfile = "";
        efile = "";
        $value$plusargs("DFILE=%s", dfile);
        $value$plusargs("EFILE=%s", efile);

        // load DDR init
        if (dfile != "") begin
            $readmemh(dfile, ddr);
            $display("[TB] loaded DDR %s", dfile);
        end

        if (test==5) begin
            // pre-fill port0 pattern region
            for (i=0;i<8192;i=i+1)
                ddr[stub_base+i] = { pattern32(4*i+3), pattern32(4*i+2),
                                     pattern32(4*i+1), pattern32(4*i) };
        end

        // configure video path
        cfg_set(ctrl_v, base_v, slotsz_v, stride_v, uvoff_v);
        do_commit(2'd0, 16'h0001);

        if (test==5) begin
            run_stub = 1;   // stub in separate initial
        end

        if (test==1 || test==2 || test==4) begin
            if (efile != "") $readmemh(efile, exp_mem);
            // settle a few frames
            if (test==4) begin
                repeat(3) @(posedge vs_s);    // 20261018 review: throttle only after video is active (it starts at frame 2)
                AR_MAX = 4000; R_MAX = 8;     // heavy : 2 frames (20261018 review: 220 never starved the small geometry)
                repeat(2) @(posedge vs_s);
                AR_MAX = 3;   R_MAX = 1;      // recover
                @(posedge vs_s);
            end
            repeat(3) @(posedge vs_s);
            @(posedge vs_s);
            cap_arm = 1;
            while (!cap_done) @(posedge pix_clk);
            cap_arm = 0;
            // compare
            mism = 0;
            for (i=0;i<TOTAL;i=i+1) begin
                e = exp_mem[i];
                if (cap_mem[i] !== e) begin
                    if (mism<8)
                        $display("[TB] pix %0d got %06x exp %06x", i, cap_mem[i], e);
                    mism = mism+1;
                end
            end
            if (test==4) begin
                if (u_reader.disp_underflow > 0 && mism==0)
                    $display("T4 PASS (underflow=%0d)", u_reader.disp_underflow);
                else
                    $display("T4 FAIL underflow=%0d mism=%0d", u_reader.disp_underflow, mism);
            end else if (test==2) begin
                if (mism==0) $display("T2 PASS"); else $display("T2 FAIL mism=%0d", mism);
            end else begin
                if (mism==0) $display("T1 PASS"); else $display("T1 FAIL mism=%0d", mism);
            end
        end
        else if (test==3) begin
            repeat(3) @(posedge vs_s);
            @(posedge vs_s);
            cap_arm=1;
            while (!cap_done) @(posedge pix_clk);
            cap_arm=0;
            // bars + grid, excluding the square rows
            mism = 0;
            for (y=0;y<V_ACT;y=y+1) begin
                if (y>=(V_ACT-120) && y<(V_ACT-120+64)) continue;
                for (x=0;x<H_ACT;x=x+1) begin
                    integer bar; reg [7:0] er,eg,eb;
                    bar = x/(H_ACT/8);
                    case (bar)
                        0: begin er=255;eg=255;eb=255; end
                        1: begin er=255;eg=255;eb=0;   end
                        2: begin er=0;  eg=255;eb=255; end
                        3: begin er=0;  eg=255;eb=0;   end
                        4: begin er=255;eg=0;  eb=255; end
                        5: begin er=255;eg=0;  eb=0;   end
                        6: begin er=0;  eg=0;  eb=255; end
                        default: begin er=0;eg=0;eb=0; end
                    endcase
                    if ((x%120)==0 || (y%120)==0) begin er=128; eg=128; eb=128; end
                    if (cap_mem[y*H_ACT+x] !== {er,eg,eb}) begin
                        if (mism<8) $display("[TB] T3 pix (%0d,%0d) got %06x exp %06x",
                                             x,y,cap_mem[y*H_ACT+x],{er,eg,eb});
                        mism = mism+1;
                    end
                end
            end
            // square: max white run inside square rows
            n = 0; j = 0;
            for (y=(V_ACT-120); y<(V_ACT-120+64); y=y+1) begin
                for (x=0;x<H_ACT;x=x+1) begin
                    if (cap_mem[y*H_ACT+x]===24'hFFFFFF) begin j=j+1; if (j>n) n=j; end
                    else j=0;
                end
            end
            if (mism==0 && n>=64)
                $display("T3 PASS (bar/grid mism=0, white run=%0d)", n);
            else
                $display("T3 FAIL mism=%0d white_run=%0d", mism, n);
        end
        else if (test==5) begin
            repeat(4) @(posedge vs_s);
            @(posedge vs_s);
            cap_arm=1;
            while (!cap_done) @(posedge pix_clk);
            cap_arm=0;
            if (efile != "") $readmemh(efile, exp_mem);
            mism = 0;
            for (i=0;i<TOTAL;i=i+1)
                if (cap_mem[i] !== exp_mem[i]) mism = mism+1;
            $display("[TB] T5 stub_err=%0d disp_mism=%0d", stub_err, mism);
            if (stub_err==0 && mism==0) $display("T5 PASS"); else $display("T5 FAIL");
        end

        #2000;
        $display("=== TB done test %0d ===", test);
        $finish;
    end

    function [31:0] pattern32; input integer k;
        begin pattern32 = 32'hA5A50000 ^ (k*32'h01010101); end
    endfunction

    // T5 port0 stub : 200 random bursts
    initial begin
        @(negedge core_rst_n);
        @(posedge core_rst_n);
        @(posedge run_stub);
        for (n=0;n<200;n=n+1) begin
            integer baddr, blen, k2;
            baddr = $urandom_range(4096-16);
            blen  = $urandom_range(16,1);
            @(posedge core_clk);
            hub_araddr <= (stub_base + baddr)*8;
            hub_arlen  <= blen-1;
            hub_arvalid<= 1'b1;
            @(posedge core_clk);
            while (!hub_arready) @(posedge core_clk);
            hub_arvalid<= 1'b0;
            for (k2=0;k2<blen;k2=k2+1) begin
                @(posedge core_clk);
                while (!hub_rvalid) @(posedge core_clk);
                if (hub_rdata !== ddr[stub_base+baddr+k2]) stub_err = stub_err+1;
            end
        end
        $display("[TB] stub finished err=%0d", stub_err);
    end

endmodule
