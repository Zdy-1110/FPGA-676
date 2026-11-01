`timescale 1ns/1ps
////////////////////////////////////////////////////////////////////////////////
// rt_night.v
// FPGA Adaptive Night Enhancement Module (cam18)
// Components:
//   1. rt_night_gamma: 1-cycle pipeline Gamma=0.5 LUT processing
//   2. rt_night: Brightness accumulation, pipelined mean divider,
//                AUTO hysteresis FSM (8 frames <48 enter, 8 frames >64 exit),
//                and slot0 stream processing.
////////////////////////////////////////////////////////////////////////////////

module rt_night_gamma (
    input  wire        clk          ,   // pix_clk (148.5 MHz)
    input  wire        rst_n        ,
    input  wire        night_active ,
    input  wire        de_in        ,
    input  wire        hs_in        ,
    input  wire        vs_in        ,
    input  wire [7:0]  r_in         ,
    input  wire [7:0]  g_in         ,
    input  wire [7:0]  b_in         ,
    output reg         de_out       ,
    output reg         hs_out       ,
    output reg         vs_out       ,
    output reg  [7:0]  r_out        ,
    output reg  [7:0]  g_out        ,
    output reg  [7:0]  b_out
);

`include "gamma_lut.vh"

    wire [7:0] r_lut = gamma_lut(r_in);
    wire [7:0] g_lut = gamma_lut(g_in);
    wire [7:0] b_lut = gamma_lut(b_in);

    wire [7:0] r_sel = night_active ? r_lut : r_in;
    wire [7:0] g_sel = night_active ? g_lut : g_in;
    wire [7:0] b_sel = night_active ? b_lut : b_in;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_out <= 1'b0;
            hs_out <= 1'b0;
            vs_out <= 1'b0;
            r_out  <= 8'd0;
            g_out  <= 8'd0;
            b_out  <= 8'd0;
        end else begin
            de_out <= de_in;
            hs_out <= hs_in;
            vs_out <= vs_in;
            r_out  <= r_sel;
            g_out  <= g_sel;
            b_out  <= b_sel;
        end
    end

endmodule

