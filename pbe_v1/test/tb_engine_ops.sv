`timescale 1ns / 1ps
// Unit test of the compare and move instructions (JEQ, JNE, MOV), the inverted CRC output
// (OSRCRC ..., INV) and the CRC good value, on one engine running ops_test.pbe.
// The CRC unit is set up as USB's CRC16: the known USB packet DATA0 80 06 00 01 00 00 40 00
// must give the CRC field dd 94, and the packet plus that field must leave the register at
// USB's residual 800d, which "CRC ok" must accept.
module tb_engine_ops;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic [15:0] prog[128];
  logic [6:0]  pc;
  logic [7:0]  pins_out, pins_oe, rx_data, tx_q[$], got[$];
  logic [3:0]  flag_set, flag_clr;
  logic        tx_pop, rx_push, irq;
  int errors = 0;
  logic [7:0] tx_head;
  logic       tx_none;
  // the TX FIFO's outputs, updated by hand: Icarus 12's @* does not see a queue change, and a
  // ternary on a queue in a port connection crashes it (BUG-024)
  task automatic tx_update;
    tx_none = tx_q.size() == 0;
    tx_head = tx_none ? 8'h00 : tx_q[0];
  endtask

  pbe_engine dut (
      .clk, .rst_n,
      .run(1'b1), .restart(1'b0),
      .clkdiv(16'd0), .pin_base(3'd0), .jmp_pin(3'd0),
      .out_msb_first(1'b0), .in_msb_first(1'b0), .start_pc(7'd0),
      .crc_poly(16'h8005), .crc_cfg(8'h7F), .timeout(16'h0), .line_cfg(8'h0),
      .coder_cfg(8'h0), .sync(8'h0), .crc_good(16'h800D),
      .host_crc_init(1'b0), .host_tmo_clr(1'b0), .host_ovf_clr(1'b0), .host_lerr_clr(1'b0),
      .status(), .crc_now(),
      .pc, .instr(prog[pc]),
      .pins_in(8'h00), .pins_out, .pins_oe,
      .tx_data(tx_head), .tx_empty(tx_none), .tx_pop,
      .rx_data, .rx_full(1'b0), .rx_push,
      .flags(4'h0), .flag_set, .flag_clr, .irq
  );

  logic [7:0] d;
  always @(posedge clk) begin
    if (rx_push) got.push_back(rx_data);
    if (tx_pop) begin
      #1;  // after the engine has taken tx_data at this edge
      d = tx_q.pop_front();
      tx_update;
    end
  end

  initial begin
    logic [7:0] exp[$];
    $readmemh("ops_image.hex", prog);
    tx_q = '{8'h80, 8'h06, 8'h00, 8'h01, 8'h00, 8'h00, 8'h40, 8'h00};
    tx_update;
    exp = '{8'h5A, 8'h81, 8'h03, 8'hDD, 8'h94, 8'h22, 8'h02, 8'hA5};
    repeat (3) @(posedge clk);
    rst_n = 1;
    repeat (600) @(posedge clk);
    if (got.size() != exp.size()) begin
      errors++;
      $display("  FAIL: %0d bytes pushed, expected %0d", got.size(), exp.size());
    end
    foreach (got[i])
      if (i >= exp.size() || got[i] !== exp[i]) begin
        errors++;
        $display("  FAIL: byte %0d is %02x, expected %02x", i, got[i], i < exp.size() ? exp[i] : 8'hxx);
      end
    if (flag_set != 0 || irq) begin
      errors++;
      $display("  FAIL: flags or IRQ changed");
    end
    if (errors == 0) begin
      $display("PASS: JEQ, JNE, MOV, OSRCRC INV and the CRC good value (USB CRC16 dd 94, residual 800d)");
      $finish;
    end else $fatal(1, "FAILED with %0d error(s)", errors);
  end
endmodule
