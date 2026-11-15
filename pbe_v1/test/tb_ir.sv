`timescale 1ns / 1ps
// Blind generality benchmark 4: IR NEC transmitter (ir_nec_tx.pbe, engine 0: IR = pin 0,
// scratch = pin 1) and receiver (ir_nec_rx.pbe, engine 1: IR = pin 4), both at once, against
// an NEC decoder and an NEC remote written from the NEC protocol description (38 kHz carrier,
// 9 ms + 4.5 ms leader, 562.5 us bursts, spaces of 562.5 us (0) and 1687.5 us (1), LSB first,
// final burst; repeat code 9 ms + 2.25 ms + burst).
// Transmit: the decoder measures the carrier (period, duty) and every burst and space (within
// 5 %), and rebuilds the bytes; a frame, a repeat code, and an extended frame with other data.
// Receive: the remote sends frames 5 % fast and 5 % slow, a repeat code, noise (a short burst)
// and a frame cut off in the middle (timeout flag), then a good frame again.
module tb_ir;
  localparam real CLK_NS = 16.6672;  // 60 MHz
  localparam int HOST_HALF = 4;
  localparam real U = 562500.0;      // the NEC unit

  logic clk = 0, rst_n = 0;
  always #(CLK_NS / 2) clk = ~clk;
  logic [7:0] ui_in = 8'b0000_0010;
  wire  [7:0] uo_out, uio_out, uio_oe;
  logic rx_in = 1;                   // demodulated, active low
  wire  led = uio_oe[0] & uio_out[0];
  wire  [7:0] bus = {3'b0, rx_in, 2'b0, uio_oe[1] & uio_out[1], led};
  tt_um_ayushyadavnvs_pbe dut (.ui_in, .uo_out, .uio_in(bus), .uio_out, .uio_oe, .ena(1'b1), .clk, .rst_n);
  `include "tb_host.svh"

  int pass = 0;
  task automatic result(input string name, input bit ok);
    check(ok, name);
    if (ok) pass++;
    $display("  IR   %-64s %s", name, ok ? "PASS" : "FAIL");
  endtask

  // ---------------- NEC decoder on the LED pin ----------------
  // a burst: carrier edges less than 100 us apart; marks[] and spaces[] in ns, in order
  real marks[$], spaces[$];
  real per_min = 1e9, per_max = 0, duty_min = 1, duty_max = 0;
  realtime t_r = 0, t_f = 0, t_start = 0, t_last_f = 0;
  bit in_burst = 0;
  always @(posedge led) begin
    if (!in_burst) begin
      if (t_last_f > 0) spaces.push_back($realtime - t_last_f);
      in_burst = 1;
      t_start = $realtime;
    end else begin
      real p;
      p = $realtime - t_r;
      if (p < per_min) per_min = p;
      if (p > per_max) per_max = p;
      if ((t_f - t_r) / p < duty_min) duty_min = (t_f - t_r) / p;
      if ((t_f - t_r) / p > duty_max) duty_max = (t_f - t_r) / p;
    end
    t_r = $realtime;
  end
  always @(negedge led) begin
    t_f = $realtime;
    t_last_f = $realtime;
  end
  always begin
    #10000;
    if (in_burst && !led && $realtime - t_f > 100000.0) begin
      in_burst = 0;
      marks.push_back(t_f - t_start);
    end
  end

  function automatic bit near(input real v, input real units);
    return v > units * U * 0.95 && v < units * U * 1.05;
  endfunction
  // decode marks/spaces from index 0: kind 1 = frame of n bytes, 2 = repeat; consumes them
  logic [7:0] dec[$];
  task automatic decode(output int kind, output string why);
    logic [7:0] b;
    int n, i;
    real m, sp;
    dec = {};
    kind = 0;
    why = "";
    // marks: leader, then one per bit, then the final burst; spaces: leader space, one per bit
    if (marks.size() < 2) why = $sformatf("only %0d bursts", marks.size());
    else begin
      m = marks.pop_front();
      sp = spaces.pop_front();
      if (!near(m, 16)) why = $sformatf("leader burst %0.0f us", m / 1000);
      else if (marks.size() == 1) begin    // a repeat code
        m = marks.pop_front();
        if (near(sp, 4) && m > 0.9 * U && m < 1.05 * U) kind = 2;
        else why = $sformatf("repeat: space %0.0f us, burst %0.0f us", sp / 1000, m / 1000);
      end else if (!near(sp, 8)) why = $sformatf("leader space %0.0f us", sp / 1000);
      else begin
        n = marks.size() - 1;              // data bits
        for (i = 0; i < n; i++) begin
          m = marks.pop_front();
          sp = spaces.pop_front();
          // a burst is 21 carrier cycles less the last low half (553 us); a space runs to the
          // next burst. Their sum is the bit: 2 units (0) or 4 units (1), within 5 %.
          if (m < 0.9 * U || m > 1.05 * U) why = $sformatf("bit %0d: burst %0.0f us", i, m / 1000);
          if (near(m + sp, 2)) b[i % 8] = 0;
          else if (near(m + sp, 4)) b[i % 8] = 1;
          else why = $sformatf("bit %0d: burst + space %0.0f us", i, (m + sp) / 1000);
          if (i % 8 == 7) dec.push_back(b);
        end
        m = marks.pop_front();
        if (m < 0.9 * U || m > 1.05 * U) why = $sformatf("final burst %0.0f us", m / 1000);
        if (n % 8 != 0) why = $sformatf("%0d bits", n);
        if (why == "") kind = 1;
      end
    end
  endtask

  task automatic tx_frame(input logic [7:0] a0, input logic [7:0] a1, input logic [7:0] c0, input logic [7:0] c1,
                          input string name);
    int kind;
    string why;
    logic [7:0] x;
    bit ok;
    marks = {};
    spaces = {};
    t_last_f = 0;
    cs(0);
    spi_byte({1'b1, 7'h16}, x);
    spi_byte(a0, x); spi_byte(a1, x); spi_byte(c0, x); spi_byte(c1, x);
    cs(1);
    #(72.0e6);                       // (a frame is 67.5 ms when half its bits are 1)
    decode(kind, why);
    ok = kind == 1 && dec.size() == 4;
    if (ok) begin
      x = dec[0]; ok &= x == a0;
      x = dec[1]; ok &= x == a1;
      x = dec[2]; ok &= x == c0;
      x = dec[3]; ok &= x == c1;
    end
    if (why != "") $display("    decoder: %s", why);
    result(name, ok);
  endtask

  // ---------------- NEC remote (demodulated, active low) ----------------
  real k = 1.0;                      // the remote's clock error
  task automatic burst(input real units);
    rx_in = 0;
    #(units * U * k);
    rx_in = 1;
  endtask
  task automatic rem_frame(input logic [7:0] a, input logic [7:0] c, input int bits);
    logic [31:0] w;
    w = {~c, c, ~a, a};
    burst(16);
    #(8 * U * k);
    for (int i = 0; i < bits; i++) begin
      burst(1);
      #((w[i] ? 3 : 1) * U * k);
    end
    if (bits == 32) burst(1);
  endtask
  task automatic rem_repeat;
    burst(16);
    #(4 * U * k);
    burst(1);
  endtask

  logic [7:0] rxq[$];
  task automatic rx_drain;
    logic [7:0] c, d;
    reg_read(7'h0B, c);
    for (int i = 0; i < c; i++) begin
      reg_read(7'h26, d);
      rxq.push_back(d);
    end
  endtask
  task automatic rx_expect_frame(input logic [7:0] a, input logic [7:0] c, input string name);
    logic [7:0] x;
    bit ok;
    rxq = {};
    #(5.0e6);
    rx_drain;
    ok = rxq.size() == 5;
    if (ok) begin
      x = rxq[0]; ok &= x == 8'h4E;
      x = rxq[1]; ok &= x == a;
      x = rxq[2]; ok &= x == 8'(~a);
      x = rxq[3]; ok &= x == c;
      x = rxq[4]; ok &= x == 8'(~c);
    end
    if (!ok) $display("    %0d bytes in the RX FIFO", rxq.size());
    result(name, ok);
  endtask

  initial begin
    logic [7:0] x;
    bit f;
    int kind;
    string why;
    repeat (5) @(posedge clk);
    @(negedge clk) rst_n = 1;
    repeat (5) @(posedge clk);
    load_program("ir_image.hex");
    reg_write(7'h00, 8'b1100_0000);
    reg_write(7'h03, 8'hF0);
    reg_write(7'h10, 8'(394));        // engine 0: quarter carrier period
    reg_write(7'h11, 8'(394 >> 8));
    reg_write(7'h12, 8'd0);
    reg_write(7'h13, 8'd1);           // JMP_PIN = scratch
    reg_write(7'h14, 8'h00);
    reg_write(7'h15, 8'd0);
    reg_write(7'h1E, 8'h40);
    reg_write(7'h20, 8'(4217));       // engine 1: 70.3 us
    reg_write(7'h21, 8'(4217 >> 8));
    reg_write(7'h22, 8'd4);
    reg_write(7'h23, 8'd0);           // JMP_PIN = IR in
    reg_write(7'h24, 8'h00);
    reg_write(7'h25, 8'd0);
    reg_write(7'h2C, 8'd240);
    reg_write(7'h2D, 8'd0);
    reg_write(7'h2E, 8'h41);
    reg_write(7'h00, 8'b0011_0011);
    repeat (2000) @(posedge clk);

    fork
      // ---- transmit ----
      begin
        tx_frame(8'h04, 8'hFB, 8'h08, 8'hF7, "TX: frame 04 FB 08 F7 decoded, every burst and space within 5 %");
        marks = {};
        spaces = {};
        t_last_f = 0;
        flag_set(0, 0);
        #(20.0e6);
        decode(kind, why);
        if (why != "") $display("    decoder: %s", why);
        flag_get(0, 0, f);
        result("TX: repeat code (9 ms, 2.25 ms, burst), FLAG0 cleared", kind == 2 && !f);
        tx_frame(8'hA5, 8'h3C, 8'hFF, 8'h00, "TX: extended frame A5 3C FF 00");
      end
      // ---- receive ----
      begin
        #(3.0e6);
        k = 0.95;
        rem_frame(8'h04, 8'h08, 32);
        rx_expect_frame(8'h04, 8'h08, "RX: frame, remote 5 % fast");
        #(8.0e6);
        rxq = {};
        k = 1.0;
        rem_repeat;
        #(5.0e6);
        rx_drain;
        x = rxq.size() ? rxq[0] : 8'h00;
        result("RX: repeat code ('R')", rxq.size() == 1 && x == 8'h52);
        #(8.0e6);
        k = 1.05;
        rem_frame(8'hE0, 8'h5A, 32);
        rx_expect_frame(8'hE0, 8'h5A, "RX: frame, remote 5 % slow");
        #(8.0e6);
        // noise: a 2 ms burst is not a leader
        rxq = {};
        burst(3.5);
        #(10.0e6);
        rx_drain;
        flag_get(1, 1, f);
        result("RX: a 2 ms burst is ignored", rxq.size() == 0 && !f);
        // a frame cut after 13 bits: timeout, FLAG1
        k = 1.0;
        rem_frame(8'h11, 8'h22, 13);
        #(22.0e6);
        flag_get(1, 1, f);
        rx_drain;
        result("RX: a frame cut off: FLAG1 (timeout) set", f);
        reg_write(7'h00, 8'b1000_0011);   // the host flushes engine 1's FIFOs
        flag_clear(1, 1);
        rem_frame(8'h01, 8'hFE, 32);
        rx_expect_frame(8'h01, 8'hFE, "RX: a good frame after the cut one");
      end
    join
    $display("  IR   carrier period %0.2f-%0.2f us (38 kHz = 26.32), duty %0.0f-%0.0f %%",
             per_min / 1000, per_max / 1000, duty_min * 100, duty_max * 100);
    check(per_min > 26316.0 * 0.98 && per_max < 26316.0 * 1.02, "carrier more than 2 % off 38 kHz");
    check(duty_min > 0.45 && duty_max < 0.55, "carrier duty not 50 %");
    if (errors == 0 && pass == 9) begin
      $display("PASS: IR NEC");
      $finish;
    end else $fatal(1, "FAILED with %0d error(s)", errors);
  end
  initial begin
    #3000ms;
    $fatal(1, "FAILED: timeout");
  end
endmodule
