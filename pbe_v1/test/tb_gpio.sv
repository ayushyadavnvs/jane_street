`timescale 1ns / 1ps
// End-to-end test of the 24-bit GPIO expander (gpio_expander.pbe, D85) through the chip's pins,
// against behavioural 74HC595 and 74HC165 models chained 3 deep (hc_chain.sv).
//   engine 0: gpio_expander.pbe at word 0; pins 0..4 = SCK, SDO, SDI, RCLK, LD#.
// The 165s' CLK-to-QH delay is 60 ns (slower than the 4.5 V datasheet's 30 ns, as a 3.3 V part).
// Scenarios: 40 random exchanges at CLKDIV 0 (the fastest) and 8 at CLKDIV 3, back to back; the
// inputs change during an exchange (they must be the ones at LD#); the outputs must not change
// until RCLK rises, and must then hold the bytes sent. The SCK rate is measured.
module tb_gpio;
  localparam real CLK_NS = 16.6672;  // 60 MHz
  localparam int HOST_HALF = 8;

  logic clk = 0, rst_n = 0;
  always #(CLK_NS / 2) clk = ~clk;

  logic [7:0] ui_in = 8'b0000_0010;
  wire  [7:0] uo_out, uio_out, uio_oe;
  wire  sdi;
  logic [23:0] in_pins = 24'h0;
  wire  [23:0] out_pins;
  // SCK, SDO and RCLK have pull-downs and LD# a pull-up, so the chips see no edge while an
  // engine restart releases the pins; SDI is the first 165's QH
  wire  [7:0] bus;
  assign bus[0] = uio_oe[0] & uio_out[0];
  assign bus[1] = uio_oe[1] & uio_out[1];
  assign bus[2] = sdi;
  assign bus[3] = uio_oe[3] & uio_out[3];
  assign bus[4] = !uio_oe[4] | uio_out[4];
  assign bus[7:5] = 3'b000;

  tt_um_ayushyadavnvs_pbe dut (
      .ui_in, .uo_out, .uio_in(bus), .uio_out, .uio_oe, .ena(1'b1), .clk, .rst_n
  );
  hc_chain #(.T_PD(60.0)) u_hc (.sck(bus[0]), .sdo(bus[1]), .rclk(bus[3]), .ld_n(bus[4]), .sdi,
                                .in_pins, .out_pins);

`ifdef PBE_SIGROK
  wire p0 = bus[0], p1 = bus[1], p2 = bus[2], p3 = bus[3], p4 = bus[4];
  initial begin
    $dumpfile("tb_gpio_pins.vcd");
    $dumpvars(0, p0, p1, p2, p3, p4);
  end
