

//////////////////////////////////////////////////////////////////////////////
module rt_dma #(
    parameter                           ADDR_WIDTH     = 'd32,
    parameter                           RD_DATA_DELAY  = 'd1
)
(
    input                               clk                     ,   //gen1:62.5MHz,gen2:125MHz
    input                               rst_n                   ,
    input           [7:0]               i_cfg_pbus_num          ,
    input           [4:0]               i_cfg_pbus_dev_num      ,
    input           [2:0]               i_cfg_max_rd_req_size   ,
    input           [2:0]               i_cfg_max_payload_size  ,
	
    //**********************************************************************
    output  wire                        o_axis_master_trdy      ,
    input                               i_axis_slave0_trdy      ,
    input                               i_axis_slave0_tvld      ,
    input                               i_axis_slave0_tlast     ,
    input                               i_axis_slave1_trdy      ,
    input                               i_axis_slave1_tvld      ,
    input                               i_axis_slave1_tlast     ,
    input                               i_axis_slave2_trdy      ,
    input                               i_axis_slave2_tvld      ,
    input                               i_axis_slave2_tlast     ,
    //**********************************************************************
	//other ctrl
    input                               i_cpld_finish           ,   //is cpld write to ram finish
    output  wire                        o_mwr_req_cmd           ,	//mwr写指令来后，开始读16in_16out_ram
    input                               i_mwr_tx_start          ,	//这个信号表示数据已经搬到16in_128out ram.可以开始mwr组包
	output  wire    [10:0]              o_mem_length            , 
	//ram addr                          
	output  wire    [31:0]              o_mwr_ram_addr          ,  //存储器写操作。从这个地址读取ram_16in_16out
	output  wire    [31:0]              o_mrd_ram_addr          ,  //存储器读操作。接收CplD数据，写入ram_16in_16out       

    //*********************************************************************RX
    input        [9:0]                 i_tlp_common_length       ,
    input        [1:0]                 i_tlp_common_at           ,
	input        [2:0]                 i_tlp_common_attr         ,
	input                              i_tlp_common_ep           ,
	input                              i_tlp_common_td           ,
	input                              i_tlp_common_th           ,
    input        [2:0]                 i_tlp_common_tc           ,
    input        [4:0]                 i_tlp_common_type         ,
    input        [2:0]                 i_tlp_common_fmt          ,
   
    input        [7:0]                 i_tlp_req_dwbe            ,
    input        [7:0]                 i_tlp_req_tag             ,
    input        [15:0]                i_tlp_req_requester_id    ,	
    input        [63:0]                i_tlp_req_addr            ,
   
    input        [11:0]                i_tlp_cpld_byte_cnt       ,   //还要获得多少数据才能完成全部数据传递
    input                              i_tlp_cpld_bcm            ,   	
    input        [2:0]                 i_tlp_cpld_status         ,
    input        [15:0]                i_tlp_cpld_completer_id   ,
    input        [6:0]                 i_tlp_cpld_low_addr       ,   //TLP中数据的起始地址
    input        [7:0]                 i_tlp_cpld_tag            ,	
    input        [15:0]                i_tlp_cpld_requester_id   ,
    //************************************************************
	input        [2:0]                 i_bar_sel                 ,	   
    input                              i_mrd_req_en              ,   //mrd_en 数据使能	
    input                              i_mwr_req_en              ,   //mwr_en 数据使能
    input        [127:0]               i_mwr_req_data            ,
    input        [3:0]                 i_mwr_req_dw_vld          ,
    input                              i_mwr_req_en_flag         ,
    input                              i_cpld_en                 ,
    input        [127:0]               i_cpld_data               ,	
    input        [3:0]                 i_cpld_dw_vld             ,
    input                              i_cpld_en_flag            ,
    input                              i_cpld_multi_flag         , 
	
	//**********************************************************************TX
    //to mwr	
	input                               i_mwr_data_ready            ,
	output  wire                        o_mwr_data_valid            ,
    output  wire    [127:0]             o_mwr_data                  ,
    output  wire                        o_mwr_last_data_en          ,
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
    output  wire     [7:0]              o_mwr_tag               ,
    output  wire    [15:0]              o_mwr_requester_id      ,
    output  wire     [63:0]             o_mwr_addr           	,
    //to mrd	
    output  wire                        o_tx_mrd_en             ,	
    output  wire    [9:0]               o_mrd_length            ,
    output  wire    [1:0]               o_mrd_at                ,
    output  wire    [2:0]               o_mrd_attr              ,
    output  wire                        o_mrd_ep                ,
    output  wire                        o_mrd_td                ,
    output  wire                        o_mrd_th                ,
    output  wire    [2:0]               o_mrd_tc                ,
    output  wire    [4:0]               o_mrd_tlp_type          ,
    output  wire    [2:0]               o_mrd_fmt               ,
    output  wire    [7:0]               o_mrd_dwbe              ,
    output  wire    [7:0]               o_mrd_tag               ,
    output  wire    [15:0]              o_mrd_requester_id      ,
    output  wire    [63:0]              o_mrd_addr           	,

	//cpld
	input                               i_cpld_tx_data_ready    ,	
    output  wire                        o_cpld_tx_data_valid    ,
    output  wire     [127:0]            o_cpld_tx_data          ,
    output  wire                        o_cpld_tx_last_data_en  ,
	
    output  wire     [9:0]              o_cpld_length           ,
    output  wire     [1:0]              o_cpld_at               ,
    output  wire     [2:0]              o_cpld_attr             ,
    output  wire                        o_cpld_ep               ,
    output  wire                        o_cpld_td               ,
    output  wire                        o_cpld_th               ,
    output  wire     [2:0]              o_cpld_tc               ,
    output  wire     [4:0]              o_cpld_tlp_type         ,
    output  wire     [2:0]              o_cpld_fmt              ,
	        
    output  wire     [11:0]             o_cpld_byte_cnt         ,	
    output  wire                        o_cpld_bcm              ,
    output  wire     [2:0]              o_cpld_compl_status     ,
    output  wire     [15:0]             o_cpld_completer_id     ,
    output  wire     [6:0]              o_cpld_low_addr         ,
    output  wire     [7:0]              o_cpld_tag              ,
    output  wire     [15:0]             o_cpld_requester_id     ,	
   //**********************************************************************		
   
    output  wire                        o_dma_wr_en             ,
    output  wire    [15:0]              o_dma_wr_byte_en        , 
    output  wire    [ADDR_WIDTH-1:0]    o_dma_wr_addr           ,
    output  wire    [127:0]             o_dma_wr_data           ,
    output  wire                        o_dma_rd_en             ,
    output  wire    [ADDR_WIDTH-1:0]    o_dma_rd_addr           ,
    input           [127:0]             i_dma_rd_data           ,  
	
    output  wire                        o_pio_wr_en             ,
    output  wire    [15:0]              o_pio_wr_byte_en        ,
    output  wire    [63:0]              o_pio_wr_addr           ,
    output  wire    [127:0]             o_pio_wr_data           ,
    output  wire                        o_pio_rd_en             ,
    output  wire    [63:0]              o_pio_rd_addr           ,
    input           [127:0]             i_pio_rd_data           ,
    // 20261018 ddr: DDR doorbell / BAR1 tap interface
    output  wire                        o_bar1_tap_vld          ,
    output  wire    [11:0]              o_bar1_tap_addr         ,
    output  wire    [31:0]              o_bar1_tap_data         ,
    output  wire                        o_mrd_start             ,
    output  wire                        o_mrd_done              ,
    output  wire                        o_db_ack                ,
    input                               i_db_req                ,
    input           [31:0]              i_db_addr               ,
    input           [19:0]              i_db_len_dw             ,
    input                               i_issue_hold            ,
    input                               i_start_block           ,
    input                               i_final_done_host       ,
    input           [127:0]             i_stat1c0               ,
    input           [127:0]             i_stat1d0               ,
    input           [127:0]             i_stat1e0               ,
    input           [127:0]             i_ext_rd_data           ,   // 20261018 disp:
    output  wire    [11:0]              o_ext_rd_addr               // 20261018 disp:
);
 
