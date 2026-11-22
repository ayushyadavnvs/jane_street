`timescale 1ns / 1ps
// Blind generality benchmark 6: I2S transmitter (i2s_tx.pbe) against an I2S receiver written
// from the Philips I2S bus specification: SD and WS (LRCLK) are sampled on the rising edge of
// BCLK; a word starts one BCLK period after WS changes, MSB first; WS low = left.
//   engine 0: BCLK = pin 0, LRCLK = pin 1, SD = pin 2.
// The receiver rebuilds 16-bit left/right samples and checks that every BCLK period is the same
// (39 clocks), its duty, and the set-up and hold of SD and WS around the rising edge.
// 200 stereo samples streamed by the host; then the host stops (silence, clocks still running)
// and starts again: the samples must still come out whole and in the right channel.
module tb_i2s;
  localparam real CLK_NS = 16.6672;  // 60 MHz
  localparam int HOST_HALF = 4;

  logic clk = 0, rst_n = 0;
  always #(CLK_NS / 2) clk = ~clk;
  logic [7:0] ui_in = 8'b0000_0010;
  wire  [7:0] uo_out, uio_out, uio_oe;
  wire  [7:0] bus = {5'b0, uio_oe[2:0] & uio_out[2:0]};
  wire  bclk = bus[0], ws = bus[1], sd = bus[2];
  tt_um_ayushyadavnvs_pbe dut (.ui_in, .uo_out, .uio_in(bus), .uio_out, .uio_oe, .ena(1'b1), .clk, .rst_n);
  `include "tb_host.svh"

  // ---------------- I2S receiver ----------------
  logic [15:0] left_q[$], right_q[$];
  logic [15:0] sh;
  int nb = -1;                 // bits of the current word still to come (-1: not in step yet)
  bit ws_d = 0, ch = 0, started = 0, armed = 0;   // armed: from the first left word on
  real per_min = 1e9, per_max = 0, hi_min = 1e9, hi_max = 0, su_min = 1e9, ho_min = 1e9;
  realtime t_r = 0, t_f = 0, t_data = 0;
  int n_err = 0;
  always @(sd or ws) begin
    t_data = $realtime;
    if (started && $realtime - t_r < ho_min) ho_min = $realtime - t_r;
  end
  always @(negedge bclk) begin
    if (started && $realtime - t_r < hi_min) hi_min = $realtime - t_r;
    if (started && $realtime - t_r > hi_max) hi_max = $realtime - t_r;
    t_f = $realtime;
  end
  always @(posedge bclk) begin
    if (started) begin
      if ($realtime - t_r < per_min) per_min = $realtime - t_r;
      if ($realtime - t_r > per_max) per_max = $realtime - t_r;
      if ($realtime - t_data < su_min) su_min = $realtime - t_data;
    end
    t_r = $realtime;
    // the bit sampled now belongs to the word selected by WS one period ago
    if (nb > 0) begin
      sh = {sh[14:0], sd};
      nb--;
      if (nb == 0 && armed) begin
        if (ch) right_q.push_back(sh);
        else left_q.push_back(sh);
      end
    end
    if (ws != ws_d) begin      // WS changed: the next bit is the MSB of the new word
      if (nb > 0) n_err++;     // (a word cut short)
      nb = 16;
      ch = ws;
      started = 1;
      if (!ws) armed = 1;
    end
    ws_d = ws;
  end

  int pass = 0;
  task automatic result(input string name, input bit ok);
    check(ok, name);
    if (ok) pass++;
    $display("  I2S  %-62s %s", name, ok ? "PASS" : "FAIL");
  endtask

  logic [15:0] sl[$], sr[$];
  // send n stereo samples in one burst, pausing while the TX FIFO is full
  task automatic stream(input int n);
    logic [7:0] x;
    logic [15:0] l, r;
    cs(0);
    spi_byte({1'b1, 7'h16}, x);
    for (int i = 0; i < n; i++) begin
      l = 16'($urandom);
      r = 16'($urandom);
      if (i == 0) begin l = 16'h8001; r = 16'h7FFE; end
      sl.push_back(l);
      sr.push_back(r);
      // every byte waits while the TX FIFO is full (a byte written to a full FIFO is dropped)
      while (uo_out[6]) @(negedge clk);
      spi_byte(l[15:8], x);
      while (uo_out[6]) @(negedge clk);
      spi_byte(l[7:0], x);
      while (uo_out[6]) @(negedge clk);
      spi_byte(r[15:8], x);
      while (uo_out[6]) @(negedge clk);
      spi_byte(r[7:0], x);
    end
    cs(1);
  endtask
  // the non-zero samples received must be exactly those sent, in order, in their channel
  task automatic compare(input string name);
    logic [15:0] a, b;
    int k, bad;
    bit ok;
    #(40 * 39 * CLK_NS * 4);
    bad = 0;
    k = 0;
    for (int i = 0; i < left_q.size() && i < right_q.size(); i++) begin   // whole frames only
      a = left_q[i];
      b = right_q[i];
      if (a !== 16'h0000 || b !== 16'h0000) begin
        if (k >= sl.size() || a !== sl[k] || b !== sr[k]) begin
          bad++;
          if (bad < 4) $display("    sample %0d: %04x %04x, sent %04x %04x", k, a, b, sl[k], sr[k]);
        end
        k++;
      end
    end
    ok = bad == 0 && k == sl.size();
    if (k != sl.size()) $display("    %0d samples received, %0d sent", k, sl.size());
    result(name, ok);
  endtask

  initial begin
    repeat (5) @(posedge clk);
    @(negedge clk) rst_n = 1;
    repeat (5) @(posedge clk);
    load_program("i2s_image.hex");
    reg_write(7'h00, 8'b0100_0000);
    reg_write(7'h10, 8'd0);
    reg_write(7'h11, 8'd0);
    reg_write(7'h12, 8'd0);
    reg_write(7'h14, 8'h01);          // OUT MSB first
    reg_write(7'h15, 8'd0);
    reg_write(7'h1B, 8'h00);
    reg_write(7'h1C, 8'h00);
    reg_write(7'h1D, 8'h00);
    reg_write(7'h1E, 8'h40);
    reg_write(7'h00, 8'b0001_0001);
    repeat (3000) @(posedge clk);

    stream(200);
    compare("200 stereo samples streamed: every sample whole, in its channel");
    repeat (20000) @(posedge clk);    // the host stops: silence, the clocks run on
    stream(40);
    compare("after a pause of silence, 40 more samples still in step");

    $display("  I2S  BCLK period %0.1f-%0.1f ns (39 clocks = %0.1f), high %0.1f-%0.1f ns; SD/WS set-up %0.1f ns, hold %0.1f ns; %0d frames",
             per_min, per_max, 39 * CLK_NS, hi_min, hi_max, su_min, ho_min, left_q.size());
    check(per_max - per_min < 0.01 && per_min > 39 * CLK_NS - 0.5 && per_max < 39 * CLK_NS + 0.5, "BCLK is not a uniform 39 clocks");
    check(su_min > 100.0 && ho_min > 100.0, "SD or WS changes near the rising edge");
    check(n_err == 0, "a word was cut short by WS");
    check(left_q.size() >= 250, "the clocks stopped while the FIFO was empty");
    if (errors == 0 && pass == 2) begin
      $display("PASS: I2S");
      $finish;
    end else $fatal(1, "FAILED with %0d error(s)", errors);
  end
  initial begin
    #200ms;
    $fatal(1, "FAILED: timeout");
  end
endmodule
