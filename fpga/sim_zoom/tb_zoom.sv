`timescale 1ns/1ps
//////////////////////////////////////////////////////////////////////////////
// tb_zoom.sv
// Comprehensive verification testbench for ZOOM2X mode:
// - DUT: rt_disp_win_reader_rgb
// - REF: ref_reader_rgb (unmodified git HEAD reference)
// - ANA: rt_zoom_ana (analysis stream extractor)
// - OSD: rt_osd (lane line overlay under zoom2x & arrow gap fix)
//
// Checks:
//   (a) zoom=0: q0 output bit-for-bit identical to REF reader across 2 full frames
//   (b) zoom=1: display stream (X,Y) = source(X>>1, Y>>1), full screen DE (2073600 px)
//   (c) analysis stream: exactly 540 lines x 960 continuous pixels = 518400 px, no error
//   (d) mid-frame zoom toggle: takes effect on next frame boundary (no tearing)
//   (e) rt_osd lane overlay: x ≈ 2*xl, width >= 2px, height doubled under zoom
//   (f) rt_osd arrow gap fix: in_arrow is strictly 0 in gaps x=[888..911] and [1008..1031]
//////////////////////////////////////////////////////////////////////////////

module tb_zoom;

    localparam H_ACT   = 1920;
    localparam V_ACT   = 1080;
    localparam H_TOTAL = 1928; // 1920 active + 8 blanking
    localparam H_SYNC  = 2;
    localparam H_BP    = 4;
    localparam H_FP    = 2;

    localparam V_TOTAL = 1084; // 1080 active + 4 blanking
    localparam V_SYNC  = 1;
    localparam V_BP    = 2;
    localparam V_FP    = 1;

    // Clocks
    reg pix_clk  = 0;
    reg core_clk = 0;
    always #3.367 pix_clk  = ~pix_clk;  // 148.5 MHz
    always #4.000 core_clk = ~core_clk; // 125.0 MHz

    reg pix_rst_n, core_rst_n;

    // Config & Commit
    reg        cfg_tgl;
    reg [15:0] cfg_ctrl;
    reg [31:0] cfg_base;
    reg        commit_tgl;
    reg [1:0]  commit_slot;
    reg [15:0] commit_frame_id;

    // Video timing from sync_vg
    wire        vs_vg, hs_vg, de_vg;
    wire [11:0] act_x, act_y;

    sync_vg #(
        .X_BITS(12), .Y_BITS(12),
        .V_TOTAL(V_TOTAL), .V_FP(V_FP), .V_BP(V_BP), .V_SYNC(V_SYNC), .V_ACT(V_ACT),
        .H_TOTAL(H_TOTAL), .H_FP(H_FP), .H_BP(H_BP), .H_SYNC(H_SYNC), .H_ACT(H_ACT)
    ) u_sync (
        .clk    (pix_clk  ),
        .rstn   (pix_rst_n),
        .vs_out (vs_vg    ),
        .hs_out (hs_vg    ),
        .de_out (de_vg    ),
        .de_re  (),
        .x_act  (act_x    ),
        .y_act  (act_y    )
    );

    // Coordinate pipeline (5 deep) to align with reader output
    reg [11:0] x_pipe [0:4];
    reg [11:0] y_pipe [0:4];
    integer pi;
    always @(posedge pix_clk) begin
        x_pipe[0] <= act_x;
        y_pipe[0] <= act_y;
        for (pi = 0; pi < 4; pi = pi + 1) begin
            x_pipe[pi+1] <= x_pipe[pi];
            y_pipe[pi+1] <= y_pipe[pi];
        end
    end
    wire [11:0] cur_out_x = x_pipe[4];
    wire [11:0] cur_out_y = y_pipe[4];

    // Source pattern generator: RGB565 f(x, y)
    function [15:0] gen_pixel(input [11:0] px, input [11:0] py);
        reg [4:0] r5;
        reg [5:0] g6;
        reg [4:0] b5;
        begin
            r5 = (px[4:0] ^ py[4:0]);
            g6 = (px[5:0] + py[5:0]);
            b5 = (px[8:4] ^ py[7:3]);
            // RB_SWAP=1 format: {b5, g6, r5}
            gen_pixel = {b5, g6, r5};
        end
    endfunction

    // Expected 24-bit RGB888 after 565->888 expansion
    function [23:0] exp_rgb888(input [11:0] px, input [11:0] py);
        reg [15:0] p565;
        reg [7:0]  r8, g8, b8;
        begin
            p565 = gen_pixel(px, py);
            r8   = {p565[4:0],  p565[4:2]};
            g8   = {p565[10:5], p565[10:9]};
            b8   = {p565[15:11],p565[15:13]};
            exp_rgb888 = {r8, g8, b8};
        end
    endfunction

    // -------------------------------------------------------------------------
    // Core Domain AXI Responders (separate for DUT and REF)
    // -------------------------------------------------------------------------
    wire [27:0] dut_araddr;
    wire [3:0]  dut_arlen;
    wire        dut_arvalid, dut_arready;
    wire [255:0]dut_rdata;
    wire        dut_rlast, dut_rvalid;

    reg         dut_arready_r;
    reg         dut_rvalid_r;
    reg         dut_rlast_r;
    reg [255:0] dut_rdata_r;
    assign dut_arready = dut_arready_r;
    assign dut_rvalid  = dut_rvalid_r;
    assign dut_rlast   = dut_rlast_r;
    assign dut_rdata   = dut_rdata_r;

    reg [27:0] dut_req_addr;
    reg [3:0]  dut_req_len;
    reg [3:0]  dut_rcnt;
    reg        dut_busy;

    always @(posedge core_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            dut_arready_r <= 1'b0;
            dut_rvalid_r  <= 1'b0;
            dut_rlast_r   <= 1'b0;
            dut_rdata_r   <= 256'd0;
            dut_busy      <= 1'b0;
            dut_rcnt      <= 4'd0;
        end else begin
            dut_arready_r <= !dut_busy;
            if (dut_arvalid && dut_arready && !dut_busy) begin
                dut_req_addr  <= dut_araddr;
                dut_req_len   <= dut_arlen;
                dut_busy      <= 1'b1;
                dut_rcnt      <= 4'd0;
                dut_arready_r <= 1'b0;
            end else if (dut_busy) begin
                reg [31:0] baddr;
                reg [11:0] row;
                reg [5:0]  cword;
                integer bi;
                baddr = {dut_req_addr, 2'b00} + {dut_rcnt, 5'b00000};
                row   = baddr / 1920;
                cword = (baddr % 1920) / 32;

                dut_rvalid_r <= 1'b1;
                dut_rlast_r  <= (dut_rcnt == dut_req_len);
                for (bi = 0; bi < 16; bi = bi + 1) begin
                    dut_rdata_r[16*bi +: 16] <= gen_pixel(cword * 16 + bi, row);
                end

                dut_rcnt <= dut_rcnt + 1'b1;
                if (dut_rcnt == dut_req_len) begin
                    dut_busy      <= 1'b0;
                    dut_arready_r <= 1'b1;
                end
            end else begin
                dut_rvalid_r <= 1'b0;
                dut_rlast_r  <= 1'b0;
            end
        end
    end

    // Reference reader AXI responder
    wire [27:0] ref_araddr;
    wire [3:0]  ref_arlen;
    wire        ref_arvalid, ref_arready;
    wire [255:0]ref_rdata;
    wire        ref_rlast, ref_rvalid;

    reg         ref_arready_r;
    reg         ref_rvalid_r;
    reg         ref_rlast_r;
    reg [255:0] ref_rdata_r;
    assign ref_arready = ref_arready_r;
    assign ref_rvalid  = ref_rvalid_r;
    assign ref_rlast   = ref_rlast_r;
    assign ref_rdata   = ref_rdata_r;

    reg [27:0] ref_req_addr;
    reg [3:0]  ref_req_len;
    reg [3:0]  ref_rcnt;
    reg        ref_busy;

    always @(posedge core_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            ref_arready_r <= 1'b0;
            ref_rvalid_r  <= 1'b0;
            ref_rlast_r   <= 1'b0;
            ref_rdata_r   <= 256'd0;
            ref_busy      <= 1'b0;
            ref_rcnt      <= 4'd0;
        end else begin
            ref_arready_r <= !ref_busy;
            if (ref_arvalid && ref_arready && !ref_busy) begin
                ref_req_addr  <= ref_araddr;
                ref_req_len   <= ref_arlen;
                ref_busy      <= 1'b1;
                ref_rcnt      <= 4'd0;
                ref_arready_r <= 1'b0;
            end else if (ref_busy) begin
                reg [31:0] baddr;
                reg [11:0] row;
                reg [5:0]  cword;
                integer bi;
                baddr = {ref_req_addr, 2'b00} + {ref_rcnt, 5'b00000};
                row   = baddr / 1920;
                cword = (baddr % 1920) / 32;

                ref_rvalid_r <= 1'b1;
                ref_rlast_r  <= (ref_rcnt == ref_req_len);
                for (bi = 0; bi < 16; bi = bi + 1) begin
                    ref_rdata_r[16*bi +: 16] <= gen_pixel(cword * 16 + bi, row);
                end

                ref_rcnt <= ref_rcnt + 1'b1;
                if (ref_rcnt == ref_req_len) begin
                    ref_busy      <= 1'b0;
                    ref_arready_r <= 1'b1;
                end
            end else begin
                ref_rvalid_r <= 1'b0;
                ref_rlast_r  <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // DUT Instance: rt_disp_win_reader_rgb
    // -------------------------------------------------------------------------
    wire [7:0] dut_r, dut_g, dut_b;
    wire       dut_de, dut_hs, dut_vs;
    wire       dut_zoom;
    wire       dut_vid;

    rt_disp_win_reader_rgb #(
        .H_ACT(H_ACT), .V_ACT(V_ACT),
        .WIN_X0(12'd0), .WIN_Y0(12'd0), .WIN_W(12'd960), .WIN_H(12'd540),
        .WIN_IDX(2'd0)
    ) u_dut_reader (
        .pix_clk        (pix_clk        ),
        .pix_rst_n      (pix_rst_n      ),
        .cfg_tgl        (cfg_tgl        ),
        .cfg_ctrl       (cfg_ctrl       ),
        .cfg_base       (cfg_base       ),
        .cfg_stride     (32'd1920       ),
        .cfg_uv_off     (32'd0          ),
        .commit_tgl     (commit_tgl     ),
        .commit_slot    (commit_slot    ),
        .commit_frame_id(commit_frame_id),
        .stat_tgl       (),
        .stat_bus       (),
        .video_active_o (dut_vid        ),
        .zoom_o         (dut_zoom       ),
        .vs             (vs_vg          ),
        .hs             (hs_vg          ),
        .de             (de_vg          ),
        .x_act          (act_x          ),
        .y_act          (act_y          ),
        .r_out          (dut_r          ),
        .g_out          (dut_g          ),
        .b_out          (dut_b          ),
        .de_out         (dut_de         ),
        .hs_out         (dut_hs         ),
        .vs_out         (dut_vs         ),
        .core_clk       (core_clk       ),
        .core_rst_n     (core_rst_n     ),
        .m_araddr       (dut_araddr     ),
        .m_arlen        (dut_arlen      ),
        .m_arvalid      (dut_arvalid    ),
        .m_arready      (dut_arready    ),
        .m_rdata        (dut_rdata      ),
        .m_rlast        (dut_rlast      ),
        .m_rvalid       (dut_rvalid     )
    );

    // -------------------------------------------------------------------------
    // Reference Model Instance: ref_reader_rgb (Original HEAD RTL)
    // -------------------------------------------------------------------------
    wire [7:0] ref_r, ref_g, ref_b;
    wire       ref_de, ref_hs, ref_vs;
    wire       ref_vid;

    ref_reader_rgb #(
        .H_ACT(H_ACT), .V_ACT(V_ACT),
        .WIN_X0(12'd0), .WIN_Y0(12'd0), .WIN_W(12'd960), .WIN_H(12'd540),
        .WIN_IDX(2'd0)
    ) u_ref_reader (
        .pix_clk        (pix_clk        ),
        .pix_rst_n      (pix_rst_n      ),
        .cfg_tgl        (cfg_tgl        ),
        .cfg_ctrl       (cfg_ctrl       ),
        .cfg_base       (cfg_base       ),
        .cfg_stride     (32'd1920       ),
        .cfg_uv_off     (32'd0          ),
        .commit_tgl     (commit_tgl     ),
        .commit_slot    (commit_slot    ),
        .commit_frame_id(commit_frame_id),
        .stat_tgl       (),
        .stat_bus       (),
        .video_active_o (ref_vid        ),
        .vs             (vs_vg          ),
        .hs             (hs_vg          ),
        .de             (de_vg          ),
        .x_act          (act_x          ),
        .y_act          (act_y          ),
        .r_out          (ref_r          ),
        .g_out          (ref_g          ),
        .b_out          (ref_b          ),
        .de_out         (ref_de         ),
        .hs_out         (ref_hs         ),
        .vs_out         (ref_vs         ),
        .core_clk       (core_clk       ),
        .core_rst_n     (core_rst_n     ),
        .m_araddr       (ref_araddr     ),
        .m_arlen        (ref_arlen      ),
        .m_arvalid      (ref_arvalid    ),
        .m_arready      (ref_arready    ),
        .m_rdata        (ref_rdata      ),
        .m_rlast        (ref_rlast      ),
        .m_rvalid       (ref_rvalid     )
    );

    // -------------------------------------------------------------------------
    // Analysis Stream Module Instance: rt_zoom_ana
    // -------------------------------------------------------------------------
    wire [7:0] ana_r, ana_g, ana_b;
    wire       ana_de, ana_hs, ana_vs;

    rt_zoom_ana u_zoom_ana (
        .pix_clk   (pix_clk   ),
        .pix_rst_n (pix_rst_n ),
        .zoom      (dut_zoom  ),
        .r_in      (dut_r     ),
        .g_in      (dut_g     ),
        .b_in      (dut_b     ),
        .de_in     (dut_de    ),
        .hs_in     (dut_hs    ),
        .vs_in     (dut_vs    ),
        .r_out     (ana_r     ),
        .g_out     (ana_g     ),
        .b_out     (ana_b     ),
        .de_out    (ana_de    ),
        .hs_out    (ana_hs    ),
        .vs_out    (ana_vs    )
    );

    // -------------------------------------------------------------------------
    // OSD Instance: rt_osd (with vertical lane line at x=400, y in [100, 400])
    // -------------------------------------------------------------------------
    wire [7:0] osd_r, osd_g, osd_b;
    wire       osd_de, osd_hs, osd_vs;

    rt_osd #(
        .H_ACT(H_ACT), .V_ACT(V_ACT)
    ) u_osd (
        .pix_clk        (pix_clk        ),
        .rst_n          (pix_rst_n      ),
        .r_in           (dut_r          ),
        .g_in           (dut_g          ),
        .b_in           (dut_b          ),
        .de_in          (dut_de         ),
        .hs_in          (dut_hs         ),
        .vs_in          (dut_vs         ),
        .x_act          (act_x          ),
        .y_act          (act_y          ),
        .zoom           (dut_zoom       ),
        .osd_en         (1'b1           ),
        .dec            (32'd0          ),
        .osdctrl        (32'd0          ),
        .box            (832'd0         ),
        .vp_x           (12'd0          ),
        .vp_y           (12'd0          ),
        .y_top          (12'd0          ),
        .y_bot          (12'd0          ),
        .g              (12'd0          ),
        .cal_mode       (1'b0           ),
        .obj            (2'd0           ),
        .cal_blink      (1'b0           ),
        .status_line    (512'd0         ),
        .tram_wclk      (pix_clk        ),
        .tram_we        (1'b0           ),
        .tram_addr      (6'd0           ),
        .tram_wdata     (32'd0          ),
        .lane_draw_en   (1'b1           ),
        .lane_l_valid   (1'b1           ),
        .lane_l_solid   (1'b1           ),
        .lane_l_ytop    (12'd100        ),
        .lane_l_ybot    (12'd400        ),
        .lane_l_x_top   ({16'd400, 16'd0}), // vertical line at x=400
        .lane_l_dx      (32'd0          ),
        .lane_r_valid   (1'b0           ),
        .lane_r_solid   (1'b0           ),
        .lane_r_ytop    (12'd0          ),
        .lane_r_ybot    (12'd0          ),
        .lane_r_x_top   (32'd0          ),
        .lane_r_dx      (32'd0          ),
        .r_out          (osd_r          ),
        .g_out          (osd_g          ),
        .b_out          (osd_b          ),
        .de_out         (osd_de         ),
        .hs_out         (osd_hs         ),
        .vs_out         (osd_vs         )
    );

    // Frame tracking: increment on the first active pixel of line 0 of each frame
    integer frame_num = 0;
    reg de_vg_d;
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            frame_num <= 0;
            de_vg_d   <= 0;
        end else begin
            de_vg_d <= de_vg;
            if (de_vg && !de_vg_d && act_y == 12'd0) begin
                frame_num <= frame_num + 1;
                $display("[TB] Active Frame %0d started at time %0t (dut_zoom=%0b)", frame_num + 1, $time, dut_zoom);
            end
        end
    end

    // Test statistics counters
    integer err_a = 0;
    integer ok_a  = 0;

    integer err_b = 0;
    integer ok_b  = 0;
    integer b_active_pixels = 0;

    integer ana_line_cnt   = 0;
    integer ana_total_pix  = 0;
    integer err_c          = 0;
    reg [11:0] ana_x_cnt   = 0;
    reg [11:0] ana_y_cnt   = 0;

    integer err_d = 0;
    integer ok_d  = 0;
    reg     mid_toggle_done = 0;

    integer osd_hits_z0   = 0;
    integer osd_hits_z1   = 0;
    integer osd_err_z0    = 0;
    integer osd_err_z1    = 0;

    integer err_f = 0;
    integer ok_f  = 0;

    // Track analysis stream pixels (Point c) during Frame 3 (zoom=1)
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            ana_x_cnt     <= 12'd0;
            ana_y_cnt     <= 12'd0;
            ana_line_cnt  <= 0;
            ana_total_pix <= 0;
        end else if (dut_zoom && frame_num == 3 && ana_de) begin
            reg [23:0] exp_p;
            exp_p = exp_rgb888(ana_x_cnt, ana_y_cnt);
            if ({ana_r, ana_g, ana_b} !== exp_p) begin
                if (err_c < 10)
                    $display("[ERR_C] (X=%0d, Y=%0d): got %h exp %h", ana_x_cnt, ana_y_cnt, {ana_r, ana_g, ana_b}, exp_p);
                err_c = err_c + 1;
            end

            ana_total_pix <= ana_total_pix + 1;
            if (ana_x_cnt == 12'd959) begin
                ana_x_cnt    <= 12'd0;
                ana_y_cnt    <= ana_y_cnt + 1'b1;
                ana_line_cnt <= ana_line_cnt + 1;
            end else begin
                ana_x_cnt <= ana_x_cnt + 1'b1;
            end
        end
    end

    // Monitor for DUT vs REF (Point a), ZOOM display (Point b), OSD (Point e), and Arrow Gap (Point f)
    always @(posedge pix_clk) begin
        if (pix_rst_n) begin
            // -------------------------------------------------------------
            // Check (a): While in zoom=0 (Frames 1 & 2), DUT must match REF bit-for-bit
            // -------------------------------------------------------------
            if (!dut_zoom && frame_num >= 1) begin
                if (dut_r !== ref_r || dut_g !== ref_g || dut_b !== ref_b ||
                    dut_de !== ref_de || dut_hs !== ref_hs || dut_vs !== ref_vs) begin
                    if (err_a < 10)
                        $display("[ERR_A] Cycle mismatch: DUT={%0d,%h} REF={%0d,%h}", dut_de, {dut_r,dut_g,dut_b}, ref_de, {ref_r,ref_g,ref_b});
                    err_a = err_a + 1;
                end else begin
                    ok_a = ok_a + 1;
                end

                // OSD check for zoom=0 using combinational hit wire
                if (u_osd.l_line_hit) begin
                    osd_hits_z0 = osd_hits_z0 + 1;
                    // In zoom=0, lane at x=400 (range 399..401), y in [100..400]
                    if (u_osd.x1 < 399 || u_osd.x1 > 401 || u_osd.y1 < 100 || u_osd.y1 > 400) begin
                        osd_err_z0 = osd_err_z0 + 1;
                    end
                end
            end

            // -------------------------------------------------------------
            // Check (d): After mid-frame toggle, dut_zoom MUST stay 0 during rest of Frame 2 active video
            // -------------------------------------------------------------
            if (mid_toggle_done && frame_num == 2 && de_vg && act_y >= 500 && act_y < (V_ACT - 1)) begin
                if (dut_zoom !== 1'b0) begin
                    err_d = err_d + 1;
                end else begin
                    ok_d = ok_d + 1;
                end
            end

            // -------------------------------------------------------------
            // Check (b) & (e): In zoom=1 mode (Frame 3)
            // -------------------------------------------------------------
            if (dut_zoom && frame_num == 3) begin
                if (dut_de) begin // Check active video stream
                    reg [23:0] exp_zoom_p;
                    b_active_pixels = b_active_pixels + 1;
                    exp_zoom_p = exp_rgb888(cur_out_x >> 1, cur_out_y >> 1);
                    if ({dut_r, dut_g, dut_b} !== exp_zoom_p) begin
                        if (err_b < 10)
                            $display("[ERR_B] (X=%0d, Y=%0d) got %h exp %h", cur_out_x, cur_out_y, {dut_r,dut_g,dut_b}, exp_zoom_p);
                        err_b = err_b + 1;
                    end else begin
                        ok_b = ok_b + 1;
                    end
                end

                // OSD check for zoom=1 using combinational hit wire
                if (u_osd.l_line_hit) begin
                    osd_hits_z1 = osd_hits_z1 + 1;
                    // In zoom=1, x1 must be in [798..803] (2*400 ± 2), y1 in [200..801] (2*[100..400])
                    if (u_osd.x1 < 798 || u_osd.x1 > 803 || u_osd.y1 < 200 || u_osd.y1 > 801) begin
                        osd_err_z1 = osd_err_z1 + 1;
                    end
                end
            end

            // -------------------------------------------------------------
            // Check (f): rt_osd arrow gap check
            // In gaps x=[888..911] and [1008..1031], in_arrow MUST be 0
            // -------------------------------------------------------------
            if (u_osd.ya >= 12'd960 && u_osd.ya < 12'd1056) begin
                if ((u_osd.xa >= 12'd888 && u_osd.xa <= 12'd911) ||
                    (u_osd.xa >= 12'd1008 && u_osd.xa <= 12'd1031)) begin
                    if (u_osd.in_arrow) begin
                        if (err_f < 10)
                            $display("[ERR_F] False in_arrow at (X=%0d, Y=%0d)", u_osd.xa, u_osd.ya);
                        err_f = err_f + 1;
                    end else begin
                        ok_f = ok_f + 1;
                    end
                end
            end
        end
    end

    // Main Test Stimulus
    initial begin
        $display("============================================================");
        $display("Starting ZOOM2X Verification Testbench (Questa FSE)");
        $display("============================================================");

        pix_rst_n  = 1'b0;
        core_rst_n = 1'b0;
        cfg_tgl    = 1'b0;
        cfg_ctrl   = 16'h0001; // video_en=1, zoom=0
        cfg_base   = 32'h0000_0000;
        commit_tgl = 1'b0;
        commit_slot= 2'd0;
        commit_frame_id = 16'd1;

        #100;
        @(posedge pix_clk);
        pix_rst_n = 1'b1;
        @(posedge core_clk);
        core_rst_n = 1'b1;

        // Apply config & commit for slot0
        #50;
        @(posedge pix_clk);
        cfg_tgl    = ~cfg_tgl;
        commit_tgl = ~commit_tgl;

        // -----------------------------------------------------------------
        // Frame 1: Warmup frame
        // -----------------------------------------------------------------
        wait (frame_num == 1);
        $display("[INFO] Frame 1 (Warmup) running...");

        // -----------------------------------------------------------------
        // Frame 2: Verification of zoom=0 & Mid-frame switch of ZOOM2X
        // -----------------------------------------------------------------
        wait (frame_num == 2);
        $display("[INFO] Frame 2 (zoom=0 check) running...");
        wait (act_y == 12'd500 && act_x == 12'd100);
        $display("[INFO] Mid-frame 2 trigger: setting cfg_ctrl[7]=1 at (X=%0d, Y=%0d)", act_x, act_y);
        cfg_ctrl[7] = 1'b1; // Turn on ZOOM2X mid-frame
        cfg_tgl     = ~cfg_tgl;
        mid_toggle_done = 1'b1;

        // -----------------------------------------------------------------
        // Frame 3: Verification of zoom=1 (Display stream & Analysis stream & OSD)
        // -----------------------------------------------------------------
        wait (frame_num == 3);
        $display("[INFO] Frame 3 (zoom=1 check) running...");
        if (dut_zoom !== 1'b1) begin
            $display("[FATAL] dut_zoom did not become 1 at start of Frame 3!");
            err_d = err_d + 1;
        end else begin
            $display("[INFO] dut_zoom cleanly switched to 1 at frame boundary.");
        end

        // Wait until Frame 3 completes (Frame 4 starts)
        wait (frame_num == 4);
        $display("[INFO] Frame 3 finished.");

        // -----------------------------------------------------------------
        // Final Assessment
        // -----------------------------------------------------------------
        $display("\n============================================================");
        $display("ZOOM2X TEST RESULTS SUMMARY");
        $display("============================================================");

        // Check (a)
        $display("(a) zoom=0 DUT vs REF match count: %0d cycles, mismatches: %0d", ok_a, err_a);

        // Check (b)
        $display("(b) zoom=1 display stream pixels checked: %0d, errors: %0d (active=%0d)", ok_b, err_b, b_active_pixels);

        // Check (c)
        $display("(c) Analysis stream: %0d lines (exp 540), %0d pixels (exp 518400), content errors: %0d",
                 ana_line_cnt, ana_total_pix, err_c);

        // Check (d)
        $display("(d) Mid-frame toggle: %0d active cycles checked, errors: %0d", ok_d, err_d);

        // Check (e)
        $display("(e) OSD Lane hits: zoom0=%0d (err=%0d), zoom1=%0d (err=%0d)",
                 osd_hits_z0, osd_err_z0, osd_hits_z1, osd_err_z1);

        // Check (f)
        $display("(f) OSD Arrow gaps checked: %0d pixels, false in_arrow errors: %0d", ok_f, err_f);

        if (err_a == 0 && err_b == 0 && err_c == 0 && err_d == 0 && err_f == 0 &&
            ok_a > 2000000 &&
            b_active_pixels == 2073600 &&
            ana_line_cnt == 540 && ana_total_pix == 518400 &&
            osd_hits_z0 > 0 && osd_err_z0 == 0 &&
            osd_hits_z1 > 0 && osd_err_z1 == 0 &&
            ok_f > 0) begin
            $display("========================================");
            $display("ZOOM_TB PASS");
            $display("========================================");
            $finish(0);
        end else begin
            $display("========================================");
            $display("ZOOM_TB FAIL");
            $display("========================================");
            $fatal(1, "ZOOM_TB failed one or more checks!");
        end
    end

endmodule
