

//////////////////////////////////////////////////////////////////////////////
module rt0202_dma_mrd_ctrl (
    input                               clk                     ,   //gen1:62.5MHz,gen2:125MHz
    input                               rst_n                   ,
    input           [7:0]               i_cfg_pbus_num          ,
    input           [4:0]               i_cfg_pbus_dev_num      ,
    input           [2:0]               i_cfg_max_rd_req_size   ,
    input           [2:0]               i_cfg_max_payload_size  ,
    //**********************************************************************
	input                               i_axis_slave1_trdy      ,
    input                               i_axis_slave1_tvld      ,
    input                               i_axis_slave1_tlast     , 
    //from dma controller
    input                               i_mrd32_req             ,
    output  reg                         o_mrd32_req_ack         ,
    input                               i_mrd64_req             ,
    output  reg                         o_mrd64_req_ack         ,
    input           [10:0]              i_mem_length            ,
    input           [63:0]              i_mem_addr              ,
    //**********************************************************************
    // 20261018 mrd: extended long read support
    input           [19:0]              i_mrd_ext_length        ,   // 20261018 mrd:
    input           [5:0]               i_mrd_max_out           ,   // 20261018 mrd:
    input                               i_mrd_abort             ,   // 20261018 mrd:
    input                               i_tag_free_vld          ,   // 20261018 mrd:
    input           [4:0]               i_tag_free              ,   // 20261018 mrd:
    output  reg                         o_mrd_start             ,   // 20261018 mrd:
    output  reg                         o_mrd_done              ,   // 20261018 mrd:
    output  reg     [31:0]              o_stat_issued           ,   // 20261018 mrd:
    output  reg     [31:0]              o_stat_freed            ,   // 20261018 mrd:
    output  reg     [31:0]              o_stat_cycles           ,   // 20261018 mrd:
    output  wire    [31:0]              o_stat_busy_map         ,   // 20261018 mrd:
    output  wire    [31:0]              o_stat_word             ,   // 20261018 mrd:
    output  reg                         o_chunk_wr_en           ,   // 20261018 mrd:
    output  reg     [4:0]               o_chunk_wr_tag          ,   // 20261018 mrd:
    output  reg     [15:0]              o_chunk_wr_idx          ,   // 20261018 mrd:
    //**********************************************************************
	output  reg                         o_tx_mrd_en             ,
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
    output  wire    [7:0]               o_mrd_tag               ,   // 20261018 mrd: reg -> wire
    output  wire    [15:0]              o_mrd_requester_id      ,
    output  reg     [63:0]              o_mrd_addr                    	,
    // 20261018 ddr: DDR doorbell trigger interface
    input                               i_db_req                ,
    input           [31:0]              i_db_addr               ,
    input           [19:0]              i_db_len_dw             ,
    output  reg                         o_db_ack                ,
    input                               i_issue_hold            ,
    input                               i_start_block
);

localparam      IDLE        = 2'd0;
localparam      HEADER_TX   = 2'd1;

reg     [19:0]  mrd_length/* synthesis PAP_MARK_DEBUG=”true”*/;   // 20261018 mrd:
reg     [19:0]  mrd_length_ff;   // 20261018 mrd:

wire            mrd_req_de/* synthesis PAP_MARK_DEBUG=”true”*/;

// 20261018 mrd: tag / outstanding request control
reg             cmd_active;   // 20261018 mrd:
reg     [15:0]  chunk_cnt;    // 20261018 mrd:
reg     [31:0]  busy_map;     // 20261018 mrd:
reg     [5:0]   out_cnt;      // 20261018 mrd:
reg     [5:0]   max_out;      // 20261018 mrd:
reg             issue_pending;   // 20261018 mrd:
reg             abort_req;       // 20261018 mrd:
reg     [4:0]   done_dly;        // 20261018 mrd:

