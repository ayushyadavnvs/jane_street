`timescale 1ns / 1ps
// End-to-end test of the quad SPI controller (qspi_flash.pbe, D87) through the chip's pins,
// against a quad SPI NOR flash model written from the common command set (qspi_flash_model.sv).
//   engine 0: qspi_flash.pbe at word 0; pins 0..5 = SCK, CS#, IO0, IO1, IO2, IO3.
// IO0-IO3 have pull-ups; CS# a pull-up; SCK a pull-down.
// Scenarios at CLKDIV 0 (the fastest) and CLKDIV 2: JEDEC ID; Read 0x03; Fast Read 0x0B;
// Fast Read Quad Output 0x6B (the required one) of 64 bytes, more than the RX FIFO, read while
// the engine runs; Fast Read Quad I/O 0xEB; Write Enable + Quad Page Program 0x32 + read back.
// The flash and the chip must never drive an IO line at once; SCK is measured in each phase.
module tb_qspi;
  localparam real CLK_NS = 16.6672;  // 60 MHz
  localparam int HOST_HALF = 4;      // host SCK = clk / 8

  logic clk = 0, rst_n = 0;
  always #(CLK_NS / 2) clk = ~clk;

  logic [7:0] ui_in = 8'b0000_0010;
  wire  [7:0] uo_out, uio_out, uio_oe;
  wire  [3:0] f_out, f_oe;
  // pull-ups on CS# and IO0-IO3, a pull-down on SCK; open lines elsewhere read 0
  localparam logic [7:0] PULL_UP = 8'b0011_1110;
  wire  [7:0] chip_lvl = (uio_oe & uio_out) | (~uio_oe & PULL_UP);
  wire  [3:0] io = (f_oe & f_out) | (~f_oe & chip_lvl[5:2]);
  wire  [7:0] bus = {2'b00, io, chip_lvl[1:0]};

  tt_um_ayushyadavnvs_pbe dut (
      .ui_in, .uo_out, .uio_in(bus), .uio_out, .uio_oe, .ena(1'b1), .clk, .rst_n
  );
  qspi_flash_model u_flash (.sck(bus[0]), .cs_n(bus[1]), .io_in(io), .io_out(f_out), .io_oe(f_oe));

`ifdef PBE_SIGROK
  wire p0 = bus[0], p1 = bus[1], p2 = bus[2], p3 = bus[3], p4 = bus[4], p5 = bus[5];
  initial begin
    $dumpfile("tb_qspi_pins.vcd");
    $dumpvars(0, p0, p1, p2, p3, p4, p5);
  end
