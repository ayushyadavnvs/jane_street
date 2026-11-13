`timescale 1ns / 1ps
// End-to-end tests of the debug-port hosts, through the chip's pins only (D75, D76).
//
//   engine 0: jtag.pbe (word 0), pins 0..3 = TCK, TMS, TDI, TDO, against IEEE 1149.1 TAPs
//             (jtag_tap.sv): one TAP, or a chain of two (TDI -> TAP A -> TAP B -> TDO)
//   engine 1: swd.pbe (word 192 of its own memory, D82), pins 4..5 = SWCLK, SWDIO, against an ADIv5 SW-DP (swd_dp.sv)
//
// The target models are written from the standards, not from the programs. SWDIO, TMS, TDI
// and TDO have pull-ups (SWDIO needs one, ADIv5 B4.1.1; TDO is high-impedance outside
// Shift-xR); TCK and SWCLK have pull-downs.
// Phases: each protocol alone at CLKDIV = 0 (the fastest setting), then both concurrently at
// CLKDIV = 0, then both concurrently at CLKDIV = 0xFFFF (the slowest) with the short scenarios.
// +ONLY=jtag|swd|both|slow runs one phase.
module tb_debug;
  localparam real CLK_NS = 16.6672;  // 60 MHz
  localparam int HOST_HALF = 8;      // host SCK = clk / 16

  logic clk = 0, rst_n = 0;
  always #(CLK_NS / 2) clk = ~clk;

  logic [7:0] ui_in = 8'b0000_0010;  // CS_n high
  wire  [7:0] uo_out, uio_out, uio_oe;
  logic [7:0] ext_drive, ext_val;

  // Released pins are pulled up, except TCK (pin 0) and SWCLK (pin 4), which are pulled down,
  // as debug connectors usually do: a restart releases the engine's pins for a few clocks, and
  // a clock line pulled up would rise then, an edge the target would act on (BUG-095).
  localparam logic [7:0] PULL_UP = 8'b1110_1110;
  wire  [7:0] chip_lvl = (~uio_oe & PULL_UP) | (uio_oe & uio_out);
  wire  [7:0] ext_lvl  = ~ext_drive | ext_val;
  wire  [7:0] bus      = chip_lvl & ext_lvl;

  tt_um_ayushyadavnvs_pbe dut (
      .ui_in, .uo_out, .uio_in(bus), .uio_out, .uio_oe, .ena(1'b1), .clk, .rst_n
  );

  // ---------------- JTAG targets ----------------
  // The targets drive TDO and SWDIO TCO ns after their clock edge: 50 ns, a slow target. At
  // CLKDIV = 0 the programs read a target's bit 3 clocks (62.5 ns) after the edge that launched
  // it (D75, D76); measured: TCO = 60 ns passes, 66 ns fails (BUG-096: 42 ns before).
  // PBE_TCO overrides it (make sigrok-debug, D77).
`ifdef PBE_TCO
  localparam real TCO = `PBE_TCO;
`else
  localparam real TCO = 50.0;
