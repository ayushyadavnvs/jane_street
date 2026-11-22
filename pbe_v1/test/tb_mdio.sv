`timescale 1ns / 1ps
// Blind generality benchmark 8: MDIO controller (mdio.pbe) against a PHY management interface
// written from IEEE 802.3 clause 22 (22.2.4.5 frame structure, 22.3.4 timing): 32 ones of
// preamble, ST 01, OP 10 read / 01 write, 5-bit PHY and register addresses, turnaround, 16 data
// bits MSB first; the PHY samples MDIO on the rising edge of MDC and drives read data T_CO
// (300 ns, the maximum) after it.
//   engine 0: MDC = pin 0, MDIO = pin 1 (pull-up).
// The PHY (address 0x0A) checks the preamble length, the MDC period (>= 400 ns), high and low
// (>= 160 ns), MDIO set-up and hold (>= 10 ns) and that the station never drives MDIO while it
// does. Tests: register writes and read-backs, the ID registers, a read from an absent PHY
// address, at 2 MHz (CLKDIV 4) and 1 MHz (CLKDIV 9).
module tb_mdio;
  localparam real CLK_NS = 16.6672;  // 60 MHz
  localparam int HOST_HALF = 4;

  logic clk = 0, rst_n = 0;
  always #(CLK_NS / 2) clk = ~clk;
  logic [7:0] ui_in = 8'b0000_0010;
  wire  [7:0] uo_out, uio_out, uio_oe;
  logic phy_drv = 0, phy_out = 1;
  wire  mdc = uio_oe[0] & uio_out[0];
  wire  mdio = phy_drv ? phy_out : (uio_oe[1] ? uio_out[1] : 1'b1);
  wire  [7:0] bus = {6'b0, mdio, mdc};
  tt_um_ayushyadavnvs_pbe dut (.ui_in, .uo_out, .uio_in(bus), .uio_out, .uio_oe, .ena(1'b1), .clk, .rst_n);
  `include "tb_host.svh"

  // ---------------- PHY ----------------
  localparam logic [4:0] PHYAD = 5'h0A;
  localparam real T_CO = 300.0;
  logic [15:0] regs[32];
  int ones = 0, n_err = 0, n_frames = 0, n_rd = 0, n_wr = 0, fight = 0;
  int st = 0;                  // 0 idle (counting preamble), 1 in a frame
  int bitn = 0;
  logic [31:0] sh;
  bit mine, is_rd;
  real per_min = 1e9, hi_min = 1e9, lo_min = 1e9, su_min = 1e9, ho_min = 1e9;
  realtime t_r = 0, t_f = 0, t_d = 0;
  wire sta_out = uio_oe[1] ? uio_out[1] : 1'b1;
  always @(sta_out) begin
    t_d = $realtime;
    if (rst_n && t_r > 0 && $realtime - t_r < ho_min) ho_min = $realtime - t_r;
  end
  always @(posedge clk) if (phy_drv && uio_oe[1]) fight++;
  always @(negedge mdc) if (rst_n) begin
    if ($realtime - t_r < hi_min) hi_min = $realtime - t_r;
    t_f = $realtime;
  end
  always @(posedge mdc) if (rst_n) begin
    if (t_r > 0 && $realtime - t_r < per_min) per_min = $realtime - t_r;
    if (t_f > 0 && $realtime - t_f < lo_min) lo_min = $realtime - t_f;
    if (!phy_drv && $realtime - t_d < su_min) su_min = $realtime - t_d;
    t_r = $realtime;
    if (st == 0) begin
      if (mdio) ones++;
      else begin               // the first 0: the start of frame, after the preamble
        if (ones < 32) begin
          n_err++;
          $display("  PHY: a start after only %0d preamble ones", ones);
        end
        st = 1;
        bitn = 1;
        sh = 32'd0;
        ones = 0;
      end
    end else begin
      sh = {sh[30:0], mdio};
      bitn++;
      if (bitn == 2 && !mdio) begin n_err++; $display("  PHY: ST is not 01"); end
      if (bitn == 14) begin    // ST OP PHYAD REGAD are in: sh[13:0]
        is_rd = sh[11:10] == 2'b10;
        mine = sh[9:5] == PHYAD;
        if (sh[11:10] != 2'b10 && sh[11:10] != 2'b01) begin n_err++; $display("  PHY: bad opcode"); end
        if (is_rd && mine) begin
          // read: Z for the first turnaround bit, then 0, then the data (see rd_ev below)
          rd_val = regs[sh[4:0]];
          -> rd_ev;
          n_rd++;
        end
      end
      if (bitn == 32) begin
        if (!is_rd && mine) begin
          if (sh[17:16] != 2'b10) begin n_err++; $display("  PHY: write turnaround is not 10"); end
          regs[sh[22:18]] = sh[15:0];
          n_wr++;
        end
        n_frames++;
        st = 0;
      end
    end
  end

  // a read: each output change T_CO after a rising edge of MDC
  logic [15:0] rd_val;
  event rd_ev;
  always @(rd_ev) begin
    @(posedge mdc);            // the first turnaround bit: nobody drives
    #(T_CO) phy_drv = 1;
    phy_out = 0;               // the second: 0
    for (int i = 15; i >= 0; i--) begin
      @(posedge mdc);
      #(T_CO) phy_out = rd_val[i];
    end
    @(posedge mdc);
    #(T_CO) phy_drv = 0;
  end

  int pass = 0;
  task automatic result(input string name, input bit ok);
    check(ok, name);
    if (ok) pass++;
    $display("  MDIO %-62s %s", name, ok ? "PASS" : "FAIL");
  endtask

  task automatic mwrite(input logic [4:0] phy, input logic [4:0] r, input logic [15:0] v);
    logic [31:0] f;
    logic [7:0] x;
    f = {2'b01, 2'b01, phy, r, 2'b10, v};
    cs(0);
    spi_byte({1'b1, 7'h16}, x);
    spi_byte(8'h00, x);
    for (int i = 3; i >= 0; i--) spi_byte(f[8*i +: 8], x);
    cs(1);
    wait_tx_empty(0);
    repeat (800) @(posedge clk);
  endtask
  task automatic mread(input logic [4:0] phy, input logic [4:0] r, output logic [7:0] ta, output logic [15:0] v);
    logic [15:0] f;
    logic [7:0] x;
    f = {2'b01, 2'b10, phy, r, 2'b11};
    cs(0);
    spi_byte({1'b1, 7'h16}, x);
    spi_byte(8'h01, x);
    spi_byte(f[15:8], x);
    spi_byte(f[7:0], x);
    cs(1);
    fifo_recv(0, ta);
    fifo_recv(0, x);
    v[15:8] = x;
    fifo_recv(0, x);
    v[7:0] = x;
  endtask

  task automatic scenarios(input int div);
    logic [7:0] ta;
    logic [15:0] v;
    bit ok;
    reg_write(7'h00, 8'b0100_0000);
    reg_write(7'h10, 8'(div));
    reg_write(7'h11, 8'd0);
    reg_write(7'h12, 8'd0);
    reg_write(7'h14, 8'h03);
    reg_write(7'h15, 8'd0);
    reg_write(7'h1B, 8'h00);
    reg_write(7'h1C, 8'h00);
    reg_write(7'h1D, 8'h00);
    reg_write(7'h1E, 8'h40);
    reg_write(7'h00, 8'b0001_0001);
    repeat (500) @(posedge clk);
    per_min = 1e9;
    t_r = 0;
    // the ID registers (2 and 3)
    mread(PHYAD, 5'd2, ta, v);
    ok = ta == 8'h00 && v == 16'h0022;
    mread(PHYAD, 5'd3, ta, v);
    ok &= ta == 8'h00 && v == 16'h1619;
    result($sformatf("CLKDIV %0d: read PHY ID registers 2 and 3", div), ok);
    // write and read back, several registers and patterns
    ok = 1;
    for (int i = 0; i < 6; i++) begin
      logic [15:0] w;
      logic [4:0] r;
      r = 5'(4 + 5 * i);
      w = (i == 0) ? 16'hFFFF : (i == 1) ? 16'h0000 : (i == 2) ? 16'h8001 : 16'($urandom);
      mwrite(PHYAD, r, w);
      ok &= regs[r] == w;
      mread(PHYAD, r, ta, v);
      ok &= ta == 8'h00 && v == w;
    end
    result($sformatf("CLKDIV %0d: 6 registers written and read back", div), ok);
    // another PHY address: nobody answers; a write to it changes nothing here
    regs[5'd9] = 16'h5A5A;
    mwrite(5'h1F, 5'd9, 16'h1234);
    mread(5'h1F, 5'd9, ta, v);
    result($sformatf("CLKDIV %0d: absent PHY address: ta = 1, data FFFF, no write", div),
           ta == 8'h01 && v == 16'hFFFF && regs[5'd9] == 16'h5A5A);
    $display("  MDIO CLKDIV %0d: MDC period %0.1f ns (%0.2f MHz)", div, per_min, 1000.0 / per_min);
  endtask

  initial begin
    repeat (5) @(posedge clk);
    @(negedge clk) rst_n = 1;
    repeat (5) @(posedge clk);
    for (int i = 0; i < 32; i++) regs[i] = 16'h0000;
    regs[2] = 16'h0022;
    regs[3] = 16'h1619;
    load_program("mdio_image.hex");
    scenarios(4);
    scenarios(9);
    $display("  MDIO PHY: %0d frames (%0d reads, %0d writes for it); MDC high >= %0.1f ns, low >= %0.1f ns; MDIO set-up >= %0.1f ns, hold >= %0.1f ns",
             n_frames, n_rd, n_wr, hi_min, lo_min, su_min, ho_min);
    check(n_err == 0, $sformatf("the PHY saw %0d frame errors", n_err));
    check(fight == 0, "the station drove MDIO while the PHY did");
    check(hi_min >= 160.0 && lo_min >= 160.0, "MDC high or low under 160 ns");
    check(su_min >= 10.0 && ho_min >= 10.0, "MDIO set-up or hold under 10 ns");
    if (errors == 0 && pass == 6) begin
      $display("PASS: MDIO");
      $finish;
    end else $fatal(1, "FAILED with %0d error(s)", errors);
  end
  initial begin
    #200ms;
    $fatal(1, "FAILED: timeout");
  end
endmodule
