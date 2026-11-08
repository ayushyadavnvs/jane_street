`timescale 1ns / 1ps
// End-to-end test of programs/can_node.pbe through the chip's pins (D72).
//
// Bus: a wired-AND CAN bus. Each node has its own transceiver model: TXD reaches the bus after
// TXD_NS, the bus reaches RXD after RXD_NS (loop delay 200 ns at the chip's pins, plus the
// chip's 2-clock input synchronizer). Nodes: engine 0 (TXD pin 0, RXD pin 1), engine 1 (TXD pin
// 2, RXD pin 3), and two reference nodes (can_ref_node.sv, written from ISO 11898-1) with clock
// errors of +0.5 % and -0.5 %. A disturber can force the bus dominant to inject errors.
// The host model talks to the chip over SPI only; it reads each record at the IRQ.
//
// Scenarios (each checked against what the reference nodes saw and against the expected
// records and error counters):
//   1. DLC 0..8 and a remote frame, chip -> reference and reference -> chip, at 125k, 250k,
//      500k and 1M (fewer frames at the slow rates); every bit the chip sends is a whole
//      number of bit times long (no resync on its own edges), and both engines receive.
//   2. Arbitration: a reference node (ID 0x100) and engine 0 (ID 0x200) start together after
//      a frame; the reference wins, engine 0 receives its frame intact (status: arbitration
//      lost), then sends its own.
//   3. ACK missing: the only other running node does not acknowledge. Engine 0 repeats the
//      frame; TEC rises by 8 per attempt to 128 (error-passive) and stays there (the passive
//      ACK-error exception); when ACKs come back the frame goes out and TEC drops to 127.
//   4. Injected errors with the chip receiving: a CRC error, a stuff error and a form error
//      from a reference node; the chip's error flag starts in the right bit; the reference
//      retransmits and the chip receives the frame.
//   5. A bit error with the chip transmitting: flag from the next bit, retransmission, TEC 8-1.
//   6. Error-passive and bus-off: every attempt of engine 0 is hit by a bit error. Flags 1-16
//      active, from 17 passive (checked on the chip's TXD), bus-off when TEC passes 255 (no
//      more drive), recovery after 128 x 11 recessive bits, then the frame goes out.
//   7. Engines 0 and 1 as two nodes: frames both ways and arbitration between them.
module tb_can;
  localparam real CLK_NS = 20.8333;   // 48 MHz
  localparam int HOST_HALF = 3;
  localparam real TXD_NS = 80.0, RXD_NS = 120.0;

  logic clk = 0, rst_n = 0;
  always #(CLK_NS / 2) clk = ~clk;

  logic [7:0] ui_in = 8'b0000_0010;
  wire  [7:0] uo_out, uio_out, uio_oe;

  // ---- the bus ----
  wire  e0_txd = uio_oe[0] ? uio_out[0] : 1'b1;
  wire  e1_txd = uio_oe[2] ? uio_out[2] : 1'b1;
  wire  ra_txd, rb_txd;
  logic force_dom = 0;
  wire  e0_t, e1_t, ra_t, rb_t;
  assign #(TXD_NS) e0_t = e0_txd;
  assign #(TXD_NS) e1_t = e1_txd;
  assign #(TXD_NS) ra_t = ra_txd;
  assign #(TXD_NS) rb_t = rb_txd;
  wire  bus = e0_t & e1_t & ra_t & rb_t & !force_dom;
  wire  bus_rx;
  assign #(RXD_NS) bus_rx = bus;
  wire [7:0] uio_in = {4'b1111, bus_rx, 1'b1, bus_rx, 1'b1};

  tt_um_ayushyadavnvs_pbe dut (
      .ui_in, .uo_out, .uio_in, .uio_out, .uio_oe, .ena(1'b1), .clk, .rst_n
  );
  can_ref_node #(.NAME("A")) ra (.rx(bus_rx), .tx(ra_txd));
  can_ref_node #(.NAME("B")) rb (.rx(bus_rx), .tx(rb_txd));

`ifdef PBE_SIGROK
  // the bus for sigrok's can decoder (verify/golden-model/sigrok)
  integer sigrok_phase = 0;
  wire can_bus = bus;
  initial begin
    $dumpfile("tb_can_bus.vcd");
    $dumpvars(0, can_bus, sigrok_phase);
  end