`endif
  localparam logic [31:0] IDCODE_A = 32'h4BA00477, IDCODE_B = 32'h06413041;
  bit chain = 0;  // 0: TAP A alone on TDO; 1: TAP A's TDO feeds TAP B, whose TDO is the chip's
  wire tdo_a, tdo_a_en, tdo_b, tdo_b_en;
  jtag_tap #(.IDCODE(IDCODE_A), .TCO(TCO)) u_tap_a (.tck(bus[0]), .tms(bus[1]), .tdi(bus[2]), .tdo(tdo_a), .tdo_en(tdo_a_en));
  // TAP B's TDI sees TAP A's TDO line (pulled up while A does not drive it)
  jtag_tap #(.IDCODE(IDCODE_B), .USER0(32'hB0B0B0B0), .TCO(TCO)) u_tap_b (
      .tck(bus[0]), .tms(bus[1]), .tdi(tdo_a_en ? tdo_a : 1'b1), .tdo(tdo_b), .tdo_en(tdo_b_en));

  // ---------------- SWD target ----------------
  localparam logic [31:0] DPIDR = 32'h2BA01477, AP_IDR = 32'h24770011;
  wire swd_drive, swd_dout;
  swd_dp #(.DPIDR(DPIDR), .AP_IDR(AP_IDR), .TCO(TCO)) u_dp (.swclk(bus[4]), .swdio(bus[5]), .drive(swd_drive), .dout(swd_dout));

  always_comb begin
    ext_drive = '0;
    ext_val = '0;
    ext_drive[3] = chain ? tdo_b_en : tdo_a_en;
    ext_val[3]   = chain ? tdo_b : tdo_a;
    ext_drive[5] = swd_drive;
    ext_val[5]   = swd_dout;
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
  logic [7:0] q0[$], q1[$];  // bytes queued for engine 0's and engine 1's TX FIFO
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
  // SWD (ADIv5): the host changes SWDIO only while SWCLK is low; the host and the target never
  // drive SWDIO at once.
  bit jt_on = 0, sw_on = 0;
  realtime jt_chg = 0, jt_rise = 0, jt_fall = 0, sw_chg = 0, sw_rise = 0, sw_fall = 0;
  real jt_hi = 1e9, jt_lo = 1e9, jt_per = 1e9, jt_setup = 1e9;
  real sw_hi = 1e9, sw_lo = 1e9, sw_per = 1e9, sw_setup = 1e9;
  int jt_bad = 0, sw_bad = 0, sw_fight = 0;
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
  always @(chip_lvl[5]) if (sw_on && uio_oe[5]) begin
    if (bus[4]) begin
      sw_bad++;
      if (sw_bad < 4) $display("  SWD: the host changed SWDIO while SWCLK was high at %0t", $time);
    end
    sw_chg = $realtime;
  end
  always @(posedge bus[4]) if (sw_on) begin
    if (uio_oe[5] && $realtime - sw_chg < sw_setup) sw_setup = $realtime - sw_chg;
    if (sw_fall > 0 && $realtime - sw_fall < sw_lo) sw_lo = $realtime - sw_fall;
    if (sw_rise > 0 && $realtime - sw_rise < sw_per) sw_per = $realtime - sw_rise;
    sw_rise = $realtime;
  end
  always @(negedge bus[4]) if (sw_on) begin
    if (sw_rise > 0 && $realtime - sw_rise < sw_hi) sw_hi = $realtime - sw_rise;
    sw_fall = $realtime;
  end
  always @(posedge clk) if (sw_on && uio_oe[5] && swd_drive) sw_fight++;

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

  // ================= SWD host (engine 1) =================
  // records: [0][byte] raw 8 bits; [1][req] read; [2][req][d0..d3][parity] write (see swd.pbe)
  function automatic logic [7:0] sw_req(input bit ap, input bit r, input logic [3:0] addr);
    logic [1:0] a;
    a = addr[3:2];
    return {1'b1, 1'b0, ^{ap, r, a}, a[1], a[0], r, ap, 1'b1};
  endfunction
  task automatic sw_raw(input logic [7:0] b);
    q1.push_back(8'h00);
    q1.push_back(b);
  endtask
  task automatic sw_line_reset;  // 56 ones, 8 idle cycles
    for (int i = 0; i < 7; i++) sw_raw(8'hFF);
    sw_raw(8'h00);
    flush(1);
`ifdef PBE_SIGROK
    $display("SIGROK_SWD LINERESET");
`endif
  endtask
  task automatic sw_switch;  // line reset, 0xE79E, line reset, idle (ADIv5 B5.2.1)
    for (int i = 0; i < 7; i++) sw_raw(8'hFF);
    sw_raw(8'h9E);
    sw_raw(8'hE7);
    for (int i = 0; i < 7; i++) sw_raw(8'hFF);
    sw_raw(8'h00);
    flush(1);
`ifdef PBE_SIGROK
    $display("SIGROK_SWD SWITCH");
