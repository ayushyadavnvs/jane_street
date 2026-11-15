`timescale 1ns/1ps
// D90 explicitly says LINE2's idle wait does not apply to Manchester.
module tb_manchester_idle_wait;
  reg clk=0, rst_n=0, put=0;
  wire [1:0] drive, a, b;
  reg seen=0;
  always #8.334 clk=~clk;
  for(genvar k=0;k<2;k=k+1) begin:g
    localparam integer K=k;
    pbe_line dut(.clk,.rst_n,.clear(1'b0),.cfg(8'h23),.cfg2(K==0?8'h00:8'h40),
      .sync(8'd0),.period_m1(16'd5),.out_msb_first(1'b0),.in_msb_first(1'b0),
      .a_in(1'b1),.a_early(1'b1),.b_in(1'b0),.ctl(1'b0),.ctl_param(5'd0),
      .drive(drive[K]),.a_out(a[K]),.b_out(b[K]),.tx_put(put),.tx_end(1'b0),
      .tx_data(8'ha5),.tx_ready(),.rx_valid(),.rx_data(),.rx_take(1'b1),.frame_end(),.err());
  end
  initial begin
    repeat(3) @(negedge clk);
    if(g[0].dut.cfg2 !== 8'h00 || g[1].dut.cfg2 !== 8'h40)
      $fatal(1,"fixture must supply two known and different LINE2 settings");
    $display("PASS: fixture has known LINE2=00 and LINE2=40");
    rst_n=1; put=1;
    @(negedge clk); put=0;
    repeat(80) begin
      @(posedge clk); #1;
      if(drive[0]) seen=1;
      if(drive[0]!==drive[1] || a[0]!==a[1] || b[0]!==b[1])
        $fatal(1,"D90: Manchester must ignore LINE2[6] idle wait");
    end
    if(!seen) $fatal(1,"baseline transmitter never started");
    $display("PASS: Manchester ignores LINE2 idle wait, both transmitters identical");
    $finish;
  end
endmodule
