
module tb_mul_corner;
    reg signed [31:0] cur_a_op;
    reg signed [31:0] cur_Sxy;
    reg signed [48:0] part_a_low;
    reg signed [47:0] part_a_high;
    reg signed [63:0] term_a_reg;
    reg signed [63:0] expected;

    integer i, seed;
    initial begin
        seed = 12345;
        for (i = 0; i < 1000; i = i + 1) begin
            cur_a_op = $random(seed);
            cur_Sxy  = $random(seed);
            
            part_a_low  = cur_a_op * $signed({1'b0, cur_Sxy[15:0]});
            part_a_high = cur_a_op * $signed(cur_Sxy[31:16]);
            term_a_reg  = $signed({{15{part_a_low[48]}}, part_a_low}) + $signed({part_a_high, 16'd0});
            expected    = cur_a_op * cur_Sxy;
            
            if (term_a_reg !== expected) begin
                $display("FAIL: cur_a_op=%0d cur_Sxy=%0d exp=%0d act=%0d", cur_a_op, cur_Sxy, expected, term_a_reg);
                $finish;
            end
        end
        $display("ALL 1000 QUESTA CORNER CASES PASSED!");
        $finish;
    end
endmodule
