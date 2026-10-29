

//////////////////////////////////////////////////////////////////////////////
module rt0205_pio_rd_ram #(
    parameter                           ADDR_WIDTH     = 'd32,
    parameter                           RD_DATA_DELAY  = 'd1
)(
    input                               clk             ,            //gen1:62.5MHz,gen2:125MHz
    input                               rst_n           ,
    //**********************************************************************
    input                               i_rd_en         ,
    input           [9:0]               i_rd_length     ,
    input           [63:0]              i_rd_addr       ,
    input                               i_cpld_tx_hold  ,
    input                               i_cpld_tlp_tx   ,
    //ram_rd
    output  wire                        o_bar_rd_clk_en ,
    output  wire    [ADDR_WIDTH-1:0]    o_bar_rd_addr   ,
    input           [127:0]             i_bar_rd_data   ,
	
    output  wire                        o_gen_tlp_start ,
    output  wire    [127:0]             o_rd_data       ,
    output  wire                        o_last_data     
);


rt020301_dma_rd_ram_ctrl #(
    .ADDR_WIDTH             (ADDR_WIDTH             ),
	.RD_DATA_DELAY          (RD_DATA_DELAY          )   //receive rd_data delay clk cyle, support 1、2、3 clk cyle.
)
u_rt020301_dma_rd_ram_ctrl
(
    .clk                    (clk                    ),  //gen1:62.5MHz,gen2:125MHz
    .rst_n                  (rst_n                  ),
    //**********************************************************************
    .i_rd_en                (i_rd_en                ),
    .i_rd_length            (i_rd_length            ),
    .i_rd_addr              (i_rd_addr              ),
    .i_tx_hold              (i_cpld_tx_hold         ),
    .i_tlp_tx               (i_cpld_tlp_tx          ),
    .o_rd_ram_hold          (                       ),//no use
    //ram_rd
    .o_bar_rd_clk_en        (o_bar_rd_clk_en        ),
    .o_bar_rd_addr          (o_bar_rd_addr          ),
    .i_bar_rd_data          (i_bar_rd_data          ),

    .o_gen_tlp_start        (o_gen_tlp_start        ),
    .o_rd_data              (o_rd_data              ),
    .o_last_data            (o_last_data            )

);

endmodule