`endif

  `include "tb_host.svh"

  // the outputs may change only when RCLK rises
  int out_glitch = 0;
  always @(out_pins) if (!bus[3]) out_glitch++;
  // SCK: the shortest period, high and low
  realtime t_r = 0, t_f = 0;
  real sck_per = 1e9, sck_hi = 1e9, sck_lo = 1e9;
  always @(posedge bus[0]) begin
    if (t_r > 0 && $realtime - t_r < sck_per) sck_per = $realtime - t_r;
    if (t_f > 0 && $realtime - t_f < sck_lo) sck_lo = $realtime - t_f;
    t_r = $realtime;
  end
  always @(negedge bus[0]) begin
    if (t_r > 0 && $realtime - t_r < sck_hi) sck_hi = $realtime - t_r;
    t_f = $realtime;
  end

  task automatic setup(input logic [15:0] div);
    reg_write(7'h00, 8'b0100_0000);   // stop, flush
    reg_write(7'h10, div[7:0]);
    reg_write(7'h11, div[15:8]);
    reg_write(7'h12, 8'd0);           // pin base 0
    reg_write(7'h14, 8'h03);          // OUT and IN MSB first
    reg_write(7'h15, 8'd0);
    reg_write(7'h1B, 8'h00);
    reg_write(7'h1C, 8'h00);
    reg_write(7'h1D, 8'h00);
    reg_write(7'h1E, 8'h00);
    reg_write(7'h00, 8'b0001_0001);   // restart and run engine 0
  endtask

  // one exchange: the 24 outputs, and the 24 inputs read
  task automatic xchg(input logic [23:0] o, output logic [23:0] i);
    logic [7:0] b;
    fifo_send(0, o[23:16]);           // o0: ends in the last 595 (out_pins[23:16])
    fifo_send(0, o[15:8]);
    fifo_send(0, o[7:0]);
    for (int k = 0; k < 3; k++) begin
      fifo_recv(0, b);
      i[8*k +: 8] = b;                // i0 = the first 165 (in_pins[7:0])
    end
`ifdef PBE_SIGROK
    $display("SIGROK_GPIO %06x %06x", o, {i[7:0], i[15:8], i[23:16]});
`endif
  endtask

  int pass = 0;
  task automatic result(input string name, input bit ok);
    check(ok, name);
    if (ok) pass++;
    $display("  GPIO %-58s %s", name, ok ? "PASS" : "FAIL");
  endtask

  task automatic run(input int n, input string what);
    logic [23:0] o, i, snap;
    bit ok = 1;
    int bad = 0;
    for (int k = 0; k < n; k++) begin
      o = $urandom;
      in_pins = $urandom;
      snap = in_pins;
      fork
        xchg(o, i);
        begin   // change the inputs once the 165s have loaded them (LD# rises)
          @(posedge bus[4]);
          #100;
          in_pins = ~snap;
        end
      join
      wait_tx_empty(0);
      repeat (40) @(posedge clk);     // the latch pulse
      if (i !== snap || out_pins !== o) begin
        bad++;
        if (bad < 4) $display("    exchange %0d: out %06x (sent %06x), in %06x (pins %06x)", k, out_pins, o, i, snap);
      end
    end
    result($sformatf("%0d random 24-bit exchanges, %s", n, what), bad == 0);
  endtask

  initial begin
    repeat (5) @(posedge clk);
    @(negedge clk) rst_n = 1;
    repeat (5) @(posedge clk);
    load_program("gpio_image.hex");

    setup(16'd0);
    run(40, "CLKDIV 0");
    $display("  CLKDIV 0: SCK min period %0.1f ns (%0.2f MHz), high %0.1f ns, low %0.1f ns",
             sck_per, 1000.0 / sck_per, sck_hi, sck_lo);
    check(sck_per > 7 * CLK_NS - 1.0 && sck_per < 7 * CLK_NS + 1.0, "SCK period at CLKDIV 0 is not 7 clocks");
    sck_per = 1e9;
    setup(16'd3);
    run(8, "CLKDIV 3");
    $display("  CLKDIV 3: SCK min period %0.1f ns (%0.2f MHz)", sck_per, 1000.0 / sck_per);
    // a known pattern: walking ones out, the inputs read back
    begin
      logic [23:0] i;
      bit ok;
      ok = 1;
      for (int k = 0; k < 24; k++) begin
        in_pins = 24'h1 << k;
        xchg(24'h800000 >> k, i);
        wait_tx_empty(0);
        repeat (40) @(posedge clk);
        ok &= i == (24'h1 << k) && out_pins == (24'h800000 >> k);
      end
      result("walking one through all 24 outputs and 24 inputs (bit order)", ok);
    end

    check(u_hc.errors() == 0, $sformatf("74HC models saw %0d timing violations", u_hc.errors()));
    check(out_glitch == 0, $sformatf("the 595 outputs changed %0d times without RCLK", out_glitch));
    if (errors == 0 && pass == 3) begin
      $display("PASS: GPIO expander");
      $finish;
    end else $fatal(1, "FAILED with %0d error(s)", errors);
  end

  initial begin
    #200ms;
    $fatal(1, "FAILED: timeout");
  end
endmodule
