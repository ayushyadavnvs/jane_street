`timescale 1ns / 1ps
// PAGE (D83), end to end through the chip's pins and host port.
//  (a) page_test.pbe (engine 0): jumps across all four 64-word pages forward and back, a loop
//      inside page 3 (no PAGE), JNE across pages, and a timeout from page 3 to the vector in
//      page 0: RX 10 12 11 13 14 15.
//  (b) page_restart.pbe (engine 1): a PAGE survives a stop (run = 0) during its delay: 0xB2;
//  (c) and a restart clears it: after the restart a jump to page 0 stays in page 0: 0xA1.
//  (d) page_loop.pbe (engine 0, CLKDIV 0): pins 0 and 1 toggle in turn from pages 0 and 3
//      while the host writes engine 0's memory; a write between a PAGE and its jump must not
//      lose the PAGE (the toggles must alternate).
module tb_page;
  localparam real CLK_NS = 20.8333;  // 48 MHz
  localparam int HOST_HALF = 8;

  logic clk = 0, rst_n = 0;
  always #(CLK_NS / 2) clk = ~clk;

  logic [7:0] ui_in = 8'b0000_0010;
  wire  [7:0] uo_out, uio_out, uio_oe;

  tt_um_ayushyadavnvs_pbe dut (
      .ui_in, .uo_out, .uio_in(8'h00), .uio_out, .uio_oe, .ena(1'b1), .clk, .rst_n
  );

  `include "tb_host.svh"

  task automatic expect_rx(input int e, input string what, input logic [7:0] w0, w1, w2, w3, w4,
                           w5, input int n);
    logic [7:0] cnt, d, want[6];
    string s;
    want[0] = w0; want[1] = w1; want[2] = w2; want[3] = w3; want[4] = w4; want[5] = w5;
    reg_read(e ? 7'h0B : 7'h0A, cnt);
    s = "";
    for (int i = 0; i < cnt; i++) begin
      reg_read(e ? 7'h26 : 7'h16, d);
      s = {s, $sformatf(" %02x", d)};
      if (i < n) check(d == want[i], $sformatf("%s: byte %0d is %02x, expected %02x", what, i, d, want[i]));
    end
    check(cnt == n, $sformatf("%s: %0d bytes (%s ), expected %0d", what, cnt, s, n));
    $display("  %s:%s", what, s);
  endtask

  // (d): the order of the pin edges
  int seq0 = 0, seq1 = 0, bad_order = 0;
  bit last1 = 1, watch = 0;
  always @(uio_out[0]) if (watch) begin seq0++; if (!last1) bad_order++; last1 = 0; end
  always @(uio_out[1]) if (watch) begin seq1++; if (last1) bad_order++; last1 = 1; end
  // the clock of each toggle, before the host writes: TOG, PAGE and the taken jump with its
  // refetch clock take 1 + 1 + 2 = 4 clocks at CLKDIV 0, into another page as within one
  int cyc = 0, t_edges[$];
  bit timing_on = 0;
  always @(posedge clk) cyc++;
  always @(uio_out[0] or uio_out[1]) if (timing_on) t_edges.push_back(cyc);

  initial begin
    $display("Test 13: PAGE (D83): jumps over a 256-word program, timeout, stop, restart, host writes");
    repeat (5) @(posedge clk);
    @(negedge clk) rst_n = 1;
    repeat (5) @(posedge clk);
    load_program("page_image.hex");

    // (a) engine 0: CLKDIV 0, timeout 20 ticks, TIMEOUT_PC 40, no parity
    reg_write(7'h10, 8'd0);
    reg_write(7'h11, 8'd0);
    reg_write(7'h15, 8'd0);
    reg_write(7'h1C, 8'd20);
    reg_write(7'h1D, 8'd0);
    reg_write(7'h1E, 8'h40 | 8'd40);
    reg_write(7'h00, 8'h11);      // restart and run engine 0
    repeat (400) @(posedge clk);
    expect_rx(0, "(a) pages 0 -> 2 -> 1 -> 3 -> 0 -> 3, timeout to page 0", 8'h10, 8'h12, 8'h11,
              8'h13, 8'h14, 8'h15, 6);

    // (b) engine 1: CLKDIV 255, so PAGE 2 [15] lasts 16 x 256 clocks; stop it in the delay
    reg_write(7'h00, 8'h00);
    reg_write(7'h09, 8'hFF);      // all flags clear
    reg_write(7'h20, 8'd255);
    reg_write(7'h21, 8'd0);
    reg_write(7'h25, 8'd0);
    reg_write(7'h00, 8'h22);      // restart and run engine 1
    repeat (1500) @(posedge clk); // JMP FLAG0 (not taken) and PAGE 2 have run; in its delay
    reg_write(7'h00, 8'h00);      // stop
    repeat (5000) @(posedge clk);
    reg_write(7'h00, 8'h02);      // run again, no restart
    repeat (6000) @(posedge clk);
    expect_rx(1, "(b) PAGE 2, stopped in its delay, run again", 8'hB2, 0, 0, 0, 0, 0, 1);

    // (c) restart in the PAGE's delay, with FLAG 0 set: JMP FLAG0, rgo must stay in page 0
    reg_write(7'h00, 8'h22);
    repeat (1500) @(posedge clk); // in PAGE 2's delay again
    reg_write(7'h08, 8'h10);      // engine 1's FLAG 0 (physical flag 4)
    reg_write(7'h00, 8'h22);      // restart and run engine 1
    repeat (3000) @(posedge clk);
    reg_write(7'h00, 8'h00);
    expect_rx(1, "(c) restart after PAGE 2: the jump stays in page 0", 8'hA1, 0, 0, 0, 0, 0, 1);

    // (d) the alternating toggles while the host writes engine 0's memory (word 250, unused)
    load_program("page_loop_image.hex");
    reg_write(7'h03, 8'h00);
    reg_write(7'h15, 8'd0);
    reg_write(7'h00, 8'h11);
    repeat (20) @(posedge clk);
    timing_on = 1;
    repeat (400) @(posedge clk);
    timing_on = 0;
    begin
      int bad;
      bad = 0;
      for (int i = 1; i < t_edges.size(); i++) if (t_edges[i] - t_edges[i-1] != 4) bad++;
      check(t_edges.size() > 90 && bad == 0,
            $sformatf("(d) %0d toggles, %0d gaps not 4 clocks (TOG, PAGE, JMP + refetch)", t_edges.size(), bad));
      $display("  (d) %0d toggles 4 clocks apart: PAGE 1 clock, the cross-page jump 1 + 1 refetch", t_edges.size());
    end
    watch = 1;
    for (int i = 0; i < 24; i++) begin
      repeat (7 * i) @(posedge clk);  // a different phase of the 8-clock loop each time
      pm_write(0, 250, 16'h0000);
    end
    repeat (50) @(posedge clk);
    watch = 0;
    reg_write(7'h00, 8'h00);
    check(seq0 > 1000 && bad_order == 0 && (seq0 - seq1 <= 1) && (seq1 - seq0 <= 1),
          $sformatf("(d) %0d / %0d toggles of pins 0 / 1, %0d out of order", seq0, seq1, bad_order));
    $display("  (d) 48 byte writes while running: %0d / %0d toggles of pins 0 / 1, %0d out of order",
             seq0, seq1, bad_order);

    if (errors == 0) begin
      $display("PASS");
      $finish;
    end else $fatal(1, "FAILED with %0d error(s)", errors);
  end

  initial begin
    #30ms;
    $fatal(1, "time limit");
  end
endmodule
