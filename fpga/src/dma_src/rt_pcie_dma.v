

module rt_pcie_dma #(
    parameter                           ADDR_WIDTH     = 'd32,
    parameter                           RD_DATA_DELAY  = 'd1
)(
    input                               clk                     ,            //gen1:62.5MHz,gen2:125MHz
    input                               rst_n                   ,

    input           [7:0]               i_cfg_pbus_num          ,
    input           [4:0]               i_cfg_pbus_dev_num      ,
    input           [2:0]               i_cfg_max_rd_req_size   ,
    input           [2:0]               i_cfg_max_payload_size  ,
    //**********************************************************************
    //axis master interface
    input                               i_axis_master_tvld      ,
    output  wire                        o_axis_master_trdy      ,
    input           [127:0]             i_axis_master_tdata     ,
    input           [3:0]               i_axis_master_tkeep     ,
    input                               i_axis_master_tlast     ,
    input           [7:0]               i_axis_master_tuser     ,

    //**********************************************************************
    //axis_slave0 interface
    input                               i_axis_slave0_trdy      ,
    output  wire                        o_axis_slave0_tvld      ,
    output  wire    [127:0]             o_axis_slave0_tdata     ,
    output  wire                        o_axis_slave0_tlast     ,
    output  wire                        o_axis_slave0_tuser     ,
    //axis_slave1 interface
    input                               i_axis_slave1_trdy      ,
    output  wire                        o_axis_slave1_tvld      ,
    output  wire    [127:0]             o_axis_slave1_tdata     ,
    output  wire                        o_axis_slave1_tlast     ,
    output  wire                        o_axis_slave1_tuser     ,
    //axis_slave2 interface
    input                               i_axis_slave2_trdy      ,
    output  wire                        o_axis_slave2_tvld      ,
    output  wire    [127:0]             o_axis_slave2_tdata     ,
    output  wire                        o_axis_slave2_tlast     ,
    output  wire                        o_axis_slave2_tuser     ,
	
    //**********************************************************************
	//other ctrl
    input                               i_cpld_finish           ,   //is cpld write to ram finish
    output  wire                        o_mwr_req_cmd           ,	//mwr写指令来后，开始读16in_16out_ram
    input                               i_mwr_tx_start          ,	//这个信号表示数据已经搬到16in_128out ram.可以开始mwr组包
    output  wire    [31:0]              o_rd_base_ram_addr      ,	
    output  wire    [31:0]              o_wr_base_ram_addr      ,
    output  wire    [10:0]              o_mem_length            ,
    //**********************************************************************
    //////ram interface
	//pio write to ram
    output wire                         o_pio_wr_en             ,
    output wire    [15:0]               o_pio_wr_byte_en        ,
    output wire    [63:0]               o_pio_wr_addr           ,
    output wire    [127:0]              o_pio_wr_data           ,
    //pio read from ram 
    output  wire                        o_pio_rd_en             ,
	output  wire   [63:0]               o_pio_rd_addr           ,
    input   wire   [127:0]              i_pio_rd_data           ,
	
    //dma cpld write to ram
    output wire                         o_dma_wr_en             ,
    output wire    [15:0]               o_dma_wr_byte_en        ,
    output wire    [ADDR_WIDTH-1:0]     o_dma_wr_addr           ,
    output wire    [127:0]              o_dma_wr_data           ,
	//dma mwr read from ram	
	output  wire                        o_dma_rd_en             ,
	output  wire   [ADDR_WIDTH-1:0]     o_dma_rd_addr           ,
    input   wire   [127:0]              i_dma_rd_data           ,
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

//**********************************************************************
//tlp
wire  [9:0]                 tlp_common_length       ;
wire  [1:0]                 tlp_common_at           ;
wire  [2:0]                 tlp_common_attr         ;
wire                        tlp_common_ep           ;
wire                        tlp_common_td           ;
wire                        tlp_common_th           ;
wire  [2:0]                 tlp_common_tc           ;
wire  [4:0]                 tlp_common_type         ;
wire  [2:0]                 tlp_common_fmt          ;

wire  [7:0]                 tlp_req_dwbe            ;
wire  [7:0]                 tlp_req_tag             ;
wire  [15:0]                tlp_req_requester_id    ;	
wire  [63:0]                tlp_req_addr            ;

wire  [11:0]                tlp_cpld_byte_cnt       ;   //还要获得多少数据才能完成全部数据传递
wire                        tlp_cpld_bcm            ;   	
wire  [2:0]                 tlp_cpld_status         ;
wire  [15:0]                tlp_cpld_completer_id   ;
wire  [6:0]                 tlp_cpld_low_addr       ;   //TLP中数据的起始地址
wire  [7:0]                 tlp_cpld_tag            ;	
wire  [15:0]                tlp_cpld_requester_id   ;
//*****************************************************************
wire  [2:0]                 bar_sel                 ;	
                                                    
wire                        req_mrd_en              ;   //mrd_en 数据使能	
wire                        req_mwr_en              ;   //mwr_en 数据使能
wire  [127:0]               req_mwr_data            ;
wire  [3:0]                 req_mwr_dw_vld          ;
wire                        req_mwr_en_flag         ;
wire                        cpld_en                 ;
wire  [127:0]               cpld_data               ;	
wire  [3:0]                 cpld_dw_vld             ;
wire                        cpld_en_flag            ;
wire                        cpld_multi_flag         ; 
//////////////////////////////////////////////////////////
//to mwr	
wire                        mwr_data_ready        ;
wire                        mwr_data_valid        ;
wire    [127:0]             mwr_data              ;
wire                        mwr_last_data_en      ;
wire    [9:0]               mwr_length            ;
wire    [1:0]               mwr_at                ;
wire    [2:0]               mwr_attr              ;
wire                        mwr_ep                ;
wire                        mwr_td                ;
wire                        mwr_th                ;
wire    [2:0]               mwr_tc                ;
wire    [4:0]               mwr_tlp_type          ;
wire    [2:0]               mwr_fmt               ;
wire    [7:0]               mwr_dwbe              ;
wire    [7:0]               mwr_tag               ;
wire    [15:0]              mwr_requester_id      ;
wire    [63:0]              mwr_addr           	  ;
//to mrd	
wire                        tx_mrd_en             ;	
wire    [9:0]               mrd_length            ;
wire    [1:0]               mrd_at                ;
wire    [2:0]               mrd_attr              ;
wire                        mrd_ep                ;
wire                        mrd_td                ;
wire                        mrd_th                ;
wire    [2:0]               mrd_tc                ;
wire    [4:0]               mrd_tlp_type          ;
wire    [2:0]               mrd_fmt               ;
wire    [7:0]               mrd_dwbe              ;
wire    [7:0]               mrd_tag               ;
wire    [15:0]              mrd_requester_id      ;
wire    [63:0]              mrd_addr              ;
//cpld
wire                        cpld_tx_data_valid    ;
wire                        cpld_tx_data_ready    ;
wire     [127:0]            cpld_tx_data          ;
wire                        cpld_tx_last_data_en  ;
wire     [9:0]              cpld_length           ;
wire     [1:0]              cpld_at               ;
wire     [2:0]              cpld_attr             ;
wire                        cpld_ep               ;
wire                        cpld_td               ;
wire                        cpld_th               ;
wire     [2:0]              cpld_tc               ;
wire     [4:0]              cpld_tlp_type         ;
wire     [2:0]              cpld_fmt              ;
wire     [11:0]             cpld_byte_cnt         ;	
wire                        cpld_bcm              ;
wire     [2:0]              cpld_compl_status     ;
wire     [15:0]             cpld_completer_id     ;
wire     [6:0]              cpld_low_addr         ;
wire     [7:0]              cpld_tag              ;
wire     [15:0]             cpld_requester_id     ;


rt_dma #(
    .ADDR_WIDTH             (ADDR_WIDTH             ),
	.RD_DATA_DELAY          (RD_DATA_DELAY          )   //receive rd_data delay clk cyle, support 1、2、3 clk cyle.
)
u_rt_dma
(
    .clk                        (clk                        ),  //gen1:62.5MHz,gen2:125MHz
    .rst_n                      (rst_n                      ),
    .i_cfg_pbus_num             (i_cfg_pbus_num             ),  //input [7:0]
    .i_cfg_pbus_dev_num         (i_cfg_pbus_dev_num         ),  //input [4:0]
    .i_cfg_max_rd_req_size      (i_cfg_max_rd_req_size      ),  //input [2:0]
    .i_cfg_max_payload_size     (i_cfg_max_payload_size     ),  //input [2:0]
    //**********************************************************************
	.o_axis_master_trdy         (o_axis_master_trdy         ),
    .i_axis_slave0_trdy         (i_axis_slave0_trdy         ),
    .i_axis_slave0_tvld         (o_axis_slave0_tvld         ),
    .i_axis_slave0_tlast        (o_axis_slave0_tlast        ),
    .i_axis_slave1_trdy         (i_axis_slave1_trdy         ),
    .i_axis_slave1_tvld         (o_axis_slave1_tvld         ),
    .i_axis_slave1_tlast        (o_axis_slave1_tlast        ),
    .i_axis_slave2_trdy         (i_axis_slave2_trdy         ),
    .i_axis_slave2_tvld         (o_axis_slave2_tvld         ),
    .i_axis_slave2_tlast        (o_axis_slave2_tlast        ),
    //**********************************************************************
	//other ctrl
    .i_cpld_finish              (i_cpld_finish              ),	
    .o_mwr_req_cmd              (o_mwr_req_cmd              ),	//mwr写指令来后，需要去开始读16in_16out_ram
    .i_mwr_tx_start             (i_mwr_tx_start             ),	//这个信号表示数据已经搬到16in_128out ram.可以开始mwr组包	
    .o_mwr_ram_addr             (o_rd_base_ram_addr         ),	//存储器写操作。从这个地址读取ram_16in_16out	
    .o_mrd_ram_addr             (o_wr_base_ram_addr         ),	//存储器读操作。接收CplD数据，写入ram_16in_16out 
    .o_mem_length               (o_mem_length               ),
	
    //**********************************************************************
    .i_tlp_common_length        (tlp_common_length         ),
    .i_tlp_common_at            (tlp_common_at             ),
	.i_tlp_common_attr          (tlp_common_attr           ),
	.i_tlp_common_ep            (tlp_common_ep             ),
	.i_tlp_common_td            (tlp_common_td             ),
	.i_tlp_common_th            (tlp_common_th             ),
    .i_tlp_common_tc            (tlp_common_tc             ),
    .i_tlp_common_type          (tlp_common_type           ),
    .i_tlp_common_fmt           (tlp_common_fmt            ),

    .i_tlp_req_dwbe             (tlp_req_dwbe              ),
    .i_tlp_req_tag              (tlp_req_tag               ),
    .i_tlp_req_requester_id     (tlp_req_requester_id      ),	
    .i_tlp_req_addr             (tlp_req_addr              ),

    .i_tlp_cpld_byte_cnt        (tlp_cpld_byte_cnt         ),   //还要获得多少数据才能完成全部数据传递
    .i_tlp_cpld_bcm             (tlp_cpld_bcm              ),   	
    .i_tlp_cpld_status          (tlp_cpld_status           ),
    .i_tlp_cpld_completer_id    (tlp_cpld_completer_id     ),
    .i_tlp_cpld_low_addr        (tlp_cpld_low_addr         ),   //TLP中数据的起始地址
    .i_tlp_cpld_tag             (tlp_cpld_tag              ),	
    .i_tlp_cpld_requester_id    (tlp_cpld_requester_id     ),

	.i_bar_sel                  (bar_sel                   ),	
    .i_mrd_req_en               (req_mrd_en                ),   //mrd_en 数据使能	
    .i_mwr_req_en               (req_mwr_en                ),   //mwr_en 数据使能
    .i_mwr_req_data             (req_mwr_data              ),
    .i_mwr_req_dw_vld           (req_mwr_dw_vld            ),
    .i_mwr_req_en_flag          (req_mwr_en_flag           ),
    .i_cpld_en                  (cpld_en                   ),
    .i_cpld_data                (cpld_data                 ),
    .i_cpld_dw_vld              (cpld_dw_vld               ),
    .i_cpld_en_flag             (cpld_en_flag              ),
    .i_cpld_multi_flag          (cpld_multi_flag           ), 
	
    //**********************************************************************	
    //to mwr
	.i_mwr_data_ready           (mwr_data_ready             ),
	.o_mwr_data_valid           (mwr_data_valid             ),
    .o_mwr_data                 (mwr_data                   ),
    .o_mwr_last_data_en         (mwr_last_data_en           ),
    .o_mwr_length               (mwr_length                 ),
    .o_mwr_at                   (mwr_at                     ),
    .o_mwr_attr                 (mwr_attr                   ),
    .o_mwr_ep                   (mwr_ep                     ),
    .o_mwr_td                   (mwr_td                     ),
    .o_mwr_th                   (mwr_th                     ),
    .o_mwr_tc                   (mwr_tc                     ),
    .o_mwr_tlp_type             (mwr_tlp_type               ),
    .o_mwr_fmt                  (mwr_fmt                    ),
    .o_mwr_dwbe                 (mwr_dwbe                   ),
    .o_mwr_tag                  (mwr_tag                    ),
    .o_mwr_requester_id         (mwr_requester_id           ),
    .o_mwr_addr           	    (mwr_addr                   ),
    //to mrd                                                
    .o_tx_mrd_en                (tx_mrd_en                  ),
    .o_mrd_length               (mrd_length                 ),
    .o_mrd_at                   (mrd_at                     ),
    .o_mrd_attr                 (mrd_attr                   ),
    .o_mrd_ep                   (mrd_ep                     ),
    .o_mrd_td                   (mrd_td                     ),
    .o_mrd_th                   (mrd_th                     ),
    .o_mrd_tc                   (mrd_tc                     ),
    .o_mrd_tlp_type             (mrd_tlp_type               ),
    .o_mrd_fmt                  (mrd_fmt                    ),
    .o_mrd_dwbe                 (mrd_dwbe                   ),
    .o_mrd_tag                  (mrd_tag                    ),
    .o_mrd_requester_id         (mrd_requester_id           ),
    .o_mrd_addr           	    (mrd_addr                   ),	
	//cpld    
    .i_cpld_tx_data_ready       (cpld_tx_data_ready         ),	
    .o_cpld_tx_data_valid       (cpld_tx_data_valid         ),
    .o_cpld_tx_data             (cpld_tx_data               ),
    .o_cpld_tx_last_data_en     (cpld_tx_last_data_en       ),
    .o_cpld_length              (cpld_length                ),
    .o_cpld_at                  (cpld_at                    ),
    .o_cpld_attr                (cpld_attr                  ),
    .o_cpld_ep                  (cpld_ep                    ),
    .o_cpld_td                  (cpld_td                    ),
    .o_cpld_th                  (cpld_th                    ),
    .o_cpld_tc                  (cpld_tc                    ),
    .o_cpld_tlp_type            (cpld_tlp_type              ),
    .o_cpld_fmt                 (cpld_fmt                   ),
    .o_cpld_byte_cnt            (cpld_byte_cnt              ),	
    .o_cpld_bcm                 (cpld_bcm                   ),
    .o_cpld_compl_status        (cpld_compl_status          ),
    .o_cpld_completer_id        (cpld_completer_id          ),
    .o_cpld_low_addr            (cpld_low_addr              ),
    .o_cpld_tag                 (cpld_tag                   ),
    .o_cpld_requester_id        (cpld_requester_id          ),		
	
    //**********************************************************************
	.o_dma_wr_en               (o_dma_wr_en                 ),
    .o_dma_wr_byte_en          (o_dma_wr_byte_en            ), 
    .o_dma_wr_addr             (o_dma_wr_addr               ),
    .o_dma_wr_data             (o_dma_wr_data               ),
	.o_dma_rd_en               (o_dma_rd_en                 ),
    .o_dma_rd_addr             (o_dma_rd_addr               ),
    .i_dma_rd_data             (i_dma_rd_data               ),
	                                                        
    .o_pio_wr_en               (o_pio_wr_en                 ),
    .o_pio_wr_byte_en          (o_pio_wr_byte_en            ),
    .o_pio_wr_addr             (o_pio_wr_addr               ),
    .o_pio_wr_data             (o_pio_wr_data               ),
    .o_pio_rd_en               (o_pio_rd_en                 ),
    .o_pio_rd_addr             (o_pio_rd_addr               ),
    .i_pio_rd_data             (i_pio_rd_data               ),

    // 20261018 ddr: DDR doorbell / BAR1 tap interface
    .o_bar1_tap_vld            (o_bar1_tap_vld              ),   // 20261018 ddr:
    .o_bar1_tap_addr           (o_bar1_tap_addr             ),   // 20261018 ddr:
    .o_bar1_tap_data           (o_bar1_tap_data             ),   // 20261018 ddr:
    .o_mrd_start               (o_mrd_start                 ),   // 20261018 ddr:
    .o_mrd_done                (o_mrd_done                  ),   // 20261018 ddr:
    .o_db_ack                  (o_db_ack                    ),   // 20261018 ddr:
    .i_db_req                  (i_db_req                    ),   // 20261018 ddr:
    .i_db_addr                 (i_db_addr                   ),   // 20261018 ddr:
    .i_db_len_dw               (i_db_len_dw                 ),   // 20261018 ddr:
    .i_issue_hold              (i_issue_hold                ),   // 20261018 ddr:
    .i_start_block             (i_start_block               ),   // 20261018 ddr:
    .i_final_done_host         (i_final_done_host           ),   // 20261018 ddr:
    .i_stat1c0                 (i_stat1c0                   ),   // 20261018 ddr:
    .i_stat1d0                 (i_stat1d0                   ),   // 20261018 ddr:
    .i_stat1e0                 (i_stat1e0                   ),   // 20261018 ddr:
    .i_ext_rd_data             (i_ext_rd_data               ),   // 20261018 disp:
    .o_ext_rd_addr             (o_ext_rd_addr               )    // 20261018 disp:

);


