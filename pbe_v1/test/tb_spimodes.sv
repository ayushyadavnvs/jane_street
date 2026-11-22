`timescale 1ns / 1ps
// Blind generality benchmark, step 3: SPI modes 1, 2 and 3 for the controller
// (spi_ctrl_m1/2/3.pbe, engine 0: SCLK, MOSI, MISO, CS# = pins 0..3) and the peripheral
// (spi_periph_m1/2/3.pbe, engine 1: pins 4..7), each against its own model written from the
// SPI mode definitions (CPOL = the clock's idle level; CPHA 0: sample on the leading edge,
// shift on the trailing one; CPHA 1: shift on the leading edge, sample on the trailing one).
// For each mode: the controller exchanges 6 bytes with a peripheral model that also checks the
// clock's idle level at both CS# edges; a controller model at 2 MHz exchanges 6 bytes with the
// peripheral program (replies queued, then the 0xFF default), in two transactions.
module tb_spimodes;
  localparam real CLK_NS = 16.6672;  // 60 MHz
  localparam int HOST_HALF = 4;

  logic clk = 0, rst_n = 0;
  always #(CLK_NS / 2) clk = ~clk;
  logic [7:0] ui_in = 8'b0000_0010;
  wire  [7:0] uo_out, uio_out, uio_oe;
  bit cpol = 0, cpha = 0;
  // engine 0's side: a peripheral model drives MISO (pin 2)
  logic pm_miso = 1;
  // engine 1's side: a controller model drives SCLK, MOSI, CS# (pins 4, 5, 7)
  logic cm_sclk = 0, cm_mosi = 0, cm_cs = 1;
  wire  [7:0] chip = (uio_oe & uio_out) | (~uio_oe & 8'hFF);   // released pins read high
  wire  [7:0] bus = {cm_cs, chip[6], cm_mosi, cm_sclk, chip[3], pm_miso, chip[1:0]};
  tt_um_ayushyadavnvs_pbe dut (.ui_in, .uo_out, .uio_in(bus), .uio_out, .uio_oe, .ena(1'b1), .clk, .rst_n);
  `include "tb_host.svh"

  int pass = 0;
  task automatic result(input string name, input bit ok);
    check(ok, name);
    if (ok) pass++;
    $display("  SPI  %-62s %s", name, ok ? "PASS" : "FAIL");
  endtask

  // ---------------- peripheral model (for the controller program) ----------------
  wire sclk = bus[0], mosi = bus[1], csn = bus[3];
  logic [7:0] p_rx;
  logic [7:0] p_got[$];
  int p_bits = 0, p_idle_err = 0, p_n = 0;
  wire lead = cpol ? !sclk : sclk;       // 1 after the leading edge
  function automatic logic [7:0] p_reply(input int n);
    return 8'hC3 ^ 8'(n * 29);
  endfunction
  // MISO shows bit (7 - bits sampled so far) of the current reply: at CS# low for CPHA 0, and
  // from every shifting edge on
  logic [7:0] p_cur;
  always @(negedge csn) if (rst_n) begin
    #1;                                  // (a zero-width glitch of the bench's pin mux at a restart is not an edge)
    if (!csn && sclk != cpol) p_idle_err++;
    if (!csn) begin
      p_n = 0;
      p_bits = 0;
      p_cur = p_reply(0);
      if (!cpha) pm_miso = p_cur[7];
    end
  end
  always @(posedge csn) if (rst_n) begin
    #1;
    if (csn && sclk != cpol) p_idle_err++;
  end
  always @(lead) if (rst_n && !csn) begin
    if (lead == !cpha) begin             // the sampling edge
      p_rx = {p_rx[6:0], mosi};
      p_bits++;
      if (p_bits == 8) begin
        p_got.push_back(p_rx);
        p_bits = 0;
        p_n++;
      end
    end else begin                       // the shifting edge
      p_cur = p_reply(p_n);
      pm_miso = p_cur[7 - p_bits];
    end
  end

  // ---------------- controller model (for the peripheral program), 2 MHz ----------------
  localparam real HALF = 250.0;
  task automatic cm_byte(input logic [7:0] tx, output logic [7:0] rx);
    for (int i = 7; i >= 0; i--) begin
      if (!cpha) begin
        cm_mosi = tx[i];
        #(HALF) cm_sclk = !cpol;          // leading: sample
        rx[i] = bus[6];
        #(HALF) cm_sclk = cpol;           // trailing: shift
      end else begin
        cm_sclk = !cpol;                  // leading: shift
        cm_mosi = tx[i];
        #(HALF) cm_sclk = cpol;           // trailing: sample
        rx[i] = bus[6];
        #(HALF);
      end
    end
  endtask

  task automatic run_mode(input int m);
    logic [7:0] x, rx;
    logic [7:0] sent[6];
    bit ok;
    string img;
    cpol = m >= 2;
    cpha = m[0];
    cm_sclk = cpol;
    img = $sformatf("spim%0d_image.hex", m);
    reg_write(7'h00, 8'b1100_0000);
    load_program(img);
    reg_write(7'h03, 8'hF0);
    reg_write(7'h10, 8'd3);           // controller: tick = 4 clocks
    reg_write(7'h11, 8'd0);
    reg_write(7'h12, 8'd0);
    reg_write(7'h14, 8'h03);
    reg_write(7'h15, 8'd0);
    reg_write(7'h1C, 8'd0);
    reg_write(7'h1D, 8'd0);
    reg_write(7'h1E, 8'h40);
    reg_write(7'h20, 8'd0);           // peripheral: CLKDIV 0
    reg_write(7'h21, 8'd0);
    reg_write(7'h22, 8'd4);
    reg_write(7'h23, 8'd3);           // JMP_PIN = CS#
    reg_write(7'h24, 8'h03);
    reg_write(7'h25, 8'd0);
    reg_write(7'h2C, 8'd120);          // 2 us without a clock: 4 SCLK periods
    reg_write(7'h2D, 8'd0);
    reg_write(7'h2E, 8'h01);
    reg_write(7'h00, 8'b0011_0011);
    repeat (200) @(posedge clk);

    // ---- the controller program against the peripheral model ----
    p_got = {};
    for (int i = 0; i < 6; i++) begin
      sent[i] = 8'($urandom);
      if (i == 0) sent[i] = 8'hA5;
      if (i == 1) sent[i] = 8'h01;
    end
    cs(0);
    spi_byte({1'b1, 7'h16}, x);
    for (int i = 0; i < 6; i++) spi_byte(sent[i], x);
    cs(1);
    ok = 1;
    for (int i = 0; i < 6; i++) begin
      fifo_recv(0, rx);
      if (rx !== p_reply(i)) begin
        ok = 0;
        $display("    controller read %02x, the model sent %02x (byte %0d)", rx, p_reply(i), i);
      end
    end
    repeat (200) @(posedge clk);
    if (p_got.size() != 6 || p_idle_err != 0 || !csn)
      $display("    peripheral model: %0d bytes, %0d idle-level errors, CS# %0d", p_got.size(), p_idle_err, csn);
    ok &= p_got.size() == 6 && p_idle_err == 0 && csn;
    for (int i = 0; i < 6 && i < p_got.size(); i++) begin
      x = p_got[i];
      ok &= x === sent[i];
    end
    result($sformatf("mode %0d (CPOL %0d, CPHA %0d): controller, 6 bytes both ways", m, cpol, cpha), ok);

    // ---- the peripheral program against the controller model ----
    ok = 1;
    fifo_send(1, 8'h3C);
    fifo_send(1, 8'h81);
    fifo_send(1, 8'h7E);
    repeat (100) @(posedge clk);
    cm_cs = 0;
    #(4 * HALF);
    for (int i = 0; i < 4; i++) begin
      cm_byte(sent[i], rx);
      x = (i == 0) ? 8'h3C : (i == 1) ? 8'h81 : (i == 2) ? 8'h7E : 8'hFF;   // the 4th: nothing queued
      if (rx !== x) begin
        ok = 0;
        $display("    peripheral replied %02x, expected %02x (byte %0d)", rx, x, i);
      end
      #(2 * HALF);
    end
    cm_cs = 1;
    #(20 * HALF);                             // (longer than the peripheral's TIMEOUT)
    ok &= bus[6] === 1'b1 && !uio_oe[6];      // MISO released
    fifo_send(1, 8'h55);
    repeat (100) @(posedge clk);
    cm_cs = 0;
    #(4 * HALF);
    cm_byte(sent[4], rx);
    ok &= rx === 8'h55;
    cm_byte(sent[5], rx);
    ok &= rx === 8'hFF;
    cm_cs = 1;
    #(8 * HALF);
    for (int i = 0; i < 6; i++) begin
      fifo_recv(1, rx);
      if (rx !== sent[i]) begin
        ok = 0;
        $display("    peripheral received %02x, the model sent %02x (byte %0d)", rx, sent[i], i);
      end
    end
    result($sformatf("mode %0d (CPOL %0d, CPHA %0d): peripheral at 2 MHz, 6 bytes, 2 transactions", m, cpol, cpha), ok);
  endtask

  initial begin
    repeat (5) @(posedge clk);
    @(negedge clk) rst_n = 1;
    repeat (5) @(posedge clk);
    run_mode(1);
    run_mode(2);
    run_mode(3);
    if (errors == 0 && pass == 6) begin
      $display("PASS: SPI modes 1-3");
      $finish;
    end else $fatal(1, "FAILED with %0d error(s)", errors);
  end
  initial begin
    #200ms;
    $fatal(1, "FAILED: timeout");
  end
endmodule
