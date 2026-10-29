

//////////////////////////////////////////////////////////////////////////////
module rt0203_dma_rd_ram #(
    parameter                           ADDR_WIDTH     = 'd32,
    parameter                           RD_DATA_DELAY  = 'd1
)(
    input                               clk             ,            //gen1:62.5MHz,gen2:125MHz
    input                               rst_n           ,
    //**********************************************************************
    //frome rt0201_mwr_ctrl
    input                               i_rd_en         ,
    input           [9:0]               i_rd_length     ,
    input                               i_mwr_tx_busy   ,
    input                               i_mwr_tx_hold   ,
    input                               i_mwr_tlp_tx    ,
    //ram_rd
    output  wire                        o_bar_rd_clk_en ,
    output  wire    [ADDR_WIDTH-1:0]    o_bar_rd_addr   ,
    input           [127:0]             i_bar_rd_data   ,
    //to rt0201_mwr_ctrl	
    output  wire                        o_gen_tlp_start ,
    output  wire    [127:0]             o_rd_data       ,
    output  wire                        o_last_data     

);

reg                 rd_en_d1;
wire                rd_en_pe;

reg     [10:0]      rd_addr;
reg     [9:0]       data_remain_cnt;
reg     [9:0]       data_remain_cnt_d1;

wire                rd_ram_hold;

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        rd_en_d1 <= 1'b0;
    else
        rd_en_d1 <= i_rd_en;
end

assign rd_en_pe = ~rd_en_d1 && i_rd_en;

//calculating rd addr from rd length
//data need to read
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        data_remain_cnt <= 10'b0;
    else if(rd_en_pe)
        data_remain_cnt <= i_rd_length;
    else if(!rd_ram_hold)
    begin
        if(data_remain_cnt >= 10'd4)
            data_remain_cnt <= data_remain_cnt - 10'd4;
        else if(data_remain_cnt < 10'd4)
            data_remain_cnt <= 10'b0;
    end
end

//data_shift
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        data_remain_cnt_d1 <= 10'b0;
    else if(!rd_ram_hold)
        data_remain_cnt_d1 <= data_remain_cnt;
end

//rd_dw_addr
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        rd_addr <= 11'b0;
    else if(!i_mwr_tx_busy)
        rd_addr <= 11'b0;
    else if(o_bar_rd_clk_en && !rd_ram_hold)
    begin
        if(data_remain_cnt_d1 >= 10'd4 )
            rd_addr <= rd_addr +11'd4;
        else
            rd_addr <= rd_addr + {9'b0+data_remain_cnt_d1[1:0]};
    end
end

reg [127:0] i_bar_rd_data_d1;
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        i_bar_rd_data_d1 <= 'd0;
    else
        i_bar_rd_data_d1 <= i_bar_rd_data;
end

rt020301_dma_rd_ram_ctrl #(
    .ADDR_WIDTH             (ADDR_WIDTH             ),
	.RD_DATA_DELAY          (RD_DATA_DELAY          )   //receive rd_data delay clk cyle, support 1、2、3 clk cyle.
)
u_rt020301_dma_rd_ram_ctrl
(
    .clk                    (clk                    ),  //gen1:62.5MHz,gen2:125MHz
    .rst_n                  (rst_n                  ),
    //**********************************************************************
    //frome rt0201_mwr_ctrl
    .i_rd_en                (rd_en_d1               ),
    .i_rd_length            (i_rd_length            ),
    .i_rd_addr              ({51'b0,rd_addr,2'b0}   ),
    .i_tx_hold              (i_mwr_tx_hold          ),
    .i_tlp_tx               (i_mwr_tlp_tx           ),
    .o_rd_ram_hold          (rd_ram_hold            ),
    //ram_rd
    .o_bar_rd_clk_en        (o_bar_rd_clk_en        ),
    .o_bar_rd_addr          (o_bar_rd_addr          ),
    .i_bar_rd_data          (i_bar_rd_data_d1       ),
    //to rt0201_mwr_ctrl	
    .o_gen_tlp_start        (o_gen_tlp_start        ),
    .o_rd_data              (o_rd_data              ),
    .o_last_data            (o_last_data            )

);

endmodule
