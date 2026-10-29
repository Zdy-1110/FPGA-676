

//////////////////////////////////////////////////////////////////////////////
module rt01_dma_rx (
    input                       clk                     ,   //gen1:62.5MHz,gen2:125MHz
    input                       rst_n                   ,
    input         [2:0]         i_cfg_max_rd_req_size   ,
    input         [2:0]         i_cfg_max_payload_size  ,
	
    input         [9:0]         i_tlp_common_length     ,
	input         [7:0]         i_tlp_req_dwbe          ,  
    input         [63:0]        i_tlp_req_addr          ,
    input         [11:0]        i_tlp_cpld_byte_cnt     ,	
    input         [6:0]         i_tlp_cpld_low_addr     ,
	
    input         [2:0]         i_bar_sel               ,
	input                       i_mwr_req_en            ,  	//mwr_en 数据使能
    input         [127:0]       i_mwr_req_data          ,
    input         [3:0]         i_mwr_req_dw_vld        ,
    input                       i_mwr_req_en_flag       ,  

	input         [7:0]         i_cpld_tag              ,
    input                       i_cpld_en               ,
    input         [127:0]       i_cpld_data             ,	
    input         [3:0]         i_cpld_dw_vld           ,
    input                       i_cpld_en_flag          ,
    input                       i_cpld_multi_flag       , 	

    //**********************************************************************
	////////to tx engine mwr and mrd
	input                       i_mwr32_req_ack         , 
	input                       i_mwr64_req_ack         , 
	input                       i_mrd32_req_ack         , 
	input                       i_mrd64_req_ack         , 
	output   wire               o_mwr32_req             ,   
	output   wire               o_mwr64_req             , 
	output   wire               o_mrd32_req             , 
	output   wire               o_mrd64_req             , 
	//mem addr	
	output   wire  [10:0]       o_mem_length            , 
	output   wire  [63:0]       o_mem_addr              ,
	//ram addr
	output   wire  [31:0]       o_mwr_ram_addr          ,  //存储器写操作。从这个地址读取ram_16in_16out
	output   wire  [31:0]       o_mrd_ram_addr          ,  //存储器读操作。接收CplD数据，写入ram_16in_16out   

    output   wire               o_dma_wr_en             ,
    output   wire  [15:0]       o_dma_wr_byte_en        , 
    output   wire  [63:0]       o_dma_wr_addr           ,
    output   wire  [127:0]      o_dma_wr_data           ,
                   
    output   reg                o_pio_wr_en             ,
    output   reg   [15:0]       o_pio_wr_byte_en        ,
    output   reg   [63:0]       o_pio_wr_addr           ,
    output   wire  [19:0]       o_mwr_ext_length        ,   // 20261018 ext:
    output   reg   [127:0]      o_pio_wr_data       ,
    //**********************************************************************
    // 20261018 mrd: extended long read support
    output   wire  [19:0]       o_mrd_ext_length        ,   // 20261018 mrd:
    output   wire  [5:0]        o_mrd_max_out           ,   // 20261018 mrd:
    output   wire  [31:0]       o_chk_seed              ,   // 20261018 mrd:
    output   wire               o_mrd_abort             ,   // 20261018 mrd:
    output   wire               o_tag_free_vld          ,   // 20261018 mrd:
    output   wire  [4:0]        o_tag_free              ,   // 20261018 mrd:
    input                       i_chunk_wr_en           ,   // 20261018 mrd:
    input          [4:0]        i_chunk_wr_tag          ,   // 20261018 mrd:
    input          [15:0]       i_chunk_wr_idx          ,   // 20261018 mrd:
    // 20261018 ddr: BAR1 write tap
    output  wire                o_bar1_tap_vld          ,
    output  wire   [11:0]       o_bar1_tap_addr         ,
    output  wire   [31:0]       o_bar1_tap_data
);


wire  [63:0]    cpld_start_addr  ;
wire  [2:0]     pio_bar_sel      ;
wire            pio_wr_en        ;
wire  [15:0]    pio_wr_byte_en   ;
wire  [63:0]    pio_wr_addr      ;
wire  [127:0]   pio_wr_data      ;