`endif
  endtask
  // ack: the RX byte (ACK bits 0..2 in bits 5..7: OK 0x20, WAIT 0x40, FAULT 0x80)
  task automatic sw_read(input bit ap, input logic [3:0] addr, output logic [7:0] ack,
                         output logic [31:0] d, output bit perr);
    logic [7:0] b;
    q1.push_back(8'h01);
    q1.push_back(sw_req(ap, 1, addr));
    flush(1);
    rx(1, ack);
    d = 'x;
    perr = 0;
    if (ack == 8'h20) begin
      for (int i = 0; i < 4; i++) begin
        rx(1, b);
        d[8*i +: 8] = b;
      end
      rx(1, b);
      perr = b[0];
    end
`ifdef PBE_SIGROK
    $display("SIGROK_SWD %s R %0x %02x %08x %0d", ap ? "AP" : "DP", addr, ack, d, perr);
`endif
  endtask
  task automatic sw_write(input bit ap, input logic [3:0] addr, input logic [31:0] d,
                          input bit bad_par, output logic [7:0] ack);
    q1.push_back(8'h02);
    q1.push_back(sw_req(ap, 0, addr));
    for (int i = 0; i < 4; i++) q1.push_back(d[8*i +: 8]);
    q1.push_back(8'(^d ^ bad_par));  // parity, then 7 idle cycles
    flush(1);
    rx(1, ack);
`ifdef PBE_SIGROK
    $display("SIGROK_SWD %s W %0x %02x %08x %0d", ap ? "AP" : "DP", addr, ack, d, bad_par);
