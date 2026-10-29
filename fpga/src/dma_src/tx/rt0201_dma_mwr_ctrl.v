

//////////////////////////////////////////////////////////////////////////////
module rt0201_dma_mwr_ctrl 
(
    input                               clk                     ,   //gen1:62.5MHz,gen2:125MHz
    input                               rst_n                   ,
    input           [7:0]               i_cfg_pbus_num          ,
    input           [4:0]               i_cfg_pbus_dev_num      ,
    input           [2:0]               i_cfg_max_payload_size  ,
    //**********************************************************************
	//axis_slave interface
    input                               i_axis_slave2_trdy      ,
    input                               i_axis_slave2_tvld      ,
    input                               i_axis_slave2_tlast     ,  
	//
    input                               i_mwr32_req             ,
    input                               i_mwr64_req             ,
    output  reg                         o_mwr32_req_ack         ,
    output  reg                         o_mwr64_req_ack         ,

    input           [10:0]              i_mem_length            ,
    input           [63:0]              i_mem_addr              ,
    input           [19:0]              i_mwr_ext_length        ,   // 20261018 ext:
    //**********************************************************************
	output                              o_mwr_req_cmd	        ,  //mwr写指令来后，需要去开始读16in_16out_ram
	input                               i_mwr_tx_start          ,  //这个信号表示数据已经搬到16in_128out ram.可以开始mwr组包
    //
    output  reg                         o_rd_en                 ,
    output  wire    [9:0]               o_rd_length             ,
	output  reg                         o_mwr_tx_busy           ,
    output  wire                        o_mwr_tx_hold           ,
    // output  wire                        o_mwr_tlp_tx            ,

    input                               i_data_valid            ,
    input           [127:0]             i_data                  ,
    input                               i_last_data_en          ,
	output  wire                        o_data_valid            ,
    output  wire    [127:0]             o_data                  ,
    output  wire                        o_last_data_en          ,

	//tlp
    output  wire    [9:0]               o_mwr_length            ,
    output  wire    [1:0]               o_mwr_at                ,
    output  wire    [2:0]               o_mwr_attr              ,
    output  wire                        o_mwr_ep                ,
    output  wire                        o_mwr_td                ,
    output  wire                        o_mwr_th                ,
    output  wire    [2:0]               o_mwr_tc                ,
    output  wire    [4:0]               o_mwr_tlp_type          ,
    output  wire    [2:0]               o_mwr_fmt               ,
    output  wire    [7:0]               o_mwr_dwbe              ,
    output  reg     [7:0]               o_mwr_tag               ,
    output  wire    [15:0]              o_mwr_requester_id      ,
    output  reg     [63:0]              o_mwr_addr                    
);

assign o_data_valid   = i_data_valid  ;
assign o_data         = i_data        ;
assign o_last_data_en = i_last_data_en;


localparam      IDLE        = 2'd0;
localparam      HEADER_TX   = 2'd1;
localparam      DATA_TX     = 2'd2;

wire            mwr_req_de;   
reg     [19:0]  mwr_length;   // 20261018 ext: 11->20bit

reg             mwr32_req_tx;
reg             mwr64_req_tx;

reg     [1:0]   current_state;
reg     [1:0]   next_state;

wire            mwr_req_rcv;

wire    [3:0]   first_dwbe;
wire    [3:0]   last_dwbe;

wire            mwr_req_ack;

wire            tx_done;

wire [9:0]      max_payload_size;

assign o_mwr_tx_hold  = ~i_axis_slave2_trdy && i_axis_slave2_tvld;

assign mwr_req_rcv = i_mwr32_req || i_mwr64_req;
assign mwr_req_ack = o_mwr32_req_ack || o_mwr64_req_ack;

assign tx_done  = i_axis_slave2_tlast && i_axis_slave2_trdy && i_axis_slave2_tvld;
assign o_mwr_req_cmd = mwr_req_rcv && mwr_req_ack;
assign mwr_req_de = i_mwr_tx_start;