//mwr req & ack
wire                            mwr32_req;
wire                            mwr32_req_ack;
wire                            mwr64_req;
wire                            mwr64_req_ack;
//mrd req & ack
wire                            mrd32_req;
wire                            mrd32_req_ack;
wire                            mrd64_req;
wire                            mrd64_req_ack;
wire  [63:0]                    o_mem_addr ;
wire                            o_mrd_req_rdy;
wire  [19:0]                    mwr_ext_length;   // 20261018 ext:
// 20261018 mrd:
wire  [19:0]                    mrd_ext_length;
wire  [5:0]                     mrd_max_out;
wire                            mrd_abort;
wire                            tag_free_vld;
wire  [4:0]                     tag_free;
wire                            chunk_wr_en;
wire  [4:0]                     chunk_wr_tag;
wire  [15:0]                    chunk_wr_idx;
wire                            mrd_start;
wire                            mrd_done;    // 20261018 ddr:
wire                            db_ack;      // 20261018 ddr:
wire  [31:0]                    chk_seed;
wire  [191:0]                   chk_stat;

	
rt01_dma_rx u_rt01_dma_rx
(
    .clk                     (clk                    ),  //gen1:62.5MHz,gen2:125MHz
    .rst_n                   (rst_n                  ),
    .i_cfg_max_rd_req_size   (i_cfg_max_rd_req_size  ),  
    .i_cfg_max_payload_size  (i_cfg_max_payload_size ),
    //**********************************************************************
	.i_tlp_common_length     (i_tlp_common_length    ),
    .i_tlp_req_dwbe          (i_tlp_req_dwbe         ),
    .i_tlp_req_addr          (i_tlp_req_addr         ),
    .i_tlp_cpld_byte_cnt     (i_tlp_cpld_byte_cnt    ),
    .i_tlp_cpld_low_addr     (i_tlp_cpld_low_addr    ),	
	
    .i_bar_sel               (i_bar_sel              ),
    .i_mwr_req_en            (i_mwr_req_en           ),
    .i_mwr_req_data          (i_mwr_req_data         ),
    .i_mwr_req_dw_vld        (i_mwr_req_dw_vld       ),
    .i_mwr_req_en_flag       (i_mwr_req_en_flag      ),

    .i_cpld_tag              (i_tlp_cpld_tag         ),
    .i_cpld_en               (i_cpld_en              ),
    .i_cpld_data             (i_cpld_data            ),
	.i_cpld_dw_vld           (i_cpld_dw_vld          ),
    .i_cpld_en_flag          (i_cpld_en_flag         ),
    .i_cpld_multi_flag       (i_cpld_multi_flag      ),	
	
	//**********************************************************************
    .i_mwr32_req_ack         (mwr32_req_ack          ),
	.i_mwr64_req_ack         (mwr64_req_ack          ),
    .i_mrd32_req_ack         (mrd32_req_ack          ),
    .i_mrd64_req_ack         (mrd64_req_ack          ),
    .o_mwr32_req             (mwr32_req              ),
    .o_mwr64_req             (mwr64_req              ),
    .o_mrd32_req             (mrd32_req              ),
    .o_mrd64_req             (mrd64_req              ),
    .o_mwr_ext_length        (mwr_ext_length         ),   // 20261018 ext:
    .o_mrd_ext_length        (mrd_ext_length         ),   // 20261018 mrd:
    .o_mrd_max_out           (mrd_max_out            ),   // 20261018 mrd:
    .o_chk_seed              (chk_seed               ),   // 20261018 mrd:
    .o_mrd_abort             (mrd_abort              ),   // 20261018 mrd:
    .o_tag_free_vld          (tag_free_vld           ),   // 20261018 mrd:
    .o_tag_free              (tag_free               ),   // 20261018 mrd:
    .i_chunk_wr_en           (chunk_wr_en            ),   // 20261018 mrd:
    .i_chunk_wr_tag          (chunk_wr_tag           ),   // 20261018 mrd:
    .i_chunk_wr_idx          (chunk_wr_idx           ),   // 20261018 mrd:

    .o_mem_length            (o_mem_length           ),		
    .o_mem_addr              (o_mem_addr             ),	
	
	.o_mwr_ram_addr          (o_mwr_ram_addr         ),
	.o_mrd_ram_addr          (o_mrd_ram_addr         ),	
	
    //**********************************************************************	
	
	.o_dma_wr_en             (o_dma_wr_en            ),
    .o_dma_wr_byte_en        (o_dma_wr_byte_en       ), 
    .o_dma_wr_addr           (o_dma_wr_addr          ),
    .o_dma_wr_data           (o_dma_wr_data          ), 
    .o_pio_wr_en             (o_pio_wr_en            ),
    .o_pio_wr_byte_en        (o_pio_wr_byte_en       ),
    .o_pio_wr_addr           (o_pio_wr_addr          ),
    .o_pio_wr_data           (o_pio_wr_data          ),
    .o_bar1_tap_vld          (o_bar1_tap_vld         ),   // 20261018 ddr:
    .o_bar1_tap_addr         (o_bar1_tap_addr        ),   // 20261018 ddr:
    .o_bar1_tap_data         (o_bar1_tap_data        )    // 20261018 ddr:
);


