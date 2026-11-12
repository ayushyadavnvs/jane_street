`timescale 1ns / 1ps
// End-to-end test of the PS/2 host (ps2_host.pbe, D84) through the chip's pins, against a
// PS/2 keyboard model written from the protocol description (ps2_dev.sv).
//   engine 0: ps2_host.pbe at word 0; pin 0 = CLK, pin 1 = DATA, both pulled up, open-drain.
// Scenarios: scan codes from the keyboard, host commands with the device's ACK and answers
// (0xED + LED byte, 0xEE echo, 0xF2 read ID, 0xFF reset), a parity error and a framing error
// from the device, a command the device does not acknowledge, a device that never answers a
// request to send (timeout, then recovery), and a command queued while the device is sending.
module tb_ps2;
  localparam real CLK_NS = 20.8333;  // 48 MHz
  localparam int HOST_HALF = 8;

  logic clk = 0, rst_n = 0;
  always #(CLK_NS / 2) clk = ~clk;

  logic [7:0] ui_in = 8'b0000_0010;
  wire  [7:0] uo_out, uio_out, uio_oe;
  wire  dev_clk_low, dev_dat_low;
  // pull-ups on CLK and DATA; the chip and the device only pull low
  wire  [7:0] chip_lvl = (~uio_oe) | uio_out;
  wire  [7:0] bus = chip_lvl & ~{6'b0, dev_dat_low, dev_clk_low};

  tt_um_ayushyadavnvs_pbe dut (
      .ui_in, .uo_out, .uio_in(bus), .uio_out, .uio_oe, .ena(1'b1), .clk, .rst_n
  );
  ps2_dev u_dev (.clk_line(bus[0]), .dat_line(bus[1]), .clk_low(dev_clk_low), .dat_low(dev_dat_low));

`ifdef PBE_SIGROK
  wire p0 = bus[0], p1 = bus[1];
  initial begin
    $dumpfile("tb_ps2_pins.vcd");
    $dumpvars(0, p0, p1);
  end
