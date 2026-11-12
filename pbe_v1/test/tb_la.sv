`timescale 1ns / 1ps
// End-to-end test of the logic analyser (la_capture.pbe) and the waveform generator
// (wavegen.pbe), D86, through the chip's pins.
//   engine 0: la_capture.pbe at word 0, channels = pins 0..3, trigger = JMP_PIN.
//   engine 1: wavegen.pbe at word 0 of its memory, A = pin 4, B = pin 5.
// The stimulus (pins 0..3) is a 4-bit counter written by the bench, independent of the
// engine's timing: it advances every STEP ns. The captured samples must show the counter in
// order, each value for STEP / (sample period) samples (one sample may mix two neighbouring
// values: the channels are read one tick apart). The trigger tests start the counter at a
// known value and check which value the first sample shows. The generator's pins are
// timestamped: every edge must fall on its sample grid and the levels must be the bytes sent.
// The host port runs at SCK = clk / 8, the fastest the chip allows, for the streaming tests.
module tb_la;
  localparam real CLK_NS = 20.8333;  // 48 MHz
  localparam int HOST_HALF = 4;      // host SCK = clk / 8

  localparam real CLK_SIM = 20.834;  // the simulated period: the half period rounds to 10.417 ns
  logic clk = 0, rst_n = 0;
  always #(CLK_NS / 2) clk = ~clk;

  logic [7:0] ui_in = 8'b0000_0010;
  wire  [7:0] uo_out, uio_out, uio_oe;
  logic [3:0] stim = 0;
  wire  [7:0] bus = {2'b00, uio_oe[5:4] & uio_out[5:4], stim};

  tt_um_ayushyadavnvs_pbe dut (
      .ui_in, .uo_out, .uio_in(bus), .uio_out, .uio_oe, .ena(1'b1), .clk, .rst_n
  );

  `include "tb_host.svh"

  int pass = 0;
  task automatic result(input string name, input bit ok);
    check(ok, name);
    if (ok) pass++;
    $display("  LA   %-62s %s", name, ok ? "PASS" : "FAIL");
  endtask

  // ---------------- stimulus: a counter on pins 0..3 ----------------
  bit stim_run = 0, cnt3 = 0;       // cnt3: count on pins 0..2 only (pin 3 is the trigger)
  real step_ns = 1000.0;
  always begin
    wait (stim_run);
    #(step_ns);
    if (stim_run) begin
      if (cnt3) stim[2:0] = stim[2:0] + 3'd1;
      else stim = stim + 4'd1;
    end
  end

  // ---------------- engine set-up ----------------
  task automatic setup_e(input int e, input logic [15:0] div, input logic [2:0] base, input logic [2:0] jpin);
    logic [6:0] b;
    b = e ? 7'h20 : 7'h10;
    reg_write(b + 0, div[7:0]);
    reg_write(b + 1, div[15:8]);
    reg_write(b + 2, 8'(base));
    reg_write(b + 3, 8'(jpin));
    reg_write(b + 4, 8'h00);          // LSB first
    reg_write(b + 5, 8'd0);
    reg_write(b + 'hB, 8'h00);
    reg_write(b + 'hC, 8'h00);
    reg_write(b + 'hD, 8'h00);
    reg_write(b + 'hE, 8'h40);
  endtask
  task automatic restart_all(input logic [15:0] div0, input logic [15:0] div1, input logic [2:0] jpin);
    reg_write(7'h00, 8'b1100_0000);   // stop both, flush
    reg_write(7'h03, 8'hF0);          // pins 4..7 to engine 1
    reg_write(7'h1F, 8'h04);          // clear engine 0's RX overflow
    setup_e(0, div0, 3'd0, jpin);
    setup_e(1, div1, 3'd4, 3'd0);
    reg_write(7'h00, 8'b0011_0011);   // restart and run both
  endtask

  // burst-read up to n bytes of engine 0's RX FIFO into q (what RX_COUNT says is there)
  logic [7:0] cap[$];
  task automatic drain(input int want);
    logic [7:0] c, d;
    while (cap.size() < want) begin
      reg_read(7'h0A, c);             // RX_COUNT
      if (c > want - cap.size()) c = want - cap.size();
      if (c != 0) begin
        cs(0);
        spi_byte({1'b0, 7'h16}, d);
        for (int i = 0; i < c; i++) begin
          spi_byte(8'h00, d);
          cap.push_back(d);
        end
        cs(1);
      end
    end
  endtask

  // the captured samples (2 per byte, low nibble first)
  logic [3:0] s[$];                   // the samples of the last capture
  task automatic samples;
    s = {};
    foreach (cap[i]) begin
      logic [7:0] c;
      c = cap[i];
      s.push_back(c[3:0]);
      s.push_back(c[7:4]);
    end
  endtask

  // The counter must appear in order: runs of one value, the value + 1 next, each run (but the
  // first) between per - 2 and per + 1 samples long; one sample between two runs may mix them
  // (or read entirely as the old value: the channels are read one tick apart). The step is not
  // a whole number of samples, so the transitions fall at every phase of the sampling.
  task automatic counter_ok(input real per, output bit ok, output string why);
    logic [3:0] cur, nxt;
    int run = 0, runs = 0;
    cur = s[0];
    ok = 1;
    for (int i = 0; i < s.size() && ok; i++) begin
      nxt = cur + 1;
      if (s[i] == cur) run++;
      else if (s[i] == nxt || (i + 1 < s.size() && s[i + 1] == nxt && ((s[i] ^ cur) & ~(cur ^ nxt)) == 0)) begin
        if (runs > 0 && (run + 2 < per || run > per + 1)) begin  // (a mixed sample counts too)
          why = $sformatf("sample %0d: value %0x lasted %0d samples, expected %0.1f", i, cur, run, per);
          ok = 0;
        end
        runs++;
        cur = nxt;
        run = (s[i] == nxt) ? 1 : 0;
      end else begin
        why = $sformatf("sample %0d: %0x after %0x", i, s[i], cur);
        ok = 0;
      end
    end
    if (ok) begin
      why = $sformatf("%0d values", runs + 1);
      ok = runs > 2;
    end
  endtask

  // ---------------- logic analyser scenarios ----------------
  task automatic la_capture(input logic [7:0] mode, input int n);
    cap = {};
    fifo_send(0, mode);
    fifo_send(0, 8'(n - 1));
  endtask

  task automatic la_free(input logic [15:0] div, input int n, input real per_samples, input string what);
    logic [7:0] st;
    string why;
    bit ok;
    restart_all(div, 16'd1, 3'd3);
    step_ns = per_samples * 6.0 * (div + 1) * CLK_NS;
    stim_run = 1;
    la_capture(8'h00, n);
    drain(n);
    stim_run = 0;
    samples;
    reg_read(7'h1F, st);
    counter_ok(per_samples, ok, why);
    result($sformatf("%s: %0d samples, %s", what, s.size(), why), ok && !st[3]);
    if (st[3]) $display("    RX overflow reported");
    if (!ok) begin
      string t = "";
      foreach (s[i]) t = {t, $sformatf("%0x", s[i])};
      $display("    samples: %s", t);
    end
  endtask

  // trigger: the counter (pins 0..2, 3 bits) runs; pin 3 changes at a known counter value
  task automatic la_trigger(input logic [7:0] mode, input string what);
    logic [3:0] first;
    logic [7:0] st;
    int div = 3;
    bit ok;
    restart_all(16'(div), 16'd1, 3'd3);
    stim = (mode == 3 || mode == 1) ? 4'b0000 : 4'b1000;
    cnt3 = 1;
    step_ns = 4 * 6.0 * (div + 1) * CLK_NS;  // 4 sample periods per value
    la_capture(mode, 8);
    repeat (200) @(posedge clk);
    // the counter runs on pins 0..2 with pin 3 held; it flips pin 3 when it reaches 5
    stim_run = 1;
    wait (stim[2:0] == 3'd5);
    #1 stim[3] = ~stim[3];
    drain(8);
    stim_run = 0;
    cnt3 = 0;
    samples;
    first = s[0];
    // 3 ticks + 2-3 clocks after the trigger: still value 5 (a value lasts 24 ticks)
    ok = first[2:0] == 3'd5 && first[3] == ((mode == 3 || mode == 1) ? 1'b1 : 1'b0);
    for (int i = 1; i < s.size(); i++) begin
      logic [3:0] v;
      v = s[i];
      ok &= v[3] == first[3];
    end
    reg_read(7'h1F, st);
    result($sformatf("trigger %s: the first sample is the trigger's (%0x)", what, first), ok && !st[3]);
  endtask

  // a capture longer than the FIFO with nobody reading: it pauses, RX overflow is reported
  task automatic la_overflow;
    logic [7:0] st;
    restart_all(16'd1, 16'd1, 3'd3);
    stim_run = 1;
    step_ns = 2000.0;
    la_capture(8'h00, 40);
    repeat (2000) @(posedge clk);
    reg_read(7'h1F, st);
    cap = {};
    drain(40);
    stim_run = 0;
    result("40-byte burst at CLKDIV 1, host not reading: RX overflow reported", st[3] == 1'b1);
  endtask

  // ---------------- generator ----------------
  // edges on A (pin 4) and B (pin 5), with their times
  realtime ea[$], eb[$];
  bit gen_on = 0;
  always @(bus[4]) if (gen_on) ea.push_back($realtime);
  always @(bus[5]) if (gen_on) eb.push_back($realtime);

  task automatic gen_play(input logic [15:0] div, input int n, input bit stream, input string what);
    logic [7:0] d[$];
    logic [7:0] q;
    realtime t0, s_ns, tick, t;
    real k;
    logic [7:0] r;
    bit a, b;
    int bad = 0;
    restart_all(16'd1, div, 3'd3);
    repeat (100) @(posedge clk);
    ea = {};
    eb = {};
    for (int i = 0; i < n; i++) begin
      r = $urandom;
      if (i == 0) r[0] = 1'b1;        // A rises at the first sample: the time origin
      d.push_back(r);
    end
    // queue the count and up to 15 bytes with the generator stopped, then run it and send the
    // rest in one burst, pausing while the TX FIFO is full
    reg_write(7'h00, 8'b0000_0001);   // engine 1 stopped
    fifo_send(1, 8'(n - 1));
    for (int i = 0; i < n && i < 15; i++) fifo_send(1, d[i]);
    gen_on = 1;
    reg_write(7'h00, 8'b0000_0011);
    if (n > 15) begin
      logic [7:0] x;
      cs(0);
      spi_byte({1'b1, 7'h26}, x);
      for (int i = 15; i < n; i++) begin
        while (uo_out[7]) @(negedge clk);
        spi_byte(d[i], x);
      end
      cs(1);
    end
    tick = (div + 1) * CLK_SIM;
    s_ns = 4 * tick;
    #(s_ns * 4 * n + 2000);
    gen_on = 0;
    t0 = ea[0];
    // every edge on the grid: A at t0 + k S, B at t0 + k S + 1 tick (+- 1 ns)
    foreach (ea[i]) begin
      k = (ea[i] - t0) / s_ns;
      if ($abs(k - $rtoi(k + 0.5)) * s_ns > 1.0) begin
        bad++;
        if (bad < 4) $display("    A edge %0d at sample %0.2f: off the grid", i, k);
      end
    end
    foreach (eb[i]) begin
      k = (eb[i] - t0 - tick) / s_ns;
      if ($abs(k - $rtoi(k + 0.5)) * s_ns > 1.0) begin
        bad++;
        if (bad < 4) $display("    B edge %0d at sample %0.2f: off the grid", i, k);
      end
    end
    // the levels: replay the edges at the middle of each sample
    for (int j = 0; j < 4 * n; j++) begin
      a = 0;
      b = 0;
      t = t0 + j * s_ns + s_ns / 2;
      foreach (ea[i]) if (ea[i] <= t) a = ~a;
      foreach (eb[i]) if (eb[i] <= t) b = ~b;
      q = d[j / 4] >> (2 * (j % 4));
      if (a !== q[0] || b !== q[1]) begin
        bad++;
        if (bad < 4) $display("    sample %0d: A %0d B %0d, expected %0d %0d", j, a, b, q[0], q[1]);
      end
    end
    // the last sample is held
    q = d[n - 1];
    if (bus[4] !== q[6] || bus[5] !== q[7]) begin
      bad++;
      $display("    the last sample is not held: A %0d B %0d, expected %0d %0d", bus[4], bus[5], q[6], q[7]);
    end
    result($sformatf("generator %s: %0d samples, %0.1f ns each, on the grid", what, 4 * n, s_ns), bad == 0);
  endtask

  initial begin
    repeat (5) @(posedge clk);
    @(negedge clk) rst_n = 1;
    repeat (5) @(posedge clk);
    load_program("la_image.hex");

    // capture: a 16-byte burst at the fastest rate, then sustained captures with the host reading
    la_free(16'd1, 16, 3.4, "burst, CLKDIV 1 (4 MS/s)");
    la_free(16'd7, 160, 3.3, "sustained, CLKDIV 7 (1 MS/s), host reading");
    la_free(16'd3, 16, 5.2, "burst, CLKDIV 3 (2 MS/s)");
    la_trigger(8'd3, "rising edge");
    la_trigger(8'd4, "falling edge");
    la_trigger(8'd1, "high level");
    la_overflow;
    // generator
    gen_play(16'd1, 15, 0, "15 bytes queued, CLKDIV 1 (6 MS/s)");
    gen_play(16'd4, 64, 1, "64 bytes streamed, CLKDIV 4 (2.4 MS/s)");
    gen_play(16'd20, 4, 0, "4 bytes, CLKDIV 20");

    if (errors == 0 && pass == 10) begin
      $display("PASS: logic analyser and generator");
      $finish;
    end else $fatal(1, "FAILED with %0d error(s)", errors);
  end

  initial begin
    #100ms;
    $fatal(1, "FAILED: timeout");
  end
endmodule
