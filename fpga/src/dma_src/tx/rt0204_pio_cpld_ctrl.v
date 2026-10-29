
module rt0204_pio_cpld_ctrl (
    input                               clk                     ,   //gen1:62.5MHz,gen2:125MHz
    input                               rst_n                   ,
    input           [7:0]               i_cfg_pbus_num          ,
    input           [4:0]               i_cfg_pbus_dev_num      ,
    input           [2:0]               i_cfg_max_payload_size  ,
    //**********************************************************************
    input                               i_axis_slave0_trdy      ,
    input                               i_axis_slave0_tvld      ,	
    input                               i_axis_slave0_tlast     ,
	
    input           [2:0]               i_bar_sel               ,
    input           [2:0]               i_mrd_tc                ,
    input           [2:0]               i_mrd_attr              ,
    input           [9:0]               i_mrd_length            ,
    input           [15:0]              i_mrd_id                ,
    input           [7:0]               i_mrd_tag               ,
    input           [63:0]              i_mrd_addr              ,

    input                               i_cpld_req_vld          ,
    output  wire                        o_cpld_req_rdy          ,
    //**********************************************************************
    //ram interface
    output  reg                         o_rd_en                 ,
    output  wire    [9:0]               o_rd_length             ,
    output  wire    [63:0]              o_rd_addr               ,
    output  wire                        o_cpld_tx_hold          ,

    input                               i_data_valid            ,
    input           [127:0]             i_data                  ,
    input                               i_last_data_en          ,
	output  wire                        o_data_valid            ,
    output  wire    [127:0]             o_data                  ,
    output  wire                        o_last_data_en          ,	
    //**********************************************************************
    output reg      [2:0]               o_bar_sel               ,
	
    output wire     [9:0]               o_cpld_length           ,
    output wire     [1:0]               o_cpld_at               ,
    output wire     [2:0]               o_cpld_attr             ,
    output wire                         o_cpld_ep               ,
    output wire                         o_cpld_td               ,
    output wire                         o_cpld_th               ,
    output wire     [2:0]               o_cpld_tc               ,
    output wire     [4:0]               o_cpld_tlp_type         ,
    output wire     [2:0]               o_cpld_fmt              ,
	
    output wire     [11:0]              o_cpld_byte_cnt         ,	
    output wire                         o_cpld_bcm              ,
    output wire     [2:0]               o_cpld_compl_status     ,
    output wire     [15:0]              o_cpld_completer_id     ,
    output wire     [6:0]               o_cpld_low_addr         ,
    output wire     [7:0]               o_cpld_tag              ,
    output wire     [15:0]              o_cpld_requester_id      

);


assign o_data_valid   = i_data_valid  ;
assign o_data         = i_data        ;
assign o_last_data_en = i_last_data_en;


localparam      IDLE        = 2'd0;
localparam      HEADER_TX   = 2'd1;
localparam      DATA_TX     = 2'd2;

localparam      FIFO_DEEP   = 7'd64;    //should be 2^N  real_deep = deep < 16 ? 16 : deep;

reg     [9:0]   cpld_length;
wire    [9:0]   cpld_length_tx;
reg     [7:0]   cpld_tag;
reg     [63:0]  cpld_addr;
reg     [15:0]  cpld_req_id;
reg     [2:0]   cpld_tc;
reg     [2:0]   cpld_attr;

reg             is_first_cpl;
reg     [9:0]   first_cpl_offset;
wire            first_cpl_offset_calcu_done;

wire            rd_en;

reg     [1:0]   state;
reg     [1:0]   next_state;

reg             tx_busy;
wire            tx_done;

wire    [106:0] data_in;
wire    [106:0] data_out;
wire            fifo_data_in;
wire            fifo_data_out;
wire            data_in_valid;
wire            data_in_ready;
wire            data_out_valid;
reg     [6:0]   fifo_data_cnt;

wire [9:0]      max_payload_size;