`endif

  `include "tb_host.svh"

  // ---------------- frames ----------------
  // a frame: [79:69] ID, [68] RTR, [67:64] DLC, [63:0] data (byte b is [63-8*b -: 8])
  // [98] IDE (extended), [97:80] extended ID 17..0 (as in can_ref_node.sv)
  typedef logic [98:0] frame_t;
  function automatic int nbytes(input frame_t f);
    return f[68] ? 0 : (f[67:64] > 8 ? 8 : int'(f[67:64]));
  endfunction
  function automatic frame_t mkf(input logic [10:0] id, input bit rtr, input logic [3:0] dlc, input int seed);
    frame_t f;
    f = '0;
    f[79:69] = id; f[68] = rtr; f[67:64] = dlc; f[63:0] = 0;
    for (int b = 0; b < 8; b++) f[63 - 8 * b -: 8] = 8'((seed * 37 + b * 91 + 5) ^ (b * 16));
    if (!rtr) for (int b = dlc > 8 ? 8 : dlc; b < 8; b++) f[63 - 8 * b -: 8] = 0;
    else f[63:0] = 0;
    return f;
  endfunction
  function automatic bit same(input frame_t a, input frame_t b);
    return a[98:80] == b[98:80] && a[79:69] == b[79:69] && a[68] == b[68] && a[67:64] == b[67:64] && a[63:0] == b[63:0];
  endfunction
  function automatic string fs(input frame_t f);
    return $sformatf("id %03x rtr %0d dlc %0d data %016x", f[79:69], f[68], f[67:64], f[63:0]);
  endfunction

  // ---------------- host: send a frame on engine e ----------------
  task automatic chip_send(input int e, input frame_t f);
    fifo_send(e, {1'b0, f[79:73]});
    fifo_send(e, {f[72:69], 4'b0});
    fifo_send(e, {f[68], 2'b00, f[67], 4'b0});
    fifo_send(e, {f[66:64], 5'b0});
    for (int b = 0; b < nbytes(f); b++) fifo_send(e, f[63 - 8 * b -: 8]);
    flag_set(e, 0);
  endtask

  // ---------------- host: records, read at the IRQ ----------------
  // a record: [111:13] frame, [12:5] status, [4:0] bytes in the record
  typedef logic [111:0] rec_t;
  rec_t recs0[$], recs1[$];
  function automatic logic [7:0] st0(input int i);   // status of engine 0's record i
    rec_t r;
    r = recs0[i];
    return r[12:5];
  endfunction
  function automatic bit st0b(input int i, input int k);
    logic [7:0] x;
    x = st0(i);
    return x[k];
  endfunction
  bit   reader_on = 0;
  logic [7:0] rbuf[16];   // the record being read (Icarus 12: no array task arguments)
  task automatic burst_read(input logic [6:0] addr, input int n);
    logic [7:0] d;
    cs(0);
    spi_byte({1'b0, addr}, d);
    for (int i = 0; i < n; i++) begin
      spi_byte(8'h00, d);   // (an array element as an output argument crashes Icarus 12)
      rbuf[i] = d;
    end
    cs(1);
  endtask
  task automatic parse(input int e, input int n);
    rec_t r;
    frame_t rf;
    rf = 0;
    if (n >= 4) begin
      rf[79:69] = {rbuf[0][6:0], rbuf[1][3:0]};
      rf[68] = rbuf[2][3];
      rf[98] = rbuf[2][2];   // IDE: an extended frame's record ends after this unit (D74)
      rf[67:64] = {rbuf[2][0], rbuf[3][2:0]};
      for (int i = 4; i < n - 1 && i < 12; i++) rf[63 - 8 * (i - 4) -: 8] = rbuf[i];
    end
    r = {rf, rbuf[n - 1], 5'(n)};
    if (e == 0) recs0.push_back(r); else recs1.push_back(r);
  endtask
  // At the IRQ: read the RX_COUNT of every engine that raised it first, then exactly that many
  // bytes. The count must be read before the engine's next record starts (at least about 16
  // bit times after the IRQ: intermission, start of frame, the first unit); reading one FIFO
  // in full before the other's count let engine 1's next record leak into this one.
  initial begin : reader
    logic [7:0] irq, cnt;
    logic [7:0] cnts[2];
    forever begin
      @(posedge clk);
      if (reader_on && uo_out[1]) begin
        reg_read(7'h02, irq);
        reg_write(7'h02, irq);
        for (int e = 0; e < 2; e++) if (irq[e]) begin
          reg_read(e ? 7'h0B : 7'h0A, cnt);
          cnts[e] = cnt;
        end
        for (int e = 0; e < 2; e++) if (irq[e]) begin
          cnt = cnts[e];
          if (cnt != 0) begin
            burst_read(e ? 7'h26 : 7'h16, cnt);
            parse(e, cnt);
          end
        end
      end
    end
  end

  // ---------------- chip setup ----------------
  int bit_clk = 96;
  task automatic setup(input int clocks_per_bit, input logic [7:0] line2);
    logic [7:0] d;
    bit_clk = clocks_per_bit;
    // a full chip reset: the CAN error counters survive an engine restart (D68), and each
    // scenario starts error-active; the reference nodes start afresh too
    reader_on = 0;
    repeat (20) @(posedge clk);
    rst_n = 0;
    repeat (5) @(posedge clk);
    @(negedge clk) rst_n = 1;  // released between edges, not at one (BUG-102)
    repeat (5) @(posedge clk);
    load_program("can_image.hex");
    ra.reset_node();
    rb.reset_node();
    recs0.delete(); recs1.delete();
    reader_on = 1;
    reg_write(7'h00, 8'hF0);     // stop, restart and flush both engines
    for (int e = 0; e < 2; e++) begin
      logic [6:0] b, p;
      b = e ? 7'h20 : 7'h10;
      p = e ? 7'h40 : 7'h30;
      reg_write(b + 0, 8'(clocks_per_bit - 1));
      reg_write(b + 1, 8'((clocks_per_bit - 1) >> 8));
      reg_write(b + 2, e ? 8'd2 : 8'd0);   // PIN_BASE
      reg_write(b + 3, 8'd1);              // JMP_PIN = RXD
      reg_write(b + 4, 8'h03);             // MSB first
      reg_write(b + 5, e ? 8'd128 : 8'd0);  // START_PC: engine 1's copy is at word 128 of its memory
      reg_write(b + 9, 8'h99);             // CRC_POLY 0x4599
      reg_write(b + 10, 8'h45);
      reg_write(b + 11, 8'h8E);            // CRC-15, fed by received bits
      reg_write(b + 12, 8'h00);
      reg_write(b + 13, 8'h00);
      reg_write(b + 14, 8'h40 | 8'd45);    // no parity, TIMEOUT_PC = done
      reg_write(p + 0, 8'h2D);             // LINE
      reg_write(p + 1, 8'h00);
      reg_write(p + 2, 8'h00);
      reg_write(p + 3, 8'h00);
      reg_write(p + 4, line2 | 8'h80);     // LINE2, with the CAN frame follower (D74) as can_node wants
    end
    reg_write(7'h03, 8'b0000_1100);      // pins 2, 3 belong to engine 1
    reg_write(7'h00, 8'h30);             // restart both
  endtask
  task automatic run_engines(input logic [1:0] which);
    reg_write(7'h00, {6'b0, which});
  endtask
  task automatic ref_cfg(input real bitns);
    ra.bit_ns = bitns; ra.ppm = 5000.0;
    rb.bit_ns = bitns; rb.ppm = -5000.0;
  endtask
  task automatic wait_bits(input int n);
    repeat (n * bit_clk) @(posedge clk);
  endtask
  task automatic read_tec(input int e, output int tec, output logic [7:0] state);
    logic [7:0] lo;
    reg_read(e ? 7'h45 : 7'h35, lo);
    reg_read(e ? 7'h47 : 7'h37, state);
    tec = {state[0], lo};
  endtask

  // ---------------- bit-time check of what engine 0 drives ----------------
  // While engine 0 alone drives the bus (no foreign edges), every interval between its TXD
  // edges is a whole number of bit times.
  bit   timing_on = 0;
  int   t_last_edge = -1, clk_n = 0, bad_timing = 0, timing_edges = 0;
  int   e0_dom_start = -1, e0_runs[$];
  logic e0_prev = 1;
  always @(posedge clk) begin
    clk_n++;
    if (timing_on && e0_txd != e0_prev) begin
      if (t_last_edge >= 0 && (clk_n - t_last_edge) % bit_clk != 0) bad_timing++;
      timing_edges++;
      t_last_edge = clk_n;
    end
    e0_prev = e0_txd;
    // ---- error-flag observation on engine 0's TXD ----
    // A dominant run of exactly 6 bits on engine 0's TXD after an error is an active flag.
    // In the same process as clk_n++, so it reads clk_n after the increment in every
    // simulator; a second always block would race it (BUG-102).
    if (!e0_txd && e0_dom_start < 0) e0_dom_start = clk_n;
    if (e0_txd && e0_dom_start >= 0) begin
      e0_runs.push_back((clk_n - e0_dom_start + bit_clk / 2) / bit_clk);
      e0_dom_start = -1;
    end
  end

  // ---------------- scenarios ----------------
  task automatic expect_rec(input int e, input frame_t f, input logic [7:0] status, input string what);
    rec_t r;
    int tries = 0;
    while ((e ? recs1.size() : recs0.size()) == 0 && tries < 4000) begin wait_bits(1); tries++; end
    if ((e ? recs1.size() : recs0.size()) == 0) check(0, $sformatf("%s: engine %0d gave no record", what, e));
    else begin
      r = e ? recs1.pop_front() : recs0.pop_front();
      check(r[12:5] == status, $sformatf("%s: engine %0d status %02x, expected %02x", what, e, r[12:5], status));
      check(same(r[111:13], f), $sformatf("%s: engine %0d got %s, expected %s", what, e, fs(r[111:13]), fs(f)));
`ifdef PBE_SIGROK
      // every frame on the bus is one record of engine 0: the list sigrok must decode
      if (e == 0 && (status == 8'h82 || status == 8'h02 || status == 8'h22))
        $display("SIGROK_EXPECT %03x %0d %0d %016x", f[79:69], f[68], f[67:64], f[63:0]);
`endif
    end
  endtask

  task automatic ref_expect(input int which, input frame_t f, input string what);
    frame_t g;
    int tries = 0;
    while ((which ? rb.rx_frames.size() : ra.rx_frames.size()) == 0 && tries < 4000) begin wait_bits(1); tries++; end
    if ((which ? rb.rx_frames.size() : ra.rx_frames.size()) == 0)
      check(0, $sformatf("%s: reference %s received nothing", what, which ? "B" : "A"));
    else begin
      g = which ? rb.rx_frames.pop_front() : ra.rx_frames.pop_front();
      check(same(g, f), $sformatf("%s: reference got %s, expected %s", what, fs(g), fs(f)));
    end
  endtask

  // wait until engine e has at least n records (the reader takes them at the IRQ)
  task automatic wait_recs(input int e, input int n);
    int tries = 0;
    while ((e ? recs1.size() : recs0.size()) < n && tries < 2000) begin wait_bits(1); tries++; end
  endtask

  task automatic wait_flag_clear(input int e, input string what);
    bit v;
    int tries = 0;
    do begin wait_bits(8); flag_get(e, 0, v); tries++; end while (v && tries < 600);
    check(!v, $sformatf("%s: engine %0d never finished sending", what, e));
  endtask

  task automatic scenario_rates();
    frame_t f;
    int nf, rate;
    string name;
    int r_only, sp_sel;
    if (!$value$plusargs("RATE=%d", r_only)) r_only = -1;
    if (!$value$plusargs("SP=%d", sp_sel)) sp_sel = 2;   // LINE2 sample point: 2 = 75 %, 3 = 87.5 %
    for (int r = (r_only >= 0 ? r_only : 0); r < (r_only >= 0 ? r_only + 1 : 4); r++) begin
      rate = r == 0 ? 384 : r == 1 ? 192 : r == 2 ? 96 : 48;
      name = r == 0 ? "125k" : r == 1 ? "250k" : r == 2 ? "500k" : "1M";
      setup(rate, 8'h70 | 8'(sp_sel));
      ref_cfg(rate * CLK_NS);
      ra.enabled = 1; rb.enabled = 0;
      ra.rx_frames.delete(); recs0.delete(); recs1.delete();
      run_engines(2'b11);
      wait_bits(24);
      nf = (r < 2) ? 3 : 10;
      // chip -> reference
      for (int i = 0; i < nf; i++) begin
        f = (i == nf - 1) ? mkf(11'h7EF - i, 1, 4'd3, i) : mkf(11'h0A5 + i * 77, 0, nf == 3 ? 4'(i * 4) : 4'(i), i + r);
        timing_on = 1; t_last_edge = -1;
        chip_send(0, f);
        wait_flag_clear(0, {name, " chip->ref"});
        timing_on = 0;
        ref_expect(0, f, $sformatf("%s chip->ref #%0d", name, i));
        expect_rec(0, f, 8'h82, $sformatf("%s chip->ref own record #%0d", name, i));
        expect_rec(1, f, 8'h02, $sformatf("%s chip->ref engine 1 #%0d", name, i));
      end
      check(bad_timing == 0, $sformatf("%s: %0d of engine 0's bits were not a whole number of bit times", name, bad_timing));
      bad_timing = 0;
      // reference -> chip
      for (int i = 0; i < nf; i++) begin
        f = (i == nf - 1) ? mkf(11'h123, 1, 4'd5, i) : mkf(11'h311 - i * 13, 0, nf == 3 ? 4'(8 - i * 4) : 4'(8 - i), i * 3);
        ra.tx_q.push_back(f);
        expect_rec(0, f, 8'h02, $sformatf("%s ref->chip engine 0 #%0d", name, i));
        expect_rec(1, f, 8'h02, $sformatf("%s ref->chip engine 1 #%0d", name, i));
      end
      check(ra.tec == 0 && ra.rec == 0 && ra.n_err_flags == 0, $sformatf("%s: the reference saw errors (TEC %0d REC %0d flags %0d)", name, ra.tec, ra.rec, ra.n_err_flags));
      $display("1: %s: %0d frames each way (DLC 0-8 and remote), records and reference frames match, bits on the grid",
               name, nf);
    end
  endtask

  task automatic scenario_arbitration();
    frame_t fa, fb, f0;
    setup(96, 8'h72);
    ref_cfg(96 * CLK_NS);
    ra.enabled = 1; rb.enabled = 1;
    ra.rx_frames.delete(); rb.rx_frames.delete(); recs0.delete(); recs1.delete();
    run_engines(2'b11);
    wait_bits(24);
    // B sends first; while it is on the bus, A (0x100) and engine 0 (0x200) get their frames
    fb = mkf(11'h050, 0, 4'd8, 7);
    fa = mkf(11'h100, 0, 4'd4, 8);
    f0 = mkf(11'h200, 0, 4'd6, 9);
    rb.tx_q.push_back(fb);
    wait_bits(10);
    ra.tx_q.push_back(fa);
    chip_send(0, f0);
    wait_flag_clear(0, "arbitration");
    expect_rec(0, fb, 8'h02, "arbitration: B's frame");
    expect_rec(0, fa, 8'h22, "arbitration: A wins, engine 0 lost (status arbitration lost)");
    expect_rec(0, f0, 8'h82, "arbitration: engine 0's frame after A's");
    ref_expect(1, fa, "arbitration: B sees A first");
    ref_expect(1, f0, "arbitration: then engine 0");
    check(ra.n_arb_lost == 0, "arbitration: the reference with the lower ID lost");
    $display("2: arbitration: ID 0x100 beat engine 0's 0x200; engine 0 received it intact, then sent its own");
  endtask

  task automatic scenario_ack();
    frame_t f;
    int tec;
    logic [7:0] st;
    setup(96, 8'h72);
    ref_cfg(96 * CLK_NS);
    ra.enabled = 1; rb.enabled = 0;
    ra.ack_en = 0;
    ra.rx_frames.delete(); recs0.delete(); recs1.delete();
    run_engines(2'b01);
    wait_bits(24);
    f = mkf(11'h345, 0, 4'd2, 3);
    chip_send(0, f);
    wait_bits(25 * 60);   // ~25 attempts
    read_tec(0, tec, st);
    check(tec == 128 && st[1] && !st[2], $sformatf("ACK missing: TEC %0d state %b, expected 128, passive, not bus-off", tec, st[2:0]));
    check(recs0.size() >= 16, $sformatf("ACK missing: only %0d attempts reported", recs0.size()));
    for (int i = 0; i < recs0.size(); i++) begin
      rec_t r;
      r = recs0[i];
      check(r[9] && !r[12], $sformatf("ACK missing: attempt %0d status %02x", i, r[12:5]));
    end
    recs0.delete();
    ra.ack_en = 1;
    wait_flag_clear(0, "ACK back");
    wait_recs(0, 1);
    read_tec(0, tec, st);
    check(tec == 127 && !st[1], $sformatf("ACK back: TEC %0d state %b, expected 127, active", tec, st[2:0]));
    while (recs0.size() > 1) void'(recs0.pop_front());
    expect_rec(0, f, 8'h82, "ACK back: the frame went out");
    $display("3: ACK missing: TEC rose by 8 per attempt to 128 (passive) and stayed; with an ACK the frame went out, TEC 127");
  endtask

  // the time engine 0 starts driving dominant after `t0`
  task automatic first_e0_dom(input int t0, output int t);
    t = -1;
    for (int i = 0; i < 400 * bit_clk && t < 0; i++) begin
      @(negedge clk);  // after the edge's clk_n++ (BUG-102)
      if (clk_n > t0 && !e0_txd) t = clk_n;
    end
  endtask

  int ra_bit_t[$];  // clock numbers of reference A's bit starts in the tail (tail_i 0..9)
  always @(ra.tqc) if (ra.tqc == 1 && ra.st == 2 /* S_FRAME */ && ra.in_tail) ra_bit_t.push_back(clk_n);

  task automatic scenario_injected();
    frame_t f;
    int t, d, rec;
    logic [7:0] st, lo;
    setup(96, 8'h72);
    ref_cfg(96 * CLK_NS);
    ra.enabled = 1; rb.enabled = 0;
    recs0.delete(); recs1.delete();
    run_engines(2'b11);
    wait_bits(24);
    // CRC error: the chip's flag starts in the bit after the ACK delimiter (EOF bit 1)
    f = mkf(11'h0F0, 0, 4'd3, 1);
    ra.crc_corrupt = 1;
    ra_bit_t.delete();
    ra.tx_q.push_back(f);
    while (ra_bit_t.size() < 3) @(posedge clk);
    first_e0_dom(ra_bit_t[2], t);
    d = t - (ra_bit_t[2] + bit_clk);   // the start of EOF bit 1, as reference A timed it
    check(d > -bit_clk / 4 && d < bit_clk / 4, $sformatf("CRC error: engine 0's flag began %0d clocks from the bit after the ACK delimiter", d));
    // the chip's records: an error record, then the retransmitted frame
    wait_bits(200);
    check(recs0.size() >= 2 && st0b(0, 4) && !st0b(0, 1), $sformatf("CRC error: first record status %02x", recs0.size() ? st0(0) : 0));
    if (recs0.size() >= 1) void'(recs0.pop_front());
    expect_rec(0, f, 8'h02, "CRC error: the retransmitted frame");
    reg_read(7'h36, lo);
    rec = lo;
    // stuff error and form error
    recs0.delete(); recs1.delete();
    f = mkf(11'h000, 0, 4'd1, 2);   // ID 0: a long dominant run, stuffed early
    ra.skip_stuff_at = 4;
    ra.tx_q.push_back(f);
    wait_bits(150);
    check(recs0.size() >= 2 && st0b(0, 4), "stuff error: no error record");
    if (recs0.size() >= 1) void'(recs0.pop_front());
    expect_rec(0, f, 8'h02, "stuff error: the retransmitted frame");
    recs0.delete(); recs1.delete();
    f = mkf(11'h3AA, 0, 4'd2, 3);
    ra.form_corrupt = 1;
    ra.tx_q.push_back(f);
    wait_bits(150);
    check(recs0.size() >= 2 && st0b(0, 4), "form error: no error record");
    if (recs0.size() >= 1) void'(recs0.pop_front());
    expect_rec(0, f, 8'h02, "form error: the retransmitted frame");
    check(ra.n_sent >= 3, "injected errors: the reference did not get its frames out");
    $display("3b: injected CRC, stuff and form errors: error records, the CRC error flag in EOF bit 1, frames received on retransmission");
  endtask

  // the disturber: force dominant for one bit where engine 0 sends recessive, `nth` data bit
  // after its SOF (counted at engine 0's TXD) - a bit error for engine 0
  bit disturb = 0;
  int disturb_after = 30, n_disturbed = 0;
  initial begin : disturber
    forever begin
      @(posedge clk);
      if (disturb && !e0_txd) begin
        // engine 0 started a frame: wait into it, then hit the next recessive bit it sends
        repeat (disturb_after * bit_clk) @(posedge clk);
        while (!e0_txd || !bus) @(posedge clk);
        repeat (bit_clk / 8) @(posedge clk);
        force_dom = 1;            // a whole bit: the chip resyncs on this edge and still samples it
        repeat (bit_clk) @(posedge clk);
        force_dom = 0;
        n_disturbed++;
        // let the error frame and intermission pass
        repeat (30 * bit_clk) @(posedge clk);
      end
    end
  end

  task automatic scenario_bit_error();
    frame_t f;
    int tec;
    logic [7:0] st;
    setup(96, 8'h72);
    ref_cfg(96 * CLK_NS);
    ra.enabled = 1; rb.enabled = 0;
    recs0.delete(); recs1.delete();
    run_engines(2'b01);
    wait_bits(24);
    f = mkf(11'h0FF, 0, 4'd8, 4);   // data with recessive bits after the arbitration field
    n_disturbed = 0;
    disturb = 1;
    chip_send(0, f);
    while (n_disturbed == 0) wait_bits(1);
    disturb = 0;
    wait_flag_clear(0, "bit error");
    wait_recs(0, 2);
    read_tec(0, tec, st);
    check(tec == 7, $sformatf("bit error: TEC %0d after one error and one success, expected 7", tec));
    check(recs0.size() >= 2 && st0b(0, 6) && st0b(0, 4), $sformatf("bit error: first record status %02x, expected bit error", recs0.size() ? st0(0) : 0));
    while (recs0.size() > 1) void'(recs0.pop_front());
    expect_rec(0, f, 8'h82, "bit error: the retransmitted frame");
    ref_expect(0, f, "bit error: reference");
    $display("4: bit error as transmitter: error record (bit error), retransmitted, TEC 8 - 1 = 7");
  endtask

  task automatic scenario_passive_busoff();
    frame_t f;
    int tec, t_off, t_back, expect_tec, n_flags_active, idx;
    logic [7:0] st;
    setup(96, 8'h72);
    ref_cfg(96 * CLK_NS);
    ra.enabled = 1; rb.enabled = 0;
    recs0.delete(); recs1.delete();
    run_engines(2'b01);
    wait_bits(24);
    f = mkf(11'h0F7, 0, 4'd8, 6);
    e0_runs.delete();
    n_disturbed = 0;
    disturb = 1;
    chip_send(0, f);
    // each disturbed attempt adds 8; TEC passes 255 at the 32nd
    for (int k = 1; k <= 32; k++) begin
      while (n_disturbed < k) wait_bits(1);
      wait_bits(4);
      read_tec(0, tec, st);
      expect_tec = 8 * k;
      if (k < 32) check(tec == expect_tec && st[1] == (expect_tec >= 128) && !st[2],
                        $sformatf("error %0d: TEC %0d state %b, expected %0d", k, tec, st[2:0], expect_tec));
      else begin
        check(st[2], $sformatf("error 32: TEC %0d state %b, expected bus-off", tec, st[2:0]));
        t_off = clk_n;
      end
    end
    disturb = 0;
    // engine 0's error flags: 16 active (6 dominant bits on its TXD), then passive
    n_flags_active = 0;
    foreach (e0_runs[i]) if (e0_runs[i] == 6) n_flags_active++;
    check(n_flags_active == 16, $sformatf("error flags: %0d active flags on engine 0's TXD, expected 16 (errors 1-16)", n_flags_active));
    // bus-off: no drive until recovery (128 x 11 recessive bits), then the frame goes out
    t_back = -1;
    while (t_back < 0 && clk_n - t_off < 2000 * bit_clk) begin
      @(negedge clk);  // after the edge's clk_n++ (BUG-102)
      if (!e0_txd) t_back = clk_n;
    end
    check(t_back > 0 && t_back - t_off >= 128 * 11 * bit_clk - 2 * bit_clk,
          $sformatf("bus-off: engine 0 drove again %0d bit times after bus-off, expected >= %0d", (t_back - t_off) / bit_clk, 128 * 11));
    wait_flag_clear(0, "after recovery");
    wait_bits(30);
    read_tec(0, tec, st);
    check(tec == 0 && st[2:1] == 0, $sformatf("after recovery: TEC %0d state %b", tec, st[2:0]));
    while (recs0.size() > 1) void'(recs0.pop_front());
    expect_rec(0, f, 8'h82, "after recovery: the frame went out");
    $display("5: error-passive after 16 errors (flags 1-16 active, then passive), bus-off at TEC 256, recovery after %0d bit times",
             (t_back - t_off) / bit_clk);
  endtask

  task automatic scenario_two_engines();
    frame_t f0, f1, fb, first0;
    setup(96, 8'h72);
    ref_cfg(96 * CLK_NS);
    ra.enabled = 0; rb.enabled = 1;
    rb.rx_frames.delete(); recs0.delete(); recs1.delete();
    run_engines(2'b11);
    wait_bits(24);
    f0 = mkf(11'h111, 0, 4'd5, 11);
    first0 = f0;
    chip_send(0, f0);
    wait_flag_clear(0, "two engines 0->1");
    expect_rec(1, f0, 8'h02, "two engines: engine 1 receives engine 0's frame");
    expect_rec(0, f0, 8'h82, "two engines: engine 0's own record");
    f1 = mkf(11'h222, 1, 4'd0, 12);
    chip_send(1, f1);
    wait_flag_clear(1, "two engines 1->0");
    expect_rec(0, f1, 8'h02, "two engines: engine 0 receives engine 1's frame");
    expect_rec(1, f1, 8'h82, "two engines: engine 1's own record");
    // arbitration between the engines: both queued while B sends
    fb = mkf(11'h010, 0, 4'd8, 13);
    f0 = mkf(11'h401, 0, 4'd1, 14);
    f1 = mkf(11'h400, 0, 4'd2, 15);
    rb.tx_q.push_back(fb);
    wait_bits(8);
    chip_send(0, f0);
    chip_send(1, f1);
    wait_flag_clear(0, "engine arbitration");
    wait_flag_clear(1, "engine arbitration");
    expect_rec(0, fb, 8'h02, "engine arbitration: B's frame (engine 0)");
    expect_rec(1, fb, 8'h02, "engine arbitration: B's frame (engine 1)");
    expect_rec(0, f1, 8'h22, "engine arbitration: engine 1 (0x400) wins over engine 0 (0x401)");
    expect_rec(1, f1, 8'h82, "engine arbitration: engine 1's own record");
    expect_rec(0, f0, 8'h82, "engine arbitration: engine 0 sends after");
    expect_rec(1, f0, 8'h02, "engine arbitration: engine 1 receives it");
    ref_expect(1, first0, "two engines: B saw engine 0's first frame");
    $display("6: engines 0 and 1 as two nodes: frames both ways, arbitration 0x400 over 0x401");
  endtask

  // an extended (CAN 2.0B) frame: base ID, extended ID, RTR, DLC
  function automatic frame_t mkx(input logic [10:0] base, input logic [17:0] ext, input bit rtr, input logic [3:0] dlc, input int seed);
    frame_t f;
    f = mkf(base, rtr, dlc, seed);
    f[98] = 1;
    f[97:80] = ext;
    return f;
  endfunction

  // engine e's record of an extended frame or a standard one with r0 recessive: the
  // first three units ({SOF, ID[10:4]}, ID[3:0], {SRR or RTR, IDE, ..}), then the status (D74)
  task automatic expect_short(input int e, input logic [10:0] base, input bit ide, input logic [7:0] status, input string what);
    rec_t r;
    frame_t rf;
    wait_recs(e, 1);
    if ((e ? recs1.size() : recs0.size()) == 0) check(0, $sformatf("%s: engine %0d gave no record", what, e));
    else begin
      r = e ? recs1.pop_front() : recs0.pop_front();
      rf = r[111:13];
      check(r[4:0] == 5'd4 && r[12:5] == status && rf[79:69] == base && rf[98] == ide,
            $sformatf("%s: engine %0d record of %0d bytes, status %02x, base ID %03x, IDE %0d; expected 4, %02x, %03x, %0d",
                      what, e, r[4:0], r[12:5], rf[79:69], rf[98], status, base, ide));
    end
  endtask

  task automatic scenario_extended();
    frame_t f, fs_, fx;
    int tec;
    logic [7:0] st, rec_lo;
    setup(96, 8'hF2);
    ref_cfg(96 * CLK_NS);
    ra.enabled = 1; rb.enabled = 0;   // the chip is the only node that can acknowledge
    run_engines(2'b11);
    wait_bits(24);
    // valid extended data and remote frames, and a standard frame with r0 recessive
    for (int i = 0; i < 4; i++) begin
      f = (i == 3) ? mkx(11'h2A5, 18'h3_1234, 1, 4'd2, i) : mkx(11'h155 + i, 18'h2_0F0F + i, 0, i == 0 ? 4'd0 : i == 1 ? 4'd3 : 4'd8, i);
      ra.tx_q.push_back(f);
      expect_short(0, f[79:69], 1, 8'h02, $sformatf("extended frame %0d", i));
      expect_short(1, f[79:69], 1, 8'h02, $sformatf("extended frame %0d (engine 1)", i));
    end
    ra.r0_bit = 1;
    f = mkf(11'h0C3, 0, 4'd5, 9);
    ra.tx_q.push_back(f);
    expect_short(0, f[79:69], 0, 8'h02, "standard frame with r0 recessive");
    expect_short(1, f[79:69], 0, 8'h02, "standard frame with r0 recessive (engine 1)");
    ra.r0_bit = 0;
    wait_bits(20);
    check(ra.n_sent == 5 && ra.n_err_flags == 0 && ra.tec == 0,
          $sformatf("extended: the reference sent %0d of 5, with %0d error flags, TEC %0d (every frame must be ACKed by the chip, no errors)",
                    ra.n_sent, ra.n_err_flags, ra.tec));
    read_tec(0, tec, st);
    reg_read(7'h36, rec_lo);
    check(tec == 0 && rec_lo == 0 && st[2:1] == 0, $sformatf("extended: engine 0 TEC %0d REC %0d state %b", tec, rec_lo, st[2:0]));
    // arbitration: a standard frame beats an extended one with the same base ID (SRR/IDE)
    rb.enabled = 1;
    rb.rx_frames.delete();
    recs0.delete(); recs1.delete();
    wait_bits(16);
    fs_ = mkf(11'h123, 0, 4'd2, 20);
    fx = mkx(11'h123, 18'h0_0001, 0, 4'd1, 21);
    rb.tx_q.push_back(mkf(11'h040, 0, 4'd8, 22));   // a frame first, so both start together after it
    wait_bits(10);
    ra.tx_q.push_back(fx);
    chip_send(0, fs_);
    wait_flag_clear(0, "standard vs extended");
    wait_bits(200);
    expect_rec(0, mkf(11'h040, 0, 4'd8, 22), 8'h02, "standard vs extended: B's frame");
    expect_rec(0, fs_, 8'h82, "standard vs extended: the standard frame (same base ID) wins");
    expect_short(0, 11'h123, 1, 8'h02, "standard vs extended: then the extended frame");
    ref_expect(1, fs_, "standard vs extended: B receives the standard frame first");
    ref_expect(1, fx, "standard vs extended: then the extended one, intact (29-bit ID)");
    check(ra.n_arb_lost == 1, $sformatf("standard vs extended: the extended sender lost arbitration %0d times, expected 1", ra.n_arb_lost));
    $display("7: extended (CAN 2.0B) frames and r0 recessive: received passively, ACKed, no error frames; standard 0x123 beats extended 0x123");
  endtask

  initial begin
    string only;
    repeat (5) @(posedge clk);
    @(negedge clk) rst_n = 1;  // released between edges, not at one (BUG-102)
    repeat (5) @(posedge clk);
    if (!$value$plusargs("ONLY=%s", only)) only = "";
    if (only == "" || only == "rates") scenario_rates();
    if (only == "" || only == "arb") scenario_arbitration();
    if (only == "" || only == "ack") scenario_ack();
    if (only == "" || only == "inject") scenario_injected();
    if (only == "" || only == "biterr") scenario_bit_error();
    if (only == "" || only == "busoff") scenario_passive_busoff();
    if (only == "" || only == "two") scenario_two_engines();
    if (only == "" || only == "ext") scenario_extended();
    if (errors == 0) begin
      $display("PASS: CAN node");
      $finish;
    end else $fatal(1, "FAILED with %0d error(s)", errors);
  end
  initial begin
    #2s;
    $fatal(1, "FAILED: timeout");
  end
endmodule
