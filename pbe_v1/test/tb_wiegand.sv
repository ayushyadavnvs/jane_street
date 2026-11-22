`timescale 1ns / 1ps
// Blind generality benchmark 5: Wiegand reader, 26 and 34 bits (wiegand.pbe on engine 0,
// wiegand_watch.pbe on engine 1), against a card-reader output model written from the Wiegand
// interface description (SIA AC-01: D0 and D1 idle high, a low pulse of 20-100 us on D0 for a
// 0 and on D1 for a 1, 200 us - 20 ms between pulses; 26 bits: an even parity bit over the
// first 12 data bits, 24 data bits, an odd parity bit over the last 12; 34 bits: 16 and 16).
// D0 = pin 0, D1 = pin 1.
// Cards: 26-bit and 34-bit codes at the nominal timing (50 us, 1 ms), the fastest (20 us,
// 200 us) and slow ones (100 us, 2 ms), a wrong leading and a wrong trailing parity bit,
// and a card cut off after 10 bits (timeout flag), then a good card.
module tb_wiegand;
  localparam real CLK_NS = 16.6672;  // 60 MHz
  localparam int HOST_HALF = 4;

  logic clk = 0, rst_n = 0;
  always #(CLK_NS / 2) clk = ~clk;
  logic [7:0] ui_in = 8'b0000_0010;
  wire  [7:0] uo_out, uio_out, uio_oe;
  logic d0 = 1, d1 = 1;
  wire  [7:0] bus = {6'b0, d1, d0};
  tt_um_ayushyadavnvs_pbe dut (.ui_in, .uo_out, .uio_in(bus), .uio_out, .uio_oe, .ena(1'b1), .clk, .rst_n);
  `include "tb_host.svh"

  int pass = 0;
  task automatic result(input string name, input bit ok);
    check(ok, name);
    if (ok) pass++;
    $display("  WIEG %-62s %s", name, ok ? "PASS" : "FAIL");
  endtask

  // ---------------- the card reader's output ----------------
  real pulse_ns = 50000.0, gap_ns = 1.0e6;
  task automatic wbit(input bit b);
    if (b) d1 = 0;
    else d0 = 0;
    #(pulse_ns);
    d0 = 1;
    d1 = 1;
    #(gap_ns);
  endtask
  // n data bits (24 or 32), MSB first, with the two parity bits; bad: 1 flips the leading
  // parity bit, 2 the trailing one; cut: stop after that many bits (0: send all)
  task automatic card(input logic [31:0] data, input int n, input int bad, input int cut);
    logic [33:0] w;
    bit pe, po;
    int total;
    pe = 0;
    po = 1;
    for (int i = n - 1; i >= n / 2; i--) pe ^= data[i];
    for (int i = n / 2 - 1; i >= 0; i--) po ^= data[i];
    if (bad == 1) pe = ~pe;
    if (bad == 2) po = ~po;
    total = n + 2;
    w = '0;
    w[total - 1] = pe;
    for (int i = 0; i < n; i++) w[i + 1] = data[i];
    w[0] = po;
    for (int i = total - 1; i >= 0; i--)
      if (cut == 0 || total - 1 - i < cut) wbit(w[i]);
  endtask

  // ---------------- host ----------------
  logic [7:0] r[$];
  task automatic read_rec(input int n);
    logic [7:0] c, d;
    int t;
    r = {};
    t = 0;
    while (r.size() < n && t < 40000) begin   // (the slowest card takes 60 ms)
      reg_read(7'h0A, c);
      for (int i = 0; i < c; i++) begin
        reg_read(7'h16, d);
        r.push_back(d);
      end
      repeat (500) @(posedge clk);
      t++;
    end
  endtask
  // the record of a 26-bit card: [b1-8][p1][b9-16][b17-24][b25-26][p2]
  task automatic expect26(input logic [23:0] data, input int bad, input string name);
    logic [25:0] w;
    logic [7:0] x;
    bit pe, po, ok;
    pe = ^data[23:12];
    po = ~^data[11:0];
    if (bad == 1) pe = ~pe;
    if (bad == 2) po = ~po;
    w = {pe, data, po};
    read_rec(6);
    ok = r.size() == 6;
    if (ok) begin
      x = r[0]; ok &= x == w[25:18];
      x = r[1]; ok &= x == (bad == 1 ? 8'h01 : 8'h00);
      x = r[2]; ok &= x == w[17:10];
      x = r[3]; ok &= x == w[9:2];
      x = r[4]; ok &= x == {6'b0, w[1:0]};
      x = r[5]; ok &= x == (bad == 2 ? 8'h00 : 8'h01);
    end
    if (!ok) begin
      $write("    record:");
      foreach (r[i]) $write(" %02x", r[i]);
      $write("\n");
    end
    result(name, ok);
  endtask
  // 34 bits: [b1-8][b9-16][p1][b17-24][b25-32][b33-34][p2]
  task automatic expect34(input logic [31:0] data, input int bad, input string name);
    logic [33:0] w;
    logic [7:0] x;
    bit pe, po, ok;
    pe = ^data[31:16];
    po = ~^data[15:0];
    if (bad == 1) pe = ~pe;
    if (bad == 2) po = ~po;
    w = {pe, data, po};
    read_rec(7);
    ok = r.size() == 7;
    if (ok) begin
      x = r[0]; ok &= x == w[33:26];
      x = r[1]; ok &= x == w[25:18];
      x = r[2]; ok &= x == (bad == 1 ? 8'h01 : 8'h00);
      x = r[3]; ok &= x == w[17:10];
      x = r[4]; ok &= x == w[9:2];
      x = r[5]; ok &= x == {6'b0, w[1:0]};
      x = r[6]; ok &= x == (bad == 2 ? 8'h00 : 8'h01);
    end
    if (!ok) begin
      $write("    record:");
      foreach (r[i]) $write(" %02x", r[i]);
      $write("\n");
    end
    result(name, ok);
  endtask

  task automatic timing(input real p_us, input real g_us);
    pulse_ns = p_us * 1000.0;
    gap_ns = g_us * 1000.0;
  endtask

  initial begin
    bit f;
    repeat (5) @(posedge clk);
    @(negedge clk) rst_n = 1;
    repeat (5) @(posedge clk);
    load_program("wiegand_image.hex");
    reg_write(7'h00, 8'b1100_0000);
    reg_write(7'h03, 8'h00);
    for (int e = 0; e < 2; e++) begin
      logic [6:0] b;
      b = e ? 7'h20 : 7'h10;
      reg_write(b + 0, 8'd119);       // 2 us tick
      reg_write(b + 1, 8'd0);
      reg_write(b + 2, 8'd0);         // the same pin base
      reg_write(b + 3, 8'd1);         // JMP_PIN = D1 (the watcher)
      reg_write(b + 4, e ? 8'h00 : 8'h02);
      reg_write(b + 5, 8'd0);
      reg_write(b + 8, 8'd0);         // FLAG_BASE 0: shared flags
      reg_write(b + 'hB, 8'h00);
      reg_write(b + 'hC, e ? 8'd2 : 8'(12500));
      reg_write(b + 'hD, e ? 8'd0 : 8'(12500 >> 8));
      reg_write(b + 'hE, e ? 8'h41 : 8'h01);
    end
    reg_write(7'h32, 8'hFF);          // engine 0 CRC_GOOD = 0xFFFF
    reg_write(7'h33, 8'hFF);
    reg_write(7'h04, 8'h00);          // flags clear: 26-bit mode
    reg_write(7'h00, 8'b0011_0011);
    repeat (2000) @(posedge clk);

    timing(50, 1000);
    fork card(32'h00A5C3F1, 24, 0, 0); expect26(24'hA5C3F1, 0, "26 bits, 50 us pulses 1 ms apart"); join
    timing(20, 200);
    fork card(32'h00000001, 24, 0, 0); expect26(24'h000001, 0, "26 bits, the fastest: 20 us pulses 200 us apart"); join
    timing(100, 2000);
    fork card(32'h00FFF000, 24, 0, 0); expect26(24'hFFF000, 0, "26 bits, slow: 100 us pulses 2 ms apart"); join
    timing(50, 400);
    fork card(32'h00123456, 24, 1, 0); expect26(24'h123456, 1, "26 bits, wrong leading parity bit: p1 = 1"); join
    fork card(32'h00123456, 24, 2, 0); expect26(24'h123456, 2, "26 bits, wrong trailing parity bit: p2 = 0"); join
    // a card cut off after 10 bits: the timeout sets FLAG3; the host flushes
    card(32'h00FACE55, 24, 0, 10);
    #(30.0e6);
    flag_get(0, 3, f);
    result("a card cut off after 10 bits: FLAG3 (timeout)", f);
    reg_write(7'h00, 8'b0100_0011);   // flush engine 0's FIFOs
    flag_clear(0, 3);
    fork card(32'h00FACE55, 24, 0, 0); expect26(24'hFACE55, 0, "26 bits after the cut card"); join
    // 34 bits
    flag_set(0, 1);
    fork card(32'hDEADBEEF, 32, 0, 0); expect34(32'hDEADBEEF, 0, "34 bits, 50 us pulses 1 ms apart"); join
    timing(20, 200);
    fork card(32'h80000001, 32, 0, 0); expect34(32'h80000001, 0, "34 bits, the fastest"); join
    fork card(32'h0F0F1234, 32, 2, 0); expect34(32'h0F0F1234, 2, "34 bits, wrong trailing parity bit"); join

    if (errors == 0 && pass == 10) begin
      $display("PASS: Wiegand");
      $finish;
    end else $fatal(1, "FAILED with %0d error(s)", errors);
  end
  initial begin
    #2000ms;
    $fatal(1, "FAILED: timeout");
  end
endmodule