rt0101_dma_request_ctrl u_rt0101_dma_request_ctrl
(
    .clk               (clk              ),  //gen1:62.5MHz,gen2:125MHz
    .rst_n             (rst_n            ),

    //**********************************************************************master
    //AXIS master interface
    .i_mwr_req_en      (i_mwr_req_en     ),
    .i_tlp_req_addr    (i_tlp_req_addr   ),
    .i_mwr_req_data    (i_mwr_req_data   ),
    .i_tlp_req_dwbe    (i_tlp_req_dwbe   ),
    .i_bar_sel         (i_bar_sel        ),

	//**********************************************************************
    .i_mwr32_req_ack   (i_mwr32_req_ack  ),
	.i_mwr64_req_ack   (i_mwr64_req_ack  ),
    .i_mrd32_req_ack   (i_mrd32_req_ack  ),
    .i_mrd64_req_ack   (i_mrd64_req_ack  ),
    .o_mwr32_req       (o_mwr32_req      ),
    .o_mwr64_req       (o_mwr64_req      ),
    .o_mrd32_req       (o_mrd32_req      ),
    .o_mrd64_req       (o_mrd64_req      ),
    .o_mwr_ext_length  (o_mwr_ext_length )   ,   // 20261018 ext:
    .o_mrd_ext_length  (o_mrd_ext_length )   ,   // 20261018 mrd:
    .o_mrd_max_out     (o_mrd_max_out    )   ,   // 20261018 mrd:
    .o_chk_seed        (o_chk_seed       )   ,   // 20261018 mrd:
    .o_mrd_abort       (o_mrd_abort      )   ,   // 20261018 mrd:
    .o_bar1_tap_vld    (o_bar1_tap_vld   )   ,   // 20261018 ddr:
    .o_bar1_tap_addr   (o_bar1_tap_addr  )   ,   // 20261018 ddr:
    .o_bar1_tap_data   (o_bar1_tap_data  )   ,   // 20261018 ddr:

	
    .o_mem_length      (o_mem_length     ),		
    .o_mem_addr        (o_mem_addr       ),	
	
	.o_mwr_ram_addr    (o_mwr_ram_addr   ),
	.o_mrd_ram_addr    (o_mrd_ram_addr   )	
);

rt0102_dma_cpld_tag_ctrl u_rt0102_dma_cpld_tag_ctrl
(
    .clk                     (clk                    ),  //gen1:62.5MHz,gen2:125MHz
    .rst_n                   (rst_n                  ),
    .i_cfg_max_rd_req_size   (i_cfg_max_rd_req_size  ),  //gen1:62.5MHz,gen2:125MHz
    .i_cfg_max_payload_size  (i_cfg_max_payload_size ),
    //**********************************************************************
    .i_cpld_length           (i_tlp_common_length    ),
    .i_cpld_tag              (i_cpld_tag             ),
    .i_multicpld_flag        (i_cpld_multi_flag      ),
    .i_cpld_data_flag        (i_cpld_en_flag         ),
    .i_chunk_wr_en           (i_chunk_wr_en          ),   // 20261018 mrd:
    .i_chunk_wr_tag          (i_chunk_wr_tag         ),   // 20261018 mrd:
    .i_chunk_wr_idx          (i_chunk_wr_idx         ),   // 20261018 mrd:

    //**********************************************************************
    .o_cpld_addr             (cpld_start_addr      )
);


// 20261018 mrd: report tag free when the last cpld of a request is finished
rt0105_cpld_tag_free u_rt0105_cpld_tag_free
(
    .clk                     (clk                    ),
    .rst_n                   (rst_n                  ),
    .i_cpld_tag              (i_cpld_tag             ),
    .i_cpld_length           (i_tlp_common_length    ),
    .i_cpld_byte_cnt         (i_tlp_cpld_byte_cnt    ),
    .i_cpld_low_addr         (i_tlp_cpld_low_addr    ),
    .i_cpld_en_flag          (i_cpld_en_flag         ),
    .o_tag_free_vld          (o_tag_free_vld         ),
    .o_tag_free              (o_tag_free             )
);


//***************************calculating dwbe from byte count and lower address
wire    [1:0]       last_dw_byte_num;
reg     [3:0]       first_dw_be;
reg     [3:0]       last_dw_be;
wire    [7:0]       cpld_dwbe ;

always@(*)
begin
    case(i_tlp_cpld_low_addr[1:0])
        2'd0: first_dw_be = 4'b1111;
        2'd1: first_dw_be = 4'b1110;
        2'd2: first_dw_be = 4'b1100;
        2'd3: first_dw_be = 4'b1000;
        default: first_dw_be = 4'hf;
    endcase
end

assign last_dw_byte_num = i_tlp_cpld_byte_cnt[1:0] + i_tlp_cpld_low_addr[1:0];

always@(*)
begin
    case(last_dw_byte_num)
        2'd0: last_dw_be = 4'b1111;
        2'd1: last_dw_be = 4'b0001;
        2'd2: last_dw_be = 4'b0011;
        2'd3: last_dw_be = 4'b0111;
        default: last_dw_be = 4'hf;
    endcase
end

assign cpld_dwbe = {last_dw_be,first_dw_be};



