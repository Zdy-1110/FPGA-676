
module tb_mul_test;
    reg signed [31:0] cur_a_op;
    reg signed [31:0] cur_Sxy;
    reg signed [48:0] part_a_low;
    reg signed [47:0] part_a_high;
    reg signed [63:0] term_a_reg;
    reg signed [63:0] expected;

    initial begin
        cur_a_op = -32'sd62259;
        cur_Sxy  = 32'sd55296000;
        
        // Old (buggy) expression:
        part_a_low = cur_a_op * $signed({1'b0, cur_Sxy[15:0]});
        part_a_high = cur_a_op * cur_Sxy[31:16]; // slice is unsigned!
        term_a_reg = part_a_low + (part_a_high <<< 16);
        expected = cur_a_op * cur_Sxy;
        $display("BUGGY: act=%0d exp=%0d match=%0d", term_a_reg, expected, (term_a_reg == expected));

        // Fixed expression:
        part_a_low = cur_a_op * $signed({1'b0, cur_Sxy[15:0]});
        part_a_high = cur_a_op * $signed(cur_Sxy[31:16]);
        term_a_reg = part_a_low + (part_a_high <<< 16);
        $display("FIXED: act=%0d exp=%0d match=%0d", term_a_reg, expected, (term_a_reg == expected));
        $finish;
    end
endmodule
