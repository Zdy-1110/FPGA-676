`timescale 1ns/1ps
//////////////////////////////////////////////////////////////////////////////
// rt_osd_ctl.v  (20261018 osd1)
// Pixel-domain OSD configuration / drive-state controller.
//   - latches the OSD register snapshot from rt_ext_regs (pclk toggle handshake)
//   - consumes key events (free domain toggle handshake)
//   - keeps lane / moving / request / disp_mode / src_sel drive state
//   - calibration mode (obj VP / YBOT / GUIDE editing + save handshake)
//   - computes the effective overlay geometry and the 64-char status row
//////////////////////////////////////////////////////////////////////////////
module rt_osd_ctl #(
    parameter integer MS_DIV = 148500      // pix_clk cycles per 1 ms (sim: reduce)
)(
    input               pix_clk       ,
    input               rst_n         ,

    // register snapshot from rt_ext_regs (pclk domain), toggle handshake
    input               osd_cfg_tgl   ,
    input      [1065:0] osd_cfg       ,

    // key events from rt_keys (free domain), toggle handshake
    input               evt_tgl       ,
    input      [2:0]    evt_key       ,
    input      [1:0]    evt_type      ,
    input      [5:0]    evt_step      ,

    // drive state back to rt_ext_regs (pclk domain)
    output reg          drv_tgl       ,
    output reg  [9:0]   drv_bus       ,

    // calibration save back to rt_ext_regs (pclk domain)
    output reg          cal_tgl       ,
    output reg  [59:0]  cal_bus       ,   // {vp_x,vp_y,y_top,y_bot,g}

    // control to rt_keys / pause
    output wire         repeat_en     ,
    output wire         pause_req     ,

    // overlay inputs for rt_osd
    input               vs            ,   // frame sync (for blanking latch)
    output reg          cal_mode      ,
    output reg  [1:0]   obj           ,
    output reg  [11:0]  eff_vp_x      ,
    output reg  [11:0]  eff_vp_y      ,
    output reg  [11:0]  eff_y_top     ,
    output reg  [11:0]  eff_y_bot     ,
    output reg  [11:0]  eff_g         ,
    output reg  [511:0] status_line   ,   // 64 chars, byte c at [8c+7:8c]
    output reg          cal_blink     ,   // 1 Hz object blink (1 = visible)
    output wire [31:0]  dec_out       ,
    output wire [31:0]  osdctrl_out   ,
    output wire [831:0] box_out
);

    localparam [1:0] T_REP=2'd0, T_SHORT=2'd1, T_LONG=2'd2, T_HOLD3=2'd3;
    localparam integer CAL_TIMEOUT_MS = 30000;
    localparam integer REQ_HOLD_MS    = 2000;

    //------------------------------------------------------------------
    // 1 ms tick (pixel domain)
    //------------------------------------------------------------------
    reg [23:0] mscnt;
    wire       ms_tick = (mscnt == (MS_DIV-1));
    always @(posedge pix_clk or negedge rst_n)
        if (!rst_n)                  mscnt <= 24'd0;
        else if (ms_tick)            mscnt <= 24'd0;
        else                         mscnt <= mscnt + 1'b1;

    //------------------------------------------------------------------
    // config snapshot latch (toggle + 4 cycles)
    //------------------------------------------------------------------
    reg cfg_s1, cfg_s2, cfg_s2d;
    always @(posedge pix_clk or negedge rst_n)
        if (!rst_n) begin cfg_s1<=0; cfg_s2<=0; cfg_s2d<=0; end
        else        begin cfg_s1<=osd_cfg_tgl; cfg_s2<=cfg_s1; cfg_s2d<=cfg_s2; end
    wire cfg_edge = cfg_s2 ^ cfg_s2d;

    reg [2:0] cfg_wait; reg cfg_latch;
    always @(posedge pix_clk or negedge rst_n)
        if (!rst_n) begin cfg_wait<=0; cfg_latch<=0; end
        else begin
            if (cfg_edge) begin cfg_wait<=3'd4; cfg_latch<=1'b1; end
            else if (cfg_wait!=0) begin cfg_wait<=cfg_wait-1'b1; cfg_latch<=1'b0; end
            else cfg_latch<=1'b0;
        end

    reg [31:0] dec_r, osdctrl_r;
    reg [31:0] cal_vp_r, cal_band_r, cal_g_r, auto_vp_r, auto_band_r;
    reg        cal_valid_r;
    reg [831:0] box_r;
    integer    bi;

    always @(posedge pix_clk or negedge rst_n)
    begin
        if (!rst_n) begin
            dec_r<=0; osdctrl_r<=0;
            cal_vp_r<=0; cal_band_r<=0; cal_g_r<=0;
            auto_vp_r<=0; auto_band_r<=0; cal_valid_r<=0; box_r<=0;
        end
        else if (cfg_latch) begin
            dec_r      <= osd_cfg[31:0];
            osdctrl_r  <= osd_cfg[63:32];
            cal_vp_r   <= osd_cfg[95:64];
            cal_band_r <= osd_cfg[127:96];
            cal_g_r    <= osd_cfg[159:128];
            auto_vp_r  <= osd_cfg[191:160];
            auto_band_r<= osd_cfg[223:192];
            cal_valid_r<= osd_cfg[224];
            box_r      <= osd_cfg[1065:234];
        end
    end

    assign dec_out     = dec_r;
    assign osdctrl_out = osdctrl_r;
    assign box_out     = box_r;

    //------------------------------------------------------------------
    // key event cross-domain
    //------------------------------------------------------------------
    reg et1, et2, et2d;
    always @(posedge pix_clk or negedge rst_n)
        if (!rst_n) begin et1<=0; et2<=0; et2d<=0; end
        else        begin et1<=evt_tgl; et2<=et1; et2d<=et2; end
    wire et_edge = et2 ^ et2d;

    reg [2:0] ek; reg [1:0] ety; reg [5:0] est; reg evt_hit;
    always @(posedge pix_clk or negedge rst_n)
        if (!rst_n) begin ek<=0; ety<=0; est<=0; evt_hit<=0; end
        else begin
            evt_hit <= et_edge;
            if (et_edge) begin ek<=evt_key; ety<=evt_type; est<=evt_step; end
        end

    //------------------------------------------------------------------
    // drive state
    //------------------------------------------------------------------
    reg [1:0] lane;
    reg       moving, left_req, right_req, disp_mode, src_sel;

    // work values
    reg [11:0] w_vpx, w_vpy, w_ybot, w_g;

    // timers
    reg [15:0] reqL, reqR;
    reg [15:0] to_ms;

    // effective selectors
    wire [11:0] sel_vpx = cal_mode ? w_vpx :
                          cal_valid_r ? cal_vp_r[11:0] :
                          (auto_vp_r==0) ? 12'd960 : auto_vp_r[11:0];
    wire [11:0] sel_vpy = cal_mode ? w_vpy :
                          cal_valid_r ? cal_vp_r[27:16] :
                          (auto_vp_r==0) ? 12'd600 : auto_vp_r[27:16];
    wire [11:0] sel_ybot= cal_mode ? w_ybot :
                          cal_valid_r ? cal_band_r[27:16] :
                          (auto_vp_r==0) ? 12'd1000 : auto_band_r[27:16];
    wire [11:0] sel_g   = cal_mode ? w_g :
                          cal_valid_r ? cal_g_r[11:0] : 12'd576;

    // registered selectors : break the y_top multiply / status decode path
    reg [11:0] sel_vpx_r, sel_vpy_r, sel_ybot_r, sel_g_r;
    always @(posedge pix_clk or negedge rst_n)
        if (!rst_n) begin
            sel_vpx_r<=12'd960; sel_vpy_r<=12'd600;
            sel_ybot_r<=12'd1000; sel_g_r<=12'd576;
        end
        else begin
            sel_vpx_r<=sel_vpx; sel_vpy_r<=sel_vpy;
            sel_ybot_r<=sel_ybot; sel_g_r<=sel_g;
        end

    function [11:0] ytop_of;
        input [11:0] vy, vb;
        reg   [17:0] d;
        begin
            d = (vb > vy) ? (vb - vy) : 18'd0;
            d = (d * 77) >> 8;
            if (d < 54) d = 54;
            ytop_of = vy + d[11:0];
        end
    endfunction

    //------------------------------------------------------------------
    // clamps for the working values
    //------------------------------------------------------------------
    function [11:0] clampv; input [12:0] v; input [11:0] lo, hi;
        begin clampv = ((v < lo) ? lo : ((v > hi) ? hi : v[11:0])); end   // 20261018 review: v[12] = underflow (was clamped to hi)
    endfunction

    //------------------------------------------------------------------
    // main state update
    //------------------------------------------------------------------
    reg [12:0] inc, dec;
    integer    ci;
    always @(posedge pix_clk or negedge rst_n)
    begin
        if (!rst_n) begin
            lane<=2'd1; moving<=0; left_req<=0; right_req<=0;
            disp_mode<=0; src_sel<=0;
            cal_mode<=0; obj<=2'd0;
            w_vpx<=12'd960; w_vpy<=12'd600; w_ybot<=12'd1000; w_g<=12'd576;
            reqL<=0; reqR<=0; to_ms<=0;
            cal_tgl<=0; cal_bus<=0;
        end
        else begin
            // 2 s request timers
            if (ms_tick) begin
                if (left_req) begin
                    if (reqL<=1) begin left_req<=1'b0; reqL<=0; end
                    else reqL<=reqL-1'b1;
                end
                if (right_req) begin
                    if (reqR<=1) begin right_req<=1'b0; reqR<=0; end
                    else reqR<=reqR-1'b1;
                end
                // calibration idle timeout
                if (cal_mode) begin
                    if (to_ms >= (CAL_TIMEOUT_MS-1)) begin cal_mode<=1'b0; to_ms<=0; end
                    else to_ms <= to_ms + 1'b1;
                end
            end

            if (evt_hit) begin
                to_ms <= 0;
                if (!cal_mode) begin
                    case (ety)
                        T_SHORT: case (ek)
                            3'd0: lane <= (lane==2'd2) ? 2'd0 : lane + 1'b1;
                            3'd1: moving <= ~moving;
                            3'd2: begin left_req<=1'b1;  reqL<=REQ_HOLD_MS; end
                            3'd3: begin right_req<=1'b1; reqR<=REQ_HOLD_MS; end
                            3'd4: disp_mode <= ~disp_mode;
                            default: ;
                        endcase
                        T_LONG:  if (ek==3'd4) src_sel <= ~src_sel;
                        T_HOLD3: if (ek==3'd4) begin
                                     cal_mode <= 1'b1;
                                     obj      <= 2'd0;
                                     w_vpx<=sel_vpx; w_vpy<=sel_vpy;
                                     w_ybot<=sel_ybot; w_g<=sel_g;
                                     to_ms<=0;
                                 end
                        default: ;
                    endcase
                end
                else begin
                    case (ety)
                        T_SHORT: if (ek==3'd4) obj <= (obj==2'd2) ? 2'd0 : obj + 1'b1;
                        T_REP: case (ek)
                            3'd0: begin // up : vp_y-- / y_bot--
                                if (obj==2'd0) begin
                                    inc = {1'b0,w_vpy} - {1'b0,est};
                                    w_vpy <= clampv(inc, 12'd0, (w_ybot>12'd60)?(w_ybot-12'd60):12'd0);
                                end else if (obj==2'd1) begin
                                    dec = {1'b0,w_ybot} - {1'b0,est};
                                    w_ybot <= clampv(dec, w_vpy+12'd60, 12'd1079);
                                end
                            end
                            3'd1: begin // down : vp_y++ / y_bot++
                                if (obj==2'd0) begin
                                    inc = {1'b0,w_vpy} + {1'b0,est};
                                    w_vpy <= clampv(inc, 12'd0, (w_ybot>12'd60)?(w_ybot-12'd60):12'd0);
                                end else if (obj==2'd1) begin
                                    dec = {1'b0,w_ybot} + {1'b0,est};
                                    w_ybot <= clampv(dec, w_vpy+12'd60, 12'd1079);
                                end
                            end
                            3'd2: begin // left : vp_x-- / g--
                                if (obj==2'd0) begin
                                    dec = {1'b0,w_vpx} - {1'b0,est};
                                    w_vpx <= clampv(dec, 12'd0, 12'd1919);
                                end else if (obj==2'd2) begin
                                    dec = {1'b0,w_g} - {1'b0,est};
                                    w_g <= clampv(dec, 12'd32, 12'd1919);
                                end
                            end
                            3'd3: begin // right : vp_x++ / g++
                                if (obj==2'd0) begin
                                    inc = {1'b0,w_vpx} + {1'b0,est};
                                    w_vpx <= clampv(inc, 12'd0, 12'd1919);
                                end else if (obj==2'd2) begin
                                    inc = {1'b0,w_g} + {1'b0,est};
                                    w_g <= clampv(inc, 12'd32, 12'd1919);
                                end
                            end
                            default: ;
                        endcase
                        T_HOLD3: if (ek==3'd4) begin
                                     cal_bus <= {w_vpx, w_vpy, ytop_of(w_vpy,w_ybot), w_ybot, w_g};
                                     cal_tgl <= ~cal_tgl;
                                     cal_mode<=1'b0;
                                     to_ms<=0;
                                 end
                        default: ;
                    endcase
                end
            end
        end
    end

    assign repeat_en = cal_mode;
    assign pause_req = cal_mode;

    //------------------------------------------------------------------
    // DRV_STATE handshake to pclk domain
    //------------------------------------------------------------------
    wire [9:0] drv_now = {obj, cal_mode, src_sel, disp_mode,
                          right_req, left_req, moving, lane};
    // 20261018 review: re-send once per frame (vs rising edge). The old send-on-change lost the
    // reset-time state because the pclk side leaves reset later; per-frame toggles also keep
    // drv_bus stable for 16 ms around every edge.
    reg        drv_vs_d;
    always @(posedge pix_clk or negedge rst_n)
    begin
        if (!rst_n) begin drv_vs_d<=1'b0; drv_tgl<=1'b0; drv_bus<=10'd0; end
        else begin
            drv_vs_d <= vs;
            if (vs & ~drv_vs_d) begin
                drv_bus <= drv_now;
                drv_tgl <= ~drv_tgl;
            end
        end
    end

    //------------------------------------------------------------------
    // 1 Hz object blink (0.5 s on / 0.5 s off)
    //------------------------------------------------------------------
    reg [9:0] blink_ms;
    always @(posedge pix_clk or negedge rst_n)
        if (!rst_n) begin blink_ms<=10'd0; cal_blink<=1'b0; end
        else if (ms_tick) begin
            if (blink_ms >= 10'd499) begin blink_ms<=10'd0; cal_blink<=~cal_blink; end
            else blink_ms <= blink_ms + 1'b1;
        end

    //------------------------------------------------------------------
    // decimal helpers + 64-char status row
    //------------------------------------------------------------------
    function [7:0] dcd;
        input [11:0] v; input integer p;
        reg [11:0] t;
        begin
            case (p)
                0: t = v % 10;
                1: t = (v/10) % 10;
                2: t = (v/100) % 10;
                default: t = (v/1000) % 10;
            endcase
            dcd = 8'h30 + t[7:0];
        end
    endfunction

    reg [7:0] sl [0:63];
    always @(*) begin
        for (ci=0; ci<64; ci=ci+1) sl[ci] = 8'h20;
        if (cal_mode) begin
            sl[0]=8'h43; sl[1]=8'h41; sl[2]=8'h4C; sl[3]=8'h20;
            sl[4]=8'h56; sl[5]=8'h50; sl[6]=8'h28;
            sl[7]=dcd(sel_vpx_r,3); sl[8]=dcd(sel_vpx_r,2); sl[9]=dcd(sel_vpx_r,1); sl[10]=dcd(sel_vpx_r,0);
            sl[11]=8'h2C;
            sl[12]=dcd(sel_vpy_r,3); sl[13]=dcd(sel_vpy_r,2); sl[14]=dcd(sel_vpy_r,1); sl[15]=dcd(sel_vpy_r,0);
            sl[16]=8'h29; sl[17]=8'h20; sl[18]=8'h59; sl[19]=8'h42; sl[20]=8'h3D;
            sl[21]=dcd(sel_ybot_r,3); sl[22]=dcd(sel_ybot_r,2); sl[23]=dcd(sel_ybot_r,1); sl[24]=dcd(sel_ybot_r,0);
            sl[25]=8'h20; sl[26]=8'h47; sl[27]=8'h3D;
            sl[28]=dcd(sel_g_r,3); sl[29]=dcd(sel_g_r,2); sl[30]=dcd(sel_g_r,1); sl[31]=dcd(sel_g_r,0);
            sl[32]=8'h20; sl[33]=8'h4F; sl[34]=8'h42; sl[35]=8'h4A; sl[36]=8'h3D;
            sl[37]= (obj==2'd0)?8'h56 : (obj==2'd1)?8'h59 : 8'h47;
            sl[38]= (obj==2'd0)?8'h50 : (obj==2'd1)?8'h42 : 8'h20;
        end
    end

    // latch effective geometry + status row during vertical blanking
    reg vs_d;
    reg [11:0] cy_vpy, cy_ybot, cy_stored, cy_d, cy_p;
    reg        cy_stored_sel;
    reg [1:0]  cy_state;
    always @(posedge pix_clk or negedge rst_n)
    begin
        if (!rst_n) begin
            vs_d<=1'b0; cy_state<=2'd0;
            cy_vpy<=12'd600; cy_ybot<=12'd1000; cy_stored<=12'd720; cy_stored_sel<=1'b0;
            cy_d<=12'd0; cy_p<=12'd0;
            eff_vp_x<=12'd960; eff_vp_y<=12'd600; eff_y_top<=12'd720;
            eff_y_bot<=12'd1000; eff_g<=12'd576; status_line<=0;
        end
        else begin
            vs_d <= vs;
            if (vs & ~vs_d) begin
                eff_vp_x <= sel_vpx_r;
                eff_vp_y <= sel_vpy_r;
                eff_y_bot<= sel_ybot_r;
                eff_g    <= sel_g_r;
                cy_vpy   <= sel_vpy_r;
                cy_ybot  <= sel_ybot_r;
                cy_stored<= cal_band_r[11:0];
                cy_stored_sel <= (cal_valid_r && !cal_mode);
                cy_state <= 2'd1;
                for (ci=0; ci<64; ci=ci+1)
                    status_line[8*ci +: 8] <= sl[ci];
            end
            else case (cy_state)
                2'd1: begin cy_d <= (cy_ybot > cy_vpy) ? (cy_ybot - cy_vpy) : 12'd0; cy_state<=2'd2; end
                2'd2: begin cy_p <= (cy_d * 77) >> 8; cy_state<=2'd3; end
                2'd3: begin
                          eff_y_top <= cy_stored_sel ? cy_stored :
                                       (cy_vpy + ((cy_p < 12'd54) ? 12'd54 : cy_p));
                          cy_state<=2'd0;
                      end
                default: ;
            endcase
        end
    end

endmodule
