`timescale 1ns/1ps
// FIFO boundary contract, independent of host/engine request gating.
module tb_fifo_robustness;
  logic clk=0, rst_n=0, flush=0, push=0, pop=0;
  logic [7:0] din=0;
  wire [7:0] dout;
  wire empty, full;
  wire [4:0] count;
  always #5 clk=~clk;
  pbe_fifo #(.ADDR_BITS(4)) dut(.*);
  task automatic tick;
    @(posedge clk); #1;
  endtask
  task automatic require(input logic condition, input string message);
    if (condition !== 1'b1) $fatal(1, "FIFO boundary: %s count=%0d empty=%b full=%b", message, count, empty, full);
  endtask
  initial begin
    tick(); @(negedge clk); rst_n=1; tick();
    require(count==0 && empty && !full, "reset empties");
    @(negedge clk); pop=1; tick();
    require(count==0 && empty && !full, "empty pop must be ignored");
    @(negedge clk); pop=0;
    for (int i=0;i<16;i++) begin
      push=1; din=8'(i+8'h40); tick();
      require(count==i+1, "count after accepted push");
      @(negedge clk);
    end
    require(full && !empty, "sixteenth push fills");
    din=8'hee; tick();
    require(count==16 && full, "full push must be ignored");
    @(negedge clk); push=0;
    for (int i=0;i<16;i++) begin
      require(dout==8'(i+8'h40), "FIFO data order / rejected push preserves oldest");
      pop=1; tick();
      require(count==15-i, "count after accepted pop");
      @(negedge clk);
    end
    tick();
    require(count==0 && empty, "repeated empty pop must be ignored");
    @(negedge clk); pop=0; push=1; din=8'h22; tick();
    @(negedge clk); push=0; flush=1; tick();
    require(count==0 && empty && !full, "flush empties");
    $display("PASS: FIFO boundary, rejection, order and flush");
    $finish;
  end
  initial begin #10000; $fatal(1,"FIFO boundary test timeout"); end
endmodule
