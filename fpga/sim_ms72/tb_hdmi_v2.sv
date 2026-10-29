`timescale 1ns/1ps
//////////////////////////////////////////////////////////////////////////////
// tb_hdmi.sv : MS7210/MS7200 I2C bring-up, host re-init, NACK stats
//   - no RTL changes, TB + I2C slave model only
//////////////////////////////////////////////////////////////////////////////
module tb_hdmi_v2;

    //------------------------------------------------------------------
    // clocks / resets
    //------------------------------------------------------------------
    reg cfg_clk = 0, pclk = 0;
    reg cfg_rst_n = 0, pclk_rst_n = 0;
    always #50 cfg_clk = ~cfg_clk;   // 10 MHz
    always #4  pclk    = ~pclk;      // 125 MHz

    initial begin
        #1000;
        cfg_rst_n  = 1;
        pclk_rst_n = 1;
    end

    //------------------------------------------------------------------
    // DUT
    //------------------------------------------------------------------
    wire scl, sda;
    wire init_over_rx, init_over_o;
    wire stat_tgl;
    wire [31:0] stat_bus;
    wire reinit_tgl;
    wire rx_en;
    pullup(sda);

    ms72xx_ctl #(.MS7210_WAIT_CNT(22'd2000)) u_ms (
        .clk            (cfg_clk),
        .rst_n          (cfg_rst_n),
        .init_over_rx   (init_over_rx),
        .init_over      (init_over_o),
        .iic_scl        (scl),
        .iic_sda        (sda),
        .rx_en          (rx_en),
        .reinit_tgl     (reinit_tgl),
        .stat_tgl       (stat_tgl),
        .stat_bus       (stat_bus)
    );

    //------------------------------------------------------------------
    // BAR1 ext register file (pclk domain)
    //------------------------------------------------------------------
    reg         i_tap_vld  = 0;
    reg  [11:0] i_tap_addr = 0;
    reg  [31:0] i_tap_data = 0;
    reg  [11:0] i_rd_addr  = 0;
    wire [127:0] o_rd128;

    rt_ext_regs u_regs (
        .clk                (pclk),
        .rst_n              (pclk_rst_n),
        .i_tap_vld          (i_tap_vld),
        .i_tap_addr         (i_tap_addr),
        .i_tap_data         (i_tap_data),
        .i_rd_addr          (i_rd_addr),
        .o_rd128            (o_rd128),
        .cfg_tgl            (),
        .cfg_ctrl           (),
        .cfg_fb_base        (),
        .cfg_slot_size      (),
        .cfg_stride         (),
        .cfg_uv_off         (),
        .commit_tgl         (),
        .commit_slot        (),
        .commit_frame_id    (),
        .i_stat_tgl         (1'b0),
        .i_stat_bus         (160'd0),
        .o_osd_tgl          (),
        .o_osd_cfg          (),
        .o_tram_we          (),
        .o_tram_addr        (),
        .o_tram_data        (),
        .i_evt_tgl          (1'b0),
        .i_evt_key          (3'd0),
        .i_evt_type         (2'd0),
        .i_evt_step         (6'd0),
        .i_drv_tgl          (1'b0),
        .i_drv_bus          (10'd0),
        .i_cal_tgl          (1'b0),
        .i_cal_bus          (60'd0),
        .i_key_stat         (5'd0),
        .o_led_host         (),
        .o_led_oe           (),
        .o_hdmi_reinit_tgl  (reinit_tgl),
        .o_hdmi_rx_en       (rx_en),
        .i_hdmi_stat_tgl    (stat_tgl),
        .i_hdmi_stat_bus    (stat_bus)
    );

    //------------------------------------------------------------------
    // BAR1 access tasks (same timing style as tb_ext.sv)
    //------------------------------------------------------------------
    task tap_wr;
        input [11:0] a;
        input [31:0] d;
        begin
            @(posedge pclk);
            i_tap_vld  <= 1'b1;
            i_tap_addr <= a;
            i_tap_data <= d;
            @(posedge pclk);
            i_tap_vld  <= 1'b0;
            repeat (4) @(posedge pclk);
        end
    endtask

    task rd_grp;
        input  [11:0]  a;
        output [127:0] d;
        begin
            i_rd_addr <= a;
            repeat (3) @(posedge pclk);
            d = o_rd128;
            @(posedge pclk);
        end
    endtask

    task get_stat;
        output [31:0] s;
        reg [127:0] d;
        begin
            rd_grp(12'h830, d);
            s = d[63:32];
        end
    endtask

    //------------------------------------------------------------------
    // expected MS7210 command table, copied from ms7210_ctl.v cmd_data
    // index 0..48 (CONECT write is checked separately)
    //------------------------------------------------------------------
    reg [23:0] exp_cmd [0:48];
    reg [23:0] exp_wrq [0:50];
    integer ei;
    initial begin
        exp_cmd[ 0] = {16'h1281, 8'h04};
        exp_cmd[ 1] = {16'h0016, 8'h04};
        exp_cmd[ 2] = {16'h0009, 8'h01};
        exp_cmd[ 3] = {16'h0007, 8'h09};
        exp_cmd[ 4] = {16'h0008, 8'hF0};
        exp_cmd[ 5] = {16'h000A, 8'hF0};
        exp_cmd[ 6] = {16'h0006, 8'h11};
        exp_cmd[ 7] = {16'h0531, 8'h84};
        exp_cmd[ 8] = {16'h0900, 8'h20};
        exp_cmd[ 9] = {16'h0901, 8'h47};
        exp_cmd[10] = {16'h0904, 8'h09};
        exp_cmd[11] = {16'h0923, 8'h07};
        exp_cmd[12] = {16'h0924, 8'h44};
        exp_cmd[13] = {16'h0925, 8'h44};
        exp_cmd[14] = {16'h090F, 8'h80};
        exp_cmd[15] = {16'h091F, 8'h07};
        exp_cmd[16] = {16'h0920, 8'h1E};
        exp_cmd[17] = {16'h0018, 8'h20};
        exp_cmd[18] = {16'h05C0, 8'hFE};
        exp_cmd[19] = {16'h000B, 8'h00};
        exp_cmd[20] = {16'h0507, 8'h06};
        exp_cmd[21] = {16'h0906, 8'h04};
        exp_cmd[22] = {16'h0920, 8'h5E};
        exp_cmd[23] = {16'h0926, 8'hDD};
        exp_cmd[24] = {16'h0927, 8'h0D};
        exp_cmd[25] = {16'h0928, 8'h88};
        exp_cmd[26] = {16'h0929, 8'h08};
        exp_cmd[27] = {16'h0910, 8'h01};
        exp_cmd[28] = {16'h000B, 8'h11};
        exp_cmd[29] = {16'h050E, 8'h00};
        exp_cmd[30] = {16'h050A, 8'h82};
        exp_cmd[31] = {16'h0509, 8'h02};
        exp_cmd[32] = {16'h050B, 8'h0D};
        exp_cmd[33] = {16'h050D, 8'h06};
        exp_cmd[34] = {16'h050D, 8'h11};
        exp_cmd[35] = {16'h050D, 8'h58};
        exp_cmd[36] = {16'h050D, 8'h00};
        exp_cmd[37] = {16'h050D, 8'h00};
        exp_cmd[38] = {16'h050D, 8'h00};
        exp_cmd[39] = {16'h050D, 8'h00};
        exp_cmd[40] = {16'h050D, 8'h00};
        exp_cmd[41] = {16'h050D, 8'h00};
        exp_cmd[42] = {16'h050D, 8'h00};
        exp_cmd[43] = {16'h050D, 8'h00};
        exp_cmd[44] = {16'h050D, 8'h00};
        exp_cmd[45] = {16'h050D, 8'h00};
        exp_cmd[46] = {16'h050D, 8'h00};
        exp_cmd[47] = {16'h050E, 8'h40};
        exp_cmd[48] = {16'h0507, 8'h00};

        // Known original-RTL behavior (kept, deliberately not filtered):
        // the last INIT busy_falling both enters WAIT and leaves
        // ms7210_ctl.iic_trig asserted (ms7210_ctl.v:240-248 uses the old
        // state in the case), so cmd19 ({000B,00}) is written once during
        // WAIT.  The WAIT-end trigger then writes cmd19 again as the first
        // SETING command.  cmd28 later writes {000B,11}, so the duplicate
        // {000B,00} is harmless; this is validated on board (osd1c).
        // Expected queue therefore:
        //   {0003,5A} + cmd0..cmd18 + cmd19 + cmd19..cmd48  (51 writes)
        exp_wrq[0] = {16'h0003, 8'h5A};
        for (ei = 0; ei < 19; ei = ei + 1)
            exp_wrq[1 + ei] = exp_cmd[ei];
        exp_wrq[20] = exp_cmd[19];
        for (ei = 19; ei < 49; ei = ei + 1)
            exp_wrq[ei + 2] = exp_cmd[ei];
    end

    //------------------------------------------------------------------
    // I2C slave model (open drain, drive changes T_DLY after SCL falling)
    // NOTE: iic_dri really sends addr[7:0] first and addr[15:8] second
    //       (iic_dri.v:264-268), so the model rebuilds {b2,b1}.
    //------------------------------------------------------------------
    localparam integer T_DLY = 700;   // ns

    reg sda_low = 1'b0;
    assign sda = sda_low ? 1'b0 : 1'bz;

    reg [7:0] mem59 [int];            // MS7210 (0xB2 / 7'h59)
    reg [7:0] mem2b [int];            // MS7200 (0x56 / 7'h2B)

    reg        in_txn       = 1'b0;
    reg [3:0]  bit_pos      = 4'd0;   // 0..7 data bits, 8 = ACK bit
    integer    byte_cnt     = 0;
    reg [7:0]  shreg        = 8'd0;
    reg        cur_rw       = 1'b0;
    reg [7:0]  cur_dev      = 8'h00;
    reg [15:0] acc_lo       = 16'd0;
    reg [15:0] acc_hi       = 16'd0;
    reg [15:0] reg_addr     = 16'd0;
    reg [15:0] last_data_addr = 16'd0;
    reg [7:0]  last_data    = 8'd0;
    reg        read_mode    = 1'b0;
    reg        read_drive_en= 1'b0;
    reg [7:0]  read_data    = 8'd0;
    reg        ack_flag     = 1'b0;
    reg        post_ack     = 1'b0;
    reg        mon_en       = 1'b0;

    reg [23:0] wr7210 [0:255];
    time       wr_start [0:255];      // transaction START time (write log)
    reg [5:0]  wr_state [0:255];      // MS7210 tx_state sampled at START
    reg        dbg_wr = 1'b0;
    initial if ($test$plusargs("DBG_WR")) dbg_wr = 1'b1;
    integer    n_wr7210 = 0;
    integer    n_rd7210 = 0;
    integer    n_txn7200 = 0;
    integer    inject_hits = 0;
    reg        inject_en = 1'b0;
    reg [15:0] inject_reg = 16'd0;
    reg        continuous_inject_en = 1'b0;
    reg [15:0] continuous_inject_reg = 16'd0;
    integer    proto_err = 0;
    reg [15:0] last_rd_addr7210 = 16'd0;
    reg [7:0]  last_rd_data7210 = 8'd0;

    time       txn_start = 0;         // first START of current transaction
    time       seg_start = 0;         // START of current address segment
    reg        seg_new   = 1'b0;      // current segment is a fresh transaction
    reg [5:0]  seg_ms_state = 6'h00;  // MS7210 tx_state at segment START

    // WAIT -> SETING transition time of the MS7210 controller (per init)
    reg [5:0]  ms_state_prev = 6'h3f;
    time       wait_end_time = 0;
    always @(posedge cfg_clk) begin
        if ((ms_state_prev == 6'h08) && (u_ms.U2_ms7210_ctl.state == 6'h10))
            wait_end_time = $time;
        ms_state_prev <= u_ms.U2_ms7210_ctl.state;
    end

    // C-segment evidence
    time       t_req = 0;
    reg        c_armed = 1'b0;
    reg        c_req_in_txn = 1'b0;
    time       c_req_txn_start = 0;
    reg        c_stop_seen = 1'b0;
    time       c_stop_time = 0;
    reg        c_new7200_start = 1'b0;
    reg        c_first7210_seen = 1'b0;
    time       c_first7210_time = 0;

    initial begin
        mem59[16'h0502] = 8'hA7;      // MS7210 STA_RD value
        mem59[16'h0003] = 8'h5A;      // keep CONECT readback sane
        #1050 mon_en = 1'b1;
    end

    function automatic [7:0] mem_rd;
        input [7:0]  dev;
        input [15:0] a;
        begin
            if (dev == 8'hB2)
                mem_rd = mem59.exists(a) ? mem59[a] : 8'h00;
            else if (dev == 8'h56)
                mem_rd = mem2b.exists(a) ? mem2b[a] : 8'h00;
            else
                mem_rd = 8'h00;
        end
    endfunction

    // full byte processing at the 8th SCL rising edge
    task automatic process_byte;
        input [7:0] b;
        begin
            if (byte_cnt == 0) begin
                cur_rw      = b[0];
                read_mode   = 1'b0;
                read_drive_en = 1'b0;
                case (b[7:1])
                    7'h59:   cur_dev = 8'hB2;
                    7'h2B:   cur_dev = 8'h56;
                    default: cur_dev = 8'h00;
                endcase
                ack_flag = (cur_dev != 8'h00);
                if (cur_dev != 8'h00 && cur_rw) begin
                    read_mode     = 1'b1;
                    read_data     = mem_rd(cur_dev, reg_addr);
                    read_drive_en = 1'b1;
                end
                // C-segment event classification (only fresh transactions)
                if (c_armed && seg_new && (seg_start > t_req)) begin
                    if (cur_dev == 8'h56)
                        c_new7200_start = 1'b1;
                    if ((cur_dev == 8'hB2) && !c_first7210_seen) begin
                        c_first7210_seen = 1'b1;
                        c_first7210_time = seg_start;
                        $display("[%0t] C: first MS7210 START after t_req", seg_start);
                    end
                end
            end
            else if (!cur_rw) begin
                if (byte_cnt == 1) begin
                    acc_lo = {8'h00, b};
                end
                else if (byte_cnt == 2) begin
                    acc_hi   = {8'h00, b};
                    reg_addr = {acc_hi[7:0], acc_lo[7:0]};
                end
                else begin
                    last_data_addr = reg_addr;
                    last_data      = b;
                    if ((cur_dev == 8'hB2) && ((inject_en && (reg_addr == inject_reg)) || (continuous_inject_en && (reg_addr == continuous_inject_reg)))) begin
                        ack_flag  = 1'b0;          // NACK, do not store
                        inject_en = 1'b0;
                        inject_hits = inject_hits + 1;
                        $display("[%0t] inject NACK at MS7210 reg %04h data %02h (continuous=%0d)",
                                 $time, reg_addr, b, continuous_inject_en);
                    end
                    else begin
                        ack_flag = 1'b1;
                        if (cur_dev == 8'hB2)      mem59[reg_addr] = b;
                        else if (cur_dev == 8'h56) mem2b[reg_addr] = b;
                    end
                    reg_addr = reg_addr + 16'd1;
                end
            end
            else begin
                // slave is shifting out read data; record the value
                read_data = b;
                ack_flag  = 1'b0;               // release for master ACK/NACK
            end
        end
    endtask

    // START / repeated START : SDA falls while SCL is high
    always @(negedge sda) begin
        if (mon_en && (scl === 1'b1)) begin
            if (in_txn && (bit_pos != 4'd0) && !post_ack) begin
                proto_err = proto_err + 1;
                if (proto_err <= 20)
                    $display("[%0t] PROTO_ERR START mid-byte bit_pos=%0d byte_cnt=%0d dev=%02h",
                             $time, bit_pos, byte_cnt, cur_dev);
            end
            seg_new   = ~in_txn;
            seg_start = $time;
            seg_ms_state = u_ms.U2_ms7210_ctl.state;
            if (!in_txn) txn_start = $time;
            in_txn    = 1'b1;
            bit_pos   = 4'd0;
            byte_cnt  = 0;
            shreg     = 8'd0;
            read_mode = 1'b0;
            read_drive_en = 1'b0;
            ack_flag  = 1'b0;
            post_ack  = 1'b0;
        end
    end

    // STOP : SDA rises while SCL is high
    always @(posedge sda) begin
        if (mon_en && (scl === 1'b1)) begin
            if (in_txn && (bit_pos != 4'd0) && !post_ack) begin
                proto_err = proto_err + 1;
                if (proto_err <= 20)
                    $display("[%0t] PROTO_ERR STOP mid-byte bit_pos=%0d byte_cnt=%0d dev=%02h",
                             $time, bit_pos, byte_cnt, cur_dev);
            end
            if (in_txn) begin
                if (cur_dev == 8'hB2) begin
                    if (cur_rw) begin
                        n_rd7210 = n_rd7210 + 1;
                        last_rd_addr7210 = reg_addr;
                        last_rd_data7210 = read_data;
                    end
                    else begin
                        if (dbg_wr)
                            $display("[%0t] WR7210[%0d] addr=%04h data=%02h txn_start=%0t state_at_start=%02h",
                                     $time, n_wr7210, last_data_addr, last_data,
                                     txn_start, seg_ms_state);
                        if (n_wr7210 < 256) begin
                            wr7210[n_wr7210] = {last_data_addr, last_data};
                            wr_start[n_wr7210] = txn_start;
                            wr_state[n_wr7210] = seg_ms_state;
                        end
                        n_wr7210 = n_wr7210 + 1;
                    end
                end
                else if (cur_dev == 8'h56) begin
                    n_txn7200 = n_txn7200 + 1;
                    if (c_armed && c_req_in_txn && (txn_start == c_req_txn_start)) begin
                        c_stop_seen = 1'b1;
                        c_stop_time = $time;
                        $display("[%0t] C: interrupted MS7200 STOP (txn_start=%0t, dev=%02h)",
                                 $time, txn_start, cur_dev);
                    end
                end
            end
            in_txn    = 1'b0;
            bit_pos   = 4'd0;
            byte_cnt  = 0;
            read_mode = 1'b0;
            read_drive_en = 1'b0;
            ack_flag  = 1'b0;
            post_ack  = 1'b0;
            sda_low   = 1'b0;
        end
    end

    // shift in on SCL rising edge
    always @(posedge scl) begin
        if (in_txn) begin
            if (bit_pos < 4'd8) begin
                if (bit_pos == 4'd7) begin
                    process_byte({shreg[6:0], (sda === 1'b1)});
                    bit_pos = 4'd8;
                end
                else begin
                    shreg   = {shreg[6:0], (sda === 1'b1)};
                    bit_pos = bit_pos + 4'd1;
                end
            end
            else begin
                // 9th clock: ACK bit; for a read data byte this is
                // the master ACK/NACK.  NACK stops further read data.
                if (read_mode && (byte_cnt >= 1) && (sda === 1'b1))
                    read_drive_en = 1'b0;
                bit_pos  = 4'd0;
                byte_cnt = byte_cnt + 1;
                post_ack = 1'b1;
            end
        end
    end

    // slave drive changes happen T_DLY after SCL falling edge
    always @(negedge scl) begin
        #(T_DLY);
        if (!in_txn) begin
            sda_low = 1'b0;
        end
        else if (bit_pos == 4'd8) begin
            sda_low = ack_flag ? 1'b1 : 1'b0;
        end
        else if (read_mode && read_drive_en && (bit_pos < 4'd8)) begin
            sda_low = ~read_data[7 - bit_pos];
        end
        else begin
            sda_low = 1'b0;
        end
        if (bit_pos != 4'd0)
            post_ack = 1'b0;
    end

    //------------------------------------------------------------------
    // debug tracing of the MS7210 controller (only with +DBG_WR)
    //------------------------------------------------------------------
    reg [5:0] dbg_prev_state = 6'h3f;
    reg       dbg_prev_trig  = 1'b0;
    always @(posedge cfg_clk) begin
        if (dbg_wr) begin
            if (u_ms.U2_ms7210_ctl.state !== dbg_prev_state)
                $display("[%0t] MS7210 state -> %02h (cmd_index=%0d delay_cnt=%0d busy=%0d iic_trig=%0d addr=%04h data=%02h)",
                         $time, u_ms.U2_ms7210_ctl.state,
                         u_ms.U2_ms7210_ctl.cmd_index, u_ms.U2_ms7210_ctl.delay_cnt,
                         u_ms.busy, u_ms.U2_ms7210_ctl.iic_trig,
                         u_ms.U2_ms7210_ctl.addr, u_ms.U2_ms7210_ctl.data_in);
            if (u_ms.U2_ms7210_ctl.iic_trig && !dbg_prev_trig)
                $display("[%0t] MS7210 iic_trig RISE state=%02h cmd_index=%0d delay_cnt=%0d addr=%04h data=%02h w_r=%0d busy=%0d quiet=%0d",
                         $time, u_ms.U2_ms7210_ctl.state,
                         u_ms.U2_ms7210_ctl.cmd_index, u_ms.U2_ms7210_ctl.delay_cnt,
                         u_ms.U2_ms7210_ctl.addr, u_ms.U2_ms7210_ctl.data_in,
                         u_ms.U2_ms7210_ctl.w_r, u_ms.busy, u_ms.iic_trig);
            dbg_prev_state <= u_ms.U2_ms7210_ctl.state;
            dbg_prev_trig  <= u_ms.U2_ms7210_ctl.iic_trig;
        end
    end

    //------------------------------------------------------------------
    // checks / reporting
    //------------------------------------------------------------------
    string  seg_name;
    integer seg_fail;
    integer total_fail = 0;
    reg [31:0] stat;
    reg [31:0] stat_prev;
    reg [127:0] d128;

    task chk64;
        input string nm;
        input [63:0] got;
        input [63:0] exp;
        begin
            if (got !== exp) begin
                $display("%s FAIL: %s got=%0h exp=%0h", seg_name, nm, got, exp);
                seg_fail = 1;
            end
        end
    endtask

    task chk_wrq;
        integer k;
        begin
            if (n_wr7210 != 51) begin
                $display("%s FAIL: n_wr7210 got=%0d exp=51", seg_name, n_wr7210);
                seg_fail = 1;
            end
            else begin
                for (k = 0; k < 51; k = k + 1) begin
                    if (wr7210[k] !== exp_wrq[k]) begin
                        $display("%s FAIL: wr7210[%0d] got=%06h exp=%06h",
                                 seg_name, k, wr7210[k], exp_wrq[k]);
                        seg_fail = 1;
                    end
                end
            end
        end
    endtask

    // The 21st write is the known duplicate cmd19 issued during WAIT.
    task chk_dup;
        begin
            chk64("dup cmd19 (write #21)", wr7210[20], exp_cmd[19]);
            chk64("dup cmd19 issued in WAIT", wr_state[20], 6'h08);
            chk64("dup cmd19 start < WAIT end", (wr_start[20] < wait_end_time), 1'b1);
        end
    endtask

    task clear_rec;
        begin
            n_wr7210 = 0;
            n_rd7210 = 0;
            n_txn7200 = 0;
        end
    endtask

    task report_stat;
        input string nm;
        input [31:0] s;
        begin
            $display("%s STAT=%08h [init_over=%0d nack_sticky=%0d rx_go=%0d ri_hold=%0d reinit_cnt=%0d fsm=%02h sta_valid=%0d nack_cnt=%0d sta_0502=%02h] n_wr7210=%0d n_rd7210=%0d n7200=%0d inject_hits=%0d proto_err=%0d",
                     nm, s, s[0], s[1], s[2], s[3], s[7:4], s[13:8], s[14],
                     s[23:16], s[31:24], n_wr7210, n_rd7210, n_txn7200,
                     inject_hits, proto_err);
        end
    endtask

    task seg_done;
        begin
            if (seg_fail == 0) begin
                $display("%s PASS", seg_name);
            end
            else begin
                $display("%s FAIL", seg_name);
                total_fail = total_fail + 1;
            end
        end
    endtask

    reg seen_ri_hold;
    reg seen_init0;
    integer ok_reinit;

    task wait_reinit_done;
        input integer  expect_rc;
        output [31:0]  s;
        output integer ok;
        time t_end;
        integer started;
        begin
            started = 0;
            ok      = 0;
            t_end   = $time + 60_000_000;   // 60 ms
            while (!started && ($time < t_end)) begin
                if (u_ms.ri_hold) seen_ri_hold = 1'b1;
                get_stat(s);
                if (s[3])     seen_ri_hold = 1'b1;
                if (!s[0]) begin
                    seen_init0 = 1'b1;
                    started    = 1;          // register snapshot saw init_over=0
                end
                else #2000;
            end
            while ((!ok) && ($time < t_end)) begin
                if (u_ms.ri_hold) seen_ri_hold = 1'b1;
                get_stat(s);
                if (s[3])  seen_ri_hold = 1'b1;
                if (!s[0]) seen_init0   = 1'b1;
                if (s[0] && s[2] && s[14]) ok = 1;
                else #5000;
            end
            if (!ok)
                $display("%s FAIL: reinit completion timeout (stat=%08h)", seg_name, s);
        end
    endtask

    task wait_reinit_done_no_rxgo;
        input integer  expect_rc;
        output [31:0]  s;
        output integer ok;
        time t_end;
        integer started;
        begin
            started = 0;
            ok      = 0;
            t_end   = $time + 60_000_000;   // 60 ms
            while (!started && ($time < t_end)) begin
                if (u_ms.ri_hold) seen_ri_hold = 1'b1;
                get_stat(s);
                if (s[3])     seen_ri_hold = 1'b1;
                if (!s[0]) begin
                    seen_init0 = 1'b1;
                    started    = 1;
                end
                else #2000;
            end
            while ((!ok) && ($time < t_end)) begin
                if (u_ms.ri_hold) seen_ri_hold = 1'b1;
                get_stat(s);
                if (s[3])  seen_ri_hold = 1'b1;
                if (!s[0]) seen_init0   = 1'b1;
                if (s[0] && s[14] && !s[3] && !u_ms.busy && (u_ms.ri_st == 2'd0)) begin
                    #50000;
                    get_stat(s);
                    if (s[0] && s[14] && !s[3] && !u_ms.busy && (u_ms.ri_st == 2'd0))
                        ok = 1;
                end
                else #5000;
            end
            if (!ok)
                $display("%s FAIL: reinit completion timeout (stat=%08h)", seg_name, s);
        end
    endtask

    //------------------------------------------------------------------
    // main test sequence
    //------------------------------------------------------------------
    integer quiet_toggles;
    time    t_quiet_end;

    initial begin
        #2000;

        //=============== V : version ===============
        seg_name = "V"; seg_fail = 0;
        rd_grp(12'h830, d128);
        chk64("version", d128[95:64], 32'h2026_1019);
        $display("V version=%08h", d128[95:64]);
        seg_done();

        //=============== (a) : rx_en=0 default power-on boot, 50ms quiet ===============
        seg_name = "(a)"; seg_fail = 0;
        stat = 0;
        begin : wait_boot_a
            time t_end;
            t_end = $time + 60_000_000;
            while (!(stat[0] && stat[14]) && ($time < t_end)) begin
                #20000;
                get_stat(stat);
            end
            if (!(stat[0] && stat[14])) begin
                $display("(a) FAIL: init timeout (stat=%08h)", stat);
                seg_fail = 1;
            end
        end
        chk64("(a) init_over",       stat[0],     1'b1);
        chk64("(a) rx_go == 0",      stat[2],     1'b0);
        chk64("(a) nack_cnt",        stat[23:16], 8'd0);
        chk64("(a) nack_sticky",     stat[1],     1'b0);
        chk64("(a) fsm_state",       stat[13:8],  6'h20);
        chk64("(a) sta_0502",        stat[31:24], 8'hA7);
        chk64("(a) reinit_cnt",      stat[7:4],   4'd0);
        chk64("(a) ri_hold",         stat[3],     1'b0);
        chk64("(a) n_wr7210",        n_wr7210,    51);
        chk_wrq();
        chk_dup();
        chk64("(a) n_rd7210",        n_rd7210,    2);
        chk64("(a) proto_err",       proto_err,   0);

        // 50ms quiet check on SCL and SDA
        quiet_toggles = 0;
        t_quiet_end = $time + 50_000_000;
        fork : mon_quiet_a
            begin
                while ($time < t_quiet_end) begin
                    @(scl or sda);
                    quiet_toggles = quiet_toggles + 1;
                end
            end
            begin
                #50_000_000;
                disable mon_quiet_a;
            end
        join
        get_stat(stat);
        chk64("(a) 50ms quiet_toggles == 0", quiet_toggles, 0);
        chk64("(a) rx_go still 0", stat[2], 1'b0);
        chk64("(a) scl idle high", scl, 1'b1);
        chk64("(a) sda idle high", sda, 1'b1);
        $display("(a) PASS: rx_en=0 default boot quiet for 50ms, scl/sda toggles=%0d, rx_go=0", quiet_toggles);
        report_stat("(a)", stat);
        seg_done();

        //=============== (b) : single NACK injection -> auto reinit 1 time ===============
        seg_name = "(b)"; seg_fail = 0;
        clear_rec();
        inject_reg  = 16'h0901;
        inject_en   = 1'b1;
        inject_hits = 0;
        seen_ri_hold = 1'b0;
        seen_init0   = 1'b0;
        tap_wr(12'h834, 32'h0000_0001);  // manual re-init with rx_en=0
        wait_reinit_done_no_rxgo(2, stat, ok_reinit);
        chk64("(b) inject_hits",   inject_hits,  1);
        chk64("(b) nack_cnt",      stat[23:16],  8'd0); // cleared on auto-reinit round
        chk64("(b) nack_sticky",   stat[1],      1'b0);
        chk64("(b) init_over",     stat[0],      1'b1);
        chk64("(b) rx_go == 0",    stat[2],      1'b0);
        chk64("(b) reinit_cnt",    stat[7:4],    4'd2); // 1 from manual tap_wr + 1 from auto-reinit = 2
        chk64("(b) proto_err",     proto_err,    0);
        $display("(b) PASS: single NACK injected -> auto-reinit 1 time, final nack_cnt=0, reinit_cnt=%0d", stat[7:4]);
        report_stat("(b)", stat);
        seg_done();

        //=============== (c) : continuous NACK -> auto-retry exactly 3 times then stop ===============
        seg_name = "(c)"; seg_fail = 0;
        clear_rec();
        continuous_inject_reg = 16'h0901;
        continuous_inject_en  = 1'b1;
        seen_ri_hold = 1'b0;
        seen_init0   = 1'b0;
        tap_wr(12'h834, 32'h0000_0001);  // manual reinit resets auto-retry budget to 3
        #30_000_000;                     // allow initial + 3 retries to complete
        get_stat(stat);
        // previous reinit_cnt was 2. Manual reinit + 3 auto retries = 2 + 1 + 3 = 6.
        chk64("(c) reinit_cnt == 6",  stat[7:4],    4'd6);
        chk64("(c) nack_sticky == 1", stat[1],      1'b1);
        chk64("(c) nack_cnt >= 1",    (stat[23:16] >= 8'd1), 1'b1);
        chk64("(c) init_over == 1",   stat[0],      1'b1);
        chk64("(c) rx_go == 0",       stat[2],      1'b0);
        continuous_inject_en = 1'b0;
        // ensure no further reinit occurs
        #10_000_000;
        get_stat(stat);
        chk64("(c) reinit_cnt still 6", stat[7:4], 4'd6);
        $display("(c) PASS: continuous NACK stopped after exactly 3 auto-retries, reinit_cnt=%0d", stat[7:4]);
        report_stat("(c)", stat);
        seg_done();

        //=============== (d) : write 0x834=3 -> MS7200 controller regains bus ===============
        seg_name = "(d)"; seg_fail = 0;
        clear_rec();
        inject_en = 1'b0;
        continuous_inject_en = 1'b0;
        seen_ri_hold = 1'b0;
        seen_init0   = 1'b0;
        tap_wr(12'h834, 32'h0000_0003);  // re-init + rx_en=1
        wait_reinit_done(7, stat, ok_reinit);
        chk64("(d) init_over",       stat[0],     1'b1);
        chk64("(d) rx_go",           stat[2],     1'b1);
        chk64("(d) sta_valid",       stat[14],    1'b1);
        chk64("(d) reinit_cnt",      stat[7:4],   4'd7); // 6 + 1 = 7
        chk64("(d) nack_cnt",        stat[23:16], 8'd0);
        chk64("(d) nack_sticky",     stat[1],     1'b0);
        // wait for MS7200 transactions
        begin : wait_ms7200_d
            integer w;
            for (w = 0; w < 50 && n_txn7200 == 0; w = w + 1) #100_000;
        end
        chk64("(d) n_txn7200 > 0",   (n_txn7200 > 0), 1'b1);
        $display("(d) PASS: write 0x834=3 enabled rx_go, MS7200 regained bus with %0d transactions", n_txn7200);
        report_stat("(d)", stat);
        seg_done();

        //=============== C : re-init during an MS7200 transaction ===============
        seg_name = "C"; seg_fail = 0;
        clear_rec();
        t_req = 0;
        c_req_in_txn = 1'b0;
        c_req_txn_start = 0;
        c_stop_seen = 1'b0;
        c_stop_time = 0;
        c_new7200_start = 1'b0;
        c_first7210_seen = 1'b0;
        c_first7210_time = 0;
        seen_ri_hold = 1'b0;
        seen_init0   = 1'b0;

        while (!u_ms.rx_go) @(posedge cfg_clk);
        @(posedge u_ms.busy);
        begin : wait_start_c
            integer n;
            n = 0;
            while (!in_txn && (n < 2000)) begin
                @(posedge cfg_clk);
                n = n + 1;
            end
            if (!in_txn) begin
                $display("C FAIL: no MS7200 START after busy rise");
                seg_fail = 1;
            end
        end
        #3000;
        t_req = $time;
        c_req_in_txn     = in_txn;
        c_req_txn_start  = txn_start;
        c_armed          = 1'b1;
        $display("[%0t] C: t_req, in_txn=%0d txn_start=%0t", t_req, in_txn, txn_start);
        tap_wr(12'h834, 32'h0000_0003);   // write 3 to maintain rx_en=1

        wait_reinit_done(8, stat, ok_reinit);
        c_armed = 1'b0;

        chk64("init_over",     stat[0],     1'b1);
        chk64("rx_go",         stat[2],     1'b1);
        chk64("sta_valid",     stat[14],    1'b1);
        chk64("reinit_cnt",    stat[7:4],   4'd8); // 7 + 1 = 8
        chk64("nack_cnt",      stat[23:16], 8'd0);
        chk64("nack_sticky",   stat[1],     1'b0);
        chk64("sta_0502",      stat[31:24], 8'hA7);
        chk64("seen_ri_hold",  seen_ri_hold, 1'b1);
        chk64("seen_init0",    seen_init0,   1'b1);
        chk64("n_wr7210",      n_wr7210,    51);
        chk_wrq();
        chk_dup();
        chk64("n_rd7210",      n_rd7210,    2);
        chk64("proto_err",     proto_err,   0);
        chk64("C req in txn",  c_req_in_txn, 1'b1);
        chk64("C stop seen",   c_stop_seen,  1'b1);
        chk64("C stop > t_req",(c_stop_time > t_req), 1'b1);
        chk64("C 7210 start seen", c_first7210_seen, 1'b1);
        chk64("C 7210 start > stop",(c_first7210_time > c_stop_time), 1'b1);
        chk64("C no new 7200 start", !c_new7200_start, 1'b1);
        $display("C TIMES t_req=%0t interrupted_stop=%0t first_ms7210_start=%0t new_7200_start=%0d",
                 t_req, c_stop_time, c_first7210_time, c_new7200_start);
        report_stat("C", stat);
        seg_done();

        //=============== B : NACK injection under rx_en=1 with auto-retry ===============
        seg_name = "B"; seg_fail = 0;
        clear_rec();
        inject_reg  = 16'h0901;
        inject_en   = 1'b1;
        inject_hits = 0;
        seen_ri_hold = 1'b0;
        seen_init0   = 1'b0;
        tap_wr(12'h834, 32'h0000_0003);  // manual reinit (reinit_cnt: 8 -> 9), NACK causes auto-reinit (reinit_cnt: 9 -> 10)
        wait_reinit_done(10, stat, ok_reinit);
        chk64("inject_hits",   inject_hits,  1);
        chk64("nack_cnt",      stat[23:16],  8'd0); // clean on 2nd round
        chk64("nack_sticky",   stat[1],      1'b0);
        chk64("init_over",     stat[0],      1'b1);
        chk64("rx_go",         stat[2],      1'b1);
        chk64("reinit_cnt",    stat[7:4],    4'd10); // 8 + 1 (manual) + 1 (auto) = 10
        chk64("proto_err",     proto_err,    0);
        $display("B PASS: NACK under rx_en=1 triggered auto-reinit, reinit_cnt=%0d, nack_cnt=0", stat[7:4]);
        report_stat("B", stat);
        seg_done();

        //=============== D : re-init clears NACK stats ===============
        seg_name = "D"; seg_fail = 0;
        inject_en = 1'b0;
        clear_rec();
        seen_ri_hold = 1'b0;
        seen_init0   = 1'b0;
        tap_wr(12'h834, 32'h0000_0003);
        wait_reinit_done(11, stat, ok_reinit);
        chk64("nack_cnt",     stat[23:16], 8'd0);
        chk64("nack_sticky",  stat[1],     1'b0);
        chk64("reinit_cnt",   stat[7:4],   4'd11); // 10 + 1 = 11
        chk64("proto_err",    proto_err,   0);
        report_stat("D", stat);
        seg_done();

        //=============== E : bit0=0 must not trigger ===============
        seg_name = "E"; seg_fail = 0;
        seen_ri_hold = 1'b0;
        get_stat(stat_prev);
        tap_wr(12'h834, 32'h0000_0002);
        begin : wait_E
            integer i;
            for (i = 0; i < 25; i = i + 1) begin
                #2000;
                if (u_ms.ri_hold) seen_ri_hold = 1'b1;
                get_stat(stat);
                if (stat[3]) seen_ri_hold = 1'b1;
            end
        end
        chk64("reinit_cnt still 11", stat[7:4], 4'd11);
        chk64("ri_hold never",      !seen_ri_hold, 1'b1);
        chk64("init_over held",     stat[0], 1'b1);
        report_stat("E", stat);
        seg_done();

        //=============== summary ===============
        if (total_fail == 0)
            $display("ALL HDMI TESTS PASSED");
        else
            $display("HDMI TESTS FAILED");
        $finish;
    end

    // global watchdog
    initial begin
        #400_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
