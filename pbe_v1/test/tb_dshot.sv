`timescale 1ns / 1ps
// Blind generality benchmark 7: DShot600 transmitter (dshot600.pbe) against an ESC-side DShot
// decoder written from the DShot description (Betaflight/BLHeli): 600 kbit/s, bit period
// 1.667 us, a 0 high for 625 ns and a 1 for 1250 ns, 16 bits MSB first: 11-bit throttle, a
// telemetry request bit, and a 4-bit checksum = (v ^ v >> 4 ^ v >> 8) & 0xF of those 12 bits.
//   engine 0: D = pin 0.
// The decoder measures every bit period (within 1 %) and every high time (within 60 ns of the
// nominal), rebuilds the frame and checks the checksum itself.
// Frames: throttle 0 (disarmed), 48 (the lowest), 1046, 2047 (full), commands with the
// telemetry bit, 200 random values, sent at 8 kHz (and two back to back).
module tb_dshot;
  localparam real CLK_NS = 16.6672;  // 60 MHz
  localparam int HOST_HALF = 4;

  logic clk = 0, rst_n = 0;
  always #(CLK_NS / 2) clk = ~clk;
  logic [7:0] ui_in = 8'b0000_0010;
  wire  [7:0] uo_out, uio_out, uio_oe;
  wire  d = uio_oe[0] & uio_out[0];
  wire  [7:0] bus = {7'b0, d};
  tt_um_ayushyadavnvs_pbe dut (.ui_in, .uo_out, .uio_in(bus), .uio_out, .uio_oe, .ena(1'b1), .clk, .rst_n);
  `include "tb_host.svh"

  // ---------------- DShot decoder ----------------
  logic [15:0] frames[$];
  logic [15:0] sh;
  int nbits = 0, n_bad_crc = 0, n_bad_len = 0, n_bad_time = 0;
  real per_min = 1e9, per_max = 0, h0_min = 1e9, h0_max = 0, h1_min = 1e9, h1_max = 0;
  realtime t_r = 0, t_f = 0;
  always @(posedge d) if (rst_n) begin   // (before reset the pins are unknown)
    real p;
    p = $realtime - t_r;
    if (nbits > 0) begin             // inside a frame: the bit period
      if (p < per_min) per_min = p;
      if (p > per_max) per_max = p;
      if (p < 1666.7 * 0.99 || p > 1666.7 * 1.01) n_bad_time++;
    end
    t_r = $realtime;
  end
  always @(negedge d) if (rst_n) begin
    real h;
    bit b;
    h = $realtime - t_r;
    t_f = $realtime;
    b = h > 937.5;                   // the threshold: 3/4 of the way from 625 to 1250... midway
    if (b) begin
      if (h < h1_min) h1_min = h;
      if (h > h1_max) h1_max = h;
      if (h < 1250.0 - 60 || h > 1250.0 + 60) n_bad_time++;
    end else begin
      if (h < h0_min) h0_min = h;
      if (h > h0_max) h0_max = h;
      if (h < 625.0 - 60 || h > 625.0 + 60) n_bad_time++;
    end
    sh = {sh[14:0], b};
    nbits++;
  end
  // a frame ends when the line has been low for 2 bit times
  always begin
    #200;
    if (nbits > 0 && !d && $realtime - t_f > 3400.0) begin
      if (nbits != 16) n_bad_len++;
      else begin
        if (((sh[15:4] ^ (sh[15:4] >> 4) ^ (sh[15:4] >> 8)) & 12'hF) != {8'b0, sh[3:0]}) n_bad_crc++;
        frames.push_back(sh);
      end
      nbits = 0;
    end
  end

  int pass = 0;
  task automatic result(input string name, input bit ok);
    check(ok, name);
    if (ok) pass++;
    $display("  DSHT %-62s %s", name, ok ? "PASS" : "FAIL");
  endtask

  logic [11:0] sent[$];
  task automatic frame(input logic [10:0] thr, input bit tlm);
    logic [7:0] x;
    sent.push_back({thr, tlm});
    cs(0);
    spi_byte({1'b1, 7'h16}, x);
    spi_byte(thr[10:3], x);
    spi_byte({thr[2:0], tlm, 4'b0000}, x);
    cs(1);
  endtask
  task automatic compare(input string name);
    logic [15:0] f;
    logic [11:0] v;
    int bad;
    wait_tx_empty(0);
    #(100000);
    bad = frames.size() != sent.size();
    for (int i = 0; i < sent.size() && i < frames.size(); i++) begin
      f = frames[i];
      v = sent[i];
      if (f[15:4] !== v) bad++;
    end
    if (bad) $display("    %0d frames decoded, %0d sent", frames.size(), sent.size());
    result(name, bad == 0);
  endtask

  initial begin
    repeat (5) @(posedge clk);
    @(negedge clk) rst_n = 1;
    repeat (5) @(posedge clk);
    load_program("dshot_image.hex");
    reg_write(7'h00, 8'b0100_0000);
    reg_write(7'h10, 8'd0);
    reg_write(7'h11, 8'd0);
    reg_write(7'h12, 8'd0);
    reg_write(7'h14, 8'h01);          // OUT MSB first
    reg_write(7'h15, 8'd0);
    reg_write(7'h19, 8'h01);          // CRC_POLY 0x0001 (x^4 + 1 with the width below)
    reg_write(7'h1A, 8'h00);
    reg_write(7'h1B, 8'h43);          // 4 bits, init 0, fed by OUT
    reg_write(7'h1C, 8'h00);
    reg_write(7'h1D, 8'h00);
    reg_write(7'h1E, 8'h40);
    reg_write(7'h00, 8'b0001_0001);
    repeat (1000) @(posedge clk);

    frame(11'd0, 0);
    frame(11'd48, 0);
    frame(11'd1046, 0);
    frame(11'd2047, 0);
    frame(11'd2047, 1);
    frame(11'd1, 1);                  // a command (beep) with the telemetry bit
    frame(11'h555, 0);
    frame(11'h2AA, 1);
    compare("8 frames: throttle 0, 48, 1046, 2047, commands, telemetry bit");
    for (int i = 0; i < 200; i++) begin
      frame(11'($urandom), 1'($urandom));
      repeat (5000) @(posedge clk);   // 12 kHz... the host's own writes make it about 8 kHz
    end
    compare("200 random frames");
    // two frames queued together: back to back, still two frames
    begin
      logic [7:0] x;
      sent.push_back(12'hABC);
      sent.push_back(12'h123);
      cs(0);
      spi_byte({1'b1, 7'h16}, x);
      spi_byte(8'hAB, x); spi_byte(8'hC0, x); spi_byte(8'h12, x); spi_byte(8'h30, x);
      cs(1);
    end
    compare("two frames queued together");

    $display("  DSHT %0d frames; bit period %0.1f-%0.1f ns (1666.7), 0 high %0.1f-%0.1f ns (625), 1 high %0.1f-%0.1f ns (1250)",
             frames.size(), per_min, per_max, h0_min, h0_max, h1_min, h1_max);
    check(n_bad_crc == 0, $sformatf("%0d frames with a wrong checksum", n_bad_crc));
    check(n_bad_len == 0, $sformatf("%0d frames not 16 bits long", n_bad_len));
    check(n_bad_time == 0, $sformatf("%0d bits outside the timing limits", n_bad_time));
    if (errors == 0 && pass == 3) begin
      $display("PASS: DShot600");
      $finish;
    end else $fatal(1, "FAILED with %0d error(s)", errors);
  end
  initial begin
    #500ms;
    $fatal(1, "FAILED: timeout");
  end
endmodule
