`timescale 1ns/1ps
module tb_ms72;
  reg clk=0, rst_n=0; always #50 clk=~clk;           // 10 MHz cfg_clk
  wire scl; wire sda; pullup(sda);
  wire io_rx, io;
  ms72xx_ctl dut(.clk(clk),.rst_n(rst_n),.init_over_rx(io_rx),.init_over(io),.iic_scl(scl),.iic_sda(sda),
                 .reinit_tgl(1'b0),.stat_tgl(),.stat_bus());
  // decode the address byte of the first few I2C transactions (START = SDA falls while SCL high)
  integer n=0, b; reg [7:0] sh;
  initial begin
    #1000 rst_n=1;
    repeat (4) begin
      @(negedge sda iff scl===1'b1);
      sh=0; for (b=0;b<8;b=b+1) begin @(posedge scl); sh={sh[6:0],sda===1'b1}; end
      $display("txn %0d addr byte = %02h at %0t", n, sh, $time); n=n+1;
    end
    $finish;
  end
  initial #50_000_000 begin $display("TIMEOUT"); $finish; end
endmodule
