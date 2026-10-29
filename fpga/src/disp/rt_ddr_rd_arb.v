`timescale 1ns/1ps
//////////////////////////////////////////////////////////////////////////////
// rt_ddr_rd_arb.v  (20261018 disp)
// Two-client DDR3 AXI read arbiter (core_clk domain).
//   port0 : rt_ddr_hub read-back engine
//   port1 : display reader   (higher priority, but port0 gets a guaranteed
//                            grant after at most 8 consecutive misses)
//   A single ordered command FIFO (depth 16) of {owner,arlen} distributes the
//   return beats.  No reliance on rid.
//////////////////////////////////////////////////////////////////////////////
module rt_ddr_rd_arb
(
    input               clk             ,   // core_clk
    input               rst_n           ,

    // port 0 (rt_ddr_hub)
    input       [27:0]  s0_araddr       ,
    input       [3:0]   s0_arlen        ,
    input               s0_arvalid      ,
    output wire         s0_arready      ,
    output wire [255:0] s0_rdata        ,
    output wire         s0_rlast        ,
    output wire         s0_rvalid       ,

    // port 1 (display)
    input       [27:0]  s1_araddr       ,
    input       [3:0]   s1_arlen        ,
    input               s1_arvalid      ,
    output wire         s1_arready      ,
    output wire [255:0] s1_rdata        ,
    output wire         s1_rlast        ,
    output wire         s1_rvalid       ,

    // DDR3 IP read channel
    output reg  [27:0]  ddr_araddr      ,
    output reg  [3:0]   ddr_arlen       ,
    output reg          ddr_arvalid     ,
    input               ddr_arready     ,
    input       [255:0] ddr_rdata       ,
    input               ddr_rlast       ,
    input               ddr_rvalid      ,
    output wire [3:0]   ddr_aruser_id
);

    assign ddr_aruser_id = 4'd0;

    //------------------------------------------------------------------
    // command FIFO : {owner,arlen}
    //------------------------------------------------------------------
    reg        qo [0:15];
    reg  [3:0] ql [0:15];
    reg  [4:0] qwr, qrd;

    wire fifo_full  = ((qwr - qrd) == 5'd16);
    wire fifo_empty = (qwr == qrd);

    //------------------------------------------------------------------
    // AR arbitration FSM
    //------------------------------------------------------------------
    reg        busy_ar;
    reg        ar_owner;       // 0 = port0, 1 = port1
    reg  [3:0] miss0;          // consecutive port1 grants while port0 waiting

    wire can0   = s0_arvalid;
    wire can1   = s1_arvalid;
    wire force0 = can0 && (miss0 >= 4'd8);

    // selection: port1 preferred, port0 forced after 8 misses
    wire sel    = (!can1) ? 1'b0 :
                  (!can0) ? 1'b1 :
                  force0  ? 1'b0 : 1'b1;

    wire ar_push = busy_ar && ddr_arready;

    always @(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
        begin
            busy_ar <= 1'b0;
            ar_owner<= 1'b0;
            miss0   <= 4'd0;
        end
        else
        begin
            if (!busy_ar)
            begin
                if (!fifo_full && (can0 || can1))
                begin
                    busy_ar  <= 1'b1;
                    ar_owner <= sel;
                end
            end
            else if (ddr_arready)
            begin
                busy_ar <= 1'b0;
            end

            if (ar_push)
            begin
                if (ar_owner)
                begin
                    if (can0) miss0 <= (miss0 == 4'd8) ? miss0 : (miss0 + 1'b1);
                end
                else
                    miss0 <= 4'd0;
            end
        end
    end

    // command FIFO write on AR handshake
    always @(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
            qwr <= 5'd0;
        else if (ar_push)
            qwr <= qwr + 1'b1;
    end

    always @(posedge clk)
    begin
        if (ar_push)
        begin
            qo[qwr[3:0]] <= ar_owner;
            ql[qwr[3:0]] <= ar_owner ? s1_arlen : s0_arlen;
        end
    end

    //------------------------------------------------------------------
    // return beat distribution
    //------------------------------------------------------------------
    wire       cur_owner = qo[qrd[3:0]];
    wire [3:0] cur_len   = ql[qrd[3:0]];

    reg  [3:0] bcnt;

    wire beat_last = ddr_rvalid && !fifo_empty && (bcnt == cur_len);

    always @(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
            qrd <= 5'd0;
        else if (beat_last)
            qrd <= qrd + 1'b1;
    end

    always @(posedge clk or negedge rst_n)
    begin
        if (!rst_n)
            bcnt <= 4'd0;
        else if (ddr_rvalid && !fifo_empty)
        begin
            if (bcnt == cur_len) bcnt <= 4'd0;
            else                 bcnt <= bcnt + 1'b1;
        end
        else if (fifo_empty)
            bcnt <= 4'd0;
    end

    //------------------------------------------------------------------
    // DDR side
    //------------------------------------------------------------------
    always @(*)
    begin
        ddr_araddr  = ar_owner ? s1_araddr : s0_araddr;
        ddr_arlen   = ar_owner ? s1_arlen  : s0_arlen;
        ddr_arvalid = busy_ar;
    end

    //------------------------------------------------------------------
    // routing to ports
    //------------------------------------------------------------------
    wire rvalid0 = ddr_rvalid && !fifo_empty && !cur_owner;
    wire rvalid1 = ddr_rvalid && !fifo_empty &&  cur_owner;

    assign s0_arready = busy_ar && !ar_owner && ddr_arready;
    assign s1_arready = busy_ar &&  ar_owner && ddr_arready;

    assign s0_rdata   = ddr_rdata;
    assign s0_rlast   = ddr_rlast && rvalid0;
    assign s0_rvalid  = rvalid0;

    assign s1_rdata   = ddr_rdata;
    assign s1_rlast   = ddr_rlast && rvalid1;
    assign s1_rvalid  = rvalid1;

endmodule
