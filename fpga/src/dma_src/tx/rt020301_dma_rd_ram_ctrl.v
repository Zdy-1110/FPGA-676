

//////////////////////////////////////////////////////////////////////////////
module rt020301_dma_rd_ram_ctrl #(
    parameter                           ADDR_WIDTH     = 'd32,
    parameter                           RD_DATA_DELAY  = 'd1
)(
    input                                clk             ,   //gen1:62.5MHz,gen2:125MHz
    input                                rst_n           ,
    //**********************************************************************
    //frome rt0201_mwr_ctrl
    input                               i_rd_en         ,
    input           [9:0]               i_rd_length     ,
    input           [63:0]              i_rd_addr       ,
    input                               i_tx_hold       ,
    input                               i_tlp_tx        ,
    output  wire                        o_rd_ram_hold   ,
    //ram_rd
    output  reg                         o_bar_rd_clk_en ,
    output  wire    [ADDR_WIDTH-1:0]    o_bar_rd_addr   ,
    input           [127:0]             i_bar_rd_data   ,
	//to rt0201_mwr_ctrl
    output  wire                        o_gen_tlp_start ,
    output  wire    [127:0]             o_rd_data       ,
    output  wire                        o_last_data     
);

localparam FIFO_DEEP = 9'd512;    //should be 2^N  real_deep = deep < 16 ? 16 : deep;

reg                         rd_en_d1;
wire                        rd_en_pe;

reg     [ADDR_WIDTH-1:0]    rd_addr;

reg     [10:0]              data_read_cnt;

reg     [1:0]               data_position;
reg     [127:0]             i_bar_rd_data_d1;
wire    [255:0]             data_shift;
reg     [127:0]             data_shift_out;

reg     [9:0]               shift_data_cnt;
reg     [9:0]               shift_data_cnt_d1;
reg     [9:0]               shift_data_cnt_d2;
reg     [9:0]               shift_data_cnt_d3;
reg     [9:0]               shift_data_cnt_d4;

reg                         shift_data_out_valid;
reg                         ram_data_out_vld;
reg                         ram_last_data_rd;
reg                         data_in_valid;
wire                        data_in_ready;
wire                        fifo_data_in;
wire                        fifo_data_out;
reg     [7:0]               fifo_data_cnt;
reg                         rd_ram_hold_d1;
wire                        data_out_ready;
wire                        data_out_valid;
reg     [9:0]               tx_data_cnt;

wire    [127:0]             data_out;

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        rd_en_d1 <= 1'b0;
    else
        rd_en_d1 <= i_rd_en;
end
//rd ctrl start
assign rd_en_pe = ~rd_en_d1 && i_rd_en;

