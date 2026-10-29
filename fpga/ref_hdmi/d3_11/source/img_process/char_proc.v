//字符叠加
module char_proc(
    input              pix_clk,    //像素时钟
    input              rst_n,
    input              i_de ,
    input [11:0]       x_act,    //横
    input [11:0]       y_act,    //纵


    output reg         o_de    ,
    output reg         o_rgb  

   );

localparam CHAR_X_START = 12'd1500;//起始的横坐标
localparam CHAR_Y_START = 12'd750;//起始的纵坐标
localparam CHAR_WIDTH = 12'd128;//字符宽度
localparam CHAR_HEIGHT = 12'd32;//字符高度

//字模
wire [127:0] char_1 = 128'h00000000000000000000000000000000  ;
wire [127:0] char_2 = 128'h00000000000000000000000000000000  ;
wire [127:0] char_3 = 128'h00002000000100000000000000400000  ;
wire [127:0] char_4 = 128'h003038000001C0000800001000700018  ;
wire [127:0] char_5 = 128'h002030600001800007FFFFF800E00018  ;
wire [127:0] char_6 = 128'h042030F0020180000400003000D80018  ;
wire [127:0] char_7 = 128'h062331800181818004000030018E0018  ;
wire [127:0] char_8 = 128'h063FB60000C183800400003001830018  ;
wire [127:0] char_9 = 128'h06203800006183000400063001018418  ;
wire [127:0] char_10= 128'h062030080071860004FFFF300301C618  ;
wire [127:0] char_11= 128'h06203008003186000400003002008418  ;
wire [127:0] char_12= 128'h0621B018003184000400003004000418  ;
wire [127:0] char_13= 128'h063E381C00018810040000300C020418  ;
wire [127:0] char_14= 128'h1FC31FF800019030040008300FFF0418  ;
wire [127:0] char_15= 128'h1C0600003FFFFFF8041FFE3016060418  ;
wire [127:0] char_16= 128'h101808000018300004100C3026060418  ;
wire [127:0] char_17= 128'h00201E000018300004100C3046060418  ;
wire [127:0] char_18= 128'h00CFF0000018300004100C3006060418  ;
wire [127:0] char_19= 128'h00F0C0000018300004100C3006060418  ;
wire [127:0] char_20= 128'h00030C000018300004100C3006060418  ;
wire [127:0] char_21= 128'h000C07000010300004100C3006060418  ;
wire [127:0] char_22= 128'h007003C000303000041FFC30063C0418  ;
wire [127:0] char_23= 128'h03FFFCC00030300804100C3006180418  ;
wire [127:0] char_24= 128'h03E180C00020300804100C3006004018  ;
wire [127:0] char_25= 128'h00218040006030080400003006004018  ;
wire [127:0] char_26= 128'h00718C00004030080400003006004018  ;
wire [127:0] char_27= 128'h00F1838000C030080400003006004018  ;
wire [127:0] char_28= 128'h018181E00100300C040000300200C018  ;
wire [127:0] char_29= 128'h061F80E006003FFC040003F003FFE3F8  ;
wire [127:0] char_30= 128'h1803806018001FF80C0000E003FFC0F0  ;
wire [127:0] char_31= 128'h20030020600000000C00004000000020  ;
wire [127:0] char_32= 128'h00000000000000000000000000000000  ;
                           
reg [11:0] x_cnt;
reg char_de;
always@(posedge pix_clk or negedge rst_n)begin
    if(!rst_n) begin
        x_cnt <= 12'd0;
        char_de <= 1'b0;
    end
    else begin
        x_cnt <= x_act-CHAR_X_START;
        char_de <= (x_act >= CHAR_X_START) && (x_act < CHAR_X_START+CHAR_WIDTH)&&(y_act >= CHAR_Y_START) && (y_act < CHAR_Y_START+CHAR_HEIGHT);
    end
end
                    
