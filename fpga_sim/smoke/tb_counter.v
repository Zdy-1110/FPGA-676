`timescale 1ns/1ps

module tb_counter;

    reg         clk;
    reg         rst_n;
    reg         en;
    wire [7:0]  cnt;

    integer errors = 0;

    counter #(.WIDTH(8)) dut (
        .clk   (clk),
        .rst_n (rst_n),
        .en    (en),
        .cnt   (cnt)
    );

    // 100 MHz clock
    initial clk = 1'b0;
    always #5 clk = ~clk;

    task check(input [7:0] expected, input [127:0] label);
        begin
            if (cnt !== expected) begin
                $display("FAIL  %0s : cnt=%0d expected=%0d", label, cnt, expected);
                errors = errors + 1;
            end else begin
                $display("ok    %0s : cnt=%0d", label, cnt);
            end
        end
    endtask

    initial begin
        rst_n = 1'b0;
        en    = 1'b0;

        // hold reset for two cycles
        repeat (2) @(negedge clk);
        check(8'd0, "reset");

        rst_n = 1'b1;
        @(negedge clk);
        check(8'd0, "after reset release");

        // disabled counter must not advance
        en = 1'b0;
        repeat (3) @(negedge clk);
        check(8'd0, "disabled");

        // enable: count 10 cycles
        en = 1'b1;
        repeat (10) @(negedge clk);
        check(8'd10, "counted 10");

        // disable again: must hold
        en = 1'b0;
        repeat (4) @(negedge clk);
        check(8'd10, "held while disabled");

        // wrap-around
        rst_n = 1'b0;
        @(negedge clk);
        rst_n = 1'b1;
        en    = 1'b1;
        repeat (255) @(negedge clk);
        check(8'd255, "reached 255");
        @(negedge clk);
        check(8'd0, "wrapped to 0");

        if (errors == 0)
            $display("\n==== SIM PASS: all checks passed ====");
        else
            $display("\n==== SIM FAIL: %0d error(s) ====", errors);

        $finish;
    end

endmodule