rt02_dma_tx #(
    .ADDR_WIDTH             (ADDR_WIDTH             ),
	.RD_DATA_DELAY          (RD_DATA_DELAY          )   //receive rd_data delay clk cyle, support 1、2、3 clk cyle.
)                                                          
u_rt02_dma_tx                                            
( 
    .clk                        (clk                        ),  //gen1:62.5MHz,gen2:125MHz
    .rst_n                      (rst_n                      ),
    .i_cfg_pbus_num             (i_cfg_pbus_num             ),  
    .i_cfg_pbus_dev_num         (i_cfg_pbus_dev_num         ),
    .i_cfg_max_rd_req_size      (i_cfg_max_rd_req_size      ),  
    .i_cfg_max_payload_size     (i_cfg_max_payload_size     ),
    //**********************************************************************master
    .i_axis_slave0_trdy         (i_axis_slave0_trdy         ),
    .i_axis_slave0_tvld         (i_axis_slave0_tvld         ),
    .i_axis_slave0_tlast        (i_axis_slave0_tlast        ),
    .i_axis_slave1_trdy         (i_axis_slave1_trdy         ),
    .i_axis_slave1_tvld         (i_axis_slave1_tvld         ),
    .i_axis_slave1_tlast        (i_axis_slave1_tlast        ),
    .i_axis_slave2_trdy         (i_axis_slave2_trdy         ),
    .i_axis_slave2_tvld         (i_axis_slave2_tvld         ),
    .i_axis_slave2_tlast        (i_axis_slave2_tlast        ),	
	//**********************************************************************
		//other ctrl
    .i_cpld_finish              (i_cpld_finish              ),	
    .o_mwr_req_cmd              (o_mwr_req_cmd              ),	//mwr写指令来后，需要去开始读16in_16out_ram 1clk
    .i_mwr_tx_start             (i_mwr_tx_start             ),	//这个信号表示数据已经搬到16in_128out ram.可以开始mwr组包	 1clk
	
    //PIO to tx
    .i_bar_sel                  (i_bar_sel                  ),
	.i_mrd_tc                   (i_tlp_common_tc            ),
    .i_mrd_attr                 (i_tlp_common_attr          ),
    .i_mrd_length               (i_tlp_common_length        ),
    .i_mrd_id                   (i_tlp_req_requester_id     ),
    .i_mrd_tag                  (i_tlp_req_tag              ),
    .i_mrd_addr                 (i_tlp_req_addr             ),
	
	.i_mrd_req_vld              (i_mrd_req_en               ),	  //mrd_en
    .o_mrd_req_rdy              (o_mrd_req_rdy              ),
	
	//**********************************************************************
    .i_mwr32_req                (mwr32_req                  ),
    .i_mwr64_req                (mwr64_req                  ),
    .i_mrd32_req                (mrd32_req                  ),
    .i_mrd64_req                (mrd64_req                  ),
    .o_mwr32_req_ack            (mwr32_req_ack              ),
    .o_mwr64_req_ack            (mwr64_req_ack              ),
    .o_mrd32_req_ack            (mrd32_req_ack              ),
    .o_mrd64_req_ack            (mrd64_req_ack              ),

    .i_mem_length               (o_mem_length               ),
    .i_mem_addr                 (o_mem_addr                 ),
    .i_mwr_ext_length           (mwr_ext_length             ),   // 20261018 ext:
    .i_mrd_ext_length           (mrd_ext_length             ),   // 20261018 mrd:
    .i_mrd_max_out              (mrd_max_out                ),   // 20261018 mrd:
    .i_mrd_abort                (mrd_abort                  ),   // 20261018 mrd:
    .i_tag_free_vld             (tag_free_vld               ),   // 20261018 mrd:
    .i_tag_free                 (tag_free                   ),   // 20261018 mrd:
    .i_chk_stat                 (chk_stat                   ),   // 20261018 mrd:
    .o_chunk_wr_en              (chunk_wr_en                ),   // 20261018 mrd:
    .o_chunk_wr_tag             (chunk_wr_tag               ),   // 20261018 mrd:
    .o_chunk_wr_idx             (chunk_wr_idx               ),   // 20261018 mrd:
    .o_mrd_start                (mrd_start                  ),   // 20261018 mrd:
    .o_mrd_done                 (mrd_done                   ),   // 20261018 ddr:
    .i_db_req                   (i_db_req                   ),   // 20261018 ddr:
    .i_db_addr                  (i_db_addr                  ),   // 20261018 ddr:
    .i_db_len_dw                (i_db_len_dw                ),   // 20261018 ddr:
    .o_db_ack                   (db_ack                     ),   // 20261018 ddr:
    .i_issue_hold               (i_issue_hold               ),   // 20261018 ddr:
    .i_start_block              (i_start_block              ),   // 20261018 ddr:
    .i_final_done_host          (i_final_done_host          ),   // 20261018 ddr:
    .i_stat1c0                  (i_stat1c0                  ),   // 20261018 ddr:
    .i_stat1d0                  (i_stat1d0                  ),   // 20261018 ddr:
    .i_stat1e0                  (i_stat1e0                  ),   // 20261018 ddr:
    .i_ext_rd_data              (i_ext_rd_data              ),   // 20261018 disp:
    .o_ext_rd_addr              (o_ext_rd_addr              ),   // 20261018 disp:
	
    //to mwr
	.i_mwr_data_ready           (i_mwr_data_ready           ),
	.o_mwr_data_valid           (o_mwr_data_valid           ),
    .o_mwr_data                 (o_mwr_data                 ),
    .o_mwr_last_data_en         (o_mwr_last_data_en         ),
    .o_mwr_length               (o_mwr_length               ),
    .o_mwr_at                   (o_mwr_at                   ),
    .o_mwr_attr                 (o_mwr_attr                 ),
    .o_mwr_ep                   (o_mwr_ep                   ),
    .o_mwr_td                   (o_mwr_td                   ),
    .o_mwr_th                   (o_mwr_th                   ),
    .o_mwr_tc                   (o_mwr_tc                   ),
    .o_mwr_tlp_type             (o_mwr_tlp_type             ),
    .o_mwr_fmt                  (o_mwr_fmt                  ),
    .o_mwr_dwbe                 (o_mwr_dwbe                 ),
    .o_mwr_tag                  (o_mwr_tag                  ),
    .o_mwr_requester_id         (o_mwr_requester_id         ),
    .o_mwr_addr           	    (o_mwr_addr                 ),
    //to mrd
    .o_tx_mrd_en                (o_tx_mrd_en                ),
    .o_mrd_length               (o_mrd_length               ),
    .o_mrd_at                   (o_mrd_at                   ),
    .o_mrd_attr                 (o_mrd_attr                 ),
    .o_mrd_ep                   (o_mrd_ep                   ),
    .o_mrd_td                   (o_mrd_td                   ),
    .o_mrd_th                   (o_mrd_th                   ),
    .o_mrd_tc                   (o_mrd_tc                   ),
    .o_mrd_tlp_type             (o_mrd_tlp_type             ),
    .o_mrd_fmt                  (o_mrd_fmt                  ),
    .o_mrd_dwbe                 (o_mrd_dwbe                 ),
    .o_mrd_tag                  (o_mrd_tag                  ),
    .o_mrd_requester_id         (o_mrd_requester_id         ),
    .o_mrd_addr           	    (o_mrd_addr                 ),	
	//cpld
    .i_cpld_tx_data_ready       (i_cpld_tx_data_ready       ),	
    .o_cpld_tx_data_valid       (o_cpld_tx_data_valid       ),
    .o_cpld_tx_data             (o_cpld_tx_data             ),
    .o_cpld_tx_last_data_en     (o_cpld_tx_last_data_en     ),
    .o_cpld_length              (o_cpld_length              ),
    .o_cpld_at                  (o_cpld_at                  ),
    .o_cpld_attr                (o_cpld_attr                ),
    .o_cpld_ep                  (o_cpld_ep                  ),
    .o_cpld_td                  (o_cpld_td                  ),
    .o_cpld_th                  (o_cpld_th                  ),
    .o_cpld_tc                  (o_cpld_tc                  ),
    .o_cpld_tlp_type            (o_cpld_tlp_type            ),
    .o_cpld_fmt                 (o_cpld_fmt                 ),
    .o_cpld_byte_cnt            (o_cpld_byte_cnt            ),	
    .o_cpld_bcm                 (o_cpld_bcm                 ),
    .o_cpld_compl_status        (o_cpld_compl_status        ),
    .o_cpld_completer_id        (o_cpld_completer_id        ),
    .o_cpld_low_addr            (o_cpld_low_addr            ),
    .o_cpld_tag                 (o_cpld_tag                 ),
    .o_cpld_requester_id        (o_cpld_requester_id        ),		
	
    //**********************************************************************	
    .o_pio_rd_en                (o_pio_rd_en                ),
    .o_pio_rd_addr              (o_pio_rd_addr              ),
    .i_pio_rd_data              (i_pio_rd_data              ),
	.o_dma_rd_en                (o_dma_rd_en                ),
    .o_dma_rd_addr              (o_dma_rd_addr              ),
    .i_dma_rd_data              (i_dma_rd_data              )
);

