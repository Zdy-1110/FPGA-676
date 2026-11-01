`timescale 1ns/1ps
//////////////////////////////////////////////////////////////////////////////
// rt_disp_top.v  (20261018 osd1)
// Display subsystem: pixel clock PLL, MS7210 I2C init, 1080p60 timing,
// rt_disp_reader, OSD overlay (rt_keys/rt_osd_ctl/rt_osd), output register
// stage, LED/key handling.
//////////////////////////////////////////////////////////////////////////////
module rt_disp_top #(
    parameter H_ACT = 1920,
    parameter V_ACT = 1080
)(
    input               free_clk          ,   // 27 MHz
    input               core_clk          ,   // DDR core clock (125 MHz)
    input               core_rst_n        ,
    input               ddr_init_done     ,
    input               pclk_i            ,   // pclk_div2 (text RAM write clock)

    // config (from rt_ext_regs, pclk domain)
    input               cfg_tgl           ,
    input       [15:0]  cfg_ctrl          ,
    input       [31:0]  cfg_fb_base       ,
    input       [31:0]  cfg_slot_size     ,
    input       [31:0]  cfg_stride        ,
    input       [31:0]  cfg_uv_off        ,
    input               commit_tgl        ,
    input       [1:0]   commit_slot       ,
    input       [15:0]  commit_frame_id   ,

    // status back to rt_ext_regs
    output wire         stat_tgl          ,
    output wire [159:0] stat_bus          ,

    // 20261019 osd1d: HDMI (MS7210) re-init + status
    input               hdmi_reinit_tgl   ,   // pclk_div2 toggle from rt_ext_regs
    input               hdmi_rx_en        ,   // 20261028: pclk_div2 rx_en from rt_ext_regs
    output wire         hdmi_stat_tgl     ,   // cfg_clk domain toggle
    output wire [31:0]  hdmi_stat_bus     ,   // cfg_clk domain snapshot

    // 20261026 cam: window 0 (slot 0) commit comes from the camera frame
    // boundary, not from the host 0x814 write (which only serves slot 1..3)
    input               cam_commit_tgl    ,   // pclk_div2 domain toggle
    input      [15:0]   cam_commit_fid    ,   // camera frame counter
    input               cam_commit_buf    ,   // slot0 buffer the frame went to

    // osd register snapshot from rt_ext_regs (pclk domain)
    input               osd_cfg_tgl       ,
    input      [1065:0] osd_cfg           ,

    // text RAM write (pclk domain)
    input               tram_we           ,
    input      [5:0]    tram_addr         ,
    input      [31:0]   tram_wdata        ,

    // back to rt_ext_regs
    output wire         evt_tgl           ,
    output wire [2:0]   evt_key           ,
    output wire [1:0]   evt_type          ,
    output wire [5:0]   evt_step          ,
    output wire         drv_tgl           ,
    output wire [9:0]   drv_bus           ,
    output wire         cal_tgl           ,
    output wire [59:0]  cal_bus           ,

    // AXI read master (core domain) to arbiter port 1
    output wire [27:0]  m_araddr          ,
    output wire [3:0]   m_arlen           ,
    output wire         m_arvalid         ,
    input               m_arready         ,
    input       [255:0] m_rdata           ,
    input               m_rlast           ,
    input               m_rvalid          ,

    // LED / keys
    input       [7:0]   led_host          ,
    input       [7:0]   led_oe            ,
    input               rdlh_link_up      ,
    input       [4:0]   key_raw           ,
    output wire [7:0]   led               ,
    output wire [4:0]   key_stat          ,

    // 20261027 stats
    input       [8:0]   stats_ctrl        ,
    output wire [95:0]  stats_bus         ,
    output wire         stats_tgl         ,

    // 20261028 lane detection & decision registers (from/to rt_ext_regs)
    input       [159:0] lane_cfg_bus      ,
    input               lane_cfg_tgl      ,
    output wire [223:0] lane_stat_bus     ,
    output wire [223:0] lane_dbg_bus      ,
    output wire         lane_stat_tgl     ,

    // 20261029 zebra detection registers (from/to rt_ext_regs)
    input       [47:0]  zebra_cfg_bus     ,
    input               zebra_cfg_tgl     ,
    output wire [95:0]  zebra_stat_bus    ,
    output wire         zebra_stat_tgl    ,

    // HDMI

    output wire         pix_clk           ,
    output wire         vs_out            ,
    output wire         hs_out            ,
    output wire         de_out            ,
    output wire [7:0]   r_out             ,
    output wire [7:0]   g_out             ,
    output wire [7:0]   b_out             ,
    output wire         hd_scl            ,
    inout               hd_sda            ,
    output wire         rstn_out
);

    wire        cfg_clk;
    wire        locked;
    wire        rx_init_done;
    wire        init_over;

    //------------------------------------------------------------------
    // PLLs
    //------------------------------------------------------------------
    pll_pix148 u_pll_pix (
        .clkin1  (free_clk   ),
        .clkout0 (pix_clk  ),
        .lock    (locked     )
    );

    pll_cfg10 u_pll_cfg (
        .clkin1  (free_clk   ),
        .clkout0 (cfg_clk    ),
        .lock    (           )
    );


    //------------------------------------------------------------------
    // MS7210 init + 1ms reset (mirror of 4_12 top)
    //------------------------------------------------------------------
    ms72xx_ctl u_ms72xx_ctl (
        .clk          (cfg_clk     ),
        .rst_n        (rstn_out    ),
        .init_over_rx (rx_init_done),
        .init_over    (init_over   ),
        .iic_scl      (hd_scl      ),
        .iic_sda      (hd_sda      ),
        .rx_en        (hdmi_rx_en  ),   // 20261028
        .reinit_tgl   (hdmi_reinit_tgl),
        .stat_tgl     (hdmi_stat_tgl),
        .stat_bus     (hdmi_stat_bus)
    );

    reg [15:0] rstn_1ms;
    always @(posedge cfg_clk)
    begin
        if (!locked)                     rstn_1ms <= 16'd0;
        else if (rstn_1ms == 16'h2710)   rstn_1ms <= rstn_1ms;
        else                             rstn_1ms <= rstn_1ms + 1'b1;
    end

    assign rstn_out = (rstn_1ms == 16'h2710);

    //------------------------------------------------------------------
    // 1080p60 video timing
    //------------------------------------------------------------------
    localparam V_TOTAL = 12'd1125;
    localparam V_FP    = 12'd4;
    localparam V_BP    = 12'd36;
    localparam V_SYNC  = 12'd5;
    localparam H_TOTAL = 12'd2200;
    localparam H_FP    = 12'd88;
    localparam H_BP    = 12'd148;
    localparam H_SYNC  = 12'd44;

    wire        vs_reg, hs_reg, de_v;
    wire [11:0] act_x, act_y;

    sync_vg #(
        .X_BITS  (12), .Y_BITS (12),
        .V_TOTAL (V_TOTAL), .V_FP (V_FP), .V_BP (V_BP),
        .V_SYNC  (V_SYNC),  .V_ACT (V_ACT),
        .H_TOTAL (H_TOTAL), .H_FP (H_FP), .H_BP (H_BP),
        .H_SYNC  (H_SYNC),  .H_ACT (H_ACT)
    ) u_sync_vg (
        .clk    (pix_clk),
        .rstn   (rstn_out ),
        .vs_out (vs_reg   ),
        .hs_out (hs_reg   ),
        .de_out (de_v     ),
        .de_re  (         ),
        .x_act  (act_x    ),
        .y_act  (act_y    )
    );

    //------------------------------------------------------------------
    // display reader : legacy full screen (quad_en=0) or 4 quadrants
    //------------------------------------------------------------------
    wire [7:0]  rd_r, rd_g, rd_b;
    wire        rd_de, rd_hs, rd_vs;
    wire        vid_active;

    wire        quad_en = cfg_ctrl[5];          // 0x800 bit5 = QUAD_EN

    wire        lg_stat_tgl;
    wire [159:0]lg_stat_bus;
    wire        lg_vid_active;
    wire [27:0] lg_araddr;
    wire [3:0]  lg_arlen;
    wire        lg_arvalid, lg_arready;
    wire [255:0]lg_rdata;
    wire        lg_rlast, lg_rvalid;

    // the idle reader has its cfg_ctrl masked to 0 so it never starts a frame
    // (video_en=0) and therefore never touches DDR in the other mode
    wire [15:0] lg_ctrl = cfg_ctrl & {16{~quad_en}};

    rt_disp_reader #(
        .H_ACT (H_ACT),
        .V_ACT (V_ACT)
    ) u_reader (
        .pix_clk       (pix_clk     ),
        .pix_rst_n     (rstn_out      ),
        .cfg_tgl       (cfg_tgl       ),
        .cfg_ctrl      (lg_ctrl       ),
        .cfg_fb_base   (cfg_fb_base   ),
        .cfg_slot_size (cfg_slot_size ),
        .cfg_stride    (cfg_stride    ),
        .cfg_uv_off    (cfg_uv_off    ),
        .commit_tgl    (commit_tgl    ),
        .commit_slot   (commit_slot   ),
        .commit_frame_id(commit_frame_id),
        .stat_tgl      (lg_stat_tgl   ),
        .stat_bus      (lg_stat_bus   ),
        .vs            (vs_reg        ),
        .hs            (hs_reg        ),
        .de            (de_v          ),
        .x_act         (act_x         ),
        .y_act         (act_y         ),
        .r_out         (rd_r          ),
        .g_out         (rd_g          ),
        .b_out         (rd_b          ),
        .de_out        (rd_de         ),
        .hs_out        (rd_hs         ),
        .vs_out        (rd_vs         ),
        .video_active_o(lg_vid_active ),
        .core_clk      (core_clk      ),
        .core_rst_n    (core_rst_n    ),
        .m_araddr      (lg_araddr     ),
        .m_arlen       (lg_arlen      ),
        .m_arvalid     (lg_arvalid    ),
        .m_arready     (lg_arready    ),
        .m_rdata       (lg_rdata      ),
        .m_rlast       (lg_rlast      ),
        .m_rvalid      (lg_rvalid     )
    );

    //------------------------------------------------------------------
    // quad mode : four 960x540 window readers (2x2) on one AXI read port
    //   window 0 = (0,0)   window 1 = (960,0)
    //   window 2 = (0,540) window 3 = (960,540)
    //   slot mode (cfg_slot_size != 0): one 960x540 NV12 frame per camera,
    //     base_k = cfg_fb_base + k*cfg_slot_size, rows 0..539 of that slot
    //   crop mode (cfg_slot_size == 0): the four rectangles are cut out of one
    //     full size frame (stride 1920, uv_off 2073600)
    //   both reduce to  addr = cfg_base + row*stride + word*32, the crop
    //   offsets being folded into cfg_base / cfg_uv_off here.
    //------------------------------------------------------------------
    wire [31:0] q_base0 = cfg_fb_base;
    wire [31:0] q_base1 = cfg_fb_base + cfg_slot_size;
    wire [31:0] q_base2 = cfg_fb_base + {cfg_slot_size[30:0],1'b0};
    wire [31:0] q_base3 = q_base2 + cfg_slot_size;

    wire        q_crop = (cfg_slot_size == 32'd0);
    wire [15:0] q_ctrl = cfg_ctrl & {16{quad_en}};

    // row/column offsets of the crop mode (0 in slot mode)
    wire [31:0] q_yo = q_crop ? (32'd540 * cfg_stride) : 32'd0;
    wire [31:0] q_uo = q_crop ? (32'd270 * cfg_stride) : 32'd0;
    wire [31:0] q_xo = q_crop ? 32'd960 : 32'd0;

    // cfg_tgl delayed one pclk so the folded base below is already stable when
    // the window readers latch their shadow config
    reg         q_cfg_tgl;
    always @(posedge pclk_i or negedge rstn_out)
        if (!rstn_out) q_cfg_tgl <= 1'b0;
        else           q_cfg_tgl <= cfg_tgl;

    reg  [31:0] q0_base_r, q1_base_r, q2_base_r, q3_base_r;
    reg  [31:0] q0_uv_r,   q1_uv_r,   q2_uv_r,   q3_uv_r;
    always @(posedge pclk_i or negedge rstn_out)
        if (!rstn_out)
        begin
            q0_base_r<=32'd0; q1_base_r<=32'd0; q2_base_r<=32'd0; q3_base_r<=32'd0;
            q0_uv_r  <=32'd0; q1_uv_r  <=32'd0; q2_uv_r  <=32'd0; q3_uv_r  <=32'd0;
        end
        else
        begin
            q0_base_r <= q_base0;
            q1_base_r <= q_base1 + q_xo;
            q2_base_r <= q_base2 + q_yo;
            q3_base_r <= q_base3 + q_yo + q_xo;
            q0_uv_r   <= cfg_uv_off;
            q1_uv_r   <= cfg_uv_off + q_xo;
            q2_uv_r   <= cfg_uv_off + q_uo;
            q3_uv_r   <= cfg_uv_off + q_uo + q_xo;
        end

    //------------------------------------------------------------------
    // 20261026 cam : window 0 double buffer (slot0 = 2 x 1 MB)
    //   The camera commits its finished frame together with the buffer it was
    //   written into.  q0_base_buf follows that commit (taken in the pclk_i
    //   domain, where cam_commit_* live) and window 0 is re-configured with a
    //   dedicated toggle, so it latches the new base for the frame it is about
    //   to display.  Slot mode only : in crop mode the base stays cfg_fb_base.
    //------------------------------------------------------------------
    reg         ccb_s1, ccb_s2, ccb_s2d;
    always @(posedge pclk_i or negedge rstn_out)
        if (!rstn_out) begin ccb_s1<=1'b0; ccb_s2<=1'b0; ccb_s2d<=1'b0; end
        else           begin ccb_s1<=cam_commit_tgl; ccb_s2<=ccb_s1; ccb_s2d<=ccb_s2; end
    wire        ccb_edge = ccb_s2 ^ ccb_s2d;

    wire [7:0]  q0_r, q0_g, q0_b, q1_r, q1_g, q1_b;    wire [7:0]  q2_r, q2_g, q2_b, q3_r, q3_g, q3_b;
    wire [159:0]q0_sbus, q1_sbus, q2_sbus, q3_sbus;
    wire [27:0] q0_araddr, q1_araddr, q2_araddr, q3_araddr;
    wire [3:0]  q0_arlen, q1_arlen, q2_arlen, q3_arlen;
    wire        q0_de, q0_hs, q0_vs, q0_vid, q0_stgl;
    wire        q1_de, q1_hs, q1_vs, q1_vid, q1_stgl;
    wire        q2_de, q2_hs, q2_vs, q2_vid, q2_stgl;
    wire        q3_de, q3_hs, q3_vs, q3_vid, q3_stgl;
    wire        q0_arvalid, q0_arready, q0_rlast, q0_rvalid;
    wire        q1_arvalid, q1_arready, q1_rlast, q1_rvalid;
    wire        q2_arvalid, q2_arready, q2_rlast, q2_rvalid;
    wire        q3_arvalid, q3_arready, q3_rlast, q3_rvalid;

    //------------------------------------------------------------------
    // window 0 commit multiplexing (camera frame boundary ^ host slot 0)
    //------------------------------------------------------------------
    reg         hcmt_s1, hcmt_s2, hcmt_s2d;
    reg         host_s0_tgl;
    reg  [31:0] q0_base_buf;
    reg         q0_cfg_tgl;
    always @(posedge pclk_i or negedge rstn_out)
        if (!rstn_out) begin
            hcmt_s1 <= 1'b0; hcmt_s2 <= 1'b0; hcmt_s2d <= 1'b0; host_s0_tgl <= 1'b0;
            q0_base_buf <= 32'd0; q0_cfg_tgl <= 1'b0;
        end else begin
            hcmt_s1  <= commit_tgl;
            hcmt_s2  <= hcmt_s1;
            hcmt_s2d <= hcmt_s2;
            if (ccb_edge) begin
                q0_base_buf <= q_base0 + (cam_commit_buf ? 32'h0010_0000 : 32'd0);
                q0_cfg_tgl  <= ~q0_cfg_tgl;
            end
            if ((hcmt_s2 ^ hcmt_s2d) && (commit_slot == 2'd0)) begin
                q0_base_buf <= q_base0;
                q0_cfg_tgl  <= ~q0_cfg_tgl;
                host_s0_tgl <= ~host_s0_tgl;
            end
        end

    wire win0_commit_tgl = cam_commit_tgl ^ host_s0_tgl;

    reg         win0_tgl_d;
    reg [15:0]  win0_fid;
    always @(posedge pclk_i or negedge rstn_out)
        if (!rstn_out) begin
            win0_tgl_d <= 1'b0;
            win0_fid   <= 16'd0;
        end else begin
            win0_tgl_d <= win0_commit_tgl;
            if (win0_commit_tgl ^ win0_tgl_d)
                win0_fid <= win0_fid + 16'd1;
        end

    rt_disp_win_reader_rgb #(
        .H_ACT(H_ACT), .V_ACT(V_ACT),
        .WIN_X0(12'd0), .WIN_Y0(12'd0), .WIN_W(12'd960), .WIN_H(12'd540),
        .WIN_IDX(2'd0)
    ) u_qwin0 (
        .pix_clk       (pix_clk     ),
        .pix_rst_n     (rstn_out    ),
        .cfg_tgl       (q0_cfg_tgl ),
        .cfg_ctrl      (q_ctrl      ),
        .cfg_base      (q0_base_buf ),
        .cfg_stride    (cfg_stride  ),
        .cfg_uv_off    (q0_uv_r     ),
        // 20261027 cam : window 0 is committed by camera or host slot 0
        .commit_tgl    (win0_commit_tgl),
        .commit_slot   (2'd0        ),
        .commit_frame_id(win0_fid   ),
        .stat_tgl      (q0_stgl     ),
        .stat_bus      (q0_sbus     ),
        .video_active_o(q0_vid      ),
        .vs            (vs_reg      ),
        .hs            (hs_reg      ),
        .de            (de_v        ),
        .x_act         (act_x       ),
        .y_act         (act_y       ),
        .r_out         (q0_r        ),
        .g_out         (q0_g        ),
        .b_out         (q0_b        ),
        .de_out        (q0_de       ),
        .hs_out        (q0_hs       ),
        .vs_out        (q0_vs       ),
        .core_clk      (core_clk    ),
        .core_rst_n    (core_rst_n  ),
        .m_araddr      (q0_araddr   ),
        .m_arlen       (q0_arlen    ),
        .m_arvalid     (q0_arvalid  ),
        .m_arready     (q0_arready  ),
        .m_rdata       (m_rdata     ),
        .m_rlast       (q0_rlast    ),
        .m_rvalid      (q0_rvalid   )
    );

    //------------------------------------------------------------------
    // 20261027 stats : sync stats_ctrl into pix_clk and instantiate stats
    //------------------------------------------------------------------
    reg [8:0] stats_ctrl_s1, stats_ctrl_s2;
    always @(posedge pix_clk or negedge rstn_out) begin
        if (!rstn_out) begin
            stats_ctrl_s1 <= 9'd0;
            stats_ctrl_s2 <= 9'd0;
        end else begin
            stats_ctrl_s1 <= stats_ctrl;
            stats_ctrl_s2 <= stats_ctrl_s1;
        end
    end
    wire       stats_en_pix  = stats_ctrl_s2[0];
    wire [7:0] stats_thr_pix = stats_ctrl_s2[8:1];

    //------------------------------------------------------------------
    // 20261101 night enhancement : point (a) gamma & brightness stats
    //------------------------------------------------------------------
    wire        q0_ng_de, q0_ng_hs, q0_ng_vs;
    wire [7:0]  q0_ng_r, q0_ng_g, q0_ng_b;
    wire [7:0]  night_mean;
    wire        night_active;
    wire        night_auto_state;

    rt_night #(
        .PIXELS_PER_FRAME (960 * 540),
        .MULT_K           (8285),
        .SHIFT_N          (21),
        .PRE_SHIFT        (11)
    ) u_rt_night (
        .clk              (pix_clk         ),
        .rst_n            (rstn_out        ),
        .mode             (cfg_ctrl[11:10] ),
        .stat_valid       (q0_vid          ),
        .de_in            (q0_de           ),
        .hs_in            (q0_hs           ),
        .vs_in            (q0_vs           ),
        .r_in             (q0_r            ),
        .g_in             (q0_g            ),
        .b_in             (q0_b            ),
        .de_out           (q0_ng_de        ),
        .hs_out           (q0_ng_hs        ),
        .vs_out           (q0_ng_vs        ),
        .r_out            (q0_ng_r         ),
        .g_out            (q0_ng_g         ),
        .b_out            (q0_ng_b         ),
        .mean             (night_mean      ),
        .night_active     (night_active    ),
        .auto_state       (night_auto_state)
    );

    rt_disp_stats u_disp_stats (
        .pix_clk    (pix_clk      ),
        .rst_n      (rstn_out     ),
        .de         (q0_de        ),
        .vs         (q0_vs        ),
        .r          (q0_r         ),
        .g          (q0_g         ),
        .b          (q0_b         ),
        .enable     (stats_en_pix ),
        .thr        (stats_thr_pix),
        .stats_bus  (stats_bus    ),
        .stats_tgl  (stats_tgl    )
    );

    //------------------------------------------------------------------
    // 20261028 lane detection : sync lane_cfg into pix_clk & instantiate
    //------------------------------------------------------------------
    reg lc_s1, lc_s2, lc_s2d;
    reg [1:0] lc_wait_cnt;
    reg [159:0] lane_cfg_pix;

    always @(posedge pix_clk or negedge rstn_out) begin
        if (!rstn_out) begin
            lc_s1        <= 1'b0;
            lc_s2        <= 1'b0;
            lc_s2d       <= 1'b0;
            lc_wait_cnt  <= 2'd0;
            lane_cfg_pix <= { {6'd0, 10'd480, 6'd0, 10'd360}, {8'd60, 8'd14, 8'd120, 8'd18}, {6'd0, 10'd500, 6'd0, 10'd260}, {6'd0, 10'd480, 6'd0, 10'd480}, 32'h0000_0003 };
        end else begin
            lc_s1  <= lane_cfg_tgl;
            lc_s2  <= lc_s1;
            lc_s2d <= lc_s2;

            if (lc_s2 ^ lc_s2d) begin
                lc_wait_cnt <= 2'd2;
            end else if (lc_wait_cnt == 2'd1) begin
                lc_wait_cnt  <= 2'd0;
                lane_cfg_pix <= lane_cfg_bus;
            end else if (lc_wait_cnt != 2'd0) begin
                lc_wait_cnt  <= lc_wait_cnt - 1'b1;
            end
        end
    end

    wire [31:0] lane_ctrl_pix       = lane_cfg_pix[31:0];
    wire [9:0]  lane_xc_pix         = lane_cfg_pix[41:32];
    wire [9:0]  lane_ego_x_pix      = lane_cfg_pix[57:48];
    wire [9:0]  lane_ytop_pix       = lane_cfg_pix[73:64];
    wire [9:0]  lane_ybot_pix       = lane_cfg_pix[89:80];
    wire [7:0]  lane_w_delta_pix    = lane_cfg_pix[103:96];
    wire [7:0]  lane_w_gmin_pix     = lane_cfg_pix[111:104];
    wire [7:0]  lane_y_delta_pix    = lane_cfg_pix[119:112];
    wire [7:0]  lane_dep_margin_pix = lane_cfg_pix[127:120];
    wire [9:0]  lane_dbg_row_pix    = lane_cfg_pix[137:128];
    wire [9:0]  lane_dbg_x_pix      = lane_cfg_pix[153:144];
    wire [223:0] lane_dbg_bus_w;
    assign lane_dbg_bus = lane_dbg_bus_w;

    wire        lane_l_valid_w, lane_l_solid_w, lane_l_double_w;
    wire [31:0] lane_l_a_q16_w, lane_l_b_q4_w;
    wire [31:0] lane_l_xtop_q16_w, lane_l_dx_q16_w;
    wire [15:0] lane_l_x_bot_w;
    wire [7:0]  lane_l_n_w;

    wire        lane_r_valid_w, lane_r_solid_w, lane_r_double_w;
    wire [31:0] lane_r_a_q16_w, lane_r_b_q4_w;
    wire [31:0] lane_r_xtop_q16_w, lane_r_dx_q16_w;
    wire [15:0] lane_r_x_bot_w;
    wire [7:0]  lane_r_n_w;

    wire        lane_depart_w, lane_frame_done_w;
    wire [7:0]  lane_frame_cnt_w;

    rt_lane_det u_rt_lane_det (
        .pix_clk           (pix_clk           ),
        .rst_n             (rstn_out          ),
        .de                (q0_ng_de          ),
        .vs                (q0_ng_vs          ),
        .hs                (q0_ng_hs          ),
        .r                 (q0_ng_r           ),
        .g                 (q0_ng_g           ),
        .b                 (q0_ng_b           ),
        .cfg_det_en        (lane_ctrl_pix[0]  ),
        .cfg_xc            (lane_xc_pix       ),
        .cfg_ego_x         (lane_ego_x_pix    ),
        .cfg_y_top         (lane_ytop_pix     ),
        .cfg_y_bot         (lane_ybot_pix     ),
        .cfg_white_delta   (lane_w_delta_pix  ),
        .cfg_white_g_min   (lane_w_gmin_pix   ),
        .cfg_yellow_delta  (lane_y_delta_pix  ),
        .cfg_depart_margin (lane_dep_margin_pix),
        .out_l_valid       (lane_l_valid_w    ),
        .out_l_solid       (lane_l_solid_w    ),
        .out_l_double      (lane_l_double_w   ),
        .out_l_a_q16       (lane_l_a_q16_w    ),
        .out_l_b_q4        (lane_l_b_q4_w     ),
        .out_l_x_at_ytop_q16(lane_l_xtop_q16_w),
        .out_l_dx_q16      (lane_l_dx_q16_w   ),
        .out_l_x_bot       (lane_l_x_bot_w    ),
        .out_l_n           (lane_l_n_w        ),
        .out_r_valid       (lane_r_valid_w    ),
        .out_r_solid       (lane_r_solid_w    ),
        .out_r_double      (lane_r_double_w   ),
        .out_r_a_q16       (lane_r_a_q16_w    ),
        .out_r_b_q4        (lane_r_b_q4_w     ),
        .out_r_x_at_ytop_q16(lane_r_xtop_q16_w),
        .out_r_dx_q16      (lane_r_dx_q16_w   ),
        .out_r_x_bot       (lane_r_x_bot_w    ),
        .out_r_n           (lane_r_n_w        ),
        .out_depart        (lane_depart_w     ),
        .out_frame_done    (lane_frame_done_w ),
        .out_frame_cnt     (lane_frame_cnt_w  ),
        .dbg_row           (lane_dbg_row_pix  ),
        .dbg_x             (lane_dbg_x_pix    ),
        .dbg_bus           (lane_dbg_bus_w    )
    );

    wire [1:0]  lane_dec_state_w;
    wire        lane_eff_req_l_w, lane_eff_req_r_w, lane_eff_force_w;

    reg lane_stat_tgl_r;
    always @(posedge pix_clk or negedge rstn_out)
        if (!rstn_out) lane_stat_tgl_r <= 1'b0;
        else if (lane_frame_done_w) lane_stat_tgl_r <= ~lane_stat_tgl_r;
    assign lane_stat_tgl = lane_stat_tgl_r;

    assign lane_stat_bus = {
        // 0x8E8: [31:24] frame_cnt, [21] force, [20] req_r, [19] req_l, [18] depart, [17:16] dec, [15:8] r_n, [7:0] l_n
        lane_frame_cnt_w[7:0], 2'd0, lane_eff_force_w, lane_eff_req_r_w, lane_eff_req_l_w,
        lane_depart_w, lane_dec_state_w[1:0], lane_r_n_w[7:0], lane_l_n_w[7:0],
        // 0x8E4: R_B
        lane_r_b_q4_w,
        // 0x8E0: R_A
        lane_r_a_q16_w,
        // 0x8DC: R_STAT: [31:16] x_bot, [2] double, [1] solid, [0] valid
        lane_r_x_bot_w, 13'd0, lane_r_double_w, lane_r_solid_w, lane_r_valid_w,
        // 0x8D8: L_B
        lane_l_b_q4_w,
        // 0x8D4: L_A
        lane_l_a_q16_w,
        // 0x8D0: L_STAT: [31:16] x_bot, [2] double, [1] solid, [0] valid
        lane_l_x_bot_w, 13'd0, lane_l_double_w, lane_l_solid_w, lane_l_valid_w
    };

    //------------------------------------------------------------------
    // 20261029 zebra detection : sync zebra_cfg into pix_clk & instantiate
    //------------------------------------------------------------------
    reg zc_s1, zc_s2, zc_s2d;
    reg [1:0] zc_wait_cnt;
    reg [47:0] zebra_cfg_pix;

    always @(posedge pix_clk or negedge rstn_out) begin
        if (!rstn_out) begin
            zc_s1         <= 1'b0;
            zc_s2         <= 1'b0;
            zc_s2d        <= 1'b0;
            zc_wait_cnt   <= 2'd0;
            zebra_cfg_pix <= 48'd0;
        end else begin
            zc_s1  <= zebra_cfg_tgl;
            zc_s2  <= zc_s1;
            zc_s2d <= zc_s2;

            if (zc_s2 ^ zc_s2d) begin
                zc_wait_cnt <= 2'd2;
            end else if (zc_wait_cnt == 2'd1) begin
                zc_wait_cnt   <= 2'd0;
                zebra_cfg_pix <= zebra_cfg_bus;
            end else if (zc_wait_cnt != 2'd0) begin
                zc_wait_cnt   <= zc_wait_cnt - 1'b1;
            end
        end
    end

    wire        zebra_en_pix    = zebra_cfg_pix[0];
    wire [7:0]  zebra_nmin_pix  = zebra_cfg_pix[15:8];
    wire [15:0] zebra_span_pix  = zebra_cfg_pix[31:16];
    wire [7:0]  zebra_gap_pix   = zebra_cfg_pix[39:32];

    wire        zebra_de_in = zebra_en_pix ? q0_ng_de : 1'b0;
    wire        zebra_vs_in = zebra_en_pix ? q0_ng_vs : 1'b0;
    wire        zebra_hs_in = zebra_en_pix ? q0_ng_hs : 1'b0;
    wire [7:0]  zebra_r_in  = zebra_en_pix ? q0_ng_r  : 8'd0;
    wire [7:0]  zebra_g_in  = zebra_en_pix ? q0_ng_g  : 8'd0;
    wire [7:0]  zebra_b_in  = zebra_en_pix ? q0_ng_b  : 8'd0;

    wire        zebra_det_w;
    wire        zebra_raw_w;
    wire [7:0]  zebra_n_rows_w;
    wire [9:0]  zebra_y_min_w;
    wire [9:0]  zebra_y_max_w;
    wire [7:0]  zebra_max_cont_w;
    wire        zebra_frame_done_w;

    rt_zebra_det u_rt_zebra_det (
        .pix_clk   (pix_clk           ),
        .rst_n     (rstn_out          ),
        .de        (zebra_de_in       ),
        .hs        (zebra_hs_in       ),
        .vs        (zebra_vs_in       ),
        .r         (zebra_r_in        ),
        .g         (zebra_g_in        ),
        .b         (zebra_b_in        ),
        .n_min     (zebra_nmin_pix    ),
        .reg_pct   (8'd0              ), // 0 = default (120)
        .span_q10  (zebra_span_pix    ),
        .gap_max_w (zebra_gap_pix     ),
        .zebra     (zebra_det_w       ),
        .zebra_raw (zebra_raw_w       ),
        .n_rows    (zebra_n_rows_w    ),
        .y_min     (zebra_y_min_w     ),
        .y_max     (zebra_y_max_w     ),
        .max_cont  (zebra_max_cont_w  ),
        .frame_done(zebra_frame_done_w)
    );

    reg [7:0] zebra_frame_cnt_r;
    reg       zebra_stat_tgl_r;

    always @(posedge pix_clk or negedge rstn_out) begin
        if (!rstn_out) begin
            zebra_frame_cnt_r <= 8'd0;
            zebra_stat_tgl_r  <= 1'b0;
        end else if (zebra_en_pix && zebra_frame_done_w) begin
            zebra_frame_cnt_r <= zebra_frame_cnt_r + 1'b1;
            zebra_stat_tgl_r  <= ~zebra_stat_tgl_r;
        end
    end

    assign zebra_stat_tgl = zebra_stat_tgl_r;

    assign zebra_stat_bus = {
        32'd0, // [95:64] Reserved
        zebra_max_cont_w[7:0], 6'd0, zebra_y_max_w[9:0], zebra_frame_cnt_r[7:0], // [63:32] -> 0xA28
        6'd0, zebra_y_min_w[9:0], zebra_n_rows_w[7:0], 6'd0, zebra_raw_w, zebra_det_w // [31:0] -> 0xA24
    };


    rt_disp_win_reader #(
        .H_ACT(H_ACT), .V_ACT(V_ACT),
        .WIN_X0(12'd960), .WIN_Y0(12'd0), .WIN_W(12'd960), .WIN_H(12'd540),
        .WIN_IDX(2'd1)
    ) u_qwin1 (
        .pix_clk       (pix_clk     ),
        .pix_rst_n     (rstn_out    ),
        .cfg_tgl       (q_cfg_tgl   ),
        .cfg_ctrl      (q_ctrl      ),
        .cfg_base      (q1_base_r   ),
        .cfg_stride    (cfg_stride  ),
        .cfg_uv_off    (q1_uv_r     ),
        .commit_tgl    (commit_tgl  ),
        .commit_slot   (commit_slot ),
        .commit_frame_id(commit_frame_id),
        .stat_tgl      (q1_stgl     ),
        .stat_bus      (q1_sbus     ),
        .video_active_o(q1_vid      ),
        .vs            (vs_reg      ),
        .hs            (hs_reg      ),
        .de            (de_v        ),
        .x_act         (act_x       ),
        .y_act         (act_y       ),
        .r_out         (q1_r        ),
        .g_out         (q1_g        ),
        .b_out         (q1_b        ),
        .de_out        (q1_de       ),
        .hs_out        (q1_hs       ),
        .vs_out        (q1_vs       ),
        .core_clk      (core_clk    ),
        .core_rst_n    (core_rst_n  ),
        .m_araddr      (q1_araddr   ),
        .m_arlen       (q1_arlen    ),
        .m_arvalid     (q1_arvalid  ),
        .m_arready     (q1_arready  ),
        .m_rdata       (m_rdata     ),
        .m_rlast       (q1_rlast    ),
        .m_rvalid      (q1_rvalid   )
    );

    rt_disp_win_reader #(
        .H_ACT(H_ACT), .V_ACT(V_ACT),
        .WIN_X0(12'd0), .WIN_Y0(12'd540), .WIN_W(12'd960), .WIN_H(12'd540),
        .WIN_IDX(2'd2)
    ) u_qwin2 (
        .pix_clk       (pix_clk     ),
        .pix_rst_n     (rstn_out    ),
        .cfg_tgl       (q_cfg_tgl   ),
        .cfg_ctrl      (q_ctrl      ),
        .cfg_base      (q2_base_r   ),
        .cfg_stride    (cfg_stride  ),
        .cfg_uv_off    (q2_uv_r     ),
        .commit_tgl    (commit_tgl  ),
        .commit_slot   (commit_slot ),
        .commit_frame_id(commit_frame_id),
        .stat_tgl      (q2_stgl     ),
        .stat_bus      (q2_sbus     ),
        .video_active_o(q2_vid      ),
        .vs            (vs_reg      ),
        .hs            (hs_reg      ),
        .de            (de_v        ),
        .x_act         (act_x       ),
        .y_act         (act_y       ),
        .r_out         (q2_r        ),
        .g_out         (q2_g        ),
        .b_out         (q2_b        ),
        .de_out        (q2_de       ),
        .hs_out        (q2_hs       ),
        .vs_out        (q2_vs       ),
        .core_clk      (core_clk    ),
        .core_rst_n    (core_rst_n  ),
        .m_araddr      (q2_araddr   ),
        .m_arlen       (q2_arlen    ),
        .m_arvalid     (q2_arvalid  ),
        .m_arready     (q2_arready  ),
        .m_rdata       (m_rdata     ),
        .m_rlast       (q2_rlast    ),
        .m_rvalid      (q2_rvalid   )
    );

    rt_disp_win_reader #(
        .H_ACT(H_ACT), .V_ACT(V_ACT),
        .WIN_X0(12'd960), .WIN_Y0(12'd540), .WIN_W(12'd960), .WIN_H(12'd540),
        .WIN_IDX(2'd3)
    ) u_qwin3 (
        .pix_clk       (pix_clk     ),
        .pix_rst_n     (rstn_out    ),
        .cfg_tgl       (q_cfg_tgl   ),
        .cfg_ctrl      (q_ctrl      ),
        .cfg_base      (q3_base_r   ),
        .cfg_stride    (cfg_stride  ),
        .cfg_uv_off    (q3_uv_r     ),
        .commit_tgl    (commit_tgl  ),
        .commit_slot   (commit_slot ),
        .commit_frame_id(commit_frame_id),
        .stat_tgl      (q3_stgl     ),
        .stat_bus      (q3_sbus     ),
        .video_active_o(q3_vid      ),
        .vs            (vs_reg      ),
        .hs            (hs_reg      ),
        .de            (de_v        ),
        .x_act         (act_x       ),
        .y_act         (act_y       ),
        .r_out         (q3_r        ),
        .g_out         (q3_g        ),
        .b_out         (q3_b        ),
        .de_out        (q3_de       ),
        .hs_out        (q3_hs       ),
        .vs_out        (q3_vs       ),
        .core_clk      (core_clk    ),
        .core_rst_n    (core_rst_n  ),
        .m_araddr      (q3_araddr   ),
        .m_arlen       (q3_arlen    ),
        .m_arvalid     (q3_arvalid  ),
        .m_arready     (q3_arready  ),
        .m_rdata       (m_rdata     ),
        .m_rlast       (q3_rlast    ),
        .m_rvalid      (q3_rvalid   )
    );

    //------------------------------------------------------------------
    // share the single AXI read port : 4-way round robin inside quad mode,
    // legacy reader outside.  The mode is switched only when no burst is in
    // flight so a return beat can never be delivered to the wrong reader.
    //------------------------------------------------------------------
    wire [3:0] wq_arvalid = {q3_arvalid, q2_arvalid, q1_arvalid, q0_arvalid};
    wire [3:0] wq_any4    = wq_arvalid;
    wire       wq_any     = |wq_any4;

    reg         qmode;          // registered bus mode (0 = legacy)
    reg         lg_pend;        // legacy burst in flight
    reg  [1:0]  wq_rr;
    reg  [1:0]  wq_sel;
    wire [3:0]  wq_avail = wq_arvalid & {4{qmode}};

    always @(*)
    begin
        case (wq_rr)
            2'd0: wq_sel = wq_avail[0] ? 2'd0 : wq_avail[1] ? 2'd1 :
                           wq_avail[2] ? 2'd2 : 2'd3;
            2'd1: wq_sel = wq_avail[1] ? 2'd1 : wq_avail[2] ? 2'd2 :
                           wq_avail[3] ? 2'd3 : 2'd0;
            2'd2: wq_sel = wq_avail[2] ? 2'd2 : wq_avail[3] ? 2'd3 :
                           wq_avail[0] ? 2'd0 : 2'd1;
            default: wq_sel = wq_avail[3] ? 2'd3 : wq_avail[0] ? 2'd0 :
                           wq_avail[1] ? 2'd1 : 2'd2;
        endcase
    end

    reg  [27:0] wq_araddr_s;
    reg  [3:0]  wq_arlen_s;
    always @(*)
    begin
        case (wq_sel)
            2'd0:    begin wq_araddr_s = q0_araddr; wq_arlen_s = q0_arlen; end
            2'd1:    begin wq_araddr_s = q1_araddr; wq_arlen_s = q1_arlen; end
            2'd2:    begin wq_araddr_s = q2_araddr; wq_arlen_s = q2_arlen; end
            default: begin wq_araddr_s = q3_araddr; wq_arlen_s = q3_arlen; end
        endcase
    end

    // burst owner queue (one entry per accepted AR)
    reg  [1:0] wq_qo [0:7];
    reg  [3:0] wq_ql [0:7];
    reg  [3:0] wq_qwr, wq_qrd;
    wire       wq_full  = ((wq_qwr - wq_qrd) == 4'd8);
    wire       wq_empty = (wq_qwr == wq_qrd);

    wire       bus_quiet = wq_empty && !lg_pend && !wq_any && !lg_arvalid;
    wire       wq_gnt = wq_any && !wq_full;
    wire       wq_arh = wq_gnt && m_arready;
    wire       lg_arh = !qmode && lg_arvalid && m_arready;

    assign m_arvalid = qmode ? wq_gnt        : lg_arvalid;
    assign m_araddr  = qmode ? wq_araddr_s   : lg_araddr;
    assign m_arlen   = qmode ? wq_arlen_s    : lg_arlen;

    assign lg_rvalid  = !qmode && m_rvalid;
    wire   q_rvalid   =  qmode && m_rvalid;

    assign lg_arready = !qmode && m_arready;
    assign lg_rdata   = m_rdata;
    assign lg_rlast   = lg_rvalid && m_rlast;

    assign q0_arready = wq_arh && (wq_sel==2'd0);
    assign q1_arready = wq_arh && (wq_sel==2'd1);
    assign q2_arready = wq_arh && (wq_sel==2'd2);
    assign q3_arready = wq_arh && (wq_sel==2'd3);

    wire [1:0] wq_cur     = wq_qo[wq_qrd[2:0]];
    wire [3:0] wq_cur_len = wq_ql[wq_qrd[2:0]];
    reg  [3:0] wq_bcnt;
    wire       wq_beat_last = q_rvalid && !wq_empty && (wq_bcnt == wq_cur_len);

    assign q0_rvalid = q_rvalid && !wq_empty && (wq_cur==2'd0);
    assign q1_rvalid = q_rvalid && !wq_empty && (wq_cur==2'd1);
    assign q2_rvalid = q_rvalid && !wq_empty && (wq_cur==2'd2);
    assign q3_rvalid = q_rvalid && !wq_empty && (wq_cur==2'd3);
    assign q0_rlast  = q0_rvalid && m_rlast;
    assign q1_rlast  = q1_rvalid && m_rlast;
    assign q2_rlast  = q2_rvalid && m_rlast;
    assign q3_rlast  = q3_rvalid && m_rlast;

    always @(posedge core_clk or negedge core_rst_n)
    begin
        if (!core_rst_n)
        begin
            wq_rr <= 2'd0; qmode <= 1'b0; lg_pend <= 1'b0;
            wq_qwr <= 4'd0; wq_qrd <= 4'd0; wq_bcnt <= 4'd0;
        end
        else
        begin
            if (bus_quiet) qmode <= quad_en;

            if (wq_arh)
            begin
                wq_qo[wq_qwr[2:0]] <= wq_sel;
                wq_ql[wq_qwr[2:0]] <= wq_arlen_s;
                wq_qwr <= wq_qwr + 1'b1;
                wq_rr  <= wq_sel + 2'd1;
            end

            if (wq_beat_last) wq_qrd <= wq_qrd + 1'b1;

            if (q_rvalid && !wq_empty)
            begin
                if (wq_bcnt == wq_cur_len) wq_bcnt <= 4'd0;
                else                       wq_bcnt <= wq_bcnt + 1'b1;
            end
            else if (wq_empty) wq_bcnt <= 4'd0;

            if (lg_arh)                    lg_pend <= 1'b1;
            else if (lg_rvalid && m_rlast) lg_pend <= 1'b0;
        end
    end

    //------------------------------------------------------------------
    // 20261030: view mode effect (DISP_CTRL[9:8]) applied to the WHOLE screen
    // 0 = Original, 1 = Grayscale, 2 = Binary (White mask), 3 = Reserved (Binary)
    // The transform runs after the 2x2 composite, so all four windows and the
    // single-view path share the same colour processing; OSD is added later.
    //------------------------------------------------------------------
    reg [1:0] view_mode_pix;
    always @(posedge pix_clk or negedge rstn_out) begin
        if (!rstn_out) view_mode_pix <= 2'b00;
        else           view_mode_pix <= cfg_ctrl[9:8];
    end

    wire [7:0] q0_eff_r = q0_de ? q0_r : 8'd0;
    wire [7:0] q0_eff_g = q0_de ? q0_g : 8'd0;
    wire [7:0] q0_eff_b = q0_de ? q0_b : 8'd0;

    //------------------------------------------------------------------
    // 2x2 composite : the four windows never overlap, so the pixel buses of
    // the same clock edge are simply OR-ed back into one stream
    //------------------------------------------------------------------
    wire [7:0] qz_r = q0_eff_r | q1_r | q2_r | q3_r;
    wire [7:0] qz_g = q0_eff_g | q1_g | q2_g | q3_g;
    wire [7:0] qz_b = q0_eff_b | q1_b | q2_b | q3_b;
    wire       qz_de = q0_de | q1_de | q2_de | q3_de;
    wire       qz_hs = q0_hs | q1_hs | q2_hs | q3_hs;
    wire       qz_vs = q0_vs | q1_vs | q2_vs | q3_vs;

    wire [7:0] pre_r  = qmode ? qz_r  : rd_r;
    wire [7:0] pre_g  = qmode ? qz_g  : rd_g;
    wire [7:0] pre_b  = qmode ? qz_b  : rd_b;
    wire       pre_de = qmode ? qz_de : rd_de;
    wire       pre_hs = qmode ? qz_hs : rd_hs;
    wire       pre_vs = qmode ? qz_vs : rd_vs;

    //------------------------------------------------------------------
    // 20261101 night enhancement : point (b) gamma on composite pre_*
    //------------------------------------------------------------------
    wire [7:0] post_pre_r, post_pre_g, post_pre_b;
    wire       post_pre_de, post_pre_hs, post_pre_vs;

    rt_night_gamma u_gamma_pre (
        .clk          (pix_clk         ),
        .rst_n        (rstn_out        ),
        .night_active (night_active    ),
        .de_in        (pre_de          ),
        .hs_in        (pre_hs          ),
        .vs_in        (pre_vs          ),
        .r_in         (pre_r           ),
        .g_in         (pre_g           ),
        .b_in         (pre_b           ),
        .de_out       (post_pre_de     ),
        .hs_out       (post_pre_hs     ),
        .vs_out       (post_pre_vs     ),
        .r_out        (post_pre_r      ),
        .g_out        (post_pre_g      ),
        .b_out        (post_pre_b      )
    );

    // Synchronously delay downstream coordinate counters by 1 cycle to match gamma
    reg [11:0] act_x_d1, act_y_d1;
    always @(posedge pix_clk or negedge rstn_out) begin
        if (!rstn_out) begin
            act_x_d1 <= 12'd0;
            act_y_d1 <= 12'd0;
        end else begin
            act_x_d1 <= act_x;
            act_y_d1 <= act_y;
        end
    end

    // Grayscale: gray = (r + 2*g + b) >> 2
    wire [7:0] v_gray = ({2'b00, post_pre_r} + {1'b0, post_pre_g, 1'b0} + {2'b00, post_pre_b}) >> 2;

    // Binary: same white criteria as zebra (v_min=140, c_max=30)
    wire [7:0] v_rq = post_pre_r & 8'hF8;
    wire [7:0] v_gq = post_pre_g & 8'hFC;
    wire [7:0] v_bq = post_pre_b & 8'hF8;
    wire [7:0] v_max_rg = (v_rq > v_gq) ? v_rq : v_gq;
    wire [7:0] v_max_c  = (v_max_rg > v_bq) ? v_max_rg : v_bq;
    wire [7:0] v_min_rg = (v_rq < v_gq) ? v_rq : v_gq;
    wire [7:0] v_min_c  = (v_min_rg < v_bq) ? v_min_rg : v_bq;
    wire       v_is_white = (v_rq >= 8'd140) && (v_gq >= 8'd140) && (v_bq >= 8'd140) &&
                            ((v_max_c - v_min_c) <= 8'd30);
    wire [7:0] v_bin = v_is_white ? 8'hFF : 8'h00;

    reg [7:0] v_mux_r, v_mux_g, v_mux_b;
    always @(*) begin
        case (view_mode_pix)
            2'b01: begin v_mux_r = v_gray; v_mux_g = v_gray; v_mux_b = v_gray; end
            2'b10, 2'b11: begin v_mux_r = v_bin; v_mux_g = v_bin; v_mux_b = v_bin; end
            default: begin v_mux_r = post_pre_r; v_mux_g = post_pre_g; v_mux_b = post_pre_b; end
        endcase
    end

    wire [7:0] src_r  = post_pre_de ? v_mux_r : 8'd0;
    wire [7:0] src_g  = post_pre_de ? v_mux_g : 8'd0;
    wire [7:0] src_b  = post_pre_de ? v_mux_b : 8'd0;
    wire       src_de = post_pre_de;
    wire       src_hs = post_pre_hs;
    wire       src_vs = post_pre_vs;

    assign vid_active = lg_vid_active | q0_vid | q1_vid | q2_vid | q3_vid;
    assign stat_tgl   = qmode ? q0_stgl : lg_stat_tgl;
    wire [159:0] base_stat_bus = qmode ? q0_sbus : lg_stat_bus;
    assign stat_bus   = { base_stat_bus[159:156], night_mean, night_active, base_stat_bus[146:0] };

    //------------------------------------------------------------------
    // key scanner (free_clk) + OSD controller (pixel) + overlay (pixel)
    //------------------------------------------------------------------
    wire        repeat_en_w, pause_req_w;
    wire        cal_mode_w;
    wire [1:0]  obj_w;
    wire [11:0] eff_vpx, eff_vpy, eff_yt, eff_yb, eff_g;
    wire [511:0]status_line_w;
    wire        cal_blink_w;
    wire [31:0] dec_w, osdctrl_w;
    wire [831:0]box_w;

    rt_keys u_rt_keys (
        .clk        (free_clk     ),
        .rst_n      (locked       ),
        .key_raw    (key_raw      ),
        .repeat_en  (repeat_en_w  ),
        .key_stat   (key_stat     ),
        .evt_tgl    (evt_tgl      ),
        .evt_key    (evt_key      ),
        .evt_type   (evt_type     ),
        .evt_step   (evt_step     )
    );

    rt_osd_ctl u_rt_osd_ctl (
        .pix_clk      (pix_clk       ),
        .rst_n        (rstn_out      ),
        .osd_cfg_tgl  (osd_cfg_tgl   ),
        .osd_cfg      (osd_cfg       ),
        .evt_tgl      (evt_tgl       ),
        .evt_key      (evt_key       ),
        .evt_type     (evt_type      ),
        .evt_step     (evt_step      ),
        .drv_tgl      (drv_tgl       ),
        .drv_bus      (drv_bus       ),
        .cal_tgl      (cal_tgl       ),
        .cal_bus      (cal_bus       ),
        .repeat_en    (repeat_en_w   ),
        .pause_req    (pause_req_w   ),
        .vs           (vs_reg        ),
        .cal_mode     (cal_mode_w    ),
        .obj          (obj_w         ),
        .eff_vp_x     (eff_vpx       ),
        .eff_vp_y     (eff_vpy       ),
        .eff_y_top    (eff_yt        ),
        .eff_y_bot    (eff_yb        ),
        .eff_g        (eff_g         ),
        .status_line  (status_line_w ),
        .cal_blink    (cal_blink_w   ),
        .dec_out      (dec_w         ),
        .osdctrl_out  (osdctrl_w     ),
        .box_out      (box_w         ),
        // 20261028 lane inputs & decision outputs
        .lane_ctrl    (lane_ctrl_pix ),
        .lane_l_valid (lane_l_valid_w),
        .lane_l_solid (lane_l_solid_w),
        .lane_r_valid (lane_r_valid_w),
        .lane_r_solid (lane_r_solid_w),
        .lane_depart_warning(lane_depart_w),
        .lane_dec_state(lane_dec_state_w),
        .lane_eff_req_l(lane_eff_req_l_w),
        .lane_eff_req_r(lane_eff_req_r_w),
        .lane_eff_force(lane_eff_force_w)
    );


    wire [7:0] osd_r, osd_g, osd_b;
    wire       osd_de, osd_hs, osd_vs;

    rt_osd #(
        .H_ACT (H_ACT),
        .V_ACT (V_ACT)
    ) u_rt_osd (
        .pix_clk     (pix_clk     ),
        .rst_n       (rstn_out    ),
        .r_in        (src_r       ),
        .g_in        (src_g       ),
        .b_in        (src_b       ),
        .de_in       (src_de      ),
        .hs_in       (src_hs      ),
        .vs_in       (src_vs      ),
        .x_act       (act_x_d1    ),
        .y_act       (act_y_d1    ),
        .osd_en      (cfg_ctrl[2] ),
        .dec         (dec_w       ),
        .osdctrl     (osdctrl_w   ),
        .box         (box_w       ),
        .vp_x        (eff_vpx     ),
        .vp_y        (eff_vpy     ),
        .y_top       (eff_yt      ),
        .y_bot       (eff_yb      ),
        .g           (eff_g       ),
        .cal_mode    (cal_mode_w  ),
        .obj         (obj_w       ),
        .cal_blink   (cal_blink_w ),
        .status_line (status_line_w),
        .tram_wclk   (pclk_i      ),
        .tram_we     (tram_we     ),
        .tram_addr   (tram_addr   ),
        .tram_wdata  (tram_wdata  ),
        // 20261028 lane line drawing
        .lane_draw_en(lane_ctrl_pix[1]),
        .lane_l_valid(lane_l_valid_w),
        .lane_l_solid(lane_l_solid_w),
        .lane_l_ytop ({2'd0, lane_ytop_pix}),
        .lane_l_ybot ({2'd0, lane_ybot_pix}),
        .lane_l_x_top(lane_l_xtop_q16_w),
        .lane_l_dx   (lane_l_dx_q16_w),
        .lane_r_valid(lane_r_valid_w),
        .lane_r_solid(lane_r_solid_w),
        .lane_r_ytop ({2'd0, lane_ytop_pix}),
        .lane_r_ybot ({2'd0, lane_ybot_pix}),
        .lane_r_x_top(lane_r_xtop_q16_w),
        .lane_r_dx   (lane_r_dx_q16_w),
        .r_out       (osd_r       ),

        .g_out       (osd_g       ),
        .b_out       (osd_b       ),
        .de_out      (osd_de      ),
        .hs_out      (osd_hs      ),
        .vs_out      (osd_vs      )
    );

    //------------------------------------------------------------------
    // output register stage
    //------------------------------------------------------------------
    reg        vs_o, hs_o, de_o;
    reg [7:0]  r_o, g_o, b_o;
    always @(posedge pix_clk)
    begin
        vs_o <= osd_vs; hs_o <= osd_hs; de_o <= osd_de;
        r_o  <= osd_r;  g_o  <= osd_g;  b_o  <= osd_b;
    end
    assign vs_out = vs_o;
    assign hs_out = hs_o;
    assign de_out = de_o;
    assign r_out  = r_o;
    assign g_out  = g_o;
    assign b_out  = b_o;

    //------------------------------------------------------------------
    // LED logic (free_clk domain)
    //------------------------------------------------------------------
    reg [1:0] sy_rd, sy_dd, sy_va, sy_io;
    always @(posedge free_clk)
    begin
        sy_rd <= {sy_rd[0], rdlh_link_up };
        sy_dd <= {sy_dd[0], ddr_init_done};
        sy_va <= {sy_va[0], vid_active   };
        sy_io <= {sy_io[0], init_over    };
    end

    reg [23:0] blink_cnt; reg blink;
    always @(posedge free_clk)
    begin
        blink_cnt <= blink_cnt + 1'b1;
        if (blink_cnt == 24'hFFFFFF) blink <= ~blink;
    end

    reg [7:0] lh1, lh2, lo1, lo2;
    always @(posedge free_clk)
    begin
        lh1 <= led_host; lh2 <= lh1;
        lo1 <= led_oe;   lo2 <= lo1;
    end

    // LED0..3 = DECISION left/straight/right == green, alarm (pixel -> free)
    wire [3:0] led_dec = { (dec_w[8] | osdctrl_w[7]),
                           (dec_w[5:4]==2'd2), (dec_w[3:2]==2'd2), (dec_w[1:0]==2'd2) };
    reg  [3:0] ld1, ld2;
    always @(posedge free_clk)
    begin
        ld1 <= led_dec; ld2 <= ld1;
    end

    wire [7:0] led_auto = { (sy_io[1] ? blink : 1'b1), sy_va[1], sy_dd[1], sy_rd[1],
                            ld2 };
    assign led = (led_auto & ~lo2) | (lh2 & lo2);

endmodule
