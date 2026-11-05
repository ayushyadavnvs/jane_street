`timescale 1ns / 1ps
// End-to-end tests of the debug-port hosts, through the chip's pins only (D75).
//
//   engine 0: jtag.pbe (word 0), pins 0..3 = TCK, TMS, TDI, TDO, against IEEE 1149.1 TAPs
//             (jtag_tap.sv): one TAP, or a chain of two (TDI -> TAP A -> TAP B -> TDO)
//
// The target models are written from the standards, not from the programs. TMS, TDI and TDO
// have pull-ups (TDO is high-impedance outside Shift-xR); TCK has a pull-down.
// Phases: CLKDIV = 0 (the fastest setting), then CLKDIV = 0xFFFF (the slowest) with the short
// scenario. +ONLY=jtag|slow runs one phase.
module tb_debug;
  localparam real CLK_NS = 20.8333;  // 48 MHz
  localparam int HOST_HALF = 8;      // host SCK = clk / 16

  logic clk = 0, rst_n = 0;
  always #(CLK_NS / 2) clk = ~clk;

  logic [7:0] ui_in = 8'b0000_0010;  // CS_n high
  wire  [7:0] uo_out, uio_out, uio_oe;
  logic [7:0] ext_drive, ext_val;

  // Released pins are pulled up, except TCK (pin 0), which is pulled down, as debug
  // connectors usually do: a restart releases the engine's pins for a few clocks, and a clock
  // line pulled up would rise then, an edge the target would act on.
  localparam logic [7:0] PULL_UP = 8'b1111_1110;
  wire  [7:0] chip_lvl = (~uio_oe & PULL_UP) | (uio_oe & uio_out);
  wire  [7:0] ext_lvl  = ~ext_drive | ext_val;
  wire  [7:0] bus      = chip_lvl & ext_lvl;

  tt_um_ayushyadavnvs_pbe dut (
      .ui_in, .uo_out, .uio_in(bus), .uio_out, .uio_oe, .ena(1'b1), .clk, .rst_n
  );

  // ---------------- JTAG targets ----------------
  // The targets drive TDO TCO ns after the falling edge of TCK: 50 ns, a slow target. At
  // CLKDIV = 0 the program reads TDO 3 clocks (62.5 ns) after that edge (D75).
  localparam real TCO = 50.0;
  localparam logic [31:0] IDCODE_A = 32'h4BA00477, IDCODE_B = 32'h06413041;
  bit chain = 0;  // 0: TAP A alone on TDO; 1: TAP A's TDO feeds TAP B, whose TDO is the chip's
  wire tdo_a, tdo_a_en, tdo_b, tdo_b_en;
  jtag_tap #(.IDCODE(IDCODE_A), .TCO(TCO)) u_tap_a (.tck(bus[0]), .tms(bus[1]), .tdi(bus[2]), .tdo(tdo_a), .tdo_en(tdo_a_en));
  // TAP B's TDI sees TAP A's TDO line (pulled up while A does not drive it)
  jtag_tap #(.IDCODE(IDCODE_B), .USER0(32'hB0B0B0B0), .TCO(TCO)) u_tap_b (
      .tck(bus[0]), .tms(bus[1]), .tdi(tdo_a_en ? tdo_a : 1'b1), .tdo(tdo_b), .tdo_en(tdo_b_en));


  always_comb begin
    ext_drive = '0;
    ext_val = '0;
    ext_drive[3] = chain ? tdo_b_en : tdo_a_en;
    ext_val[3]   = chain ? tdo_b : tdo_a;
  end

`ifdef PBE_SIGROK
  integer sigrok_phase = 0;
  wire p0 = bus[0], p1 = bus[1], p2 = bus[2], p3 = bus[3];
  wire p4 = bus[4], p5 = bus[5];
  initial begin
    $dumpfile("tb_debug_pins.vcd");
    $dumpvars(0, p0, p1, p2, p3, p4, p5, sigrok_phase);
  end
