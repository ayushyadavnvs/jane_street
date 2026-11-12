`timescale 1ns / 1ps
// Behavioural models of the 74HC595 and 74HC165, written from their datasheets (TI SN74HC595
// SCLS041, SN74HC165 SCLS116; switching characteristics at VCC = 4.5 V), and a 3-deep chain of
// each (D85). Not derived from gpio_expander.pbe.
//
// 74HC595: an 8-bit shift register and an 8-bit storage register. SRCLK rising: QA' <= SER,
//   each stage <= the one before, QH' = stage H (feeds the next chip's SER). RCLK rising: the
//   storage register (the outputs QA..QH) <= the shift register. SRCLR# high, OE# low (tied).
//   Checks: SER set up >= T_SU before SRCLK rises and held >= T_H after; SRCLK high and low
//   >= T_W; SRCLK rising >= T_SR before RCLK rises (the last bit must be in); RCLK high >= T_W.
// 74HC165: SH/LD# low loads A..H asynchronously (QH = H at once, after T_PD). With SH/LD# high
//   and CLK INH low, CLK rising shifts: A <= SER, each stage <= the one before; QH = stage H,
//   valid T_PD after the edge (and the old value until then). Checks: SH/LD# low >= T_W,
//   SH/LD# high >= T_LD_SU before CLK rises; CLK high and low >= T_W.
module hc595 #(
    parameter real T_SU = 25.0, T_H = 0.0, T_W = 20.0, T_SR = 19.0
) (
    input  wire       ser,
    input  wire       srclk,
    input  wire       rclk,
    output wire       qh_s,   // QH', serial out to the next chip
    output logic [7:0] q = 0  // QH..QA = bit 7..0
);
  logic [7:0] sr = 0;
  assign qh_s = sr[7];
  int n_errors = 0;
  realtime t_ser = 0, t_rise = -1e9, t_fall = -1e9, t_rrise = -1e9;
  always @(ser) begin
    t_ser = $realtime;
    if ($realtime - t_rise < T_H) begin
      n_errors++;
      $display("  74HC595: SER changed %0.1f ns after SRCLK rose (hold %0.1f)", $realtime - t_rise, T_H);
    end
  end
  always @(posedge srclk) begin
    if ($realtime - t_ser < T_SU) begin
      n_errors++;
      $display("  74HC595: SER set up %0.1f ns before SRCLK (needs %0.1f) at %0t", $realtime - t_ser, T_SU, $time);
    end
    if ($realtime - t_fall < T_W) begin
      n_errors++;
      $display("  74HC595: SRCLK low for %0.1f ns", $realtime - t_fall);
    end
    t_rise = $realtime;
    sr = {sr[6:0], ser};
  end
  always @(negedge srclk) begin
    if ($realtime - t_rise < T_W) begin
      n_errors++;
      $display("  74HC595: SRCLK high for %0.1f ns", $realtime - t_rise);
    end
    t_fall = $realtime;
  end
  always @(posedge rclk) begin
    if ($realtime - t_rise < T_SR) begin
      n_errors++;
      $display("  74HC595: RCLK rose %0.1f ns after SRCLK", $realtime - t_rise);
    end
    t_rrise = $realtime;
    q = sr;
  end
  always @(negedge rclk)
    if ($realtime - t_rrise < T_W) begin
      n_errors++;
      $display("  74HC595: RCLK high for %0.1f ns", $realtime - t_rrise);
    end
endmodule

module hc165 #(
    parameter real T_PD = 30.0, T_W = 16.0, T_LD_SU = 25.0
) (
    input  wire [7:0] d,      // H..A = bit 7..0
    input  wire       ser,
    input  wire       clk,
    input  wire       sh_ld_n,
    output logic      qh = 0
);
  logic [7:0] sr = 0;
  int n_errors = 0;
  realtime t_ld_fall = -1e9, t_ld_rise = -1e9, t_rise = -1e9, t_fall = -1e9;
  always @(negedge sh_ld_n) t_ld_fall = $realtime;
  always @(posedge sh_ld_n) begin
    if ($realtime - t_ld_fall < T_W) begin
      n_errors++;
      $display("  74HC165: SH/LD# low for %0.1f ns", $realtime - t_ld_fall);
    end
    t_ld_rise = $realtime;
  end
  // asynchronous parallel load while SH/LD# is low
  always @(*) if (!sh_ld_n) sr = d;
  always @(posedge clk) begin
    if (sh_ld_n) begin
      if ($realtime - t_ld_rise < T_LD_SU) begin
        n_errors++;
        $display("  74HC165: SH/LD# high only %0.1f ns before CLK", $realtime - t_ld_rise);
      end
      if ($realtime - t_fall < T_W) begin
        n_errors++;
        $display("  74HC165: CLK low for %0.1f ns", $realtime - t_fall);
      end
      sr = {sr[6:0], ser};
    end
    t_rise = $realtime;
  end
  always @(negedge clk) begin
    if ($realtime - t_rise < T_W) begin
      n_errors++;
      $display("  74HC165: CLK high for %0.1f ns", $realtime - t_rise);
    end
    t_fall = $realtime;
  end
  // QH follows stage H after the propagation delay (the old value until then)
  always @(sr[7]) qh <= #(T_PD) sr[7];
endmodule

// Three of each. 595: the chip's SDO feeds u_o[0]; u_o[0].QH' -> u_o[1].SER -> ... u_o[2].
// 165: u_i[0].QH is the chip's SDI; u_i[1].QH -> u_i[0].SER; u_i[2].QH -> u_i[1].SER; u_i[2].SER = 0.
module hc_chain #(
    parameter real T_PD = 30.0
) (
    input  wire        sck,
    input  wire        sdo,
    input  wire        rclk,
    input  wire        ld_n,
    output wire        sdi,
    input  wire [23:0] in_pins,   // {chip 2, chip 1, chip 0} inputs, each H..A
    output wire [23:0] out_pins   // {chip 2, chip 1, chip 0} outputs, each QH..QA
);
  wire [2:0] qs;
  wire [2:0] qh;
  hc595 u_o0 (.ser(sdo),   .srclk(sck), .rclk, .qh_s(qs[0]), .q(out_pins[7:0]));
  hc595 u_o1 (.ser(qs[0]), .srclk(sck), .rclk, .qh_s(qs[1]), .q(out_pins[15:8]));
  hc595 u_o2 (.ser(qs[1]), .srclk(sck), .rclk, .qh_s(qs[2]), .q(out_pins[23:16]));
  hc165 #(.T_PD(T_PD)) u_i0 (.d(in_pins[7:0]),   .ser(qh[1]), .clk(sck), .sh_ld_n(ld_n), .qh(qh[0]));
  hc165 #(.T_PD(T_PD)) u_i1 (.d(in_pins[15:8]),  .ser(qh[2]), .clk(sck), .sh_ld_n(ld_n), .qh(qh[1]));
  hc165 #(.T_PD(T_PD)) u_i2 (.d(in_pins[23:16]), .ser(1'b0),  .clk(sck), .sh_ld_n(ld_n), .qh(qh[2]));
  assign sdi = qh[0];
  wire _unused = qs[2];
  function automatic int errors();
    return u_o0.n_errors + u_o1.n_errors + u_o2.n_errors + u_i0.n_errors + u_i1.n_errors + u_i2.n_errors;
  endfunction
endmodule
