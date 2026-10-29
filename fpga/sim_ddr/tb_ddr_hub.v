`timescale 1ns/1ps
//////////////////////////////////////////////////////////////////////////////
// tb_ddr_hub.v : testbench for rt_ddr_hub (DDR3 hub / doorbell / readback)
// 20261018  ddr hub verification
//////////////////////////////////////////////////////////////////////////////
module tb_ddr_hub;

//----------------------------------------------------------------- clocks
reg pclk, ddr_clk;
initial begin pclk = 1'b0;    forever #4    pclk    = ~pclk;    end   // 8 ns
initial begin ddr_clk = 1'b0; forever #5.15 ddr_clk = ~ddr_clk; end  // 10.3 ns

//----------------------------------------------------------------- reset / init
reg pclk_rst_n, ddr_rst_n, ddr_init_done;
initial begin
    pclk_rst_n   = 1'b0;
    ddr_rst_n    = 1'b0;
    ddr_init_done= 1'b0;
    #200;
    pclk_rst_n   = 1'b1;
    ddr_rst_n    = 1'b1;
    #2000;
    ddr_init_done= 1'b1;
end

//----------------------------------------------------------------- DUT pins
reg         i_tap_vld;
reg  [11:0] i_tap_addr;
reg  [31:0] i_tap_data;
reg         i_dma_wr_en;
reg  [31:0] i_dma_wr_addr;
reg  [127:0]i_dma_wr_data;
reg  [15:0] i_dma_wr_be;
reg         i_mrd_start;
reg         i_mrd_done;
reg         i_db_ack;
wire        o_db_req;
wire [31:0] o_db_addr;
wire [19:0] o_db_len_dw;
wire        o_issue_hold;
wire        o_start_block;
wire        o_final_done_host;
wire        o_copy_wr_en;
wire [11:0] o_copy_wr_addr;
wire [127:0]o_copy_wr_data;
wire [127:0]o_stat1c0, o_stat1d0, o_stat1e0;

wire [27:0] axi_awaddr;
wire [3:0]  axi_awlen;
wire        axi_awvalid;
wire [255:0]axi_wdata;
wire [31:0] axi_wstrb;
reg         axi_awready;
reg         axi_wready;
wire [27:0] axi_araddr;
wire [3:0]  axi_arlen;
wire        axi_arvalid;
reg         axi_arready;
reg  [255:0]axi_rdata;
reg         axi_rlast;
reg         axi_rvalid;

rt_ddr_hub u_dut (
    .pclk            (pclk            ),
    .pclk_rst_n      (pclk_rst_n      ),
    .i_tap_vld       (i_tap_vld       ),
    .i_tap_addr      (i_tap_addr      ),
    .i_tap_data      (i_tap_data      ),
    .i_dma_wr_en     (i_dma_wr_en     ),
    .i_dma_wr_addr   (i_dma_wr_addr   ),
    .i_dma_wr_data   (i_dma_wr_data   ),
    .i_dma_wr_be     (i_dma_wr_be     ),
    .i_mrd_start     (i_mrd_start     ),
    .i_mrd_done      (i_mrd_done      ),
    .i_db_ack        (i_db_ack        ),
    .o_db_req        (o_db_req        ),
    .o_db_addr       (o_db_addr       ),
    .o_db_len_dw     (o_db_len_dw     ),
    .o_issue_hold    (o_issue_hold    ),
    .o_start_block   (o_start_block   ),
    .o_final_done_host(o_final_done_host),
    .o_copy_wr_en    (o_copy_wr_en    ),
    .o_copy_wr_addr  (o_copy_wr_addr  ),
    .o_copy_wr_data  (o_copy_wr_data  ),
    .o_stat1c0       (o_stat1c0       ),
    .o_stat1d0       (o_stat1d0       ),
    .o_stat1e0       (o_stat1e0       ),
    .ddr_clk         (ddr_clk         ),
    .ddr_rst_n       (ddr_rst_n       ),
    .ddr_init_done   (ddr_init_done   ),
    .axi_awaddr      (axi_awaddr      ),
    .axi_awlen       (axi_awlen       ),
    .axi_awvalid     (axi_awvalid     ),
    .axi_awready     (axi_awready     ),
    .axi_wdata       (axi_wdata       ),
    .axi_wstrb       (axi_wstrb       ),
    .axi_wready      (axi_wready      ),
    .axi_araddr      (axi_araddr      ),
    .axi_arlen       (axi_arlen       ),
    .axi_arvalid     (axi_arvalid     ),
    .axi_arready     (axi_arready     ),
    .axi_rdata       (axi_rdata       ),
    .axi_rlast       (axi_rlast       ),
    .axi_rvalid      (axi_rvalid      )
);

//----------------------------------------------------------------- status aliases
wire [15:0] st_ovf    = o_stat1c0[31:16];
wire [4:0]  st_qlvl   = o_stat1c0[4:0];
wire        st_qfull  = o_stat1c0[8];
wire [1:0]  st_eng    = o_stat1c0[11:10];
wire [1:0]  st_cmt    = o_stat1c0[13:12];
wire [31:0] st_push   = o_stat1c0[63:32];
wire [31:0] st_done   = o_stat1c0[95:64];
wire [31:0] st_lastid = o_stat1c0[127:96];
wire [15:0] st_wmax   = o_stat1d0[31:16];
wire        st_wfovf  = o_stat1d0[4];
wire        st_rfovf  = o_stat1d0[5];
wire        st_cfovf  = o_stat1d0[7];   // fix1018hw: cfifo overflow sticky
wire        st_init   = o_stat1d0[0];
wire [31:0] st_pushed = o_stat1d0[63:32];
wire [31:0] st_bursts = o_stat1d0[95:64];
wire [31:0] st_rbdone = o_stat1d0[127:96];
wire [31:0] st_dbcyc  = o_stat1e0[31:0];
wire [31:0] st_beats  = o_stat1e0[63:32];
wire [31:0] st_rbbeat = o_stat1e0[127:96];

//----------------------------------------------------------------- shared state
reg  [255:0] ddr_mem [0:65535];        // DDR3 model (2 MB, 32-byte words)
reg  [127:0] ram     [0:4095];         // on-chip readback RAM
integer      GAP;                      // DDR write beat gap (0..GAP)
integer      ddr_cyc;
integer      wr_beat_cnt;
integer      g_conflict;
integer      g_err;
integer      g_fail;
integer      bi, g;
reg  [255:0] mem_init_dummy;

//----------------------------------------------------------------- DDR write model
reg [2:0]  dw_st;
reg [4:0]  aw_delay, w_left, w_gap, w_j;
reg [27:0] w_addr;
reg [3:0]  w_alen;
reg        h8_arm, h8_started;
integer    h8_first, h8_last, h8_n;

always @(posedge ddr_clk or negedge ddr_rst_n)
    if (!ddr_rst_n) begin
        axi_awready <= 1'b0; axi_wready <= 1'b0; dw_st <= 3'd0;
        aw_delay <= 5'd0; w_left <= 5'd0; w_gap <= 5'd0; w_j <= 5'd0;
        w_addr <= 28'd0; w_alen <= 4'd0;
    end else begin
        case (dw_st)
            3'd0: begin
                axi_awready <= 1'b0;
                if (axi_awvalid) begin
                    aw_delay <= $urandom_range(5,0);
                    dw_st    <= 3'd1;
                end
            end
            3'd1: begin
                if (aw_delay == 5'd0) begin
                    axi_awready <= 1'b1;
                    w_addr      <= axi_awaddr;
                    w_alen      <= axi_awlen;
                    w_left      <= {1'b0, axi_awlen} + 1'b1;
                    w_j         <= 5'd0;
                    dw_st       <= 3'd2;
                end else aw_delay <= aw_delay - 1'b1;
            end
            3'd2: begin
                axi_awready <= 1'b0;
                axi_wready  <= 1'b1;
                dw_st       <= 3'd3;
            end
            3'd3: begin
                for (bi = 0; bi < 32; bi = bi + 1)
                    if (axi_wstrb[bi])
                        ddr_mem[(w_addr>>3) + w_j][bi*8 +: 8] <= axi_wdata[bi*8 +: 8];
                wr_beat_cnt <= wr_beat_cnt + 1;
                if (h8_arm) begin h8_last <= ddr_cyc; h8_n <= h8_n + 1; end
                if (w_left == 5'd1) begin
                    axi_wready <= 1'b0;
                    dw_st      <= 3'd0;
                end else begin
                    w_left <= w_left - 1'b1;
                    w_j    <= w_j + 1'b1;
                    g      = $urandom_range(GAP,0);
                    if (g == 0) begin
                        axi_wready <= 1'b1;
                        dw_st      <= 3'd3;
                    end else begin
                        axi_wready <= 1'b0;
                        w_gap      <= g[4:0];
                        dw_st      <= 3'd4;
                    end
                end
            end
            3'd4: begin
                if (w_gap > 5'd1) w_gap <= w_gap - 1'b1;
                else begin axi_wready <= 1'b1; dw_st <= 3'd3; end
            end
            default: dw_st <= 3'd0;
        endcase
    end

always @(posedge ddr_clk)
    if (h8_arm && axi_awvalid && !h8_started) begin
        h8_started <= 1'b1; h8_first <= ddr_cyc;
    end

//----------------------------------------------------------------- DDR read model
reg [2:0]  dr_st;
reg [4:0]  ar_delay, r_left, r_gap, r_j;
reg [27:0] r_addr;
reg [3:0]  r_alen;

always @(posedge ddr_clk or negedge ddr_rst_n)
    if (!ddr_rst_n) begin
        axi_arready <= 1'b0; axi_rvalid <= 1'b0; axi_rlast <= 1'b0;
        axi_rdata <= 256'd0; dr_st <= 3'd0; ar_delay <= 5'd0;
        r_left <= 5'd0; r_gap <= 5'd0; r_j <= 5'd0;
        r_addr <= 28'd0; r_alen <= 4'd0;
    end else begin
        case (dr_st)
            3'd0: begin
                axi_arready <= 1'b0;
                if (axi_arvalid) begin
                    ar_delay <= $urandom_range(5,0);
                    dr_st    <= 3'd1;
                end
            end
            3'd1: begin
                if (ar_delay == 5'd0) begin
                    axi_arready <= 1'b1;
                    r_addr      <= axi_araddr;
                    r_alen      <= axi_arlen;
                    r_left      <= {1'b0, axi_arlen} + 1'b1;
                    r_j         <= 5'd0;
                    dr_st       <= 3'd2;
                end else ar_delay <= ar_delay - 1'b1;
            end
            3'd2: begin
                axi_arready <= 1'b0;
                axi_rvalid  <= 1'b1;
                axi_rdata   <= ddr_mem[(r_addr>>3) + r_j];
                axi_rlast   <= (r_left == 5'd1);
                r_j         <= r_j + 1'b1;
                dr_st       <= 3'd3;
            end
            3'd3: begin
                if (axi_rlast) begin
                    axi_rvalid <= 1'b0; axi_rlast <= 1'b0; dr_st <= 3'd0;
                end else begin
                    r_left <= r_left - 1'b1;
                    g      = $urandom_range(3,0);
                    if (g == 0) begin
                        axi_rdata  <= ddr_mem[(r_addr>>3) + r_j];
                        axi_rlast  <= (r_left == 5'd2);
                        r_j        <= r_j + 1'b1;
                        axi_rvalid <= 1'b1;
                        dr_st      <= 3'd3;
                    end else begin
                        axi_rvalid <= 1'b0; r_gap <= g[4:0]; dr_st <= 3'd4;
                    end
                end
            end
            3'd4: begin
                if (r_gap > 5'd1) r_gap <= r_gap - 1'b1;
                else begin
                    axi_rvalid <= 1'b1;
                    axi_rdata  <= ddr_mem[(r_addr>>3) + r_j];
                    axi_rlast  <= (r_left == 5'd1);
                    r_j        <= r_j + 1'b1;
                    dr_st      <= 3'd3;
                end
            end
            default: dr_st <= 3'd0;
        endcase
    end

//----------------------------------------------------------------- on-chip RAM model
always @(posedge pclk) begin
    if (o_copy_wr_en) ram[o_copy_wr_addr] <= o_copy_wr_data;
    if (o_copy_wr_en && i_dma_wr_en) g_conflict <= g_conflict + 1;
end

//----------------------------------------------------------------- misc counters
always @(posedge ddr_clk) ddr_cyc <= ddr_cyc + 1;

//----------------------------------------------------------------- register write task
task tap_wr;
    input [11:0] addr;
    input [31:0] data;
    begin
        @(posedge pclk);
        i_tap_addr <= addr;
        i_tap_data <= data;
        i_tap_vld  <= 1'b1;
        @(posedge pclk);
        i_tap_vld  <= 1'b0;
        repeat (4) @(posedge pclk);
    end
endtask

//----------------------------------------------------------------- include engine + tests
`include "tb_ddr_hub_engine.vh"
`include "tb_ddr_hub_tests.vh"

endmodule