`endif
  endtask

  int sw_pass = 0;
  task automatic sw_result(input string name, input bit ok);
    check(ok, name);
    if (ok) sw_pass++;
    $display("  SWD  %-40s %s", name, ok ? "PASS" : "FAIL");
  endtask

  task automatic swd_scenarios(input bit full);
    logic [7:0] ack;
    logic [31:0] d;
    bit perr, ok;
    int n0, n1;
    // 1: the JTAG-to-SWD switch (the port starts in JTAG mode), line reset, DPIDR read
    sw_switch;
    sw_read(0, 4'h0, ack, d, perr);
    sw_result($sformatf("switch + line reset + DPIDR (%08x)", d), ack == 8'h20 && d == DPIDR && !perr);
    if (full) begin
    // 2: DP and AP registers: CTRL/STAT power-up, SELECT, TAR/DRW, AP read through RDBUFF
    sw_write(0, 4'h4, 32'h5000_0000, 0, ack);  ok = ack == 8'h20;
    sw_read(0, 4'h4, ack, d, perr);            ok &= ack == 8'h20 && d == 32'hF000_0000 && !perr;
    sw_write(0, 4'h8, 32'h0000_0000, 0, ack);  ok &= ack == 8'h20;   // AP 0, bank 0
    sw_write(1, 4'h4, 32'h0000_0008, 0, ack);  ok &= ack == 8'h20;   // TAR = 8 (mem[2])
    sw_write(1, 4'hC, 32'hA5A5_0F0F, 0, ack);  ok &= ack == 8'h20;   // DRW
    sw_read(1, 4'hC, ack, d, perr);            ok &= ack == 8'h20 && !perr;  // posted
    sw_read(0, 4'hC, ack, d, perr);            ok &= ack == 8'h20 && d == 32'hA5A5_0F0F && !perr;
    sw_write(0, 4'h8, 32'h0000_00F0, 0, ack);  ok &= ack == 8'h20;   // bank 0xF
    sw_read(1, 4'hC, ack, d, perr);            ok &= ack == 8'h20;   // IDR, posted
    sw_read(0, 4'hC, ack, d, perr);            ok &= ack == 8'h20 && d == AP_IDR;
    sw_write(0, 4'h8, 32'h0000_0000, 0, ack);  ok &= ack == 8'h20;
    sw_result("DP + AP write/read, AP read via RDBUFF", ok && u_dp.mem[2] == 32'hA5A5_0F0F);
    // 3: WAIT, then a retry: a read waits twice, a write once (its data phase is dropped)
    u_dp.wait_n = 2;
    sw_read(1, 4'h4, ack, d, perr);            ok = ack == 8'h40;
    sw_read(1, 4'h4, ack, d, perr);            ok &= ack == 8'h40;
    sw_read(1, 4'h4, ack, d, perr);            ok &= ack == 8'h20;
    sw_read(0, 4'hC, ack, d, perr);            ok &= ack == 8'h20 && d == 32'h8;   // TAR
    u_dp.wait_n = 1;
    n0 = u_dp.n_writes;
    sw_write(1, 4'h4, 32'h0000_000C, 0, ack);  ok &= ack == 8'h40 && u_dp.n_writes == n0;
    sw_write(1, 4'h4, 32'h0000_000C, 0, ack);  ok &= ack == 8'h20 && u_dp.tar == 32'hC;
    sw_read(0, 4'h0, ack, d, perr);            ok &= ack == 8'h20 && d == DPIDR;  // in step
    sw_result("WAIT then retry (read and write)", ok && u_dp.n_writes == n0 + 1);
    // 4: FAULT: an AP access fails; sticky until ABORT.STKERRCLR
    u_dp.fault_next = 1;
    sw_read(1, 4'hC, ack, d, perr);            ok = ack == 8'h80;
    sw_write(1, 4'hC, 32'h1, 0, ack);          ok &= ack == 8'h80;   // still sticky
    sw_read(0, 4'h4, ack, d, perr);            ok &= ack == 8'h20 && d[5];  // STICKYERR
    sw_write(0, 4'h0, 32'h0000_0004, 0, ack);  ok &= ack == 8'h20;   // ABORT.STKERRCLR
    sw_read(0, 4'h4, ack, d, perr);            ok &= ack == 8'h20 && !d[5];
    sw_read(1, 4'hC, ack, d, perr);            ok &= ack == 8'h20;
    sw_result("FAULT, sticky, cleared by ABORT", ok && u_dp.mem[3] != 32'h1);
    // 5: the target sends read data with a wrong parity bit: reported
    u_dp.bad_par_next = 1;
    sw_read(0, 4'h0, ack, d, perr);            ok = ack == 8'h20 && d == DPIDR && perr;
    sw_read(0, 4'h0, ack, d, perr);            ok &= ack == 8'h20 && !perr;
    sw_result("target data parity error detected", ok);
    // 6: the host sends a write with a wrong parity bit: the target drops it, WDATAERR
    n0 = u_dp.n_writes;
    n1 = u_dp.n_wdataerr;
    sw_write(1, 4'h4, 32'h0000_0010, 1, ack);  ok = ack == 8'h20 && u_dp.n_writes == n0 && u_dp.tar == 32'hC;
    sw_read(1, 4'h4, ack, d, perr);            ok &= ack == 8'h80;   // FAULT while WDATAERR
    sw_read(0, 4'h4, ack, d, perr);            ok &= ack == 8'h20 && d[7];
    sw_write(0, 4'h0, 32'h0000_0008, 0, ack);  ok &= ack == 8'h20;   // ABORT.WDERRCLR
    sw_write(1, 4'h4, 32'h0000_0010, 0, ack);  ok &= ack == 8'h20 && u_dp.tar == 32'h10;
    sw_result("write parity error rejected by the target", ok && u_dp.n_wdataerr == n1 + 1);
    // 7: a line reset, then the DPIDR read it requires
    sw_line_reset;
    sw_read(0, 4'h0, ack, d, perr);
    sw_result("line reset + DPIDR", ack == 8'h20 && d == DPIDR);
    end
  endtask

  // ---------------- engine set-up ----------------
  task automatic setup(input logic [15:0] div);
    reg_write(7'h00, 8'b1100_0000);   // stop both, flush their FIFOs
    reg_write(7'h03, 8'hF0);          // pins 4..7 to engine 1
    for (int e = 0; e < 2; e++) begin
      logic [6:0] b;
      b = e ? 7'h20 : 7'h10;
      reg_write(b + 0, div[7:0]);
      reg_write(b + 1, div[15:8]);
      reg_write(b + 2, e ? 4 : 0);    // pin base
      reg_write(b + 3, 0);
      reg_write(b + 4, 0);            // LSB first both ways
      reg_write(b + 5, e ? 192 : 0);  // start: swd ends at word 255 of engine 1's memory
      reg_write(b + 'hB, 0);          // CRC off
      reg_write(b + 'hC, 0);          // no timeout
      reg_write(b + 'hD, 0);
      reg_write(b + 'hE, 0);          // even parity
    end
    reg_write(7'h00, 8'b0011_0011);   // restart and run both
  endtask

  task automatic timing_clear;
    jt_per = 1e9; jt_hi = 1e9; jt_lo = 1e9; jt_setup = 1e9; jt_rise = 0; jt_fall = 0;
    sw_per = 1e9; sw_hi = 1e9; sw_lo = 1e9; sw_setup = 1e9; sw_rise = 0; sw_fall = 0;
  endtask
  task automatic report_timing(input string what);
    if (jt_rise > 0)
      $display("  %s TCK:   min period %0.1f ns (%0.2f MHz), high %0.1f, low %0.1f, TMS/TDI setup %0.1f ns",
               what, jt_per, 1000.0 / jt_per, jt_hi, jt_lo, jt_setup);
    if (sw_rise > 0)
      $display("  %s SWCLK: min period %0.1f ns (%0.2f MHz), high %0.1f, low %0.1f, SWDIO setup %0.1f ns",
               what, sw_per, 1000.0 / sw_per, sw_hi, sw_lo, sw_setup);
    timing_clear;
  endtask

  string only;
  initial begin
    if (!$value$plusargs("ONLY=%s", only)) only = "";
    repeat (5) @(posedge clk);
    @(negedge clk) rst_n = 1;  // released between edges, not at one (BUG-102)
    repeat (5) @(posedge clk);
    load_program("debug_image.hex");   // jtag at engine 0 word 0, swd at engine 1 word 192
    jt_on = 1;
    sw_on = 1;

    if (only == "" || only == "jtag") begin
`ifdef PBE_SIGROK
      sigrok_phase = 1;
