
//////////////////////////////////////////////////////////////////////////////
//
// Library:
// Filename:pango_pcie_top_tb.v
//////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
`define  IPS2L_PCIE_SPEEDUP_SIM
`define  IPM_HSST_SPEEDUP_SIM
module pango_pcie_top_tb;
    reg                 button_rst_n;
    reg                 perst_n;
    //clk and rst
    reg                 ref_clk_n;
    wire                ref_clk_p;
    //rc
    wire                rc_smlh_link_up;
    wire                rc_rdlh_link_up;

    //ep
    wire                ep_smlh_link_up;
    wire                ep_rdlh_link_up;

//difference signals

    // wire                rc_rxn;
    // wire                rc_rxp;
    // wire                rc_txn;
    // wire                rc_txp;
    // initial
        // $display("x1 tb");
		
    wire    [3:0]       rc_rxn;
    wire    [3:0]       rc_rxp;
    wire    [3:0]       rc_txn;
    wire    [3:0]       rc_txp;
    initial
        $display("tb");


//***************************************DUT*****************************
pango_pcie_top_sim

#(
    .APP_DEV_NUM        (0                  ),      // set device_number
    .APP_BUS_NUM        (0                  )       // set bus_number
)
u_pango_pcie_top_rc (

    .button_rst_n       (button_rst_n       ),
    .perst_n            (button_rst_n       ),
    //UART interface
    .txd                (                   ),
    .rxd                (                   ),
    //clk and rst
    .ref_clk_n          (ref_clk_n          ),      //100 Mhz
    .ref_clk_p          (ref_clk_p          ),      //100 Mhz
    //clock out
    //diff signals
    .rxn                (rc_rxn             ),
    .rxp                (rc_rxp             ),
    .txn                (rc_txn             ),
    .txp                (rc_txp             ),
    //LED signals
    .ref_led            (ref_led            ),
    .pclk_led           (pclk_led           ),
    .smlh_link_up       (rc_smlh_link_up    ),
    .rdlh_link_up       (rc_rdlh_link_up    )
);



pango_pcie_dma_top

u_pango_pcie_top_ep (

    .button_rst_n       (button_rst_n       ),
    .perst_n            (button_rst_n       ),
    //UART interface
    .txd                (                   ),
    .rxd                (                   ),
    //clk and rst
    .ref_clk_n          (ref_clk_n          ),      //100 Mhz
    .ref_clk_p          (ref_clk_p          ),      //100 Mhz
    //clock out
    //diff signals
    .rxn                (rc_txn             ),
    .rxp                (rc_txp             ),
    .txn                (rc_rxn             ),
    .txp                (rc_rxp             ),
    //LED signals
    .ref_led            (ref_led            ),
    .pclk_led           (pclk_led           ),
    .smlh_link_up       (ep_smlh_link_up    ),
    .rdlh_link_up       (ep_rdlh_link_up    )
);

