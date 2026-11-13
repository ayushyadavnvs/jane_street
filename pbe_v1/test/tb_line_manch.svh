// Included by tb_line.sv: test M, the Manchester mode of pbe_line (LINE[1:0] = 3, D90).
// The encoder and the checks here are written from IEEE 802.3 clause 7.3.1.1 (each bit is
// two halves, the first the complement of the bit, so a 1 is low then high) and clause
// 14.3.1.2.1 (TP_IDL: the line held high after the last bit), not from the RTL.
// Two coders at 6 clocks per bit (10BASE-T at 60 MHz): mt transmits, mr receives, either
// from the reference encoder below (with a clock offset and per-edge jitter) or from mt.
//
//  M1  transmit, pair, bytes: every clock of every half-bit, b the complement of a, then
//      the line high for 3 bit times and released.
//  M2  transmit, the other polarity (LINE[7]), single bits.
//  M3  a transmit underrun: err pulses and the line holds its level (no transitions).
//  M4  receive a frame (7 x 0x55, SFD 0xD5 = SYNC, 64 bytes, TP_IDL) from the reference
//      encoder at 0, +-100 ppm (+-0.01 %, 802.3's limit) and +-1 %, with per-edge jitter up
//      to +-0.7 clock: the bytes, one frame end, no error. The receiver's line is also sampled
//      at the falling clock edge (a_early), as the chip's synchronizer does.
//  M5  link pulses (NLP, one bit time high) and a stray edge on an idle line: nothing.
//  M6  mt into mr (loopback), preamble and SFD sent as data.
//  M7  a jitter sweep: the largest per-edge jitter at which 20 frames all decode (printed).

localparam int PM = 6;  // clocks per Manchester bit
logic [7:0] cfg_mt = 0, cfg_mr = 0, sync_mr = 0;
logic       put_mt = 0, end_mt = 0, take_mr = 0, m_line = 0, use_mloop = 0;
logic [7:0] data_mt = 0;
wire        drive_mt, ao_mt, bo_mt, ready_mt, rv_mt, fe_mt, err_mt;
wire        drive_mr, ao_mr, bo_mr, ready_mr, rv_mr, fe_mr, err_mr;
wire [7:0]  rd_mt, rd_mr;
// idle (not driven) reads low: the receive comparator's output with no signal (docs/info.md)
wire        mt_line = drive_mt ? ao_mt : 1'b0;
// the receiver's line sampled at the falling clock edge too, as the chip's negedge
// synchronizer does (a_early: the level half a clock before the rising edge)
logic       mr_early = 0;
always @(negedge clk) mr_early <= use_mloop ? mt_line : m_line;