assign max_payload_size = (i_cfg_max_payload_size == 3'd0) ? 10'h20 :
                          (i_cfg_max_payload_size == 3'd1) ? 10'h40 :
                          (i_cfg_max_payload_size == 3'd2) ? 10'h80 :
                          (i_cfg_max_payload_size == 3'd3) ? 10'h100 : 10'd20;


//get tlp information
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        mwr_length <= 'd0;
    else if(mwr_req_de && !o_mwr_tx_busy)
        mwr_length <= (i_mwr_ext_length != 20'd0) ? i_mwr_ext_length : {9'd0, i_mem_length};  // 20261018 ext:
    else if(mwr_length >  {10'd0, max_payload_size} && current_state == HEADER_TX && !o_mwr_tx_hold) 
        mwr_length <= mwr_length - {10'd0, max_payload_size};   // 20261018 ext:
    else if(mwr_length <= {10'd0, max_payload_size} && current_state == HEADER_TX && !o_mwr_tx_hold)   // 20261018 ext:
        mwr_length <= 'd0;
end

//one TLP the true length to be transmitted
assign o_mwr_length = (mwr_length > {10'd0, max_payload_size}) ? max_payload_size : mwr_length[9:0];  // 20261018 ext:

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        o_mwr_addr <= 64'd0;
    else if(mwr_req_de && !o_mwr_tx_busy)
        o_mwr_addr <= i_mem_addr;
    else if(|mwr_length && tx_done)
        o_mwr_addr <= o_mwr_addr + {52'b0,max_payload_size,2'b0};
end


//rd flag
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        o_rd_en <= 1'b0;
    else if(tx_done)
        o_rd_en <= 1'b0;
    else if(|mwr_length)
        o_rd_en <= 1'b1;
end

assign o_rd_length = o_mwr_length;



//
reg mwr32_req_flag;
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        mwr32_req_flag <= 1'b0;
    else if(i_mwr_tx_start)
        mwr32_req_flag <= 1'b0;
    else if(i_mwr32_req && o_mwr32_req_ack)
        mwr32_req_flag <= 1'b1;
	else 
        mwr32_req_flag <= mwr32_req_flag;	    
end

reg mwr64_req_flag;
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        mwr64_req_flag <= 1'b0;
    else if(i_mwr_tx_start)
        mwr64_req_flag <= 1'b0;
    else if(i_mwr64_req && o_mwr64_req_ack)
        mwr64_req_flag <= 1'b1;
	else 
        mwr64_req_flag <= mwr64_req_flag;	    
end

//

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        mwr32_req_tx <= 1'b0;
    else if(tx_done && ~(|mwr_length))
        mwr32_req_tx <= 1'b0;
    else if(mwr_req_de && mwr32_req_flag)
        mwr32_req_tx <= 1'b1;
	else 
        mwr32_req_tx <= mwr32_req_tx;	    
end
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        mwr64_req_tx <= 1'b0;
    else if(tx_done && ~(|mwr_length))
        mwr64_req_tx <= 1'b0;
    else if(mwr_req_de && mwr64_req_flag)
        mwr64_req_tx <= 1'b1;
    else
        mwr64_req_tx <= mwr64_req_tx;	    
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        o_mwr_tag <= 8'b0;
    else if(tx_done)
        o_mwr_tag <= o_mwr_tag + 8'b1;
end

//tlp header
assign o_mwr_requester_id = {i_cfg_pbus_num,i_cfg_pbus_dev_num,3'b0};
assign {o_mwr_fmt,o_mwr_tlp_type} = mwr32_req_tx ? 8'h40
                                    : mwr64_req_tx ? 8'h60 : 8'h40;
assign o_mwr_tc    = 3'b0;
assign o_mwr_attr  = 3'b0;
assign {o_mwr_th,o_mwr_td,o_mwr_ep,o_mwr_at} = 5'b0;
assign first_dwbe  = 4'hf;
assign last_dwbe   = o_mwr_length == 10'h1 ? 4'h0 : 4'hf;
assign o_mwr_dwbe  = {last_dwbe,first_dwbe};

//mwr_tx
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        current_state <= IDLE;
    else
        current_state <= next_state;
end

always @(*)
begin
    case(current_state)
        IDLE:
        begin
            if( i_data_valid && i_axis_slave2_trdy) //start transmit
                next_state = HEADER_TX;
            else
                next_state = IDLE;
        end
        HEADER_TX:
        begin
            if(i_axis_slave2_trdy)
                next_state = DATA_TX;
            else
                next_state = current_state;
        end
        DATA_TX:
        begin
            if(i_last_data_en && (!o_mwr_tx_hold))//transmit end
                next_state = IDLE;
            else
                next_state = current_state;
        end
        default:
        begin
            next_state = IDLE;
        end
    endcase
end


always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        o_mwr_tx_busy <= 1'b0;
    else if(~(|mwr_length) && tx_done)
        o_mwr_tx_busy <= 1'b0;
    else if(mwr_req_de)
        o_mwr_tx_busy <= 1'b1;
end

//ack
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        o_mwr32_req_ack <= 1'b0;
    else if(!i_mwr32_req)
        o_mwr32_req_ack <= 1'b0;
    else if(i_mwr32_req && !o_mwr_tx_busy)
        o_mwr32_req_ack <= 1'b1;
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        o_mwr64_req_ack <= 1'b0;
    else if(!i_mwr64_req)
        o_mwr64_req_ack <= 1'b0;
    else if(i_mwr64_req && !o_mwr_tx_busy)
        o_mwr64_req_ack <= 1'b1;
end

endmodule