`endif
      $display("Phase 1: JTAG alone, CLKDIV = 0");
      setup(16'd0);
      jtag_scenarios(1);
      report_timing("CLKDIV 0");
    end
    if (only == "" || only == "swd") begin
`ifdef PBE_SIGROK
      sigrok_phase = 2;
`endif
      $display("Phase 2: SWD alone, CLKDIV = 0");
      setup(16'd0);
      swd_scenarios(1);
      report_timing("CLKDIV 0");
    end
    if (only == "" || only == "both") begin
`ifdef PBE_SIGROK
      sigrok_phase = 3;
`endif
      $display("Phase 3: JTAG (engine 0) and SWD (engine 1) concurrently, CLKDIV = 0");
      setup(16'd0);
      fork
        jtag_scenarios(1);
        swd_scenarios(1);
      join
      report_timing("CLKDIV 0");
    end
    if (only == "" || only == "slow") begin
`ifdef PBE_SIGROK
      sigrok_phase = 4;
`endif
      $display("Phase 4: both concurrently, CLKDIV = 0xFFFF (the slowest)");
      // the SW-DP must be in SWD mode first (the switch at full speed: 136 cycles at 0xFFFF
      // would take 45M clocks); then an IDCODE read and a DPIDR read, each about 45 cycles
      if (u_dp.n_switch == 0) begin
        setup(16'd0);
        sw_switch;
      end
      rx_wait = 64'd1_000_000_000;
      setup(16'hFFFF);
      timing_clear;
      fork
        jtag_scenarios(0);
        begin
          logic [7:0] ack;
          logic [31:0] d;
          bit perr;
          sw_read(0, 4'h0, ack, d, perr);
          sw_result($sformatf("DPIDR read (%08x)", d), ack == 8'h20 && d == DPIDR && !perr);
        end
      join
      report_timing("CLKDIV 0xFFFF");
    end

    check(jt_bad == 0, $sformatf("JTAG: TMS/TDI changed %0d times while TCK was high", jt_bad));
    check(sw_bad == 0, $sformatf("SWD: SWDIO changed %0d times while SWCLK was high", sw_bad));
    check(sw_fight == 0, $sformatf("SWD: host and target drove SWDIO together for %0d clocks", sw_fight));
    check(u_dp.n_proto_err == 0, $sformatf("SWD target saw %0d protocol errors", u_dp.n_proto_err));
    $display("  JTAG scenarios passed: %0d; SWD scenarios passed: %0d; SWD target: %0d line resets, %0d switches, %0d OK, %0d WAIT, %0d FAULT",
             jt_pass, sw_pass, u_dp.n_line_reset, u_dp.n_switch, u_dp.n_ok, u_dp.n_wait, u_dp.n_fault);
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
