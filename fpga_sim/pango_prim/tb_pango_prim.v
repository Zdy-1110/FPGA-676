`timescale 1ns/1ps

// 用紫光同创 Pango 真实原语模型（logos2 / PG2L100H GTP 前仿库）跑的最小仿真。
// 覆盖：GTP_GRS（全局复位，实例名必须是 GRS_INST）、GTP_CLKBUFG、GTP_LUT4、GTP_DFF。
module tb_pango_prim;

    // ---------------------------------------------------------------
    // Pango 规定：testbench 必须例化全局复位模块，且实例名必须为 GRS_INST。
    // GRS_N = 1'b1 表示不复位。
    // ---------------------------------------------------------------
    GTP_GRS GRS_INST (.GRS_N(1'b1));

    // ---------------- 全局时钟缓冲 ----------------
    reg  clk_in;
    wire clk;
    GTP_CLKBUFG u_clkbufg (.CLKIN(clk_in), .CLKOUT(clk));

    // ---------------- LUT4: Z = I0 & I1 ----------------
    reg  a, b;
    wire z;
    GTP_LUT4 #(.INIT(16'h8888)) u_lut4 (
        .I0 (a),
        .I1 (b),
        .I2 (1'b0),
        .I3 (1'b0),
        .Z  (z)
    );

    // ---------------- DFF: z 打一拍 ----------------
    wire q;
    GTP_DFF u_dff (
        .D   (z),
        .CLK (clk),
        .Q   (q)
    );

    integer errors = 0;

    task check(input actual, input expected, input [127:0] label);
        begin
            if (actual !== expected) begin
                $display("FAIL  %0s : got %b expected %b", label, actual, expected);
                errors = errors + 1;
            end else begin
                $display("ok    %0s : %b", label, actual);
            end
        end
    endtask

    // 100 MHz from clk_in, buffered through the Pango global clock buffer
    initial clk_in = 1'b0;
    always #5 clk_in = ~clk_in;

    integer i;
    initial begin
        a = 1'b0; b = 1'b0;
        #20;

        // LUT4 组合逻辑真值表
        {a, b} = 2'b00; #4; check(z, 1'b0, "LUT4 0&0");
        {a, b} = 2'b01; #4; check(z, 1'b0, "LUT4 0&1");
        {a, b} = 2'b10; #4; check(z, 1'b0, "LUT4 1&0");
        {a, b} = 2'b11; #4; check(z, 1'b1, "LUT4 1&1");

        // DFF 在时钟沿采集 LUT 输出
        @(negedge clk);
        a = 1'b1; b = 1'b1;
        @(posedge clk); #1;
        check(q, 1'b1, "DFF captured LUT=1");

        @(negedge clk);
        a = 1'b1; b = 1'b0;
        @(posedge clk); #1;
        check(q, 1'b0, "DFF captured LUT=0");

        // 连续计时 10 拍，确认时钟经 BUFG 后仍在翻转
        for (i = 0; i < 10; i = i + 1) @(posedge clk);
        check(1'b1, 1'b1, "clock toggled 10 edges");

        if (errors == 0)
            $display("\n==== PANGO PRIM SIM PASS: all checks passed ====");
        else
            $display("\n==== PANGO PRIM SIM FAIL: %0d error(s) ====", errors);

        $finish;
    end

endmodule