// 20261018 mrd: online checker
rt_mrd_checker u_rt_mrd_checker
(
    .clk                        (clk                        ),
    .rst_n                      (rst_n                      ),
    .i_start                    (mrd_start                  ),
    .i_seed                     (chk_seed                   ),
    .i_wr_en                    (o_dma_wr_en                ),
    .i_wr_addr                  (o_dma_wr_addr[31:0]        ),
    .i_wr_data                  (o_dma_wr_data              ),
    .i_wr_be                    (o_dma_wr_byte_en           ),
    .o_stat                     (chk_stat                   )
);

assign o_axis_master_trdy = o_mrd_req_rdy;

assign o_mrd_start = mrd_start;   // 20261018 ddr:
assign o_mrd_done  = mrd_done;    // 20261018 ddr:
assign o_db_ack    = db_ack;      // 20261018 ddr:

endmodule


//////////////////////////////////////////////////////////////////////////////
// 20261018 mrd: online read data checker
// stat = {first_exp, first_data, first_idx, sum, beat_cnt, err_cnt}
module rt_mrd_checker
(
    input                       clk                     ,
    input                       rst_n                   ,
    input                       i_start                 ,
    input           [31:0]      i_seed                  ,
    input                       i_wr_en                 ,
    input           [31:0]      i_wr_addr               ,   //128bit word address
    input           [127:0]     i_wr_data               ,
    input           [15:0]      i_wr_be                 ,
    output  wire    [191:0]     o_stat
);

