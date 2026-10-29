
//////////////////////////////////////////////////////////////////////////////
module rt_gs_dma_interface_conversion #(
    parameter                           ADDR_WIDTH     = 'd32,
    parameter                           RD_DATA_DELAY  = 'd1,	

    // 20261018 fast: 1 = 128-bit in/out DMA RAM, 0 = original 16-bit repack
    parameter                           FAST_PATH      = 0

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
    input         [31:0]                i_wr_base_ram_addr      ,
    input         [10:0]                i_mem_length            , //总共长度 单位：dw
    // 20261018 ddr: copy write port for DDR readback into DMA RAM
    input                               i_copy_wr_en            ,
    input         [11:0]                i_copy_wr_addr          ,
    input         [127:0]               i_copy_wr_data
);

// 20261018 fast: original 16-bit repack path (FAST_PATH==0)
generate
if (FAST_PATH == 0) begin : g_orig

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

rt_cpld_16bit_ram_ctrl u_rt_cpld_16bit_ram_ctrl
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
 

rt_mwr_16bit_ram_ctrl #(
	.RD_DATA_DELAY              (RD_DATA_DELAY              )   //receive rd_data delay clk cyle, support 1、2、3 clk cyle.
)  
u_rt_mwr_16bit_ram_ctrl
(
    .clk                        (clk                        ),  //gen1:62.5MHz,gen2:125MHz
    .rst_n                      (rst_n                      ),

    //**********************************************************************
    .i_rd_16in_16out_ram_en     (i_mwr_req_cmd              ),  //mwr写指令来后，开始读16in_16out_ram
    .i_mem_length               (i_mem_length               ),
	                                                       
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

end
// 20261018 fast: 128-bit in/out DMA RAM path (FAST_PATH==1)
else begin : g_fast

wire        cpld_128_done ;
reg         mwr_req_cmd_d1 ;
reg         mwr_req_cmd_d2 ;

// 20261018 fast: 128-bit write finish counter, same connection as original
rt_cpld_128_wr_finish u_rt_cpld_128_wr_finish_fast
(
    .clk                      (clk                      ),  //gen1:62.5MHz,gen2:125MHz
    .rst_n                    (rst_n                    ),

    .i_mem_length             (i_mem_length             ),
    .i_wr_en                  (i_dma_wr_en              ),
    .o_cpld_128_wr_ram_finish (cpld_128_done            )
);

// 20261018 fast: o_cpld_finish directly from 128-bit write finish
assign o_cpld_finish = cpld_128_done ;

// 20261018 fast: delay i_mwr_req_cmd by 2 clocks for mwr tx start
always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
        mwr_req_cmd_d1 <= 1'b0 ;
        mwr_req_cmd_d2 <= 1'b0 ;
    end
    else begin
        mwr_req_cmd_d1 <= i_mwr_req_cmd ;
        mwr_req_cmd_d2 <= mwr_req_cmd_d1 ;
    end

// 20261018 fast: o_mwr_tx_start = i_mwr_req_cmd delayed 2 clocks
assign o_mwr_tx_start = mwr_req_cmd_d2 ;

// 20261018 fast: 128-bit word address = base word offset + dma word offset
wire [11:0] fast_wr_addr = i_wr_base_ram_addr[14:3] + {3'b000, i_dma_wr_addr[8:0]} ;
wire [11:0] fast_rd_addr = i_rd_base_ram_addr[14:3] + {3'b000, i_dma_rd_addr[8:0]} ;

// 20261018 ddr: DMA write has priority over DDR readback copy write
wire         fast_ram_wr_en   = i_dma_wr_en | i_copy_wr_en;                                  // 20261018 ddr:
wire [11:0]  fast_ram_wr_addr = i_dma_wr_en ? fast_wr_addr  : i_copy_wr_addr;                // 20261018 ddr:
wire [127:0] fast_ram_wr_data = i_dma_wr_en ? i_dma_wr_data : i_copy_wr_data;                // 20261018 ddr:
wire [15:0]  fast_ram_wr_be   = i_dma_wr_en ? i_dma_wr_byte_en : 16'hFFFF;                   // 20261018 ddr:

// 20261018 fast: 128-bit in/out DMA buffer RAM, output to o_dma_rd_data
ram_128in_128out u_fast_dma_ram
(
    .wr_clk             (clk                    ),  // input
    .wr_rst             (~rst_n                 ),  // input
    .wr_en              (fast_ram_wr_en         ),  // input
    .wr_byte_en         (fast_ram_wr_be         ),  // input [15:0]
    .wr_addr            (fast_ram_wr_addr       ),  // input [11:0]
    .wr_data            (fast_ram_wr_data       ),  // input [127:0]
    .rd_clk             (clk                    ),  // input
    .rd_rst             (~rst_n                 ),  // input
    .rd_clk_en          (i_dma_rd_en            ),  // input
    .rd_addr            (fast_rd_addr           ),  // input [11:0]
    .rd_data            (o_dma_rd_data          )   // output [127:0]
);

// 20261018 fast: 16-bit side outputs unused in fast path
assign o_dma_ram_wr_en      = 1'b0                ;
assign o_dma_ram_wr_byte_en = 2'b0                ;
assign o_dma_ram_wr_addr    = {ADDR_WIDTH{1'b0}}  ;
assign o_dma_ram_wr_data    = 16'b0               ;
assign o_dma_ram_rd_en      = 1'b0                ;
assign o_dma_ram_rd_addr    = {ADDR_WIDTH{1'b0}}  ;

end
endgenerate

endmodule