`endif

  `include "tb_host.svh"

  // The chip only ever drives a PS/2 line low (open drain).
  int drive_high = 0;
  always @(posedge clk) if ((uio_oe[0] && uio_out[0]) || (uio_oe[1] && uio_out[1])) drive_high++;

  // one RX record: two bytes
  task automatic rx_rec(output logic [7:0] b, output logic [7:0] s);
    longint n = 0;
    for (int k = 0; k < 2; k++) begin
      n = 0;
      while (!uo_out[4] && n < 4_000_000) begin
        @(posedge clk);
        n++;
      end
      check(uo_out[4], "no RX byte from the PS/2 host");
      if (k == 0) reg_read(7'h16, b);
      else reg_read(7'h16, s);
    end
`ifdef PBE_SIGROK
    $display("SIGROK_PS2 %02x %02x", b, s);
`endif
  endtask

  int pass = 0;
  task automatic result(input string name, input bit ok);
    check(ok, name);
    if (ok) pass++;
    $display("  PS/2 %-52s %s", name, ok ? "PASS" : "FAIL");
  endtask

  // a command: expect [cmd][ack status], then the device's answer bytes
  task automatic command(input logic [7:0] c, input logic [7:0] ack_st, inout bit ok);
    logic [7:0] b, s;
    fifo_send(0, c);
    rx_rec(b, s);
    ok &= b == c && s == ack_st;
    if (!(b == c && s == ack_st)) $display("    command %02x: record %02x %02x", c, b, s);
  endtask
  task automatic expect_byte(input logic [7:0] e, input logic [7:0] st, inout bit ok);
    logic [7:0] b, s;
    rx_rec(b, s);
    ok &= b == e && s == st;
    if (!(b == e && s == st)) $display("    expected %02x %02x, got %02x %02x", e, st, b, s);
  endtask

  initial begin
    logic [7:0] b, s;
    bit ok;
    int n0;
    repeat (5) @(posedge clk);
    @(negedge clk) rst_n = 1;
    repeat (5) @(posedge clk);
    load_program("ps2_image.hex");
    reg_write(7'h00, 8'b0100_0000);   // stop, flush
    reg_write(7'h10, 8'd239);         // CLKDIV 239: a 5 us tick
    reg_write(7'h11, 8'd0);
    reg_write(7'h12, 8'd0);           // pin base 0
    reg_write(7'h13, 8'd1);           // JMP_PIN = DATA
    reg_write(7'h14, 8'h00);          // LSB first
    reg_write(7'h15, 8'd0);           // start
    reg_write(7'h1B, 8'h00);          // CRC off
    reg_write(7'h32, 8'hFF);          // CRC_GOOD = 0xFFFF: status bit 1 reads 0
    reg_write(7'h33, 8'hFF);
    reg_write(7'h1C, 8'(4000));       // TIMEOUT 4000 ticks = 20 ms
    reg_write(7'h1D, 8'(4000 >> 8));
    reg_write(7'h1E, 8'h81);          // odd parity, timeout vector at word 1
    reg_write(7'h00, 8'b0001_0001);   // restart and run engine 0

    // 1: scan codes (set 2): 'A' make and break, extended up-arrow make and break
    ok = 1;
    begin
      logic [7:0] e[$];
      e = '{8'h1C, 8'hF0, 8'h1C, 8'hE0, 8'h75, 8'hE0, 8'hF0, 8'h75};
      foreach (e[i]) u_dev.tx_q.push_back(e[i]);
      foreach (e[i]) expect_byte(e[i], 8'h00, ok);
    end
    result("scan codes: A make/break, extended up-arrow", ok);

    // 2: Set LEDs: 0xED, ACK 0xFA, the LED byte, ACK 0xFA
    ok = 1;
    command(8'hED, 8'h20, ok);
    expect_byte(8'hFA, 8'h00, ok);
    command(8'h07, 8'h20, ok);
    expect_byte(8'hFA, 8'h00, ok);
    result($sformatf("0xED set LEDs, 0xFA ACKs (LEDs = %0d)", u_dev.leds), ok && u_dev.leds == 8'h07);

    // 3: echo, read ID, reset
    ok = 1;
    command(8'hEE, 8'h20, ok);
    expect_byte(8'hEE, 8'h00, ok);
    command(8'hF2, 8'h20, ok);
    expect_byte(8'hFA, 8'h00, ok);
    expect_byte(8'hAB, 8'h00, ok);
    expect_byte(8'h83, 8'h00, ok);
    command(8'hFF, 8'h20, ok);
    expect_byte(8'hFA, 8'h00, ok);
    expect_byte(8'hAA, 8'h00, ok);
    result("0xEE echo, 0xF2 ID (AB 83), 0xFF reset (FA AA)", ok);

    // 4: a byte with a bad parity bit, then a good one
    ok = 1;
    u_dev.bad_parity_next = 1;
    u_dev.tx_q.push_back(8'h55);
    u_dev.tx_q.push_back(8'h55);
    expect_byte(8'h55, 8'h01, ok);
    expect_byte(8'h55, 8'h00, ok);
    result("device byte with a parity error reported (status 0x01)", ok);

    // 5: a stop bit of 0
    ok = 1;
    u_dev.bad_stop_next = 1;
    u_dev.tx_q.push_back(8'h3C);
    u_dev.tx_q.push_back(8'h29);
    rx_rec(b, s);
    ok = b == 8'h3C && s == 8'h80;
    expect_byte(8'h29, 8'h00, ok);   // space: framing is back
    result("device byte with a 0 stop bit: framing error (0x80)", ok);

    // 6: the device does not acknowledge a command
    ok = 1;
    u_dev.no_ack_next = 1;
    command(8'hF4, 8'hA0, ok);
    expect_byte(8'hFA, 8'h00, ok);   // the model still answers
    result("command not acknowledged (0xA0)", ok);

    // 7: no device answer to a request to send: timeout after 20 ms, lines released, recovery
    ok = 1;
    u_dev.mute = 1;
    n0 = u_dev.n_rx;
    fifo_send(0, 8'hF5);
    rx_rec(b, s);
    ok = b == 8'h00 && s == 8'h04 && bus[0] && bus[1] && u_dev.n_rx == n0;
    u_dev.mute = 0;
    command(8'hF4, 8'h20, ok);
    expect_byte(8'hFA, 8'h00, ok);
    result("no clock after a request to send: timeout (00 04), recovery", ok);

    // 8: a command queued while the device sends: the device's byte first, then the command
    ok = 1;
    u_dev.tx_q.push_back(8'h5A);
    wait (!u_dev.dev_clocking);   // the previous byte's last clock (its record is read before it ends)
    wait (u_dev.dev_clocking);
    fifo_send(0, 8'hED);
    expect_byte(8'h5A, 8'h00, ok);
    rx_rec(b, s);
    ok &= b == 8'hED && s == 8'h20;
    expect_byte(8'hFA, 8'h00, ok);
    command(8'h02, 8'h20, ok);
    expect_byte(8'hFA, 8'h00, ok);
    result("command queued during a device byte waits for it", ok && u_dev.leds == 8'h02);

    check(u_dev.n_errors == 0, $sformatf("the PS/2 device model saw %0d protocol errors", u_dev.n_errors));
    check(drive_high == 0, $sformatf("the chip drove a PS/2 line high for %0d clocks", drive_high));
    begin
      logic [7:0] st;
      reg_read(7'h1F, st);
      check(!st[3], "RX overflow reported");
    end
    $display("  PS/2 scenarios passed: %0d of 8; device: %0d bytes received, %0d sent, %0d requests to send",
             pass, u_dev.n_rx, u_dev.n_tx, u_dev.n_rts);
    if (errors == 0 && pass == 8) begin
      $display("PASS: PS/2 host");
      $finish;
    end else $fatal(1, "FAILED with %0d error(s)", errors);
  end

  initial begin
    #400ms;
    $fatal(1, "FAILED: timeout");
  end
endmodule
