`timescale 1ns / 1ps

module tb_sccb;

    reg clk_25M = 1'b0;
    always #20 clk_25M = ~clk_25M; // 25MHz

    reg clk_pclk = 1'b0;
    always #4 clk_pclk = ~clk_pclk; // 125MHz (pclk_div2)

    localparam SIM_DIV = 16'd4;

    // Pullups on SDA buses
    wire sda_orig;
    wire sda_new;
    wire sda_t6;
    pullup(sda_orig);
    pullup(sda_new);
    pullup(sda_t6);

    //==================================================================
    // T1 & T2 & T3 & T4 Signals & Instances
    //==================================================================
    reg rst_n = 1'b0;

    wire scl_orig;
    wire done_orig;
    reg_config_orig #(.I2C_DIV(SIM_DIV)) u_orig (
        .clk_25M(clk_25M),
        .camera_rstn(rst_n),
        .initial_en(1'b1),
        .reg_conf_done(done_orig),
        .i2c_sclk(scl_orig),
        .i2c_sdat(sda_orig),
        .clock_20k(),
        .reg_index(),
        .nack_after102()
    );
    sccb_slave_model u_slave_orig (
        .scl(scl_orig),
        .sda(sda_orig),
        .nack_data_en(1'b0)
    );

    wire scl_new;
    wire done_new;
    reg [23:0] rt_cmd = 24'd0;
    reg rt_req_tgl = 1'b0;
    wire rt_done_tgl;
    wire rt_nack;
    reg slave_new_nack = 1'b0;

    reg_config #(.I2C_DIV(SIM_DIV)) u_new (
        .clk_25M(clk_25M),
        .camera_rstn(rst_n),
        .initial_en(1'b1),
        .reg_conf_done(done_new),
        .i2c_sclk(scl_new),
        .i2c_sdat(sda_new),
        .clock_20k(),
        .reg_index(),
        .nack_after102(),
        .rt_cmd(rt_cmd),
        .rt_req_tgl(rt_req_tgl),
        .rt_done_tgl(rt_done_tgl),
        .rt_nack(rt_nack)
    );
    sccb_slave_model u_slave_new (
        .scl(scl_new),
        .sda(sda_new),
        .nack_data_en(slave_new_nack)
    );

    // Byte collector for orig
    reg [7:0] bytes_orig [0:2000];
    integer cnt_orig = 0;
    reg [7:0] s_orig;
    reg [3:0] bcnt_orig = 0;
    reg in_trans_orig = 0;

    always @(negedge sda_orig) if (scl_orig) begin in_trans_orig <= 1; bcnt_orig <= 0; end
    always @(posedge sda_orig) if (scl_orig) begin in_trans_orig <= 0; bcnt_orig <= 0; end
    always @(posedge scl_orig) begin
        if (in_trans_orig) begin
            if (bcnt_orig < 8) begin
                s_orig <= {s_orig[6:0], sda_orig};
                bcnt_orig <= bcnt_orig + 1;
            end else begin
                bytes_orig[cnt_orig] <= s_orig;
                cnt_orig <= cnt_orig + 1;
                bcnt_orig <= 0;
            end
        end
    end

    // Byte collector for new
    reg [7:0] bytes_new [0:2000];
    integer cnt_new = 0;
    reg [7:0] s_new;
    reg [3:0] bcnt_new = 0;
    reg in_trans_new = 0;

    always @(negedge sda_new) if (scl_new) begin in_trans_new <= 1; bcnt_new <= 0; end
    always @(posedge sda_new) if (scl_new) begin in_trans_new <= 0; bcnt_new <= 0; end
    always @(posedge scl_new) begin
        if (in_trans_new) begin
            if (bcnt_new < 8) begin
                s_new <= {s_new[6:0], sda_new};
                bcnt_new <= bcnt_new + 1;
            end else begin
                bytes_new[cnt_new] <= s_new;
                cnt_new <= cnt_new + 1;
                bcnt_new <= 0;
            end
        end
    end

    //==================================================================
    // T5 Standalone rt_ext_regs
    //==================================================================
    reg rst_n_t5 = 1'b0;
    reg tap_vld_t5 = 1'b0;
    reg [11:0] tap_addr_t5 = 12'd0;
    reg [31:0] tap_data_t5 = 32'd0;
    reg [11:0] rd_addr_t5 = 12'd0;
    wire [127:0] rd128_t5;
    wire [23:0] sccb_cmd_t5;
    wire sccb_req_tgl_t5;
    reg sccb_done_tgl_t5 = 1'b0;
    reg sccb_nack_t5 = 1'b0;

    rt_ext_regs u_ext_t5 (
        .clk(clk_pclk),
        .rst_n(rst_n_t5),
        .i_tap_vld(tap_vld_t5),
        .i_tap_addr(tap_addr_t5),
        .i_tap_data(tap_data_t5),
        .i_rd_addr(rd_addr_t5),
        .o_rd128(rd128_t5),
        .cfg_tgl(), .cfg_ctrl(), .cfg_fb_base(), .cfg_slot_size(), .cfg_stride(), .cfg_uv_off(),
        .commit_tgl(), .commit_slot(), .commit_frame_id(),
        .i_stat_tgl(1'b0), .i_stat_bus(160'd0),
        .o_osd_tgl(), .o_osd_cfg(),
        .o_tram_we(), .o_tram_addr(), .o_tram_data(),
        .i_evt_tgl(1'b0), .i_evt_key(3'd0), .i_evt_type(2'd0), .i_evt_step(6'd0),
        .i_drv_tgl(1'b0), .i_drv_bus(10'd0),
        .i_cal_tgl(1'b0), .i_cal_bus(60'd0),
        .i_key_stat(5'd0),
        .o_led_host(), .o_led_oe(),
        .o_hdmi_reinit_tgl(), .o_hdmi_rx_en(), .i_hdmi_stat_tgl(1'b0), .i_hdmi_stat_bus(32'd0),
        .i_cam_cfg_done(1'b0), .i_cam_initial_en(1'b0), .i_cam_vsync(1'b0), .i_cam_href(1'b0),
        .i_cam_pclk_tgl(1'b0), .i_cam_href16(1'b0), .i_cam_pclk_rst_n(1'b1), .i_por_done(1'b1),
        .i_cam_vs_cnt16(8'd0), .i_cam_wr_stat(32'd0), .i_cam_urg_cnt(32'd0),
        .o_stats_ctrl(), .i_stats_bus(96'd0), .i_stats_tgl(1'b0),
        .o_lane_cfg_bus(), .o_lane_cfg_tgl(), .i_lane_stat_bus(256'd0), .i_lane_dbg_bus(224'd0), .i_lane_stat_tgl(1'b0),
        .o_zebra_cfg_bus(), .o_zebra_cfg_tgl(), .i_zebra_stat_bus(96'd0), .i_zebra_stat_tgl(1'b0),
        .o_sccb_cmd(sccb_cmd_t5),
        .o_sccb_req_tgl(sccb_req_tgl_t5),
        .i_sccb_done_tgl(sccb_done_tgl_t5),
        .i_sccb_nack(sccb_nack_t5)
    );

    //==================================================================
    // T6 Integrated rt_ext_regs + reg_config + slave
    //==================================================================
    reg rst_n_top = 1'b0;
    reg rst_n_ext = 1'b0;
    reg tap_vld_t6 = 1'b0;
    reg [11:0] tap_addr_t6 = 12'd0;
    reg [31:0] tap_data_t6 = 32'd0;
    reg [11:0] rd_addr_t6 = 12'd0;
    wire [127:0] rd128_t6;

    wire [23:0] sccb_cmd_t6;
    wire sccb_req_tgl_t6;
    wire sccb_done_tgl_t6;
    wire sccb_nack_t6;
    wire scl_t6;
    wire done_t6;

    rt_ext_regs u_ext_t6 (
        .clk(clk_pclk),
        .rst_n(rst_n_ext),
        .i_tap_vld(tap_vld_t6),
        .i_tap_addr(tap_addr_t6),
        .i_tap_data(tap_data_t6),
        .i_rd_addr(rd_addr_t6),
        .o_rd128(rd128_t6),
        .cfg_tgl(), .cfg_ctrl(), .cfg_fb_base(), .cfg_slot_size(), .cfg_stride(), .cfg_uv_off(),
        .commit_tgl(), .commit_slot(), .commit_frame_id(),
        .i_stat_tgl(1'b0), .i_stat_bus(160'd0),
        .o_osd_tgl(), .o_osd_cfg(),
        .o_tram_we(), .o_tram_addr(), .o_tram_data(),
        .i_evt_tgl(1'b0), .i_evt_key(3'd0), .i_evt_type(2'd0), .i_evt_step(6'd0),
        .i_drv_tgl(1'b0), .i_drv_bus(10'd0),
        .i_cal_tgl(1'b0), .i_cal_bus(60'd0),
        .i_key_stat(5'd0),
        .o_led_host(), .o_led_oe(),
        .o_hdmi_reinit_tgl(), .o_hdmi_rx_en(), .i_hdmi_stat_tgl(1'b0), .i_hdmi_stat_bus(32'd0),
        .i_cam_cfg_done(done_t6), .i_cam_initial_en(1'b1), .i_cam_vsync(1'b0), .i_cam_href(1'b0),
        .i_cam_pclk_tgl(1'b0), .i_cam_href16(1'b0), .i_cam_pclk_rst_n(1'b1), .i_por_done(1'b1),
        .i_cam_vs_cnt16(8'd0), .i_cam_wr_stat(32'd0), .i_cam_urg_cnt(32'd0),
        .o_stats_ctrl(), .i_stats_bus(96'd0), .i_stats_tgl(1'b0),
        .o_lane_cfg_bus(), .o_lane_cfg_tgl(), .i_lane_stat_bus(256'd0), .i_lane_dbg_bus(224'd0), .i_lane_stat_tgl(1'b0),
        .o_zebra_cfg_bus(), .o_zebra_cfg_tgl(), .i_zebra_stat_bus(96'd0), .i_zebra_stat_tgl(1'b0),
        .o_sccb_cmd(sccb_cmd_t6),
        .o_sccb_req_tgl(sccb_req_tgl_t6),
        .i_sccb_done_tgl(sccb_done_tgl_t6),
        .i_sccb_nack(sccb_nack_t6)
    );

    reg_config #(.I2C_DIV(SIM_DIV)) u_reg_t6 (
        .clk_25M(clk_25M),
        .camera_rstn(rst_n_top),
        .initial_en(1'b1),
        .reg_conf_done(done_t6),
        .i2c_sclk(scl_t6),
        .i2c_sdat(sda_t6),
        .clock_20k(),
        .reg_index(),
        .nack_after102(),
        .rt_cmd(sccb_cmd_t6),
        .rt_req_tgl(sccb_req_tgl_t6),
        .rt_done_tgl(sccb_done_tgl_t6),
        .rt_nack(sccb_nack_t6)
    );

    sccb_slave_model u_slave_t6 (
        .scl(scl_t6),
        .sda(sda_t6),
        .nack_data_en(1'b0)
    );

    // Byte collector for T6
    reg [7:0] bytes_t6 [0:2000];
    integer cnt_t6 = 0;
    reg [7:0] s_t6;
    reg [3:0] bcnt_t6 = 0;
    reg in_trans_t6 = 0;

    always @(negedge sda_t6) if (scl_t6) begin in_trans_t6 <= 1; bcnt_t6 <= 0; end
    always @(posedge sda_t6) if (scl_t6) begin in_trans_t6 <= 0; bcnt_t6 <= 0; end
    always @(posedge scl_t6) begin
        if (in_trans_t6) begin
            if (bcnt_t6 < 8) begin
                s_t6 <= {s_t6[6:0], sda_t6};
                bcnt_t6 <= bcnt_t6 + 1;
            end else begin
                bytes_t6[cnt_t6] <= s_t6;
                cnt_t6 <= cnt_t6 + 1;
                bcnt_t6 <= 0;
            end
        end
    end

    //==================================================================
    // Helper Tasks
    //==================================================================
    task tap_write_t5(input [11:0] addr, input [31:0] data);
        begin
            @(posedge clk_pclk);
            tap_vld_t5  <= 1'b1;
            tap_addr_t5 <= addr;
            tap_data_t5 <= data;
            @(posedge clk_pclk);
            tap_vld_t5  <= 1'b0;
            @(posedge clk_pclk);
        end
    endtask

    task tap_write_t6(input [11:0] addr, input [31:0] data);
        begin
            @(posedge clk_pclk);
            tap_vld_t6  <= 1'b1;
            tap_addr_t6 <= addr;
            tap_data_t6 <= data;
            @(posedge clk_pclk);
            tap_vld_t6  <= 1'b0;
            @(posedge clk_pclk);
        end
    endtask

    task read_reg_t5(input [11:0] addr, output [31:0] val);
        reg [127:0] g;
        begin
            @(posedge clk_pclk);
            rd_addr_t5 <= addr;
            @(posedge clk_pclk);
            #1; // read registered output o_rd128
            g = rd128_t5;
            case (addr[3:2])
                2'd0: val = g[31:0];
                2'd1: val = g[63:32];
                2'd2: val = g[95:64];
                2'd3: val = g[127:96];
            endcase
        end
    endtask

    task read_reg_t6(input [11:0] addr, output [31:0] val);
        reg [127:0] g;
        begin
            @(posedge clk_pclk);
            rd_addr_t6 <= addr;
            @(posedge clk_pclk);
            #1;
            g = rd128_t6;
            case (addr[3:2])
                2'd0: val = g[31:0];
                2'd1: val = g[63:32];
                2'd2: val = g[95:64];
                2'd3: val = g[127:96];
            endcase
        end
    endtask

    //==================================================================
    // Main Test Sequence
    //==================================================================
    integer i;
    reg t1_pass = 1, t2_pass = 1, t3_pass = 1, t4_pass = 1, t5_pass = 1, t6_pass = 1;
    reg last_done_tgl;
    reg [31:0] rdata;
    integer cnt_before_mid;

    initial begin
        // Hold reset low for several clk_25M cycles then release
        rst_n = 1'b0;
        rst_n_t5 = 1'b0;
        rst_n_top = 1'b0;
        rst_n_ext = 1'b0;
        repeat (20) @(posedge clk_25M);
        @(negedge clk_25M);
        rst_n = 1'b1;
        rst_n_t5 = 1'b1;
        rst_n_top = 1'b1;
        rst_n_ext = 1'b1;
        $display("[INFO] Reset released at %0t.", $time);

        //--------------------------------------------------------------
        // T2 Part 1: While table is executing, issue a mid-table request on u_new
        // Wait until reg_index is around 50
        //--------------------------------------------------------------
        wait(u_new.reg_index == 9'd50);
        @(posedge clk_25M);
        rt_cmd <= 24'h123456;
        rt_req_tgl <= ~rt_req_tgl;
        $display("[INFO] T2: Issued mid-table request 0x123456 while reg_index=50");

        // Wait until both tables finish (done_orig & done_new)
        wait(done_orig == 1'b1 && done_new == 1'b1);
        $display("[INFO] Both boot tables reached done. Waiting for T2 pending request to complete...");
        // Wait for rt_done_tgl to flip for the mid-table request
        wait(rt_done_tgl == 1'b1);
        #1000;

        //--------------------------------------------------------------
        // T1 Evaluation: 357 transactions, 4 bytes each = 1428 bytes
        //--------------------------------------------------------------
        if (cnt_orig != 357 * 4) begin
            $display("T1 FAIL: cnt_orig=%0d (expected 1428)", cnt_orig);
            t1_pass = 0;
        end
        for (i = 0; i < 357 * 4; i = i + 1) begin
            if (bytes_orig[i] !== bytes_new[i]) begin
                $display("T1 FAIL: Mismatch at byte %0d: orig=0x%02x, new=0x%02x", i, bytes_orig[i], bytes_new[i]);
                t1_pass = 0;
            end
        end
        if (t1_pass) begin
            $display("T1 PASS: 357 table entries (1428 bytes) exactly match between orig and new");
        end else begin
            $display("SCCB_TB FAIL T1 mismatch");
            $finish;
        end

        //--------------------------------------------------------------
        // T2 Evaluation: The 358th transaction on u_new must be {0x78, 0x12, 0x34, 0x56}
        //--------------------------------------------------------------
        if (cnt_new != 358 * 4) begin
            $display("T2 FAIL: cnt_new=%0d (expected %0d)", cnt_new, 358 * 4);
            t2_pass = 0;
        end else begin
            if (bytes_new[1428] !== 8'h78 || bytes_new[1429] !== 8'h12 ||
                bytes_new[1430] !== 8'h34 || bytes_new[1431] !== 8'h56) begin
                $display("T2 FAIL: mid request bytes mismatch: {%02x, %02x, %02x, %02x}",
                    bytes_new[1428], bytes_new[1429], bytes_new[1430], bytes_new[1431]);
                t2_pass = 0;
            end
        end
        if (t2_pass) begin
            $display("T2 PASS: mid-table request executed exactly once after boot table completed");
        end else begin
            $display("SCCB_TB FAIL T2 error");
            $finish;
        end

        //--------------------------------------------------------------
        // T3: 3 consecutive requests: 0x3406<=0x01, 0x3400<=0x04, 0x5183<=0x94
        //--------------------------------------------------------------
        // Request 1: 0x340601
        last_done_tgl = rt_done_tgl;
        rt_cmd <= 24'h340601;
        rt_req_tgl <= ~rt_req_tgl;
        wait(rt_done_tgl != last_done_tgl);
        #500;
        if (rt_nack !== 1'b0) begin $display("T3 FAIL: req1 nack!=0"); t3_pass = 0; end

        // Request 2: 0x340004
        last_done_tgl = rt_done_tgl;
        rt_cmd <= 24'h340004;
        rt_req_tgl <= ~rt_req_tgl;
        wait(rt_done_tgl != last_done_tgl);
        #500;
        if (rt_nack !== 1'b0) begin $display("T3 FAIL: req2 nack!=0"); t3_pass = 0; end

        // Request 3: 0x518394
        last_done_tgl = rt_done_tgl;
        rt_cmd <= 24'h518394;
        rt_req_tgl <= ~rt_req_tgl;
        wait(rt_done_tgl != last_done_tgl);
        #500;
        if (rt_nack !== 1'b0) begin $display("T3 FAIL: req3 nack!=0"); t3_pass = 0; end

        // Check bytes received
        // req 1: bytes_new[1432..1435] == {78, 34, 06, 01}
        // req 2: bytes_new[1436..1439] == {78, 34, 00, 04}
        // req 3: bytes_new[1440..1443] == {78, 51, 83, 94}
        if (bytes_new[1432] !== 8'h78 || bytes_new[1433] !== 8'h34 || bytes_new[1434] !== 8'h06 || bytes_new[1435] !== 8'h01 ||
            bytes_new[1436] !== 8'h78 || bytes_new[1437] !== 8'h34 || bytes_new[1438] !== 8'h00 || bytes_new[1439] !== 8'h04 ||
            bytes_new[1440] !== 8'h78 || bytes_new[1441] !== 8'h51 || bytes_new[1442] !== 8'h83 || bytes_new[1443] !== 8'h94) begin
            $display("T3 FAIL: Bytes mismatch on 3 requests");
            t3_pass = 0;
        end
        if (t3_pass) begin
            $display("T3 PASS: 3 consecutive runtime requests executed correctly with rt_nack=0");
        end else begin
            $display("SCCB_TB FAIL T3 error");
            $finish;
        end

        //--------------------------------------------------------------
        // T4: NACK on data byte
        //--------------------------------------------------------------
        slave_new_nack <= 1'b1;
        last_done_tgl = rt_done_tgl;
        rt_cmd <= 24'h500055;
        rt_req_tgl <= ~rt_req_tgl;
        wait(rt_done_tgl != last_done_tgl);
        #500;
        if (rt_nack !== 1'b1) begin
            $display("T4 FAIL: rt_nack was %0b (expected 1)", rt_nack);
            t4_pass = 0;
        end
        slave_new_nack <= 1'b0;
        if (t4_pass) begin
            $display("T4 PASS: NACK properly detected, rt_nack=1");
        end else begin
            $display("SCCB_TB FAIL T4 error");
            $finish;
        end

        //--------------------------------------------------------------
        // T5: Standalone rt_ext_regs
        //--------------------------------------------------------------
        // 1. Check version register 0x838 == 0x20261106
        read_reg_t5(12'h838, rdata);
        if (rdata !== 32'h20261106) begin
            $display("T5 FAIL: 0x838 read 0x%08x (expected 0x20261106)", rdata);
            t5_pass = 0;
        end
        // 2. Write 0x8F8 with 24'hAABBCC
        tap_write_t5(12'h8F8, 32'h00AABBCC);
        // Verify o_sccb_req_tgl flipped, 0x8F8 reads 0x00AABBCC, 0x8FC bit0=1 (busy)
        read_reg_t5(12'h8F8, rdata);
        if (rdata[23:0] !== 24'hAABBCC) begin
            $display("T5 FAIL: 0x8F8 read 0x%08x (expected 0x00AABBCC)", rdata);
            t5_pass = 0;
        end
        read_reg_t5(12'h8FC, rdata);
        if (rdata[0] !== 1'b1) begin // busy bit
            $display("T5 FAIL: 0x8FC busy bit is not 1 after write, 0x8FC=0x%08x", rdata);
            t5_pass = 0;
        end
        // 3. While busy, write 0x8F8 again with 24'h112233 -> should set overrun, command unchanged
        tap_write_t5(12'h8F8, 32'h00112233);
        read_reg_t5(12'h8F8, rdata);
        if (rdata[23:0] !== 24'hAABBCC) begin
            $display("T5 FAIL: 0x8F8 changed during busy, read 0x%08x", rdata);
            t5_pass = 0;
        end
        read_reg_t5(12'h8FC, rdata);
        if (rdata[3] !== 1'b1) begin // overrun bit
            $display("T5 FAIL: overrun bit not set after busy write, 0x8FC=0x%08x", rdata);
            t5_pass = 0;
        end
        // 4. Flip i_sccb_done_tgl
        sccb_done_tgl_t5 <= ~sccb_done_tgl_t5;
        repeat (5) @(posedge clk_pclk); // sync
        read_reg_t5(12'h8FC, rdata);
        if (rdata[0] !== 1'b0) begin // busy should clear
            $display("T5 FAIL: busy did not clear after done toggle, 0x8FC=0x%08x", rdata);
            t5_pass = 0;
        end
        if (rdata[31:16] !== 16'd1) begin // done_cnt
            $display("T5 FAIL: done_cnt is %0d (expected 1)", rdata[31:16]);
            t5_pass = 0;
        end
        // 5. Write 0x8FC to clear overrun
        tap_write_t5(12'h8FC, 32'd0);
        read_reg_t5(12'h8FC, rdata);
        if (rdata[3] !== 1'b0) begin
            $display("T5 FAIL: overrun bit not cleared by write to 0x8FC, 0x8FC=0x%08x", rdata);
            t5_pass = 0;
        end
        if (t5_pass) begin
            $display("T5 PASS: rt_ext_regs tap write/read, busy, overrun, and done_cnt verified");
        end else begin
            $display("SCCB_TB FAIL T5 error");
            $finish;
        end

        //--------------------------------------------------------------
        // T6: Integrated rt_ext_regs + reg_config + slave
        //--------------------------------------------------------------
        wait(done_t6 == 1'b1);
        $display("[INFO] T6: u_reg_t6 boot table finished.");
        // Poll 0x8FC busy==0 and write 3 commands
        // Command 1: 0x300802
        read_reg_t6(12'h8FC, rdata);
        while (rdata[0]) begin @(posedge clk_pclk); read_reg_t6(12'h8FC, rdata); end
        tap_write_t6(12'h8F8, 32'h00300802);
        // Wait done
        read_reg_t6(12'h8FC, rdata);
        while (rdata[0]) begin @(posedge clk_pclk); read_reg_t6(12'h8FC, rdata); end

        // Command 2: 0x380010
        read_reg_t6(12'h8FC, rdata);
        while (rdata[0]) begin @(posedge clk_pclk); read_reg_t6(12'h8FC, rdata); end
        tap_write_t6(12'h8F8, 32'h00380010);
        // Wait done
        read_reg_t6(12'h8FC, rdata);
        while (rdata[0]) begin @(posedge clk_pclk); read_reg_t6(12'h8FC, rdata); end

        // Command 3: 0x5000A7
        read_reg_t6(12'h8FC, rdata);
        while (rdata[0]) begin @(posedge clk_pclk); read_reg_t6(12'h8FC, rdata); end
        tap_write_t6(12'h8F8, 32'h005000A7);
        // Wait done
        read_reg_t6(12'h8FC, rdata);
        while (rdata[0]) begin @(posedge clk_pclk); read_reg_t6(12'h8FC, rdata); end

        read_reg_t6(12'h8FC, rdata);
        if (rdata[31:16] !== 16'd3 || rdata[15:8] !== 8'd0) begin
            $display("T6 FAIL: Expected done_cnt=3, nack_cnt=0, got 0x8FC=0x%08x", rdata);
            t6_pass = 0;
        end

        // Check slave bytes for these 3 commands
        // Boot table was 357*4 = 1428 bytes
        if (cnt_t6 != 360 * 4) begin
            $display("T6 FAIL: cnt_t6=%0d (expected 360*4=%0d)", cnt_t6, 360 * 4);
            t6_pass = 0;
        end else begin
            if (bytes_t6[1428] !== 8'h78 || bytes_t6[1429] !== 8'h30 || bytes_t6[1430] !== 8'h08 || bytes_t6[1431] !== 8'h02 ||
                bytes_t6[1432] !== 8'h78 || bytes_t6[1433] !== 8'h38 || bytes_t6[1434] !== 8'h00 || bytes_t6[1435] !== 8'h10 ||
                bytes_t6[1436] !== 8'h78 || bytes_t6[1437] !== 8'h50 || bytes_t6[1438] !== 8'h00 || bytes_t6[1439] !== 8'hA7) begin
                $display("T6 FAIL: Integrated transaction byte mismatch");
                t6_pass = 0;
            end
        end

        // Reset ONLY rt_ext_regs for 20 cycles
        cnt_before_mid = cnt_t6;
        @(posedge clk_pclk);
        rst_n_ext <= 1'b0;
        repeat (20) @(posedge clk_pclk);
        rst_n_ext <= 1'b1;
        repeat (10) @(posedge clk_pclk);

        // Wait for at least 3 SCCB write times
        // 1 write = ~40 i2c_com clock cycles = 40 * (SIM_DIV+1)*2 * 40ns = ~16us
        #60000; // 60us

        // Slave must NOT have received any new transactions
        if (cnt_t6 !== cnt_before_mid) begin
            $display("T6 FAIL: Slave received unwanted transactions after ext_regs reset! cnt_t6 was %0d, now %0d",
                cnt_before_mid, cnt_t6);
            t6_pass = 0;
        end
        read_reg_t6(12'h8FC, rdata);
        if (rdata[0] !== 1'b0) begin
            $display("T6 FAIL: 0x8FC busy is not 0 after ext_regs reset, 0x8FC=0x%08x", rdata);
            t6_pass = 0;
        end

        // Write 1 more command: 0x400102
        tap_write_t6(12'h8F8, 32'h00400102);
        read_reg_t6(12'h8FC, rdata);
        while (rdata[0]) begin @(posedge clk_pclk); read_reg_t6(12'h8FC, rdata); end

        if (cnt_t6 !== (361 * 4)) begin
            $display("T6 FAIL: Post-reset command was not received by slave, cnt_t6=%0d", cnt_t6);
            t6_pass = 0;
        end else begin
            if (bytes_t6[1440] !== 8'h78 || bytes_t6[1441] !== 8'h40 || bytes_t6[1442] !== 8'h01 || bytes_t6[1443] !== 8'h02) begin
                $display("T6 FAIL: Post-reset command byte mismatch: {%02x,%02x,%02x,%02x}",
                    bytes_t6[1440], bytes_t6[1441], bytes_t6[1442], bytes_t6[1443]);
                t6_pass = 0;
            end
        end

        if (t6_pass) begin
            $display("T6 PASS: Integrated test and independent ext_regs reset test passed");
        end else begin
            $display("SCCB_TB FAIL T6 error");
            $finish;
        end

        // Final summary
        $display("----------------------------------------");
        $display("SCCB_TB PASS");
        $display("----------------------------------------");
        $finish;
    end

endmodule