`endif

  `include "tb_host.svh"

  // ---------------- host side ----------------
  logic [7:0] q0[$], q1[$];  // bytes queued for engine 0's and engine 1's TX FIFO (q1 unused)
  // Burst engine e's queue into its TX FIFO in one SPI transaction, pausing while TX is full
  // (uo_out[6 + e]), as a host with flow control would.
  task automatic flush(input int e);
    logic [7:0] d;
    cs(0);
    spi_byte({1'b1, e ? 7'h26 : 7'h16}, d);
    while (e ? q1.size() : q0.size()) begin
      while (uo_out[6+e]) @(posedge clk);
      d = e ? q1.pop_front() : q0.pop_front();  // (a pop passed as an argument crashes Icarus 12)
      spi_byte(d, d);
    end
    cs(1);
  endtask
  // one RX byte: wait on the RX-not-empty pin (uo_out[4 + e]) without using the SPI port
  longint rx_wait = 2_000_000;  // clocks
  task automatic rx(input int e, output logic [7:0] d);
    longint n = 0;
    while (!uo_out[4+e] && n < rx_wait) begin
      @(posedge clk);
      n++;
    end
    check(uo_out[4+e], $sformatf("engine %0d: no RX byte", e));
    reg_read(e ? 7'h26 : 7'h16, d);
  endtask

  // ---------------- timing checks on the pins ----------------
  // JTAG (1149.1): TMS and TDI change only while TCK is low, and are set up before it rises.
  bit jt_on = 0;
  realtime jt_chg = 0, jt_rise = 0, jt_fall = 0;
  real jt_hi = 1e9, jt_lo = 1e9, jt_per = 1e9, jt_setup = 1e9;
  int jt_bad = 0;
  always @(bus[1] or bus[2]) if (jt_on) begin
    if (bus[0]) begin
      jt_bad++;
      if (jt_bad < 4) $display("  JTAG: TMS/TDI changed while TCK was high at %0t", $time);
    end
    jt_chg = $realtime;
  end
  always @(posedge bus[0]) if (jt_on) begin
    if ($realtime - jt_chg < jt_setup) jt_setup = $realtime - jt_chg;
    if (jt_fall > 0 && $realtime - jt_fall < jt_lo) jt_lo = $realtime - jt_fall;
    if (jt_rise > 0 && $realtime - jt_rise < jt_per) jt_per = $realtime - jt_rise;
    jt_rise = $realtime;
  end
  always @(negedge bus[0]) if (jt_on) begin
    if (jt_rise > 0 && $realtime - jt_rise < jt_hi) jt_hi = $realtime - jt_rise;
    jt_fall = $realtime;
  end

  // ================= JTAG host (engine 0) =================
  // records: [0][n-1][tms], [1][n-1][tdi], [2][n-1][tdi] (see jtag.pbe)
  task automatic jt_tms(input int n, input logic [7:0] bits);
    q0.push_back(8'h00);
    q0.push_back(8'(n - 1));
    q0.push_back(bits);
  endtask
  // From Run-Test/Idle: an IR or DR scan of n bits (n <= 64), back to Run-Test/Idle.
  task automatic jt_scan(input bit ir, input int n, input logic [63:0] tdi, output logic [63:0] tdo);
    int chunks, left, k;
    logic [7:0] b;
    if (ir) jt_tms(4, 8'b0011);   // Select-DR, Select-IR, Capture-IR, Shift-IR
    else    jt_tms(3, 8'b001);    // Select-DR, Capture-DR, Shift-DR
    chunks = (n + 7) / 8;
    for (int c = 0; c < chunks; c++) begin
      k = (c == chunks - 1) ? n - 8 * c : 8;
      q0.push_back((c == chunks - 1) ? 8'h02 : 8'h01);
      q0.push_back(8'(k - 1));
      q0.push_back(8'(tdi >> (8 * c)));
    end
    jt_tms(2, 8'b01);             // Update-xR, Run-Test/Idle
    flush(0);
    tdo = '0;
    for (int c = 0; c < chunks; c++) begin
      k = (c == chunks - 1) ? n - 8 * c : 8;
      rx(0, b);
      tdo |= 64'(b >> (8 - k)) << (8 * c);
    end
`ifdef PBE_SIGROK
    $display("SIGROK_JTAG %s %0d %0x %0x", ir ? "IR" : "DR", n, tdi & ((64'd1 << n) - 1), tdo);
`endif
  endtask
  task automatic jt_reset;  // Test-Logic-Reset from any state, then Run-Test/Idle
    jt_tms(6, 8'b011111);
    flush(0);
  endtask

  int jt_pass = 0;
  task automatic jt_result(input string name, input bit ok);
    check(ok, name);
    if (ok) jt_pass++;
    $display("  JTAG %-40s %s", name, ok ? "PASS" : "FAIL");
  endtask

  // the JTAG scenarios; `full` adds the chain (the slow phase runs only the IDCODE read)
  task automatic jtag_scenarios(input bit full);
    logic [63:0] o;
    bit ok;
    chain = 0;
    // 1: Test-Logic-Reset selects IDCODE: a DR scan reads it
    jt_reset;
    jt_scan(0, 32, 64'hFFFF_FFFF, o);
    jt_result($sformatf("reset + IDCODE read (%08x)", o[31:0]), o[31:0] == IDCODE_A);
    if (full) begin
    // 2: IR scan selecting BYPASS (Capture-IR shifts out 0001), then a 1-bit delay
    jt_scan(1, 4, 64'hF, o);
    ok = o[3:0] == 4'b0001;
    jt_scan(0, 16, 64'hA5C3, o);
    jt_result("IR = BYPASS, 16-bit DR scan delayed by 1", ok && o[15:0] == 16'h4B86);
    // 3: USER: write a 32-bit value, read it back while writing another
    jt_scan(1, 4, 64'b1010, o);
    jt_scan(0, 32, 64'hDEAD_BEEF, o);
    ok = o[31:0] == 32'h0;            // the power-up value, captured
    jt_scan(0, 32, 64'h1234_5678, o);
    ok &= o[31:0] == 32'hDEAD_BEEF;
    jt_scan(0, 32, 64'h0, o);
    jt_result("32-bit USER DR write and read-back", ok && o[31:0] == 32'h1234_5678 && u_tap_a.user == 32'h0);
    // 4: short scans, one record each: 1 bit and 7 bits (IR is still USER, USER = 0)
    jt_scan(0, 1, 64'h1, o);          // captures USER bit 0, shifts a 1 in at bit 31
    ok = o[0] == 1'b0 && u_tap_a.user == 32'h8000_0000;
    jt_scan(0, 7, 64'h55, o);         // captures bits 6..0 (0); USER = 0x55 << 25 | 0x80000000 >> 7
    ok &= o[6:0] == 7'h0;
    jt_scan(0, 32, 64'h0, o);
    jt_result("1-bit and 7-bit DR scans", ok && o[31:0] == 32'hAB00_0000);
    // 5: a chain of two TAPs: TDI -> A -> B -> TDO
    chain = 1;
    jt_reset;
    jt_scan(0, 64, 64'hFFFF_FFFF_FFFF_FFFF, o);   // both IDCODEs: B's comes out first
    ok = o[31:0] == IDCODE_B && o[63:32] == IDCODE_A;
    jt_scan(1, 8, {56'd0, 4'b1010, 4'b1111}, o);  // B: BYPASS (shifted first), A: USER
    ok &= o[7:0] == 8'h11;                       // both capture 0001
    jt_scan(0, 33, {31'd0, 32'hCAFE_F00D, 1'b0}, o);  // bit 0 lands in B's bypass
    jt_scan(0, 33, 64'd0, o);
    ok &= o[0] == 1'b0 && o[32:1] == 32'hCAFE_F00D && u_tap_a.user == 32'h0 && u_tap_b.user == 32'hB0B0B0B0;
    jt_result("2-TAP chain: IDCODEs, IR 8 bits, DR through BYPASS", ok);
    chain = 0;
    jt_reset;
    end
  endtask

  // ---------------- engine set-up ----------------
  task automatic setup(input logic [15:0] div);
    reg_write(7'h00, 8'b1100_0000);   // stop both, flush their FIFOs
    reg_write(7'h03, 8'hF0);          // pins 4..7 to engine 1 (not running)
    for (int e = 0; e < 1; e++) begin
      logic [6:0] b;
      b = e ? 7'h20 : 7'h10;
      reg_write(b + 0, div[7:0]);
      reg_write(b + 1, div[15:8]);
      reg_write(b + 2, e ? 4 : 0);    // pin base
      reg_write(b + 3, 0);
      reg_write(b + 4, 0);            // LSB first both ways
      reg_write(b + 5, e ? 64 : 0);   // start
      reg_write(b + 'hB, 0);          // CRC off
      reg_write(b + 'hC, 0);          // no timeout
      reg_write(b + 'hD, 0);
      reg_write(b + 'hE, 0);          // even parity
    end
    reg_write(7'h00, 8'b0001_0001);   // restart and run engine 0
  endtask

  task automatic timing_clear;
    jt_per = 1e9; jt_hi = 1e9; jt_lo = 1e9; jt_setup = 1e9; jt_rise = 0; jt_fall = 0;
  endtask
  task automatic report_timing(input string what);
    if (jt_rise > 0)
      $display("  %s TCK:   min period %0.1f ns (%0.2f MHz), high %0.1f, low %0.1f, TMS/TDI setup %0.1f ns",
               what, jt_per, 1000.0 / jt_per, jt_hi, jt_lo, jt_setup);
    timing_clear;
  endtask

  string only;
  initial begin
    if (!$value$plusargs("ONLY=%s", only)) only = "";
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (5) @(posedge clk);
    load_program("debug_image.hex");   // jtag at word 0
    jt_on = 1;

    if (only == "" || only == "jtag") begin
`ifdef PBE_SIGROK
      sigrok_phase = 1;
`endif
      $display("Phase 1: JTAG, CLKDIV = 0");
      setup(16'd0);
      jtag_scenarios(1);
      report_timing("CLKDIV 0");
    end
    if (only == "" || only == "slow") begin
`ifdef PBE_SIGROK
      sigrok_phase = 2;
`endif
      $display("Phase 2: CLKDIV = 0xFFFF (the slowest)");
      rx_wait = 64'd1_000_000_000;
      setup(16'hFFFF);
      timing_clear;
      jtag_scenarios(0);
      report_timing("CLKDIV 0xFFFF");
    end

    check(jt_bad == 0, $sformatf("JTAG: TMS/TDI changed %0d times while TCK was high", jt_bad));
    $display("  JTAG scenarios passed: %0d", jt_pass);
    if (errors == 0) begin
      $display("PASS: debug ports");
      $finish;
    end else $fatal(1, "FAILED with %0d error(s)", errors);
  end

  initial begin
    #3000ms;
    $fatal(1, "FAILED: timeout");
  end
endmodule