rt_bridge_top u_rt_bridge_top
(
    .clk                        (clk                       ),            
    .rst_n                      (rst_n                     ),

    .i_axis_master_tvld         (i_axis_master_tvld        ),
    .i_axis_master_trdy         (o_axis_master_trdy        ),
    .i_axis_master_tdata        (i_axis_master_tdata       ),
    .i_axis_master_tkeep        (i_axis_master_tkeep       ),
    .i_axis_master_tlast        (i_axis_master_tlast       ),
    .i_axis_master_tuser        (i_axis_master_tuser       ),

    .o_tlp_common_length        (tlp_common_length         ),
    .o_tlp_common_at            (tlp_common_at             ),
	.o_tlp_common_attr          (tlp_common_attr           ),
	.o_tlp_common_ep            (tlp_common_ep             ),
	.o_tlp_common_td            (tlp_common_td             ),
	.o_tlp_common_th            (tlp_common_th             ),
    .o_tlp_common_tc            (tlp_common_tc             ),
    .o_tlp_common_type          (tlp_common_type           ),
    .o_tlp_common_fmt           (tlp_common_fmt            ),
                                                           
    .o_tlp_req_dwbe             (tlp_req_dwbe              ),
    .o_tlp_req_tag              (tlp_req_tag               ),
    .o_tlp_req_requester_id     (tlp_req_requester_id      ),	
    .o_tlp_req_addr             (tlp_req_addr              ),
                                                           
    .o_tlp_cpld_byte_cnt        (tlp_cpld_byte_cnt         ),   //还要获得多少数据才能完成全部数据传递
    .o_tlp_cpld_bcm             (tlp_cpld_bcm              ),   	
    .o_tlp_cpld_status          (tlp_cpld_status           ),
    .o_tlp_cpld_completer_id    (tlp_cpld_completer_id     ),
    .o_tlp_cpld_low_addr        (tlp_cpld_low_addr         ),   //TLP中数据的起始地址
    .o_tlp_cpld_tag             (tlp_cpld_tag              ),	
    .o_tlp_cpld_requester_id    (tlp_cpld_requester_id     ),

	.o_bar_sel                  (bar_sel                   ),	
    .o_req_mrd_en               (req_mrd_en                ),   //mrd_en 数据使能	
    .o_req_mwr_en               (req_mwr_en                ),   //mwr_en 数据使能
    .o_req_mwr_data             (req_mwr_data              ),
    .o_req_mwr_dw_vld           (req_mwr_dw_vld            ),
    .o_req_mwr_en_flag          (req_mwr_en_flag           ),
    .o_cpld_en                  (cpld_en                   ),
    .o_cpld_data                (cpld_data                 ),
    .o_cpld_dw_vld              (cpld_dw_vld               ),
    .o_cpld_en_flag             (cpld_en_flag              ),
    .o_cpld_multi_flag          (cpld_multi_flag           ),   
	
    //*********************************************************************tx 
    //mwr	
    .i_mwr_data_valid           (mwr_data_valid            ),
	.o_mwr_data_ready           (mwr_data_ready            ),
    .i_mwr_data                 (mwr_data                  ),
    .i_mwr_last_data_en         (mwr_last_data_en          ),
	.i_mwr_length               (mwr_length                ),
    .i_mwr_at                   (mwr_at                    ),
    .i_mwr_attr                 (mwr_attr                  ),
    .i_mwr_ep                   (mwr_ep                    ),
    .i_mwr_td                   (mwr_td                    ),
    .i_mwr_th                   (mwr_th                    ),
    .i_mwr_tc                   (mwr_tc                    ),
    .i_mwr_tlp_type             (mwr_tlp_type              ),
    .i_mwr_fmt                  (mwr_fmt                   ),
    .i_mwr_dwbe                 (mwr_dwbe                  ),
    .i_mwr_tag                  (mwr_tag                   ),
    .i_mwr_requester_id         (mwr_requester_id          ),
    .i_mwr_addr                 (mwr_addr                  ),
    .i_axis_slave2_trdy         (i_axis_slave2_trdy        ),
    .o_axis_slave2_tvld         (o_axis_slave2_tvld        ),
    .o_axis_slave2_tdata        (o_axis_slave2_tdata       ),
    .o_axis_slave2_tlast        (o_axis_slave2_tlast       ),
    .o_axis_slave2_tuser        (o_axis_slave2_tuser       ),
    //mrd
    .i_tx_mrd_en                (tx_mrd_en                 ),
	.i_mrd_length               (mrd_length                ),
    .i_mrd_at                   (mrd_at                    ),
    .i_mrd_attr                 (mrd_attr                  ),
    .i_mrd_ep                   (mrd_ep                    ),
    .i_mrd_td                   (mrd_td                    ),
    .i_mrd_th                   (mrd_th                    ),
    .i_mrd_tc                   (mrd_tc                    ),
    .i_mrd_tlp_type             (mrd_tlp_type              ),
    .i_mrd_fmt                  (mrd_fmt                   ),
    .i_mrd_dwbe                 (mrd_dwbe                  ),
    .i_mrd_tag                  (mrd_tag                   ),
    .i_mrd_requester_id         (mrd_requester_id          ),
    .i_mrd_addr                 (mrd_addr                  ),
    .i_axis_slave1_trdy         (i_axis_slave1_trdy        ),
    .o_axis_slave1_tvld         (o_axis_slave1_tvld        ),
    .o_axis_slave1_tdata        (o_axis_slave1_tdata       ),
    .o_axis_slave1_tlast        (o_axis_slave1_tlast       ),
    .o_axis_slave1_tuser        (o_axis_slave1_tuser       ),
    //cpld
    .i_cpld_tx_data_valid       (cpld_tx_data_valid        ),
    .o_cpld_tx_data_ready       (cpld_tx_data_ready        ),
    .i_cpld_tx_data             (cpld_tx_data              ),
    .i_cpld_tx_last_data_en     (cpld_tx_last_data_en      ),
    .i_cpld_length              (cpld_length               ),
    .i_cpld_at                  (cpld_at                   ),
    .i_cpld_attr                (cpld_attr                 ),
    .i_cpld_ep                  (cpld_ep                   ),
    .i_cpld_td                  (cpld_td                   ),
    .i_cpld_th                  (cpld_th                   ),
    .i_cpld_tc                  (cpld_tc                   ),
    .i_cpld_tlp_type            (cpld_tlp_type             ),
    .i_cpld_fmt                 (cpld_fmt                  ),
    .i_cpld_byte_cnt            (cpld_byte_cnt             ),	
    .i_cpld_bcm                 (cpld_bcm                  ),
    .i_cpld_compl_status        (cpld_compl_status         ),
    .i_cpld_completer_id        (cpld_completer_id         ),
    .i_cpld_low_addr            (cpld_low_addr             ),
    .i_cpld_tag                 (cpld_tag                  ),
    .i_cpld_requester_id        (cpld_requester_id         ),	
    .i_axis_slave0_trdy         (i_axis_slave0_trdy        ),
    .o_axis_slave0_tvld         (o_axis_slave0_tvld        ),
    .o_axis_slave0_tdata        (o_axis_slave0_tdata       ),
    .o_axis_slave0_tlast        (o_axis_slave0_tlast       ),
    .o_axis_slave0_tuser        (o_axis_slave0_tuser       ) 
);

endmodule
