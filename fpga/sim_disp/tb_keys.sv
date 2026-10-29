`timescale 1ns/1ps
//////////////////////////////////////////////////////////////////////////////
// tb_keys.sv : T8 - key events + calibration (rt_keys + rt_osd_ctl + rt_ext_regs)
//   Clocks are scaled: TICK_DIV=32 (1 ms = 32 free_clk), MS_DIV=32 (1 ms = 32 pix).
//////////////////////////////////////////////////////////////////////////////
module tb_keys;
    localparam TD = 32;    // free_clk cycles per ms
    localparam MD = 32;    // pix_clk cycles per ms

    reg free_clk=0, pix_clk=0, pclk=0;
    always #1.0   free_clk = ~free_clk;   // 2 ns  (1 ms = 64 ns)
    always #3.367 pix_clk  = ~pix_clk;    // 6.734 ns
    always #4.0   pclk     = ~pclk;       // 8 ns

    reg rst_n;

    // keys
    reg  [4:0] key_raw = 5'b11111;
    wire [4:0] key_stat;

    // key event handshake
    wire       evt_tgl; wire [2:0] evt_key; wire [1:0] evt_type; wire [5:0] evt_step;

    // osd ctl <-> ext
    wire       repeat_en_w, pause_req_w;
    wire       cal_mode_w; wire [1:0] obj_w;
    wire [11:0] eff_vpx, eff_vpy, eff_yt, eff_yb, eff_g;
    wire [511:0] status_line_w; wire cal_blink_w;
    wire [31:0] dec_w, osdctrl_w; wire [831:0] box_w;
    wire       drv_tgl; wire [9:0] drv_bus;
    wire       cal_tgl; wire [59:0] cal_bus;
    reg        vs = 1'b0;   // 20261018 review: DRV_STATE is now re-sent once per frame -> need frame sync
    always #500 vs = ~vs;   // 1 us "frames" (settle = 4 us)

    // ext regs buses
    reg         i_tap_vld=0; reg [11:0] i_tap_addr=0; reg [31:0] i_tap_data=0;
    reg  [11:0] i_rd_addr=0; wire [127:0] o_rd128;
    wire        cfg_tgl; wire [15:0] cfg_ctrl;
    wire [31:0] cfg_fb_base, cfg_slot_size, cfg_stride, cfg_uv_off;
    wire        commit_tgl; wire [1:0] commit_slot; wire [15:0] commit_fid;
    wire        osd_cfg_tgl; wire [1065:0] osd_cfg;
    wire        tram_we; wire [5:0] tram_addr; wire [31:0] tram_data;
    wire [7:0]  led_host, led_oe;

    rt_keys #(.TICK_DIV(TD)) u_keys (
        .clk(free_clk), .rst_n(rst_n), .key_raw(key_raw),
        .repeat_en(repeat_en_w), .key_stat(key_stat),
        .evt_tgl(evt_tgl), .evt_key(evt_key), .evt_type(evt_type), .evt_step(evt_step));

    rt_osd_ctl #(.MS_DIV(MD)) u_ctl (
        .pix_clk(pix_clk), .rst_n(rst_n),
        .osd_cfg_tgl(osd_cfg_tgl), .osd_cfg(osd_cfg),
        .evt_tgl(evt_tgl), .evt_key(evt_key), .evt_type(evt_type), .evt_step(evt_step),
        .drv_tgl(drv_tgl), .drv_bus(drv_bus),
        .cal_tgl(cal_tgl), .cal_bus(cal_bus),
        .repeat_en(repeat_en_w), .pause_req(pause_req_w),
        .vs(vs), .cal_mode(cal_mode_w), .obj(obj_w),
        .eff_vp_x(eff_vpx), .eff_vp_y(eff_vpy), .eff_y_top(eff_yt), .eff_y_bot(eff_yb),
        .eff_g(eff_g), .status_line(status_line_w), .cal_blink(cal_blink_w),
        .dec_out(dec_w), .osdctrl_out(osdctrl_w), .box_out(box_w));

    rt_ext_regs u_ext (
        .clk(pclk), .rst_n(rst_n),
        .i_tap_vld(i_tap_vld), .i_tap_addr(i_tap_addr), .i_tap_data(i_tap_data),
        .i_rd_addr(i_rd_addr), .o_rd128(o_rd128),
        .cfg_tgl(cfg_tgl), .cfg_ctrl(cfg_ctrl), .cfg_fb_base(cfg_fb_base),
        .cfg_slot_size(cfg_slot_size), .cfg_stride(cfg_stride), .cfg_uv_off(cfg_uv_off),
        .commit_tgl(commit_tgl), .commit_slot(commit_slot), .commit_frame_id(commit_fid),
        .i_stat_tgl(1'b0), .i_stat_bus(160'd0),
        .o_osd_tgl(osd_cfg_tgl), .o_osd_cfg(osd_cfg),
        .o_tram_we(tram_we), .o_tram_addr(tram_addr), .o_tram_data(tram_data),
        .i_evt_tgl(evt_tgl), .i_evt_key(evt_key), .i_evt_type(evt_type), .i_evt_step(evt_step),
        .i_drv_tgl(drv_tgl), .i_drv_bus(drv_bus),
        .i_cal_tgl(cal_tgl), .i_cal_bus(cal_bus),
        .i_key_stat(key_stat), .o_led_host(led_host), .o_led_oe(led_oe));

    //------------------------------------------------------------- helpers
    task tap_wr(input [11:0] a, input [31:0] d);
    begin
        @(posedge pclk); i_tap_vld<=1'b1; i_tap_addr<=a; i_tap_data<=d;
        @(posedge pclk); i_tap_vld<=1'b0;
        repeat(3) @(posedge pclk);
    end endtask

    task rd_grp(input [11:0] a, output [127:0] d);
    begin
        @(posedge pclk); i_rd_addr<=a; repeat(3)@(posedge pclk); d=o_rd128; @(posedge pclk);
    end endtask

    task press_ms(input integer k, input integer ms);
    begin
        key_raw[k]=1'b0;
        #(ms*TD*2.0);
        key_raw[k]=1'b1;
        #(80*TD*2.0);       // release debounce + propagation
    end endtask

    task settle; begin #(4000); end endtask

    integer errs=0;
    reg [127:0] d;
    reg [31:0] dv, cc, calvp, calband, calguide, kev;
    integer vpx, vpy, ybot, ytop, gval;

    task chk_int(input [255:0] nm, input integer got, input integer exp);
    begin
        if (got!==exp) begin errs=errs+1; $display("[T8] FAIL %0s got %0d exp %0d", nm, got, exp); end
        else $display("[T8] ok   %0s = %0d", nm, got);
    end endtask

    initial begin
        rst_n=0;
        repeat(20) @(posedge pix_clk);
        rst_n=1;
        repeat(20) @(posedge pix_clk);
        settle;

        // 20261018 review: no spurious key event after reset (kdeb used to reset to "pressed")
        #(60*TD*2.0); settle;
        rd_grp(12'h840, d); kev = d[63:32];
        chk_int("KEY_EVT.seq after reset", kev[7:0], 0);

        // ---- KEY0 short x2 -> lane 0
        press_ms(0, 30); press_ms(0, 30); settle;
        rd_grp(12'h840, d); dv = d[95:64];        // DRV_STATE
        chk_int("lane after 2x KEY0", dv[1:0], 0);
        chk_int("moving init",        dv[2],   0);

        // ---- KEY1 short -> moving=1
        press_ms(1, 30); settle;
        rd_grp(12'h840, d); dv = d[95:64];
        chk_int("moving after KEY1",  dv[2],   1);

        // ---- KEY4 hold3 -> enter calibration
        press_ms(4, 3100); settle;
        rd_grp(12'h980, d); cc = d[31:0];         // CAL_CTRL
        chk_int("cal_mode=1",  cc[1], 1);
        chk_int("pause_req=1", cc[2], 1);
        settle;

        // ---- KEY2 held 2000 ms -> vp_x -= 354
        press_ms(2, 2000); settle;
        // KEY4 short -> obj = YBOT ; KEY1 short -> y_bot += 2
        press_ms(4, 30); settle;
        press_ms(1, 30); settle;
        // KEY4 hold3 -> save & exit
        press_ms(4, 3100); settle;

        rd_grp(12'h980, d); cc = d[31:0];
        chk_int("CAL_VALID", cc[0], 1);
        chk_int("CAL_SRC",   cc[3], 1);
        chk_int("CAL_SEQ",   cc[15:8], 1);
        chk_int("CAL_MODE=0",cc[1], 0);

        rd_grp(12'h980, d); calvp = d[63:32];
        vpx = calvp[15:0]; vpy = calvp[31:16];
        chk_int("CAL_VP.x", vpx, 606);
        chk_int("CAL_VP.y", vpy, 600);

        rd_grp(12'h980, d); calband = d[95:64];
        ytop = calband[15:0]; ybot = calband[31:16];
        chk_int("CAL_BAND.y_top", ytop, 720);
        chk_int("CAL_BAND.y_bot", ybot, 1002);

        rd_grp(12'h980, d); calguide = d[127:96];
        gval = calguide[15:0];
        chk_int("CAL_GUIDE.g", gval, 576);

        // DRV_STATE after save
        rd_grp(12'h840, d); dv = d[95:64];
        chk_int("DRV lane",     dv[1:0], 0);
        chk_int("DRV moving",   dv[2],   1);
        chk_int("DRV src_sel",  dv[6],   0);
        chk_int("DRV cal_mode", dv[7],   0);

        // KEY_EVT : last event = KEY4 HOLD3
        rd_grp(12'h840, d); kev = d[63:32];
        chk_int("KEY_EVT.type", kev[13:12], 3);
        chk_int("KEY_EVT.key",  kev[10:8],  4);
        if (kev[7:0] != 0) $display("[T8] ok   KEY_EVT.seq = %0d", kev[7:0]);
        else begin errs=errs+1; $display("[T8] FAIL KEY_EVT.seq = 0"); end

        // ---- re-enter calibration, 30 s idle -> auto exit, CAL unchanged
        press_ms(4, 3100); settle;
        rd_grp(12'h980, d); cc = d[31:0];
        chk_int("re-enter cal_mode", cc[1], 1);
        #(32000*MD*6.734);          // > 30 s of pixel-domain ms
        settle;
        rd_grp(12'h980, d); cc = d[31:0];
        chk_int("idle timeout CAL_MODE", cc[1], 0);
        chk_int("idle timeout CAL_SEQ",  cc[15:8], 1);
        rd_grp(12'h980, d);
        chk_int("idle timeout CAL_VP.x", d[47:32], 606);

        // 20261018 review: push VP past the top-left corner -> must clamp at 0 (used to wrap to the far side)
        press_ms(4, 3100); settle;
        press_ms(2, 4000); settle;          // vp_x 606 - (>1000) -> 0
        press_ms(0, 4000); settle;          // vp_y 600 - (>1000) -> 0
        press_ms(4, 3100); settle;          // save
        rd_grp(12'h980, d);
        chk_int("edge CAL_VP.x", d[47:32], 0);
        chk_int("edge CAL_VP.y", d[63:48], 0);

        if (errs==0) $display("T8 PASS"); else $display("T8 FAIL errs=%0d", errs);
        #2000;
        $display("=== TB done T8 ===");
        $finish;
    end
endmodule
