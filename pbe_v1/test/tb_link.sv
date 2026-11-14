`timescale 1ns / 1ps
// The engine-to-engine link (D102), through the chip's pins and host port.
//
// Both engines run link_echo.pbe (PULL, PUSH: TX FIFO -> RX FIFO). With LINK[0] on, engine 0's
// RX FIFO drains into engine 1's TX FIFO; with LINK[1], engine 1's into engine 0's.
//   a. reset: LINK reads "off, path empty"; with the link off every FIFO acts as before.
//   b. a stream of 200 bytes host -> E0 -> E1 -> host (and the mirror, E1 -> E0): in order,
//      none lost or doubled.
//   c. backpressure, both directions: the consumer stopped, the producer's RX FIFO and the
//      consumer's TX FIFO fill (LINK_FILL 32), the producer's PUSH blocks (RX overflow status
//      and IRQ, as a full RX FIFO always did), its TX FIFO fills behind it; then the consumer
//      runs and every byte comes out in order.
//   d. simultaneous host access: the host pushes the consumer's TX FIFO in the clock a link
//      byte would move (the monitor below counts those clocks): the host wins, the link byte
//      moves a clock later, each source keeps its order. A host read of a linked RX FIFO's data
//      register does not pop.
//   e. the link switched off mid-stream (and a ring with both links on cut open): bytes stay
//      where they are, the host reads the rest from the producer's RX FIFO; nothing lost or
//      doubled.
//   f. restart, flush, LINK flush and reset with the link on.
//   g. a host write to every unused second-page address changes no register (COVERAGE.md).
module tb_link;
  localparam real CLK_NS = 16.6672;  // 60 MHz
  localparam int HOST_HALF = 3;

  logic clk = 0, rst_n = 0;
  always #(CLK_NS / 2) clk = ~clk;

  logic [7:0] ui_in = 8'b0000_0010;
  wire  [7:0] uo_out, uio_out, uio_oe;

  tt_um_ayushyadavnvs_pbe dut (
      .ui_in, .uo_out, .uio_in(8'h00), .uio_out, .uio_oe, .ena(1'b1), .clk, .rst_n
  );

  `include "tb_host.svh"

  // clocks in which the host pushed a TX FIFO while that FIFO's link had a byte ready to move
  int collide = 0;
  always @(posedge clk)
    for (int e = 0; e < 2; e++)
      if (dut.host_txw[1-e] && dut.link_en[e] && !dut.rx_empty[e] && !dut.tx_full[1-e]) collide++;

  function automatic logic [6:0] link_a(input int e); return e ? 7'h27 : 7'h17; endfunction
  function automatic logic [6:0] fill_a(input int e); return e ? 7'h4D : 7'h3D; endfunction
  function automatic logic [6:0] data_a(input int e); return e ? 7'h26 : 7'h16; endfunction

  task automatic rd(input logic [6:0] a, output logic [7:0] d);
    reg_read(a, d);
  endtask

  task automatic chip_reset();
    repeat (5) @(posedge clk);
    rst_n = 0;
    repeat (5) @(posedge clk);
    @(negedge clk) rst_n = 1;
    repeat (5) @(posedge clk);
  endtask

  task automatic setup();
    sent.delete(); got.delete(); ga.delete(); gb.delete(); a_q.delete(); b_q.delete();
    chip_reset();
    load_program("link_image.hex");
    reg_write(7'h00, 8'hF0);  // stopped, restarted, flushed
  endtask

  task automatic wait_clocks(input int n);
    repeat (n) @(posedge clk);
  endtask

  // Byte queues (Icarus 12 takes no queue arguments): `got` what came out, `sent` what went in;
  // ga/gb and a_q/b_q split them by source.
  logic [7:0] sent[$], got[$], ga[$], gb[$], a_q[$], b_q[$];

  // read n bytes from engine e's RX FIFO into `got` (the link must be off for e)
  task automatic drain(input int e, input int n);
    logic [7:0] d;
    for (int i = 0; i < n; i++) begin
      fifo_recv(e, d);
      got.push_back(d);
    end
  endtask

  function automatic string qs_got();
    string s = "";
    foreach (got[i]) s = {s, $sformatf("%02x ", got[i])};
    return s;
  endfunction

  // which: 0 got vs sent, 1 ga vs a_q, 2 gb vs b_q
  task automatic same_q(input int which, input string what);
    bit ok;
    string s1 = "", s2 = "";
    case (which)
      0: begin ok = got.size() == sent.size(); if (ok) foreach (got[i]) if (got[i] !== sent[i]) ok = 0;
               foreach (got[i]) s1 = {s1, $sformatf("%02x ", got[i])}; foreach (sent[i]) s2 = {s2, $sformatf("%02x ", sent[i])}; end
      1: begin ok = ga.size() == a_q.size(); if (ok) foreach (ga[i]) if (ga[i] !== a_q[i]) ok = 0;
               foreach (ga[i]) s1 = {s1, $sformatf("%02x ", ga[i])}; foreach (a_q[i]) s2 = {s2, $sformatf("%02x ", a_q[i])}; end
      default: begin ok = gb.size() == b_q.size(); if (ok) foreach (gb[i]) if (gb[i] !== b_q[i]) ok = 0;
               foreach (gb[i]) s1 = {s1, $sformatf("%02x ", gb[i])}; foreach (b_q[i]) s2 = {s2, $sformatf("%02x ", b_q[i])}; end
    endcase
    check(ok, $sformatf("%s: got %s, expected %s", what, s1, s2));
  endtask

  // ---------------- a ----------------
  task automatic t_reset();
    logic [7:0] d;
    setup();
    for (int e = 0; e < 2; e++) begin
      rd(link_a(e), d);
      check(d == 8'h02, $sformatf("a: LINK%0d after reset %02x, expected 02", e, d));
      rd(fill_a(e), d);
      check(d == 8'h00, $sformatf("a: LINK_FILL%0d after reset %02x", e, d));
    end
    // link off: engine 0 echoes into its own RX FIFO, engine 1's FIFOs stay empty
    reg_write(7'h00, 8'h01);
    for (int i = 0; i < 5; i++) fifo_send(0, 8'(8'h30 + i));
    wait_clocks(50);
    rd(7'h0A, d); check(d == 5, $sformatf("a: link off, E0 RX_COUNT %0d", d));
    rd(7'h0D, d); check(d == 0, $sformatf("a: link off, E1 TX_COUNT %0d", d));
    rd(fill_a(0), d); check(d == 5, $sformatf("a: LINK_FILL0 %0d (counts with the link off too)", d));
    $display("a: reset values; link off leaves every FIFO as before");
  endtask

  // ---------------- b ----------------
  task automatic t_stream(input int p);  // p: producer engine
    int c = 1 - p;
    logic [7:0] d;
    setup();
    reg_write(link_a(p), 8'h01);
    reg_write(7'h00, 8'h03);
    fork
      for (int i = 0; i < 200; i++) begin
        d = 8'(i * 7 + p);
        sent.push_back(d);
        fifo_send(p, d);
      end
      drain(c, 200);
    join
    same_q(0, $sformatf("b: stream E%0d -> E%0d", p, c));
    rd(fill_a(p), d); check(d == 0, $sformatf("b: fill %0d after the stream", d));
    rd(link_a(p), d); check(d == 8'h03, $sformatf("b: LINK%0d %02x, expected on and empty", p, d));
    $display("b: 200 bytes E%0d -> E%0d through the link, in order", p, c);
  endtask

  // ---------------- c ----------------
  task automatic t_backpressure(input int p);
    int c = 1 - p;
    logic [7:0] d, st;
    setup();
    reg_write(link_a(p), 8'h01);
    reg_write(7'h00, 8'(1 << p));  // the producer runs, the consumer is stopped
    // 32 bytes in the path, 1 held by the blocked engine, 16 in its TX FIFO
    for (int i = 0; i < 49; i++) begin
      d = 8'(8'hC0 ^ (i * 13));
      sent.push_back(d);
      reg_write(data_a(p), d);   // no full check: the counts below show nothing was dropped
      wait_clocks(4);
    end
    wait_clocks(50);
    rd(fill_a(p), d); check(d == 32, $sformatf("c%0d: LINK_FILL %0d, expected 32", p, d));
    rd(link_a(p), d); check(d == 8'h0D, $sformatf("c%0d: LINK %02x, expected 0d (on, RX full, TX full)", p, d));
    rd(p ? 7'h0B : 7'h0A, d); check(d == 16, $sformatf("c%0d: producer RX_COUNT %0d", p, d));
    rd(c ? 7'h0D : 7'h0C, d); check(d == 16, $sformatf("c%0d: consumer TX_COUNT %0d", p, d));
    rd(p ? 7'h0D : 7'h0C, d); check(d == 16, $sformatf("c%0d: producer TX_COUNT %0d (blocked)", p, d));
    rd(p ? 7'h2F : 7'h1F, st); check(st[3], $sformatf("c%0d: producer status %02x: RX overflow expected", p, st));
    rd(7'h02, d); check(d[p], $sformatf("c%0d: IRQ %02x: producer's overflow IRQ expected", p, d));
    reg_write(7'h02, 8'h03);
    reg_write(p ? 7'h2F : 7'h1F, 8'h04);
    reg_write(7'h00, 8'h03);       // the consumer runs: everything drains into its RX FIFO
    drain(c, 49);
    same_q(0, $sformatf("c%0d: after backpressure", p));
    rd(fill_a(p), d); check(d == 0, $sformatf("c%0d: fill %0d at the end", p, d));
    $display("c: E%0d -> E%0d: path full at 32, PUSH blocked (overflow status + IRQ), 49 bytes out in order", p, c);
  endtask

  // ---------------- d ----------------
  task automatic t_host_access();
    logic [7:0] d, n0;
    int rounds = 0;
    setup();
    // Engine 0 runs link_burst.pbe (START_PC 16): at FLAG 0 it pushes 1..12, one every 3 clocks,
    // and the link moves each a clock later. The host writes 0x80 + k to engine 1's TX FIFO k
    // clocks after setting the flag, k = 0, 1, 2 ...; some k land on a move.
    reg_write(7'h15, 8'd16);
    reg_write(link_a(0), 8'h01);
    for (int k = 0; k < 200 && collide == 0; k++) begin
      int c0;
      reg_write(7'h00, 8'h30);       // stop and restart both, empty the path
      reg_write(link_a(0), 8'h03);
      ga.delete(); gb.delete(); got.delete();
      reg_write(7'h00, 8'h01);
      c0 = collide;
      reg_write(7'h08, 8'h01);       // FLAG 0
      wait_clocks(k);
      reg_write(7'h26, 8'h80 | 8'(k));
      wait_clocks(100);
      rd(fill_a(0), d);
      check(d == 13, $sformatf("d: k %0d: fill %0d, expected 13", k, d));
      reg_write(7'h00, 8'h02);       // E1 (echo) copies its TX FIFO into its RX FIFO
      drain(1, 13);
      foreach (got[i]) begin d = got[i]; if (d[7]) gb.push_back(d); else ga.push_back(d); end
      a_q.delete(); b_q.delete();
      for (int i = 1; i <= 12; i++) a_q.push_back(8'(i));
      b_q.push_back(8'h80 | 8'(k));
      same_q(1, $sformatf("d: k %0d, the link's bytes", k));
      same_q(2, $sformatf("d: k %0d, the host's byte", k));
      rounds++;
      if (collide != c0) $display("d: k %0d: the host's byte and a link byte in one clock: %s", k, qs_got());
    end
    check(collide > 0, "d: no clock with a host push and a link move together was reached");
    // a host read of a linked RX FIFO's data register does not pop
    setup();
    reg_write(7'h00, 8'h01);
    fifo_send(0, 8'hA3);
    wait_clocks(100);
    reg_write(7'h00, 8'h00);
    for (int i = 0; i < 16; i++) reg_write(7'h26, 8'hEE);  // E1's TX FIFO full: nothing can move
    reg_write(link_a(0), 8'h01);
    rd(7'h16, d);
    rd(7'h16, d);
    rd(7'h0A, n0);
    check(n0 == 1 && d == 8'hA3, $sformatf("d: host reads with the link on: RX_COUNT %0d, data %02x (no pop)", n0, d));
    reg_write(link_a(0), 8'h00);
    rd(7'h16, d);
    rd(7'h0A, n0);
    check(n0 == 0 && d == 8'hA3, $sformatf("d: host read with the link off: RX_COUNT %0d, data %02x (pop)", n0, d));
    $display("d: %0d clocks with a host push and a link move together (host first, link a clock later), %0d rounds, order kept; host reads with the link on do not pop", collide, rounds);
  endtask

  // ---------------- e ----------------
  task automatic t_toggle();
    logic [7:0] d, n;
    int k;
    setup();
    reg_write(7'h20, 8'd20);       // E1 slow: bytes queue in the path
    reg_write(link_a(0), 8'h01);
    reg_write(7'h00, 8'h03);
    for (int i = 0; i < 30; i++) begin
      d = 8'(i + 1);
      sent.push_back(d);
      fifo_send(0, d);
      if (i == 20) reg_write(link_a(0), 8'h00);  // off mid-stream
    end
    wait_clocks(3000);
    // E1's side: what crossed before the switch; E0's RX FIFO: the rest
    // E1 is slow and its RX FIFO holds 16: keep draining until it has nothing more
    repeat (6) begin
      rd(7'h0B, n);
      drain(1, n);
      wait_clocks(2500);
    end
    rd(7'h0A, n);
    k = n;
    drain(0, k);
    same_q(0, "e: link off mid-stream: E1's bytes then E0's");
    check(k > 0, "e: nothing was left in E0's RX FIFO (the switch came too late to test)");
    // a ring: both links on, 5 bytes circulate; then LINK[1] off: they collect in E1's RX FIFO
    setup();
    reg_write(link_a(0), 8'h01);
    reg_write(7'h00, 8'h03);
    sent.delete(); got.delete();
    for (int i = 0; i < 5; i++) begin sent.push_back(8'(8'h50 + i)); fifo_send(0, 8'(8'h50 + i)); end
    wait_clocks(500);              // all 5 in E1's RX FIFO; now close the ring
    reg_write(link_a(1), 8'h01);
    wait_clocks(2000);
    rd(fill_a(0), n); rd(fill_a(1), d);
    check(n + d <= 5, $sformatf("e: ring: %0d + %0d bytes in the paths", n, d));
    reg_write(link_a(1), 8'h00);
    wait_clocks(500);
    rd(7'h0B, n);
    check(n == 5, $sformatf("e: ring cut: E1 RX_COUNT %0d, expected 5", n));
    drain(1, 5);
    k = 0;
    while (k < 5 && got[0] != sent[k]) k++;
    for (int i = 0; i < 5; i++) if (k < 5) check(got[i] == sent[(k + i) % 5], $sformatf("e: ring order %s", qs_got()));
    check(k < 5, $sformatf("e: ring bytes %s", qs_got()));
    $display("e: link switched off mid-stream, the rest read from E0's RX FIFO; a ring of 5 bytes cut open intact");
  endtask

  // ---------------- f ----------------
  task automatic t_restart_flush();
    logic [7:0] d;
    setup();
    reg_write(link_a(0), 8'h01);
    reg_write(7'h00, 8'h01);
    for (int i = 0; i < 20; i++) begin d = 8'(8'h90 + i); sent.push_back(d); fifo_send(0, d); end
    wait_clocks(200);
    rd(fill_a(0), d); check(d == 20, $sformatf("f: fill %0d, expected 20", d));
    reg_write(7'h00, 8'h31);       // restart both engines (E0 left running): FIFOs and link stay
    rd(fill_a(0), d); check(d == 20, $sformatf("f: fill %0d after restart", d));
    rd(link_a(0), d); check(d[0], "f: restart switched the link off");
    reg_write(7'h00, 8'h03);
    drain(1, 20);
    same_q(0, "f: after an engine restart");
    // CTRL flush of E0: its RX FIFO (the path's first half) empties, E1's TX FIFO keeps its 16
    reg_write(7'h00, 8'h01);
    for (int i = 0; i < 20; i++) fifo_send(0, 8'(i));
    wait_clocks(200);
    reg_write(7'h00, 8'h41);
    rd(fill_a(0), d); check(d == 16, $sformatf("f: fill %0d after CTRL flush E0, expected 16", d));
    for (int i = 0; i < 3; i++) fifo_send(0, 8'(i));
    wait_clocks(100);
    rd(fill_a(0), d); check(d == 19, $sformatf("f: fill %0d, expected 19", d));
  endtask

  task automatic t_flush2();
    logic [7:0] d;
    setup();
    reg_write(link_a(0), 8'h01);
    reg_write(7'h00, 8'h01);
    for (int i = 0; i < 20; i++) fifo_send(0, 8'(i));
    for (int i = 0; i < 3; i++) fifo_send(0, 8'hF0);   // 23: 16 in E1's TX FIFO, 7 in E0's RX FIFO
    wait_clocks(200);
    rd(fill_a(0), d); check(d == 23, $sformatf("f: fill %0d, expected 23", d));
    reg_write(link_a(0), 8'h03);   // LINK flush, link stays on
    rd(fill_a(0), d); check(d == 0, $sformatf("f: fill %0d after LINK flush", d));
    rd(link_a(0), d); check(d == 8'h03, $sformatf("f: LINK %02x after flush, expected 03", d));
    for (int i = 0; i < 4; i++) fifo_send(0, 8'(8'h40 + i));
    wait_clocks(100);
    rd(fill_a(0), d); check(d == 4, $sformatf("f: fill %0d after flush and 4 more", d));
    reg_write(7'h0E, 8'h02);       // TX_FLUSH E1: the path's second half
    rd(fill_a(0), d); check(d == 0, $sformatf("f: fill %0d after TX_FLUSH E1", d));
    reg_write(7'h00, 8'h81);       // CTRL flush E1 with the link on: nothing else changes
    rd(link_a(0), d); check(d == 8'h03, $sformatf("f: LINK %02x after CTRL flush E1", d));
    chip_reset();
    rd(link_a(0), d); check(d == 8'h02, $sformatf("f: LINK %02x after reset, expected 02 (off)", d));
    $display("f: restart keeps the link and its bytes; CTRL flush, TX_FLUSH and LINK flush empty their FIFOs; reset turns it off");
  endtask

  // ---------------- g ----------------
  // Every readable register that does not change by itself (engines stopped, pins static).
  logic [7:0] snap[128];
  function automatic bit skip_a(input int a);  // PINS and the FIFO data registers (reads pop)
    return a == 7'h05 || a == 7'h16 || a == 7'h26;
  endfunction
  task automatic snapshot();
    logic [7:0] d;
    for (int a = 0; a < 128; a++)
      if (!skip_a(a)) begin reg_read(7'(a), d); snap[a] = d; end
  endtask
  task automatic t_unused_page2();
    logic [7:0] d;
    int bad = 0;
    setup();
    // give the second pages and their neighbours non-reset values first
    // (not LINE and LINE2: a line coder runs even while its engine is stopped)
    for (int a = 7'h30; a <= 7'h4C; a++) if (((a & 15) >= 1 && (a & 15) <= 3) || ((a & 15) >= 8 && (a & 15) <= 12)) reg_write(7'(a), 8'(a * 3 + 1));
    reg_write(link_a(0), 8'h01);   // and the link on, so its state is in the snapshot too
    snapshot();
    for (int p = 0; p < 2; p++)
      for (int r = 5; r < 16; r++)
        if (r <= 7 || r >= 13) reg_write(7'(8'h30 + 16 * p + r), 8'hFF);
    for (int a = 0; a < 128; a++)
      if (!skip_a(a)) begin
        reg_read(7'(a), d);
        if (d !== snap[a]) begin
          bad++;
          $display("  g: register %02x changed %02x -> %02x", a, snap[a], d);
        end
      end
    check(bad == 0, "g: a write to an unused second-page address changed a register");
    $display("g: writes of ff to second-page +5..+7 and +D..+F of both engines changed nothing");
  endtask

  initial begin
    t_reset();
    t_stream(0);
    t_stream(1);
    t_backpressure(0);
    t_backpressure(1);
    t_host_access();
    t_toggle();
    t_restart_flush();
    t_flush2();
    t_unused_page2();
    if (errors == 0) begin
      $display("PASS: engine-to-engine link");
      $finish;
    end else $fatal(1, "FAILED with %0d error(s)", errors);
  end
  initial begin
    #200ms;
    $fatal(1, "FAILED: timeout");
  end
endmodule
