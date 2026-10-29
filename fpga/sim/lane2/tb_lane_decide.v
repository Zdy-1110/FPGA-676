`timescale 1ns/1ps

module tb_lane_decide;

    reg         pix_clk;
    reg         rst_n;

    reg         osd_cfg_tgl;
    reg [1065:0]osd_cfg;

    reg         evt_tgl;
    reg [2:0]   evt_key;
    reg [1:0]   evt_type;
    reg [5:0]   evt_step;

    wire        drv_tgl;
    wire [9:0]  drv_bus;
    wire        cal_tgl;
    wire [59:0] cal_bus;
    wire        repeat_en;
    wire        pause_req;

    reg         vs;
    wire        cal_mode;
    wire [1:0]  obj;
    wire [11:0] eff_vp_x, eff_vp_y, eff_y_top, eff_y_bot, eff_g;
    wire [511:0]status_line;
    wire        cal_blink;
    wire [31:0] dec_out;
    wire [31:0] osdctrl_out;
    wire [831:0]box_out;

    reg [31:0]  lane_ctrl;
    reg         lane_l_valid, lane_l_solid;
    reg         lane_r_valid, lane_r_solid;
    reg         lane_depart_warning;

    wire [1:0]  lane_dec_state;
    wire        lane_eff_req_l, lane_eff_req_r, lane_eff_force;

    // Instantiate rt_osd_ctl with fast 1ms tick for simulation
    rt_osd_ctl #(
        .MS_DIV(10)
    ) uut (
        .pix_clk            (pix_clk            ),
        .rst_n              (rst_n              ),
        .osd_cfg_tgl        (osd_cfg_tgl        ),
        .osd_cfg            (osd_cfg            ),
        .evt_tgl            (evt_tgl            ),
        .evt_key            (evt_key            ),
        .evt_type           (evt_type           ),
        .evt_step           (evt_step           ),
        .drv_tgl            (drv_tgl            ),
        .drv_bus            (drv_bus            ),
        .cal_tgl            (cal_tgl            ),
        .cal_bus            (cal_bus            ),
        .repeat_en          (repeat_en          ),
        .pause_req          (pause_req          ),
        .vs                 (vs                 ),
        .cal_mode           (cal_mode           ),
        .obj                (obj                ),
        .eff_vp_x           (eff_vp_x           ),
        .eff_vp_y           (eff_vp_y           ),
        .eff_y_top          (eff_y_top          ),
        .eff_y_bot          (eff_y_bot          ),
        .eff_g              (eff_g              ),
        .status_line        (status_line        ),
        .cal_blink          (cal_blink          ),
        .dec_out            (dec_out            ),
        .osdctrl_out        (osdctrl_out        ),
        .box_out            (box_out            ),
        .lane_ctrl          (lane_ctrl          ),
        .lane_l_valid       (lane_l_valid       ),
        .lane_l_solid       (lane_l_solid       ),
        .lane_r_valid       (lane_r_valid       ),
        .lane_r_solid       (lane_r_solid       ),
        .lane_depart_warning(lane_depart_warning),
        .lane_dec_state     (lane_dec_state     ),
        .lane_eff_req_l     (lane_eff_req_l     ),
        .lane_eff_req_r     (lane_eff_req_r     ),
        .lane_eff_force     (lane_eff_force     )
    );

    always #3.367 pix_clk = ~pix_clk;

    localparam T_SHORT = 2'd1, T_LONG = 2'd2;

    task send_key;
        input [2:0] k;
        input [1:0] ty;
        begin
            evt_key  = k;
            evt_type = ty;
            evt_step = 6'd1;
            evt_tgl  = ~evt_tgl;
            repeat (10) @(posedge pix_clk);
        end
    endtask

    task set_host_cfg;
        input [31:0] host_dec;
        begin
            osd_cfg[31:0] = host_dec;
            osd_cfg_tgl   = ~osd_cfg_tgl;
            repeat (10) @(posedge pix_clk);
        end
    endtask

    integer total_cases = 0;
    integer mismatch_count = 0;

    // Loop variables
    integer i_req_mode;  // 0: none, 1: key_short_l, 2: key_long_l, 3: key_short_r, 4: key_long_r,
                         // 5: sw_short_l, 6: sw_force_l, 7: sw_short_r, 8: sw_force_r,
                         // 9: both_key_l_last, 10: both_key_r_last, 11: both_sw_l_last, 12: both_sw_r_last
    integer i_line_state; // 0: invalid, 1: dashed, 2: solid
    integer i_lane_mode;  // 0: host 0x850, 1: hardware lane mode
    integer i_dep_en;     // 0: no depart alarm, 1: depart alarm enabled
    integer i_dep_warn;   // 0: no depart warning, 1: depart warning active

    reg [31:0] exp_dec;
    reg [1:0]  exp_dec_state;
    integer    req_side;   // 0: none, 1: left, 2: right
    integer    is_force;
    reg        line_dashed;

    initial begin
        pix_clk = 0;
        rst_n = 0;
        osd_cfg_tgl = 0;
        osd_cfg = 1066'd0;
        evt_tgl = 0;
        evt_key = 0;
        evt_type = 0;
        evt_step = 0;
        vs = 0;
        lane_ctrl = 32'd0;
        lane_l_valid = 0;
        lane_l_solid = 0;
        lane_r_valid = 0;
        lane_r_solid = 0;
        lane_depart_warning = 0;

        #50;
        rst_n = 1;
        #50;

        // Set host dec to known pattern 0x000000AA
        set_host_cfg(32'h0000_00AA);

        // Exhaustive test matrix
        for (i_lane_mode = 0; i_lane_mode < 2; i_lane_mode = i_lane_mode + 1) begin
            for (i_dep_en = 0; i_dep_en < 2; i_dep_en = i_dep_en + 1) begin
                for (i_dep_warn = 0; i_dep_warn < 2; i_dep_warn = i_dep_warn + 1) begin
                    for (i_line_state = 0; i_line_state < 3; i_line_state = i_line_state + 1) begin
                        for (i_req_mode = 0; i_req_mode < 13; i_req_mode = i_req_mode + 1) begin
                            total_cases = total_cases + 1;

                            // Reset key timers by waiting or re-applying
                            rst_n = 0;
                            #20;
                            rst_n = 1;
                            #20;
                            set_host_cfg(32'h0000_00AA);

                            // Apply line state to both sides
                            case (i_line_state)
                                0: begin // invalid
                                    lane_l_valid = 1'b0; lane_l_solid = 1'b0;
                                    lane_r_valid = 1'b0; lane_r_solid = 1'b0;
                                    line_dashed = 1'b0;
                                end
                                1: begin // dashed
                                    lane_l_valid = 1'b1; lane_l_solid = 1'b0;
                                    lane_r_valid = 1'b1; lane_r_solid = 1'b0;
                                    line_dashed = 1'b1;
                                end
                                2: begin // solid
                                    lane_l_valid = 1'b1; lane_l_solid = 1'b1;
                                    lane_r_valid = 1'b1; lane_r_solid = 1'b1;
                                    line_dashed = 1'b0;
                                end
                            endcase

                            lane_depart_warning = i_dep_warn[0];

                            // Base LANE_CTRL
                            lane_ctrl = 32'd0;
                            lane_ctrl[2] = i_lane_mode[0];
                            lane_ctrl[3] = i_dep_en[0];

                            req_side = 0;
                            is_force = 0;

                            // Apply request
                            case (i_req_mode)
                                0: begin // None
                                    req_side = 0; is_force = 0;
                                end
                                1: begin // KEY2 SHORT
                                    send_key(3'd2, T_SHORT);
                                    req_side = 1; is_force = 0;
                                end
                                2: begin // KEY2 LONG (force)
                                    send_key(3'd2, T_LONG);
                                    req_side = 1; is_force = 1;
                                end
                                3: begin // KEY3 SHORT
                                    send_key(3'd3, T_SHORT);
                                    req_side = 2; is_force = 0;
                                end
                                4: begin // KEY3 LONG (force)
                                    send_key(3'd3, T_LONG);
                                    req_side = 2; is_force = 1;
                                end
                                5: begin // SW Left Normal
                                    lane_ctrl[8] = 1'b1; lane_ctrl[10] = 1'b0;
                                    req_side = 1; is_force = 0;
                                end
                                6: begin // SW Left Force
                                    lane_ctrl[8] = 1'b1; lane_ctrl[10] = 1'b1;
                                    req_side = 1; is_force = 1;
                                end
                                7: begin // SW Right Normal
                                    lane_ctrl[9] = 1'b1; lane_ctrl[10] = 1'b0;
                                    req_side = 2; is_force = 0;
                                end
                                8: begin // SW Right Force
                                    lane_ctrl[9] = 1'b1; lane_ctrl[10] = 1'b1;
                                    req_side = 2; is_force = 1;
                                end
                                9: begin // Both KEY: Right then Left (Left last)
                                    send_key(3'd3, T_SHORT);
                                    send_key(3'd2, T_LONG);
                                    req_side = 1; is_force = 1;
                                end
                                10: begin // Both KEY: Left then Right (Right last)
                                    send_key(3'd2, T_LONG);
                                    send_key(3'd3, T_SHORT);
                                    req_side = 2; is_force = 0;
                                end
                                11: begin // Both SW: Right then Left
                                    lane_ctrl[9] = 1'b1;
                                    repeat (2) @(posedge pix_clk);
                                    lane_ctrl[8] = 1'b1; lane_ctrl[10] = 1'b1;
                                    req_side = 1; is_force = 1;
                                end
                                12: begin // Both SW: Left then Right
                                    lane_ctrl[8] = 1'b1; lane_ctrl[10] = 1'b0;
                                    repeat (2) @(posedge pix_clk);
                                    lane_ctrl[9] = 1'b1; lane_ctrl[10] = 1'b1;
                                    req_side = 2; is_force = 1;
                                end
                            endcase

                            repeat (5) @(posedge pix_clk);

                            // Calculate Expected DEC
                            if (i_lane_mode == 0) begin
                                exp_dec = 32'h0000_00AA; // Host 0x850 pass-through
                            end else begin
                                // Hardware Lane Mode
                                if (req_side == 0) begin
                                    exp_dec_state = 2'd0; // KEEP
                                end else begin
                                    exp_dec_state = line_dashed ? 2'd1 : is_force ? 2'd2 : 2'd0;
                                end

                                exp_dec = 32'd0;
                                case (exp_dec_state)
                                    2'd1: begin // ALLOW
                                        exp_dec[1:0] = (req_side == 1) ? 2'd2 : 2'd1;
                                        exp_dec[3:2] = 2'd1;
                                        exp_dec[5:4] = (req_side == 2) ? 2'd2 : 2'd1;
                                        exp_dec[8]   = (i_dep_en && i_dep_warn);
                                    end
                                    2'd2: begin // ALARM
                                        exp_dec[1:0] = (req_side == 1) ? 2'd3 : 2'd1;
                                        exp_dec[3:2] = 2'd2;
                                        exp_dec[5:4] = (req_side == 2) ? 2'd3 : 2'd1;
                                        exp_dec[8]   = 1'b1;
                                    end
                                    default: begin // KEEP
                                        exp_dec[1:0] = 2'd1;
                                        exp_dec[3:2] = 2'd2;
                                        exp_dec[5:4] = 2'd1;
                                        exp_dec[8]   = (i_dep_en && i_dep_warn);
                                    end
                                endcase
                            end

                            // Compare
                            if (dec_out != exp_dec) begin
                                mismatch_count = mismatch_count + 1;
                                if (mismatch_count <= 10) begin
                                    $display("MISMATCH case=%0d (mode=%0d, dep_en=%0d, dep_warn=%0d, line=%0d, req=%0d): RTL dec=%08X vs EXP dec=%08X",
                                             total_cases, i_lane_mode, i_dep_en, i_dep_warn, i_line_state, i_req_mode,
                                             dec_out, exp_dec);
                                end
                            end
                        end
                    end
                end
            end
        end

        $display("==================================================");
        $display("DECIDE: cases=%0d mismatch=%0d", total_cases, mismatch_count);
        $display("==================================================");
        $finish;
    end

endmodule
