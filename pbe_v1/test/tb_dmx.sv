`timescale 1ns / 1ps
// Blind generality benchmark 1: DMX512 transmitter (dmx512_tx.pbe) against a DMX512 receiver
// written from ANSI E1.11 (break >= 88 us, mark after break >= 8 us, slots of 1 start bit, 8
// data bits LSB first and 2 stop bits at 250 kbaud, sampled mid-bit from the start edge).
//   engine 0: dmx512_tx.pbe at word 0, TX = pin 0.
// Packets: 24 slots; a full packet (start code + 512 slots); a packet fed slowly (marks between
// slots); two packets back to back. The receiver checks every bit time, both stop bits, the
// break and the mark after break, and rebuilds the slots.
module tb_dmx;
  localparam real CLK_NS = 16.6672;  // 60 MHz
  localparam int HOST_HALF = 4;

  logic clk = 0, rst_n = 0;
  always #(CLK_NS / 2) clk = ~clk;
  logic [7:0] ui_in = 8'b0000_0010;
  wire  [7:0] uo_out, uio_out, uio_oe;
  wire  line = !uio_oe[0] | uio_out[0];   // pulled up while released
  wire  [7:0] bus = {7'b0, line};
  tt_um_ayushyadavnvs_pbe dut (.ui_in, .uo_out, .uio_in(bus), .uio_out, .uio_oe, .ena(1'b1), .clk, .rst_n);
  `include "tb_host.svh"

  // ---------------- DMX512 receiver ----------------
  localparam real BIT = 4000.0;
  logic [7:0] slots[$];        // the slots of the packet being received
  int n_packets = 0, n_frame_err = 0;
  real brk_min = 1e9, mab_min = 1e9, bit_err_max = 0;
  int last_count = 0;          // slots in the last complete packet
  logic [7:0] last[$];
  realtime t_fall = 0, t_edge = 0;
  bit in_slot = 0;
  // bit widths: every edge inside a slot must be a whole number of bit times after the start edge
  realtime t_start = 0;
  always @(line) begin
    if (in_slot) begin
      real k, e;
      k = ($realtime - t_start) / BIT;
      e = (k - $floor(k + 0.5)) * BIT;
      if (e < 0) e = -e;
      if (e > bit_err_max) bit_err_max = e;
    end
  end
  initial begin
    logic [7:0] d;
    realtime t0, low;
    forever begin
      @(negedge line);
      t0 = $realtime;
      // a start bit or a break: sample the 8 data bits and the stop bits
      t_start = t0;
      in_slot = 1;
      #(BIT * 1.5);
      for (int i = 0; i < 8; i++) begin
        d[i] = line;
        #(BIT);
      end
      if (!line && d == 8'h00) begin
        // no stop bit and all zeros: a break. Measure it and the mark after it.
        in_slot = 0;
        @(posedge line);
        low = $realtime - t0;
        if (low < brk_min) brk_min = low;
        if (low < 88000.0) n_frame_err++;
        if (n_packets > 0 || slots.size() > 0) begin
          last = slots;
          last_count = slots.size();
        end
        slots = {};
        n_packets++;
        t0 = $realtime;
        @(negedge line);
        if ($realtime - t0 < mab_min) mab_min = $realtime - t0;
        // this falling edge is the start code's start bit: handle it as a slot
        t0 = $realtime;
        t_start = t0;
        in_slot = 1;
        #(BIT * 1.5);
        for (int i = 0; i < 8; i++) begin
          d[i] = line;
          #(BIT);
        end
      end
      if (!line) n_frame_err++;   // stop bit 1
      #(BIT);
      if (!line) n_frame_err++;   // stop bit 2
      in_slot = 0;
      slots.push_back(d);
    end
  end

  int pass = 0;
  task automatic result(input string name, input bit ok);
    check(ok, name);
    if (ok) pass++;
    $display("  DMX  %-60s %s", name, ok ? "PASS" : "FAIL");
  endtask

  logic [7:0] pkt[$];
  // send pkt: FLAG0, then the slots in bursts (gap_clocks > 0: a pause after every slot)
  task automatic send(input int gap_clocks);
    logic [7:0] x;
    wait_tx_empty(0);
    flag_set(0, 0);
    if (gap_clocks == 0) begin
      cs(0);
      spi_byte({1'b1, 7'h16}, x);
      foreach (pkt[i]) begin
        while (uo_out[6]) @(negedge clk);
        spi_byte(pkt[i], x);
      end
      cs(1);
    end else foreach (pkt[i]) begin
      fifo_send(0, pkt[i]);
      repeat (gap_clocks) @(posedge clk);
    end
  endtask
  task automatic mk(input int n);   // start code 0 and n data slots
    pkt = {};
    pkt.push_back(8'h00);
    for (int i = 0; i < n; i++) pkt.push_back(8'($urandom));
  endtask
  // the slots received so far in the open packet must equal pkt
  task automatic expect_open(input string name);
    bit ok;
    logic [7:0] a, b;
    wait_tx_empty(0);
    #(60 * BIT);
    ok = slots.size() == pkt.size();
    for (int i = 0; i < pkt.size() && ok; i++) begin
      a = slots[i];
      b = pkt[i];
      ok = a === b;
    end
    if (!ok) $display("    %0d slots received, %0d sent", slots.size(), pkt.size());
    result(name, ok);
  endtask

  initial begin
    repeat (5) @(posedge clk);
    @(negedge clk) rst_n = 1;
    repeat (5) @(posedge clk);
    load_program("dmx_image.hex");
    reg_write(7'h00, 8'b0100_0000);
    reg_write(7'h10, 8'd119);         // 2 us tick
    reg_write(7'h11, 8'd0);
    reg_write(7'h12, 8'd0);
    reg_write(7'h14, 8'h00);
    reg_write(7'h15, 8'd0);
    reg_write(7'h1B, 8'h00);
    reg_write(7'h1C, 8'h00);
    reg_write(7'h1D, 8'h00);
    reg_write(7'h1E, 8'h40);
    reg_write(7'h00, 8'b0001_0001);
    repeat (2000) @(posedge clk);

    mk(24);
    send(0);
    expect_open("24 slots");
    mk(512);
    send(0);
    expect_open("a full packet: start code + 512 slots");
    mk(6);
    send(9000);
    expect_open("6 slots fed slowly (150 us of mark between slots)");
    mk(3);
    send(0);
    expect_open("a short packet right after");

    $display("  DMX  %0d packets; break min %0.1f us (>= 88), mark after break min %0.1f us (>= 8), worst edge %0.1f ns off the 4 us grid",
             n_packets, brk_min / 1000, mab_min / 1000, bit_err_max);
    check(n_packets == 4, "the receiver did not see 4 breaks");
    check(n_frame_err == 0, $sformatf("%0d framing errors (stop bits, short break)", n_frame_err));
    check(brk_min >= 92000.0, "break shorter than a transmitter's 92 us");
    check(mab_min >= 12000.0, "mark after break shorter than a transmitter's 12 us");
    check(bit_err_max < 80.0, "a bit edge more than 2 % off the 4 us grid");
    if (errors == 0 && pass == 4) begin
      $display("PASS: DMX512");
      $finish;
    end else $fatal(1, "FAILED with %0d error(s)", errors);
  end
  initial begin
    #200ms;
    $fatal(1, "FAILED: timeout");
  end
endmodule