wire            mrd_req_rcv;   // 20261018 ddr: moved up for start_db
wire            start_host  = mrd_req_de && !cmd_active;   // 20261018 ddr:
wire            start_db    = i_db_req && !cmd_active && !mrd_req_rcv && !i_start_block;   // 20261018 ddr:
wire            start       = start_host || start_db;   // 20261018 mrd:
wire [5:0]      limit_eff   = (i_mrd_max_out == 6'd0) ? 6'd16 : (i_mrd_max_out > 6'd32) ? 6'd32 : i_mrd_max_out;   // 20261018 mrd:
wire            can_issue   = !busy_map[chunk_cnt[4:0]] && (out_cnt < limit_eff);   // 20261018 mrd:
wire [19:0]     eff_len     = (i_mrd_ext_length != 20'd0) ? i_mrd_ext_length : {9'd0, i_mem_length};   // 20261018 mrd:
wire            tag_clr     = i_tag_free_vld && busy_map[i_tag_free];   // 20261018 mrd:
wire            fire        = issue_pending && can_issue && !abort_req && !o_tx_mrd_en && !i_issue_hold;   // 20261018 mrd:

reg             mrd32_req_tx;
reg             mrd64_req_tx;

reg     [1:0]   state/* synthesis PAP_MARK_DEBUG=”true”*/;
reg     [1:0]   next_state;


//tlp_tx
wire    [3:0]   first_dwbe;
wire    [3:0]   last_dwbe;

reg             tx_busy/* synthesis PAP_MARK_DEBUG=”true”*/;
reg             tx_busy_d1;
wire            tx_busy_ne;

wire            abort_go    = abort_req && (issue_pending || !tx_busy);   // 20261018 mrd:
wire            done_cond   = cmd_active && !tx_busy && !issue_pending && (out_cnt == 6'd0) && !o_tx_mrd_en;   // 20261018 mrd:
wire            done_fire   = done_cond && (done_dly == 5'd16);   // 20261018 mrd:

wire            mrd_req_ack;
wire            mrd_tx_hold;

wire            tx_done;
wire [9:0]      max_rd_req_size;

assign mrd_req_rcv = i_mrd32_req || i_mrd64_req;
assign mrd_req_ack = o_mrd32_req_ack || o_mrd64_req_ack;
assign mrd_req_de = mrd_req_rcv && mrd_req_ack;

assign tx_done  =  i_axis_slave1_trdy && i_axis_slave1_tvld && i_axis_slave1_tlast;

//
reg [2:0] min_size;
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        min_size <= 'd0;
    else if(i_cfg_max_payload_size <= i_cfg_max_rd_req_size)
        min_size <= i_cfg_max_payload_size;
    else 
        min_size <= i_cfg_max_rd_req_size;
end
//

assign max_rd_req_size = (min_size == 3'd0) ? 10'h20 :
                         (min_size == 3'd1) ? 10'h40 :
                         (min_size == 3'd2) ? 10'h80 :
                         (min_size == 3'd3) ? 10'h100 : 10'd20;

//get tlp information
//length > max_rd_req_size,
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        mrd_length <= 20'd0;
    else if(abort_go)   // 20261018 mrd:
        mrd_length <= 20'd0;
    else if(start)   // 20261018 mrd:
        mrd_length <= start_db ? i_db_len_dw : eff_len;   // 20261018 ddr:
    else if((mrd_length >  {10'd0, max_rd_req_size}) && o_tx_mrd_en && i_axis_slave1_trdy)   // 20261018 mrd:
        mrd_length <= mrd_length - {10'd0, max_rd_req_size};
    else if((mrd_length <= {10'd0, max_rd_req_size}) && o_tx_mrd_en && i_axis_slave1_trdy)   // 20261018 mrd:
        mrd_length <= 20'd0;
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        mrd_length_ff <= 20'd0;   // 20261018 mrd:
    else
        mrd_length_ff <= mrd_length;
end

//the true length to be transmitted
assign o_mrd_length = (mrd_length_ff > {10'd0, max_rd_req_size}) ? max_rd_req_size : mrd_length_ff[9:0];   // 20261018 mrd:

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        o_mrd_addr <= 64'd0;
    else if(start)   // 20261018 mrd:
        o_mrd_addr <= start_db ? {32'd0, i_db_addr} : i_mem_addr;   // 20261018 ddr:
    else if(|mrd_length && tx_done)
        o_mrd_addr <= o_mrd_addr + {52'b0,max_rd_req_size,2'b0};
end

//start tx mrd
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        o_tx_mrd_en <= 1'b0;
    else if(i_axis_slave1_trdy && o_tx_mrd_en)
        o_tx_mrd_en <= 1'b0;
    else if(start)   // 20261018 mrd:
        o_tx_mrd_en <= 1'b1;
    else if(fire)    // 20261018 mrd:
        o_tx_mrd_en <= 1'b1;
end


// 20261018 mrd: tag is the chunk counter in current command
assign o_mrd_tag = {3'b000, chunk_cnt[4:0]};   // 20261018 mrd:



//**********************************************************************

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        mrd32_req_tx <= 1'b0;
    else if(abort_go || (tx_done && ~(|mrd_length)))   // 20261018 mrd:
        mrd32_req_tx <= 1'b0;
    else if((start_host && i_mrd32_req) || start_db)   // 20261018 ddr:
        mrd32_req_tx <= 1'b1;
	else
        mrd32_req_tx <= mrd32_req_tx;	    
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        mrd64_req_tx <= 1'b0;
    else if(abort_go || (tx_done && ~(|mrd_length)))   // 20261018 mrd:
        mrd64_req_tx <= 1'b0;
    else if(start_host && i_mrd64_req)   // 20261018 ddr:
        mrd64_req_tx <= 1'b1;
	else
        mrd64_req_tx <= mrd64_req_tx;	    
end

//tlp header
assign o_mrd_requester_id = {i_cfg_pbus_num,i_cfg_pbus_dev_num,3'b0};
assign {o_mrd_fmt,o_mrd_tlp_type}  = mrd32_req_tx ? 8'h0
                                    : mrd64_req_tx ? 8'h20 : 8'h00;
assign o_mrd_tc    = 3'b0;
assign o_mrd_attr  = 3'b0;
assign {o_mrd_th,o_mrd_td,o_mrd_ep,o_mrd_at}  = 5'b0;
assign first_dwbe  = 4'hf;
assign last_dwbe   = o_mrd_length == 10'h1 ? 4'h0 : 4'hf;
assign o_mrd_dwbe  = {last_dwbe,first_dwbe};


//mrd_tx
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        state <= IDLE;
    else
        state <= next_state;
end

always @(*)
begin
    case(state)
        IDLE:
        begin
            if(o_tx_mrd_en && i_axis_slave1_trdy) //start transmit
                next_state = HEADER_TX;
            else
                next_state = IDLE;
        end
        HEADER_TX:
        begin
            if(mrd_tx_hold)
                next_state = HEADER_TX;
            else
                next_state = IDLE;
        end
        default:
        begin
            next_state = IDLE;
        end
    endcase
end


always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        tx_busy <= 1'b0;
    else if(abort_go)   // 20261018 mrd:
        tx_busy <= 1'b0;
    else if(~(|mrd_length) && tx_done)
        tx_busy <= 1'b0;
    else if(start)   // 20261018 mrd:
        tx_busy <= 1'b1;
end



always@(posedge clk or negedge rst_n)begin
    if(!rst_n)
        tx_busy_d1 <= 1'b0;
    else
        tx_busy_d1 <= tx_busy;
end

assign tx_busy_ne = ~tx_busy && tx_busy_d1;


//ack
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        o_mrd32_req_ack <= 1'b0;
    else if(!i_mrd32_req)
        o_mrd32_req_ack <= 1'b0;
    else if(i_mrd32_req && !cmd_active && !i_start_block)   // 20261018 ddr:
        o_mrd32_req_ack <= 1'b1;
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        o_mrd64_req_ack <= 1'b0;
    else if(!i_mrd64_req)
        o_mrd64_req_ack <= 1'b0;
    else if(i_mrd64_req && !cmd_active && !i_start_block)   // 20261018 ddr:
        o_mrd64_req_ack <= 1'b1;
end

//when i_axis_slave1_trdy down,hold all tx logic
assign mrd_tx_hold = ~i_axis_slave1_trdy && i_axis_slave1_tvld;


//**********************************************************************
// 20261018 mrd: outstanding request / tag management

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        issue_pending <= 1'b0;
    else if(start || abort_go)
        issue_pending <= 1'b0;
    else if(|mrd_length && tx_done)
        issue_pending <= 1'b1;
    else if(fire)
        issue_pending <= 1'b0;
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        chunk_cnt <= 16'd0;   // 20261018 mrd:
    else if(start || abort_go)
        chunk_cnt <= 16'd0;
    else if(tx_done)
        chunk_cnt <= chunk_cnt + 16'd1;
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        busy_map <= 32'd0;   // 20261018 mrd:
    else if(abort_go)
        busy_map <= 32'd0;
    else
        busy_map <= (busy_map | (tx_done ? (32'd1 << chunk_cnt[4:0]) : 32'd0)) & ~(tag_clr ? (32'd1 << i_tag_free) : 32'd0);
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        out_cnt <= 6'd0;   // 20261018 mrd:
    else if(abort_go)
        out_cnt <= 6'd0;
    else
        out_cnt <= out_cnt + (tx_done ? 6'd1 : 6'd0) - (tag_clr ? 6'd1 : 6'd0);
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        max_out <= 6'd0;   // 20261018 mrd:
    else if(start)
        max_out <= 6'd0;
    else if(out_cnt > max_out)
        max_out <= out_cnt;
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        abort_req <= 1'b0;   // 20261018 mrd:
    else if(abort_go)
        abort_req <= 1'b0;
    else if(i_mrd_abort)
        abort_req <= 1'b1;
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        done_dly <= 5'd0;   // 20261018 mrd:
    else if(start || abort_go)
        done_dly <= 5'd0;
    else if(done_cond)
        done_dly <= (done_dly == 5'd16) ? 5'd0 : done_dly + 5'd1;
    else
        done_dly <= 5'd0;
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        cmd_active <= 1'b0;   // 20261018 mrd:
    else if(abort_go)
        cmd_active <= 1'b0;
    else if(start)
        cmd_active <= 1'b1;
    else if(done_fire)
        cmd_active <= 1'b0;
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        o_mrd_done <= 1'b0;   // 20261018 mrd:
    else
        o_mrd_done <= done_fire;
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        o_mrd_start <= 1'b0;   // 20261018 mrd:
    else
        o_mrd_start <= start;
end

// 20261018 ddr: doorbell request acknowledged, same cycle as o_mrd_start
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        o_db_ack <= 1'b0;   // 20261018 ddr:
    else
        o_db_ack <= start_db;   // 20261018 ddr:
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
    begin
        o_chunk_wr_en  <= 1'b0;   // 20261018 mrd:
        o_chunk_wr_tag <= 5'd0;
        o_chunk_wr_idx <= 16'd0;
    end
    else
    begin
        o_chunk_wr_en  <= tx_done;
        o_chunk_wr_tag <= chunk_cnt[4:0];
        o_chunk_wr_idx <= chunk_cnt;
    end
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        o_stat_issued <= 32'd0;   // 20261018 mrd:
    else if(start)
        o_stat_issued <= 32'd0;
    else if(tx_done)
        o_stat_issued <= o_stat_issued + 32'd1;
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        o_stat_freed <= 32'd0;   // 20261018 mrd:
    else if(start)
        o_stat_freed <= 32'd0;
    else if(tag_clr)
        o_stat_freed <= o_stat_freed + 32'd1;
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        o_stat_cycles <= 32'd0;   // 20261018 mrd:
    else if(start)
        o_stat_cycles <= 32'd0;
    else if(cmd_active)
        o_stat_cycles <= o_stat_cycles + 32'd1;
end

assign o_stat_busy_map = busy_map;   // 20261018 mrd:
assign o_stat_word = {cmd_active, tx_busy, issue_pending, 5'd0, 2'd0, limit_eff, 2'd0, max_out, 2'd0, out_cnt};   // 20261018 mrd:

endmodule
