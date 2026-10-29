

//////////////////////////////////////////////////////////////////////////////
module rt_pio_mwr_16bit_ram_ctrl (
    input                               clk                     ,   //gen1:62.5MHz,gen2:125MHz
    input                               rst_n                   ,

    input                               i_rd_16in_16out_ram_en  ,
    input        [9:0]                  i_rd_length            ,
 //to 16in_16out	
    output reg                          o_rd_en                 ,
    output reg   [31:0]                 o_rd_addr               ,
    input        [15:0]                 i_ram_data              ,

    input        [31:0]                 i_rd_base_ram_addr      ,	
 //to 16in_128out	
	output reg                          o_wr_en                 ,
    output reg   [31:0]                 o_wr_addr               ,
    output reg   [15:0]                 o_wr_data               ,
    output reg   [1:0]                  o_wr_be                 ,	
	
    output reg                          o_mwr_16_wr_ram_done
);


reg mwr_req_en/* synthesis PAP_MARK_DEBUG=”true”*/;
always @(posedge clk or negedge rst_n)begin
    if(~rst_n)
        mwr_req_en <= 1'b0;	
	else
        mwr_req_en <= i_rd_16in_16out_ram_en; 
end

reg [10:0] data_length_16bit;
always @(posedge clk or negedge rst_n)
begin
    if (!rst_n)
        data_length_16bit <= 'd0;
	else if(mwr_req_en)
        data_length_16bit <= {i_rd_length,1'b0};	
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
    else if(mwr_req_en)
        o_rd_en <= 1'b1;		
	else if(rd_en_cnt==(data_length_16bit - 1'b1))
        o_rd_en <= 1'b0;		
	else
	    o_rd_en <= o_rd_en;
end
                                       
always @(posedge clk or negedge rst_n)begin
    if(~rst_n)
        o_rd_addr <= 'd0;
    else if(i_rd_16in_16out_ram_en)
        o_rd_addr <= {1'b0,i_rd_base_ram_addr[31:1]};	
    else if(o_rd_en)
        o_rd_addr <= o_rd_addr + 1'b1;		
	else
        o_rd_addr <= o_rd_addr; 
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
	else if(i_rd_16in_16out_ram_en)
        o_wr_addr <= {1'b0,i_rd_base_ram_addr[31:1]};			
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
        o_mwr_16_wr_ram_done <= 1'b0;				
	else
	    o_mwr_16_wr_ram_done <= o_wr_en_ne;
end

endmodule
