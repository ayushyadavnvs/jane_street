`timescale 1ns / 1ps
// Instruction fetch (D50), end to end through the chip's pins and host port.
//
//  Timing: engine 0 runs fetch_timing.pbe at CLKDIV = 0, 1 and 3. Every edge of pin 0 is timed
//  in clocks and checked against the rule at the top of pbe_engine.sv:
//    an instruction takes (DLY + 1) * (CLKDIV + 1) clocks, plus 1 if it is a taken jump and
//    CLKDIV = 0; after a WAIT completes, the next instruction is timed from that clock.
//  Host writes: engine 1 runs fetch_host.pbe. The host rewrites
//    (a) the word the stopped engine is parked on, then runs it again without a restart;
//    (b) the first word, then restarts the engine;
//    (c) the word a running engine is blocked on (WAIT FLAG 0, HIGH becomes LOW).
//  Each time the engine must run the new word, not the copy in its instruction register.
module tb_fetch;
  localparam real CLK_NS = 20.8333;  // 48 MHz
  localparam int HOST_HALF = 8;      // host SCK = clk / 16

  logic clk = 0, rst_n = 0;
  always #(CLK_NS / 2) clk = ~clk;

  logic [7:0] ui_in = 8'b0000_0010;  // CS_n high
  wire  [7:0] uo_out, uio_out, uio_oe;
  logic       pin1 = 0;

  tt_um_ayushyadavnvs_pbe dut (
      .ui_in, .uo_out, .uio_in({6'b0, pin1, 1'b0}), .uio_out, .uio_oe, .ena(1'b1), .clk, .rst_n
  );

  `include "tb_host.svh"

  // clock count; pin 0 changes after the edge that counted it
  int cyc = 0;
  always @(posedge clk) cyc++;
  int edges[$];
  always @(uio_out[0]) edges.push_back(cyc);

  // ---------------- timing ----------------
  int k, j, t0, tj0, tj1, t1, t2, lat, rise;
  int exp_d[$];
  task automatic timing(input int clkdiv);
    int got;
    logic [7:0] d;
    k   = clkdiv + 1;             // clocks per tick
    j   = (clkdiv == 0) ? 1 : 0;  // the bubble after a taken jump shows only at CLKDIV = 0
    t0  = k;                      // DLY 0, 1 and 2
    t1  = 2 * k;
    t2  = 3 * k;
    tj0 = k + j;                  // taken jumps, DLY 0 and 1
    tj1 = 2 * k + j;
    // E1-E0 .. E8-E7: two passes of the loop, the first ending in a taken JMP X--
    exp_d = '{t0, t2, t0 + tj1, t0 + tj0, t0, t2, t0 + tj1, t0 + t0};
    reg_write(7'h00, 8'h00);      // stop
    reg_write(7'h10, 8'(clkdiv));
    reg_write(7'h11, 8'h00);
    pin1 = 0;
    edges.delete();
    reg_write(7'h00, 8'h11);      // restart and run engine 0
    while (edges.size() < 9) @(posedge clk);
    repeat (50) @(posedge clk);
    #1 pin1 = 1;
    rise = cyc;                   // the chip's input synchronizer takes it at the next edge
    while (edges.size() < 12) @(posedge clk);
    for (int i = 0; i < 8; i++) begin
      got = edges[i+1] - edges[i];
      check(got == exp_d[i], $sformatf("CLKDIV %0d: E%0d-E%0d = %0d clocks, expected %0d",
                                       clkdiv, i + 1, i, got, exp_d[i]));
    end
    // WAIT sees the pin 3 clocks after it changes (2 synchronizer flops, then the WAIT's
    // clock); the next instruction issues on the first tick after that.
    lat = edges[9] - rise;
    check(lat == 3 + k, $sformatf("CLKDIV %0d: pin 1 rise to E9 = %0d clocks, expected %0d",
                                  clkdiv, lat, 3 + k));
    check(edges[10] - edges[9] == t1, $sformatf("CLKDIV %0d: E10-E9 = %0d clocks, expected %0d",
                                               clkdiv, edges[10] - edges[9], t1));
    check(edges[11] - edges[10] == t0, $sformatf("CLKDIV %0d: E11-E10 = %0d clocks, expected %0d",
                                                clkdiv, edges[11] - edges[10], t0));
    $display("  CLKDIV %0d: edge gaps %0d %0d %0d %0d %0d %0d %0d %0d, WAIT latency %0d", clkdiv,
             edges[1] - edges[0], edges[2] - edges[1], edges[3] - edges[2], edges[4] - edges[3],
             edges[5] - edges[4], edges[6] - edges[5], edges[7] - edges[6], edges[8] - edges[7], lat);
  endtask

  // ---------------- host writes ----------------
  task automatic pm_write(input int word, input logic [15:0] v);
    logic [7:0] d;
    reg_write(7'h06, 8'(word * 2));
    cs(0);
    spi_byte({1'b1, 7'h07}, d);
    spi_byte(v[15:8], d);
    spi_byte(v[7:0], d);
    cs(1);
  endtask

  // the bytes in engine 1's RX FIFO, after giving the engine time to push them
  logic [7:0] rx_got[$];
  task automatic rx_take;
    logic [7:0] n, d;
    rx_got.delete();
    repeat (200) @(posedge clk);
    reg_read(7'h0B, n);
    for (int i = 0; i < n; i++) begin
      reg_read(7'h26, d);
      rx_got.push_back(d);
    end
  endtask

  task automatic expect_rx(input string what, input logic [7:0] a, input int n);
    // a, then 0x33 and 0x5A for case (b)
    logic [7:0] want[$];
    string s;
    want = '{a, 8'h33, 8'h5A};
    rx_take;
    s = "";
    foreach (rx_got[i]) s = {s, $sformatf(" %02x", rx_got[i])};
    check(rx_got.size() == n, $sformatf("%s: %0d bytes (%s ), expected %0d", what, rx_got.size(), s, n));
    for (int i = 0; i < n && i < rx_got.size(); i++)
      check(rx_got[i] == want[i], $sformatf("%s: byte %0d is %02x, expected %02x", what, i,
                                            rx_got[i], want[i]));
    $display("  %s:%s", what, s);
  endtask

  initial begin
    logic [7:0] f;
    $display("Test 12: instruction fetch: timing at CLKDIV 0, 1, 3 and host writes to the program memory");
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (5) @(posedge clk);
    load_program("fetch_image.hex");

    timing(0);
    timing(1);
    timing(3);

    reg_write(7'h00, 8'h00);
    reg_write(7'h25, 8'd64);      // engine 1 runs fetch_host.pbe
    reg_write(7'h00, 8'h22);      // restart and run engine 1
    expect_rx("first run", 8'h11, 1);

    // (a) parked on PULL (word 3), stopped, word 3 becomes SET OSR, 0x33; run, no restart
    reg_write(7'h00, 8'h00);
    repeat (20) @(posedge clk);
    pm_write(64 + 3, 16'h9330);
    repeat (20) @(posedge clk);
    reg_write(7'h00, 8'h02);
    expect_rx("(a) stopped on a word the host rewrote, then run", 8'h33, 1);

    // (c) running, blocked on WAIT FLAG 0, HIGH (word 6); the host writes the low byte only
    reg_write(7'h06, 8'((64 + 6) * 2 + 1));
    reg_write(7'h07, 8'h00);      // 0x4280 -> 0x4200: WAIT FLAG 0, LOW, which holds at once
    rx_got.delete();
    repeat (200) @(posedge clk);
    reg_read(7'h0B, f);
    check(f == 1, $sformatf("(c) blocked on a word the host rewrote: %0d bytes, expected 1", f));
    if (f == 1) begin
      reg_read(7'h26, f);
      check(f == 8'h5A, $sformatf("(c) byte is %02x, expected 5a", f));
      $display("  (c) blocked on a word the host rewrote, running: %02x", f);
    end
    reg_read(7'h04, f);
    check(f == 8'h00, "(c) a flag changed");

    // (b) stopped, word 0 becomes SET OSR, 0x44; restart
    reg_write(7'h00, 8'h00);
    pm_write(64 + 0, 16'h9440);
    reg_write(7'h00, 8'h22);
    expect_rx("(b) first word rewritten, then restart", 8'h44, 3);

    if (errors == 0) begin
      $display("PASS");
      $finish;
    end else $fatal(1, "FAILED with %0d error(s)", errors);
  end

  initial begin
    #5ms;
    $fatal(1, "time limit");
  end
endmodule
