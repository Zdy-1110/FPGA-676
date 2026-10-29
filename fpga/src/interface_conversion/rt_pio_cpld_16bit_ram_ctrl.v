

//////////////////////////////////////////////////////////////////////////////
module rt_pio_cpld_16bit_ram_ctrl
(
    input                               clk                     ,   //gen1:62.5MHz,gen2:125MHz
    input                               rst_n                   ,
    //**********************************************************************
    input       [10:0]                  i_mem_length            ,  //总共长度 单位：dw
	input                               i_cpld_128_wr_ram_finish,
	
    output reg                          o_rd_en                 ,
    output reg  [31:0]                  o_rd_addr               ,
    input       [15:0]                  i_ram_data              ,
	
    input       [31:0]                  i_wr_base_ram_addr      ,

	output reg                          o_wr_en                 ,
    output reg  [31:0]                  o_wr_addr               ,
    output reg  [15:0]                  o_wr_data               ,
    output reg  [1:0]                   o_wr_be                 ,
	
    output reg                          o_cpld_finish           	          
);


reg [11:0] data_length_16bit;
always @(posedge clk or negedge rst_n)
begin
    if (!rst_n)
        data_length_16bit <= 'd0;
	else if(i_cpld_128_wr_ram_finish)
        data_length_16bit <= {i_mem_length,1'b0};	
    else
        data_length_16bit <= data_length_16bit;	       	
end

// reg o_rd_en;                                                       
reg [31:0] rd_en_cnt;                                         
always @(posedge clk or negedge rst_n)begin
    if(~rst_n)
        rd_en_cnt <= 'd0;
    else if(o_rd_en)
        rd_en_cnt <= rd_en_cnt + 1'b1;		
	else
        rd_en_cnt <= 'd0; 
end

always @(posedge clk or negedge rst_n)begin
    if(~rst_n)
        o_rd_en <= 1'b0;
    else if(i_cpld_128_wr_ram_finish)
        o_rd_en <= 1'b1;		
	else if(rd_en_cnt==(data_length_16bit - 1'b1))
        o_rd_en <= 1'b0;		
	else
	    o_rd_en <= o_rd_en;
end

// assign o_rd_addr = rd_en_cnt;

                                       
always @(posedge clk or negedge rst_n)begin
    if(~rst_n)
        o_rd_addr <= 'd0;
    else if(i_cpld_128_wr_ram_finish)
        o_rd_addr <= {1'b0,i_wr_base_ram_addr[31:1]};	
    else if(o_rd_en)
        o_rd_addr <= o_rd_addr + 1'b1;		
	else
        o_rd_addr <= 'd0; 
end



//////////////////////////////////
reg o_rd_en_d1;
always @(posedge clk or negedge rst_n)begin
    if(~rst_n)
        o_rd_en_d1 <= 1'b0;	
	else
        o_rd_en_d1 <= o_rd_en; 
end

always @(posedge clk or negedge rst_n)begin
    if(~rst_n)
        o_wr_data <= 'd0;	
	else
        o_wr_data <= i_ram_data; 
end
always @(posedge clk or negedge rst_n)begin
    if(~rst_n)
        o_wr_en <= 1'b0;	
	else
        o_wr_en <= o_rd_en_d1; 
end

always @(posedge clk or negedge rst_n)begin
    if(~rst_n)
        o_wr_addr <= 'd0;	
	else if(i_cpld_128_wr_ram_finish)
        o_wr_addr <= {1'b0,i_wr_base_ram_addr[31:1]};		
	else if(o_wr_en)
        o_wr_addr <= o_wr_addr + 1'b1;		
	else
	    o_wr_addr <= o_wr_addr;
end

always @(posedge clk or negedge rst_n)begin
    if(~rst_n)
        o_wr_be <= 2'b00;				
	else
	    o_wr_be <= 2'b11;
end


reg o_wr_en_d1;
always @(posedge clk or negedge rst_n)begin
    if(~rst_n)
        o_wr_en_d1 <= 1'b0;				
	else
	    o_wr_en_d1 <= o_wr_en;
end

wire o_wr_en_ne = ~o_wr_en & o_wr_en_d1;

always @(posedge clk or negedge rst_n)begin
    if(~rst_n)
        o_cpld_finish <= 1'b0;				
	else
	    o_cpld_finish <= o_wr_en_ne;
end

endmodule
