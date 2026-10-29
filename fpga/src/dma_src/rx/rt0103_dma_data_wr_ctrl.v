

//////////////////////////////////////////////////////////////////////////////
module rt0103_dma_data_wr_ctrl (
    input                           clk         ,   //gen1:62.5MHz,gen2:125MHz
    input                           rst_n       ,

    //**********************************************************************
    input       [2:0]               i_bar_sel   ,
    input                           i_de        ,
    input       [9:0]               i_length    ,
    input       [7:0]               i_dwbe      ,
    input       [127:0]             i_data      ,
    input       [3:0]               i_dw_vld    ,
    input       [63:0]              i_addr      ,
    input                           i_data_flag ,

    //**********************************************************************
    //ram write control
	output reg  [2:0]               o_wr_bar_sel,
    output reg                      o_wr_en     ,
    output reg  [63:0]              o_wr_addr   ,
    output reg  [127:0]             o_wr_data   ,
    output reg  [15:0]              o_wr_be     
);

reg             i_data_flag_d1;
wire            i_data_flag_pe;
reg             i_data_flag_pe_d1;
wire            i_data_flag_ne;

reg     [9:0]   length;
reg     [3:0]   dw_vld;
reg     [7:0]   dwbe;

reg     [15:0]  byte_en;
reg     [15:0]  byte_en_ff;
wire    [31:0]  byte_en_shift;
reg     [15:0]  dw_vld_shift_out;

reg     [3:0]   last_dw_position;
wire    [15:0]  last_data_be;

reg     [1:0]   data_position;
reg     [127:0] data_ff;
reg     [127:0] data_ff2;
wire    [255:0] data_shift;
reg     [127:0] data_shift_out;

reg     [63:0]  wr_addr;

reg i_de_d1;
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        i_de_d1 <= 1'b0;
    else
        i_de_d1 <=  i_de;
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        i_data_flag_d1 <= 1'b0;
    else
        i_data_flag_d1 <=  i_data_flag;
end
assign i_data_flag_pe = i_data_flag & ~i_data_flag_d1;
assign i_data_flag_ne  = ~i_data_flag & i_data_flag_d1;


//**********************************************************************gen byte enbale from dwbe and dw_vld***************************************************************************


always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        i_data_flag_pe_d1 <= 1'b0;
    else
        i_data_flag_pe_d1 <= i_data_flag_pe;
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        length <= 10'b0;
    else if(i_data_flag_pe)
        length <= i_length;
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        dw_vld <= 4'b0;
    else
        dw_vld <= i_dw_vld;
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        dwbe <= 8'b0;
    else if(i_data_flag_pe)
        dwbe <= i_dwbe;
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        last_dw_position <= 4'b0;
    else if(i_data_flag_pe)
        case(i_length[1:0])
            2'd0: last_dw_position <= 4'b1000;
            2'd1: last_dw_position <= 4'b0001;
            2'd2: last_dw_position <= 4'b0010;
            2'd3: last_dw_position <= 4'b0100;
        default: last_dw_position <= 4'b0000;
    endcase
end

assign last_data_be[4*0+3:4*0] = last_dw_position[0] ? (dwbe[7:4] & {4{dw_vld[0]}}) : {4{dw_vld[0]}};
assign last_data_be[4*1+3:4*1] = last_dw_position[1] ? (dwbe[7:4] & {4{dw_vld[1]}}) : {4{dw_vld[1]}};
assign last_data_be[4*2+3:4*2] = last_dw_position[2] ? (dwbe[7:4] & {4{dw_vld[2]}}) : {4{dw_vld[2]}};
assign last_data_be[4*3+3:4*3] = last_dw_position[3] ? (dwbe[7:4] & {4{dw_vld[3]}}) : {4{dw_vld[3]}};

//gen byte_en
always@(*)
begin
    if(i_data_flag_d1)
    begin
        if(length == 10'b1)
            byte_en = {12'b0,dwbe[3:0]};
        else
        begin
            byte_en[4*0+3:4*0] = i_data_flag_pe_d1 ? dwbe[3:0] : (i_data_flag_ne ? last_data_be[4*0+3:4*0] : {4{dw_vld[0]}});
            byte_en[4*1+3:4*1] = i_data_flag_ne ? last_data_be[4*1+3:4*1] : {4{dw_vld[1]}};
            byte_en[4*2+3:4*2] = i_data_flag_ne ? last_data_be[4*2+3:4*2] : {4{dw_vld[2]}};
            byte_en[4*3+3:4*3] = i_data_flag_ne ? last_data_be[4*3+3:4*3] : {4{dw_vld[3]}};
        end
    end
    else
        byte_en = 16'b0;
end

//**********************************************************************data shift***************************************************************************
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        data_position <= 2'b0;
    else if(i_data_flag_pe)
        data_position <= i_addr[3:2];
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
    begin
        data_ff  <= 128'b0;
        data_ff2 <= 128'b0;
    end
    else
    begin
        data_ff  <= i_data;
        data_ff2 <= data_ff;
    end
end
//data shift
assign data_shift = {data_ff,data_ff2};

always@(*)
begin
    case(data_position)
        2'd0:  data_shift_out   = data_shift[32*8-1:32*4];
        2'd1:  data_shift_out   = data_shift[32*7-1:32*3];
        2'd2:  data_shift_out   = data_shift[32*6-1:32*2];
        2'd3:  data_shift_out   = data_shift[32*5-1:32*1];
        default: data_shift_out = 128'b0;
    endcase
end

//**********************************************************************byte_en shift***************************************************************************
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        byte_en_ff <= 16'b0;
    else
        byte_en_ff <= byte_en;
end
//dw_vld shift
assign byte_en_shift[31:0] = {byte_en,byte_en_ff};

always@(*)
begin
    case(data_position)
        2'd0:  dw_vld_shift_out   = byte_en_shift[4*8-1:4*4];
        2'd1:  dw_vld_shift_out   = byte_en_shift[4*7-1:4*3];
        2'd2:  dw_vld_shift_out   = byte_en_shift[4*6-1:4*2];
        2'd3:  dw_vld_shift_out   = byte_en_shift[4*5-1:4*1];
        default: dw_vld_shift_out = 16'b0;
    endcase
end

//**********************************************************************gen bar write ctrl***************************************************************************

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        o_wr_en <= 1'b0;
    else 
        o_wr_en <= i_de_d1;
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        wr_addr <= 64'b0;
    else if(i_data_flag_pe)
        wr_addr <= i_addr;
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        o_wr_addr <= 64'b0;
    else if(i_data_flag_pe_d1)
        o_wr_addr <= {4'b0,wr_addr[63:4]};
    else if(o_wr_en)
        o_wr_addr <= o_wr_addr + 1'b1;
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        o_wr_data <= 128'b0;
    else
        o_wr_data <= data_shift_out;
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        o_wr_be <= 16'b0;
    else
        o_wr_be <= dw_vld_shift_out;
end

always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        o_wr_bar_sel <= 3'b0;
    else if(i_data_flag_pe)
        o_wr_bar_sel <= i_bar_sel;
end

endmodule