pbe_line mt (
    .clk, .rst_n, .clear(1'b0), .cfg(cfg_mt), .cfg2(8'h00), .sync(8'h00), .period_m1(16'(PM - 1)),
    .out_msb_first(1'b0), .in_msb_first(1'b0), .a_in(1'b0), .a_early(1'b0), .b_in(1'b0),
    .drive(drive_mt), .a_out(ao_mt), .b_out(bo_mt),
    .tx_put(put_mt), .tx_end(end_mt), .tx_data(data_mt), .tx_ready(ready_mt),
    .rx_valid(rv_mt), .rx_data(rd_mt), .rx_take(1'b0), .frame_end(fe_mt), .err(err_mt)
);
pbe_line mr (
    .clk, .rst_n, .clear(1'b0), .cfg(cfg_mr), .cfg2(8'h00), .sync(sync_mr), .period_m1(16'(PM - 1)),
    .out_msb_first(1'b0), .in_msb_first(1'b0), .a_in(use_mloop ? mt_line : m_line), .a_early(mr_early),
    .b_in(1'b0),
    .drive(drive_mr), .a_out(ao_mr), .b_out(bo_mr),
    .tx_put(1'b0), .tx_end(1'b0), .tx_data(8'h00), .tx_ready(ready_mr),
    .rx_valid(rv_mr), .rx_data(rd_mr), .rx_take(take_mr), .frame_end(fe_mr), .err(err_mr)
);

int n_err_mt = 0, n_err_mr = 0, n_fe_mr = 0;
logic [7:0] got_m[$];
always @(posedge clk) begin
  if (err_mt) n_err_mt++;
  if (err_mr) n_err_mr++;
  if (fe_mr) n_fe_mr++;
  take_mr <= 0;
  if (rv_mr && !take_mr) begin
    got_m.push_back(rd_mr);
    take_mr <= 1;
  end
end

task automatic send_mt(input logic [7:0] d, input bit is_end);
  @(negedge clk);
  while (!ready_mt) @(negedge clk);
  data_mt = d; put_mt = !is_end; end_mt = is_end;
  @(negedge clk);
  put_mt = 0; end_mt = 0;
endtask

// mt's line, one entry per clock: drive, a, b (separate queues: Icarus cannot bit-select a
// queue element with a variable index)
int mq_d[$], mq_a[$], mq_b[$];
bit mt_watch = 0;
always @(posedge clk)
  if (mt_watch) begin
    mq_d.push_back(drive_mt);
    mq_a.push_back(ao_mt);
    mq_b.push_back(bo_mt);
  end
task automatic mq_clear();
  mq_d.delete();
  mq_a.delete();
  mq_b.delete();
endtask

// reference: the per-clock levels of a frame of bits (802.3: first half !b, second half b;
// inv swaps), then 3 bit times high
int mref[$];
bit mbits[$];
task automatic manch_ref(input bit inv);
  mref.delete();
  foreach (mbits[i]) begin
    for (int c = 0; c < PM / 2; c++) mref.push_back(!(mbits[i] ^ inv));
    for (int c = 0; c < PM / 2; c++) mref.push_back(mbits[i] ^ inv);
  end
  for (int c = 0; c < 3 * PM; c++) mref.push_back(1);
endtask

// compare mt's line (from its first driven clock) with mref; then it must be released
task automatic check_mt(input string what, input bit pair);
  int f, bad;
  f = -1;
  foreach (mq_d[i]) if (mq_d[i] == 1 && f < 0) f = i;
  bad = 0;
  check(f >= 0, {what, ": never driven"});
  for (int i = 0; f >= 0 && i < mref.size() && !bad; i++) begin
    if (f + i >= mq_d.size()) bad = 1;
    else if (mq_d[f+i] != 1 || mq_a[f+i] != mref[i] || (pair && mq_b[f+i] == mref[i])) bad = 1;
    if (bad)
      check(0, $sformatf("%s: clock %0d of the frame: drive %0d a %0d b %0d, expected a %0d", what, i,
                         f + i < mq_d.size() ? mq_d[f+i] : 0, f + i < mq_d.size() ? mq_a[f+i] : 0,
                         f + i < mq_d.size() ? mq_b[f+i] : 0, mref[i]));
  end
  if (f >= 0 && !bad)
    check(f + mref.size() < mq_d.size() && mq_d[f+mref.size()] == 0,
          {what, ": the line is not released right after the 3 high bit times"});
endtask

// ---- the reference encoder: one frame onto m_line with a clock offset and jitter ----
// Deterministic jitter (an LCG, so Icarus and Verilator see the same edges, D80).
int unsigned lcg = 32'h1234_5678;
function real urand();  // 0 .. 1
  lcg = lcg * 32'd1664525 + 32'd1013904223;
  return real'(lcg >> 8) / 16777216.0;
endfunction
logic [7:0] mframe[$];  // the bytes of the frame, preamble and SFD included
// t_half: half a bit in ns; jit: per-edge jitter, uniform +-jit ns
// (a static task: Icarus 12 crashed on this one as an automatic task)
real md_t0, md_half, md_t;
int  md_lv[$];
logic [7:0] md_b;
task manch_drive(input real ppm, input real jit, input bit tpidl);
  md_lv.delete();
  foreach (mframe[i]) begin
    md_b = mframe[i];
    for (int k = 0; k < 8; k++) begin  // LSB first
      md_lv.push_back(!md_b[k]);
      md_lv.push_back(md_b[k]);
    end
  end
  if (tpidl) for (int k = 0; k < 6; k++) md_lv.push_back(1);  // 3 bit times high
  md_lv.push_back(0);                                          // then idle
  md_half = PM / 2 * 20.0 * (1.0 + ppm * 1e-6);
  @(negedge clk);
  md_t0 = $realtime + 3.0;
  for (int i = 0; i < md_lv.size(); i++) begin
    if (i == 0 || md_lv[i] != md_lv[i-1]) begin  // a transition
      md_t = md_t0 + i * md_half + (2.0 * urand() - 1.0) * jit;
      if (md_t < $realtime) md_t = $realtime;
      // never on a rising edge of clk (posedges at 10, 30, 50 ... ns), D80 rule 3
      if (md_t - 20.0 * $floor(md_t / 20.0) > 9.99 && md_t - 20.0 * $floor(md_t / 20.0) < 10.01)
        md_t = md_t + 0.05;
      #(md_t - $realtime);
      m_line = md_lv[i];
    end
  end
endtask

task automatic m_frame(input int n);
  mframe.delete();
  repeat (7) mframe.push_back(8'h55);
  mframe.push_back(8'hD5);
  for (int i = 0; i < n; i++) mframe.push_back(8'($rtoi(urand() * 255.99)));
endtask

// receive one frame from the encoder; ok if all n payload bytes arrive, one frame end, no error
task automatic m_rx(input int n, input real ppm, input real jit, output bit ok);
  got_m.delete();
  n_err_mr = 0;
  n_fe_mr = 0;
  m_frame(n);
  manch_drive(ppm, jit, 1);
  repeat (6 * PM) @(negedge clk);
  ok = got_m.size() == n && n_fe_mr == 1 && n_err_mr == 0;
  for (int i = 0; ok && i < n; i++) if (got_m[i] !== mframe[8+i]) ok = 0;
endtask

// M4's cases; jitter in ns at a 20 ns clock (module level: Icarus 12 crashes on a real array
// in an automatic task)
real ppms[6], jits[6];
task run_manch_tests();  // static: Icarus 12 crashed on its locals as an automatic task
  logic [7:0] pkt[$];
  logic [7:0] b;
  bit ok;
  int nt, flips, f;
  real best;
  // ===== M1: transmit, 802.3 polarity, pair, bytes =====
  cfg_mt = 8'b0011_0011;  // bytes, pair, Manchester
  pkt = '{8'h55, 8'hD5, 8'h00, 8'hFF, 8'hA3, 8'h5C};
  mbits.delete();
  foreach (pkt[i]) begin
    b = pkt[i];
    for (int k = 0; k < 8; k++) mbits.push_back(b[k]);
  end
  manch_ref(0);
  mq_clear();
  n_err_mt = 0;
  mt_watch = 1;
  foreach (pkt[i]) send_mt(pkt[i], 0);
  send_mt(0, 1);
  while (drive_mt) @(negedge clk);
  repeat (4) @(negedge clk);
  mt_watch = 0;
  check_mt("M1 Manchester TX", 1);
  check(n_err_mt == 0, "M1 Manchester TX: an error");
  $display("M1: Manchester TX (802.3: 1 = low-high), pair, %0d bytes: every half bit, then 3 bit times high and released", pkt.size());

  // ===== M2: the other polarity, single bits =====
  cfg_mt = 8'b1001_0011;  // inverted, pair, bits, Manchester
  mbits = '{1, 1, 0, 1, 0, 0, 0, 1, 1};
  manch_ref(1);
  mq_clear();
  mt_watch = 1;
  foreach (mbits[i]) send_mt(8'(mbits[i]), 0);
  send_mt(0, 1);
  while (drive_mt) @(negedge clk);
  repeat (4) @(negedge clk);
  mt_watch = 0;
  check_mt("M2 Manchester TX, LINE[7]", 1);
  $display("M2: Manchester TX, the other polarity (LINE[7], 1 = high-low), %0d single bits", mbits.size());

  // ===== M3: underrun =====
  cfg_mt = 8'b0011_0011;
  mq_clear();
  n_err_mt = 0;
  mt_watch = 1;
  send_mt(8'h0F, 0);  // ends with a 0: the second half is low
  repeat (24 * PM) @(negedge clk);  // nothing queued for 2 bytes' time after it
  send_mt(8'hF0, 0);
  send_mt(0, 1);
  while (drive_mt) @(negedge clk);
  mt_watch = 0;
  flips = 0;
  nt = 0;
  // between the end of the first byte (bit 8) and 12 bit times later the line must not move
  begin
    f = -1;
    foreach (mq_d[i]) if (mq_d[i] == 1 && f < 0) f = i;
    for (int i = f + 8 * PM; i < f + 20 * PM && i < mq_d.size(); i++) begin
      nt++;
      if (mq_a[i] != 0) flips++;
    end
  end
  check(n_err_mt > 0 && nt > 0 && flips == 0,
        $sformatf("M3 underrun: %0d err pulses, %0d clocks not at the last level (want err > 0, 0 clocks)", n_err_mt, flips));
  $display("M3: Manchester TX underrun reported (err), the line holds its level");

  // ===== M4: receive from the reference encoder =====
  cfg_mr = 8'b0010_0011;  // bytes, Manchester
  sync_mr = 8'hD5;        // the SFD
  m_line = 0;
  repeat (10 * PM) @(negedge clk);
  begin
    ppms[0] = 0.0;      jits[0] = 0.0;
    ppms[1] = 100.0;    jits[1] = 12.0;
    ppms[2] = -100.0;   jits[2] = 12.0;
    ppms[3] = 10000.0;  jits[3] = 8.0;
    ppms[4] = -10000.0; jits[4] = 8.0;
    ppms[5] = 0.0;      jits[5] = 14.0;
    for (int k = 0; k < 6; k++) begin
      m_rx(64, ppms[k], jits[k], ok);
      check(ok, $sformatf("M4 Manchester RX at %0.0f ppm, jitter +-%0.1f ns: %0d bytes, %0d frame ends, %0d errors",
                          ppms[k], jits[k], got_m.size(), n_fe_mr, n_err_mr));
      if (ok) $display("M4: Manchester RX, 64 bytes after 7 x 0x55 and SFD 0xD5, %0.0f ppm, jitter +-%0.2f clock: ok",
                       ppms[k], jits[k] / 20.0);
    end
  end

  // ===== M5: link pulses and a stray edge on an idle line =====
  got_m.delete();
  n_err_mr = 0;
  n_fe_mr = 0;
  for (int k = 0; k < 3; k++) begin
    repeat (40 * PM) @(negedge clk);
    m_line = 1;
    repeat (PM) @(negedge clk);  // one bit time high: a normal link pulse
    m_line = 0;
  end
  repeat (40 * PM) @(negedge clk);
  m_line = 1;  // a stray edge, then the line stays high
  repeat (40 * PM) @(negedge clk);
  m_line = 0;
  repeat (40 * PM) @(negedge clk);
  check(got_m.size() == 0 && n_fe_mr == 0 && n_err_mr == 0,
        $sformatf("M5: link pulses gave %0d bytes, %0d frame ends, %0d errors", got_m.size(), n_fe_mr, n_err_mr));
  $display("M5: 3 link pulses and a stray edge on an idle line: no bytes, no frame end, no error");

  // ===== M6: loopback mt -> mr =====
  cfg_mt = 8'b0011_0011;
  use_mloop = 1;
  got_m.delete();
  n_fe_mr = 0;
  n_err_mr = 0;
  m_frame(40);
  foreach (mframe[i]) send_mt(mframe[i], 0);
  send_mt(0, 1);
  while (drive_mt) @(negedge clk);
  repeat (6 * PM) @(negedge clk);
  ok = got_m.size() == 40 && n_fe_mr == 1 && n_err_mr == 0;
  for (int i = 0; ok && i < 40; i++) if (got_m[i] !== mframe[8+i]) ok = 0;
  check(ok, $sformatf("M6 loopback: %0d bytes, %0d frame ends, %0d errors", got_m.size(), n_fe_mr, n_err_mr));
  $display("M6: Manchester loopback (coder to coder): 40 bytes after preamble and SFD, one frame end");
  use_mloop = 0;

  // ===== M7: jitter sweep (M4 is the requirement; this measures the margin) =====
  best = 0.0;
  for (int j = 2; j <= 24; j += 2) begin
    ok = 1;
    for (int r = 0; r < 20 && ok; r++) m_rx(32, (r % 2) ? 100.0 : -100.0, j * 1.0, ok);
    if (ok) best = j * 1.0;
    else j = 99;
  end
  $display("M7: per-edge jitter decoded in 20 frames at +-100 ppm: up to +-%0.2f clock (+-%0.1f ns at 60 MHz)",
           best / 20.0, best / 20.0 * 16.667);
  check(best >= 14.0, "M7: less than +-0.7 clock of per-edge jitter decoded");
endtask
