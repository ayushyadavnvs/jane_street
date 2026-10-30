`timescale 1ns / 1ps
// BUG-058/059: preserve observable counterexamples to overly strong prose.
// Default mode verifies existing behavior. The plusargs below deliberately fail
// the original stronger expectations; RTL is never changed to make them pass.
module tb_spec_boundaries;
  logic clk = 0, rst_n = 0, restart = 0, pm_wr = 0;
  always #5 clk = ~clk;
  logic [15:0] prog[128];
  wire [6:0] pc;
  wire [7:0] pins_out, pins_oe;
  bit saw_prefetch64 = 0, saw_instruction64 = 0;
  pbe_engine dut (
    .clk, .rst_n, .run(1'b1), .restart,
    .clkdiv(16'd0), .pin_base(3'd0), .jmp_pin(3'd0),
    .out_msb_first(1'b0), .in_msb_first(1'b0), .start_pc(7'd0),
    .crc_poly(16'd0), .crc_cfg(8'd0), .timeout(16'd0), .line_cfg(8'd0),
    .coder_cfg(8'd0), .sync(8'd0), .crc_good(16'd0),
    .host_crc_init(1'b0), .host_tmo_clr(1'b0), .host_ovf_clr(1'b0), .host_lerr_clr(1'b0),
    .status(), .crc_now(), .pc, .pc_copy(), .instr(prog[pc]), .pm_wr,
    .pins_in(8'd0), .pins_out, .pins_oe,
    .tx_data(8'd0), .tx_empty(1'b1), .tx_pop(),
    .rx_data(), .rx_full(1'b0), .rx_push(),
    .flags(4'd0), .flag_set(), .flag_clr(), .irq()
  );
  // Match top-level PM write ordering: RAM and engine sample pre-edge state.
  always @(posedge clk) if (pm_wr) prog[0] <= 16'h0000; // replacement DRV0
  task automatic sample_clock;
    @(posedge clk); #1;
  endtask
  task automatic reset_at_start;
    @(negedge clk); restart = 1;
    sample_clock();
    @(negedge clk); restart = 0;
    sample_clock(); // target fetch; current instruction is now word 0
  endtask
  initial begin
    for (int i = 0; i < 128; i++) prog[i] = 16'hd800;
    repeat (3) sample_clock();
    @(negedge clk); rst_n = 1;
    reset_at_start();
    for (int i = 0; i < 130; i++) begin
      if (dut.exec && pc == 7'd64) begin
        saw_prefetch64 = 1;
        $display("BUG-058 prefetch pc=64 while instruction 63 executes");
        if ($test$plusargs("EXPECT_WINDOW_FENCE"))
          $fatal(1, "original requested pc<=start_pc+63 property fails");
      end
      if (dut.exec && pc == 7'd65) begin
        saw_instruction64 = 1;
        $display("BUG-058 actual instruction 64 executes outside offset window");
        if ($test$plusargs("EXPECT_INSTRUCTION_WINDOW_FENCE"))
          $fatal(1, "sequential executed-instruction window property fails");
      end
      sample_clock();
    end
    if (!saw_prefetch64 || !saw_instruction64) $fatal(1, "window counterexamples absent");
    @(negedge clk); prog[0] = 16'h0080; // old DRV1
    reset_at_start();
    @(negedge clk); pm_wr = 1;
    if (!dut.exec || dut.instr_q !== 16'h0080) $fatal(1, "ready old instruction setup failed");
    sample_clock();
    $display("BUG-059 PM write edge: out=%02x oe=%02x RAM[0]=%04x iv=%0d next_pc=%0d",
             pins_out, pins_oe, prog[0], dut.iv, pc);
    if ($test$plusargs("EXPECT_WRITE_CANCELLATION") && pins_out[0])
      $fatal(1, "old ready instruction executes on same PM-write edge");
    if (pins_out !== 8'd1 || pins_oe !== 8'd1 || prog[0] !== 16'h0000 || dut.iv || pc != 1)
      $fatal(1, "documented ready-instruction/write behavior changed");
    @(negedge clk); pm_wr = 0;
    sample_clock();
    if (!dut.iv || pc != 2) $fatal(1, "successor refill failed");
    $display("PASS: BUG-058/059 original claims have explicit preserved counterexamples");
    $finish;
  end
  initial begin
    #20us;
    $fatal(1, "time limit");
  end
endmodule
