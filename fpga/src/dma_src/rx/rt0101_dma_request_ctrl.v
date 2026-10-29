

//////////////////////////////////////////////////////////////////////////////
module rt0101_dma_request_ctrl
(
    input                       clk                     ,   //gen1:62.5MHz,gen2:125MHz
    input                       rst_n                   ,

	input                       i_mwr_req_en            ,  	//mwr_en 数据使能
    input         [63:0]        i_tlp_req_addr          ,
    input         [127:0]       i_mwr_req_data          ,
    input         [3:0]         i_tlp_req_dwbe          ,  
	input         [2:0]         i_bar_sel               ,	

    //**********************************************************************
	////////to tx engine mwr and mrd
	input                       i_mwr32_req_ack         , 
	input                       i_mwr64_req_ack         , 
	input                       i_mrd32_req_ack         , 
	input                       i_mrd64_req_ack         , 
	output   reg                o_mwr32_req             ,   
	output   reg                o_mwr64_req             , 
	output   reg                o_mrd32_req             , 
	output   reg                o_mrd64_req             , 
	//mem addr	
	output   reg  [10:0]        o_mem_length            , 
	output   reg  [63:0]        o_mem_addr              ,
	// 20261018 ext: MWr扩展长度寄存器输出(0=保持原4KB行为)
	output  wire    [19:0]      o_mwr_ext_length        ,
	// 20261018 mrd: MRd扩展控制
	output  wire    [19:0]      o_mrd_ext_length        ,   // 20261018 mrd:
	output  wire    [5:0]       o_mrd_max_out           ,   // 20261018 mrd:
	output  wire    [31:0]      o_chk_seed              ,   // 20261018 mrd:
	output  wire                o_mrd_abort             ,   // 20261018 mrd:
	// 20261018 ddr: BAR1 write tap to DDR doorbell hub
	output  wire                o_bar1_tap_vld          ,
	output  wire    [11:0]      o_bar1_tap_addr         ,
	output  wire    [31:0]      o_bar1_tap_data         ,
	//ram addr
	output   reg [31:0]         o_mwr_ram_addr          ,  //存储器写操作。从这个地址读取ram_16in_16out
	output   reg [31:0]         o_mrd_ram_addr               //存储器读操作。接收CplD数据，写入ram_16in_16out       

);