rt0103_dma_data_wr_ctrl u_rt0103_dma_data_wr_ctrl
(
    .clk                (clk                ),  //gen1:62.5MHz,gen2:125MHz
    .rst_n              (rst_n              ),

    //**********************************************************************
    .i_bar_sel          (i_bar_sel          ),
    .i_de               (i_cpld_en          ),
    .i_length           (i_tlp_common_length),
    .i_dwbe             (cpld_dwbe          ),
    .i_data             (i_cpld_data        ),
    .i_dw_vld           (i_cpld_dw_vld      ),
    .i_addr             (cpld_start_addr    ),
    .i_data_flag        (i_cpld_en_flag     ),

    //**********************************************************************
    //ram write control
    .o_wr_bar_sel       (       ),
    .o_wr_en            (o_dma_wr_en        ),
    .o_wr_addr          (o_dma_wr_addr      ),
    .o_wr_data          (o_dma_wr_data      ),
    .o_wr_be            (o_dma_wr_byte_en   )
);


rt0103_dma_data_wr_ctrl u_rt0104_pio_data_wr_ctrl
(
    .clk                (clk                ),  //gen1:62.5MHz,gen2:125MHz
    .rst_n              (rst_n              ),

    //**********************************************************************
    .i_bar_sel          (i_bar_sel          ),
    .i_de               (i_mwr_req_en       ),
    .i_length           (i_tlp_common_length),
    .i_dwbe             (i_tlp_req_dwbe     ),
    .i_data             (i_mwr_req_data     ),
    .i_dw_vld           (i_mwr_req_dw_vld   ),
    .i_addr             (i_tlp_req_addr     ),
    .i_data_flag        (i_mwr_req_en_flag  ),

    //**********************************************************************
    //ram write control
    .o_wr_bar_sel       (pio_bar_sel        ),
    .o_wr_en            (pio_wr_en          ),
    .o_wr_addr          (pio_wr_addr        ),
    .o_wr_data          (pio_wr_data        ),
    .o_wr_be            (pio_wr_byte_en     )
);

always@(*)
begin
    if(pio_bar_sel == 2'b0)
    begin
        o_pio_wr_en       = pio_wr_en     ;
        o_pio_wr_addr     = pio_wr_addr   ;
        o_pio_wr_data     = pio_wr_data   ;
        o_pio_wr_byte_en  = pio_wr_byte_en;
    end
    else
    begin
        o_pio_wr_en       = 'd0;  
        o_pio_wr_addr     = 'd0;
        o_pio_wr_data     = 'd0;
        o_pio_wr_byte_en  = 'd0;
    end
end


endmodule


//////////////////////////////////////////////////////////////////////////////
// 20261018 mrd: tag free generator
// free the tag when the last cpld of the request is received
module rt0105_cpld_tag_free
(
    input                       clk                     ,
    input                       rst_n                   ,
    input           [7:0]       i_cpld_tag              ,
    input           [9:0]       i_cpld_length           ,
    input           [11:0]      i_cpld_byte_cnt         ,
    input           [6:0]       i_cpld_low_addr         ,
    input                       i_cpld_en_flag          ,
    output  reg                 o_tag_free_vld          ,
    output  reg     [4:0]       o_tag_free
);

reg             flag_d1;   // 20261018 mrd:
wire            pe;        // 20261018 mrd:
wire            ne;        // 20261018 mrd:

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        flag_d1 <= 1'b0;   // 20261018 mrd:
    else
        flag_d1 <= i_cpld_en_flag;   // 20261018 mrd:
end

assign pe = i_cpld_en_flag & ~flag_d1;   // 20261018 mrd:
assign ne = ~i_cpld_en_flag & flag_d1;   // 20261018 mrd:

wire [12:0] bc_eff  = (i_cpld_byte_cnt == 12'd0) ? 13'd4096 : {1'b0, i_cpld_byte_cnt};   // 20261018 mrd:
wire [12:0] len_eff = (i_cpld_length == 10'd0) ? 13'd4096 : {1'b0, i_cpld_length, 2'b00};   // 20261018 mrd:
wire        is_last = ((bc_eff + {11'd0, i_cpld_low_addr[1:0]}) <= len_eff);   // 20261018 mrd:

reg             lat_last;   // 20261018 mrd:
reg     [4:0]   lat_tag;    // 20261018 mrd:

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
    begin
        lat_last <= 1'b0;   // 20261018 mrd:
        lat_tag  <= 5'd0;   // 20261018 mrd:
    end
    else if(pe)
    begin
        lat_last <= is_last;   // 20261018 mrd:
        lat_tag  <= i_cpld_tag[4:0];   // 20261018 mrd:
    end
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
    begin
        o_tag_free_vld <= 1'b0;   // 20261018 mrd:
        o_tag_free     <= 5'd0;   // 20261018 mrd:
    end
    else
    begin
        o_tag_free_vld <= ne && lat_last;   // 20261018 mrd:
        if(ne)
            o_tag_free <= lat_tag;   // 20261018 mrd:
    end
end

endmodule
