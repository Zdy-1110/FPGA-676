`timescale 1ns/1ps
////////////////////////////////////////////////////////////////////////////////
// tb_rt_night.v
// Unit testbench for rt_night module (cam18).
// Reduced frame size: 64 x 8 = 512 active pixels per frame.
// Parameter derivation:
//   FRAME_W = 64, FRAME_H = 8 -> PIXELS_PER_FRAME = 512.
//   N = 512.
//   SHIFT_N = 32.
//   MULT_K = round(2^SHIFT_N / N) = round(4294967296 / 512) = 8388608.
//   Verification: (S * 8388608 + (1 << 31)) >> 32 == (S + 256) >> 9 == round(S / 512).
//   Maximum error relative to true mean across all S (0..130560) is exactly 0 LSB.
////////////////////////////////////////////////////////////////////////////////

module tb_rt_night;

    localparam FRAME_W          = 64;
    localparam FRAME_H          = 8;
    localparam PIXELS_PER_FRAME = FRAME_W * FRAME_H; // 512
    localparam MULT_K           = 8388608;           // round(2^32 / 512)
    localparam SHIFT_N          = 32;

    reg        clk;
    reg        rst_n;
    reg  [1:0] mode;
    reg        de_in;
    reg        hs_in;
    reg        vs_in;
    reg  [7:0] r_in, g_in, b_in;

    wire       de_out;
    wire       hs_out;
    wire       vs_out;
    wire [7:0] r_out, g_out, b_out;
    wire [7:0] mean;
    wire       night_active;
    wire       auto_state;

    // Clock generation: 148.5 MHz -> period ~6.734 ns
    initial clk = 1'b0;
    always #3.367 clk = ~clk;

    // DUT instantiation
    rt_night #(
        .PIXELS_PER_FRAME (PIXELS_PER_FRAME),
        .MULT_K           (MULT_K),
        .SHIFT_N          (SHIFT_N)
    ) u_dut (
        .clk          (clk         ),
        .rst_n        (rst_n       ),
        .mode         (mode        ),
        .stat_valid   (1'b1        ),
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
        .b_out        (b_out       ),
        .mean         (mean        ),
        .night_active (night_active),
        .auto_state   (auto_state  )
    );

    // Testbench data structures
    reg [7:0] lut_golden [0:255];
    integer   fd_lut, fd_c4_data, fd_c4_exp;
    integer   i, p, line_idx;
    integer   err_cnt = 0;
    reg [7:0] exp_mean_c4 [0:2];

    // Vsync pulse helper: pulses vsync high for 10 cycles, then low for 10 cycles
    task send_vsync;
        begin
            @(posedge clk);
            vs_in <= 1'b1;
            repeat (10) @(posedge clk);
            vs_in <= 1'b0;
            repeat (10) @(posedge clk);
        end
    endtask

    // Send constant grey frame
    task send_frame_const;
        input [7:0] val;
        integer py, px;
        begin
            for (py = 0; py < FRAME_H; py = py + 1) begin
                hs_in <= 1'b1;
                repeat (2) @(posedge clk);
                hs_in <= 1'b0;
                repeat (4) @(posedge clk);
                for (px = 0; px < FRAME_W; px = px + 1) begin
                    de_in <= 1'b1;
                    r_in  <= val;
                    g_in  <= val;
                    b_in  <= val;
                    @(posedge clk);
                end
                de_in <= 1'b0;
                r_in  <= 8'd0;
                g_in  <= 8'd0;
                b_in  <= 8'd0;
                repeat (6) @(posedge clk);
            end
            send_vsync();
        end
    endtask

    // Main Test Sequence
    integer f, val_in, d_de, d_hs, d_vs;
    integer diff_c4;
    reg [7:0] r_file, g_file, b_file;

    initial begin
        // Initialize inputs
        rst_n = 1'b0;
        mode  = 2'b00;
        de_in = 1'b0;
        hs_in = 1'b0;
        vs_in = 1'b0;
        r_in  = 8'd0;
        g_in  = 8'd0;
        b_in  = 8'd0;

        // Load gamma_lut.txt
        fd_lut = $fopen("gamma_lut.txt", "r");
        if (fd_lut == 0) fd_lut = $fopen("D:/pango_build/4_15_PCIE_DMA/sim_night/gamma_lut.txt", "r");
        if (fd_lut == 0) begin
            $display("NIGHT_TB FAIL Cannot open gamma_lut.txt");
            $finish;
        end
        for (i = 0; i < 256; i = i + 1) begin
            if ($fscanf(fd_lut, "%d\n", lut_golden[i]) != 1) begin
                $display("NIGHT_TB FAIL Error reading gamma_lut.txt line %0d", i);
                $finish;
            end
        end
        $fclose(fd_lut);

        // Load case4 expected data
        fd_c4_exp = $fopen("case4_expected.txt", "r");
        if (fd_c4_exp == 0) fd_c4_exp = $fopen("D:/pango_build/4_15_PCIE_DMA/sim_night/case4_expected.txt", "r");
        if (fd_c4_exp == 0) begin
            $display("NIGHT_TB FAIL Cannot open case4_expected.txt");
            $finish;
        end
        for (i = 0; i < 3; i = i + 1) begin
            if ($fscanf(fd_c4_exp, "%d\n", exp_mean_c4[i]) != 1) begin
                $display("NIGHT_TB FAIL Error reading case4_expected.txt line %0d", i);
                $finish;
            end
        end
        $fclose(fd_c4_exp);

        // Release reset
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);

        $display("=== STARTING NIGHT ENHANCEMENT TESTS ===");

        //--------------------------------------------------------------
        // CASE 1: 0..255 grey scale LUT check (ON) & Bypass (OFF) + 1 cycle latency check
        //--------------------------------------------------------------
        $display("[CASE 1] Checking Gamma LUT, Bypass, and 1-cycle pipeline latency...");
        mode = 2'b01; // Force ON
        send_vsync();
        if (night_active !== 1'b1) begin
            $display("NIGHT_TB FAIL Case 1: night_active not 1 after force ON vsync");
            $finish;
        end

        // Stream 0..255 with night ON
        for (val_in = 0; val_in < 256; val_in = val_in + 1) begin
            @(posedge clk);
            de_in <= 1'b1;
            hs_in <= val_in[0];
            vs_in <= 1'b0;
            r_in  <= val_in[7:0];
            g_in  <= val_in[7:0];
            b_in  <= val_in[7:0];
            d_de  = 1'b1;
            d_hs  = val_in[0];
            d_vs  = 1'b0;

            @(posedge clk);
            #1; // Sample output after clock edge (1-cycle pipeline delay)
            if (de_out !== d_de || hs_out !== d_hs || vs_out !== d_vs) begin
                $display("NIGHT_TB FAIL Case 1: Timing mismatch! Sync signals not delayed by exactly 1 cycle (val=%0d, de_out=%0b exp=%0b)",
                         val_in, de_out, d_de);
                $finish;
            end
            if (r_out !== lut_golden[val_in] || g_out !== lut_golden[val_in] || b_out !== lut_golden[val_in]) begin
                $display("NIGHT_TB FAIL Case 1: LUT output mismatch for in=%0d: got RGB=(%0d,%0d,%0d), exp=%0d",
                         val_in, r_out, g_out, b_out, lut_golden[val_in]);
                $finish;
            end
        end
        de_in <= 1'b0; hs_in <= 1'b0; vs_in <= 1'b0;
        @(posedge clk);

        // Stream 0..255 with night OFF
        mode = 2'b10; // Force OFF
        send_vsync();
        if (night_active !== 1'b0) begin
            $display("NIGHT_TB FAIL Case 1: night_active not 0 after force OFF vsync");
            $finish;
        end

        for (val_in = 0; val_in < 256; val_in = val_in + 1) begin
            @(posedge clk);
            de_in <= 1'b1;
            hs_in <= val_in[1];
            vs_in <= 1'b0;
            r_in  <= val_in[7:0];
            g_in  <= val_in[7:0];
            b_in  <= val_in[7:0];
            d_de  = 1'b1;
            d_hs  = val_in[1];
            d_vs  = 1'b0;

            @(posedge clk);
            #1;
            if (de_out !== d_de || hs_out !== d_hs || vs_out !== d_vs) begin
                $display("NIGHT_TB FAIL Case 1: Bypass timing mismatch! Sync signals not delayed by exactly 1 cycle (val=%0d)", val_in);
                $finish;
            end
            if (r_out !== val_in[7:0] || g_out !== val_in[7:0] || b_out !== val_in[7:0]) begin
                $display("NIGHT_TB FAIL Case 1: Bypass data mismatch for in=%0d: got RGB=(%0d,%0d,%0d)",
                         val_in, r_out, g_out, b_out);
                $finish;
            end
        end
        de_in <= 1'b0; hs_in <= 1'b0; vs_in <= 1'b0;
        @(posedge clk);
        $display("[CASE 1] Passed.");

        //--------------------------------------------------------------
        // CASE 2: AUTO Hysteresis Sequence
        //   - 10 frames of 100 -> remain DAY (auto_state=0, night_active=0)
        //   - 7 frames of 40 + 1 frame of 100 + 8 frames of 40 -> enter NIGHT on 8th dark frame
        //   - 8 frames of 56 (48-64) -> remain NIGHT (auto_state=1, night_active=1)
        //   - 8 frames of 80 -> exit NIGHT on 8th bright frame
        //--------------------------------------------------------------
        $display("[CASE 2] Checking AUTO Hysteresis FSM...");
        rst_n = 1'b0;
        mode  = 2'b00; // AUTO
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // 10 frames of 100
        for (f = 0; f < 10; f = f + 1) begin
            send_frame_const(8'd100);
            if (auto_state !== 1'b0 || night_active !== 1'b0) begin
                $display("NIGHT_TB FAIL Case 2: In 10 bright frames (frame %0d), auto_state=%0b night_active=%0b (exp 0/0)",
                         f, auto_state, night_active);
                $finish;
            end
        end

        // 7 frames of 40
        for (f = 0; f < 7; f = f + 1) begin
            send_frame_const(8'd40);
            if (auto_state !== 1'b0 || night_active !== 1'b0) begin
                $display("NIGHT_TB FAIL Case 2: Premature night entry in 7 dark frames (frame %0d)", f);
                $finish;
            end
        end

        // 1 frame of 100 (resets counter)
        send_frame_const(8'd100);
        if (auto_state !== 1'b0 || night_active !== 1'b0) begin
            $display("NIGHT_TB FAIL Case 2: Expected day after glitch frame");
            $finish;
        end

        // 8 frames of 40
        for (f = 0; f < 7; f = f + 1) begin
            send_frame_const(8'd40);
            if (auto_state !== 1'b0 || night_active !== 1'b0) begin
                $display("NIGHT_TB FAIL Case 2: Premature night entry before 8th dark frame (frame %0d)", f);
                $finish;
            end
        end
        // 8th dark frame
        send_frame_const(8'd40);
        if (auto_state !== 1'b1 || night_active !== 1'b1) begin
            $display("NIGHT_TB FAIL Case 2: Failed to enter night mode on 8th dark frame (auto_state=%0b, night_active=%0b)",
                     auto_state, night_active);
            $finish;
        end

        // 8 frames of 56 (inside hysteresis 48-64 band -> remain night)
        for (f = 0; f < 8; f = f + 1) begin
            send_frame_const(8'd56);
            if (auto_state !== 1'b1 || night_active !== 1'b1) begin
                $display("NIGHT_TB FAIL Case 2: Failed to hold night mode in hysteresis band 56 (frame %0d)", f);
                $finish;
            end
        end

        // 8 frames of 80 (>64)
        for (f = 0; f < 7; f = f + 1) begin
            send_frame_const(8'd80);
            if (auto_state !== 1'b1 || night_active !== 1'b1) begin
                $display("NIGHT_TB FAIL Case 2: Premature day exit before 8th bright frame (frame %0d)", f);
                $finish;
            end
        end
        // 8th bright frame
        send_frame_const(8'd80);
        if (auto_state !== 1'b0 || night_active !== 1'b0) begin
            $display("NIGHT_TB FAIL Case 2: Failed to exit night mode on 8th bright frame (auto_state=%0b, night_active=%0b)",
                     auto_state, night_active);
            $finish;
        end
        $display("[CASE 2] Passed.");

        //--------------------------------------------------------------
        // CASE 3: Mode 01 / 10 / 11 Forced Behavior
        //--------------------------------------------------------------
        $display("[CASE 3] Checking Mode forced override...");
        // Force ON (01) while bright (100)
        mode = 2'b01;
        send_frame_const(8'd100);
        if (night_active !== 1'b1) begin
            $display("NIGHT_TB FAIL Case 3: Mode 01 did not force night_active=1");
            $finish;
        end

        // Force OFF (10) while dark (20)
        mode = 2'b10;
        for (f = 0; f < 10; f = f + 1) begin
            send_frame_const(8'd20);
            if (night_active !== 1'b0) begin
                $display("NIGHT_TB FAIL Case 3: Mode 10 did not force night_active=0");
                $finish;
            end
        end
        // Note: AUTO state machine must continue running in background!
        if (auto_state !== 1'b1) begin
            $display("NIGHT_TB FAIL Case 3: AUTO FSM did not continue running under forced OFF");
            $finish;
        end

        // Force OFF (11)
        mode = 2'b11;
        send_frame_const(8'd20);
        if (night_active !== 1'b0) begin
            $display("NIGHT_TB FAIL Case 3: Mode 11 did not force night_active=0");
            $finish;
        end

        // Return to AUTO (00): should immediately take auto_state (=1)
        mode = 2'b00;
        send_frame_const(8'd20);
        if (night_active !== 1'b1) begin
            $display("NIGHT_TB FAIL Case 3: Mode 00 failed to restore active AUTO state");
            $finish;
        end
        $display("[CASE 3] Passed.");

        //--------------------------------------------------------------
        // CASE 4: Mean calculation vs Python expected (error <= 1 LSB)
        //--------------------------------------------------------------
        $display("[CASE 4] Checking Mean calculation accuracy on 3 non-uniform frames...");
        fd_c4_data = $fopen("case4_data.txt", "r");
        if (fd_c4_data == 0) fd_c4_data = $fopen("D:/pango_build/4_15_PCIE_DMA/sim_night/case4_data.txt", "r");
        if (fd_c4_data == 0) begin
            $display("NIGHT_TB FAIL Cannot open case4_data.txt");
            $finish;
        end

        for (f = 0; f < 3; f = f + 1) begin
            for (p = 0; p < PIXELS_PER_FRAME; p = p + 1) begin
                if ($fscanf(fd_c4_data, "%d %d %d\n", r_file, g_file, b_file) != 3) begin
                    $display("NIGHT_TB FAIL Error reading case4_data.txt frame %0d pixel %0d", f, p);
                    $finish;
                end
                @(posedge clk);
                de_in <= 1'b1;
                r_in  <= r_file;
                g_in  <= g_file;
                b_in  <= b_file;
            end
            @(posedge clk);
            de_in <= 1'b0;
            r_in  <= 8'd0;
            g_in  <= 8'd0;
            b_in  <= 8'd0;
            send_vsync();

            // Check mean against Python expected
            diff_c4 = mean - exp_mean_c4[f];
            if (diff_c4 < 0) diff_c4 = -diff_c4;
            $display("  Frame %0d: DUT mean=%0d, Python expected=%0d, diff=%0d", f, mean, exp_mean_c4[f], diff_c4);
            if (diff_c4 > 1) begin
                $display("NIGHT_TB FAIL Case 4: Frame %0d mean error (%0d) exceeds 1 LSB!", f, diff_c4);
                $finish;
            end
        end
        $fclose(fd_c4_data);
        $display("[CASE 4] Passed.");

        //--------------------------------------------------------------
        // Final Summary
        //--------------------------------------------------------------
        $display("========================================");
        $display("NIGHT_TB PASS");
        $display("========================================");
        $finish;
    end

endmodule
