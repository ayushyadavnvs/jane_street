// Line coder: an optional stage between an engine's shift registers and its line pin(s).
//
// It owns the bit timing (one bit every period_m1 + 1 clocks), because bits it inserts or
// removes (stuffing) must not cost the program anything (v2 lesson, docs/USB_NOTES.md).
//
//   cfg[1:0]  mode       0 off, 1 NRZ (the bit is the level), 2 NRZI (0 = change level, 1 = keep),
//                        3 Manchester (D90, see below)
//   cfg[3:2]  stuffing   0 none, 1 after 6 ones (USB), 2 after 5 ones (HDLC), 3 after 5 equal (CAN)
//   cfg[4]    pair       pin a carries the line, pin b its complement; both low (SE0) ends a frame
//   cfg[5]    bytes      the engine transfers whole bytes (else single bits)
//   cfg[6]    flag-delimited frames (HDLC, D94; not with Manchester): a stuffing violation
//             ends the frame at either line level, and reception goes on: the bit after the
//             violation is the first of the next frame (a flag's last 0, or an abort's 7th 1).
//             The "8 idle bits" frame end is off. Without it a violation ends a frame only at
//             the idle (high) level, and reception then waits for the line to leave it.
//   cfg[7]    Manchester only: the other polarity (a 1 is high then low, as G.E. Thomas and
//             MIL-STD-1553); 0 is IEEE 802.3's (a 1 is low then high). Reserved otherwise.
//   cfg2      LINE2 (D65), every bit 0 = the behaviour described below:
//     [2:0]   sample point: 0 the default, floor(period_m1/2)+1; 1, 2, 3 add N/8, N/4, 3N/8
//             (N = period_m1 + 1, shifted copies, no multiplier): 62.5 %, 75 %, 87.5 % of the
//             bit when N is a multiple of 8. 4-7 are reserved and act as 0.
//     [3]     resynchronize the receive timer on falling edges only (else on every edge)
//     [4]     the receive pin is pin_base+1 (handled by the engine; pair mode must be off)
//     [5]     bit-synchronous (CAN) mode: pbe_bsync replaces this module's timing (engine)
//     [6]     before a frame starts, wait until the line has been idle for 11 bit times, or
//             for 3 after the end of a received frame (counted at the receive sample point)
//     [7]     the CAN frame follower of pbe_bsync (D74); not used here
//
// Transmit: tx_put queues a byte (or a bit in tx_data[0]), tx_end queues "end of frame"; one
// entry is buffered (tx_ready). A frame starts with 2 idle bit times (an inter-packet gap) and
// then sends the sync byte (if not zero), the queued data, and on tx_end: in pair mode SE0, SE0,
// one bit of idle level, then it lets go of the line; otherwise it lets go at once.
// Receive: a frame starts when the line leaves the idle level (1). Sampling is mid-bit, and
// every edge re-centres the bit timer, so clock errors do not add up over a frame. Decoded bits
// are unstuffed (a stuff bit with the wrong value is an error) and, if sync is not zero,
// dropped until the last 8 bits equal sync. Then bytes (or bits) are delivered in rx_data.
// The frame ends on SE0 followed by the idle level (pair mode); otherwise after 8 bit times at
// the idle level, or when a run at the idle level breaks the stuffing rule. frame_end pulses, and
// a byte of that frame the engine has not taken is dropped.
//
// Stuffing control (D94): LINECTL (ctl, ctl_param[4] = 1) [0] stuffing off, [1] stuffing on
// (both: on). It applies to the units queued after it, so a program sends an unstuffed flag
// as an ordinary byte between STUFFOFF and STUFFON, inside one coder frame, and the NRZI level
// stays continuous through it. The SYNC byte is always stuffed. The other LINECTL controls are
// the bit-synchronous coder's (ignored here). Reset and clear: stuffing on.
//
// Manchester (cfg[1:0] = 3, D90). Each bit is two halves, the second the bit's value and the
// first its complement (IEEE 802.3 clause 7.3.1.1: "during the first half of the bit-symbol
// the encoded signal is the logical complement of the bit value"; so a 1 is low then high and
// there is a transition in the middle of every bit). cfg[7] swaps the halves. No stuffing
// (cfg[3:2] is ignored); SYNC, bytes/bits, pair and the bit order work as in the other modes.
//   Transmit: the first half is floor(period_m1/2) + 1 clocks, the second the rest of the bit
//   (3 + 3 at 6 clocks per bit). After END, the line is held at the high level for 3 bit times
//   (a and b complementary in pair mode), then let go: 10BASE-T's TP_IDL (clause 14.3.1.2.1)
//   and DALI's stop condition. A transmit underrun holds the level (no transitions).
//   Receive: clock recovery from the edges (D101). A bit timer holds the expected mid-bit point;
//   the edge after a mid-bit transition is decided by the next edge: if it comes while the two
//   times (from the reference) add up to less than T, the first was a bit boundary and the
//   second is the mid-bit transition; otherwise the first was the mid-bit transition. T is 2
//   bits plus the learnt lateness of mid-bit transitions after a boundary (inter-symbol
//   interference), 2.5 bits while hunting for SYNC, where repeats SYNC never has are
//   impossible. The level after a mid-bit transition is the bit (inverted with cfg[7]). Each
//   mid-bit transition moves the timer by 1/8 of its error (1/8-clock resolution). Edges
//   are timed to half a clock: a_early is the pin sampled on the falling clock edge (the top
//   level's negedge synchronizer), so the receiver samples on both clock edges. The first
//   transition after idle starts a frame and is taken as the mid-bit transition of a bit that
//   is not delivered (a preamble or start bit).
//   No transition for 2N clocks ends the carrier: frame_end pulses, but only for a frame whose
//   SYNC was found (or SYNC = 0), so link pulses and stray edges end silently. Overrun, sync
//   and delivery are as in the other modes. LINE2's sample point, resync and idle wait do not
//   apply.
//
// Cycle contract clarified by the round-2 model audit (existing behavior):
// - clear/reset empties queues/state, releases drive, sets a_out/b_out=1/0 and previous
//   level=1, and clears data/valid/event outputs. The engine asserts clear while mode=off;
//   standalone callers must do so too. Mode 3 is reserved, with no promised behavior.
// - Transfers observe tx_ready before the edge. A newly queued item is considered on a
//   later edge; tx_end wins if asserted with tx_put. Producers must not enqueue while
//   !tx_ready. END without an active frame is consumed without driving. The gap leaves
//   drive low; after two bit periods, the following clock emits the first sync/data bit.
// - TX/RX timers are 16 bits and compare the old count. TX boundaries use == period_m1;
//   RX sample is old_count == floor(period_m1/2)+1. An input edge resets the NEXT count
//   but does not cancel a sample already due on that edge. At period_m1=0 RX cannot
//   sample (its count remains 0); there is no universal receive guarantee at that rate.
// - Sync and payload share stuffing/run state across entry boundaries. Stuffed bits pass
//   through NRZI too. Initial previous bit/level=1, run=0; inserted ones-style bits reset
//   run to 0, inserted equal-style bits start a new run of length 1. A TX underrun pulses
//   err at each empty bit boundary and holds the driven level until new data/end arrives.
// - RX is suppressed throughout non-idle TX states, including gap and end sequence. A low
//   level starts RX even without a new edge; SE0 takes priority. Initial NRZI previous
//   sampled level=1. The sync window is zero-filled, so it can match before 8 received
//   bits. Transfer bit order follows in_msb_first/out_msb_first, including sync.
// - A receive stuff violation advances run/sample state; in single mode an idle-high
//   violation ends the frame without err. Pair SE0 length is not checked: the first later
//   sampled non-SE0 returns idle, and pulses frame_end only if a_in=1. Single mode's 8th
//   idle-high sample can also deliver data. Arbitrary data with no sync or long idle runs
//   is therefore not guaranteed to round-trip without framing restrictions.
// - RX overrun replaces the unread unit and pulses err; coincident rx_take allows the
//   replacement without err. frame_end/err are registered one-clock indications. On the
//   NEXT edge, old frame_end clears rx_valid, winning over a new unit/take that edge.
// - Release clears drive but keeps output latches. Configuration is read live; changing
//   mode/period/width/shift direction mid-frame has no protocol-validity guarantee.
module pbe_line (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        clear,
    input  logic [7:0]  cfg,
    input  logic [7:0]  cfg2,
    input  logic [7:0]  sync,
    input  logic [15:0] period_m1,
    input  logic        out_msb_first,
    input  logic        in_msb_first,
    // line pins
    input  logic        a_in,        // synchronized levels
    input  logic        a_early,     // a_in's pin sampled half a clock earlier (Manchester, D90)
    input  logic        b_in,
    output logic        drive,       // the coder owns the line pin(s)
    output logic        a_out,
    output logic        b_out,
    // transmit
    input  logic        ctl,         // LINECTL (D94): stuffing off/on for the units queued after it
    input  logic [4:0]  ctl_param,
    input  logic        tx_put,
    input  logic        tx_end,
    input  logic [7:0]  tx_data,
    output logic        tx_ready,
    // receive
    output logic        rx_valid,
    output logic [7:0]  rx_data,
    input  logic        rx_take,
    output logic        frame_end,   // pulse
    output logic        err          // pulse: stuff error, receive overrun or transmit underrun
);
  wire       nrzi  = cfg[1:0] == 2'd2;
  wire       manch = cfg[1:0] == 2'd3;                 // Manchester (D90)
  wire       minv  = cfg[7];                           // Manchester polarity
  wire       flagd = cfg[6] && !manch;                // flag-delimited frames (D94)
  wire       _unused = &{cfg2[7], cfg2[5:4], ctl_param[3:2], 1'b0};  // [5:4] are the engine's
  wire [2:0] sp_sel = cfg2[2:0];
  wire       fall_only = cfg2[3];
  wire       idle_wait = cfg2[6] && !manch;  // D90: ignored in Manchester
  wire [1:0] st    = manch ? 2'd0 : cfg[3:2];
  wire       pair  = cfg[4];
  wire       bytes = cfg[5];
  wire       ones  = st != 2'd3;                    // stuff after ones, else after equal bits
  wire [2:0] run_n = (st == 2'd1) ? 3'd6 : 3'd5;
  wire [3:0] width = bytes ? 4'd8 : 4'd1;

  // ---------------- transmit ----------------
  localparam logic [2:0] T_IDLE = 3'd0, T_GAP = 3'd1, T_RUN = 3'd2, T_SE0A = 3'd3, T_SE0B = 3'd4,
                         T_J = 3'd5;
  logic [2:0]  ts;
  logic [15:0] tcnt;
  logic        gap2, kick;           // second gap bit; emit a bit now (frame start)
  logic        q_valid, q_end;
  logic [7:0]  q_data, tsh;
  logic [3:0]  tbits;                // bits left in tsh
  logic        level;                // line level, 1 = idle (USB J)
  logic [2:0]  trun;
  logic        tlast, tstuff;        // stuff bit due in the next slot
  logic        mhalf;                // Manchester: the level of the current bit's second half
  logic        ns_mode, q_ns, tns;   // stuffing off (D94): now, for the queued unit, for tsh

  assign tx_ready = !q_valid;
  wire boundary = tcnt == period_m1;
  wire tmid     = tcnt == {1'b0, period_m1[15:1]};  // Manchester: the end of a first half

  // what the next bit slot sends
  wire        n_load = !tstuff && tbits == 4'd0 && q_valid && !q_end;
  wire [7:0]  q_bits = (!bytes && out_msb_first) ? {q_data[0], 7'b0} : q_data;
  wire [7:0]  n_src  = n_load ? q_bits : tsh;
  wire        n_bit  = tstuff ? (ones ? 1'b0 : !tlast) : (out_msb_first ? n_src[7] : n_src[0]);
  wire        n_have = tstuff || tbits != 4'd0 || n_load;
  wire        n_end  = !tstuff && tbits == 4'd0 && q_valid && q_end;
  wire [3:0]  n_left = n_load ? width - 4'd1 : tbits - 4'd1;
  wire [7:0]  n_rest = out_msb_first ? {n_src[6:0], 1'b0} : {1'b0, n_src[7:1]};
  // stuffing state after this bit
  logic [2:0] n_run;
  logic       n_last;
  always_comb begin
    if (tstuff) begin
      n_run  = ones ? 3'd0 : 3'd1;
      n_last = n_bit;
    end else if (ones) begin
      n_run  = n_bit ? trun + 3'd1 : 3'd0;
      n_last = n_bit;
    end else begin
      n_run  = (n_bit == tlast) ? trun + 3'd1 : 3'd1;
      n_last = n_bit;
    end
  end
  wire n_ns    = n_load ? q_ns : tns;  // the bit comes from a unit sent with stuffing off
  wire n_stuff = !tstuff && st != 2'd0 && !n_ns && n_run == run_n;
  wire n_level = nrzi ? (n_bit ? level : !level) : n_bit;

  // ---------------- receive ----------------
  localparam logic [1:0] R_IDLE = 2'd0, R_RUN = 2'd1, R_SE0 = 2'd2;
  logic [1:0]  rs;
  logic [15:0] rcnt;
  logic        a_d, rprev, rlast, rstuff, hunting;
  logic [2:0]  rrun, ridle;
  logic [7:0]  win, rsh;
  logic [3:0]  rbits;

  wire        se0    = pair && !manch && !a_in && !b_in;
  // sample point (LINE2[2:0]); 0 is the original floor(period_m1/2)+1
  wire [15:0] n_per  = period_m1 + 16'd1;
  wire        _unused_nper = &{n_per[1:0], 1'b0};
  logic [15:0] sp_add;
  always_comb begin
    case (sp_sel)
      3'd1:    sp_add = {3'b0, n_per[15:3]};
      3'd2:    sp_add = {2'b0, n_per[15:2]};
      3'd3:    sp_add = {2'b0, n_per[15:2]} + {3'b0, n_per[15:3]};
      default: sp_add = 16'd0;
    endcase
  end
  // The default sample point is computed as before. The others come from a register,
  // updated every clock from CLKDIV and LINE2, so the adders are not on the counter's
  // compare path (timing review of D65); a change of either takes effect one clock later.
  // sp_ok: sp_q holds a computed value (from the first clock after reset); before it, sp_q's
  // reset 0 matched rcnt's and sample points 1-3 also sampled at the first clock (BUG-104).
  wire [15:0] sp_base = {1'b0, period_m1[15:1]} + 16'd1;
  logic [15:0] sp_q;
  logic        sp_ok;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      sp_q  <= '0;
      sp_ok <= 1'b0;
    end else begin
      sp_q  <= sp_base + sp_add;
      sp_ok <= 1'b1;
    end
  // Manchester receive (D101, replacing D90's single-threshold loop: BUG-151). Times are in
  // 1/8 clocks; a bit is 8N (N = period_m1 + 1). The time since the reference (the expected
  // position of the last mid-bit transition) at this clock edge is mcnt + 8; an edge seen now
  // came then, or 4 earlier if it was already there at the falling clock edge (a_early).
  // The edge after a mid-bit transition is either a boundary (nominally 4N later) or the next
  // mid-bit transition (8N). One edge alone cannot tell them apart under the full 802.3 jitter,
  // so the decision waits for the following edge: the first edge E1 becomes pending (p_tau,
  // its time), and
  //   - if a further edge E2 comes while the two times add up to less than T, E1 was a
  //     boundary and E2 is the mid-bit transition (nominal sum 4N + 8N = 12N);
  //   - once they reach T (at an edge E2, or E1's time plus now), E1 was the mid-bit
  //     transition (nominal sum 8N + 12N = 20N or more) and E2, if any, is the next pending edge.
  // T = 16N + m_b: m_b is the mean phase error of the mid-bit transitions that follow a boundary
  // (gain 1/2, 1/4, 1/8, then 1/16 from the start of the frame), which inter-symbol interference
  // moves late against the transitions that follow a mid-bit one; the threshold follows it.
  // While hunting for SYNC, T = 20N, and a repeated bit that SYNC never repeats (Ethernet: two
  // 0s) is impossible, so the edge after it is taken as a mid-bit transition at once. Each
  // mid-bit transition moves the reference by 1/8 of its error. No mid-bit transition and no
  // pending edge for 2 bit times (16N) ends the carrier. A pending edge under 5/8 bit after the
  // reference that is not followed in time is dropped (no bit). T and 5N are registered (one
  // clock late after a CLKDIV change, like sp_q).
  // Timing: mcnt and p_tau are kept 8 eighths (one clock) low, as in D90, so the constants are
  // shifted copies of CLKDIV (8N - 8 = 8 period_m1, 16N - 8 = 16 period_m1 + 8, no adder);
  // everything is computed from registers for both possible edge times, and the pins only
  // select among the results.
  logic signed [23:0] mcnt, p_tau, m_b;          // mcnt, p_tau: time - 8; m_b: + 8N - 8
  logic               p_v, p_force;
  logic        [1:0]  m_gear;
  logic        [23:0] m_t;                                   // T - 16 (registered)
  logic        [23:0] m_5n;                                  // 5N - 8 (registered)
  wire         [23:0] m_8p  = {5'b0, period_m1, 3'b000};      // 8N - 8
  wire         [23:0] m_16p = {4'b0, period_m1, 4'b0000};     // 16N - 16
  wire         [23:0] m_end = {4'b0, period_m1, 4'b1000};     // 16N - 8
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) m_5n <= '0;
    else m_5n <= {6'b0, period_m1, 2'b00} + {8'b0, period_m1} - 24'd3;   // 5 period_m1 - 3
  wire               m_edge  = a_in != a_d;
  wire               m_early = m_edge && a_early != a_d;     // the edge came in the first half
  // E1 is decided once p_tau + (the edge's time, or now) reaches T
  // (one three-operand sum each: a carry-save stage and one carry chain, the sign is the compare)
  wire signed [24:0] m_d0    = {p_tau[23], p_tau} + {mcnt[23], mcnt} - {m_t[23], m_t};
  wire signed [24:0] m_d4    = {p_tau[23], p_tau} + {mcnt[23], mcnt} - {m_t[23], m_t} - 25'sd4;
  wire               m_c0    = !m_d0[24];
  wire               m_c4    = !m_d4[24];
  wire               _unused_md = &{1'b0, m_d0[23:0], m_d4[23:0]};
  wire               m_res   = p_v && (p_force || (m_early ? m_c4 : m_c0));  // E1 resolved
  // E1 resolved as mid-bit but under 5/8 bit after the reference: no mid-bit transition comes
  // that early within 802.3's jitter; a lone edge there (the end of TP_IDL after a 0, a stray
  // edge) is dropped, as D90 skipped it
  wire               m_junk  = m_res && !p_force && p_tau < $signed(m_5n);
  wire               m_fire  = m_res && !m_junk;                 // E1 was mid-bit
  wire               m_rep1  = |(sync[7:1] & sync[6:0]);     // SYNC repeats a 1
  wire               m_rep0  = |(~sync[7:1] & ~sync[6:0]);   // SYNC repeats a 0
  wire               m_lastb = a_d ^ minv;                    // the last bit (or E1's)
  wire               m_once  = hunting && !(m_lastb ? m_rep1 : m_rep0);  // no repeat possible
  wire               m_bmid  = !m_res && m_edge && p_v;       // E1 was a boundary: a mid
  wire               m_amid  = !m_res && m_edge && !p_v && m_once;
  wire               m_mid   = m_fire || m_bmid || m_amid;    // a bit is delivered
  wire               m_lost  = !p_v && mcnt >= $signed(m_end);
  // A mid-bit transition err late moves the reference by 8N + err/8 (rounded): E1's (fire)
  // or this edge's (both times). err = time - 8N = (time - 8) - 8 period_m1.
  // A rounded (x + 2^(k-1)) >>> k is (x >>> k) + x[k-1]: the bit becomes the next adder's carry.
  wire signed [23:0] m_ep    = p_tau - $signed(m_8p);
  wire signed [23:0] m_e0    = mcnt - $signed(m_8p);
  wire signed [23:0] m_ep3   = m_ep >>> 3;                      // (own wires: the shifts must
  wire signed [23:0] m_e03   = m_e0 >>> 3;                      //  be arithmetic)
  wire signed [23:0] m_np    = m_e0 - m_ep3 - {23'b0, m_ep[2]};  // the candidates
  wire signed [23:0] m_n0    = m_e0 - m_e03 - {23'b0, m_e0[2]};
  wire signed [23:0] m_n4    = m_e0 - m_e03;                    // (e0 - 4 + 4) >>> 3
  wire signed [23:0] m_next  = m_fire ? m_np : m_early ? m_n4 : m_n0;
  wire signed [23:0] m_t4    = mcnt - 24'sd4;                   // an early edge's time
  wire signed [23:0] m_q0    = m_np - 24'sd8;                   // E2's time after E1 is taken
  wire signed [23:0] m_q4    = m_np - 24'sd12;
  // m_b moves by (err - m_b) / 2^(gear + 1), rounded
  wire signed [23:0] m_bd0   = mcnt - m_b;                      // err - (m_b's mean)
  wire signed [23:0] m_bd4   = m_bd0 - 24'sd4;
  logic signed [23:0] m_bs0, m_bs4;
  logic               m_br0, m_br4;
  always_comb
    case (m_gear)
      2'd0:    begin m_bs0 = m_bd0 >>> 1; m_br0 = m_bd0[0]; m_bs4 = m_bd4 >>> 1; m_br4 = m_bd4[0]; end
      2'd1:    begin m_bs0 = m_bd0 >>> 2; m_br0 = m_bd0[1]; m_bs4 = m_bd4 >>> 2; m_br4 = m_bd4[1]; end
      2'd2:    begin m_bs0 = m_bd0 >>> 3; m_br0 = m_bd0[2]; m_bs4 = m_bd4 >>> 3; m_br4 = m_bd4[2]; end
      default: begin m_bs0 = m_bd0 >>> 4; m_br0 = m_bd0[3]; m_bs4 = m_bd4 >>> 4; m_br4 = m_bd4[3]; end
    endcase
  wire signed [23:0] m_b0    = m_b + m_bs0 + {23'b0, m_br0};
  wire signed [23:0] m_b4    = m_b + m_bs4 + {23'b0, m_br4};
  wire        sp_dflt = sp_sel == 3'd0 || sp_sel[2];
  wire        sample = rcnt == (sp_dflt ? sp_base : sp_q) && (sp_dflt || sp_ok);
  // LINE2[6]: idle bit times seen at the sample point (saturating at 11), and whether the
  // last thing on the line was the end of a frame (then 3 idle bits are enough)
  logic [3:0] icnt;
  logic       after_end;
  wire        tx_ok = !idle_wait || icnt == 4'd11 || (after_end && icnt >= 4'd3);
  wire        r_bit  = nrzi ? (a_in == rprev) : a_in;
  wire        r_exp  = ones ? 1'b0 : !rlast;           // value a stuff bit must have
  logic [2:0] r_run;
  always_comb begin
    if (rstuff)    r_run = ones ? 3'd0 : 3'd1;
    else if (ones) r_run = r_bit ? rrun + 3'd1 : 3'd0;
    else           r_run = (r_bit == rlast) ? rrun + 3'd1 : 3'd1;
  end
  wire [7:0] win_n = in_msb_first ? {win[6:0], r_bit} : {r_bit, win[7:1]};
  wire [7:0] rsh_n = in_msb_first ? {rsh[6:0], r_bit} : {r_bit, rsh[7:1]};
  wire       m_bit = (m_fire ? a_d : a_in) ^ minv;        // Manchester: the level after mid-bit
  wire [7:0] m_win = in_msb_first ? {win[6:0], m_bit} : {m_bit, win[7:1]};
  // the SYNC compare for both possible bits, selected after (timing: m_fire is late)
  wire [7:0] m_wd  = in_msb_first ? {win[6:0], a_d ^ minv} : {a_d ^ minv, win[7:1]};
  wire [7:0] m_wi  = in_msb_first ? {win[6:0], a_in ^ minv} : {a_in ^ minv, win[7:1]};
  wire       m_hit = m_fire ? m_wd == sync : m_wi == sync;
  wire [7:0] m_rsh = in_msb_first ? {rsh[6:0], m_bit} : {m_bit, rsh[7:1]};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ts <= T_IDLE; tcnt <= '0; gap2 <= 1'b0; kick <= 1'b0;
      q_valid <= 1'b0; q_end <= 1'b0; q_data <= '0; tsh <= '0; tbits <= '0;
      level <= 1'b1; trun <= '0; tlast <= 1'b1; tstuff <= 1'b0;
      drive <= 1'b0; a_out <= 1'b1; b_out <= 1'b0;
      rs <= R_IDLE; rcnt <= '0; a_d <= 1'b1; rprev <= 1'b1; rlast <= 1'b1; rstuff <= 1'b0;
      hunting <= 1'b0; rrun <= '0; ridle <= '0; win <= '0; rsh <= '0; rbits <= '0;
      rx_valid <= 1'b0; rx_data <= '0; frame_end <= 1'b0; err <= 1'b0;
      icnt <= '0; after_end <= 1'b0; mhalf <= 1'b1; mcnt <= '0;
      p_v <= 1'b0; p_force <= 1'b0; p_tau <= '0; m_b <= '0; m_gear <= '0; m_t <= '0;
      ns_mode <= 1'b0; q_ns <= 1'b0; tns <= 1'b0;
    end else if (clear) begin
      ts <= T_IDLE; tcnt <= '0; gap2 <= 1'b0; kick <= 1'b0;
      q_valid <= 1'b0; q_end <= 1'b0; q_data <= '0; tsh <= '0; tbits <= '0;
      level <= 1'b1; trun <= '0; tlast <= 1'b1; tstuff <= 1'b0;
      drive <= 1'b0; a_out <= 1'b1; b_out <= 1'b0;
      rs <= R_IDLE; rcnt <= '0; a_d <= 1'b1; rprev <= 1'b1; rlast <= 1'b1; rstuff <= 1'b0;
      hunting <= 1'b0; rrun <= '0; ridle <= '0; win <= '0; rsh <= '0; rbits <= '0;
      rx_valid <= 1'b0; rx_data <= '0; frame_end <= 1'b0; err <= 1'b0;
      icnt <= '0; after_end <= 1'b0; mhalf <= 1'b1; mcnt <= '0;
      p_v <= 1'b0; p_force <= 1'b0; p_tau <= '0; m_b <= '0; m_gear <= '0; m_t <= '0;
      ns_mode <= 1'b0; q_ns <= 1'b0; tns <= 1'b0;
    end else begin
      frame_end <= 1'b0;
      err       <= 1'b0;

      // ---- transmit ----
      if (tx_put || tx_end) begin
        q_valid <= 1'b1;
        q_end   <= tx_end;
        q_data  <= tx_data;
        q_ns    <= ns_mode;
      end
      if (ctl && ctl_param[4]) begin    // LINECTL STUFFOFF / STUFFON (D94)
        if (ctl_param[1]) ns_mode <= 1'b0;
        else if (ctl_param[0]) ns_mode <= 1'b1;
      end
      tcnt <= (ts == T_IDLE || boundary || kick) ? 16'd0 : tcnt + 16'd1;
      kick <= 1'b0;
      case (ts)
        T_IDLE:
          if (q_valid) begin
            if (q_end) q_valid <= 1'b0;  // end with no frame: nothing to do
            else if (tx_ok) begin
              ts   <= T_GAP;
              gap2 <= 1'b0;
            end
          end
        T_GAP:
          if (boundary) begin
            gap2 <= 1'b1;
            if (gap2) begin             // the gap is over: start the frame
              ts     <= T_RUN;
              kick   <= 1'b1;
              level  <= 1'b1;
              trun   <= '0;
              tlast  <= 1'b1;
              tstuff <= 1'b0;
              tsh    <= sync;
              tns    <= 1'b0;             // the SYNC byte is stuffed
              tbits  <= (sync != 8'd0) ? 4'd8 : 4'd0;
            end
          end
        T_RUN:
          if (boundary || kick) begin
            if (n_have) begin
              level  <= n_level;
              a_out  <= manch ? !(n_bit ^ minv) : n_level;  // Manchester: the first half
              b_out  <= manch ? (n_bit ^ minv) : !n_level;
              mhalf  <= n_bit ^ minv;
              drive  <= 1'b1;
              trun   <= n_run;
              tlast  <= n_last;
              tstuff <= n_stuff;
              if (!tstuff) begin
                tsh   <= n_rest;
                tbits <= n_left;
              end
              if (n_load) begin
                q_valid <= 1'b0;
                tns     <= q_ns;
              end
            end else if (n_end) begin
              q_valid <= 1'b0;
              if (manch) begin              // TP_IDL: high for 3 bit times (SE0A, SE0B, J)
                ts    <= T_SE0A;
                a_out <= 1'b1;
                b_out <= 1'b0;
                drive <= 1'b1;
              end else if (pair) begin
                ts    <= T_SE0A;
                a_out <= 1'b0;
                b_out <= 1'b0;
              end else begin
                ts    <= T_IDLE;
                drive <= 1'b0;
              end
            end else err <= 1'b1;       // underrun: the line keeps its level
          end else if (manch && tmid && drive) begin  // Manchester: the second half
            a_out <= mhalf;
            b_out <= !mhalf;              // (an underrun keeps mhalf: the level holds)
          end
        T_SE0A: if (boundary) ts <= T_SE0B;
        T_SE0B:
          if (boundary) begin
            ts    <= T_J;
            a_out <= 1'b1;
            b_out <= 1'b0;
          end
        default:                        // T_J: one bit of idle level, then let go
          if (boundary) begin
            ts    <= T_IDLE;
            drive <= 1'b0;
            level <= 1'b1;
          end
      endcase

      // ---- receive (off while transmitting: half duplex) ----
      a_d <= a_in;
      if (rx_take) rx_valid <= 1'b0;
      rcnt <= ((fall_only ? (a_d && !a_in) : (a_in != a_d)) || rcnt == period_m1) ? 16'd0 : rcnt + 16'd1;
      // Manchester (D101): the bit timer; the first edge of a frame is the reference
      m_t <= hunting ? m_16p + {6'b0, period_m1, 2'b00} + 24'd4 : m_8p + m_b;  // T - 16
      if (rs != R_RUN || !manch) begin
        mcnt <= m_early ? 24'sd4 : 24'sd0;
        p_v <= 1'b0; p_force <= 1'b0; p_tau <= '0; m_b <= m_8p; m_gear <= '0;
      end else begin
        // a mid-bit transition err late: the reference moves 8N + err/8
        if (m_mid) mcnt <= m_next;
        else if (!m_lost) mcnt <= mcnt + 24'sd8;
        if (m_fire) begin               // E1 was mid-bit; this edge (if any) is pending
          p_v     <= m_edge;
          p_tau   <= m_early ? m_q4 : m_q0;
          p_force <= m_once;
        end else if (m_junk) begin      // E1 dropped; this edge (if any) is pending
          p_v     <= m_edge;
          p_tau   <= m_early ? m_t4 : mcnt;
          p_force <= 1'b0;
        end else if (m_bmid) p_v <= 1'b0;
        else if (m_edge && !m_amid) begin
          p_v     <= 1'b1;
          p_tau   <= m_early ? m_t4 : mcnt;
          p_force <= 1'b0;
        end
        if (m_bmid) begin               // after a boundary: the class the threshold follows
          m_b <= m_early ? m_b4 : m_b0;
          if (m_gear != 2'd3) m_gear <= m_gear + 2'd1;
        end
      end
      if (sample) begin
        if (!a_in || ts != T_IDLE || rs != R_IDLE) icnt <= 4'd0;
        else if (icnt != 4'd11) icnt <= icnt + 4'd1;
      end
      if (frame_end) after_end <= 1'b1;
      else if (sample && !a_in) after_end <= 1'b0;
      if (ts != T_IDLE) rs <= R_IDLE;
      else if (manch) begin
        if (rs != R_RUN) begin
          if (m_edge) begin             // carrier: a frame starts (this bit is not delivered)
            rs      <= R_RUN;
            hunting <= sync != 8'd0;
            win     <= '0;
            rbits   <= '0;
          end
        end else if (m_mid) begin       // a mid-bit transition: the bit is the level after it
          if (hunting) begin
            win <= m_win;
            if (m_hit) hunting <= 1'b0;
          end else if (rbits == width - 4'd1) begin
            rx_data  <= bytes ? m_rsh : {7'b0, m_bit};
            if (rx_valid && !rx_take) err <= 1'b1;  // the engine missed one
            rx_valid <= 1'b1;
            rbits    <= '0;
            rsh      <= m_rsh;
          end else begin
            rbits <= rbits + 4'd1;
            rsh   <= m_rsh;
          end
        end else if (m_lost) begin      // no transition for 2 bit times: the carrier ended
          rs        <= R_IDLE;
          frame_end <= !hunting;
        end
      end else case (rs)
        R_IDLE:
          if (se0) rs <= R_SE0;
          else if (!a_in) begin         // the line left the idle level: a frame starts
            rs      <= R_RUN;
            rprev   <= 1'b1;
            rlast   <= 1'b1;
            rrun    <= '0;
            rstuff  <= 1'b0;
            ridle   <= '0;
            hunting <= sync != 8'd0;
            win     <= '0;
            rbits   <= '0;
          end
        R_RUN:
          if (sample) begin
            if (se0) rs <= R_SE0;
            else begin
              rprev <= a_in;
              rlast <= rstuff ? r_exp : r_bit;
              rrun  <= r_run;
              // without SE0, a frame ends after 8 bit times at the idle level
              ridle <= a_in ? ridle + 3'd1 : 3'd0;
              if (!pair && !flagd && a_in && ridle == 3'd7) begin
                rs        <= R_IDLE;
                frame_end <= 1'b1;
              end
              if (rstuff) begin
                rstuff <= 1'b0;
                if (r_bit != r_exp) begin
                  // Without SE0, a run too long for stuffing at the idle level is how a frame
                  // ends (HDLC flag or abort, CAN end of frame); anywhere else it is an error.
                  // Flag-delimited (D94): at either level, and the next frame starts with the
                  // next bit (the run count restarts, r_run = 0).
                  if (!pair && flagd) begin
                    frame_end <= 1'b1;
                    hunting   <= sync != 8'd0;
                    win       <= '0;
                    rbits     <= '0;
                  end else if (!pair && a_in) begin
                    rs        <= R_IDLE;
                    frame_end <= 1'b1;
                  end else err <= 1'b1;
                end
              end else begin
                rstuff <= st != 2'd0 && r_run == run_n;
                if (hunting) begin
                  win <= win_n;
                  if (win_n == sync) hunting <= 1'b0;
                end else if (rbits == width - 4'd1) begin
                  rx_data  <= bytes ? rsh_n : {7'b0, r_bit};
                  if (rx_valid && !rx_take) err <= 1'b1;  // the engine missed one
                  rx_valid <= 1'b1;
                  rbits    <= '0;
                  rsh      <= rsh_n;
                end else begin
                  rbits <= rbits + 4'd1;
                  rsh   <= rsh_n;
                end
              end
            end
          end
        default:                        // R_SE0: wait for the idle level
          if (sample && !se0) begin
            rs        <= R_IDLE;
            frame_end <= a_in;
          end
      endcase
      // A byte the engine has not taken when its frame ends belongs to that frame: drop it,
      // so it cannot be read as the start of the next frame (BUG-028).
      if (frame_end) rx_valid <= 1'b0;
    end
  end
endmodule
