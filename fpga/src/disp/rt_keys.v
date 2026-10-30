`timescale 1ns/1ps
//////////////////////////////////////////////////////////////////////////////
// rt_keys.v  (20261018 osd1)
// Free-running key scanner in the 27 MHz free_clk domain.
//   - 20 ms debounce per key (KEY_STAT behaviour preserved)
//   - press-time events : SHORT (<1000ms) / LONG (1000..2999ms) / HOLD3 (3000ms)
//   - repeat mode (repeat_en=1, synced from the pixel domain):
//       KEY0..KEY3 emit REP immediately then at 300ms and every 66ms,
//       step = 2 (<500ms) / 8 (500..1499ms) / 32 (>=1500ms).
//   - events are shipped to the pixel / pclk domains through a toggle handshake
//     (event spacing is >= 66 ms so a level toggle is sufficient).
//////////////////////////////////////////////////////////////////////////////
module rt_keys #(
    parameter integer TICK_DIV = 27000      // free_clk cycles per 1 ms
)(
    input               clk         ,       // free_clk 27 MHz
    input               rst_n       ,
    input       [4:0]   key_raw     ,       // active low
    input               repeat_en   ,       // from pixel domain, synced here

    output reg  [4:0]   key_stat    ,       // debounced, pressed = 1

    output reg          evt_tgl     ,
    output reg  [2:0]   evt_key     ,
    output reg  [1:0]   evt_type    ,       // 0 REP, 1 SHORT, 2 LONG, 3 HOLD3
    output reg  [5:0]   evt_step
);

    localparam integer DEB_MS = 20;         // debounce
    localparam integer H3_MS  = 10000;   // 20261030: 10 s hold enters cal/debug; 1-10 s is LONG(return)
    localparam integer S_MS   = 1000;
    localparam integer L_MS   = 3000;
    localparam integer REP0   = 300;
    localparam integer REPI   = 66;

    //------------------------------------------------------------------
    // 1 ms tick
    //------------------------------------------------------------------
    reg [23:0] tcnt;
    wire       tick = (tcnt == (TICK_DIV-1));
    always @(posedge clk or negedge rst_n)
        if (!rst_n)                    tcnt <= 24'd0;
        else if (tcnt == (TICK_DIV-1)) tcnt <= 24'd0;
        else                           tcnt <= tcnt + 1'b1;

    //------------------------------------------------------------------
    // input synchronisers
    //------------------------------------------------------------------
    reg  [4:0] ks1, ks2;
    reg        rp1, rp2;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin ks1<=5'h1F; ks2<=5'h1F; rp1<=1'b0; rp2<=1'b0; end   // 20261018 review: released
        else        begin ks1<=key_raw; ks2<=ks1; rp1<=repeat_en; rp2<=rp1; end

    //------------------------------------------------------------------
    // debounce
    //------------------------------------------------------------------
    reg  [4:0] kdeb;
    reg  [4:0] dbc [0:4];
    integer    dk;
    always @(posedge clk or negedge rst_n)
    begin
        if (!rst_n) begin
            kdeb <= 5'h1F;   // 20261018 review: start released (was 0 -> 5 fake SHORTs 20 ms after reset)
            for (dk=0; dk<5; dk=dk+1) dbc[dk] <= 5'd0;
        end
        else if (tick) begin
            for (dk=0; dk<5; dk=dk+1) begin
                if (ks2[dk] != kdeb[dk]) begin
                    if (dbc[dk] < DEB_MS) dbc[dk] <= dbc[dk] + 1'b1;
                    else begin kdeb[dk] <= ks2[dk]; dbc[dk] <= 5'd0; end
                end
                else dbc[dk] <= 5'd0;
            end
        end
    end

    always @(*)
        key_stat = ~kdeb;                   // pressed = 1 (pin active low)

    //------------------------------------------------------------------
    // event generation
    //------------------------------------------------------------------
    function [5:0] step_of;
        input [13:0] ms;
        begin
            step_of = (ms < 13'd500) ? 6'd2 : ((ms < 13'd1500) ? 6'd8 : 6'd32);
        end
    endfunction

    reg  [13:0] t     [0:4];    // ms since press (14 bit: 10 s hold needs >8191)
    reg  [13:0] rep_at[0:4];    // next repeat deadline
    reg         pp    [0:4];    // previous pressed
    reg         h3    [0:4];    // hold3 already sent
    reg         mr    [0:4];    // mode latched at press (repeat)

    integer     ek;
    reg         p, pe, ne;

    task emit;
        input [2:0] k;
        input [1:0] ty;
        input [5:0] st;
        begin
            evt_key  <= k;
            evt_type <= ty;
            evt_step <= st;
            evt_tgl  <= ~evt_tgl;
        end
    endtask

    always @(posedge clk or negedge rst_n)
    begin
        if (!rst_n) begin
            evt_tgl  <= 1'b0;
            evt_key  <= 3'd0;
            evt_type <= 2'd0;
            evt_step <= 6'd0;
            for (ek=0; ek<5; ek=ek+1) begin
                t[ek]<=14'd0; rep_at[ek]<=14'd300; pp[ek]<=1'b0;
                h3[ek]<=1'b0; mr[ek]<=1'b0;
            end
        end
        else if (tick) begin
            for (ek=0; ek<5; ek=ek+1) begin
                p  = ~kdeb[ek];
                pe = p  & ~pp[ek];
                ne = ~p &  pp[ek];
                pp[ek] <= p;

                if (pe) begin
                    t[ek]      <= 14'd0;
                    h3[ek]     <= 1'b0;
                    rep_at[ek] <= REP0;
                    mr[ek]     <= (ek!=4) ? rp2 : 1'b0;   // KEY4 never repeats
                    if (rp2 && (ek!=4)) emit(ek[2:0], 2'd0, 6'd2);  // immediate REP
                end
                else if (p) begin
                    t[ek] <= t[ek] + 1'b1;
                    if (!mr[ek] && !h3[ek] && ((t[ek]+1'b1) >= H3_MS)) begin
                        h3[ek] <= 1'b1;
                        emit(ek[2:0], 2'd3, 6'd0);        // HOLD3
                    end
                    else if (mr[ek] && ((t[ek]+1'b1) >= rep_at[ek])) begin
                        rep_at[ek] <= rep_at[ek] + REPI;
                        emit(ek[2:0], 2'd0, step_of(t[ek]+1'b1));
                    end
                end

                if (ne && !mr[ek] && !h3[ek]) begin
                    if (t[ek] < S_MS) emit(ek[2:0], 2'd1, 6'd0);   // SHORT
                    else              emit(ek[2:0], 2'd2, 6'd0);   // LONG
                end
            end
        end
    end

endmodule
