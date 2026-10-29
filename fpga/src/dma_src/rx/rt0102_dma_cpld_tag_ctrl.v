

//////////////////////////////////////////////////////////////////////////////
module rt0102_dma_cpld_tag_ctrl
(
    input                               clk                     ,   //gen1:62.5MHz,gen2:125MHz
    input                               rst_n                   ,
    input           [2:0]               i_cfg_max_rd_req_size   ,
    input           [2:0]               i_cfg_max_payload_size  ,
    //**********************************************************************
    input           [9:0]               i_cpld_length           ,
    input           [7:0]               i_cpld_tag              ,
    input                               i_multicpld_flag        ,
    input                               i_cpld_data_flag        ,
    //**********************************************************************
    input                               i_chunk_wr_en           ,   // 20261018 mrd:
    input           [4:0]               i_chunk_wr_tag          ,   // 20261018 mrd:
    input           [15:0]              i_chunk_wr_idx          ,   // 20261018 mrd:
    //**********************************************************************
    output  wire    [63:0]              o_cpld_addr            
);

//**********************************************************************
// 20261018 mrd: chunk index table, tag -> chunk index in current command
reg  [15:0] chunk_tbl [0:31];   // 20261018 mrd:
always@(posedge clk)
begin
    if(i_chunk_wr_en)
        chunk_tbl[i_chunk_wr_tag] <= i_chunk_wr_idx;   // 20261018 mrd:
end
wire [15:0] cur_chunk = chunk_tbl[i_cpld_tag[4:0]];   // 20261018 mrd:

reg    cpld_data_flag_d1;
wire   cpld_data_flag_pe/* synthesis PAP_MARK_DEBUG=”true”*/;

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        cpld_data_flag_d1 <= 1'b0;
    else
        cpld_data_flag_d1 <=  i_cpld_data_flag;
end

assign cpld_data_flag_pe = i_cpld_data_flag & ~cpld_data_flag_d1;


//************************************gen write address*************************************
reg ram_wr_en/* synthesis PAP_MARK_DEBUG=”true”*/;
always@(posedge clk or negedge rst_n)begin
    if(!rst_n)
        ram_wr_en <= 1'b0;
    else
        ram_wr_en <= cpld_data_flag_pe;
end

wire [5:0] cpld_tag_tmp /* synthesis PAP_MARK_DEBUG=”true”*/;
assign cpld_tag_tmp = i_cpld_tag[5:0]; //64 tag use;

reg  [9:0] tag_addr_next/* synthesis PAP_MARK_DEBUG=”true”*/;
wire [9:0] multicpld_addr/* synthesis PAP_MARK_DEBUG=”true”*/;
//save multicpld address pointer
ipm_distributed_sdpram_v1_2
    #(
    .ADDR_WIDTH (6                  ),  //address width   range:4-10
    .DATA_WIDTH (10                 ),  //data width      range:1-256
    .RST_TYPE   ("ASYNC"            ),  //reset type   "ASYNC" "SYNC"
    .OUT_REG    (0                  ),  //output options :non_register(0)  register(1)  // 20261018 mrd:
    .INIT_FILE  ("NONE"             ),  //legal value:"NONE" or "initial file name"
    .FILE_FORMAT("BIN"              )   //initial data format : "BIN" or "HEX"
     )
    u_ipm_distributed_sdpram_v1_2
     (
    .wr_data    (  tag_addr_next    ),
    .wr_addr    (  cpld_tag_tmp     ),
    .rd_addr    (  cpld_tag_tmp     ),
    .wr_clk     (  clk              ),
    .rd_clk     (  clk              ),
    .wr_en      (  ram_wr_en        ),
    .rst        (  ~rst_n           ),
    .rd_data    (  multicpld_addr   )
     );
	 

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        tag_addr_next <= 10'b0;
    else if(cpld_data_flag_pe)
        tag_addr_next <= i_multicpld_flag ? multicpld_addr + {i_cpld_length[7:0],2'b0} : 10'b0; 
end


reg [2:0] min_size/* synthesis PAP_MARK_DEBUG=”true”*/;
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        min_size <= 'd0;
    else if(i_cfg_max_payload_size <= i_cfg_max_rd_req_size)
        min_size <= i_cfg_max_payload_size;
    else 
        min_size <= i_cfg_max_rd_req_size;
end

//************************************gen write address*************************************

assign o_cpld_addr = (min_size == 3'd0) ? {41'b0,{cur_chunk,multicpld_addr[6:0]}} :  //128byte  // 20261018 mrd:
                     (min_size == 3'd1) ? {40'b0,{cur_chunk,multicpld_addr[7:0]}} :  //256byte  // 20261018 mrd:
                     (min_size == 3'd2) ? {39'b0,{cur_chunk,multicpld_addr[8:0]}} :  //512byte  // 20261018 mrd:
                     (min_size == 3'd3) ? {38'b0,{cur_chunk,multicpld_addr[9:0]}} :  //1024byte  // 20261018 mrd:
                                          {41'b0,{cur_chunk,multicpld_addr[6:0]}} ;   // 20261018 mrd:
													
endmodule