reg               bar1_wr_en      /* synthesis PAP_MARK_DEBUG=”true”*/;
reg     [11:0]    bar1_wr_addr    /* synthesis PAP_MARK_DEBUG=”true”*/;
reg     [127:0]   bar1_wr_data    ;
reg     [15:0]    bar1_wr_byte_en /* synthesis PAP_MARK_DEBUG=”true”*/;
always@(*)
begin
    if(i_bar_sel == 3'b1)           
    begin
        bar1_wr_en       = i_mwr_req_en;    
        bar1_wr_addr     = i_tlp_req_addr[11:0];
        bar1_wr_data     = i_mwr_req_data;
        bar1_wr_byte_en  = {{4{i_tlp_req_dwbe[3]}},{4{i_tlp_req_dwbe[2]}},{4{i_tlp_req_dwbe[1]}},{4{i_tlp_req_dwbe[0]}}};
    end
    else
    begin
        bar1_wr_en       = 1'b0;
        bar1_wr_addr     = 12'b0;
        bar1_wr_data     = 128'b0;
        bar1_wr_byte_en  = 16'b0;
    end
end

reg     [31:0]      bar1_wr_data_d1/* synthesis PAP_MARK_DEBUG=”true”*/;
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        bar1_wr_data_d1 <= 32'b0;
    else
        bar1_wr_data_d1 <= bar1_wr_data[31:0];
end

// 20261018 ddr: BAR1 write tap for DDR doorbell hub
reg                 tap_vld;    // 20261018 ddr:
reg     [11:0]      tap_addr;   // 20261018 ddr:
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
    begin
        tap_vld  <= 1'b0;   // 20261018 ddr:
        tap_addr <= 12'b0;  // 20261018 ddr:
    end
    else
    begin
        tap_vld  <= &bar1_wr_byte_en && bar1_wr_en;   // 20261018 ddr:
        tap_addr <= bar1_wr_addr;                     // 20261018 ddr:
    end
end

assign o_bar1_tap_vld  = tap_vld;             // 20261018 ddr:
assign o_bar1_tap_addr = tap_addr;            // 20261018 ddr:
assign o_bar1_tap_data = bar1_wr_data_d1;     // 20261018 ddr:

wire ack_rcv;
assign ack_rcv = i_mwr32_req_ack | i_mwr64_req_ack | i_mrd32_req_ack | i_mrd64_req_ack;


//**************************************************rd
//*******rd l_addr

reg rd_l_addr_en;
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        rd_l_addr_en <= 1'b0;
    else if(rd_l_addr_en)
        rd_l_addr_en <= 1'b0;
    else
        rd_l_addr_en <= &bar1_wr_byte_en && bar1_wr_en && ((bar1_wr_addr[8:0] == 9'h100) && !bar1_wr_addr[11]);
end

reg [31:0] rd_l_addr;
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        rd_l_addr <= 32'd0;
    else if(rd_l_addr_en)
        rd_l_addr <= bar1_wr_data_d1;
end

//******rd h_addr
reg rd_h_addr_en;
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        rd_h_addr_en <= 1'b0;
    else if(rd_h_addr_en)
        rd_h_addr_en <= 1'b0;
    else
        rd_h_addr_en <= &bar1_wr_byte_en && bar1_wr_en && ((bar1_wr_addr[8:0] == 9'h104) && !bar1_wr_addr[11]);
end

reg [31:0] rd_h_addr;
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        rd_h_addr <= 32'd0;
    else if(rd_h_addr_en)
        rd_h_addr <= bar1_wr_data_d1;
end

//******rd ram addr
reg mrd_ram_addr_en/* synthesis PAP_MARK_DEBUG=”true”*/;
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        mrd_ram_addr_en <= 1'b0;
    else if(mrd_ram_addr_en)
        mrd_ram_addr_en <= 1'b0;
    else
        mrd_ram_addr_en <= &bar1_wr_byte_en && bar1_wr_en && ((bar1_wr_addr[8:0] == 9'h110) && !bar1_wr_addr[11]);
end

// reg [31:0] o_mrd_ram_addr;
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        o_mrd_ram_addr <= 32'd0;
    else if(mrd_ram_addr_en)
        o_mrd_ram_addr <= bar1_wr_data_d1;
end


//******rd data length
reg rd_data_length_en;
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        rd_data_length_en <= 1'b0;
    else if(rd_data_length_en)
        rd_data_length_en <= 1'b0;
    else
        rd_data_length_en <= &bar1_wr_byte_en && bar1_wr_en && ((bar1_wr_addr[8:0] == 9'h120) && !bar1_wr_addr[11]);
end

reg [31:0] rd_data_length;
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        rd_data_length <= 32'd0;
    else if(rd_data_length_en)
        rd_data_length <= bar1_wr_data_d1;
end


//******mrd_reg_state
reg mrd_reg_state;
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        mrd_reg_state <= 1'b0;
    else if(mrd_reg_state)
        mrd_reg_state <= 1'b0;
    else
        mrd_reg_state <= &bar1_wr_byte_en && bar1_wr_en && ((bar1_wr_addr[8:0] == 9'h130) && !bar1_wr_addr[11]);
end


//******rd_32_64_addr
reg rd_32_64_addr_en;
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        rd_32_64_addr_en <= 1'b0;
    else if(rd_32_64_addr_en)
        rd_32_64_addr_en <= 1'b0;
    else
        rd_32_64_addr_en <= &bar1_wr_byte_en && bar1_wr_en && ((bar1_wr_addr[8:0] == 9'h140) && !bar1_wr_addr[11]);
end

reg [31:0] rd_32_64_addr;
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        rd_32_64_addr <= 32'd0;
    else if(rd_32_64_addr_en)
        rd_32_64_addr <= bar1_wr_data_d1;
end

 
 
//*********************************************wr
//*******wr l_addr
reg wr_l_addr_en;
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        wr_l_addr_en <= 1'b0;
    else if(wr_l_addr_en)
        wr_l_addr_en <= 1'b0;
    else
        wr_l_addr_en <= &bar1_wr_byte_en && bar1_wr_en && ((bar1_wr_addr[8:0] == 9'h200) && !bar1_wr_addr[11]);
end
reg [31:0] wr_l_addr;
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        wr_l_addr <= 32'd0;
    else if(wr_l_addr_en)
        wr_l_addr <= bar1_wr_data_d1;
end


//*******rd h_addr
reg wr_h_addr_en;
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        wr_h_addr_en <= 1'b0;
    else if(wr_h_addr_en)
        wr_h_addr_en <= 1'b0;
    else
        wr_h_addr_en <= &bar1_wr_byte_en && bar1_wr_en && ((bar1_wr_addr[8:0] == 9'h204) && !bar1_wr_addr[11]);
end
reg [31:0] wr_h_addr;
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        wr_h_addr <= 32'd0;
    else if(wr_h_addr_en)
        wr_h_addr <= bar1_wr_data_d1;
end


//*******rd ram addr
reg mwr_ram_addr_en/* synthesis PAP_MARK_DEBUG=”true”*/;
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        mwr_ram_addr_en <= 1'b0;
    else if(mwr_ram_addr_en)
        mwr_ram_addr_en <= 1'b0;
    else
        mwr_ram_addr_en <= &bar1_wr_byte_en && bar1_wr_en && ((bar1_wr_addr[8:0] == 9'h210) && !bar1_wr_addr[11]);
end
// reg [31:0] o_mwr_ram_addr;
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        o_mwr_ram_addr <= 32'd0;
    else if(mwr_ram_addr_en)
        o_mwr_ram_addr <= bar1_wr_data_d1;
end


//********wr data length
reg wr_data_length_en;
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        wr_data_length_en <= 1'b0;
    else if(wr_data_length_en)
        wr_data_length_en <= 1'b0;
    else
        wr_data_length_en <= &bar1_wr_byte_en && bar1_wr_en && ((bar1_wr_addr[8:0] == 9'h220) && !bar1_wr_addr[11]);
end
reg [31:0] wr_data_length;
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        wr_data_length <= 32'd0;
    else if(wr_data_length_en)
        wr_data_length <= bar1_wr_data_d1;
end


//********mwr ext length  // 20261018 ext:
reg mwr_ext_length_en;   // 20261018 ext:
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        mwr_ext_length_en <= 1'b0;   // 20261018 ext:
    else if(mwr_ext_length_en)
        mwr_ext_length_en <= 1'b0;
    else
        mwr_ext_length_en <= &bar1_wr_byte_en && bar1_wr_en && ((bar1_wr_addr[8:0] == 9'h250) && !bar1_wr_addr[11]);   // 20261018 ext:
end
reg [19:0] mwr_ext_length;   // 20261018 ext:
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        mwr_ext_length <= 20'd0;   // 20261018 ext:
    else if(mwr_ext_length_en)
        mwr_ext_length <= bar1_wr_data_d1[19:0];   // 20261018 ext:
end

assign o_mwr_ext_length = mwr_ext_length;   // 20261018 ext:


//********mrd ext length  // 20261018 mrd:
reg mrd_ext_length_en;   // 20261018 mrd:
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        mrd_ext_length_en <= 1'b0;   // 20261018 mrd:
    else if(mrd_ext_length_en)
        mrd_ext_length_en <= 1'b0;
    else
        mrd_ext_length_en <= &bar1_wr_byte_en && bar1_wr_en && ((bar1_wr_addr[8:0] == 9'h150) && !bar1_wr_addr[11]);   // 20261018 mrd:
end
reg [19:0] mrd_ext_length;   // 20261018 mrd:
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        mrd_ext_length <= 20'd0;   // 20261018 mrd:
    else if(mrd_ext_length_en)
        mrd_ext_length <= bar1_wr_data_d1[19:0];   // 20261018 mrd:
end
assign o_mrd_ext_length = mrd_ext_length;   // 20261018 mrd:


//********mrd max outstanding  // 20261018 mrd:
reg mrd_max_out_en;   // 20261018 mrd:
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        mrd_max_out_en <= 1'b0;   // 20261018 mrd:
    else if(mrd_max_out_en)
        mrd_max_out_en <= 1'b0;
    else
        mrd_max_out_en <= &bar1_wr_byte_en && bar1_wr_en && ((bar1_wr_addr[8:0] == 9'h154) && !bar1_wr_addr[11]);   // 20261018 mrd:
end
reg [5:0] mrd_max_out;   // 20261018 mrd:
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        mrd_max_out <= 6'd0;   // 20261018 mrd:
    else if(mrd_max_out_en)
        mrd_max_out <= bar1_wr_data_d1[5:0];   // 20261018 mrd:
end
assign o_mrd_max_out = mrd_max_out;   // 20261018 mrd:


//********checker seed  // 20261018 mrd:
reg chk_seed_en;   // 20261018 mrd:
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        chk_seed_en <= 1'b0;   // 20261018 mrd:
    else if(chk_seed_en)
        chk_seed_en <= 1'b0;
    else
        chk_seed_en <= &bar1_wr_byte_en && bar1_wr_en && ((bar1_wr_addr[8:0] == 9'h158) && !bar1_wr_addr[11]);   // 20261018 mrd:
end
reg [31:0] chk_seed;   // 20261018 mrd:
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        chk_seed <= 32'd0;   // 20261018 mrd:
    else if(chk_seed_en)
        chk_seed <= bar1_wr_data_d1;   // 20261018 mrd:
end
assign o_chk_seed = chk_seed;   // 20261018 mrd:


//********mrd abort (only need the en pulse)  // 20261018 mrd:
reg mrd_abort_en;   // 20261018 mrd:
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        mrd_abort_en <= 1'b0;   // 20261018 mrd:
    else if(mrd_abort_en)
        mrd_abort_en <= 1'b0;
    else
        mrd_abort_en <= &bar1_wr_byte_en && bar1_wr_en && ((bar1_wr_addr[8:0] == 9'h15C) && !bar1_wr_addr[11]);   // 20261018 mrd:
end
assign o_mrd_abort = mrd_abort_en;   // 20261018 mrd:


//******mwr_reg_state
reg mwr_reg_state;
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        mwr_reg_state <= 1'b0;
    else if(mwr_reg_state)
        mwr_reg_state <= 1'b0;
    else
        mwr_reg_state <= &bar1_wr_byte_en && bar1_wr_en && ((bar1_wr_addr[8:0] == 9'h230) && !bar1_wr_addr[11]);
end


//******wr_32_64_addr
reg wr_32_64_addr_en;
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        wr_32_64_addr_en <= 1'b0;
    else if(wr_32_64_addr_en)
        wr_32_64_addr_en <= 1'b0;
    else
        wr_32_64_addr_en <= &bar1_wr_byte_en && bar1_wr_en && ((bar1_wr_addr[8:0] == 9'h240) && !bar1_wr_addr[11]);
end

reg [31:0] wr_32_64_addr;
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        wr_32_64_addr <= 32'd0;
    else if(wr_32_64_addr_en)
        wr_32_64_addr <= bar1_wr_data_d1;
end



//******************************************************************requst
reg rd_32_64_addr_en_d1;
reg wr_32_64_addr_en_d1;

//******rd_last_cmd
reg rd_last_cmd_flag;
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        rd_last_cmd_flag <= 1'b0;
    else if (ack_rcv )
        rd_last_cmd_flag <= 1'b0;
    else if(rd_32_64_addr_en_d1)
        rd_last_cmd_flag <= 1'b1;
	else
        rd_last_cmd_flag <= rd_last_cmd_flag;	
end
//******wr_last_cmd
reg wr_last_cmd_flag;
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        wr_last_cmd_flag <= 1'b0;
    else if (ack_rcv )
        wr_last_cmd_flag <= 1'b0;
    else if(wr_32_64_addr_en_d1)
        wr_last_cmd_flag <= 1'b1;
	else
        wr_last_cmd_flag <= wr_last_cmd_flag;	
end


always@(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        rd_32_64_addr_en_d1 <= 1'b0;
        wr_32_64_addr_en_d1 <= 1'b0;
	end
    else begin
        rd_32_64_addr_en_d1 <= rd_32_64_addr_en;
        wr_32_64_addr_en_d1 <= wr_32_64_addr_en;
    end
end

reg wr_32_64_flag;   //64bit addr = 1,32bit addr = 0,
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        wr_32_64_flag <= 1'b0;
    else if (ack_rcv )
        wr_32_64_flag <= 1'b0;
    else if(wr_32_64_addr_en_d1 && wr_32_64_addr[0])  
        wr_32_64_flag <= 1'b1;
end

reg rd_32_64_flag;   //64bit addr = 1,32bit addr = 0,
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        rd_32_64_flag <= 1'b0;
    else if (ack_rcv )
        rd_32_64_flag <= 1'b0;
    else if(rd_32_64_addr_en_d1 && rd_32_64_addr[0])  
        rd_32_64_flag <= 1'b1;
end

//gen req valid
wire mwr32_req_vld;
wire mwr64_req_vld;
wire mrd32_req_vld;
wire mrd64_req_vld;
assign mwr32_req_vld =  ~wr_32_64_flag && wr_last_cmd_flag ;
assign mwr64_req_vld =  wr_32_64_flag && wr_last_cmd_flag  ;
assign mrd32_req_vld =  ~rd_32_64_flag && rd_last_cmd_flag ;
assign mrd64_req_vld =  rd_32_64_flag && rd_last_cmd_flag  ;

//mwr_32_req
always@(posedge clk or negedge rst_n)begin
    if(!rst_n)
        o_mwr32_req <= 1'b0;
    else if(i_mwr32_req_ack)
        o_mwr32_req <= 1'b0;
    else if(mwr32_req_vld)
        o_mwr32_req  <= 1'b1;
end

//mwr_64_req
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        o_mwr64_req <= 1'b0;
    else if(i_mwr64_req_ack)
        o_mwr64_req <= 1'b0;
    else if(mwr64_req_vld)
        o_mwr64_req  <= 1'b1;
end
//mrd_32_req
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        o_mrd32_req <= 1'b0;
    else if(i_mrd32_req_ack)
        o_mrd32_req <= 1'b0;
    else if(mrd32_req_vld)
        o_mrd32_req  <= 1'b1;
end

//mrd_64_req
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        o_mrd64_req <= 1'b0;
    else if(i_mrd64_req_ack)
        o_mrd64_req <= 1'b0;
    else if(mrd64_req_vld)
        o_mrd64_req  <= 1'b1;
end

//********************************************************************mem_length and mem_addr latch
reg rd_data_length_en_d1;
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        rd_data_length_en_d1 <= 1'b0;
    else
        rd_data_length_en_d1  <= rd_data_length_en;
end

reg rd_l_addr_en_d1;
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        rd_l_addr_en_d1 <= 1'b0;
    else
        rd_l_addr_en_d1  <= rd_l_addr_en;
end

reg rd_h_addr_en_d1;
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        rd_h_addr_en_d1 <= 1'b0;
    else
        rd_h_addr_en_d1  <= rd_h_addr_en;
end

//
reg wr_data_length_en_d1;
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        wr_data_length_en_d1 <= 1'b0;
    else
        wr_data_length_en_d1  <= wr_data_length_en;
end

reg wr_l_addr_en_d1;
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        wr_l_addr_en_d1 <= 1'b0;
    else
        wr_l_addr_en_d1  <= wr_l_addr_en;
end

reg wr_h_addr_en_d1;
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        wr_h_addr_en_d1 <= 1'b0;
    else
        wr_h_addr_en_d1  <= wr_h_addr_en;
end

//////
//o_mem_length
always@(posedge clk or negedge rst_n)begin
    if(!rst_n)
        o_mem_length <= 10'd0;
    else if(rd_data_length_en_d1)
        o_mem_length <= rd_data_length[9:0] + 10'h1;
    else if(wr_data_length_en_d1)
        o_mem_length <= wr_data_length[9:0] + 10'h1;
end

//o_mem_addr
always@(posedge clk or negedge rst_n)begin
    if(!rst_n)
        o_mem_addr[31:0] <= 32'd0;
    else if(rd_l_addr_en_d1)
        o_mem_addr[31:0] <= rd_l_addr;
    else if(wr_l_addr_en_d1)
        o_mem_addr[31:0] <= wr_l_addr;
end

always@(posedge clk or negedge rst_n)begin
    if(!rst_n)
        o_mem_addr[63:32] <= 32'd0;
    else if(rd_h_addr_en_d1)
        o_mem_addr[63:32] <= rd_h_addr;
    else if(wr_h_addr_en_d1)
        o_mem_addr[63:32] <= wr_h_addr;
end

endmodule
