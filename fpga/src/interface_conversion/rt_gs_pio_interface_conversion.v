
//////////////////////////////////////////////////////////////////////////////
module rt_gs_pio_interface_conversion #(
    parameter                           ADDR_WIDTH  = 'd32

)(
    input                               clk                     ,   //gen1:62.5MHz,gen2:125MHz
    input                               rst_n                   ,
    //**********************************************************************
	input                               i_dma_wr_en             ,
    input         [15:0]                i_dma_wr_byte_en        ,
    input         [ADDR_WIDTH-1:0]      i_dma_wr_addr           ,
    input         [127:0]               i_dma_wr_data           ,

	output  wire                        o_dma_ram_wr_en         ,
    output  wire  [1:0]                 o_dma_ram_wr_byte_en    ,
    output  wire  [ADDR_WIDTH-1:0]      o_dma_ram_wr_addr       ,
    output  wire  [15:0]                o_dma_ram_wr_data       ,
    //////	
    input                               i_dma_rd_en             ,
	input         [ADDR_WIDTH-1:0]      i_dma_rd_addr           ,
    output  wire  [127:0]               o_dma_rd_data           ,	
	
    output  wire                        o_dma_ram_rd_en         ,
	output  wire  [ADDR_WIDTH-1:0]      o_dma_ram_rd_addr       ,
    input         [15:0]                i_dma_ram_rd_data       ,

	/////////////////////////////////////////////////
	//other ctrl
    output  wire                        o_cpld_finish           ,   
    input	                            i_mwr_req_cmd           ,
    output  wire	                    o_mwr_tx_start          ,	
    input         [31:0]                i_rd_base_ram_addr      ,
	input         [9:0]                 i_rd_length      ,
	
    input         [31:0]                i_wr_base_ram_addr      ,
    input         [10:0]                i_mem_length              //总共长度 单位：dw
);

///////////////////////////////////////////////////////////////////////////////////////write ram
wire        o_cpld_128_wr_ram_finish ;
wire        rd_en                    ;
wire [ADDR_WIDTH-1:0] rd_addr        ;
wire [15:0] rd_data                  ;

rt_cpld_128_wr_finish u_rt_cpld_128_wr_finish
(
    .clk                      (clk                      ),  //gen1:62.5MHz,gen2:125MHz
    .rst_n                    (rst_n                    ),

    .i_mem_length             (i_mem_length             ),
    .i_wr_en                  (i_dma_wr_en              ),
    .o_cpld_128_wr_ram_finish (o_cpld_128_wr_ram_finish )
);

rt_pio_cpld_16bit_ram_ctrl u_rt_pio_cpld_16bit_ram_ctrl
(
    .clk                      (clk                    ),  //gen1:62.5MHz,gen2:125MHz
    .rst_n                    (rst_n                  ),
//**********************************************
    .i_mem_length             (i_mem_length            ),
    .i_cpld_128_wr_ram_finish (o_cpld_128_wr_ram_finish),
	                        
    .o_rd_en                  (rd_en                  ),
    .o_rd_addr                (rd_addr                ),
    .i_ram_data               (rd_data                ),

    .i_wr_base_ram_addr       (i_wr_base_ram_addr     ),							  

	.o_wr_en                  (o_dma_ram_wr_en        ),
    .o_wr_addr                (o_dma_ram_wr_addr      ),
    .o_wr_data                (o_dma_ram_wr_data      ),
	.o_wr_be                  (o_dma_ram_wr_byte_en   ),
    .o_cpld_finish            (o_cpld_finish          )
);

ram_128in_16out u_ram_128in_16out
(
    .wr_clk                 (clk                    ),  // input
    .wr_rst                 (~rst_n                 ),  // input
    .wr_en                  (i_dma_wr_en            ),  // input
    .wr_byte_en             (i_dma_wr_byte_en       ),  // input [15:0]
    .wr_addr                (i_dma_wr_addr[8:0]     ),  // input [8:0]
    .wr_data                (i_dma_wr_data          ),  // input [127:0]
    .rd_clk                 (clk                    ),  // input
    .rd_rst                 (~rst_n                 ),  // input
    .rd_clk_en              (rd_en                  ),  // input
    .rd_addr                (rd_addr[11:0]          ),  // input [11:0]
    .rd_data                (rd_data                )   // output [15:0]
);

///////////////////////////////////////////////////////////////////////////////////////read ram
wire         wr_en       ;
wire [31:0]  wr_addr     ;
wire [15:0]  wr_data     ;
wire [1:0]   wr_byte_en  ;	

rt_pio_mwr_16bit_ram_ctrl u_rt_pio_mwr_16bit_ram_ctrl
(
    .clk                        (clk                        ),  //gen1:62.5MHz,gen2:125MHz
    .rst_n                      (rst_n                      ),

    //**********************************************************************
    .i_rd_16in_16out_ram_en     (i_mwr_req_cmd              ),  //开始读16in_16out_ram
    .i_rd_length                (i_rd_length                ),
	                                                       
    .o_rd_en                    (o_dma_ram_rd_en            ),
    .o_rd_addr                  (o_dma_ram_rd_addr          ),
    .i_ram_data                 (i_dma_ram_rd_data          ),
	
    .i_rd_base_ram_addr         (i_rd_base_ram_addr         ),

    //**********************************************************************
    .o_wr_en                    (wr_en                      ),
    .o_wr_addr                  (wr_addr                    ),
    .o_wr_data                  (wr_data                    ),
    .o_wr_be                    (wr_byte_en                 ),
    .o_mwr_16_wr_ram_done       (o_mwr_tx_start             )  //这个信号表示数据已经搬到16in_128out ram.可以开始mwr组包
);
	
ram_16in_128out u_16in_128out
(
    .wr_clk                     (clk                        ),  // input
    .wr_rst                     (~rst_n                     ),  // input
    .wr_en                      (wr_en                      ),  // input
    .wr_byte_en                 (wr_byte_en                 ),  // input [1:0]
    .wr_addr                    (wr_addr[11:0]              ),  // input [11:0]
    .wr_data                    (wr_data                    ),  // input [15:0]
    .rd_clk                     (clk                        ),  // input
    .rd_rst                     (~rst_n                     ),  // input
    .rd_clk_en                  (i_dma_rd_en                ),  // input
    .rd_addr                    (i_dma_rd_addr              ),  // input [8:0]
    .rd_data                    (o_dma_rd_data              )   // output [127:0]
);

endmodule