assign max_payload_size = (i_cfg_max_payload_size == 3'd0) ? 10'h20 :           //dw
                          (i_cfg_max_payload_size == 3'd1) ? 10'h40 :
                          (i_cfg_max_payload_size == 3'd2) ? 10'h80 :
                          (i_cfg_max_payload_size == 3'd3) ? 10'h100 : 10'd20;

//reg             cpld_req_ff;

assign data_in = {i_bar_sel,   //106:104
                  i_mrd_tc,     //103:101
                  i_mrd_attr,   //100:98
                  i_mrd_length, //97:88
                  i_mrd_id,     //87:72
                  i_mrd_tag,    //71:64
                  i_mrd_addr};  //63:0

assign data_in_valid = i_cpld_req_vld;

assign o_cpld_req_rdy = data_in_ready;

//cpld_req buff
    pgs_pciex4_prefetch_fifo_v1_2
    #(
        .D              (FIFO_DEEP      ),  //should be 2^N
        .W              (107            )
     )
    u_cpld_req_fifo
    (
    .clk                (clk            ),
    .rst_n              (rst_n          ),

    .data_in_valid      (data_in_valid  ),
    .data_in            (data_in        ),
    .data_in_ready      (data_in_ready  ),

    .data_out_ready     (~tx_busy       ),
    .data_out           (data_out       ),
    .data_out_valid     (data_out_valid )
    );

assign fifo_data_in  = data_in_valid  && data_in_ready ;
assign fifo_data_out = ~tx_busy && data_out_valid;

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        fifo_data_cnt <= 7'b0;
    else if(fifo_data_in && fifo_data_out)
        fifo_data_cnt <= fifo_data_cnt;
    else if(fifo_data_in)
        fifo_data_cnt <= fifo_data_cnt + 7'h1;
    else if(fifo_data_out)
        fifo_data_cnt <= fifo_data_cnt - 7'h1;
end

//for o_trgt1_radm_pkt_halt[1] :Halt non-posted TLPs for VC0,MRD
wire o_cpld_tx_rdy;
assign o_cpld_tx_rdy = (fifo_data_cnt >= FIFO_DEEP- 7'd10 ) ? 1'b0 : 1'b1 ;

//******************************************************************get mrd information************************************************************************
// current mult-completion address equals to:
// 1. for the first completion, address equals to MRD address
// 2. for the other comoletion(if have), address from last mult-completion's address added last mult-completion's length
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        cpld_addr <= 64'd0;
    else if(fifo_data_out)
        cpld_addr <= data_out[63:0];
    else if(|cpld_length && state == HEADER_TX && !o_cpld_tx_hold)
        cpld_addr <= cpld_addr + {52'b0,cpld_length_tx,2'b0};
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        cpld_tag <= 8'd0;
    else if(fifo_data_out)
        cpld_tag <= data_out[71:64];
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        cpld_req_id <= 16'd0;
    else if(fifo_data_out)
        cpld_req_id <= data_out[87:72];
end


always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        cpld_length <= 10'd0;
    else if(fifo_data_out)
        cpld_length <= data_out[97:88];
    else if(state == HEADER_TX  && !o_cpld_tx_hold)
        cpld_length <= cpld_length - cpld_length_tx;
end

//multicpld: first completion
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        is_first_cpl <= 1'b0;
    else if(tx_done)
        is_first_cpl <= 1'b0;
    else if(fifo_data_out)
        is_first_cpl <= 1'b1;
end

//multicpld: for rcb first_completion_length = max_payload_size - first_cpl_offset
//first_cpl_offset need <= max_payload_size
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        first_cpl_offset <= 10'b0;
    else if(fifo_data_out)
        first_cpl_offset <= data_out[11:2];
    else if (first_cpl_offset >= max_payload_size)
        first_cpl_offset <= first_cpl_offset - max_payload_size;
end

assign first_cpl_offset_calcu_done = first_cpl_offset < max_payload_size;

//the true length to be transmitted
assign cpld_length_tx = (cpld_length <= max_payload_size) ? cpld_length :
                        (is_first_cpl && first_cpl_offset_calcu_done) ? (max_payload_size - first_cpl_offset) : max_payload_size ;

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        cpld_attr <= 3'd0;
    else if(fifo_data_out)
        cpld_attr <= data_out[100:98];
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        cpld_tc <= 3'd0;
    else if(fifo_data_out)
        cpld_tc <= data_out[103:101];
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        o_bar_sel <= 3'd0;
    else if(fifo_data_out)
        o_bar_sel <= data_out[106:104];
end

//gen tx busy
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        tx_busy <= 1'b0;
    else if(tx_done && ~(|cpld_length))
        tx_busy <= 1'b0;
    else if(fifo_data_out)
        tx_busy <= 1'b1;
end

assign rd_en = is_first_cpl ? ((cpld_length <= max_payload_size) ? |cpld_length : first_cpl_offset_calcu_done ) :  |cpld_length;

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        o_rd_en <= 1'b0;
    else if(tx_done)
        o_rd_en <= 1'b0;
    else if(rd_en)
        o_rd_en <= 1'b1;
end 

assign o_rd_length = cpld_length_tx;
assign o_rd_addr   = cpld_addr;

//first DW
assign o_cpld_length    = cpld_length_tx;
assign {o_cpld_fmt,o_cpld_tlp_type}   = 8'h4a;
assign {o_cpld_th,o_cpld_td,o_cpld_ep,o_cpld_at}    = 5'b0;
assign o_cpld_tc               = cpld_tc;
assign o_cpld_attr             = cpld_attr;
//second DW
assign o_cpld_completer_id      = {i_cfg_pbus_num,i_cfg_pbus_dev_num,3'b0};
assign o_cpld_compl_status     = 3'b0;
assign o_cpld_bcm              = 1'b0;
assign o_cpld_byte_cnt         = {cpld_length,2'b0};
//third DW
assign o_cpld_low_addr         = is_first_cpl ? {cpld_addr[6:2],2'b0} : 7'b0;
assign o_cpld_tag              = cpld_tag;
assign o_cpld_requester_id     = cpld_req_id;


//mwr_tx
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        state <= IDLE;
    else
        state <= next_state;
end

always @(*)
begin
    case(state)
        IDLE:
        begin
            if(i_data_valid && i_axis_slave0_trdy) //start transmit
                next_state = HEADER_TX;
            else
                next_state = IDLE;
        end
        HEADER_TX:
        begin
            if(i_axis_slave0_trdy)
                next_state = DATA_TX;
            else
                next_state = state;
        end
        DATA_TX:
        begin
            if(i_last_data_en && !o_cpld_tx_hold)//transmit end
                next_state = IDLE;
            else
                next_state = state;
        end
        default:
        begin
            next_state = IDLE;
        end
    endcase
end



assign tx_done = i_axis_slave0_trdy && i_axis_slave0_tvld && i_axis_slave0_tlast;

assign o_cpld_tx_hold = ~i_axis_slave0_trdy && i_axis_slave0_tvld;


endmodule