`endif

  `include "tb_host.svh"

  // the chip and the flash never drive the same IO line
  int fight = 0;
  always @(posedge clk) if (|(uio_oe[5:2] & f_oe)) fight++;

  // SCK: shortest period and phases (reset per measurement)
  realtime t_r = 0, t_f = 0;
  real per = 1e9, hi = 1e9, lo = 1e9;
  always @(posedge bus[0]) begin
    if (t_r > 0 && $realtime - t_r < per) per = $realtime - t_r;
    if (t_f > 0 && $realtime - t_f < lo) lo = $realtime - t_f;
    t_r = $realtime;
  end
  always @(negedge bus[0]) begin
    if (t_r > 0 && $realtime - t_r < hi) hi = $realtime - t_r;
    t_f = $realtime;
  end
  task automatic meas_reset;
    per = 1e9; hi = 1e9; lo = 1e9; t_r = 0; t_f = 0;
  endtask

  // ---------------- host side ----------------
  logic [7:0] q[$];      // bytes for the TX FIFO
  logic [7:0] single[$]; // the single-line bytes of the current transaction (for sigrok)
  task automatic flush;  // one burst, pausing while the TX FIFO is full
    logic [7:0] d;
    cs(0);
    spi_byte({1'b1, 7'h16}, d);
    while (q.size()) begin
      while (uo_out[6]) @(negedge clk);
      d = q.pop_front();
      spi_byte(d, d);
    end
    cs(1);
  endtask
  task automatic rx(output logic [7:0] d);
    longint n = 0;
    while (!uo_out[4] && n < 2_000_000) begin
      @(posedge clk);
      n++;
    end
    check(uo_out[4], "no RX byte");
    reg_read(7'h16, d);
  endtask
  // single write of n (1..4) bytes; quad write of the bytes in wq
  task automatic swrite(input int n, input logic [31:0] b);  // b: the first byte in [31:24]
    logic [7:0] x;
    q.push_back(8'h01);
    q.push_back(8'(n - 1));
    for (int i = 0; i < n; i++) begin
      x = b[31 - 8 * i -: 8];
      q.push_back(x);
      single.push_back(x);
    end
  endtask
  logic [7:0] wq[$];
  task automatic qwrite;
    q.push_back(8'h03);
    q.push_back(8'(wq.size() - 1));
    foreach (wq[i]) q.push_back(wq[i]);
  endtask
  task automatic phase(input logic [7:0] t, input int n);
    q.push_back(t);
    q.push_back(8'(n - 1));
  endtask
  task automatic finish_txn;
    string s = "";
    q.push_back(8'h00);
    flush;
`ifdef PBE_SIGROK
    foreach (single[i]) s = {s, $sformatf("%02x", single[i])};
    $display("SIGROK_QSPI %s", s);
`endif
    single = {};
  endtask
  logic [7:0] d[$];      // the bytes of the last read_n
  task automatic read_n(input int n);
    logic [7:0] b;
    d = {};
    for (int i = 0; i < n; i++) begin
      rx(b);
      d.push_back(b);
    end
  endtask

  int pass = 0;
  task automatic result(input string name, input bit ok);
    check(ok, name);
    if (ok) pass++;
    $display("  QSPI %-58s %s", name, ok ? "PASS" : "FAIL");
  endtask
  function automatic bit same(input int a);
    for (int i = 0; i < d.size(); i++) if (d[i] !== u_flash.mem[(a + i) % u_flash.SIZE]) return 0;
    return 1;
  endfunction
  function automatic string sck_str();
    return $sformatf("SCK %0.2f MHz (high %0.1f, low %0.1f ns)", 1000.0 / per, hi, lo);
  endfunction

  task automatic setup(input logic [15:0] div);
    reg_write(7'h00, 8'b0100_0000);   // stop, flush
    reg_write(7'h10, div[7:0]);
    reg_write(7'h11, div[15:8]);
    reg_write(7'h12, 8'd0);
    reg_write(7'h14, 8'h03);          // MSB first both ways
    reg_write(7'h15, 8'd0);
    reg_write(7'h1B, 8'h00);
    reg_write(7'h1C, 8'h00);
    reg_write(7'h1D, 8'h00);
    reg_write(7'h1E, 8'h40);
    reg_write(7'h00, 8'b0001_0001);
  endtask

  task automatic scenarios(input logic [15:0] div);
    int a;
    string m;
    bit ok;
    // JEDEC ID
    swrite(1, {8'h9F, 8'h00, 8'h00, 8'h00});
    phase(8'h02, 3);
    finish_txn;
    read_n(3);
    result($sformatf("CLKDIV %0d: JEDEC ID 9F (%02x %02x %02x)", div, d[0], d[1], d[2]),
           d[0] == 8'hEF && d[1] == 8'h40 && d[2] == 8'h16);
    // Read 0x03, 1-1-1, single read SCK
    a = 12'h1F0;
    swrite(4, {8'h03, 8'h00, 8'(a >> 8), 8'(a)});
    meas_reset;
    phase(8'h02, 8);
    finish_txn;
    read_n(8);
    result($sformatf("CLKDIV %0d: Read 03, 8 bytes", div), same(a));
    // Fast Read 0x0B, 8 dummy clocks
    a = 12'h7FC;
    swrite(4, {8'h0B, 8'h00, 8'(a >> 8), 8'(a)});
    phase(8'h05, 8);
    phase(8'h02, 6);
    finish_txn;
    read_n(6);
    result($sformatf("CLKDIV %0d: Fast Read 0B, 6 bytes", div), same(a));
    // Fast Read Quad Output 0x6B, 64 bytes: more than the RX FIFO, read while it runs
    a = 12'h0A3;
    swrite(4, {8'h6B, 8'h00, 8'(a >> 8), 8'(a)});
    phase(8'h05, 8);
    phase(8'h04, 64);
    finish_txn;
    meas_reset;
    read_n(64);
    result($sformatf("CLKDIV %0d: Fast Read Quad Output 6B (1-1-4), 64 bytes", div), same(a));
    // Fast Read Quad I/O 0xEB: address and mode quad, 4 dummy clocks
    a = 12'hC40;
    swrite(1, {8'hEB, 8'h00, 8'h00, 8'h00});
    wq = {};
    wq.push_back(8'h00); wq.push_back(8'(a >> 8)); wq.push_back(8'(a)); wq.push_back(8'h00);
    qwrite;
    phase(8'h05, 4);
    phase(8'h04, 16);
    finish_txn;
    read_n(16);
    result($sformatf("CLKDIV %0d: Fast Read Quad I/O EB (1-4-4), 16 bytes", div), same(a));
    // Write Enable, Quad Page Program 0x32 (24 bytes), read back with 6B
    a = 12'h310 + div;
    swrite(1, {8'h06, 8'h00, 8'h00, 8'h00});
    finish_txn;
    begin
      wq = {};
      for (int i = 0; i < 24; i++) wq.push_back(8'($urandom));
      swrite(4, {8'h32, 8'h00, 8'(a >> 8), 8'(a)});
      qwrite;
      finish_txn;
      swrite(1, {8'h05, 8'h00, 8'h00, 8'h00});              // status: WEL cleared by the program
      phase(8'h02, 1);
      finish_txn;
      read_n(1);
      m = $sformatf("%02x", d[0]);
      swrite(4, {8'h6B, 8'h00, 8'(a >> 8), 8'(a)});
      phase(8'h05, 8);
      phase(8'h04, 24);
      finish_txn;
      read_n(24);
      ok = m == "00";
      for (int i = 0; i < 24; i++) ok &= d[i] === wq[i];
      result($sformatf("CLKDIV %0d: WREN, Quad Page Program 32, 24 bytes back (SR %s)", div, m), ok);
    end
  endtask

  initial begin
    repeat (5) @(posedge clk);
    @(negedge clk) rst_n = 1;
    repeat (5) @(posedge clk);
    for (int i = 0; i < 4096; i++) u_flash.mem[i] = $urandom;
    load_program("qspi_image.hex");

    setup(16'd0);
    // the SCK rates at CLKDIV 0, one phase type at a time
    begin
      meas_reset;
      swrite(4, {8'h03, 8'h00, 8'h00, 8'h00});
      flush;
      wait_tx_empty(0);
      repeat (200) @(posedge clk);
      $display("  CLKDIV 0 single write: %s", sck_str());
      meas_reset;
      phase(8'h02, 4);
      finish_txn;
      read_n(4);
      $display("  CLKDIV 0 single read:  %s", sck_str());
      meas_reset;
      swrite(4, {8'h6B, 8'h00, 8'h00, 8'h00});
      flush;
      wait_tx_empty(0);
      repeat (200) @(posedge clk);
      meas_reset;
      phase(8'h05, 8);
      flush;
      wait_tx_empty(0);
      repeat (200) @(posedge clk);
      $display("  CLKDIV 0 dummy:        %s", sck_str());
      meas_reset;
      phase(8'h04, 8);
      finish_txn;
      read_n(8);
      $display("  CLKDIV 0 quad read:    %s", sck_str());
      meas_reset;
      swrite(1, {8'h06, 8'h00, 8'h00, 8'h00});
      finish_txn;
      swrite(4, {8'h32, 8'h00, 8'h0F, 8'h00});
      flush;
      wait_tx_empty(0);
      repeat (200) @(posedge clk);
      meas_reset;
      wq = {};
      wq.push_back(8'h12); wq.push_back(8'h34); wq.push_back(8'h56); wq.push_back(8'h78);
      qwrite;
      finish_txn;
      repeat (200) @(posedge clk);
      $display("  CLKDIV 0 quad write:   %s", sck_str());
    end
    scenarios(16'd0);
    setup(16'd2);
    scenarios(16'd2);

    check(u_flash.n_errors == 0, $sformatf("the flash model saw %0d protocol/timing errors", u_flash.n_errors));
    check(fight == 0, $sformatf("the chip and the flash drove an IO line at once for %0d clocks", fight));
    $display("  QSPI scenarios passed: %0d of 12; flash: %0d commands", pass, u_flash.n_cmds);
    if (errors == 0 && pass == 12) begin
      $display("PASS: QSPI");
      $finish;
    end else $fatal(1, "FAILED with %0d error(s)", errors);
  end

  initial begin
    #100ms;
    $fatal(1, "FAILED: timeout");
  end
endmodule