// stage 1
reg             s1_en;
reg     [31:0]  s1_addr;
reg     [127:0] s1_data;
reg     [15:0]  s1_be;

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
    begin
        s1_en   <= 1'b0;
        s1_addr <= 32'd0;
        s1_data <= 128'd0;
        s1_be   <= 16'd0;
    end
    else
    begin
        s1_en   <= i_wr_en;
        s1_addr <= i_wr_addr;
        s1_data <= i_wr_data;
        s1_be   <= i_wr_be;
    end
end

wire [31:0] s1_d0 = s1_data[31:0];
wire [31:0] s1_d1 = s1_data[63:32];
wire [31:0] s1_d2 = s1_data[95:64];
wire [31:0] s1_d3 = s1_data[127:96];

wire [31:0] idx0 = {s1_addr[29:0], 2'd0};
wire [31:0] idx1 = {s1_addr[29:0], 2'd1};
wire [31:0] idx2 = {s1_addr[29:0], 2'd2};
wire [31:0] idx3 = {s1_addr[29:0], 2'd3};

wire [31:0] exp0 = i_seed ^ idx0 ^ {idx0[15:0], 16'h0};
wire [31:0] exp1 = i_seed ^ idx1 ^ {idx1[15:0], 16'h0};
wire [31:0] exp2 = i_seed ^ idx2 ^ {idx2[15:0], 16'h0};
wire [31:0] exp3 = i_seed ^ idx3 ^ {idx3[15:0], 16'h0};

wire full0 = &s1_be[3:0];
wire full1 = &s1_be[7:4];
wire full2 = &s1_be[11:8];
wire full3 = &s1_be[15:12];

wire mis0 = full0 && (s1_d0 != exp0);
wire mis1 = full1 && (s1_d1 != exp1);
wire mis2 = full2 && (s1_d2 != exp2);
wire mis3 = full3 && (s1_d3 != exp3);

wire [31:0] sum01 = (full0 ? s1_d0 : 32'd0) + (full1 ? s1_d1 : 32'd0);
wire [31:0] sum23 = (full2 ? s1_d2 : 32'd0) + (full3 ? s1_d3 : 32'd0);

// stage 2
reg             s2_en;
reg     [3:0]   s2_mis;
reg     [31:0]  s2_sum01;
reg     [31:0]  s2_sum23;
reg     [31:0]  s2_first_idx;
reg     [31:0]  s2_first_data;
reg     [31:0]  s2_first_exp;

reg [31:0] s2_first_idx_comb;
reg [31:0] s2_first_data_comb;
reg [31:0] s2_first_exp_comb;

always@(*)
begin
    if(mis0)
    begin
        s2_first_idx_comb  = idx0;
        s2_first_data_comb = s1_d0;
        s2_first_exp_comb  = exp0;
    end
    else if(mis1)
    begin
        s2_first_idx_comb  = idx1;
        s2_first_data_comb = s1_d1;
        s2_first_exp_comb  = exp1;
    end
    else if(mis2)
    begin
        s2_first_idx_comb  = idx2;
        s2_first_data_comb = s1_d2;
        s2_first_exp_comb  = exp2;
    end
    else
    begin
        s2_first_idx_comb  = idx3;
        s2_first_data_comb = s1_d3;
        s2_first_exp_comb  = exp3;
    end
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
    begin
        s2_en         <= 1'b0;
        s2_mis        <= 4'd0;
        s2_sum01      <= 32'd0;
        s2_sum23      <= 32'd0;
        s2_first_idx  <= 32'd0;
        s2_first_data <= 32'd0;
        s2_first_exp  <= 32'd0;
    end
    else
    begin
        s2_en         <= s1_en;
        s2_mis        <= {mis3, mis2, mis1, mis0};
        s2_sum01      <= sum01;
        s2_sum23      <= sum23;
        s2_first_idx  <= s2_first_idx_comb;
        s2_first_data <= s2_first_data_comb;
        s2_first_exp  <= s2_first_exp_comb;
    end
end

wire [2:0] s2_mis_cnt = s2_mis[0] + s2_mis[1] + s2_mis[2] + s2_mis[3];

// stage 3
reg     [31:0]  err_cnt;
reg     [31:0]  beat_cnt;
reg     [31:0]  sum;
reg             have_err;
reg     [31:0]  first_idx;
reg     [31:0]  first_data;
reg     [31:0]  first_exp;

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
    begin
        err_cnt    <= 32'd0;
        beat_cnt   <= 32'd0;
        sum        <= 32'd0;
        have_err   <= 1'b0;
        first_idx  <= 32'hFFFFFFFF;
        first_data <= 32'd0;
        first_exp  <= 32'd0;
    end
    else if(i_start)
    begin
        err_cnt    <= 32'd0;
        beat_cnt   <= 32'd0;
        sum        <= 32'd0;
        have_err   <= 1'b0;
        first_idx  <= 32'hFFFFFFFF;
        first_data <= 32'd0;
        first_exp  <= 32'd0;
    end
    else if(s2_en)
    begin
        beat_cnt <= beat_cnt + 32'd1;
        err_cnt  <= err_cnt + {29'd0, s2_mis_cnt};
        sum      <= sum + s2_sum01 + s2_sum23;
        if(!have_err && (|s2_mis))
        begin
            have_err   <= 1'b1;
            first_idx  <= s2_first_idx;
            first_data <= s2_first_data;
            first_exp  <= s2_first_exp;
        end
    end
end

assign o_stat = {first_exp, first_data, first_idx, sum, beat_cnt, err_cnt};

endmodule