//total dw data need read
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        data_read_cnt <= 11'b0;
    else if(rd_en_pe)
        data_read_cnt <= {1'b0,i_rd_length} + {9'b0,i_rd_addr[3:2]};
    else if(!o_rd_ram_hold)
    begin
        if(data_read_cnt > 11'h4)
            data_read_cnt <= data_read_cnt - 11'h4;
        else if(data_read_cnt <= 11'h4)
            data_read_cnt <= 11'b0;
    end
end

//bar rd enable
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        o_bar_rd_clk_en <= 1'b0;
    else if(rd_en_pe)
        o_bar_rd_clk_en <= 1'b1;
    else if(data_read_cnt <= 11'd4)
        o_bar_rd_clk_en <= 1'b0;
end

//bar rd addr
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        rd_addr <= {ADDR_WIDTH{1'b0}};
    else if(rd_en_pe)   
        rd_addr <= i_rd_addr[ADDR_WIDTH+3:4];
    else if(o_bar_rd_clk_en && !o_rd_ram_hold)
        rd_addr <= rd_addr + {{(ADDR_WIDTH-1){1'b0}},1'b1};
end

assign o_bar_rd_addr = rd_addr;

//data_shift
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        data_position <= 2'b0;
    else if(rd_en_pe)
        data_position <= i_rd_addr[3:2];
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        i_bar_rd_data_d1 <= 128'b0;
    else if(!rd_ram_hold_d1)
        i_bar_rd_data_d1 <= i_bar_rd_data;
end

assign data_shift = {i_bar_rd_data,i_bar_rd_data_d1};

always@(*)
begin
    case(data_position)
        2'd0: data_shift_out = data_shift[32*0+127:32*0];
        2'd1: data_shift_out = data_shift[32*1+127:32*1];
        2'd2: data_shift_out = data_shift[32*2+127:32*2];
        2'd3: data_shift_out = data_shift[32*3+127:32*3];
        default : data_shift_out = 128'b0;
    endcase
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        shift_data_cnt <= 10'b0;
    else if(rd_en_pe)
        shift_data_cnt <= i_rd_length;
    else if(!o_rd_ram_hold)
    begin
        if(shift_data_cnt >= 10'd4)
            shift_data_cnt <= shift_data_cnt - 10'd4;
        else if(shift_data_cnt < 10'd4)
            shift_data_cnt <= 10'b0;
    end
end

always@(posedge clk or negedge rst_n)  //delay
begin
    if(!rst_n) begin
        shift_data_cnt_d1  <= 10'b0;
        shift_data_cnt_d2  <= 10'b0;
        shift_data_cnt_d3  <= 10'b0;
        shift_data_cnt_d4  <= 10'b0;
	end
    else begin
        shift_data_cnt_d1  <= shift_data_cnt;
        shift_data_cnt_d2  <= shift_data_cnt_d1;
        shift_data_cnt_d3  <= shift_data_cnt_d2;
        shift_data_cnt_d4  <= shift_data_cnt_d3;
	end
end

//bar read data valid
//
reg o_bar_rd_clk_en_d1;
reg o_bar_rd_clk_en_d2;
reg o_bar_rd_clk_en_d3;
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)begin
        o_bar_rd_clk_en_d1 <= 1'b0;
        o_bar_rd_clk_en_d2 <= 1'b0;
        o_bar_rd_clk_en_d3 <= 1'b0;
	end
    else begin
        o_bar_rd_clk_en_d1 <= o_bar_rd_clk_en;
        o_bar_rd_clk_en_d2 <= o_bar_rd_clk_en_d1;
        o_bar_rd_clk_en_d3 <= o_bar_rd_clk_en_d2;
	end
end
//

always@(posedge clk or negedge rst_n)   //delay
begin
    if(!rst_n)
        ram_data_out_vld <= 1'b0;
    else if(o_rd_ram_hold)
        ram_data_out_vld <= 1'b0;
    else begin
	    case(RD_DATA_DELAY)
            2'b01:
                ram_data_out_vld <= o_bar_rd_clk_en_d1;
            2'b10:
                ram_data_out_vld <= o_bar_rd_clk_en_d2;
            2'b11:
                ram_data_out_vld <= o_bar_rd_clk_en_d3;
        default:
                ram_data_out_vld <= o_bar_rd_clk_en_d1;              
        endcase	
	end
end


always@(posedge clk or negedge rst_n)   //delay
begin
    if(!rst_n)
        shift_data_out_valid <= 1'b0;
    else if(!o_rd_ram_hold)begin
	    case(RD_DATA_DELAY)
            2'b01:begin
			    if(shift_data_cnt_d2 > 10'b0)
                    shift_data_out_valid <= 1'b1;
				else if(~(|shift_data_cnt_d2) && fifo_data_in)
                    shift_data_out_valid <= 1'b0;
			end	
            2'b10:begin
			    if(shift_data_cnt_d3 > 10'b0)
                    shift_data_out_valid <= 1'b1;
				else if(~(|shift_data_cnt_d3) && fifo_data_in)
                    shift_data_out_valid <= 1'b0;
			end	
            2'b11:begin
			    if(shift_data_cnt_d4 > 10'b0)
                    shift_data_out_valid <= 1'b1;
				else if(~(|shift_data_cnt_d4) && fifo_data_in)
                    shift_data_out_valid <= 1'b0;
			end		
        default:
                shift_data_out_valid = shift_data_out_valid;              
        endcase
	end	
end
 

//read ram last data flag
always@(*)    //delay
begin
    case(RD_DATA_DELAY)
        2'b01: ram_last_data_rd = ~(|shift_data_cnt_d2) && shift_data_out_valid;
        2'b10: ram_last_data_rd = ~(|shift_data_cnt_d3) && shift_data_out_valid;
        2'b11: ram_last_data_rd = ~(|shift_data_cnt_d4) && shift_data_out_valid;
        default : ram_last_data_rd = 1'b0;
    endcase
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        data_in_valid <= 1'b0;
    else if(o_rd_ram_hold || ram_last_data_rd && data_in_valid)
        data_in_valid <= 1'b0;
    else if(ram_data_out_vld)
        data_in_valid <= 1'b1;
end

    pgs_pciex4_prefetch_fifo_v1_2
    #(
        .D              (FIFO_DEEP      ), //should be 2^N
        .W              (128            )
     )
    u_mwr_data_rd_fifo
    (
    .clk                (clk            ),
    .rst_n              (rst_n          ),

    .data_in_valid      (data_in_valid  ),
    .data_in            (data_shift_out ),
    .data_in_ready      (data_in_ready  ),

    .data_out_ready     (data_out_ready ),
    .data_out           (data_out       ),
    .data_out_valid     (data_out_valid )
    );

assign fifo_data_in  = data_in_valid  && data_in_ready ;
assign fifo_data_out = data_out_ready && data_out_valid;

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        fifo_data_cnt <= 8'b0;
    else if(fifo_data_in && fifo_data_out)
        fifo_data_cnt <= fifo_data_cnt;
    else if(fifo_data_in)
        fifo_data_cnt <= fifo_data_cnt + 8'h1;
    else if(fifo_data_out)
        fifo_data_cnt <= fifo_data_cnt - 8'h1;
end

assign o_rd_ram_hold = (fifo_data_cnt >= FIFO_DEEP - 8'd2) ? 1'b1 : 1'b0;

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        rd_ram_hold_d1 <= 1'b0;
    else
        rd_ram_hold_d1 <= o_rd_ram_hold;
end

assign data_out_ready  = i_tlp_tx && !i_tx_hold;

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        tx_data_cnt <= 10'b0;
    else if(rd_en_pe)
        tx_data_cnt <= (i_rd_length >= 10'd4) ? i_rd_length - 10'd4 :  10'd0;
    else if(fifo_data_out && |tx_data_cnt)
        tx_data_cnt <= (tx_data_cnt >= 10'd4) ? tx_data_cnt - 10'd4 :  10'd0;
end

//read fifo last data flag
assign o_last_data = ~(|tx_data_cnt) && fifo_data_out;

assign o_gen_tlp_start = data_out_valid;
assign o_rd_data       = data_out;

endmodule