always@(posedge pix_clk)
begin
    if(char_de) begin
        case(y_act-CHAR_Y_START)
            15'd0 : begin if(char_1[CHAR_WIDTH-1-x_cnt])  o_rgb<= 1'b1; else o_rgb<= 0 ;end
            15'd1 : begin if(char_2[CHAR_WIDTH-1-x_cnt])  o_rgb<= 1'b1; else o_rgb<= 0 ;end
            15'd2 : begin if(char_3[CHAR_WIDTH-1-x_cnt])  o_rgb<= 1'b1; else o_rgb<= 0 ;end
            15'd3 : begin if(char_4[CHAR_WIDTH-1-x_cnt])  o_rgb<= 1'b1; else o_rgb<= 0 ;end
            15'd4 : begin if(char_5[CHAR_WIDTH-1-x_cnt])  o_rgb<= 1'b1; else o_rgb<= 0 ;end
            15'd5 : begin if(char_6[CHAR_WIDTH-1-x_cnt])  o_rgb<= 1'b1; else o_rgb<= 0 ;end
            15'd6 : begin if(char_7[CHAR_WIDTH-1-x_cnt])  o_rgb<= 1'b1; else o_rgb<= 0 ;end
            15'd7 : begin if(char_8[CHAR_WIDTH-1-x_cnt])  o_rgb<= 1'b1; else o_rgb<= 0 ;end
            15'd8 : begin if(char_9[CHAR_WIDTH-1-x_cnt])  o_rgb<= 1'b1; else o_rgb<= 0 ;end
            15'd9 : begin if(char_10[CHAR_WIDTH-1-x_cnt])  o_rgb<= 1'b1; else o_rgb<= 0 ;end
            15'd10: begin if(char_11[CHAR_WIDTH-1-x_cnt])  o_rgb<= 1'b1; else o_rgb<= 0; end
            15'd11: begin if(char_12[CHAR_WIDTH-1-x_cnt])  o_rgb<= 1'b1; else o_rgb<= 0; end
            15'd12: begin if(char_13[CHAR_WIDTH-1-x_cnt])  o_rgb<= 1'b1; else o_rgb<= 0; end
            15'd13: begin if(char_14[CHAR_WIDTH-1-x_cnt])  o_rgb<= 1'b1; else o_rgb<= 0; end
            15'd14: begin if(char_15[CHAR_WIDTH-1-x_cnt])  o_rgb<= 1'b1; else o_rgb<= 0; end
            15'd15: begin if(char_16[CHAR_WIDTH-1-x_cnt])  o_rgb<= 1'b1; else o_rgb<= 0; end
            15'd16: begin if(char_17[CHAR_WIDTH-1-x_cnt])  o_rgb<= 1'b1; else o_rgb<= 0; end
            15'd17: begin if(char_18[CHAR_WIDTH-1-x_cnt])  o_rgb<= 1'b1; else o_rgb<= 0; end
            15'd18: begin if(char_19[CHAR_WIDTH-1-x_cnt])  o_rgb<= 1'b1; else o_rgb<= 0; end
            15'd19: begin if(char_20[CHAR_WIDTH-1-x_cnt])  o_rgb<= 1'b1; else o_rgb<= 0; end
            15'd20: begin if(char_21[CHAR_WIDTH-1-x_cnt])  o_rgb<= 1'b1; else o_rgb<= 0; end
            15'd21: begin if(char_22[CHAR_WIDTH-1-x_cnt])  o_rgb<= 1'b1; else o_rgb<= 0; end
            15'd22: begin if(char_23[CHAR_WIDTH-1-x_cnt])  o_rgb<= 1'b1; else o_rgb<= 0; end
            15'd23: begin if(char_24[CHAR_WIDTH-1-x_cnt])  o_rgb<= 1'b1; else o_rgb<= 0; end
            15'd24: begin if(char_25[CHAR_WIDTH-1-x_cnt])  o_rgb<= 1'b1; else o_rgb<= 0; end
            15'd25: begin if(char_26[CHAR_WIDTH-1-x_cnt])  o_rgb<= 1'b1; else o_rgb<= 0; end
            15'd26: begin if(char_27[CHAR_WIDTH-1-x_cnt])  o_rgb<= 1'b1; else o_rgb<= 0; end
            15'd27: begin if(char_28[CHAR_WIDTH-1-x_cnt])  o_rgb<= 1'b1; else o_rgb<= 0; end
            15'd28: begin if(char_29[CHAR_WIDTH-1-x_cnt])  o_rgb<= 1'b1; else o_rgb<= 0; end
            15'd29: begin if(char_30[CHAR_WIDTH-1-x_cnt])  o_rgb<= 1'b1; else o_rgb<= 0; end
            15'd30: begin if(char_31[CHAR_WIDTH-1-x_cnt])  o_rgb<= 1'b1; else o_rgb<= 0; end
            15'd31: begin if(char_32[CHAR_WIDTH-1-x_cnt])  o_rgb<= 1'b1; else o_rgb<= 0; end

        default: o_rgb<= 0;
        endcase  
    end
    else     
        o_rgb<= 0;
end

reg    o_de_d;
always@(posedge pix_clk or negedge rst_n)    begin
    if(!rst_n)
    begin
        o_de_d  <=    1'd0;
        o_de    <=    1'd0;
    end
    else     
    begin
        o_de_d  <=    i_de;
        o_de    <=    o_de_d;
    end
end
endmodule