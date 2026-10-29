
module dut(
    input wire clk,
    input wire [9:0] dbg_row = 10'd0,
    output wire [7:0] out
);
    assign out = dbg_row[7:0];
endmodule

module tb;
    reg clk = 0;
    wire [7:0] out;
    dut uut (.clk(clk), .out(out));
endmodule
