`timescale 1ns/1ps
//////////////////////////////////////////////////////////////////////////////
// rt_ext_regs.v  (20261018 osd1)
// BAR1 extended register file for the display path.  pclk_div2 domain.
//   - write : tap bus (i_tap_vld / i_tap_addr[11:0] / i_tap_data[31:0])
//   - read  : registered 128-bit group output (o_rd128)
//   - config  -> pixel domain (cfg_tgl + raw values, pixel domain syncs)
//   - commit  -> pixel domain (commit_tgl + {slot,frame_id})
//   - status  <- pixel/ddr domain (i_stat_tgl + i_stat_bus), latched here
//   - osd registers -> pixel domain snapshot (o_osd_tgl + o_osd_cfg)
//   - key events / drive state / cal save <- pixel+free domains (toggle)
//   - text RAM write forwarded to the pixel-domain dual-clock RAM
//   - keys    <- free domain debounced (i_key_stat)
//   - LED host control -> top
//   - HDMI (MS7210) : 0x834 R HDMI_STAT {sta_0502[31:24], nack_cnt[23:16], init_over_rx[15], sta_valid[14], ms7210_state[13:8], reinit_cnt[7:4], ri_hold[3], rx_go[2], nack_sticky[1], init_over[0]}; W HDMI_CTRL bit0=1 re-init MS7210
//////////////////////////////////////////////////////////////////////////////
module rt_ext_regs
(
    input               clk             ,   // pclk_div2
    input               rst_n           ,

    // write tap
    input               i_tap_vld       ,
    input       [11:0]  i_tap_addr      ,
    input       [31:0]  i_tap_data      ,

    // read tap
    input       [11:0]  i_rd_addr       ,
    output reg  [127:0] o_rd128         ,

    // config -> pixel domain
    output reg          cfg_tgl         ,
    output reg  [15:0]  cfg_ctrl        ,   // [0]video_en [1]pat_force [2]osd_en
                                            // [4]csc_sel [5]quad_en [6]cam_off [12]byte_swap
                                            // [13]dw_swap [14]half_swap
    output reg  [31:0]  cfg_fb_base     ,
    output reg  [31:0]  cfg_slot_size   ,
    output reg  [31:0]  cfg_stride      ,
    output reg  [31:0]  cfg_uv_off      ,

    // commit -> pixel domain
    output reg          commit_tgl      ,
    output reg  [1:0]   commit_slot     ,
    output reg  [15:0]  commit_frame_id ,

    // status <- pixel/ddr domain
    input               i_stat_tgl      ,
    input       [159:0] i_stat_bus      ,

    // osd register snapshot -> pixel domain
    output reg          o_osd_tgl       ,
    output wire [1065:0]o_osd_cfg       ,

    // text RAM write -> pixel domain dual-clock RAM (write side here)
    output wire         o_tram_we        ,
    output wire [5:0]   o_tram_addr      ,
    output wire [31:0]  o_tram_data      ,

    // key events <- free domain (toggle handshake)
    input               i_evt_tgl       ,
    input       [2:0]   i_evt_key       ,
    input       [1:0]   i_evt_type      ,
    input       [5:0]   i_evt_step      ,

    // drive state <- pixel domain (toggle handshake)
    input               i_drv_tgl       ,
    input       [9:0]   i_drv_bus       ,

    // calibration save <- pixel domain (toggle handshake)
    input               i_cal_tgl       ,
    input       [59:0]  i_cal_bus       ,

    // keys (free domain, debounced) - active-high pressed
    input       [4:0]   i_key_stat      ,

    // LED host control
    output wire [7:0]   o_led_host      ,
    output wire [7:0]   o_led_oe        ,

    // 20261019 osd1d: HDMI (MS7210) re-init + status
    output reg          o_hdmi_reinit_tgl = 1'b0,   // pclk_div2 domain toggle to cfg_clk
    output reg          o_hdmi_rx_en      = 1'b0,   // 20261028: pclk_div2 domain MS7200 enable to cfg_clk
    input               i_hdmi_stat_tgl         ,   // cfg_clk domain toggle
    input       [31:0]  i_hdmi_stat_bus         ,   // cfg_clk domain snapshot

    // 20261026 cam diag : read-only camera status (BAR1 0x8A0 / 0x8A4)
    //   every input below is asynchronous to clk (pclk_div2) and is
    //   synchronized inside this module
    input               i_cam_cfg_done          ,   // reg_config reg_conf_done (free_clk)
    input               i_cam_initial_en        ,   // power_on_delay initial_en (free_clk)
    input               i_cam_vsync             ,   // cmos1_vsync pad (cmos1_pclk domain)
    input               i_cam_href              ,   // cmos1_href  pad (cmos1_pclk domain)
    input               i_cam_pclk_tgl          ,   // cmos1_pclk activity toggle
    input               i_cam_href16            ,   // cam1_href_16bit (pclk_16bit domain)
    input               i_cam_pclk_rst_n        ,   // camera pixel domain reset released
    input               i_por_done              ,   // power-on done (free_clk)
    input       [7:0]   i_cam_vs_cnt16          ,   // vsync edges, pclk_16bit domain, saturated
    input       [31:0]  i_cam_wr_stat           ,   // cam_ddr_writer o_stat
    input       [31:0]  i_cam_urg_cnt           ,   // MRd pause episodes (0x8A8)

    // 20261027 stats : bypass lane detection stats (BAR1 0x8B0 - 0x8BC)
    output wire [8:0]   o_stats_ctrl            ,
    input       [95:0]  i_stats_bus             ,
    input               i_stats_tgl             ,

    // 20261028 lane detection & decision registers (BAR1 0x8C0 - 0x8EC, 0xA00 - 0xA1C)
    output wire [159:0] o_lane_cfg_bus          ,
    output reg          o_lane_cfg_tgl = 1'b0   ,
    input       [223:0] i_lane_stat_bus         ,
    input       [223:0] i_lane_dbg_bus          ,
    input               i_lane_stat_tgl         ,

    // 20261029 zebra detection registers (BAR1 0xA20 - 0xA2C)
    output wire [47:0]  o_zebra_cfg_bus         ,
    output reg          o_zebra_cfg_tgl = 1'b0  ,
    input       [95:0]  i_zebra_stat_bus        ,
    input               i_zebra_stat_tgl
);


    //------------------------------------------------------------------
    // registers
    //------------------------------------------------------------------
    reg [31:0] reg_disp_ctrl;
    reg [31:0] reg_fb_base;
    reg [31:0] reg_slot_size;
    reg [31:0] reg_stride;
    reg [31:0] reg_uv_off;
    reg [31:0] reg_led_ctrl;

    // 20261027 stats registers
    reg [8:0]  reg_stats_ctrl;
    assign o_stats_ctrl = reg_stats_ctrl;

    // 20261028 lane registers
    reg [31:0] reg_lane_ctrl;
    reg [31:0] reg_lane_geom;
    reg [31:0] reg_lane_roi;
    reg [31:0] reg_lane_thr;
    reg [31:0] reg_lane_dbg_sel;

    // 20261029 zebra registers
    reg [31:0] reg_zebra_ctrl;
    reg [31:0] reg_zebra_gap;
    assign o_zebra_cfg_bus = { reg_zebra_gap[7:0], 8'd0, reg_zebra_ctrl };
    assign o_lane_cfg_bus = { reg_lane_dbg_sel, reg_lane_thr, reg_lane_roi, reg_lane_geom, reg_lane_ctrl };

    // osd registers

    reg [31:0] reg_decision;
    reg [31:0] reg_osd_ctrl;
    reg [31:0] box_lo [0:15];
    reg [31:0] box_hi [0:15];
    reg        cal_valid;
    reg        cal_src;
    reg [7:0]  cal_seq;
    reg [31:0] cal_vp, cal_band, cal_guide;
    reg [31:0] auto_vp, auto_band;
    reg [31:0] live_vp;
    reg [31:0] bev_ctrl;

    // latched key event / drive state
    reg [7:0]  evt_seq;
    reg [2:0]  evt_key_r;
    reg [1:0]  evt_type_r;
    reg [5:0]  evt_step_r;
    reg [9:0]  drv_r;

    integer    bi;

    // status latched in pclk domain
    reg [31:0] stat_dbg;
    reg [31:0] stat_underflow;
    reg [31:0] stat_newfr;
    reg [31:0] stat_frames;
    reg [15:0] stat_frame_id;
    reg        stat_video_active;
    reg [1:0]  stat_slot;
    reg        stat_night_active;
    reg [7:0]  stat_night_mean;

    //------------------------------------------------------------------
    // write decode
    //------------------------------------------------------------------
    wire in_box = (i_tap_addr >= 12'h900) && (i_tap_addr <= 12'h97F);
    wire in_tram= (i_tap_addr >= 12'hC00) && (i_tap_addr <= 12'hCFF);
    wire [3:0] boxi = i_tap_addr[6:3];

    // calibration save handshake (pixel -> pclk)
    reg ca_s1, ca_s2, ca_s2d;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin ca_s1<=0; ca_s2<=0; ca_s2d<=0; end
        else        begin ca_s1<=i_cal_tgl; ca_s2<=ca_s1; ca_s2d<=ca_s2; end
    wire ca_edge = ca_s2 ^ ca_s2d;

    always @(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
        begin
            reg_disp_ctrl <= 32'h0000_0004;
            reg_fb_base   <= 32'h0400_0000;
            reg_slot_size <= 32'h0040_0000;
            reg_stride    <= 32'd1920;
            reg_uv_off    <= 32'h001F_A400;
            reg_led_ctrl  <= 32'h0000_0000;
            reg_decision  <= 32'h0000_0000;
            reg_osd_ctrl  <= 32'h0000_0060;
            cal_valid     <= 1'b0;
            cal_src       <= 1'b0;
            cal_seq       <= 8'd0;
            cal_vp        <= 32'd0;
            cal_band      <= 32'd0;
            cal_guide     <= 32'd0;
            auto_vp       <= 32'd0;
            auto_band     <= 32'd0;
            live_vp       <= 32'd0;
            bev_ctrl      <= 32'd0;
            reg_stats_ctrl<= {8'd48, 1'b0};
            reg_lane_ctrl <= 32'h0000_0003;
            reg_lane_geom <= {6'd0, 10'd480, 6'd0, 10'd480}; // [25:16]=ego_x(480), [9:0]=x_c(480)
            reg_lane_roi  <= {6'd0, 10'd500, 6'd0, 10'd260}; // [25:16]=y_bot(500), [9:0]=y_top(260)
            reg_lane_thr  <= {8'd60, 8'd14, 8'd120, 8'd18};  // [31:24]=60, [23:16]=14, [15:8]=120, [7:0]=18
            reg_lane_dbg_sel <= {6'd0, 10'd480, 6'd0, 10'd360}; // [25:16]=dbg_x(480), [9:0]=dbg_row(360)
            o_lane_cfg_tgl<= 1'b0;
            // 20261029 zebra defaults
            reg_zebra_ctrl  <= 32'd0;
            reg_zebra_gap   <= 32'd0;
            o_zebra_cfg_tgl <= 1'b0;
            for (bi=0; bi<16; bi=bi+1) begin box_lo[bi]<=32'd0; box_hi[bi]<=32'd0; end
            cfg_tgl       <= 1'b0;
            commit_tgl    <= 1'b0;
            commit_slot   <= 2'b0;
            commit_frame_id <= 16'b0;

        end
        else
        begin
            if (ca_edge)
            begin
                cal_vp    <= { {4'd0,i_cal_bus[47:36]}, {4'd0,i_cal_bus[59:48]} }; // {vp_y, vp_x}
                cal_band  <= { {4'd0,i_cal_bus[23:12]}, {4'd0,i_cal_bus[35:24]} }; // {y_bot, y_top}
                cal_guide <= { 16'd0, i_cal_bus[11:0] };                           // {g}
                cal_valid <= 1'b1;
                cal_src   <= 1'b1;
                cal_seq   <= cal_seq + 1'b1;
            end
            else if (i_tap_vld && i_tap_addr[11])
            begin
                if (in_tram) begin
                    // text RAM forwarded to the pixel domain (nothing stored here)
                end
                else if (in_box) begin
                    if (i_tap_addr[2]) box_hi[boxi] <= i_tap_data;
                    else               box_lo[boxi] <= i_tap_data;
                end
                else case (i_tap_addr)
                    12'h800: begin
                        reg_disp_ctrl <= i_tap_data;
                        cfg_tgl       <= ~cfg_tgl;
                    end
                    12'h804: begin
                        reg_fb_base   <= {i_tap_data[31:12], 12'b0};
                        cfg_tgl       <= ~cfg_tgl;
                    end
                    12'h808: begin
                        reg_slot_size <= {i_tap_data[31:12], 12'b0};
                        cfg_tgl       <= ~cfg_tgl;
                    end
                    12'h80C: begin
                        reg_stride    <= {i_tap_data[31:5], 5'b0};
                        cfg_tgl       <= ~cfg_tgl;
                    end
                    12'h810: begin
                        reg_uv_off    <= {i_tap_data[31:5], 5'b0};
                        cfg_tgl       <= ~cfg_tgl;
                    end
                    12'h814: begin
                        commit_slot     <= i_tap_data[1:0];
                        commit_frame_id <= i_tap_data[31:16];
                        commit_tgl      <= ~commit_tgl;
                    end
                    12'h84C: begin
                        reg_led_ctrl    <= i_tap_data;
                    end
                    12'h850: begin
                        reg_decision <= i_tap_data;
                    end
                    12'h880: begin
                        reg_osd_ctrl <= i_tap_data;
                    end
                    12'h980: begin
                        cal_valid <= i_tap_data[0];
                        cal_src   <= i_tap_data[3];
                    end
                    12'h984: begin cal_vp    <= i_tap_data; end
                    12'h988: begin cal_band  <= i_tap_data; end
                    12'h98C: begin cal_guide <= i_tap_data; end
                    12'h990: begin auto_vp   <= i_tap_data; end
                    12'h994: begin auto_band <= i_tap_data; end
                    12'h998: begin live_vp   <= i_tap_data; end
                    12'h9A0: begin bev_ctrl  <= i_tap_data; end
                    12'h8B0: begin
                        reg_stats_ctrl[0] <= i_tap_data[0];
                        if (i_tap_data[15:8] != 8'd0)
                            reg_stats_ctrl[8:1] <= i_tap_data[15:8];
                        else if (i_tap_data[8:1] != 8'd0)
                            reg_stats_ctrl[8:1] <= i_tap_data[8:1];
                    end
                    12'h8C0: begin reg_lane_ctrl <= i_tap_data; o_lane_cfg_tgl <= ~o_lane_cfg_tgl; end
                    12'h8C4: begin reg_lane_geom <= i_tap_data; o_lane_cfg_tgl <= ~o_lane_cfg_tgl; end
                    12'h8C8: begin reg_lane_roi  <= i_tap_data; o_lane_cfg_tgl <= ~o_lane_cfg_tgl; end
                    12'h8CC: begin reg_lane_thr  <= i_tap_data; o_lane_cfg_tgl <= ~o_lane_cfg_tgl; end
                    12'hA00: begin reg_lane_dbg_sel <= i_tap_data; o_lane_cfg_tgl <= ~o_lane_cfg_tgl; end
                    12'hA20: begin reg_zebra_ctrl <= i_tap_data; o_zebra_cfg_tgl <= ~o_zebra_cfg_tgl; end
                    12'hA2C: begin reg_zebra_gap  <= i_tap_data; o_zebra_cfg_tgl <= ~o_zebra_cfg_tgl; end
                    default: ;

                endcase
            end
        end
    end

    //------------------------------------------------------------------
    // 20261019 osd1d / 20261028: HDMI_CTRL write @0x834:
    // bit0=1 -> re-run MS7210 init in cfg_clk domain.
    // bit1   -> rx_en (enable MS7200 after MS7210 init, default 0).
    // Toggle has no reset on purpose (a PCIe/core reset must not trigger a re-init).
    //------------------------------------------------------------------
    wire hdmi_wr = i_tap_vld && (i_tap_addr == 12'h834);
    always @(posedge clk) if (hdmi_wr && i_tap_data[0]) o_hdmi_reinit_tgl <= ~o_hdmi_reinit_tgl;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            o_hdmi_rx_en <= 1'b0;
        else if (hdmi_wr)
            o_hdmi_rx_en <= i_tap_data[1];
    end

    // HDMI_STAT from cfg_clk: bus is stable +-800 ns around each toggle; sync regs have no reset.
    reg hs_s1 = 1'b0, hs_s2 = 1'b0, hs_s2d = 1'b0;
    reg [31:0] hdmi_stat_r = 32'd0;
    always @(posedge clk) begin
        hs_s1 <= i_hdmi_stat_tgl; hs_s2 <= hs_s1; hs_s2d <= hs_s2;
        if (hs_s2 ^ hs_s2d) hdmi_stat_r <= i_hdmi_stat_bus;
    end

    //------------------------------------------------------------------
    // text RAM write (pclk -> pixel dual-clock RAM, write side)
    //------------------------------------------------------------------
    assign o_tram_we   = i_tap_vld && in_tram;
    assign o_tram_addr = i_tap_addr[7:2];
    assign o_tram_data = i_tap_data;

    //------------------------------------------------------------------
    // config bus -> pixel domain
    //------------------------------------------------------------------
    always @(*)
    begin
        cfg_ctrl    = 16'd0;
        cfg_ctrl[0] = reg_disp_ctrl[0];
        cfg_ctrl[1] = reg_disp_ctrl[1];
        cfg_ctrl[2] = reg_disp_ctrl[2];
        cfg_ctrl[4] = reg_disp_ctrl[4];
        cfg_ctrl[5] = reg_disp_ctrl[5];   // 20261026 quad: QUAD_EN
        cfg_ctrl[6] = reg_disp_ctrl[6];   // 20261027 cam: CAM_OFF
        cfg_ctrl[8] = reg_disp_ctrl[8];   // 20261029 view_mode[0]
        cfg_ctrl[9] = reg_disp_ctrl[9];   // 20261029 view_mode[1]
        cfg_ctrl[10]= reg_disp_ctrl[10];  // 20261101 night_mode[0]
        cfg_ctrl[11]= reg_disp_ctrl[11];  // 20261101 night_mode[1]
        cfg_ctrl[12]= reg_disp_ctrl[12];
        cfg_ctrl[13]= reg_disp_ctrl[13];
        cfg_ctrl[14]= reg_disp_ctrl[14];
        cfg_fb_base   = reg_fb_base;
        cfg_slot_size = reg_slot_size;
        cfg_stride    = reg_stride;
        cfg_uv_off    = reg_uv_off;
    end

    assign o_led_host = reg_led_ctrl[7:0];
    assign o_led_oe   = reg_led_ctrl[15:8];

    //------------------------------------------------------------------
    // OSD register snapshot -> pixel domain
    //------------------------------------------------------------------
    wire [831:0] box_flat;
    genvar gi;
    generate
        for (gi=0; gi<16; gi=gi+1) begin: gbox
            assign box_flat[52*gi +: 52] =
                { box_lo[gi][31:28], box_hi[gi][27:16], box_hi[gi][11:0],
                  box_lo[gi][27:16], box_lo[gi][11:0] };
        end
    endgenerate

    assign o_osd_cfg = { box_flat, cal_seq, cal_src, cal_valid,
                         auto_band, auto_vp, cal_guide, cal_band, cal_vp,
                         reg_osd_ctrl, reg_decision };

    //------------------------------------------------------------------
    // key event capture (free -> pclk)
    //------------------------------------------------------------------
    reg ev_s1, ev_s2, ev_s2d;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin ev_s1<=0; ev_s2<=0; ev_s2d<=0; end
        else        begin ev_s1<=i_evt_tgl; ev_s2<=ev_s1; ev_s2d<=ev_s2; end
    wire ev_edge = ev_s2 ^ ev_s2d;

    always @(posedge clk or negedge rst_n)
    begin
        if (!rst_n) begin
            evt_seq<=8'd0; evt_key_r<=3'd0; evt_type_r<=2'd0; evt_step_r<=6'd0;
        end
        else if (ev_edge) begin
            evt_seq    <= evt_seq + 1'b1;
            evt_key_r  <= i_evt_key;
            evt_type_r <= i_evt_type;
            evt_step_r <= i_evt_step;
        end
    end

    wire [31:0] key_evt_w = { 10'd0, evt_step_r, 2'd0, evt_type_r, 1'b0, evt_key_r, evt_seq };

    //------------------------------------------------------------------
    // drive state capture (pixel -> pclk)
    //------------------------------------------------------------------
    reg dr_s1, dr_s2, dr_s2d;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin dr_s1<=0; dr_s2<=0; dr_s2d<=0; end
        else        begin dr_s1<=i_drv_tgl; dr_s2<=dr_s1; dr_s2d<=dr_s2; end
    wire dr_edge = dr_s2 ^ dr_s2d;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) drv_r <= 10'd0;
        else if (dr_edge) drv_r <= i_drv_bus;

    wire [31:0] drv_state_w = { 22'd0, drv_r };

    //------------------------------------------------------------------
    // OSD snapshot toggle : any host OSD write or a hardware cal save
    //------------------------------------------------------------------
    wire osd_reg_wr = i_tap_vld && i_tap_addr[11] &&
                      ( in_box ||
                       (i_tap_addr==12'h850) || (i_tap_addr==12'h880) ||
                       (i_tap_addr==12'h980) || (i_tap_addr==12'h984) ||
                       (i_tap_addr==12'h988) || (i_tap_addr==12'h98C) ||
                       (i_tap_addr==12'h990) || (i_tap_addr==12'h994) );
    wire osd_tgl_evt = osd_reg_wr || ca_edge;

    always @(posedge clk or negedge rst_n)
        if (!rst_n)                o_osd_tgl <= 1'b0;
        else if (osd_tgl_evt)      o_osd_tgl <= ~o_osd_tgl;

    //------------------------------------------------------------------
    // status capture : sync stat_tgl into pclk domain
    //------------------------------------------------------------------
    reg stat_s1, stat_s2, stat_s2d;
    always @(posedge clk or negedge rst_n)
    begin
        if (!rst_n) begin stat_s1<=1'b0; stat_s2<=1'b0; stat_s2d<=1'b0; end
        else        begin stat_s1<=i_stat_tgl; stat_s2<=stat_s1; stat_s2d<=stat_s2; end
    end
    wire stat_edge = stat_s2 ^ stat_s2d;

    always @(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
        begin
            stat_slot         <= 2'b0;
            stat_video_active <= 1'b0;
            stat_frame_id     <= 16'b0;
            stat_frames       <= 32'b0;
            stat_newfr        <= 32'b0;
            stat_underflow    <= 32'b0;
            stat_dbg          <= 32'b0;
            stat_night_active <= 1'b0;
            stat_night_mean   <= 8'd0;
        end
        else if (stat_edge)
        begin
            stat_slot         <= i_stat_bus[1:0];
            stat_video_active <= i_stat_bus[2];
            stat_frame_id     <= i_stat_bus[18:3];
            stat_frames       <= i_stat_bus[50:19];
            stat_newfr        <= i_stat_bus[82:51];
            stat_underflow    <= i_stat_bus[114:83];
            stat_dbg          <= i_stat_bus[146:115];
            stat_night_active <= i_stat_bus[147];
            stat_night_mean   <= i_stat_bus[155:148];
        end
    end

    //------------------------------------------------------------------
    // 20261026 cam : read-only camera diagnostics
    //   all inputs are asynchronous to clk -> 3 stage synchronizers here.
    //   The href edge counter is built in this (pclk_div2) domain; the
    //   pclk_16bit vsync counter is saturating in its own domain and only
    //   carried over through 2 stages (a read during an increment can be off
    //   by one for a single cycle, it is a diagnostic only).
    //   0x8A0 CAM_STAT0 = { 8'd0, href_cnt[7:0], vs16_cnt[7:0],
    //                       por_done, pclk_rst_n, href16, pclk_tgl,
    //                       href, vsync, initial_en, cfg_done }
    //   0x8A4 CAM_STAT1 = cam_ddr_writer.o_stat (32 bit)
    //------------------------------------------------------------------
    reg [2:0] cam_s_cfgdone, cam_s_initen, cam_s_vsync, cam_s_href;
    reg [2:0] cam_s_href16, cam_s_pclkrst, cam_s_pordone, cam_s_ptgl;
    reg [7:0] cam_vs16_s1, cam_vs16_s2;
    reg       cam_href_d;
    reg [7:0] cam_href_cnt;

    wire      cam_href_rise = cam_s_href[2] & ~cam_href_d;
    wire [7:0] cam_flags_w  = { cam_s_pordone[2], cam_s_pclkrst[2],
                                cam_s_href16[2],  cam_s_ptgl[2],
                                cam_s_href[2],    cam_s_vsync[2],
                                cam_s_initen[2],  cam_s_cfgdone[2] };
    wire [31:0] cam_stat0_w = { 8'd0, cam_href_cnt, cam_vs16_s2, cam_flags_w };
    wire [31:0] cam_stat1_w = i_cam_wr_stat;

    always @(posedge clk or negedge rst_n)
        if (!rst_n)
        begin
            cam_s_cfgdone  <= 3'd0;  cam_s_initen  <= 3'd0;
            cam_s_vsync    <= 3'd0;  cam_s_href    <= 3'd0;
            cam_s_href16   <= 3'd0;  cam_s_pclkrst <= 3'd0;
            cam_s_pordone  <= 3'd0;  cam_s_ptgl    <= 3'd0;
            cam_vs16_s1    <= 8'd0;  cam_vs16_s2   <= 8'd0;
            cam_href_d     <= 1'b0;  cam_href_cnt  <= 8'd0;
        end
        else
        begin
            cam_s_cfgdone  <= { cam_s_cfgdone[1:0],  i_cam_cfg_done   };
            cam_s_initen   <= { cam_s_initen[1:0],   i_cam_initial_en };
            cam_s_vsync    <= { cam_s_vsync[1:0],    i_cam_vsync      };
            cam_s_href     <= { cam_s_href[1:0],     i_cam_href       };
            cam_s_href16   <= { cam_s_href16[1:0],   i_cam_href16     };
            cam_s_pclkrst  <= { cam_s_pclkrst[1:0],  i_cam_pclk_rst_n };
            cam_s_pordone  <= { cam_s_pordone[1:0],  i_por_done       };
            cam_s_ptgl     <= { cam_s_ptgl[1:0],     i_cam_pclk_tgl   };
            cam_vs16_s1    <= i_cam_vs_cnt16;
            cam_vs16_s2    <= cam_vs16_s1;
            cam_href_d     <= cam_s_href[2];
            if (cam_href_rise && (cam_href_cnt != 8'hFF))
                cam_href_cnt <= cam_href_cnt + 1'b1;
        end

    //------------------------------------------------------------------
    // 20261027 stats : sync stats_tgl and latch shadow register
    //   Wait 2 clk cycles after edge detection before latching stats_bus
    //------------------------------------------------------------------
    reg st_s1, st_s2, st_s2d;
    reg [1:0] st_wait_cnt;
    reg [95:0] stats_shadow;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st_s1        <= 1'b0;
            st_s2        <= 1'b0;
            st_s2d       <= 1'b0;
            st_wait_cnt  <= 2'd0;
            stats_shadow <= 96'd0;
        end else begin
            st_s1  <= i_stats_tgl;
            st_s2  <= st_s1;
            st_s2d <= st_s2;

            if (st_s2 ^ st_s2d) begin
                st_wait_cnt <= 2'd2;
            end else if (st_wait_cnt == 2'd1) begin
                st_wait_cnt  <= 2'd0;
                stats_shadow <= i_stats_bus;
            end else if (st_wait_cnt != 2'd0) begin
                st_wait_cnt  <= st_wait_cnt - 1'b1;
            end
        end
    end

    //------------------------------------------------------------------
    // 20261028 lane : sync lane_stat_tgl and latch shadow register
    //   Wait 2 clk cycles after edge detection before latching lane_stat_bus
    //------------------------------------------------------------------
    reg ls_s1, ls_s2, ls_s2d;
    reg [1:0] ls_wait_cnt;
    reg [223:0] lane_stat_shadow;
    reg [223:0] lane_dbg_shadow;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ls_s1            <= 1'b0;
            ls_s2            <= 1'b0;
            ls_s2d           <= 1'b0;
            ls_wait_cnt      <= 2'd0;
            lane_stat_shadow <= 224'd0;
            lane_dbg_shadow  <= 224'd0;
        end else begin
            ls_s1  <= i_lane_stat_tgl;
            ls_s2  <= ls_s1;
            ls_s2d <= ls_s2;

            if (ls_s2 ^ ls_s2d) begin
                ls_wait_cnt <= 2'd2;
            end else if (ls_wait_cnt == 2'd1) begin
                ls_wait_cnt      <= 2'd0;
                lane_stat_shadow <= i_lane_stat_bus;
                lane_dbg_shadow  <= i_lane_dbg_bus;
            end else if (ls_wait_cnt != 2'd0) begin
                ls_wait_cnt      <= ls_wait_cnt - 1'b1;
            end
        end
    end

    //------------------------------------------------------------------
    // 20261029 zebra : sync zebra_stat_tgl and latch shadow register
    //------------------------------------------------------------------
    reg zs_s1, zs_s2, zs_s2d;
    reg [1:0] zs_wait_cnt;
    reg [95:0] zebra_stat_shadow;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            zs_s1             <= 1'b0;
            zs_s2             <= 1'b0;
            zs_s2d            <= 1'b0;
            zs_wait_cnt       <= 2'd0;
            zebra_stat_shadow <= 96'd0;
        end else begin
            zs_s1  <= i_zebra_stat_tgl;
            zs_s2  <= zs_s1;
            zs_s2d <= zs_s2;

            if (zs_s2 ^ zs_s2d) begin
                zs_wait_cnt <= 2'd2;
            end else if (zs_wait_cnt == 2'd1) begin
                zs_wait_cnt       <= 2'd0;
                zebra_stat_shadow <= i_zebra_stat_bus;
            end else if (zs_wait_cnt != 2'd0) begin
                zs_wait_cnt       <= zs_wait_cnt - 1'b1;
            end
        end
    end


    //------------------------------------------------------------------
    // read decode : 128-bit group selected by i_rd_addr[11:4]
    //------------------------------------------------------------------
    wire [31:0] fb_stat_w = { stat_frame_id, 4'd0, stat_night_mean, stat_night_active, stat_video_active, stat_slot };
    wire [31:0] key_stat_w = { 27'd0, i_key_stat };   // 20261018 review: pressed=1
    wire [31:0] led_rd_w   = reg_led_ctrl;
    wire [31:0] cal_ctrl_w = { cal_seq, 4'd0, cal_src, /*pause*/ drv_r[7], drv_r[7], cal_valid };
    // bit0 valid, bit1 mode(=drv[7]), bit2 pause(=drv[7]), bit3 src, bit8-15 seq

    function [31:0] bxlo; input [3:0] b; begin bxlo = box_lo[b]; end endfunction
    function [31:0] bxhi; input [3:0] b; begin bxhi = box_hi[b]; end endfunction

    always @(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
            o_rd128 <= 128'd0;
        else
        begin
            case (i_rd_addr[11:4])
                8'h80: o_rd128 <= { reg_stride    , reg_slot_size, reg_fb_base  , reg_disp_ctrl };
                8'h81: o_rd128 <= { 32'd0, 32'd0       , 32'd0        , reg_uv_off    };
                8'h82: o_rd128 <= { stat_underflow, stat_newfr, stat_frames, fb_stat_w };
                8'h83: o_rd128 <= { 32'h4F53_4431, 32'h2026_1101, hdmi_stat_r, stat_dbg };   // "OSD1", 0x838=0x20261101
                8'h84: o_rd128 <= { led_rd_w, drv_state_w, key_evt_w, key_stat_w };
                8'h85: o_rd128 <= { 32'd0, 32'd0, 32'd0, reg_decision };
                8'h88: o_rd128 <= { 32'd0, 32'd0, 32'd0, reg_osd_ctrl };
                8'h90: o_rd128 <= { bxhi(4'd1), bxlo(4'd1), bxhi(4'd0), bxlo(4'd0) };
                8'h91: o_rd128 <= { bxhi(4'd3), bxlo(4'd3), bxhi(4'd2), bxlo(4'd2) };
                8'h92: o_rd128 <= { bxhi(4'd5), bxlo(4'd5), bxhi(4'd4), bxlo(4'd4) };
                8'h93: o_rd128 <= { bxhi(4'd7), bxlo(4'd7), bxhi(4'd6), bxlo(4'd6) };
                8'h94: o_rd128 <= { bxhi(4'd9), bxlo(4'd9), bxhi(4'd8), bxlo(4'd8) };
                8'h95: o_rd128 <= { bxhi(4'd11),bxlo(4'd11),bxhi(4'd10),bxlo(4'd10) };
                8'h96: o_rd128 <= { bxhi(4'd13),bxlo(4'd13),bxhi(4'd12),bxlo(4'd12) };
                8'h97: o_rd128 <= { bxhi(4'd15),bxlo(4'd15),bxhi(4'd14),bxlo(4'd14) };
                8'h98: o_rd128 <= { cal_guide, cal_band, cal_vp, cal_ctrl_w };
                8'h99: o_rd128 <= { 32'd0, live_vp, auto_band, auto_vp };
                8'h9A: o_rd128 <= { 32'd0, 32'd0, 32'd0, bev_ctrl };
                // 20261026 cam : 0x8A0 CAM_STAT0, 0x8A4 CAM_STAT1 (read only)
                8'h8A: o_rd128 <= { 32'd0, i_cam_urg_cnt, cam_stat1_w, cam_stat0_w };   // 0x8A8 = cam MRd pause episodes
                // 20261027 stats : 0x8B0 CTRL, 0x8B4 CNT, 0x8B8 R180/90, 0x8BC R450/360
                8'h8B: o_rd128 <= {
                    {stats_shadow[87:80], stats_shadow[95:88], stats_shadow[71:64], stats_shadow[79:72]}, // 0x8BC: {row450_L, row450_R, row360_L, row360_R}
                    {stats_shadow[55:48], stats_shadow[63:56], stats_shadow[39:32], stats_shadow[47:40]}, // 0x8B8: {row180_L, row180_R, row90_L, row90_R}
                    {stats_shadow[15:0],  stats_shadow[31:16]},                                             // 0x8B4: {frame_cnt[15:0], edge_cnt[15:0]}
                    {23'd0, reg_stats_ctrl}                                                                 // 0x8B0: {23'd0, stats_ctrl[8:0]}
                };
                // 20261028 lane : 0x8C0 CTRL/GEOM/ROI/THR, 0x8D0 L_STAT/A/B/R_STAT, 0x8E0 R_A/B/STAT
                8'h8C: o_rd128 <= { reg_lane_thr, reg_lane_roi, reg_lane_geom, reg_lane_ctrl };
                8'h8D: o_rd128 <= { lane_stat_shadow[127:96], lane_stat_shadow[95:64], lane_stat_shadow[63:32], lane_stat_shadow[31:0] };
                8'h8E: o_rd128 <= { 32'd0, lane_stat_shadow[223:192], lane_stat_shadow[191:160], lane_stat_shadow[159:128] };
                // 20261028 lane debug : 0xA00 DBG_SEL, 0xA04-0xA0C, 0xA10-0xA1C
                8'hA0: o_rd128 <= { lane_dbg_shadow[95:64], lane_dbg_shadow[63:32], lane_dbg_shadow[31:0], reg_lane_dbg_sel };
                8'hA1: o_rd128 <= { lane_dbg_shadow[223:192], lane_dbg_shadow[191:160], lane_dbg_shadow[159:128], lane_dbg_shadow[127:96] };
                // 20261029 zebra : 0xA20 CTRL, 0xA24 STAT, 0xA28 FRAME, 0xA2C GAP
                8'hA2: o_rd128 <= { reg_zebra_gap, zebra_stat_shadow[63:32], zebra_stat_shadow[31:0], reg_zebra_ctrl };
                default: o_rd128 <= 128'd0;

            endcase
        end
    end

endmodule
