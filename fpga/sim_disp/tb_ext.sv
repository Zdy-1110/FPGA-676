`timescale 1ns/1ps
//////////////////////////////////////////////////////////////////////////////
// tb_ext.sv : T6 - rt_ext_regs register file + rt0101 decode masking
//////////////////////////////////////////////////////////////////////////////
module tb_ext;
    reg clk = 0, rst_n;
    always #4 clk = ~clk;

    // rt0101 stimulus
    reg         i_mwr_req_en;
    reg  [63:0] i_tlp_req_addr;
    reg  [127:0]i_mwr_req_data;
    reg  [3:0]  i_tlp_req_dwbe;
    reg  [2:0]  i_bar_sel;
    reg         i_mwr32_req_ack, i_mwr64_req_ack, i_mrd32_req_ack, i_mrd64_req_ack;
    wire        o_mwr32_req, o_mwr64_req, o_mrd32_req, o_mrd64_req;
    wire [10:0] o_mem_length;
    wire [63:0] o_mem_addr;
    wire [19:0] o_mwr_ext_length, o_mrd_ext_length;
    wire [5:0]  o_mrd_max_out;
    wire [31:0] o_chk_seed;
    wire        o_mrd_abort;
    wire        tap_vld;
    wire [11:0] tap_addr;
    wire [31:0] tap_data;
    wire [31:0] o_mwr_ram_addr, o_mrd_ram_addr;

    rt0101_dma_request_ctrl u_ctrl (
        .clk(clk), .rst_n(rst_n),
        .i_mwr_req_en(i_mwr_req_en), .i_tlp_req_addr(i_tlp_req_addr),
        .i_mwr_req_data(i_mwr_req_data), .i_tlp_req_dwbe(i_tlp_req_dwbe),
        .i_bar_sel(i_bar_sel),
        .i_mwr32_req_ack(i_mwr32_req_ack), .i_mwr64_req_ack(i_mwr64_req_ack),
        .i_mrd32_req_ack(i_mrd32_req_ack), .i_mrd64_req_ack(i_mrd64_req_ack),
        .o_mwr32_req(o_mwr32_req), .o_mwr64_req(o_mwr64_req),
        .o_mrd32_req(o_mrd32_req), .o_mrd64_req(o_mrd64_req),
        .o_mem_length(o_mem_length), .o_mem_addr(o_mem_addr),
        .o_mwr_ext_length(o_mwr_ext_length), .o_mrd_ext_length(o_mrd_ext_length),
        .o_mrd_max_out(o_mrd_max_out), .o_chk_seed(o_chk_seed), .o_mrd_abort(o_mrd_abort),
        .o_bar1_tap_vld(tap_vld), .o_bar1_tap_addr(tap_addr), .o_bar1_tap_data(tap_data),
        .o_mwr_ram_addr(o_mwr_ram_addr), .o_mrd_ram_addr(o_mrd_ram_addr)
    );

    // ext regs
    reg  [11:0] rd_addr = 0;
    wire [127:0]rd128;
    wire        cfg_tgl, commit_tgl;
    wire [15:0] cfg_ctrl;
    wire [31:0] cfg_fb_base, cfg_slot_size, cfg_stride, cfg_uv_off;
    wire [1:0]  commit_slot;
    wire [15:0] commit_fid;
    wire [7:0]  led_host, led_oe;
    reg  [159:0]stat_bus = 0;
    reg         stat_tgl = 0;
    reg  [4:0]  key_stat = 5'b00101;   // pressed bits 0 and 2

    rt_ext_regs u_ext (
        .clk(clk), .rst_n(rst_n),
        .i_tap_vld(tap_vld), .i_tap_addr(tap_addr), .i_tap_data(tap_data),
        .i_rd_addr(rd_addr), .o_rd128(rd128),
        .cfg_tgl(cfg_tgl), .cfg_ctrl(cfg_ctrl), .cfg_fb_base(cfg_fb_base),
        .cfg_slot_size(cfg_slot_size), .cfg_stride(cfg_stride), .cfg_uv_off(cfg_uv_off),
        .commit_tgl(commit_tgl), .commit_slot(commit_slot), .commit_frame_id(commit_fid),
        .i_stat_tgl(stat_tgl), .i_stat_bus(stat_bus),
        .i_key_stat(key_stat), .o_led_host(led_host), .o_led_oe(led_oe),
        .i_hdmi_stat_tgl(1'b0), .i_hdmi_stat_bus(32'd0), .o_hdmi_reinit_tgl()
    );

    // sticky monitor of old decode enables
    reg old_any;
    always @(posedge clk)
        if (u_ctrl.rd_l_addr_en || u_ctrl.wr_l_addr_en || u_ctrl.rd_h_addr_en ||
            u_ctrl.wr_h_addr_en || u_ctrl.rd_data_length_en || u_ctrl.wr_data_length_en ||
            u_ctrl.mrd_ram_addr_en || u_ctrl.mwr_ram_addr_en)
            old_any <= 1'b1;

    integer errs = 0;
    task chk; input [1023:0] name; input [127:0] got; input [127:0] exp;
        begin
            if (got !== exp) begin
                errs = errs+1;
                $display("[T6] FAIL %0s got %032x exp %032x", name, got, exp);
            end else
                $display("[T6] ok   %0s = %032x", name, got);
        end
    endtask

    task tap_wr; input [11:0] a; input [31:0] d;
        begin
            @(posedge clk);
            i_bar_sel      <= 3'b1;
            i_mwr_req_en   <= 1'b1;
            i_tlp_req_addr <= {52'b0, a};
            i_mwr_req_data <= {96'b0, d};
            i_tlp_req_dwbe <= 4'hF;
            @(posedge clk);
            i_mwr_req_en   <= 1'b0;
            repeat(4) @(posedge clk);
        end
    endtask

    task rd_grp; input [11:0] a; output [127:0] d;
        begin
            rd_addr <= a;
            repeat(3) @(posedge clk);
            d = rd128;
            @(posedge clk);
        end
    endtask

    reg [127:0] d128;
    initial begin
        rst_n=0; i_mwr_req_en=0; i_tlp_req_addr=0; i_mwr_req_data=0;
        i_tlp_req_dwbe=0; i_bar_sel=0;
        i_mwr32_req_ack=0; i_mwr64_req_ack=0; i_mrd32_req_ack=0; i_mrd64_req_ack=0;
        old_any=0;
        repeat(10) @(posedge clk);
        rst_n=1;
        repeat(5) @(posedge clk);

        // ---- defaults
        rd_grp(12'h800, d128);
        chk("DISP_CTRL def",  d128[31:0],   32'h0000_0004);
        chk("FB_BASE def",    d128[63:32],  32'h0400_0000);
        chk("SLOT_SIZE def",  d128[95:64],  32'h0040_0000);
        chk("STRIDE def",     d128[127:96], 32'h0000_0780);
        rd_grp(12'h810, d128);
        chk("UV_OFF def",     d128[31:0],   32'h001F_A400);
        rd_grp(12'h830, d128);
        chk("EXT_VERSION",    d128[95:64],  32'h2026_1019);
        chk("EXT_MAGIC",      d128[127:96], 32'h4F53_4431);   // 20261018 osd1: "OSD1"
        rd_grp(12'h840, d128);
        chk("KEY_STAT",       d128[31:0],   {27'b0, 5'b00101});   // 20261018 review: pressed = 1
        chk("LED_CTRL def",   d128[127:96], 32'h0);

        // ---- writes
        tap_wr(12'h800, 32'h0000_0015);   // video_en, osd_en, csc
        tap_wr(12'h804, 32'h1234_5ABC);   // -> 0x12345000
        tap_wr(12'h808, 32'h0023_4FFF);   // -> 0x00234000
        tap_wr(12'h80C, 32'h0000_0FFF);   // -> 0x00000FE0
        tap_wr(12'h810, 32'h0000_ABCD);   // -> 0x0000ABA0
        tap_wr(12'h84C, 32'h00FF_0055);   // led
        rd_grp(12'h800, d128);
        chk("DISP_CTRL w",  d128[31:0],   32'h0000_0015);
        chk("FB_BASE w",    d128[63:32],  32'h1234_5000);
        chk("SLOT_SIZE w",  d128[95:64],  32'h0023_4000);
        chk("STRIDE w",     d128[127:96], 32'h0000_0FE0);
        rd_grp(12'h810, d128);
        chk("UV_OFF w",     d128[31:0],   32'h0000_ABC0);
        rd_grp(12'h840, d128);
        chk("LED_CTRL w",   d128[127:96], 32'h00FF_0055);

        // ---- 0x900 / 0xA00 must not touch old regs
        tap_wr(12'h900, 32'hDEAD_BEEF);
        tap_wr(12'hA00, 32'h1234_5678);
        repeat(4) @(posedge clk);
        if (old_any) begin errs=errs+1; $display("[T6] FAIL old decode triggered"); end
        else $display("[T6] ok   old decode not triggered by 0x900/0xA00");
        if (u_ctrl.rd_l_addr !== 32'h0) begin errs=errs+1; $display("[T6] FAIL rd_l_addr changed"); end
        else $display("[T6] ok   rd_l_addr untouched");
        if (u_ctrl.wr_l_addr !== 32'h0) begin errs=errs+1; $display("[T6] FAIL wr_l_addr changed"); end
        else $display("[T6] ok   wr_l_addr untouched");

        // ---- sanity: 0x100 IS decoded (rd_l_addr)
        tap_wr(12'h100, 32'hCAFE_0001);
        repeat(2) @(posedge clk);
        if (u_ctrl.rd_l_addr !== 32'hCAFE_0001) begin errs=errs+1;
            $display("[T6] FAIL 0x100 not decoded (%08x)", u_ctrl.rd_l_addr); end
        else $display("[T6] ok   0x100 decoded");

        if (errs==0) $display("T6 PASS"); else $display("T6 FAIL errs=%0d", errs);
        $finish;
    end
endmodule
