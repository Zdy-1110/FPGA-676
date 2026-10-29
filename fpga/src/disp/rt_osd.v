`timescale 1ns/1ps
//////////////////////////////////////////////////////////////////////////////
// rt_osd.v  (20261018 osd1)
// Pixel-domain OSD overlay, inserted between the DDR reader (YUV->RGB) and the
// output register stage.  Layers, bottom to top:
//   1 alarm border   2 detection boxes   3 y_top / y_bot lines
//   4 guide rays     5 crosshair         6 arrow icons   7 text
// Coordinates are 1920x1080 display coordinates aligned to the incoming video.
//////////////////////////////////////////////////////////////////////////////
module rt_osd #(
    parameter H_ACT = 1920,
    parameter V_ACT = 1080
)(
    input               pix_clk       ,
    input               rst_n         ,

    // video in (already 5-cycle delayed by rt_disp_reader)
    input       [7:0]   r_in          ,
    input       [7:0]   g_in          ,
    input       [7:0]   b_in          ,
    input               de_in         ,
    input               hs_in         ,
    input               vs_in         ,
    // raw pixel coordinates from sync_vg (delayed internally by 5)
    input       [11:0]  x_act         ,
    input       [11:0]  y_act         ,

    // enable + registers (pixel domain, latched by rt_osd_ctl)
    input               osd_en        ,   // DISP_CTRL[2]
    input       [31:0]  dec           ,   // DECISION
    input       [31:0]  osdctrl       ,   // OSD_CTRL
    input       [831:0] box           ,   // 16 x {color,y1,x1,y0,x0}
    input       [11:0]  vp_x          ,
    input       [11:0]  vp_y          ,
    input       [11:0]  y_top         ,
    input       [11:0]  y_bot         ,
    input       [11:0]  g             ,
    input               cal_mode      ,
    input       [1:0]   obj           ,
    input               cal_blink     ,
    input       [511:0] status_line   ,

    // text RAM write port (pclk domain)
    input               tram_wclk     ,
    input               tram_we       ,
    input       [5:0]   tram_addr     ,
    input       [31:0]  tram_wdata    ,

    // 20261028 lane line overlay inputs
    input  wire         lane_draw_en  ,   // LANE_CTRL[1]
    input  wire         lane_l_valid  ,
    input  wire         lane_l_solid  ,
    input  wire [11:0]  lane_l_ytop   ,
    input  wire [11:0]  lane_l_ybot   ,
    input  wire [31:0]  lane_l_x_top  ,
    input  wire [31:0]  lane_l_dx     ,
    input  wire         lane_r_valid  ,
    input  wire         lane_r_solid  ,
    input  wire [11:0]  lane_r_ytop   ,
    input  wire [11:0]  lane_r_ybot   ,
    input  wire [31:0]  lane_r_x_top  ,
    input  wire [31:0]  lane_r_dx     ,

    // video out

    output reg  [7:0]   r_out         ,
    output reg  [7:0]   g_out         ,
    output reg  [7:0]   b_out         ,
    output reg          de_out        ,
    output reg          hs_out        ,
    output reg          vs_out
);

    //------------------------------------------------------------------
    // text RAM : 64 x 32 (byte offset r*64+c -> DW r*16 + c/4)
    //------------------------------------------------------------------
    reg [31:0] tram [0:63];
    always @(posedge tram_wclk)
        if (tram_we) tram[tram_addr[5:0]] <= tram_wdata;

    //------------------------------------------------------------------
    // coordinate alignment : x_act/y_act delayed 5 to match r_in
    //------------------------------------------------------------------
    reg [11:0] xsh [0:4];
    reg [11:0] ysh [0:4];
    integer    si;
    always @(posedge pix_clk) begin
        xsh[0] <= x_act; ysh[0] <= y_act;
        for (si=1; si<5; si=si+1) begin
            xsh[si] <= xsh[si-1]; ysh[si] <= ysh[si-1];
        end
    end
    wire [11:0] xa = xsh[4];
    wire [11:0] ya = ysh[4];

    //------------------------------------------------------------------
    // text / arrow addressing (combinational on the aligned coords)
    //------------------------------------------------------------------
    wire        in_text = (xa>=12'd16) && (xa<12'd1040) &&
                          (ya>=12'd16) && (ya<12'd196);
    wire [11:0] tyrel   = ya - 12'd16;
    wire [5:0]  trow    = tyrel / 12'd36;        // 0..4
    wire [5:0]  tlrem   = tyrel % 12'd36;        // 0..35
    wire [5:0]  tcol    = (xa - 12'd16) >> 4;    // 0..63
    wire        tcell   = in_text && (tlrem < 12'd32);
    wire [2:0]  tgx     = ((xa-12'd16) >> 1) & 3'h7;   // 0..7 glyph column
    wire [3:0]  tgy     = tlrem >> 1;            // 0..15
    wire [5:0]  t_ram_addr = {trow[1:0], tcol[5:2]};   // r*16 + c/4  (r<4 valid)
    wire [31:0] t_ram_dw   = tram[t_ram_addr];
    wire [7:0]  t_char     = (trow < 6'd4) ? t_ram_dw[{tcol[1:0],3'b000} +: 8]
                                           : status_line[{tcol,3'b000} +: 8];
    wire [6:0]  fch    = t_char[6:0];
    wire [3:0]  frow   = tgy;
    wire [7:0]  fbits;

    //------------------------------------------------------------------
    // arrow addressing : 3 regions of 96x96 at x=792/912/1032, y=960
    //------------------------------------------------------------------
    wire [11:0] ax0 = (xa>=12'd1032) ? 12'd1032 : ((xa>=12'd912) ? 12'd912 : 12'd792);
    wire [1:0]  akk = (xa>=12'd1032) ? 2'd2 : ((xa>=12'd912) ? 2'd1 : 2'd0);
    wire        in_arrow = (ya>=12'd960) && (ya<12'd1056) &&
                           (xa>=12'd792) && (xa<12'd1128);
    wire [4:0]  aix  = (xa-ax0) >> 2;             // 0..23
    wire [4:0]  arow = (ya-12'd960) >> 2;         // 0..23
    wire [1:0]  asel = akk;
    wire [23:0] abits;
    wire [1:0]  astat = dec[{akk,1'b0} +: 2];     // DECISION[1:0],[3:2],[5:4]

    font8x16_rom u_font  (.clk(pix_clk), .ch(fch),  .row(frow),  .bits(fbits));
    arrow24_rom  u_arrow (.clk(pix_clk), .sel(asel), .row(arow), .bits(abits));

    //------------------------------------------------------------------
    // stage 1 : carry coords + rom selection info
    //------------------------------------------------------------------
    reg [11:0] x1, y1;
    reg [7:0]  r1, g1, b1;
    reg        de1, hs1, vs1;
    reg        tcell1;  reg [2:0] tgx1;
    reg        arr1;    reg [4:0] aix1; reg [1:0] astat1;
    always @(posedge pix_clk or negedge rst_n)
    begin
        if (!rst_n) begin
            x1<=0; y1<=0; r1<=0; g1<=0; b1<=0; de1<=0; hs1<=0; vs1<=0;
            tcell1<=0; tgx1<=0; arr1<=0; aix1<=0; astat1<=0;
        end
        else begin
            x1<=xa; y1<=ya; r1<=r_in; g1<=g_in; b1<=b_in;
            de1<=de_in; hs1<=hs_in; vs1<=vs_in;
            tcell1 <= tcell && (t_char!=8'h20) && (t_char!=8'h00);
            tgx1   <= tgx[2:0];
            arr1   <= in_arrow;
            aix1   <= aix;
            astat1 <= astat;
        end
    end
    wire fbit = fbits[7-tgx1];
    wire abit = abits[23-aix1];

    //------------------------------------------------------------------
    // ray slope : dx = (g<<16)/(y_bot-vp_y) computed sequentially in blank
    //------------------------------------------------------------------
    reg vs_r1, vs_r2;
    wire vs_rise = vs_r1 & ~vs_r2;
    wire [11:0] dy12 = (y_bot > vp_y) ? (y_bot - vp_y) : 12'd1;

    localparam DIV_IDLE=2'd0, DIV_RUN=2'd1, DIV_DONE=2'd2;
    reg [1:0]  dstate;
    reg [5:0]  dcnt;
    reg [31:0] div_n, div_q;
    reg [12:0] div_rem;
    reg [11:0] div_d;
    reg [31:0] dx;

    always @(posedge pix_clk or negedge rst_n)
    begin
        if (!rst_n) begin
            vs_r1<=0; vs_r2<=0;
            dstate<=DIV_IDLE; dcnt<=0; div_n<=0; div_q<=0; div_rem<=0; div_d<=0; dx<=0;
        end
        else begin
            vs_r1 <= vs_in; vs_r2 <= vs_r1;
            case (dstate)
                DIV_IDLE: if (vs_rise) begin
                    div_n   <= {20'd0, g} << 16;
                    div_d   <= dy12;
                    div_rem <= 13'd0;
                    div_q   <= 32'd0;
                    dcnt    <= 6'd0;
                    dstate  <= DIV_RUN;
                end
                DIV_RUN: begin
                    if ({div_rem[11:0], div_n[31]} >= {1'b0, div_d}) begin
                        div_rem <= {div_rem[11:0], div_n[31]} - {1'b0, div_d};
                        div_q   <= {div_q[30:0], 1'b1};
                    end
                    else begin
                        div_rem <= {div_rem[11:0], div_n[31]};
                        div_q   <= {div_q[30:0], 1'b0};
                    end
                    div_n <= {div_n[30:0], 1'b0};
                    dcnt  <= dcnt + 1'b1;
                    if (dcnt == 6'd31) dstate <= DIV_DONE;
                end
                DIV_DONE: begin dx <= div_q; dstate <= DIV_IDLE; end
                default:  dstate <= DIV_IDLE;
            endcase
        end
    end

    //------------------------------------------------------------------
    // per-line ray offset accumulation
    //------------------------------------------------------------------
    reg [11:0] prev_y1;
    reg [31:0] ray_off;
    wire newline = de1 && (y1 != prev_y1);
    wire [31:0] off_next = (y1 == vp_y) ? 32'd0 :
                           ((y1 > vp_y && y1 <= y_bot) ? (ray_off + dx) : 32'd0);
    wire [31:0] off_now  = newline ? off_next : ray_off;
    always @(posedge pix_clk or negedge rst_n)
        if (!rst_n) begin prev_y1<=12'd0; ray_off<=32'd0; end
        else if (de1) begin
            prev_y1 <= y1;
            if (newline) ray_off <= off_next;
        end
    wire [11:0] off16 = off_now[27:16];

    //------------------------------------------------------------------
    // 20261028 lane line overlay accumulation (vs_rise latched parameters)
    //------------------------------------------------------------------
    reg        ll_valid_r, ll_solid_r;
    reg [11:0] ll_ytop_r,  ll_ybot_r;
    reg [31:0] ll_xtop_r,  ll_dx_r;
    reg        lr_valid_r, lr_solid_r;
    reg [11:0] lr_ytop_r,  lr_ybot_r;
    reg [31:0] lr_xtop_r,  lr_dx_r;
    reg        lane_draw_en_r;

    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            ll_valid_r     <= 1'b0; ll_solid_r <= 1'b0;
            ll_ytop_r      <= 12'd260; ll_ybot_r <= 12'd500;
            ll_xtop_r      <= 32'd0; ll_dx_r <= 32'd0;
            lr_valid_r     <= 1'b0; lr_solid_r <= 1'b0;
            lr_ytop_r      <= 12'd260; lr_ybot_r <= 12'd500;
            lr_xtop_r      <= 32'd0; lr_dx_r <= 32'd0;
            lane_draw_en_r <= 1'b0;
        end else if (vs_rise) begin
            ll_valid_r     <= lane_l_valid;
            ll_solid_r     <= lane_l_solid;
            ll_ytop_r      <= lane_l_ytop;
            ll_ybot_r      <= lane_l_ybot;
            ll_xtop_r      <= lane_l_x_top;
            ll_dx_r        <= lane_l_dx;

            lr_valid_r     <= lane_r_valid;
            lr_solid_r     <= lane_r_solid;
            lr_ytop_r      <= lane_r_ytop;
            lr_ybot_r      <= lane_r_ybot;
            lr_xtop_r      <= lane_r_x_top;
            lr_dx_r        <= lane_r_dx;

            lane_draw_en_r <= lane_draw_en;
        end
    end

    reg [31:0] lane_l_accum, lane_r_accum;
    wire [31:0] l_next = (y1 == ll_ytop_r) ? ll_xtop_r :
                         ((y1 > ll_ytop_r && y1 <= ll_ybot_r) ? (lane_l_accum + ll_dx_r) : 32'd0);
    wire [31:0] l_now  = newline ? l_next : lane_l_accum;

    wire [31:0] r_next = (y1 == lr_ytop_r) ? lr_xtop_r :
                         ((y1 > lr_ytop_r && y1 <= lr_ybot_r) ? (lane_r_accum + lr_dx_r) : 32'd0);
    wire [31:0] r_now  = newline ? r_next : lane_r_accum;

    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            lane_l_accum <= 32'd0;
            lane_r_accum <= 32'd0;
        end else if (de1) begin
            if (newline) begin
                lane_l_accum <= l_next;
                lane_r_accum <= r_next;
            end
        end
    end

    wire signed [13:0] l_x_int = $signed(l_now[29:16]);
    wire signed [13:0] r_x_int = $signed(r_now[29:16]);
    wire signed [13:0] x1_s    = $signed({2'b00, x1});

    // Valid only in x<960 and y<540, line width 3 pixels (-1, 0, +1)
    wire l_line_range = (y1 >= ll_ytop_r) && (y1 <= ll_ybot_r) && (x1 < 12'd960) && (y1 < 12'd540);
    wire l_line_hit   = lane_draw_en_r && ll_valid_r && l_line_range &&
                        ((x1_s - l_x_int) >= -14'sd1) && ((x1_s - l_x_int) <= 14'sd1);

    wire r_line_range = (y1 >= lr_ytop_r) && (y1 <= lr_ybot_r) && (x1 < 12'd960) && (y1 < 12'd540);
    wire r_line_hit   = lane_draw_en_r && lr_valid_r && r_line_range &&
                        ((x1_s - r_x_int) >= -14'sd1) && ((x1_s - r_x_int) <= 14'sd1);


    //------------------------------------------------------------------
    // 2 Hz alarm blink
    //------------------------------------------------------------------
    reg [26:0] hzcnt; reg hz2;
    always @(posedge pix_clk or negedge rst_n)
        if (!rst_n) begin hzcnt<=0; hz2<=0; end
        else if (hzcnt == 27'd37124999) begin hzcnt<=0; hz2<=~hz2; end
        else hzcnt <= hzcnt + 1'b1;

    //------------------------------------------------------------------
    // compose
    //------------------------------------------------------------------
    wire alarm  = dec[8] | osdctrl[7];
    wire border = (x1<12'd12)||(x1>=(H_ACT-12))||(y1<12'd12)||(y1>=(V_ACT-12));
    wire alarm_draw = alarm && border && (!osdctrl[10] || hz2);

    wire box_en   = osdctrl[4];
    wire arrow_en = osdctrl[6];
    wire text_en  = osdctrl[5];

    wire cross_on   = osdctrl[0] || cal_mode;
    wire ray_on     = osdctrl[1] || cal_mode;
    wire ybot_on    = osdctrl[2] || cal_mode;
    wire ytop_on    = osdctrl[3] || cal_mode;
    wire cross_blink= cal_mode ? ((obj==2'd0)?cal_blink:1'b1) : 1'b1;
    wire ray_blink  = cal_mode ? ((obj==2'd2)?cal_blink:1'b1) : 1'b1;
    wire ybot_blink = cal_mode ? ((obj==2'd1)?cal_blink:1'b1) : 1'b1;

    wire cross_hit = ((y1>=vp_y-1)&&(y1<=vp_y+1)&&(x1>=vp_x-40)&&(x1<=vp_x+40)) ||
                     ((x1>=vp_x-1)&&(x1<=vp_x+1)&&(y1>=vp_y-40)&&(y1<=vp_y+40));
    wire ybot_hit  = (y1==y_bot) || (y1==(y_bot+1));
    wire ytop_hit  = (y1==y_top);

    wire signed [13:0] ray_l = $signed({2'b0,vp_x}) - $signed({2'b0,off16});
    wire signed [13:0] ray_r = $signed({2'b0,vp_x}) + $signed({2'b0,off16});
    wire ray_range = (y1>=vp_y) && (y1<=y_bot);
    wire ray_hit   = ray_range &&
                     (($signed({2'b0,x1})-ray_l)<=1) && ((ray_l-$signed({2'b0,x1}))<=1);
    wire ray_hit2  = ray_range &&
                     (($signed({2'b0,x1})-ray_r)<=1) && ((ray_r-$signed({2'b0,x1}))<=1);

    // box loop (combinational from x1,y1; registered into stage 2)
    integer    bj;
    reg [11:0] bx0,by0,bx1,by1;
    reg [3:0]  bc;
    reg        bhit_c;
    reg [3:0]  bcol_c;
    reg [7:0]  cr, cg, cb;

    function [7:0] colr; input [3:0] c;
        begin
            case (c)
                4'd1: colr=8'd255;
                4'd2: colr=8'd0;
                4'd3: colr=8'd255;
                4'd4: colr=8'd0;
                4'd5: colr=8'd0;
                4'd6: colr=8'd255;
                4'd7: colr=8'd255;
                default: colr=8'd0;
            endcase
        end
    endfunction
    function [7:0] colg; input [3:0] c;
        begin
            case (c)
                4'd1: colg=8'd0;
                4'd2: colg=8'd220;
                4'd3: colg=8'd220;
                4'd4: colg=8'd128;
                4'd5: colg=8'd255;
                4'd6: colg=8'd0;
                4'd7: colg=8'd255;
                default: colg=8'd0;
            endcase
        end
    endfunction
    function [7:0] colb; input [3:0] c;
        begin
            case (c)
                4'd1: colb=8'd0;
                4'd2: colb=8'd0;
                4'd3: colb=8'd0;
                4'd4: colb=8'd255;
                4'd5: colb=8'd255;
                4'd6: colb=8'd255;
                4'd7: colb=8'd255;
                default: colb=8'd0;
            endcase
        end
    endfunction

    always @(*)
    begin
        bhit_c = 1'b0; bcol_c = 4'd0;
        if (box_en) begin
            for (bj=0; bj<16; bj=bj+1) begin
                bx0 = box[52*bj +: 12];
                by0 = box[52*bj+12 +: 12];
                bx1 = box[52*bj+24 +: 12];
                by1 = box[52*bj+36 +: 12];
                bc  = box[52*bj+48 +: 4];
                if ((bc!=4'd0) && (x1>=bx0) && (x1<=bx1) && (y1>=by0) && (y1<=by1) &&
                    (((x1-bx0)<12'd2) || ((bx1-x1)<12'd2) ||
                     ((y1-by0)<12'd2) || ((by1-y1)<12'd2))) begin
                    bhit_c = 1'b1; bcol_c = bc;
                end
            end
        end
    end

    //------------------------------------------------------------------
    // stage 2 : register the layer decisions
    //------------------------------------------------------------------
    reg [11:0] x2, y2;
    reg [7:0]  r2, g2, b2;
    reg        de2, hs2, vs2;
    reg        alarm2, bhit2, ytop2, ybot2, ray2, cross2;
    reg [3:0]  bcol2;
    reg        arr2, abit2, text2, fbit2;
    reg [1:0]  astat2;
    reg        lane_l_hit2, lane_l_solid2;
    reg        lane_r_hit2, lane_r_solid2;

    always @(posedge pix_clk or negedge rst_n)
    begin
        if (!rst_n) begin
            x2<=0; y2<=0; r2<=0; g2<=0; b2<=0; de2<=0; hs2<=0; vs2<=0;
            alarm2<=0; bhit2<=0; bcol2<=0; ytop2<=0; ybot2<=0; ray2<=0; cross2<=0;
            arr2<=0; abit2<=0; astat2<=0; text2<=0; fbit2<=0;
            lane_l_hit2<=0; lane_l_solid2<=0; lane_r_hit2<=0; lane_r_solid2<=0;
        end
        else begin
            x2<=x1; y2<=y1; r2<=r1; g2<=g1; b2<=b1;
            de2<=de1; hs2<=hs1; vs2<=vs1;
            alarm2 <= alarm_draw;
            bhit2  <= bhit_c;       bcol2 <= bcol_c;
            ytop2  <= ytop_on && ytop_hit;
            ybot2  <= ybot_on && ybot_blink && ybot_hit;
            ray2   <= ray_on && ray_blink && (ray_hit || ray_hit2);
            cross2 <= cross_on && cross_blink && cross_hit;
            arr2   <= arr1 && arrow_en;   abit2 <= abit;   astat2 <= astat1;
            text2  <= tcell1 && text_en;  fbit2 <= fbit;
            lane_l_hit2   <= l_line_hit;
            lane_l_solid2 <= ll_solid_r;
            lane_r_hit2   <= r_line_hit;
            lane_r_solid2 <= lr_solid_r;
        end
    end

    //------------------------------------------------------------------
    // stage 3 : layer selection
    //------------------------------------------------------------------
    always @(*)
    begin
        cr = r2; cg = g2; cb = b2;
        if (de2 && osd_en) begin
            // 20261028 lane lines (solid yellow: 255,220,0; dashed green: 0,220,0)
            if (lane_l_hit2) begin
                cr = lane_l_solid2 ? 8'd255 : 8'd0;
                cg = 8'd220;
                cb = 8'd0;
            end
            if (lane_r_hit2) begin
                cr = lane_r_solid2 ? 8'd255 : 8'd0;
                cg = 8'd220;
                cb = 8'd0;
            end
            if (alarm2) begin cr=8'd255; cg=8'd0; cb=8'd0; end

            if (bhit2)  begin cr=colr(bcol2); cg=colg(bcol2); cb=colb(bcol2); end
            if (ytop2)  begin cr=8'd128; cg=8'd128; cb=8'd128; end
            if (ybot2)  begin cr=8'd255; cg=8'd220; cb=8'd0; end
            if (ray2)   begin cr=8'd0; cg=8'd255; cb=8'd0; end
            if (cross2) begin cr=8'd255; cg=8'd0; cb=8'd0; end
            if (arr2 && (astat2!=2'd0)) begin
                if (abit2) case (astat2)
                    2'd1: begin cr=8'd96;  cg=8'd96;  cb=8'd96;  end
                    2'd2: begin cr=8'd0;   cg=8'd220; cb=8'd0;   end
                    2'd3: begin cr=8'd230; cg=8'd0;   cb=8'd0;   end
                    default: ;
                endcase
                else begin cr=r2>>1; cg=g2>>1; cb=b2>>1; end
            end
            if (text2) begin
                if (fbit2) begin cr=8'd255; cg=8'd255; cb=8'd255; end
                else       begin cr=r2>>1; cg=g2>>1; cb=b2>>1; end
            end
        end
    end

    always @(posedge pix_clk or negedge rst_n)
    begin
        if (!rst_n) begin
            r_out<=0; g_out<=0; b_out<=0; de_out<=0; hs_out<=0; vs_out<=0;
        end
        else begin
            r_out<=cr; g_out<=cg; b_out<=cb;
            de_out<=de2; hs_out<=hs2; vs_out<=vs2;
        end
    end

endmodule
