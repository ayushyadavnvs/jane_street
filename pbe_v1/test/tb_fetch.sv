`timescale 1ns / 1ps
// Instruction fetch (D50), end to end through the chip's pins and host port.
//
//  Timing: engine 0 runs fetch_timing.pbe at CLKDIV = 0, 1 and 3. Every edge of pin 0 is timed
//  in clocks and checked against the rule at the top of pbe_engine.sv:
//    an instruction takes (DLY + 1) * (CLKDIV + 1) clocks, plus 1 if it is a taken jump and
//    CLKDIV = 0; after a WAIT completes, the next instruction is timed from that clock.
//  Host writes: engine 1 runs fetch_host.pbe (its own memory, START_PC 200). The host rewrites
//    (a) the word the stopped engine is parked on, then runs it again without a restart;
//    (b) the first word, then restarts the engine;
//    (c) the word a running engine is blocked on (WAIT FLAG 0, HIGH becomes LOW).
//  Each time the engine must run the new word, not the copy in its instruction register.
//  Separate memories (D82):
//    (d) a write to engine 0's memory at engine 1's program address leaves engine 1's alone;
//    (e) the pointer carries from the low byte into the next word, from PM_ADDR into PM_ADDR_H
//        (word 127 -> 128) and wraps word 255 -> 0 without changing the engine (readback);
//    (f) a program at START_PC 252: sequential execution wraps 255 -> 0 and a jump target
//        wraps mod 256 (252 + 10 = word 6);
//    (g) engine 0 runs fetch_stream.pbe (START_PC 128) at CLKDIV 0 while the host writes
//        engine 1's memory: no clock lost; then engine 0's own memory: exactly 2 clocks per
//        byte written, the two refetches of BUG-074 (a single refetch, or only the late one,
//        costs 1);
//    (h) after a reset (the memories keep their contents) an engine run without a restart
//        starts at word 0: the reset refetch (pm_wr_q's reset value, BUG-074).
module tb_fetch;
  localparam real CLK_NS = 16.6672;  // 60 MHz
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

  // ---------------- host writes: pm_select and pm_write are in tb_host.svh ----------------

  // (f)'s program (engine 1, START_PC 252): words 252..255, then 0..9
  function automatic logic [15:0] wrap_word(input int i);
    case (i)
      0: return 16'h9610;   // 252 SET OSR, 0x61
      1: return 16'hDB80;   // 253 MOV ISR, OSR
      2: return 16'hB000;   // 254 PUSH
      3: return 16'hD800;   // 255 NOP: sequential execution goes on to word 0
      4: return 16'h9620;   //   0 SET OSR, 0x62
      5: return 16'hDB80;   //   1 MOV ISR, OSR
      6: return 16'hB000;   //   2 PUSH
      7: return 16'h60A0;   //   3 JMP 10: word (252 + 10) mod 256 = 6
      8: return 16'h9EE0;   //   4 SET OSR, 0xEE (jumped over)
      9: return 16'hB000;   //   5 PUSH (jumped over)
      10: return 16'h9630;  //   6 SET OSR, 0x63
      11: return 16'hDB80;  //   7 MOV ISR, OSR
      12: return 16'hB000;  //   8 PUSH
      default: return 16'h60D0;  // 9 JMP 13: word (252 + 13) mod 256 = 9, itself
    endcase
  endfunction

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
    expect_bytes(what, a, 8'h33, 8'h5A, n);
  endtask

  task automatic expect_bytes(input string what, input logic [7:0] w0, w1, w2, input int n);
    logic [7:0] want[3];
    string s;
    want[0] = w0; want[1] = w1; want[2] = w2;
    rx_take;
    s = "";
    foreach (rx_got[i]) s = {s, $sformatf(" %02x", rx_got[i])};
    check(rx_got.size() == n, $sformatf("%s: %0d bytes (%s ), expected %0d", what, rx_got.size(), s, n));
    for (int i = 0; i < n && i < rx_got.size(); i++)
      check(rx_got[i] == want[i], $sformatf("%s: byte %0d is %02x, expected %02x", what, i,
                                            rx_got[i], want[i]));
    $display("  %s:%s", what, s);
  endtask

  // ---------------- separate memories (D82) ----------------
  // (g): engine 0's pin 0 edges while it runs fetch_stream.pbe. Gap i (clocks from edge i-1 to
  // edge i, edge 0 the first TOG of a pass) is 3 at the start of each pass of 62, else 1;
  // returns the clocks added to it, and how many gaps grew.
  task automatic stream_extra(output int extra, output int grown, output int bad);
    int g, want;
    extra = 0; grown = 0; bad = 0;
    for (int i = 1; i < edges.size(); i++) begin
      g = edges[i] - edges[i-1];
      want = (i % 62 == 0) ? 3 : 1;
      if (g != want) begin
        extra += g - want;
        grown++;
        if (g - want != 2) bad++;
      end
    end
  endtask

  // restart and run engine 0; its first word (DRV0) makes an edge only if pin 0 was high, and
  // that edge is not one of the TOGs
  bit stream_high;
  task automatic stream_start;
    stream_high = uio_out[0];
    edges.delete();
    reg_write(7'h00, 8'h11);
  endtask
  task automatic stream_stop;
    reg_write(7'h00, 8'h00);
    if (stream_high) void'(edges.pop_front());
  endtask

  task automatic separate_memories;
    logic [7:0] f, h;
    int extra, grown, bad, nw;

    // (d) engine 0's word 200 is engine 1's first word's address; engine 1 must not see it
    reg_write(7'h00, 8'h00);
    pm_write(0, 200, 16'h9770);   // SET OSR, 0x77 in engine 0's memory
    reg_write(7'h00, 8'h22);      // restart and run engine 1: SET OSR, 0x44 (from (b))
    expect_bytes("(d) engine 0's word 200 written, engine 1 restarted", 8'h44, 8'h33, 8'h5A, 3);

    // (e) pointer carries and readback
    reg_write(7'h00, 8'h00);
    pm_select(0, 127);
    reg_read(7'h06, f); reg_read(7'h0F, h);
    check(f == 8'hFE && h == 8'h00, $sformatf("(e) pointer at engine 0 word 127: %02x %02x, expected fe 00", h, f));
    pm_write(0, 127, 16'h0000);   // its high, then low byte: the pointer moves to word 128
    reg_read(7'h06, f); reg_read(7'h0F, h);
    check(f == 8'h00 && h == 8'h01, $sformatf("(e) after word 127: %02x %02x, expected 01 00", h, f));

    // (f) engine 1, START_PC 252: words 252..255 then 0..9 of its memory, written in one burst
    // from word 252 (the pointer wraps 255 -> 0 and stays on engine 1)
    pm_select(1, 252);
    cs(0);
    spi_byte({1'b1, 7'h07}, f);
    for (int i = 0; i < 14; i++) begin
      spi_byte(wrap_word(i) >> 8, f);
      spi_byte(wrap_word(i) & 8'hFF, f);
    end
    cs(1);
    reg_read(7'h06, f); reg_read(7'h0F, h);
    check(f == 8'd20 && h == 8'h02, $sformatf("(e) after the burst to 252..9: %02x %02x, expected 02 14", h, f));
    reg_write(7'h25, 8'd252);
    reg_write(7'h00, 8'h22);
    expect_bytes("(f) START_PC 252, 255 -> 0, jump to 252 + 10", 8'h61, 8'h62, 8'h63, 3);

    // (g) engine 0 streams at CLKDIV 0 from START_PC 128; first the host writes engine 1
    reg_write(7'h00, 8'h00);
    reg_write(7'h10, 8'h00);
    reg_write(7'h11, 8'h00);
    reg_write(7'h15, 8'd128);
    nw = 6;
    stream_start;
    for (int i = 0; i < nw; i++) begin
      repeat (37 * i) @(posedge clk);  // a different phase of the pass each time
      pm_write(1, 128 + i, 16'h0000);  // engine 1's memory: not engine 0's program
    end
    repeat (100) @(posedge clk);
    stream_stop;
    stream_extra(extra, grown, bad);
    check(edges.size() > 1000 && extra == 0,
          $sformatf("(g) %0d writes to engine 1's memory: %0d edges, %0d clocks added to engine 0, expected 0",
                    nw, edges.size(), extra));
    $display("  (g) %0d writes to engine 1's memory while engine 0 runs: %0d edges, %0d clocks lost", nw,
             edges.size(), extra);

    stream_start;
    for (int i = 0; i < nw; i++) begin
      repeat (37 * i) @(posedge clk);
      pm_write(0, 250, 16'h0000);      // engine 0's memory, a word its program does not use
    end
    repeat (100) @(posedge clk);
    stream_stop;
    stream_extra(extra, grown, bad);
    // each word is two PM_DATA writes (its high and low byte), 128 clocks apart
    check(grown == 2 * nw && bad == 0 && extra == 4 * nw,
          $sformatf("(g) %0d byte writes to engine 0's own memory: %0d gaps grew, by %0d clocks in all, %0d not by 2; expected %0d gaps, 2 clocks each",
                    2 * nw, grown, extra, bad, 2 * nw));
    $display("  (g) %0d byte writes to engine 0's own memory: %0d gaps grew by %0d clocks in all (2 each)",
             2 * nw, grown, extra);

    // (h) reset, then run engine 1 without a restart: pc is 0 after reset and START_PC is
    // reset too, so it must run word 0 (SET OSR, 0x62) first, and jump to 0 + 10 (word 10,
    // the 0000 words of its memory, which only drive engine 1's pins, not owned by it), so
    // set START_PC 252 again first: then 0x62 and 0x63 come out.
    rst_n = 0;
    repeat (3) @(posedge clk);
    @(negedge clk) rst_n = 1;
    repeat (5) @(posedge clk);
    reg_write(7'h25, 8'd252);
    reg_write(7'h00, 8'h02);       // run engine 1, no restart
    expect_bytes("(h) after reset, run without a restart: word 0 first", 8'h62, 8'h63, 8'h00, 2);
  endtask

  initial begin
    logic [7:0] f;
    $display("Test 12: instruction fetch: timing at CLKDIV 0, 1, 3 and host writes to the program memory");
    repeat (5) @(posedge clk);
    @(negedge clk) rst_n = 1;  // released between edges, not at one (BUG-102)
    repeat (5) @(posedge clk);
    load_program("fetch_image.hex");

    timing(0);
    timing(1);
    timing(3);

    reg_write(7'h00, 8'h00);
    reg_write(7'h25, 8'd200);     // engine 1 runs fetch_host.pbe, at word 200 of its memory
    reg_write(7'h00, 8'h22);      // restart and run engine 1
    expect_rx("first run", 8'h11, 1);

    // (a) parked on PULL (word 3), stopped, word 3 becomes SET OSR, 0x33; run, no restart
    reg_write(7'h00, 8'h00);
    repeat (20) @(posedge clk);
    pm_write(1, 200 + 3, 16'h9330);
    repeat (20) @(posedge clk);
    reg_write(7'h00, 8'h02);
    expect_rx("(a) stopped on a word the host rewrote, then run", 8'h33, 1);

    // (c) running, blocked on WAIT FLAG 0, HIGH (word 6); the host writes the low byte only
    pm_select(1, 200 + 6);
    reg_write(7'h06, 8'(((200 + 6) % 128) * 2 + 1));  // the low byte
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
    pm_write(1, 200 + 0, 16'h9440);
    reg_write(7'h00, 8'h22);
    expect_rx("(b) first word rewritten, then restart", 8'h44, 3);

    separate_memories;

    if (errors == 0) begin
      $display("PASS");
      $finish;
    end else $fatal(1, "FAILED with %0d error(s)", errors);
  end

  initial begin
    #20ms;
    $fatal(1, "time limit");
  end
endmodule
