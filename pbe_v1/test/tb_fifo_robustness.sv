`timescale 1ns/1ps
// FIFO boundary contract, independent of host/engine request gating.
module tb_fifo_robustness;
  logic clk=0, rst_n=0, flush=0, push=0, pop=0, mark=0, rewind=0;
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
    // mark and rewind (D66): a frame is read again after a rewind, and while the mark is held
    // the host cannot overwrite it
    @(negedge clk); flush=0;
    for (int i=0;i<4;i++) begin push=1; din=8'(i+8'h60); tick(); @(negedge clk); end
    push=0; mark=1; tick(); @(negedge clk); mark=0;
    for (int i=0;i<3;i++) begin
      require(dout==8'(i+8'h60), "marked data order");
      pop=1; tick(); @(negedge clk);
    end
    pop=0;
    require(count==1, "count after pops past the mark");
    for (int i=0;i<12;i++) begin push=1; din=8'(i+8'h70); tick(); @(negedge clk); end
    require(full && count==13, "full counts from the held mark (4 + 12 = 16)");
    din=8'hee; tick(); @(negedge clk); push=0;
    require(count==13, "a push into the held bytes must be ignored");
    rewind=1; tick(); @(negedge clk); rewind=0;
    require(count==16 && dout==8'h60, "rewind reads again from the mark");
    for (int i=0;i<16;i++) begin
      require(dout==(i<4 ? 8'(i+8'h60) : 8'(i-4+8'h70)), "data after rewind");
      pop=1; tick(); @(negedge clk);
    end
    pop=0;
    require(empty && full, "all read again; the mark is still held");
    mark=1; tick(); @(negedge clk); mark=0;
    require(empty && !full, "a new mark releases the old bytes");
    flush=1; tick(); @(negedge clk); flush=0;
    push=1; din=8'h11; tick(); @(negedge clk); push=0; pop=1; tick(); @(negedge clk); pop=0;
    rewind=1; tick(); @(negedge clk); rewind=0;
    require(empty, "without a mark (after flush) rewind does nothing");
    $display("PASS: FIFO boundary, rejection, order, flush, mark and rewind");
    $finish;
  end
  initial begin #20000; $fatal(1,"FIFO boundary test timeout"); end
endmodule
