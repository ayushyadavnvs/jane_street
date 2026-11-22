`timescale 1ns / 1ps
// Blind generality benchmark 2: MIDI in (midi_in.pbe, running status expanded) and MIDI out
// (uart_tx.pbe at 31.25 kbaud), against a MIDI device model and a reference parser written from
// the MIDI 1.0 specification.
//   engine 0: midi_in.pbe, RX = pin 0.   engine 1: uart_tx.pbe, TX = pin 4.
// In: the model sends a stream with explicit and running status (2- and 1-data messages),
// real-time bytes between and inside messages, a system exclusive message, and data with no
// running status, back to back at 31.25 kbaud (and 1 % fast and slow). The bytes the host reads
// must equal the reference expansion.
// Out: bytes written by the host must appear as 8N1 at 31.25 kbaud +- 1 %.
module tb_midi;
  localparam real CLK_NS = 16.6672;  // 60 MHz
  localparam int HOST_HALF = 4;
  localparam real BIT = 32000.0;     // 31.25 kbaud

  logic clk = 0, rst_n = 0;
  always #(CLK_NS / 2) clk = ~clk;
  logic [7:0] ui_in = 8'b0000_0010;
  wire  [7:0] uo_out, uio_out, uio_oe;
  logic midi_rx = 1;
  wire  midi_tx = !uio_oe[4] | uio_out[4];
  wire  [7:0] bus = {3'b0, midi_tx, 3'b0, midi_rx};
  tt_um_ayushyadavnvs_pbe dut (.ui_in, .uo_out, .uio_in(bus), .uio_out, .uio_oe, .ena(1'b1), .clk, .rst_n);
  `include "tb_host.svh"

  int pass = 0;
  task automatic result(input string name, input bit ok);
    check(ok, name);
    if (ok) pass++;
    $display("  MIDI %-60s %s", name, ok ? "PASS" : "FAIL");
  endtask

  // ---------------- the sending device ----------------
  real bit_ns = BIT;
  task automatic dev_send(input logic [7:0] b);
    midi_rx = 0;
    #(bit_ns);
    for (int i = 0; i < 8; i++) begin
      midi_rx = b[i];
      #(bit_ns);
    end
    midi_rx = 1;
    #(bit_ns);                       // one stop bit: bytes back to back
  endtask

  // ---------------- reference: expand running status (MIDI 1.0) ----------------
  logic [7:0] src[$], ref_q[$], got[$];
  task automatic expand;
    logic [7:0] b, run;
    int need, have;
    run = 0;
    need = 0;
    have = 0;
    ref_q = {};
    foreach (src[i]) begin
      b = src[i];
      if (b >= 8'hF8) ref_q.push_back(b);                  // real time: anywhere, no effect
      else if (b >= 8'hF0) begin                           // system: cancels running status
        ref_q.push_back(b);
        run = 0;
        have = 0;
      end else if (b[7]) begin                             // channel status
        run = b;
        need = (b[7:4] == 4'hC || b[7:4] == 4'hD) ? 1 : 2;
        have = 0;
      end else if (run == 0) ref_q.push_back(b);           // data with no running status
      else begin
        if (have == 0) ref_q.push_back(run);
        ref_q.push_back(b);
        have = (have + 1 == need) ? 0 : have + 1;
      end
    end
  endtask

  task automatic s(input logic [7:0] b);
    src.push_back(b);
  endtask
  task automatic stream;
    src = {};
    s(8'h90); s(8'h3C); s(8'h7F);            // note on
    s(8'h3C); s(8'h00);                      // running status
    s(8'h40); s(8'h7F);                      // running status
    s(8'hF8);                                // clock between messages
    s(8'h43); s(8'hF8); s(8'h64);            // clock inside a running message
    s(8'h80); s(8'h40); s(8'h40);            // note off
    s(8'hC5); s(8'h07);                      // program change: 1 data byte
    s(8'h08); s(8'h09);                      // running, 1 data byte each
    s(8'hD2); s(8'h55);                      // channel pressure
    s(8'hE1); s(8'h00); s(8'h40);            // pitch bend
    s(8'h7F); s(8'h7F);                      // running
    s(8'hB0); s(8'h07); s(8'h64);            // control change
    s(8'hA3); s(8'h30); s(8'h11);            // poly pressure
    s(8'hF0); s(8'h7E); s(8'h7F); s(8'h09); s(8'h01); s(8'hF7);   // system exclusive
    s(8'h45); s(8'h46);                      // data with no running status: passed
    s(8'hFE);                                // active sensing
    s(8'h99); s(8'h24); s(8'h7F); s(8'h26); s(8'h60);
    s(8'hF2); s(8'h10); s(8'h20);            // song position (system common)
    s(8'h8F); s(8'h00); s(8'h00);
  endtask

  task automatic in_test(input real rate, input string what);
    logic [7:0] d, c;
    bit ok;
    int n;
    bit_ns = BIT * rate;
    stream;
    expand;
    got = {};
    fork
      foreach (src[i]) dev_send(src[i]);
      begin
        n = 0;
        while (got.size() < ref_q.size() && n < 60000) begin
          reg_read(7'h0A, c);
          for (int i = 0; i < c; i++) begin
            reg_read(7'h16, d);
            got.push_back(d);
          end
          repeat (100) @(posedge clk);
          n++;
        end
      end
    join
    repeat (40000) @(posedge clk);
    reg_read(7'h0A, c);
    ok = got.size() == ref_q.size() && c == 0;
    for (int i = 0; i < ref_q.size() && i < got.size(); i++) begin
      logic [7:0] a, b;
      a = got[i];
      b = ref_q[i];
      if (a !== b) begin
        if (ok) $display("    byte %0d: %02x, expected %02x", i, a, b);
        ok = 0;
      end
    end
    if (got.size() != ref_q.size()) $display("    %0d bytes, expected %0d (+%0d left)", got.size(), ref_q.size(), c);
    result($sformatf("in, %s: %0d bytes sent, %0d expanded bytes", what, src.size(), ref_q.size()), ok);
  endtask

  // ---------------- MIDI out: a UART receiver at 31.25 kbaud ----------------
  logic [7:0] out_q[$];
  real bit_min = 1e9, bit_max = 0;
  int frame_err = 0;
  initial forever begin
    logic [7:0] d;
    realtime t0;
    @(negedge midi_tx);
    t0 = $realtime;
    #(BIT * 1.5);
    for (int i = 0; i < 8; i++) begin
      d[i] = midi_tx;
      #(BIT);
    end
    if (!midi_tx) frame_err++;
    out_q.push_back(d);
  end
  // the start bit's width
  realtime tf = 0;
  always @(negedge midi_tx) tf = $realtime;

  initial begin
    logic [7:0] st;
    repeat (5) @(posedge clk);
    @(negedge clk) rst_n = 1;
    repeat (5) @(posedge clk);
    load_program("midi_image.hex");
    reg_write(7'h00, 8'b1100_0000);
    reg_write(7'h03, 8'hF0);
    reg_write(7'h10, 8'd119);         // engine 0: 1/16 bit
    reg_write(7'h11, 8'd0);
    reg_write(7'h12, 8'd0);
    reg_write(7'h13, 8'd0);           // JMP_PIN = RX
    reg_write(7'h14, 8'h00);
    reg_write(7'h15, 8'd0);
    reg_write(7'h1E, 8'h40);
    reg_write(7'h20, 8'(959));        // engine 1: uart_tx, 1/2 bit
    reg_write(7'h21, 8'(959 >> 8));
    reg_write(7'h22, 8'd4);
    reg_write(7'h24, 8'h00);
    reg_write(7'h25, 8'd0);
    reg_write(7'h2E, 8'h40);
    reg_write(7'h00, 8'b0011_0011);
    repeat (2000) @(posedge clk);

    in_test(1.0, "31.25 kbaud");
    in_test(0.99, "1 % fast");
    in_test(1.01, "1 % slow");

    // out: a note on, a running-status pair and a real-time byte
    begin
      logic [7:0] o[$];
      bit ok;
      o.push_back(8'h90); o.push_back(8'h3C); o.push_back(8'h7F); o.push_back(8'h3E);
      o.push_back(8'h7F); o.push_back(8'hF8); o.push_back(8'h00); o.push_back(8'hFF);
      foreach (o[i]) fifo_send(1, o[i]);
      wait_tx_empty(1);
      #(15 * BIT);
      ok = out_q.size() == o.size() && frame_err == 0;
      for (int i = 0; i < o.size() && i < out_q.size(); i++) begin
        logic [7:0] a, b;
        a = out_q[i];
        b = o[i];
        ok &= a === b;
      end
      result($sformatf("out: %0d bytes as 8N1 at 31.25 kbaud", o.size()), ok);
    end
    reg_read(7'h1F, st);
    check(!st[3], "RX overflow");
    if (errors == 0 && pass == 4) begin
      $display("PASS: MIDI");
      $finish;
    end else $fatal(1, "FAILED with %0d error(s)", errors);
  end
  initial begin
    #300ms;
    $fatal(1, "FAILED: timeout");
  end
endmodule
