`timescale 1ns / 1ps
// Unit test (BUG-012): when restart arrives in the same cycle an instruction completes,
// the instruction must have no side effects (no FIFO pop or push, no flag change, no IRQ).
module tb_engine_restart;
  logic clk = 0, rst_n = 0, restart = 0;
  always #5 clk = ~clk;
  logic [15:0] instr;
  logic [5:0]  pc;
  logic [7:0]  pins_out, pins_oe, rx_data;
  logic [3:0]  flag_set, flag_clr;
  logic        tx_pop, rx_push, irq;
  int errors = 0;

  pbe_engine dut (
      .clk, .rst_n,
      .run(1'b1), .restart,
      .clkdiv(16'd0), .pin_base(3'd0), .jmp_pin(3'd0),
      .out_msb_first(1'b0), .in_msb_first(1'b0), .start_pc(6'd0),
        .bitdiv(8'd31),
      .pc, .instr,
      .pins_in(8'h00), .pins_out, .pins_oe,
      .tx_data(8'h5A), .tx_empty(1'b0), .tx_pop,
      .rx_data, .rx_full(1'b0), .rx_push,
      .flags(4'h0), .flag_set, .flag_clr, .irq
  );

  task automatic try(input logic [15:0] word, input string name);
    instr = word;
    @(negedge clk);
    restart = 1;
    #1;  // combinational strobes settle while restart is high
    if (tx_pop || rx_push || flag_set != 0 || flag_clr != 0 || irq) begin
      errors++;
      $display("  FAIL: %s had side effects during restart (pop %b push %b set %b clr %b irq %b)",
               name, tx_pop, rx_push, flag_set, flag_clr, irq);
    end
    @(negedge clk);
    restart = 0;
  endtask

  initial begin
    repeat (3) @(posedge clk);
    rst_n = 1;
    try(16'hA000, "PULL");
    try(16'hB000, "PUSH");
    try(16'hC000, "FLAG 0, SET");
    try(16'hC800, "FLAG 0, CLR");
    try(16'hD000, "FLAG 0, IRQ");
    if (errors == 0) begin
      $display("PASS: restart suppresses instruction side effects");
      $finish;
    end else $fatal(1, "FAILED with %0d error(s)", errors);
  end
endmodule
