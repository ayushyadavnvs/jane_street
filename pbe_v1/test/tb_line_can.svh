// Included by tb_line.sv: tests D (LINE2 on pbe_line) and E (pbe_bsync, the CAN coder).
// The CAN encoder here is written from ISO 11898-1 (bit stuffing after 5 equal bits in the
// stuffed region; CRC delimiter, ACK slot, ACK delimiter and 7 EOF bits recessive), not
// from the RTL.

// ---------------- D: LINE2 on pbe_line ----------------
int t_fe_u = -1;
always @(posedge clk) if (fe_u) t_fe_u = clk_n;

// One received frame on u's pin: a start bit (P clocks low), then a bit that is low for X
// clocks and high after, then idle. Returns the second bit as u received it.
task automatic line_probe(input int x, output int bit1);
  got.delete();
  a_in = 1;
  repeat (12 * P) @(negedge clk);
  a_in = 0;
  repeat (P) @(negedge clk);
  repeat (x) @(negedge clk);
  a_in = 1;
  repeat (12 * P) @(negedge clk);
  bit1 = got.size() >= 2 ? int'(got[1]) : -1;
endtask

task automatic run_line2_tests();
  int b1, b2, sp, t_rel, t_drv;
  use_loop = 0;
  cfg_u = 8'h01;   // NRZ, no stuffing, single bits
  sync_u = 0;
  // D1: the sample point. A bit that rises X clocks after its start reads 1 exactly when
  // X <= sample + 1 (the counter restarts one clock after the edge). Falling-edge-only
  // resync, so the rising edge inside the bit does not move the sample.
  for (int k = 0; k < 4; k++) begin
    sp = (P - 1) / 2 + 1 + k * (P / 8);
    cfg2_u = 8'h08 | 8'(k);
    line_probe(sp + 1, b1);
    line_probe(sp + 2, b2);
    check(b1 == 1 && b2 == 0, $sformatf("LINE2 sample point %0d: X=%0d read %0d, X=%0d read %0d (expected 1, 0)",
                                        k, sp + 1, b1, sp + 2, b2));
  end
  // D2: a rising edge 10 clocks into bit 2, a falling one 10 clocks later. Falling-only resync
  // samples bit 2 at its normal point (high); every-edge resync moves the sample past the
  // falling edge (low).
  for (int m = 0; m < 2; m++) begin
    cfg2_u = m ? 8'h08 : 8'h00;
    got.delete();
    repeat (12 * P) @(negedge clk);
    a_in = 0;
    repeat (2 * P + 10) @(negedge clk);
    a_in = 1;
    repeat (10) @(negedge clk);
    a_in = 0;
    repeat (2 * P) @(negedge clk);
    a_in = 1;
    repeat (12 * P) @(negedge clk);
    if (m) b2 = got.size() >= 3 ? int'(got[2]) : -1;
    else b1 = got.size() >= 3 ? int'(got[2]) : -1;
  end
  check(b1 == 0 && b2 == 1, $sformatf("LINE2[3]: every-edge resync read %0d (expected 0), falling-only read %0d (expected 1)", b1, b2));
  $display("D: LINE2 sample points 0-3 at %0d clocks per bit, and falling-edge-only resync", P);

  // D3: the bus-idle wait. After the line was busy, a frame starts no earlier than 11 idle bit
  // times (plus pbe_line's 2-bit gap); right after a received frame end, 3 are enough.
  cfg2_u = 8'h40;
  a_in = 0;
  repeat (3 * P) @(negedge clk);
  a_in = 1;
  t_rel = clk_n;
  send_u(8'h00, 0);
  send_u(8'h00, 1);
  while (!drive_u) @(posedge clk);
  t_drv = clk_n;
  while (drive_u) @(posedge clk);
  // 11 idle samples span 10 to 11 bit times (the first may come at once), then the 2-bit gap
  check(t_drv - t_rel >= 12 * P && t_drv - t_rel <= 13 * P + 2,
        $sformatf("LINE2[6]: frame started %0d clocks after the line went idle, expected 11 idle samples + 2 bits (%0d..%0d)",
                  t_drv - t_rel, 12 * P, 13 * P + 2));
  // a received frame, then a frame queued at its end
  line_probe(1, b1);   // ends with a frame end after 8 idle bits; 4 more idle follow
  a_in = 0;
  repeat (P) @(negedge clk);
  a_in = 1;            // a 1-bit frame, ended by 8 idle bits
  while (t_fe_u < clk_n - 2) @(posedge clk);
  t_rel = t_fe_u;
  send_u(8'h00, 0);
  send_u(8'h00, 1);
  while (!drive_u) @(posedge clk);
  t_drv = clk_n;
  while (drive_u) @(posedge clk);
  check(t_drv - t_rel >= 5 * P - 2 && t_drv - t_rel <= 6 * P + 2,
        $sformatf("LINE2[6]: after a frame end the frame started %0d clocks later, expected 3 + 2 bits (about %0d)",
                  t_drv - t_rel, 5 * P));
  cfg2_u = 8'h00;
  $display("D: LINE2[6] bus-idle wait: 11 idle bits, or 3 after a frame end");
endtask

// ---------------- E: pbe_bsync ----------------
localparam int PB = 48;   // 1 Mbit/s at 48 MHz
localparam int LD = 4;    // transceiver loop delay, clocks
logic [7:0] bc_cfg = 8'h0D, bc_cfg2 = 8'h62;  // NRZ, stuff 5 equal; CAN mode, idle wait, 75 %
logic       bc_clear = 1, bc_put = 0, bc_ctl = 0, bc_drop = 0, bc_crc_ok = 1, bc_autotake = 1;
logic [4:0] bc_param = 0;
logic [7:0] bc_data = 0;
logic       ext = 1;
logic [7:0] dline = '1;
logic       bc_take;
wire        bc_drv, bc_ready, bc_rv, bc_fe, bc_err, bc_cstep, bc_cbit, bc_arb, bc_berr, bc_sent;
wire        bc_pas, bc_boff;
wire [7:0]  bc_rd, bc_rec;
wire [8:0]  bc_tec;
wire        bus = ext && !bc_drv;
always @(posedge clk) dline <= {dline[6:0], bus};
wire        bc_in = dline[LD-1];

pbe_bsync c (
    .clk, .rst_n, .clear(bc_clear), .cfg(bc_cfg), .cfg2(bc_cfg2), .period_m1(16'(PB - 1)),
    .out_msb_first(1'b1), .in_msb_first(1'b1), .a_in(bc_in), .drive(bc_drv),
    .tx_put(bc_put), .tx_data(bc_data), .tx_ready(bc_ready), .rx_valid(bc_rv), .rx_data(bc_rd),
    .rx_take(bc_take), .frame_end(bc_fe), .err(bc_err), .ctl(bc_ctl), .ctl_param(bc_param),
    .drop(bc_drop), .crc_ok(bc_crc_ok), .crc_step(bc_cstep), .crc_bit(bc_cbit),
    .arb_lost(bc_arb), .bit_err(bc_berr), .sent(bc_sent), .tec(bc_tec), .rec(bc_rec),
    .passive(bc_pas), .busoff(bc_boff)
);

logic [7:0] bgot[$];
int n_bfe = 0, n_berr = 0, n_barb = 0, n_bbe = 0, n_bsent = 0, t_bfe = -1, t_barb = -1, t_tail = -1;
int drv_on[$], drv_off[$];   // clock numbers where c starts / stops driving
logic drv_q = 0;
always @(posedge clk) begin
  bc_take <= 0;
  if (bc_autotake && bc_rv && !bc_take) begin
    bgot.push_back(bc_rd);
    bc_take <= 1;
  end
  if (bc_fe) begin n_bfe++; t_bfe = clk_n; end
  if (bc_err) n_berr++;
  if (bc_arb) begin n_barb++; t_barb = clk_n; end
  if (c.cs == 3'd3 && c.tpos == 4'd0) t_tail = clk_n;
  if (bc_berr) n_bbe++;
  if (bc_sent) n_bsent++;
  drv_q <= bc_drv;
  if (bc_drv && !drv_q) drv_on.push_back(clk_n);
  if (!bc_drv && drv_q) drv_off.push_back(clk_n);
end

// reference CAN encoder: the stuffed region (SOF first), then the tail
logic cbits[$];   // destuffed bits, SOF first (module level: Icarus 12 queue arguments)
logic cline[$];   // the line levels
logic mine[$];    // the bits c sends
task automatic can_encode(input bit with_tail);
  int run;
  logic last;
  cline.delete();
  run = 0;
  last = 1'bx;
  foreach (cbits[i]) begin
    cline.push_back(cbits[i]);
    run = (cbits[i] === last) ? run + 1 : 1;
    last = cbits[i];
    if (run == 5) begin
      cline.push_back(!last);
      last = !last;
      run = 1;
    end
  end
  if (with_tail) repeat (13) cline.push_back(1'b1);  // delimiters, ACK slot, EOF, intermission
endtask

// the other node drives cline from now, one bit every PB clocks
task automatic ext_drive();
  foreach (cline[i]) begin
    ext = cline[i];
    repeat (PB) @(negedge clk);
  end
  ext = 1;
endtask

task automatic bc_send(input logic [7:0] d);
  @(negedge clk);
  while (!bc_ready) @(negedge clk);
  bc_data = d; bc_put = 1;
  @(negedge clk);
  bc_put = 0;
endtask

task automatic bc_linectl(input logic [4:0] prm);
  @(negedge clk);
  bc_param = prm; bc_ctl = 1;
  @(negedge clk);
  bc_ctl = 0;
endtask

task automatic bc_reset();
  @(negedge clk);
  bc_clear = 1;
  ext = 1;
  repeat (3) @(negedge clk);
  bc_clear = 0;
  bgot.delete(); drv_on.delete(); drv_off.delete();
  n_bfe = 0; n_berr = 0; n_barb = 0; n_bbe = 0; n_bsent = 0;
endtask

task automatic run_bsync_tests();
  int t0, ok, base, n, k, tb_start, d, sp, b1, b2;
  logic dom;
  rst_n = 1;

  // ---- E1: integration and wait, readback of its own frame, the tail with an ACK ----
  bc_reset();
  t0 = clk_n;
  mine.delete();
  mine.push_back(0);                                    // SOF
  for (int i = 0; i < 30; i++) mine.push_back(logic'((i < 7) ? 0 : (i < 14) ? 1 : ((i * 5) % 3 == 0)));
  fork
    begin
      foreach (mine[i]) bc_send(mine[i] ? 8'h80 : 8'h00);
    end
    begin   // stuffing off as soon as the last unit is in: the tail follows
      while (bgot.size() < mine.size()) @(posedge clk);
      bc_linectl(5'b10001);
    end
    begin   // a receiver's ACK in the ACK slot
      while (!(c.cs == 3'd3 && c.tpos == 4'd1)) @(posedge clk);
      ext = 0;
      while (c.tpos == 4'd1) @(posedge clk);
      ext = 1;
    end
  join
  while (n_bfe == 0) @(posedge clk);
  check(drv_on.size() > 0 && drv_on[0] - t0 >= 11 * PB - PB / 2 && drv_on[0] - t0 <= 12 * PB + 2,
        $sformatf("bsync: own frame started %0d clocks after clear, expected 11 bit times of integration",
                  drv_on.size() ? drv_on[0] - t0 : -1));
  // every drive edge on the bit grid of its own SOF: no resync on its own (delayed) edges
  ok = 1;
  foreach (drv_on[i]) if ((drv_on[i] - drv_on[0]) % PB != 0) ok = 0;
  foreach (drv_off[i]) if ((drv_off[i] - drv_on[0]) % PB != 0) ok = 0;
  check(ok, "bsync: a drive edge off the bit grid (resynchronized on its own edge?)");
  check(bgot.size() == mine.size(), $sformatf("bsync: read back %0d bits, sent %0d", bgot.size(), mine.size()));
  foreach (mine[i]) if (i < bgot.size()) check(bgot[i] == 8'(mine[i]), $sformatf("bsync: bit %0d read %0d, sent %0d", i, bgot[i], mine[i]));
  check(n_bsent == 1 && n_berr == 0 && bc_tec == 0, $sformatf("bsync: sent %0d, errors %0d, TEC %0d", n_bsent, n_berr, bc_tec));
  // the levels it drove match the reference encoder (the stuff bits included)
  cbits.delete();
  foreach (mine[i]) cbits.push_back(mine[i]);
  can_encode(0);
  ok = 1;
  n = 0;
  for (int i = 0; i < cline.size(); i++) begin
    // c drove dominant in bit i if a drive interval covers the middle of the bit
    dom = 0;
    foreach (drv_on[j]) if (j < drv_off.size() && drv_on[0] + i * PB + PB / 2 >= drv_on[j] && drv_on[0] + i * PB + PB / 2 < drv_off[j]) dom = 1;
    if (dom != !cline[i]) begin ok = 0; n = i; end
  end
  check(ok, $sformatf("bsync: line bit %0d differs from the reference encoder (stuffing)", n));
  $display("E1: own frame after integration, %0d bits read back (%0d on the line), on the bit grid, ACKed, sent",
           bgot.size(), cline.size());

  // ---- E2: arbitration lost to a lower ID; the loser keeps receiving and ACKs ----
  repeat (16 * PB) @(negedge clk);
  bgot.delete(); drv_on.delete(); drv_off.delete(); n_barb = 0; n_bfe = 0; n_berr = 0;
  // winner: SOF, ID 0x123, RTR 0, IDE 0, r0 0, DLC 0; loser (c): ID 0x127
  cbits.delete();
  cbits.push_back(0);
  for (int i = 10; i >= 0; i--) cbits.push_back(logic'(11'h123 >> i));
  repeat (7) cbits.push_back(0);
  mine.delete();
  mine.push_back(0);
  for (int i = 10; i >= 0; i--) mine.push_back(logic'(11'h127 >> i));
  repeat (7) mine.push_back(0);
  can_encode(1);
  fork
    ext_drive();
    begin   // c joins after the SOF began (the late-join window), then queues its bits
      repeat (2) @(negedge clk);
      foreach (mine[i]) bc_send(mine[i] ? 8'h80 : 8'h00);
    end
    begin
      while (bgot.size() < cbits.size()) @(posedge clk);
      bc_linectl(5'b10001);
    end
  join
  while (n_bfe == 0) @(posedge clk);
  // the first difference: ID bit 2 (0x127 has 1, 0x123 has 0), line bit index of that bit
  check(n_barb == 1, $sformatf("bsync: %0d arbitration-lost pulses, expected 1", n_barb));
  check(bgot.size() == cbits.size(), $sformatf("bsync: loser received %0d bits, winner sent %0d", bgot.size(), cbits.size()));
  foreach (cbits[i]) if (i < bgot.size()) check(bgot[i] == 8'(cbits[i]), $sformatf("bsync: loser bit %0d is %0d, winner sent %0d", i, bgot[i], cbits[i]));
  // after the loss it drove only the ACK slot: the last drive interval starts in the tail
  ok = 1;
  foreach (drv_on[i]) if (drv_on[i] > t_barb && drv_on[i] < t_tail) ok = 0;
  foreach (drv_off[i]) if (drv_off[i] > t_barb + 1 && drv_off[i] < t_tail) ok = 0;
  check(ok, "bsync: drove after losing arbitration, before the ACK slot");
  check(drv_on.size() >= 1 && n_berr == 0 && bc_rec == 0, $sformatf("bsync: errors %0d, REC %0d after a lost arbitration", n_berr, bc_rec));
  $display("E2: arbitration lost to ID 0x123: stopped driving, received the winner's %0d bits, ACKed", bgot.size());

  // ---- E3: stuff error; the error flag starts in the next bit ----
  repeat (16 * PB) @(negedge clk);
  bgot.delete(); drv_on.delete(); drv_off.delete(); n_bfe = 0; n_berr = 0;
  cline.delete();
  repeat (6) cline.push_back(0);   // SOF and five dominant bits: the 6th breaks the stuffing rule
  repeat (20) cline.push_back(1);
  tb_start = clk_n + 1;
  ext_drive();
  // the 6th dominant bit (index 5) is sampled in bit 5; the flag starts at bit 6's start
  check(drv_on.size() >= 1, "bsync: no error flag after a stuff error");
  if (drv_on.size() >= 1) begin
    d = drv_on[0] - (tb_start + 6 * PB);
    check(d >= LD && d <= LD + 3, $sformatf("bsync: error flag started %0d clocks after bit 6 began (expected %0d..%0d)", d, LD, LD + 3));
    check(drv_off.size() >= 1 && drv_off[0] - drv_on[0] == 6 * PB, $sformatf("bsync: active error flag lasted %0d clocks, expected 6 bits (%0d)",
                                                   drv_off.size() ? drv_off[0] - drv_on[0] : -1, 6 * PB));
  end
  check(n_berr == 1 && bc_rec == 1, $sformatf("bsync: stuff error: errors %0d, REC %0d (expected 1, 1)", n_berr, bc_rec));
  $display("E3: stuff error: 6 dominant error-flag bits from the next bit, REC 1");

  // ---- E4: bit error as a transmitter, after the arbitration window ----
  repeat (24 * PB) @(negedge clk);
  bgot.delete(); drv_on.delete(); drv_off.delete(); n_bfe = 0; n_berr = 0; n_bbe = 0;
  fork
    begin
      bc_send(8'h00);              // SOF
      bc_send(8'h80); bc_send(8'h00); bc_send(8'h80);
      while (bgot.size() < 2) @(posedge clk);
      bc_linectl(5'b00000);        // width 1, arbitration window off
      bc_send(8'h80); bc_send(8'h80); bc_send(8'h00);
    end
    begin   // force dominant in the 5th bit it sends (a recessive one): a bit error
      while (bgot.size() < 4) @(posedge clk);
      while (c.sampled) @(posedge clk);   // the 5th bit has started
      tb_start = clk_n;
      ext = 0;
      repeat (PB) @(negedge clk);
      ext = 1;
    end
  join
  while (n_bfe == 0) @(posedge clk);
  repeat (20 * PB) @(negedge clk);
  check(n_bbe == 1 && bc_tec == 8, $sformatf("bsync: bit error: %0d bit-error pulses, TEC %0d (expected 1, 8)", n_bbe, bc_tec));
  k = -1;
  foreach (drv_on[i]) if (k < 0 && drv_on[i] > tb_start) k = drv_on[i];  // the first drive after the bad bit
  d = k - tb_start;
  // the forced dominant edge is a foreign edge: c resynchronizes on it (loop delay + 1), so the
  // bad bit lasts PB clocks from that edge
  check(d >= PB && d <= PB + LD + 2, $sformatf("bsync: flag after a bit error began %0d clocks after the bad bit, expected 1 bit (%0d..%0d)", d, PB, PB + LD + 2));
  $display("E4: bit error as transmitter: flag from the next bit, TEC 8");

  // ---- E5: LINECTL "error now" while receiving: the flag starts at the next bit ----
  repeat (16 * PB) @(negedge clk);
  drv_on.delete(); drv_off.delete(); n_berr = 0;
  cline.delete();
  cline.push_back(0);
  repeat (4) begin cline.push_back(1); cline.push_back(0); end
  repeat (20) cline.push_back(1);
  fork
    ext_drive();
    begin
      repeat (3 * PB + PB / 3) @(negedge clk);   // in the middle of bit 3
      tb_start = clk_n;
      bc_linectl(5'b10100);
    end
  join
  check(drv_on.size() >= 1, "bsync: no error flag after LINECTL error now");
  if (drv_on.size() >= 1) begin
    d = drv_on[0] - tb_start;
    check(d > 0 && d <= PB, $sformatf("bsync: error now: flag began %0d clocks later, expected within the bit", d));
  end
  check(n_berr == 1 && bc_rec == 2, $sformatf("bsync: error now: errors %0d, REC %0d (expected 1, 2)", n_berr, bc_rec));
  $display("E5: LINECTL error now: flag from the next bit start, REC 2");

  // ---- E6: sample points 0-3 (falling-edge-only resync: the rising edge inside the bit
  // does not move the sample). As in D1, X <= sample + 1 reads 1. ----
  for (int s2 = 0; s2 < 4; s2++) begin
    sp = (PB - 1) / 2 + 1 + s2 * (PB / 8);
    for (int v = 0; v < 2; v++) begin
      bc_cfg2 = 8'h20 | 8'(s2);
      bc_reset();
      repeat (12 * PB) @(negedge clk);
      ext = 0;
      repeat (PB) @(negedge clk);
      repeat (sp + 1 + v) @(negedge clk);
      ext = 1;
      repeat (3 * PB) @(negedge clk);
      if (v == 0) b1 = bgot.size() >= 2 ? int'(bgot[1]) : -1;
      else b2 = bgot.size() >= 2 ? int'(bgot[1]) : -1;
    end
    check(b1 == 1 && b2 == 0, $sformatf("bsync sample point %0d (%0d clocks): read %0d, %0d (expected 1, 0)", s2, sp, b1, b2));
  end
  bc_cfg2 = 8'h62;
  $display("E6: bsync sample points 0-3 at %0d clocks per bit", PB);
  bc_reset();
  bc_clear = 1;
endtask