////////////////////////////////////////////////////////////////////////////////
// rt_night: Controller and slot0 processing
//   Derivation of Reciprocal Constant for Slot0 (960 x 540 active pixels):
//     N = 960 * 540 = 518,400 pixels.
//     Each pixel Y in [0, 255]. Maximum accumulation acc_y_max = 518,400 * 255 = 132,192,000 (< 2^27).
//     We want to compute: mean = round(acc_y / N).
//     Using fixed-point representation with SHIFT_N = 32:
//       K = round(2^SHIFT_N / N) = round(4294967296 / 518400) = 8285.
//       Approximation formula: mean_approx = (acc_y * 8285 + (1 << 31)) >> 32.
//     Error analysis:
//       K * N = 8285 * 518400 = 4,294,944,000.
//       Difference with 2^32: 4,294,944,000 - 4,294,967,296 = -23,296.
//       Relative error: -23,296 / 2^32 = -5.42e-6.
//       Maximum error in mean over all acc_y in [0, 132,192,000]:
//         max |round(acc_y / 518400) - ((acc_y * 8285 + 2^31) >> 32)| <= 1 LSB.
//       Thus the error is guaranteed <= 1 LSB.
////////////////////////////////////////////////////////////////////////////////
module rt_night #(
    parameter PIXELS_PER_FRAME = 960 * 540,
    parameter MULT_K           = 8285,
    parameter SHIFT_N          = 32,
    parameter PRE_SHIFT        = 0     // acc pre-shift to narrow the multiply (top: 11, SHIFT_N 21; err ~0.004 LSB)
)(
    input  wire        clk          ,   // pix_clk (148.5 MHz)
    input  wire        rst_n        ,

    // mode from 0x800[11:10]: 00=AUTO, 01=FORCE_ON, 10/11=FORCE_OFF
    input  wire [1:0]  mode         ,
    input  wire        stat_valid   ,   // slot0 video active (pix_clk); 0 = do not run AUTO statistics

    // stream in (raw slot0)
    input  wire        de_in        ,
    input  wire        hs_in        ,
    input  wire        vs_in        ,
    input  wire [7:0]  r_in         ,
    input  wire [7:0]  g_in         ,
    input  wire [7:0]  b_in         ,

    // stream out (delayed 1 cycle, gamma enhanced if night_active)
    output wire        de_out       ,
    output wire        hs_out       ,
    output wire        vs_out       ,
    output wire [7:0]  r_out        ,
    output wire [7:0]  g_out        ,
    output wire [7:0]  b_out        ,

    // status outputs
    output reg  [7:0]  mean         ,
    output reg         night_active ,
    output reg         auto_state
);

    // 2-stage synchronizer for mode
    reg [1:0] mode_s1, mode_s2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mode_s1 <= 2'b00;
            mode_s2 <= 2'b00;
        end else begin
            mode_s1 <= mode;
            mode_s2 <= mode_s1;
        end
    end

    // Vsync edge detection
    reg vs_d1, vs_d2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs_d1 <= 1'b0;
            vs_d2 <= 1'b0;
        end else begin
            vs_d1 <= vs_in;
            vs_d2 <= vs_d1;
        end
    end
    wire vs_rise = vs_d1 & ~vs_d2;

    // Pixel brightness Y = (R + 2*G + B) / 4
    wire [9:0] y_sum = {2'b00, r_in} + {1'b0, g_in, 1'b0} + {2'b00, b_in};
    wire [7:0] y_pix = y_sum[9:2];

    // Brightness accumulator
    reg [31:0] acc_y;
    reg [31:0] acc_snap;
    reg [2:0]  calc_step;
    reg [51:0] mult_p;
    reg [7:0]  calc_mean_val;
    reg [3:0]  hyst_cnt;
    reg        next_auto;
    reg        valid_snap;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_y         <= 32'd0;
            acc_snap      <= 32'd0;
            calc_step     <= 3'd0;
            mult_p        <= 52'd0;
            calc_mean_val <= 8'd0;
            mean          <= 8'd0;
            auto_state    <= 1'b0;
            hyst_cnt      <= 4'd0;
            night_active  <= 1'b0;
            valid_snap    <= 1'b0;
        end else begin
            if (vs_rise) begin
                acc_snap  <= acc_y;
                valid_snap <= stat_valid;
                acc_y     <= de_in ? {24'd0, y_pix} : 32'd0;
                calc_step <= 3'd1;
            end else begin
                if (de_in)
                    acc_y <= acc_y + y_pix;

                case (calc_step)
                    3'd1: begin
                        // Stage 1: Multiply accumulation with reciprocal constant
                        mult_p    <= (acc_snap >> PRE_SHIFT) * MULT_K;
                        calc_step <= 3'd2;
                    end
                    3'd2: begin
                        // Stage 2: Round and shift right to get 8-bit mean
                        if (SHIFT_N > 0) begin
                            mult_p    <= (mult_p + (52'd1 << (SHIFT_N - 1))) >> SHIFT_N;
                        end
                        calc_step <= 3'd3;
                    end
                    3'd3: begin
                        // Stage 3: Saturate and register mean
                        if (mult_p > 52'd255)
                            calc_mean_val <= 8'd255;
                        else
                            calc_mean_val <= mult_p[7:0];
                        calc_step <= 3'd4;
                    end
                    3'd4: begin
                        // Stage 4: Update mean, evaluate AUTO FSM and latch night_active
                        mean <= calc_mean_val;

                        // AUTO hysteresis state machine
                        if (!auto_state) begin
                            // In DAY mode: require 8 consecutive frames with mean < 48 to enter NIGHT
                            if (calc_mean_val < 8'd48) begin
                                if (hyst_cnt == 4'd7) begin
                                    auto_state <= 1'b1;
                                    hyst_cnt   <= 4'd0;
                                    next_auto   = 1'b1;
                                end else begin
                                    hyst_cnt   <= hyst_cnt + 1'b1;
                                    next_auto   = 1'b0;
                                end
                            end else begin
                                hyst_cnt  <= 4'd0;
                                next_auto  = 1'b0;
                            end
                        end else begin
                            // In NIGHT mode: require 8 consecutive frames with mean > 64 to exit NIGHT
                            if (calc_mean_val > 8'd64) begin
                                if (hyst_cnt == 4'd7) begin
                                    auto_state <= 1'b0;
                                    hyst_cnt   <= 4'd0;
                                    next_auto   = 1'b0;
                                end else begin
                                    hyst_cnt   <= hyst_cnt + 1'b1;
                                    next_auto   = 1'b1;
                                end
                            end else begin
                                hyst_cnt  <= 4'd0;
                                next_auto  = 1'b1;
                            end
                        end

                        // 20261101: slot0 not showing video (legacy mode / disabled) -> hold AUTO in day state
                        if (!valid_snap) begin
                            auto_state <= 1'b0;
                            hyst_cnt   <= 4'd0;
                            next_auto   = 1'b0;
                        end

                        // night_active only updates on vsync boundary
                        if (mode_s2 == 2'b01)
                            night_active <= 1'b1;
                        else if (mode_s2[1])
                            night_active <= 1'b0;
                        else
                            night_active <= next_auto;

                        calc_step <= 3'd0;
                    end
                    default: ;
                endcase
            end
        end
    end

    // Point (a) gamma instance for slot0 stream
    rt_night_gamma u_gamma (
        .clk          (clk         ),
        .rst_n        (rst_n       ),
        .night_active (night_active),
        .de_in        (de_in       ),
        .hs_in        (hs_in       ),
        .vs_in        (vs_in       ),
        .r_in         (r_in        ),
        .g_in         (g_in        ),
        .b_in         (b_in        ),
        .de_out       (de_out      ),
        .hs_out       (hs_out      ),
        .vs_out       (vs_out      ),
        .r_out        (r_out       ),
        .g_out        (g_out       ),
        .b_out        (b_out       )
    );

endmodule
