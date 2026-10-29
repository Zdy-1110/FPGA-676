`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: Myminieye
// Engineer: Nill
// 
// Create Date: 2019-09-16 19:46
// Design Name: 
// Module Name: ms7210_ctl
// Project Name: hdmi_tx
// Target Devices: Pg2l100H  
// Tool Versions: 
// Description:  
// 
// Dependencies: 
// Revision: v1.0
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

`define UD #1
module ms72xx_ctl #(parameter [21:0] MS7210_WAIT_CNT = 22'h30D399)(
    input       clk,
    input       rst_n,
    
    output      init_over_rx,
    output      init_over,
    output      iic_scl,
    inout       iic_sda,

    input       rx_en,          // 20261028: pclk_div2 domain rx_en (async)
    // 20261019 osd1d: host MS7210 re-init request / status snapshot
    input       reinit_tgl,     // pclk_div2 domain toggle (async)
    output reg  stat_tgl = 1'b0,// cfg_clk domain toggle
    output reg  [31:0] stat_bus = 32'd0  // cfg_clk domain status snapshot
);
    reg rstn_temp1,rstn_temp2;
    reg rstn;
    always @(posedge clk or negedge rst_n)
    begin
    	if(!rst_n)
    	    rstn_temp1 <= 1'b0;
    	else
    	    rstn_temp1 <= rst_n;
    end
    
    always @(posedge clk)
    begin
    	rstn_temp2 <= rstn_temp1;
    	rstn <= rstn_temp2;
    end
    
    wire         init_over_rx;
    wire   [7:0] device_id_rx;
    wire         iic_trig_rx ;
    wire         w_r_rx      ;
    wire  [15:0] addr_rx     ;
    wire  [ 7:0] data_in_rx  ;
    wire         busy_rx     ;
    wire  [ 7:0] data_out_rx ;
    wire         byte_over_rx;
    
    wire   [7:0] device_id_tx;
    wire         iic_trig_tx ;
    wire         w_r_tx      ;
    wire  [15:0] addr_tx     ;
    wire  [ 7:0] data_in_tx  ;
    wire         busy_tx     ;
    wire  [ 7:0] data_out_tx ;
    wire         byte_over_tx;
    
    wire   [7:0] device_id   ;
    wire         iic_trig    ;
    wire         w_r         ;
    wire  [15:0] addr        /*synthesis PAP_MARK_DEBUG="true"*/;
    wire  [ 7:0] data_in     ;
    wire         busy        ;
    wire  [ 7:0] data_out    /*synthesis PAP_MARK_DEBUG="true"*/;
    wire         byte_over   /*synthesis PAP_MARK_DEBUG="true"*/;
    wire   [5:0] tx_state;
    wire         ack_err;

    // 20261028: rx_en from rt_ext_regs (pclk_div2 domain), 2-stage synchronizer
    reg [1:0] rx_en_sync = 2'b00;
    always @(posedge clk) rx_en_sync <= {rx_en_sync[0], rx_en};
    wire rx_en_synced = rx_en_sync[1];

    // 20261019 osd1d: host re-init request. reinit_tgl comes from rt_ext_regs (pclk_div2).
    // No reset on the synchroniser on purpose: a reset must never create a fake edge.
    reg [2:0] ri_sync = 3'b000;
    always @(posedge clk) ri_sync <= {ri_sync[1:0], reinit_tgl};
    wire reinit_req = ri_sync[2] ^ ri_sync[1];

    // RUN -> HOLD (mask every I2C trigger) -> wait 32 consecutive idle cycles (busy==0)
    // -> RST 16 cycles (ms7210_ctl reset, rx_go=0 holds MS7200 in reset, stats cleared) -> RUN.
    localparam RI_RUN = 2'd0, RI_HOLD = 2'd1, RI_RST = 2'd2;
    reg [1:0] ri_st;
    reg [4:0] ri_idle;
    reg [3:0] ri_rcnt;
    reg [3:0] reinit_cnt;
    reg [1:0] auto_retry_cnt;
    wire ri_hold = (ri_st != RI_RUN);
    wire ri_rst  = (ri_st == RI_RST);

    reg       nack_sticky;
    reg       sta_valid;

    // rx_en is sampled and latched only when MS7210 (re-)config starts.
    // Changing rx_en in flight must not cut bus during MS7200 transactions.
    reg rx_en_latched = 1'b0;
    always @(posedge clk) begin
        if (!rstn)
            rx_en_latched <= 1'b0;      // default rx_en=0 on reset
        else if (ri_rst)
            rx_en_latched <= rx_en_synced;
    end

    // Auto-reinit when MS7210 config (+ 0x0502 read) ends with NACK and budget < 3
    wire auto_reinit_req = (ri_st == RI_RUN) && init_over && sta_valid && nack_sticky && (auto_retry_cnt < 2'd3) && !busy;

    always @(posedge clk)
    begin
        if (!rstn) begin
            ri_st <= RI_RUN; ri_idle <= 5'd0; ri_rcnt <= 4'd0; reinit_cnt <= 4'd0;
            auto_retry_cnt <= 2'd0;
        end else begin
            case (ri_st)
                RI_RUN : begin
                    if (reinit_req) begin
                        ri_st <= RI_HOLD; ri_idle <= 5'd0;
                        auto_retry_cnt <= 2'd0; // manual 0x834 bit0 resets auto-retry budget
                    end else if (auto_reinit_req) begin
                        ri_st <= RI_HOLD; ri_idle <= 5'd0;
                        auto_retry_cnt <= auto_retry_cnt + 2'd1;
                    end
                end
                RI_HOLD: if (busy) ri_idle <= 5'd0;
                         else if (ri_idle == 5'd31) begin
                             ri_st <= RI_RST; ri_rcnt <= 4'd0; reinit_cnt <= reinit_cnt + 4'd1;
                         end else ri_idle <= ri_idle + 5'd1;
                RI_RST : if (ri_rcnt == 4'd15) ri_st <= RI_RUN; else ri_rcnt <= ri_rcnt + 4'd1;
                default: ri_st <= RI_RUN;
            endcase
        end
    end

    // 20261018 fix: MS7210 first, MS7200 after the bus has been idle ~6.5 ms.
    // 20261028: rx_en=0 disables rx_go completely; MS7200 stays in reset, bus stays idle.
    reg [15:0] ho_cnt;
    reg        rx_go;
    always @(posedge clk)
    begin
        if (!rstn || ri_rst) begin
            ho_cnt <= 16'd0; rx_go <= 1'b0;
        end else if (rx_en_latched && init_over && !rx_go) begin
            if (busy) ho_cnt <= 16'd0;
            else begin ho_cnt <= ho_cnt + 16'd1; if (&ho_cnt) rx_go <= 1'b1; end
        end
    end

    // 20261019 osd1d: NACK statistics for MS7210-owned transactions + last 0x0502 readback.
    reg busy_q;
    always @(posedge clk) busy_q <= busy;
    wire busy_fall = busy_q & ~busy;
    reg [7:0] nack_cnt;
    reg [7:0] sta_0502;
    always @(posedge clk)
    begin
        if (!rstn || ri_rst) begin
            nack_cnt <= 8'd0; nack_sticky <= 1'b0; sta_0502 <= 8'd0; sta_valid <= 1'b0;
        end else if (busy_fall && !rx_go) begin
            if (ack_err) begin
                nack_sticky <= 1'b1;
                if (nack_cnt != 8'hFF) nack_cnt <= nack_cnt + 8'd1;
            end
            if (tx_state == 6'b10_0000) begin   // STA_RD: the single 0x0502 read
                sta_0502 <= data_out; sta_valid <= 1'b1;
            end
        end
    end

    wire [31:0] stat_w = { sta_0502, nack_cnt, init_over_rx, sta_valid, tx_state,
                           reinit_cnt, ri_hold, rx_go, nack_sticky, init_over };
    reg [3:0] st_div = 4'd0;
    always @(posedge clk)
    begin
        st_div <= st_div + 4'd1;
        if (st_div == 4'd0) stat_bus <= stat_w;
        if (st_div == 4'd8) stat_tgl <= ~stat_tgl;
    end

    ms7200_ctl U1_ms7200_ctl(
        .clk             (  clk           ),//input
        .rstn            (  rx_go         ),//input   20261018 fix: was rstn
                              
        .init_over       (  init_over_rx  ),//output reg          
        .device_id       (                ),//output        [7:0] 
        .iic_trig        (  iic_trig_rx   ),//output reg          
        .w_r             (  w_r_rx        ),//output reg          
        .addr            (  addr_rx       ),//output reg   [15:0] 
        .data_in         (  data_in_rx    ),//output reg   [ 7:0] 
        .busy            (  busy_rx       ),//input               
        .data_out        (  data_out_rx   ),//input        [ 7:0] 
        .byte_over       (  byte_over_rx  ) //input               
    );
    
    ms7210_ctl #(
        .WAIT_CNT        (  MS7210_WAIT_CNT )
    ) U2_ms7210_ctl(
        .clk             (  clk           ),//input               
        .rstn            (  rstn & ~ri_rst),//input   20261018 fix: was init_over_rx; 20261019: re-init reset
                              
        .init_over       (  init_over     ),//output reg          
        .device_id       (                ),//output        [7:0] 
        .iic_trig        (  iic_trig_tx   ),//output reg          
        .w_r             (  w_r_tx        ),//output reg          
        .addr            (  addr_tx       ),//output reg   [15:0] 
        .data_in         (  data_in_tx    ),//output reg   [ 7:0] 
        .busy            (  busy_tx       ),//input               
        .data_out        (  data_out_tx   ),//input        [ 7:0] 
        .byte_over       (  byte_over_tx  ),//input               
        .fsm_state       (  tx_state      ) //output       [ 5:0]  20261019 osd1d: for NACK stats
    );
    
    // 20261018 fix: bus owner = MS7210 until rx_go, then MS7200; MS7210 triggers after init_over are dropped
    assign device_id = rx_go ? 8'h56 : 8'hB2;
    assign iic_trig = ri_hold ? 1'b0 : (rx_go ? iic_trig_rx : (iic_trig_tx & ~init_over));
    assign w_r = rx_go ? w_r_rx : w_r_tx;
    assign addr = rx_go ? addr_rx : addr_tx;
    assign data_in = rx_go ? data_in_rx : data_in_tx;
    assign busy_tx = rx_go ? 1'b0 : busy;
    assign data_out_tx = rx_go ? 8'd0 : data_out;
    assign byte_over_tx = rx_go ? 1'b0 : byte_over;

    assign busy_rx = rx_go ? busy : 1'b0;
    assign data_out_rx = rx_go ? data_out : 8'd0;
    assign byte_over_rx = rx_go ? byte_over : 1'b0;

    wire         sda_in/*synthesis PAP_MARK_DEBUG="true"*/;
    wire         sda_out/*synthesis PAP_MARK_DEBUG="true"*/;
    wire         sda_out_en/*synthesis PAP_MARK_DEBUG="true"*/;  
    iic_dri #(
        .CLK_FRE        (  27'd10_000_000  ),//parameter            CLK_FRE   = 27'd50_000_000,//system clock frequency
        .IIC_FREQ       (  20'd400_000     ),//parameter            IIC_FREQ  = 20'd400_000,   //I2c clock frequency
        .T_WR           (  10'd1           ),//parameter            T_WR      = 10'd5,         //I2c transmit delay ms
        .ADDR_BYTE      (  2'd2            ),//parameter            ADDR_BYTE = 2'd1,          //I2C addr byte number
        .LEN_WIDTH      (  8'd3            ),//parameter            LEN_WIDTH = 8'd3,          //I2C transmit byte width
        .DATA_BYTE      (  2'd1            ) //parameter            DATA_BYTE = 2'd1           //I2C data byte number
    )iic_dri(                       
        .clk            (  clk             ),//input                clk,
        // iic_dri must never be soft-reset: busy/trans_en/twr_* have no reset, a mid-transaction
        // reset would hang the bus. Only MS7210's controller is reset by ri_rst.
        .rstn           (  rstn            ),//input                rstn,
        .device_id      (  device_id       ),//input                device_id,
        .pluse          (  iic_trig        ),//input                pluse,                     //I2C transmit trigger
        .w_r            (  w_r             ),//input                w_r,                       //I2C transmit direction 1:send  0:receive
        .byte_len       (  4'd1            ),//input  [LEN_WIDTH:0] byte_len,                  //I2C transmit data byte length of once trigger
                   
        .addr           (  addr            ),//input  [7:0]         addr,                      //I2C transmit addr
        .data_in        (  data_in         ),//input  [7:0]         data_in,                   //I2C send data
                     
        .busy           (  busy            ),//output reg           busy=0,                    //I2C bus status
        
        .byte_over      (  byte_over       ),//output reg           byte_over=0,               //I2C byte transmit over flag               
        .data_out       (  data_out        ),//output reg[7:0]      data_out,                  //I2C receive data
                                           
        .scl            (  iic_scl         ),//output               scl,
        .sda_in         (  sda_in          ),//input                sda_in,
        .sda_out        (  sda_out         ),//output   reg         sda_out=1'b1,
        .sda_out_en     (  sda_out_en      ),//output               sda_out_en
        .ack_err        (  ack_err         ) //output reg           ack_err  20261019 osd1d
    );
    
    assign iic_sda = sda_out_en ? sda_out : 1'bz;
    assign sda_in = iic_sda;
    
endmodule
