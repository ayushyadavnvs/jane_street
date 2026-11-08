`timescale 1ns / 1ps
// Unit test of the compare and move instructions (JEQ, JNE, MOV), the inverted CRC output
// (OSRCRC ..., INV) and the CRC good value, on one engine running ops_test.pbe.
// The CRC unit is set up as USB's CRC16: the known USB packet DATA0 80 06 00 01 00 00 40 00
// must give the CRC field dd 94, and the packet plus that field must leave the register at
// USB's residual 800d, which "CRC ok" must accept.
// A second engine (e2) runs can_ops.pbe in bit-synchronous (CAN) mode alone on a wired-AND
// bus with a real TX FIFO: split pins (LINE2[4]), PULL NOWAIT, MARK, REWIND, LINECTL, the CRC
// fed from the line, OSRCRC LEFT (CRC-15/CAN check value 0x059E), the line-event vector after
// an ACK error, and TEC 8.
module tb_engine_ops;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic [15:0] prog[512];  // an image: engine 0's memory is words 0-255
  logic [7:0]  pc;
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
      .out_msb_first(1'b0), .in_msb_first(1'b0), .start_pc(8'd0),
      .crc_poly(16'h8005), .crc_cfg(8'h7F), .timeout(16'h0), .line_cfg(8'h0),
      .coder_cfg(8'h0), .coder_cfg2(8'h0), .sync(8'h0), .crc_good(16'h800D),
      .host_crc_init(1'b0), .host_tmo_clr(1'b0), .host_ovf_clr(1'b0), .host_lerr_clr(1'b0),
      .host_arb_clr(1'b0), .host_berr_clr(1'b0), .host_sent_clr(1'b0),
      .status(), .crc_now(), .can_tec(), .can_rec(), .can_state(),
      .pc, .instr(prog[pc]),
      .pins_in(8'h00), .pins_out, .pins_oe,
      .tx_data(tx_head), .tx_empty(tx_none), .tx_pop, .tx_mark(), .tx_rewind(),
      .rx_data, .rx_full(1'b0), .rx_push,
      .flags(4'h0), .flag_set, .flag_clr, .irq
  );

  // ---- e2: bit-synchronous mode ----
  logic [15:0] prog2[512];
  logic [7:0]  pc2;
  logic [7:0]  po2, oe2, rxd2, tx2_din = 0, tx2_dout, got2[$];
  logic        tx2_push = 0, tx2_empty, tx2_pop, tx2_mark, tx2_rewind, rx2_push;
  logic [3:0]  flags2 = 0;
  logic [8:0]  tec2;
  logic [7:0]  dly2 = '1;   // a 3-clock transceiver loop on pin 1 (RX); pin 0 reads recessive
  wire         bus2 = !(oe2[0] && !po2[0]);
  always @(posedge clk) dly2 <= {dly2[6:0], bus2};
  pbe_fifo #(.ADDR_BITS(4)) txf2 (
      .clk, .rst_n, .flush(1'b0), .push(tx2_push), .din(tx2_din), .pop(tx2_pop),
      .mark(tx2_mark), .rewind(tx2_rewind), .dout(tx2_dout), .empty(tx2_empty), .full(), .count());
  pbe_engine e2 (
      .clk, .rst_n,
      .run(1'b1), .restart(1'b0),
      .clkdiv(16'd47), .pin_base(3'd0), .jmp_pin(3'd0),
      .out_msb_first(1'b1), .in_msb_first(1'b1), .start_pc(8'd0),
      .crc_poly(16'h4599), .crc_cfg(8'h8E), .timeout(16'h0), .line_cfg(8'h40 | 8'd39),
      .coder_cfg(8'h0D), .coder_cfg2(8'h72), .sync(8'h0), .crc_good(16'h0),
      .host_crc_init(1'b0), .host_tmo_clr(1'b0), .host_ovf_clr(1'b0), .host_lerr_clr(1'b0),
      .host_arb_clr(1'b0), .host_berr_clr(1'b0), .host_sent_clr(1'b0),
      .status(), .crc_now(), .can_tec(tec2), .can_rec(), .can_state(),
      .pc(pc2), .instr(prog2[pc2]),
      .pins_in({6'b0, dly2[2], 1'b1}), .pins_out(po2), .pins_oe(oe2),
      .tx_data(tx2_dout), .tx_empty(tx2_empty), .tx_pop(tx2_pop), .tx_mark(tx2_mark), .tx_rewind(tx2_rewind),
      .rx_data(rxd2), .rx_full(1'b0), .rx_push(rx2_push),
      .flags(flags2), .flag_set(), .flag_clr(), .irq()
  );
  always @(posedge clk) if (rx2_push) got2.push_back(rxd2);

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
    $readmemh("can_ops_image.hex", prog2);
    tx_q = '{8'h80, 8'h06, 8'h00, 8'h01, 8'h00, 8'h00, 8'h40, 8'h00};
    tx_update;
    exp = '{8'h5A, 8'h81, 8'h03, 8'hDD, 8'h94, 8'h22, 8'h02, 8'hA5};
    repeat (3) @(posedge clk);
    @(negedge clk) rst_n = 1;  // released between edges, not at one (BUG-102)
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
    // e2: queue "123456789", raise FLAG0, let the frame run (integration + ~110 bits)
    for (int i = 0; i < 9; i++) begin
      @(negedge clk); tx2_din = 8'h31 + 8'(i); tx2_push = 1;
      @(negedge clk); tx2_push = 0;
    end
    flags2 = 4'b0001;
    repeat (48 * 140) @(posedge clk);
    exp = '{8'hFF, 8'h31, 8'h32, 8'h31, 8'h31, 8'h32, 8'h33, 8'h34, 8'h35, 8'h36, 8'h37, 8'h38, 8'h39,
            8'h0B, 8'h3C, 8'h10};
    if (got2.size() != exp.size()) begin
      errors++;
      $display("  FAIL: CAN-mode engine pushed %0d bytes, expected %0d", got2.size(), exp.size());
    end
    foreach (got2[i])
      if (i >= exp.size() || got2[i] !== exp[i]) begin
        errors++;
        $display("  FAIL: CAN-mode byte %0d is %02x, expected %02x", i, got2[i], i < exp.size() ? exp[i] : 8'hxx);
      end
    if (tec2 !== 9'd8) begin
      errors++;
      $display("  FAIL: TEC %0d after an ACK error, expected 8", tec2);
    end
    if (errors == 0) begin
      $display("PASS: JEQ, JNE, MOV, OSRCRC INV and the CRC good value (USB CRC16 dd 94, residual 800d)");
      $display("PASS: CAN mode: split pins, PULL NOWAIT/MARK/REWIND, LINECTL, line-fed CRC-15, OSRCRC LEFT 0b3c, vector, TEC 8");
      $finish;
    end else $fatal(1, "FAILED with %0d error(s)", errors);
  end
endmodule