GTP_GRS GRS_INST    (.GRS_N(1'b1)) ;

always #5 ref_clk_n = ~ref_clk_n;

assign    ref_clk_p = ~ref_clk_n;

initial
begin
    button_rst_n    = 1'b0;
    ref_clk_n       = 1'b0;
    //APB interface
    #100
    button_rst_n    = 1'b1;

    force pango_pcie_top_tb.u_pango_pcie_top_rc.uart_p_addr       = 16'h0;
    force pango_pcie_top_tb.u_pango_pcie_top_rc.uart_p_sel        = 1'b0;
    force pango_pcie_top_tb.u_pango_pcie_top_rc.uart_p_strb       = 4'h0;
    force pango_pcie_top_tb.u_pango_pcie_top_rc.uart_p_ce         = 1'b0;
    force pango_pcie_top_tb.u_pango_pcie_top_rc.uart_p_we         = 1'b0;
    force pango_pcie_top_tb.u_pango_pcie_top_rc.uart_p_wdata      = 32'h0;
	
//PCIE_CTRL
    #100
        wait(|pango_pcie_top_tb.u_pango_pcie_top_ep.u_ips2l_pcie_wrap.U_IPS2L_PCIE_TOP.U_IPS2L_HSSTLP_PCIE_SOFT_PHY.hsst_ch_ready[3:0])
            $display ("hsst rst done!");
        wait(pango_pcie_top_tb.u_pango_pcie_top_ep.u_ips2l_pcie_wrap.U_IPS2L_PCIE_TOP.U_IPS2L_PCIE_HARD_CTRL.app_ltssm_enable)
            $display ("ltssm enable!");
        wait(rc_rdlh_link_up)
            $display ("PCIe link up!");
        #1000
        wait(pango_pcie_top_tb.u_pango_pcie_top_rc.smlh_ltssm_state[4:0] == 5'h11)
        if (pango_pcie_top_tb.u_pango_pcie_top_ep.u_ips2l_pcie_wrap.U_IPS2L_PCIE_TOP.mac_phy_rate == 1'b1)
            $display ("link rate is 5.0GT/S");
        else
            $display ("link rate is 2.5GT/S");

            $display ("cfg start!");

			
			
		
        #1000
        //rc cfg ep bar
//--------------------CFG read-------------------------------
        //cfg_ctrl_en enable
                rc_apb_write(16'h9008,32'h0100_0000,4'b1000);
        #5000   //cfg wr type 0
                rc_apb_write(16'h9000,32'h0000_003c,4'b0001);
        // BAR0
        #1000   //reg num 4 BAR0
                rc_apb_write(16'h9008,32'h0000_0002,4'b0001);
                //tag 0
                rc_apb_write(16'h9000,32'h0000_0000,4'b0010);
                //tx_en 1
                rc_apb_write(16'h9000,32'h0100_0000,4'b1000);
                //tx_en 0
                rc_apb_write(16'h9000,32'h0000_0000,4'b1000);
         // BAR0
        #1000   //reg num 4 BAR0
                rc_apb_write(16'h9008,32'h0000_0004,4'b0001);
                //tag 0
                rc_apb_write(16'h9000,32'h0000_0000,4'b0010);
                //tx_en 1
                rc_apb_write(16'h9000,32'h0100_0000,4'b1000);
                //tx_en 0
                rc_apb_write(16'h9000,32'h0000_0000,4'b1000);
        //BAR1
        #1000   //reg num 5 BAR1
                rc_apb_write(16'h9008,32'h0000_0005,4'b0001);
                //tag 1
                rc_apb_write(16'h9000,32'h0000_0100,4'b0010);
                //tx_en 1
                rc_apb_write(16'h9000,32'h0100_0000,4'b1000);
                //tx_en 0
                rc_apb_write(16'h9000,32'h0000_0000,4'b1000);
        //BAR2
        #1000   //reg num 6 BAR2
                rc_apb_write(16'h9008,32'h0000_0006,4'b0001);
                //tag 2
                rc_apb_write(16'h9000,32'h0000_0200,4'b0010);
                //tx_en 1
                rc_apb_write(16'h9000,32'h0100_0000,4'b1000);
                //tx_en 0
                rc_apb_write(16'h9000,32'h0000_0000,4'b1000);
        //BAR3
        #1000   //reg num 7 BAR3
                rc_apb_write(16'h9008,32'h0000_0007,4'b0001);
                //tag 3
                rc_apb_write(16'h9000,32'h0000_0300,4'b0010);
                //tx_en 1
                rc_apb_write(16'h9000,32'h0100_0000,4'b1000);
                //tx_en 0
                rc_apb_write(16'h9000,32'h0000_0000,4'b1000);
        //BAR4
        #1000   //reg num 8 BAR4
                rc_apb_write(16'h9008,32'h0000_0008,4'b0001);
                //tag 4
                rc_apb_write(16'h9000,32'h0000_0400,4'b0010);
                //tx_en 1
                rc_apb_write(16'h9000,32'h0100_0000,4'b1000);
                //tx_en 0
                rc_apb_write(16'h9000,32'h0000_0000,4'b1000);
        //BAR5
        #1000   //reg num 8 BAR5
                rc_apb_write(16'h9008,32'h0000_0009,4'b0001);
                //tag 5
                rc_apb_write(16'h9000,32'h0000_0500,4'b0010);
                //tx_en 1
                rc_apb_write(16'h9000,32'h0100_0000,4'b1000);
                //tx_en 0
                rc_apb_write(16'h9000,32'h0000_0000,4'b1000);
        $display ("CFG Read Done!");
//--------------------CFG write all 1------------------------
        //cfgwr all 1
        #5000
                rc_apb_write(16'h9008,32'h0100_0000,4'b1000);
                //cfg wr type 0
                rc_apb_write(16'h9000,32'h0000_003d,4'b0001);
                //des id bus 1 dev0 fun 0
                rc_apb_write(16'h9004,32'h0100_0000,4'b1000);
                //wr data all 1
                rc_apb_write(16'h900c,32'hffff_ffff,4'b1111);
        // BAR0
        #1000   //reg num 4 BAR0
                rc_apb_write(16'h9008,32'h0000_0004,4'b0001);
                //tag 0
                rc_apb_write(16'h9000,32'h0000_0000,4'b0010);
                //tx_en 1
                rc_apb_write(16'h9000,32'h0100_0000,4'b1000);
                //tx_en 0
                rc_apb_write(16'h9000,32'h0000_0000,4'b1000);
        //BAR1
        #1000   //reg num 5 BAR1
                rc_apb_write(16'h9008,32'h0000_0005,4'b0001);
                //tag 1
                rc_apb_write(16'h9000,32'h0000_0100,4'b0010);
                //tx_en 1
                rc_apb_write(16'h9000,32'h0100_0000,4'b1000);
                //tx_en 0
                rc_apb_write(16'h9000,32'h0000_0000,4'b1000);
        //BAR2
        #1000   //reg num 6 BAR2
                rc_apb_write(16'h9008,32'h0000_0006,4'b0001);
                //tag 2
                rc_apb_write(16'h9000,32'h0000_0200,4'b0010);
                //tx_en 1
                rc_apb_write(16'h9000,32'h0100_0000,4'b1000);
                //tx_en 0
                rc_apb_write(16'h9000,32'h0000_0000,4'b1000);
        //BAR3
        #1000   //reg num 7 BAR3
                rc_apb_write(16'h9008,32'h0000_0007,4'b0001);
                //tag 3
                rc_apb_write(16'h9000,32'h0000_0300,4'b0010);
                //tx_en 1
                rc_apb_write(16'h9000,32'h0100_0000,4'b1000);
                //tx_en 0
                rc_apb_write(16'h9000,32'h0000_0000,4'b1000);
        //BAR4
        #1000   //reg num 8 BAR4
                rc_apb_write(16'h9008,32'h0000_0008,4'b0001);
                //tag 4
                rc_apb_write(16'h9000,32'h0000_0400,4'b0010);
                //tx_en 1
                rc_apb_write(16'h9000,32'h0100_0000,4'b1000);
                //tx_en 0
                rc_apb_write(16'h9000,32'h0000_0000,4'b1000);
        //BAR5
        #1000   //reg num 8 BAR5
                rc_apb_write(16'h9008,32'h0000_0009,4'b0001);
                //tag 5
                rc_apb_write(16'h9000,32'h0000_0500,4'b0010);
                //tx_en 1
                rc_apb_write(16'h9000,32'h0100_0000,4'b1000);
                //tx_en 0
                rc_apb_write(16'h9000,32'h0000_0000,4'b1000);
        $display ("CFG Write Done!");
//--------------------CFG read-------------------------------
        #5000   //cfg wr type 0
                rc_apb_write(16'h9000,32'h0000_003c,4'b0001);
        // BAR0
        #1000   //reg num 4 BAR0
                rc_apb_write(16'h9008,32'h0000_0004,4'b0001);
                //tag 0
                rc_apb_write(16'h9000,32'h0000_0000,4'b0010);
                //tx_en 1
                rc_apb_write(16'h9000,32'h0100_0000,4'b1000);
                //tx_en 0
                rc_apb_write(16'h9000,32'h0000_0000,4'b1000);
        //BAR1
        #1000   //reg num 5 BAR1
                rc_apb_write(16'h9008,32'h0000_0005,4'b0001);
                //tag 1
                rc_apb_write(16'h9000,32'h0000_0100,4'b0010);
                //tx_en 1
                rc_apb_write(16'h9000,32'h0100_0000,4'b1000);
                //tx_en 0
                rc_apb_write(16'h9000,32'h0000_0000,4'b1000);
        //BAR2
        #1000   //reg num 6 BAR2
                rc_apb_write(16'h9008,32'h0000_0006,4'b0001);
                //tag 2
                rc_apb_write(16'h9000,32'h0000_0200,4'b0010);
                //tx_en 1
                rc_apb_write(16'h9000,32'h0100_0000,4'b1000);
                //tx_en 0
                rc_apb_write(16'h9000,32'h0000_0000,4'b1000);
        //BAR3
        #1000   //reg num 7 BAR3
                rc_apb_write(16'h9008,32'h0000_0007,4'b0001);
                //tag 3
                rc_apb_write(16'h9000,32'h0000_0300,4'b0010);
                //tx_en 1
                rc_apb_write(16'h9000,32'h0100_0000,4'b1000);
                //tx_en 0
                rc_apb_write(16'h9000,32'h0000_0000,4'b1000);
        //BAR4
        #1000   //reg num 8 BAR4
                rc_apb_write(16'h9008,32'h0000_0008,4'b0001);
                //tag 4
                rc_apb_write(16'h9000,32'h0000_0400,4'b0010);
                //tx_en 1
                rc_apb_write(16'h9000,32'h0100_0000,4'b1000);
                //tx_en 0
                rc_apb_write(16'h9000,32'h0000_0000,4'b1000);
        //BAR5
        #1000   //reg num 8 BAR5
                rc_apb_write(16'h9008,32'h0000_0009,4'b0001);
                //tag 5
                rc_apb_write(16'h9000,32'h0000_0500,4'b0010);
                //tx_en 1
                rc_apb_write(16'h9000,32'h0100_0000,4'b1000);
                //tx_en 0
                rc_apb_write(16'h9000,32'h0000_0000,4'b1000);
        $display ("CFG Read Done!");
//--------------------CFG write base addr reg---------------
        //cfg_ctrl_en enable
        #5000
                //rc_apb_write(16'h9008,32'h0100_0000,4'b1000);
                //cfg wr type 0
                rc_apb_write(16'h9000,32'h0000_003d,4'b0001);
                //des id bus 1 dev0 fun 0
                rc_apb_write(16'h9004,32'h0100_0000,4'b1000);
        // BAR0
        #1000   //reg num 4 BAR0
                rc_apb_write(16'h9008,32'h0000_0004,4'b0001);
                //tag 0
                rc_apb_write(16'h9000,32'h0000_0000,4'b0010);
                //wr data all 1
                rc_apb_write(16'h900c,32'h0000_2000,4'b1111);
                //tx_en 1
                rc_apb_write(16'h9000,32'h0100_0000,4'b1000);
                //tx_en 0
                rc_apb_write(16'h9000,32'h0000_0000,4'b1000);
        //BAR1
        #1000   //reg num 5 BAR1
                rc_apb_write(16'h9008,32'h0000_0005,4'b0001);
                //tag 1
                rc_apb_write(16'h9000,32'h0000_0100,4'b0010);
                //wr data all 1
                rc_apb_write(16'h900c,32'hf7e1_2000,4'b1111);
                //tx_en 1
                rc_apb_write(16'h9000,32'h0100_0000,4'b1000);
                //tx_en 0
                rc_apb_write(16'h9000,32'h0000_0000,4'b1000);
        //BAR2
        #1000   //reg num 6 BAR2
                rc_apb_write(16'h9008,32'h0000_0006,4'b0001);
                //tag 2
                rc_apb_write(16'h9000,32'h0000_0200,4'b0010);
                //wr data all 1
                rc_apb_write(16'h900c,32'hf7e1_0000,4'b1111);
                //tx_en 1
                rc_apb_write(16'h9000,32'h0100_0000,4'b1000);
                //tx_en 0
                rc_apb_write(16'h9000,32'h0000_0000,4'b1000);
        //BAR3
        #1000   //reg num 7 BAR3
                rc_apb_write(16'h9008,32'h0000_0007,4'b0001);
                //tag 3
                rc_apb_write(16'h9000,32'h0000_0300,4'b0010);
                //wr data all 1
                rc_apb_write(16'h900c,32'h0000_000f,4'b1111);
                //tx_en 1
                rc_apb_write(16'h9000,32'h0100_0000,4'b1000);
                //tx_en 0
                rc_apb_write(16'h9000,32'h0000_0000,4'b1000);
        //BAR4
        #1000   //reg num 8 BAR4
                rc_apb_write(16'h9008,32'h0000_0008,4'b0001);
                //tag 4
                rc_apb_write(16'h9000,32'h0000_0400,4'b0010);
                //wr data all 1
                rc_apb_write(16'h900c,32'h0000_0000,4'b1111);
                //tx_en 1
                rc_apb_write(16'h9000,32'h0100_0000,4'b1000);
                //tx_en 0
                rc_apb_write(16'h9000,32'h0000_0000,4'b1000);
        //BAR5
        #1000   //reg num 8 BAR5
                rc_apb_write(16'h9008,32'h0000_0009,4'b0001);
                //tag 5
                rc_apb_write(16'h9000,32'h0000_0500,4'b0010);
                //wr data all 1
                rc_apb_write(16'h900c,32'h0000_0000,4'b1111);
                //tx_en 1
                rc_apb_write(16'h9000,32'h0100_0000,4'b1000);
                //tx_en 0
                rc_apb_write(16'h9000,32'h0000_0000,4'b1000);
//--------------------CFG read-------------------------------
        //      cfg_wr type
        #1000
                rc_apb_write(16'h9000,32'h0000_003d,4'b0001);
        //      cfg_wr  regnum =1
                //tag 6
                rc_apb_write(16'h9000,32'h0000_0600,4'b0010);

                rc_apb_write(16'h9008,32'h0000_0001,4'b0001);
        //      cfg_wr MSE IOE MEMEN

                rc_apb_write(16'h900c,32'h0000_0007,4'b0001);
        //      cfg_wr  tx en

                rc_apb_write(16'h9000,32'h0100_0000,4'b1000);
                //tx_en 0
                rc_apb_write(16'h9000,32'h0000_0000,4'b1000);
        //      cfg_ctrl_en release

                //rc_apb_write(16'h9008,32'h0000_0000,4'b1000);

        #1000
                $display ("CFG cfg Done!");
        //      rc DBI MSE IOE MEMEN
                rc_apb_write(16'h7004,32'h0000_0007,4'b0001);

        #5000   //cfg wr type 0
                rc_apb_write(16'h9000,32'h0000_003c,4'b0001);
        // BAR0
        #1000   //reg num 4 BAR0
                rc_apb_write(16'h9008,32'h0000_0004,4'b0001);
                //tag 0
                rc_apb_write(16'h9000,32'h0000_0000,4'b0010);
                //tx_en 1
                rc_apb_write(16'h9000,32'h0100_0000,4'b1000);
                //tx_en 0
                rc_apb_write(16'h9000,32'h0000_0000,4'b1000);
        //BAR1
        #1000   //reg num 5 BAR1
                rc_apb_write(16'h9008,32'h0000_0005,4'b0001);
                //tag 1
                rc_apb_write(16'h9000,32'h0000_0100,4'b0010);
                //tx_en 1
                rc_apb_write(16'h9000,32'h0100_0000,4'b1000);
                //tx_en 0
                rc_apb_write(16'h9000,32'h0000_0000,4'b1000);
        //BAR2
        #1000   //reg num 6 BAR2
                rc_apb_write(16'h9008,32'h0000_0006,4'b0001);
                //tag 2
                rc_apb_write(16'h9000,32'h0000_0200,4'b0010);
                //tx_en 1
                rc_apb_write(16'h9000,32'h0100_0000,4'b1000);
                //tx_en 0
                rc_apb_write(16'h9000,32'h0000_0000,4'b1000);
        //BAR3
        #1000   //reg num 7 BAR3
                rc_apb_write(16'h9008,32'h0000_0007,4'b0001);
                //tag 3
                rc_apb_write(16'h9000,32'h0000_0300,4'b0010);
                //tx_en 1
                rc_apb_write(16'h9000,32'h0100_0000,4'b1000);
                //tx_en 0
                rc_apb_write(16'h9000,32'h0000_0000,4'b1000);
        //BAR4
        #1000   //reg num 8 BAR4
                rc_apb_write(16'h9008,32'h0000_0008,4'b0001);
                //tag 4
                rc_apb_write(16'h9000,32'h0000_0400,4'b0010);
                //tx_en 1
                rc_apb_write(16'h9000,32'h0100_0000,4'b1000);
                //tx_en 0
                rc_apb_write(16'h9000,32'h0000_0000,4'b1000);
        //BAR5
        #1000   //reg num 8 BAR5
                rc_apb_write(16'h9008,32'h0000_0009,4'b0001);
                //tag 5
                rc_apb_write(16'h9000,32'h0000_0500,4'b0010);
                //tx_en 1
                rc_apb_write(16'h9000,32'h0100_0000,4'b1000);
                //tx_en 0
                rc_apb_write(16'h9000,32'h0000_0000,4'b1000);
        $display ("CFG Read Done!");

        //      cfg_ctrl_en release
        #5000
                rc_apb_write(16'h9008,32'h0000_0000,4'b1000);



//----------------------DMA test--------------------------------------
                $display ("start DMA test!");
				
          //DMA 1 DW
                //rc_cfg_ep_rd
                rc_cfg_ep_rd(32'h0000_0180,32'h0000_0280,32'h0000_0008,32'h0000_0000,32'h0000_0001);  //addr_l_reg，addr_h_reg，ram_addr，length,wr_32_64_addr
				wait(pango_pcie_top_tb.u_pango_pcie_top_ep.u_rt_pcie_dma.i_cpld_finish)
                rc_mrd_tx(8'h00,32'hf7e1_2130); 
                $display ("ep_rcv cpld!");
                //cfg_ep_tx_mwr
                rc_cfg_ep_wr(32'h0000_0180,32'h0000_0280,32'h0000_0008,32'h0000_0000,32'h0000_0001);  //addr_l_reg，addr_h_reg，ram_addr，length,wr_32_64_addr
 				wait(pango_pcie_top_tb.u_pango_pcie_top_ep.u_rt_pcie_dma.u_rt_dma.u_rt02_dma_tx.u_rt0206_data_mux.mwr_tx_finish)
                rc_mrd_tx(8'h00,32'hf7e1_2230); 
                $display ("1dw DMA test done!"); 

        //DMA 8 DW
                //cfg_ep_tx_mrd
                rc_cfg_ep_rd(32'h0000_0180,32'h0000_0280,32'h0000_0008,32'h0000_0007,32'h0000_0001);  //addr_l_reg，addr_h_reg，ram_addr，length
 				wait(pango_pcie_top_tb.u_pango_pcie_top_ep.u_rt_pcie_dma.i_cpld_finish)
                rc_mrd_tx(8'h00,32'hf7e1_2130); 
                $display ("ep_rcv cpld!");
                //cfg_ep_tx_mwr
                rc_cfg_ep_wr(32'h0000_0180,32'h0000_0280,32'h0000_0008,32'h0000_0007,32'h0000_0001);  //addr_l_reg，addr_h_reg，ram_addr，length
 				wait(pango_pcie_top_tb.u_pango_pcie_top_ep.u_rt_pcie_dma.u_rt_dma.u_rt02_dma_tx.u_rt0206_data_mux.mwr_tx_finish)
                rc_mrd_tx(8'h00,32'hf7e1_2230); 
                $display ("8dw DMA test done!");
				
 		//DMA 64 DW
                //cfg_ep_tx_mrd
                rc_cfg_ep_rd(32'h0000_0180,32'h0000_0280,32'h0000_0008,32'h0000_003f,32'h0000_0001);
				wait(pango_pcie_top_tb.u_pango_pcie_top_ep.u_rt_pcie_dma.i_cpld_finish)
                rc_mrd_tx(8'h00,32'hf7e1_2130);
                $display ("ep_rcv cpld!");
                //cfg_ep_tx_mwr
                rc_cfg_ep_wr(32'h0000_0180,32'h0000_0280,32'h0000_0008,32'h0000_003f,32'h0000_0001);
				wait(pango_pcie_top_tb.u_pango_pcie_top_ep.u_rt_pcie_dma.u_rt_dma.u_rt02_dma_tx.u_rt0206_data_mux.mwr_tx_finish)
                rc_mrd_tx(8'h00,32'hf7e1_2230);
                $display ("64dw DMA test done!"); 

		//DMA 128 DW
                //cfg_ep_tx_mrd
                rc_cfg_ep_rd(32'h0000_0180,32'h0000_0280,32'h0000_0008,32'h0000_007f,32'h0000_0001);
				wait(pango_pcie_top_tb.u_pango_pcie_top_ep.u_rt_pcie_dma.i_cpld_finish)
                rc_mrd_tx(8'h00,32'hf7e1_2130);
                $display ("ep_rcv cpld!");
                //cfg_ep_tx_mwr
                rc_cfg_ep_wr(32'h0000_0180,32'h0000_0280,32'h0000_0008,32'h0000_007f,32'h0000_0001);
				wait(pango_pcie_top_tb.u_pango_pcie_top_ep.u_rt_pcie_dma.u_rt_dma.u_rt02_dma_tx.u_rt0206_data_mux.mwr_tx_finish)
                rc_mrd_tx(8'h00,32'hf7e1_2230);
                $display ("128dw DMA test done!");
				
		//DMA 256 DW
                //cfg_ep_tx_mrd
                rc_cfg_ep_rd(32'h0000_0180,32'h0000_0280,32'h0000_0008,32'h0000_00ff,32'h0000_0001);
				wait(pango_pcie_top_tb.u_pango_pcie_top_ep.u_rt_pcie_dma.i_cpld_finish)
                rc_mrd_tx(8'h00,32'hf7e1_2130);
                $display ("ep_rcv cpld!");
                //cfg_ep_tx_mwr
                rc_cfg_ep_wr(32'h0000_0180,32'h0000_0280,32'h0000_0008,32'h0000_00ff,32'h0000_0001);
				wait(pango_pcie_top_tb.u_pango_pcie_top_ep.u_rt_pcie_dma.u_rt_dma.u_rt02_dma_tx.u_rt0206_data_mux.mwr_tx_finish)
                rc_mrd_tx(8'h00,32'hf7e1_2230);
                $display ("256dw DMA test done!");
			

    #10000;

        //PIO 1 DW
                //rc_tx_mwr
                rc_mwr_tx(8'h00,32'h0000_2000);
                //rc_tx_mrd
                rc_mrd_tx(8'h00,32'h0000_2000);
                wait(pango_pcie_top_tb.u_pango_pcie_top_rc.u_ips2l_pcie_dma.i_axis_master_tdata[31:24]==8'h4a)
                $display ("rc_rcv cpld! PIO 1 DW test done");

        //PIO 64DW						
				//PIO 64 DW
                rc_mwr_tx(8'h3f,32'h0000_2000);
                //rc_tx_mwr
                #1000
                rc_mrd_tx(8'h3f,32'h0000_2000);
                wait(pango_pcie_top_tb.u_pango_pcie_top_rc.u_ips2l_pcie_dma.i_axis_master_tdata[31:24]==8'h4a)
                $display ("rc_rcv cpld! PIO 64 DW test done");				
         //PIO 128DW						
				//PIO 128 DW
                rc_mwr_tx(8'h7f,32'h0000_2000);
                //rc_tx_mwr
                #1000
                rc_mrd_tx(8'h7f,32'h0000_2000);
                wait(pango_pcie_top_tb.u_pango_pcie_top_rc.u_ips2l_pcie_dma.i_axis_master_tdata[31:24]==8'h4a)
                $display ("rc_rcv cpld! PIO 128 DW test done");	
        //PIO 256DW						
				//PIO 64 DW
                rc_mwr_tx(8'hff,32'h0000_2000);
                //rc_tx_mwr
                #1000
                rc_mrd_tx(8'hff,32'h0000_2000);
                wait(pango_pcie_top_tb.u_pango_pcie_top_rc.u_ips2l_pcie_dma.i_axis_master_tdata[31:24]==8'h4a)
                $display ("rc_rcv cpld! PIO 256 DW test done");					

				
    #20000 $finish;
end



task    rc_apb_write;
        input [15:0]    addr;
        input [31:0]    wdata;
        input [3:0]     strb;
        begin
            @(posedge pango_pcie_top_tb.u_pango_pcie_top_rc.ref_clk)
            #1
                force pango_pcie_top_tb.u_pango_pcie_top_rc.uart_p_addr       = addr;
                force pango_pcie_top_tb.u_pango_pcie_top_rc.uart_p_sel        = 1'b1;
                force pango_pcie_top_tb.u_pango_pcie_top_rc.uart_p_strb       = strb;
                force pango_pcie_top_tb.u_pango_pcie_top_rc.uart_p_ce         = 1'b0;
                force pango_pcie_top_tb.u_pango_pcie_top_rc.uart_p_we         = 1'b1;
                force pango_pcie_top_tb.u_pango_pcie_top_rc.uart_p_wdata      = wdata;
            @(posedge pango_pcie_top_tb.u_pango_pcie_top_rc.ref_clk)
            #1
                force pango_pcie_top_tb.u_pango_pcie_top_rc.uart_p_ce         = 1'b1;
            //wait(pango_pcie_top_tb.u_pango_pcie_top_rc.uart_p_rdy)
            //@(posedge pango_pcie_top_tb.u_pango_pcie_top_rc.ref_clk)
            @(negedge pango_pcie_top_tb.u_pango_pcie_top_rc.uart_p_rdy)
            #1
                force pango_pcie_top_tb.u_pango_pcie_top_rc.uart_p_addr       = 16'h0;
                force pango_pcie_top_tb.u_pango_pcie_top_rc.uart_p_sel        = 1'b0;
                force pango_pcie_top_tb.u_pango_pcie_top_rc.uart_p_strb       = 4'h0;
                force pango_pcie_top_tb.u_pango_pcie_top_rc.uart_p_ce         = 1'b0;
                force pango_pcie_top_tb.u_pango_pcie_top_rc.uart_p_we         = 1'b0;
                force pango_pcie_top_tb.u_pango_pcie_top_rc.uart_p_wdata      = 32'h0;
        end
endtask


task    rc_mwr_tx_with_data;
        input   [31:0]  addr;
        input   [31:0]  data;
        begin
        #1000
            //cfg cmd_reg;
            //type:mwr 32bit with data
            // rc_apb_write(16'h8140,32'h0101_0100,4'b1111);  //64bit地址 还要加16'h8170寄存器
            rc_apb_write(16'h8140,32'h0100_0100,4'b1111);
            //length:1 dw
            rc_apb_write(16'h8150,32'h0000_0000,4'b1111);     //rc固定的发一个DW长度
            //addr_l:0xf7e1_2100
            rc_apb_write(16'h8160,addr,4'b1111);              //addr表示的是bar1地址
            //wr_data: cfg ep tx 32mwr 32dw
            rc_apb_write(16'h8180,data,4'b1111);              //data表示的是bar1 tlp包给EP的数据,这个数据包括addr_l_reg、addr_h_reg、length。
        end
endtask


task    rc_cfg_ep_rd;
        input   [31:0]  addr_l_reg;
        input   [31:0]  addr_h_reg;
        input   [31:0]  ram_addr;
		input   [31:0]  length;
		input   [31:0]  addr_32_64;
        begin
        #5000
            //
            rc_mwr_tx_with_data(32'hf7e1_2100,addr_l_reg);
            //
            rc_mwr_tx_with_data(32'hf7e1_2104,addr_h_reg);
            //
            rc_mwr_tx_with_data(32'hf7e1_2110,ram_addr);
            //
            rc_mwr_tx_with_data(32'hf7e1_2120,length);
            //
            rc_mwr_tx_with_data(32'hf7e1_2140,addr_32_64);
        end
endtask

task    rc_cfg_ep_wr;
        input   [31:0]  addr_l_reg;
        input   [31:0]  addr_h_reg;
        input   [31:0]  ram_addr;
		input   [31:0]  length;
		input   [31:0]  addr_32_64;
        begin
        #5000
            //
            rc_mwr_tx_with_data(32'hf7e1_2200,addr_l_reg);
            //
            rc_mwr_tx_with_data(32'hf7e1_2204,addr_h_reg);
            //
            rc_mwr_tx_with_data(32'hf7e1_2210,ram_addr);
            //
            rc_mwr_tx_with_data(32'hf7e1_2220,length);
            //
            rc_mwr_tx_with_data(32'hf7e1_2240,addr_32_64);
        end
endtask




//
task    rc_mwr_tx;
        input   [7:0]   length;
        input   [31:0]  addr;
        begin
        #1000
            //type:mwr 32bit
            rc_apb_write(16'h8140,32'h0100_0000,4'b1111);
            //length:32 dw
            rc_apb_write(16'h8150,{24'b0,length},4'b1111);
            //addr_l:0x0000_0000
            rc_apb_write(16'h8160,addr,4'b1111);
        end
endtask

task    rc_mrd_tx;
        input   [7:0]   length;
        input   [31:0]  addr;
        begin
        #1000
            //type:mrd 32bit
            rc_apb_write(16'h8140,32'h0000_0000,4'b1111);
            //length:32 dw
            rc_apb_write(16'h8150,{24'b0,length},4'b1111);
            //addr_l:0x0000_0000
            rc_apb_write(16'h8160,addr,4'b1111);
        end
endtask


endmodule


