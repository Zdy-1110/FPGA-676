
//////////////////////////////////////////////////////////////////////////////
module rt_cpld_128_wr_finish
(
    input                               clk                     ,   //gen1:62.5MHz,gen2:125MHz
    input                               rst_n                   ,
    //**********************************************************************
    input       [10:0]                  i_mem_length            ,  //单位：dw

	input                               i_wr_en                 ,
    output reg                          o_cpld_128_wr_ram_finish           	          
);

reg wr_ram_done;

reg [8:0] data_length_128bit;
always @(posedge clk or negedge rst_n)
begin
    if (!rst_n)
        data_length_128bit <= 'd0;
	else
        data_length_128bit <= {i_mem_length[10:2]};	 
end

reg [8:0] wr_en_cnt;
always @(posedge clk or negedge rst_n)
begin
    if (!rst_n)
        wr_en_cnt <= 'd0;
	else if(wr_ram_done)
        wr_en_cnt <= 'd0;
	else if(i_wr_en)
        wr_en_cnt <= wr_en_cnt + 1'b1;	
    else 
        wr_en_cnt <= wr_en_cnt ;        	
end

always @(posedge clk or negedge rst_n)
begin
    if (!rst_n)
        wr_ram_done <= 1'b0;
	else if(i_wr_en)begin
	    if(data_length_128bit=='d0)
           wr_ram_done <= 1'b1;	
        else if(wr_en_cnt == (data_length_128bit - 1))
           wr_ram_done <= 1'b1;
        else
		   wr_ram_done <= 1'b0; 
	end
	else
		wr_ram_done <= 1'b0; 	
end



////
reg wr_ram_done_d1;
reg wr_ram_done_d2;
always@(posedge clk or negedge rst_n)
begin
    if(!rst_n) begin
        wr_ram_done_d1 <= 1'b0;
        wr_ram_done_d2 <= 1'b0;
	end
    else begin
        wr_ram_done_d1 <=  wr_ram_done;
        wr_ram_done_d2 <=  wr_ram_done_d1;
	end
end

wire wr_ram_done_ne = ~wr_ram_done_d1 && wr_ram_done_d2;


always@(posedge clk or negedge rst_n)
begin
    if(!rst_n)
        o_cpld_128_wr_ram_finish <= 1'b0;
    else
        o_cpld_128_wr_ram_finish <=  wr_ram_done_ne;
end

endmodule
