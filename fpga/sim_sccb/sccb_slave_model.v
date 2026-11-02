`timescale 1ns / 1ps

module sccb_slave_model (
    input  wire scl,
    inout  wire sda,
    input  wire nack_data_en // When high, do not ACK the 4th byte (data byte)
);

    pullup(sda);

    reg sda_out = 1'b1;
    assign sda = (sda_out == 1'b0) ? 1'b0 : 1'bz;

    reg [7:0] shift_in = 8'd0;
    reg [3:0] bit_cnt = 4'd0;
    reg [2:0] byte_cnt = 3'd0;
    reg in_trans = 1'b0;

    // Monitor START and STOP
    always @(negedge sda) begin
        if (scl == 1'b1) begin
            // START condition
            in_trans <= 1'b1;
            bit_cnt <= 4'd0;
            byte_cnt <= 3'd0;
            sda_out <= 1'b1;
        end
    end

    always @(posedge sda) begin
        if (scl == 1'b1) begin
            // STOP condition
            in_trans <= 1'b0;
            bit_cnt <= 4'd0;
            byte_cnt <= 3'd0;
            sda_out <= 1'b1;
        end
    end

    // Clock falling edge: set up SDA (ACK/NACK) or release SDA
    always @(negedge scl) begin
        if (in_trans) begin
            if (bit_cnt == 4'd8) begin
                // 9th clock bit (ACK slot)
                if (byte_cnt == 3'd3 && nack_data_en) begin
                    sda_out <= 1'b1; // NACK
                end else begin
                    sda_out <= 1'b0; // ACK
                end
            end else begin
                sda_out <= 1'b1; // Release bus for data bits
            end
        end else begin
            sda_out <= 1'b1;
        end
    end

    // Clock rising edge: sample data bits
    always @(posedge scl) begin
        if (in_trans) begin
            if (bit_cnt < 4'd8) begin
                shift_in <= {shift_in[6:0], sda};
                bit_cnt  <= bit_cnt + 1'b1;
            end else begin
                // ACK bit finished
                bit_cnt  <= 4'd0;
                byte_cnt <= byte_cnt + 1'b1;
            end
        end
    end

endmodule
