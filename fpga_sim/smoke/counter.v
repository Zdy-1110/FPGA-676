// 8-bit synchronous up-counter with enable and synchronous clear.
module counter #(
    parameter WIDTH = 8
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire             en,
    output reg [WIDTH-1:0]  cnt
);

    always @(posedge clk) begin
        if (!rst_n)
            cnt <= {WIDTH{1'b0}};
        else if (en)
            cnt <= cnt + 1'b1;
    end

endmodule
