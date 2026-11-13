`timescale 1ns / 1ps
// The quad host port (D89), end to end through the chip's pins:
//   (a) reset is single-lane SPI, HOSTCFG reads 0;
//   (b) HOSTCFG = 1 takes effect at CS_n high; registers, FIFO bursts and reads work in quad;
//   (c) uo_out[3:1] carry Q3..Q1 only while CS_n is low, IRQ and the running bits otherwise;
//       uo_out[7:4] (RX data, TX full) stay status bits in quad mode;
//   (d) a program load (the UART image) and a UART loopback (engine 0 pin 0 -> engine 1 pin 1)
//       in quad mode, 64 bytes streamed through both FIFOs;
//   (e) back to single mode by writing HOSTCFG = 0, and by 8 SCK pulses with CS_n high (the
//       recovery, also harmless in single mode); a chip reset;
//   (f) the burst rate at SCK = clk / 8 in both modes, both directions.
module tb_quad;
  localparam real CLK_NS = 20.8333;  // 48 MHz
  localparam int HOST_HALF = 4;      // host SCK = clk / 8, the port's maximum
  logic clk = 0, rst_n = 0;
  always #(CLK_NS / 2) clk = ~clk;

  logic [7:0] ui_in = 8'b0000_0010;
  wire  [7:0] uo_out, uio_out, uio_oe;
  // loopback: engine 0's UART TX on pin 0 drives engine 1's RX on pin 1
  wire  [7:0] bus = {6'b0, uio_oe[0] ? uio_out[0] : 1'b1, uio_oe[0] ? uio_out[0] : 1'b1};

  tt_um_ayushyadavnvs_pbe dut (
      .ui_in, .uo_out, .uio_in(bus), .uio_out, .uio_oe, .ena(1'b1), .clk, .rst_n
  );

  `include "tb_host.svh"

  int pass = 0;
  task automatic result(input string name, input bit ok);
    check(ok, name);
    if (ok) pass++;
    $display("  QUAD %-64s %s", name, ok ? "PASS" : "FAIL");
  endtask

  // clocks for n bytes burst-written into a TX FIFO, and burst-read back (one transaction each)
  task automatic burst_rate(input int n, output real wr_clk, output real rd_clk, output bit ok);
    logic [7:0] d, cnt;
    realtime t0;
    ok = 1;
    cs(0);
    t0 = $realtime;
    spi_byte({1'b1, 7'h16}, d);
    for (int i = 0; i < n; i++) spi_byte(8'(i * 7 + 3), d);
    wr_clk = ($realtime - t0) / CLK_NS / (n + 1);  // the command byte too
    cs(1);
    reg_read(7'h0C, cnt);
    if (cnt != 8'(n)) ok = 0;
    // the TX FIFO cannot be read by the host: time a burst read of registers instead
    // (TX_COUNT first; the address then increments)
    cs(0);
    t0 = $realtime;
    spi_byte({1'b0, 7'h0C}, d);
    for (int i = 0; i < n; i++) begin
      spi_byte(8'h00, d);
      if (i == 0 && d != 8'(n)) ok = 0;
    end
    rd_clk = ($realtime - t0) / CLK_NS / (n + 1);
    cs(1);
    reg_write(7'h0E, 8'h01);  // TX_FLUSH E0
  endtask

  logic [7:0] sent[64], got[64];
  task automatic send_all();
    for (int i = 0; i < 64; i++) fifo_send(0, sent[i]);
  endtask
  task automatic recv_all();
    logic [7:0] d;
    for (int i = 0; i < 64; i++) begin
      fifo_recv(1, d);
      got[i] = d;
    end
  endtask

  // ---------------- tests ----------------
  initial begin
    logic [7:0] d, st;
    real wr1, rd1, wr4, rd4;
    bit ok;
    int div_tx, div_rx;

    repeat (5) @(posedge clk);
    @(negedge clk) rst_n = 1;
    repeat (5) @(posedge clk);
    $display("Quad host port (D89), host SCK = clk / %0d", 2 * HOST_HALF);

    // (a)
    reg_read(7'h50, d);
    result("(a) reset: single-lane SPI, HOSTCFG = 0", d == 8'h00 && !host_quad);
    reg_write(7'h04, 8'hA5);
    reg_read(7'h04, d);
    result("(a) single-lane register write and read back", d == 8'hA5);

    // (f) single-lane rate
    burst_rate(16, wr1, rd1, ok);
    result($sformatf("(f) single: %0.1f clocks/byte written, %0.1f read (16-byte bursts)", wr1, rd1), ok);

    // (b)
    host_quad_on();
    result("(b) HOSTCFG = 1 written in single mode; the port is quad from CS_n high",
           host_quad && host_quad_entries == 1);
    reg_read(7'h50, d);
    result("(b) HOSTCFG reads 1 in quad mode", d == 8'h01);
    reg_write(7'h04, 8'h3C);
    reg_read(7'h04, d);
    result("(b) quad register write and read back", d == 8'h3C);
    burst_rate(16, wr4, rd4, ok);
    result($sformatf("(f) quad: %0.1f clocks/byte written, %0.1f read (16-byte bursts)", wr4, rd4), ok);
    result($sformatf("(f) quad / single = %0.2f (write), %0.2f (read)", wr1 / wr4, rd1 / rd4),
           wr1 / wr4 > 3.0 && rd1 / rd4 > 3.0);

    // (c) the borrowed pins (the running bits are checked in (d))
    reg_write(7'h26, 8'h55);  // one byte in E1's TX FIFO, 16 in E0's: TX full on uo_out[6]
    cs(0);
    spi_byte({1'b1, 7'h16}, d);
    for (int i = 0; i < 16; i++) spi_byte(8'(i), d);
    repeat (4) @(negedge clk);
    result("(c) quad, CS_n low: uo_out[6] (E0 TX full) is still a status pin", uo_out[6] && !uo_out[7]);
    cs(1);
    reg_write(7'h00, 8'hC0);  // flush both engines' FIFOs

    // (d) a program load and a UART loopback at 1 Mbaud, in quad mode
    load_program("uart_image.hex");
    div_tx = $rtoi(1000.0 / 2.0 / CLK_NS + 0.5) - 1;  // tick = 1/2 bit
    div_rx = $rtoi(1000.0 / 4.0 / CLK_NS + 0.5) - 1;  // tick = 1/4 bit
    reg_write(7'h03, 8'h02);  // pin 1 to E1
    reg_write(7'h10, 8'(div_tx));
    reg_write(7'h11, 8'h00);
    reg_write(7'h12, 8'd0);   // E0 pin_base 0
    reg_write(7'h14, 8'h00);
    reg_write(7'h15, 8'd0);   // START_PC 0
    reg_write(7'h20, 8'(div_rx));
    reg_write(7'h21, 8'h00);
    reg_write(7'h22, 8'd1);   // E1 pin_base 1
    reg_write(7'h23, 8'd0);   // JMP_PIN = rx
    reg_write(7'h24, 8'h00);
    reg_write(7'h25, 8'd8);   // uart_rx at word 8 of engine 1's memory
    reg_write(7'h00, 8'h33);  // restart and run both
    for (int i = 0; i < 64; i++) sent[i] = 8'($urandom);
    fork
      send_all();
      recv_all();
    join
    ok = host_quad;
    for (int i = 0; i < 64; i++) if (got[i] !== sent[i]) ok = 0;
    result("(d) program load and UART loopback in quad mode: 64 bytes", ok);
    repeat (4) @(negedge clk);
    result("(c) CS_n high in quad mode: uo_out[3:1] = {run E1, run E0, IRQ} = 110",
           uo_out[3:1] == 3'b110);

    // (e) back to single mode
    host_quad_off();
    reg_read(7'h50, d);
    result("(e) HOSTCFG = 0 written in quad mode: single again", d == 8'h00 && !host_quad);
    reg_write(7'h04, 8'h96);
    reg_read(7'h04, d);
    result("(e) single-lane register write and read back", d == 8'h96);
    host_recover();  // harmless in single mode
    reg_read(7'h04, d);
    result("(e) 8 SCK pulses with CS_n high in single mode: nothing changes", d == 8'h96);
    host_quad_on();
    reg_read(7'h50, d);
    ok = d == 8'h01 && host_quad;
    host_recover();
    reg_read(7'h50, d);
    result("(e) 8 SCK pulses with CS_n high in quad mode: single again", ok && d == 8'h00);
    host_quad_on();
    host_want_quad = 0;  // the bench does not switch again after the reset
    rst_n = 0;
    repeat (3) @(negedge clk);
    rst_n = 1;
    repeat (3) @(negedge clk);
    reg_read(7'h50, d);
    result("(e) a chip reset returns the port to single mode", d == 8'h00 && !host_quad);

    if (errors == 0) $display("PASS: quad host port (%0d checks)", pass);
    else $fatal(1, "FAILED with %0d error(s)", errors);
    $finish;
  end

  initial begin
    #50ms;
    $fatal(1, "timeout");
  end
endmodule
