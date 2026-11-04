`timescale 1ns / 1ps
// Reference classic-CAN node for tb_can, written from ISO 11898-1:2015 / Bosch CAN 2.0A, not
// from the RTL. Behavioural: it runs on its own time quanta (16 per bit, sample point after 12,
// SJW 4) derived from a nominal bit time and a clock error in ppm, so it drifts against the chip.
//
// Implemented: hard sync on recessive-to-dominant in bus idle; resync with SJW on
// recessive-to-dominant edges (not while this node sends dominant); bit stuffing (SOF..CRC,
// 5 equal bits); CRC-15 (x^15+x^14+x^10+x^8+x^7+x^4+x^3+1); bitwise arbitration over the
// identifier and RTR; ACK; stuff, bit, form, CRC and ACK errors with active/passive error flags,
// the error delimiter, intermission and suspend transmission; TEC/REC with fault-confinement
// rules 1-10 (rule 3b and overload frames are not modelled; rule-6 counting as in the RTL's D68
// reading of ISO: 14 / 8 dominant bits); bus-off and recovery after 128 x 11 recessive bits.
// Automatic retransmission of the frame in tx_q[0] until it is sent.
//
// Test hooks: `ack_en` (0 = never acknowledge), `crc_corrupt` (flip the next transmitted CRC's
// last bit), `skip_stuff_at` (drop the stuff bit after this transmitted-bit index), `form_corrupt`
// (send a dominant CRC delimiter), each one shot.
module can_ref_node #(parameter string NAME = "ref") (
    input  wire  rx,     // the bus as this node's transceiver reports it
    output logic tx = 1  // this node's TXD
);
  // ---- configuration ----
  real    bit_ns = 2000.0;
  real    ppm = 0.0;
  bit     enabled = 0;
  bit     ack_en = 1;
  bit     crc_corrupt = 0, form_corrupt = 0;
  int     skip_stuff_at = -1;
  bit     r0_bit = 0;   // test hook: send r0 recessive
  bit     tx_ext = 0;
  localparam int TQ = 16, SAMPLE = 12, SJW = 4;

  // ---- frames ----
  // a frame: [79:69] ID, [68] RTR, [67:64] DLC, [63:0] data (byte b is [63-8*b -: 8])
  // [98] IDE (extended frame), [97:80] extended ID bits 17..0 (CAN 2.0B)
  typedef logic [98:0] frame_t;
  frame_t tx_q[$];
  frame_t rx_frames[$];       // frames received without error (own frames not included)
  int     n_sent = 0, n_err_flags = 0, n_arb_lost = 0;
  int     tec = 0, rec = 0;
  bit     busoff = 0;
  function automatic bit passive();
    return tec >= 128 || rec >= 128;
  endfunction

  // ---- bit timing ----
  int tqc = 0;
  bit rx_prev = 1, sampled_bit = 1, drv_dom = 0;
  // ---- protocol state ----
  typedef enum {S_INTEG, S_IDLE, S_FRAME, S_EFLAG, S_EDELIM, S_BUSOFF} st_t;
  st_t st = S_INTEG;
  int  recessive_run = 0, idle_bits = 0, susp = 0;
  bit  after_frame = 0;
  // frame being sent/received
  logic fbits[$];        // the frame's destuffed bits up to the end of the CRC (transmitter)
  int  fpos = 0;         // destuffed bit index (SOF = 0)
  int  tpos = 0;         // line bit index in this frame
  bit  transmitting = 0, sending_tx = 0; // this node started the frame / still owns it
  bit  stuff_next = 0, last_lvl = 1;
  int  run = 0;
  bit  in_tail = 0;
  int  tail_i = 0;
  bit  cur_bit = 1;       // what this node sends in the current bit
  bit  cur_is_stuff = 0;
  logic [14:0] crc = 0;
  logic rbits[$];        // destuffed received bits
  int  dlc_n = -1, crc_end = -1;
  bit  crc_ok_rx = 0;
  // error frame
  int  ef_cnt = 0, ef_eq = 0, ed_cnt = 0, dom_after = 0;
  bit  ef_passive = 0, ef_prev = 0, first_after = 0, ack_exc = 0, ef_tx = 0;
  int  boff_seq = 0, boff_run = 0;

  // back to power-on: counters, queues, integration
  function automatic void reset_node();
    tx_q.delete(); rx_frames.delete();
    tec = 0; rec = 0; busoff = 0; st = S_INTEG; recessive_run = 0; idle_bits = 0; susp = 0;
    n_sent = 0; n_err_flags = 0; n_arb_lost = 0; enabled = 0; ack_en = 1;
    crc_corrupt = 0; form_corrupt = 0; skip_stuff_at = -1; r0_bit = 0; tx = 1; drv_dom = 0;
  endfunction

  function automatic logic [14:0] crc_step(input logic [14:0] c, input logic b);
    logic fb;
    fb = b ^ c[14];
    crc_step = {c[13:0], 1'b0} ^ (fb ? 15'h4599 : 15'h0);
  endfunction

  // the destuffed bits SOF..CRC of a frame
  function automatic void build(input frame_t f);
    logic [14:0] c;
    int n;
    fbits.delete();
    tx_ext = f[98];   // the arbitration field runs to RTR: bit 12, or bit 32 when extended
    fbits.push_back(0);
    for (int i = 10; i >= 0; i--) fbits.push_back(f[69 + i]);
    if (f[98]) begin   // CAN 2.0B: SRR, IDE, ID 17..0, then RTR, r1
      fbits.push_back(1);
      fbits.push_back(1);
      for (int i = 17; i >= 0; i--) fbits.push_back(f[80 + i]);
    end
    fbits.push_back(f[68]);
    fbits.push_back(0);        // IDE (standard) or r1 (extended): dominant
    fbits.push_back(r0_bit);   // r0: receivers must accept either level
    for (int i = 3; i >= 0; i--) fbits.push_back(f[64 + i]);
    n = f[68] ? 0 : (f[67:64] > 8 ? 8 : f[67:64]);
    for (int b = 0; b < n * 8; b++) fbits.push_back(f[63 - b]);
    c = 0;
    foreach (fbits[i]) c = crc_step(c, fbits[i]);
    if (crc_corrupt) begin
      c[0] = !c[0];
      crc_corrupt = 0;
    end
    for (int i = 14; i >= 0; i--) fbits.push_back(c[i]);
  endfunction

  function automatic void start_error(input bit is_tx_err, input bit ack_error);
    n_err_flags++;
    ef_tx = is_tx_err;
    ef_passive = passive();              // the flag of the state the error was detected in
    ack_exc = is_tx_err && ack_error && ef_passive;
    if (is_tx_err) begin
      if (!ack_exc) tec += 8;
    end else rec = rec >= 255 ? 255 : rec + 1;
    if (tec > 255) begin
      st = S_BUSOFF; busoff = 1; boff_seq = 0; boff_run = 0;
      return;
    end
    st = S_EFLAG; ef_cnt = 0; ef_eq = 0;
    in_tail = 0;
  endfunction

  // called at the start of every bit (time quantum 0)
  function automatic void bit_start();
    drv_dom = 0;
    cur_is_stuff = 0;
    cur_bit = 1;
    case (st)
      S_IDLE: begin
        if (enabled && tx_q.size() > 0 && !busoff && idle_bits >= (after_frame ? 3 : 11) + susp) begin
          // start a frame: SOF
          build(tx_q[0]);
          st = S_FRAME; transmitting = 1; sending_tx = 1; fpos = 0; tpos = 0;
          stuff_next = 0; run = 0; last_lvl = 1; in_tail = 0; rbits.delete();
          dlc_n = -1; crc_end = -1; crc = 0;
          cur_bit = 0;
        end
      end
      S_FRAME: begin
        if (in_tail) begin
          tail_i++;
          // 0 CRC delim, 1 ACK, 2 ACK delim, 3..9 EOF
          cur_bit = 1;
          if (tail_i == 0 && form_corrupt && sending_tx) begin cur_bit = 0; form_corrupt = 0; end
          if (tail_i == 1 && !sending_tx && crc_ok_rx && ack_en) cur_bit = 0;
        end else if (stuff_next) begin
          cur_is_stuff = 1;
          cur_bit = !last_lvl;
          if (sending_tx && skip_stuff_at >= 0 && fpos - 1 == skip_stuff_at) begin
            cur_bit = last_lvl;          // the injected stuff error: no stuff bit
            skip_stuff_at = -1;
          end
          if (!sending_tx) cur_bit = 1;
        end else if (sending_tx && fpos < fbits.size()) cur_bit = fbits[fpos];
        else cur_bit = 1;
        if (tpos == 0) cur_bit = sending_tx ? 0 : 1;   // SOF (already being sent)
      end
      S_EFLAG: cur_bit = ef_passive;
      default: cur_bit = 1;
    endcase
    if (busoff) cur_bit = 1;
    drv_dom = !cur_bit;
    tx = cur_bit;
  endfunction

  // called at the sample point of every bit
  function automatic void sample(input bit b);
    case (st)
      S_INTEG: begin
        recessive_run = b ? recessive_run + 1 : 0;
        if (recessive_run >= 11) begin st = S_IDLE; idle_bits = 11; after_frame = 0; end
      end
      S_IDLE: idle_bits = b ? idle_bits + 1 : 0;
      S_FRAME: frame_sample(b);
      S_EFLAG: begin
        if (!ef_passive) begin
          if (b) begin
            if (ef_tx) tec += 8; else rec = rec + 8 > 255 ? 255 : rec + 8;
          end
          ef_cnt++;
          if (ef_cnt == 6) begin st = S_EDELIM; ed_cnt = 0; dom_after = 6; first_after = 1; end
        end else begin
          if (ack_exc && !b) begin tec += 8; ack_exc = 0; end
          ef_eq = (ef_cnt > 0 && b == ef_prev) ? ef_eq + 1 : 1;
          ef_prev = b;
          ef_cnt++;
          if (ef_eq == 6) begin st = S_EDELIM; ed_cnt = 0; dom_after = 0; first_after = 1; end
        end
        if (tec > 255) begin st = S_BUSOFF; busoff = 1; boff_seq = 0; boff_run = 0; end
      end
      S_EDELIM: begin
        if (ed_cnt == 0 && !b) begin
          // still waiting for the first recessive bit
          if (first_after && !ef_tx) rec = rec + 8 > 255 ? 255 : rec + 8;
          dom_after++;
          if (dom_after == (ef_passive ? 8 : 14)) begin
            if (ef_tx) tec += 8; else rec = rec + 8 > 255 ? 255 : rec + 8;
            dom_after = ef_passive ? 0 : 6;
          end
        end else if (b) begin
          ed_cnt++;
          if (ed_cnt == 8) begin
            st = S_IDLE; idle_bits = 0; after_frame = 1; susp = (ef_tx && passive()) ? 8 : 0;
          end
        end else start_error(ef_tx, 0);   // form error in the delimiter
        first_after = 0;
        if (tec > 255) begin st = S_BUSOFF; busoff = 1; boff_seq = 0; boff_run = 0; end
      end
      S_BUSOFF: begin
        boff_run = b ? boff_run + 1 : 0;
        if (boff_run == 11) begin
          boff_run = 0;
          boff_seq++;
          if (boff_seq == 128) begin
            busoff = 0; tec = 0; rec = 0; st = S_IDLE; idle_bits = 11; after_frame = 0; susp = 0;
          end
        end
      end
      default: ;
    endcase
  endfunction

  function automatic void frame_sample(input bit b);
    bit role_tx;
    int dl;
    role_tx = sending_tx;
    if (in_tail) begin
      case (tail_i)
        0: if (!b) begin start_error(role_tx, 0); return; end
        1: if (role_tx && b) begin start_error(1, 1); return; end
        2: begin
          if (!b) begin start_error(role_tx, 0); return; end
          if (!role_tx && !crc_ok_rx) begin start_error(0, 0); return; end
        end
        9: begin
          if (!b && role_tx) begin start_error(1, 0); return; end
          // the frame is over
          if (role_tx) begin
            n_sent++;
            void'(tx_q.pop_front());
            if (tec > 0) tec--;
          end else begin
            if (rec > 127) rec = 119; else if (rec > 0) rec--;
            rx_frames.push_back(decode());
          end
          st = S_IDLE; idle_bits = 0; after_frame = 1; susp = (role_tx && passive()) ? 8 : 0;
          transmitting = 0; sending_tx = 0;
          return;
        end
        default: if (!b) begin start_error(role_tx, 0); return; end
      endcase
      return;
    end
    if (tpos == 0 && b) begin st = S_IDLE; return; end   // not a start of frame
    if (cur_is_stuff) begin
      if (b == last_lvl) begin start_error(role_tx, 0); return; end   // stuff error
      last_lvl = b; run = 1; stuff_next = 0;
      tpos++;
      return;
    end
    // a data bit: arbitration (identifier and RTR: destuffed bits 1..12), bit error
    if (sending_tx && cur_bit != b) begin
      if (fpos >= 1 && fpos <= (tx_ext ? 32 : 12) && cur_bit == 1 && b == 0) begin
        sending_tx = 0;   // lost arbitration: receive from here
        n_arb_lost++;
      end else begin start_error(1, 0); return; end
    end
    rbits.push_back(b);
    run = (b == last_lvl) ? run + 1 : 1;
    last_lvl = b;
    fpos++;
    tpos++;
    if (rbits.size() == (rbits.size() > 13 && rbits[13] ? 39 : 19)) begin
      // header complete: SOF ID(11) RTR IDE r0 DLC(4)
      if (rbits[13]) begin   // extended: RTR at 32, DLC at 35..38
        dl = {rbits[35], rbits[36], rbits[37], rbits[38]};
        dlc_n = rbits[32] ? 0 : (dl > 8 ? 8 : dl);
        crc_end = 39 + 8 * dlc_n + 15;
      end else begin
        dl = {rbits[15], rbits[16], rbits[17], rbits[18]};
        dlc_n = rbits[12] ? 0 : (dl > 8 ? 8 : dl);
        crc_end = 19 + 8 * dlc_n + 15;
      end
    end
    if (crc_end > 0 && rbits.size() == crc_end) begin
      logic [14:0] c;
      c = 0;
      foreach (rbits[i]) c = crc_step(c, rbits[i]);   // over the frame and its CRC: 0 if good
      crc_ok_rx = c == 0;
      // a stuff bit may still follow the last CRC bit
      stuff_next = run == 5;
      if (!stuff_next) begin in_tail = 1; tail_i = -1; end
      return;
    end
    stuff_next = run == 5;
  endfunction

  function automatic frame_t decode();
    frame_t f;
    f[79:69] = 0;
    for (int i = 1; i <= 11; i++) f[80 - i] = rbits[i];
    f[98:80] = 0;
    if (rbits[13]) begin
      f[98] = 1;
      for (int i = 0; i < 18; i++) f[97 - i] = rbits[14 + i];
      f[68] = rbits[32];
      f[67:64] = {rbits[35], rbits[36], rbits[37], rbits[38]};
      f[63:0] = 0;
      for (int b = 0; b < dlc_n * 8; b++) f[63 - b] = rbits[39 + b];
    end else begin
      f[68] = rbits[12];
      f[67:64] = {rbits[15], rbits[16], rbits[17], rbits[18]};
      f[63:0] = 0;
      for (int b = 0; b < dlc_n * 8; b++) f[63 - b] = rbits[19 + b];
    end
    return f;
  endfunction

  // after a stuff bit that followed the last CRC bit, the tail begins
  function automatic void after_stuff_check();
    if (st == S_FRAME && !in_tail && crc_end > 0 && rbits.size() == crc_end && !stuff_next) begin
      in_tail = 1; tail_i = -1;
    end
  endfunction

  // ---- the time-quantum loop ----
  bit fall;
  always begin
    #(bit_ns * (1.0 + ppm * 1.0e-6) / TQ);
    if (enabled) begin
      fall = rx_prev && !rx;
      rx_prev = rx;
      if (fall && st == S_IDLE) begin
        // hard synchronization: this quantum is the sync segment of a start of frame
        st = S_FRAME;
        if (!(enabled && tx_q.size() > 0 && !busoff && idle_bits >= (after_frame ? 3 : 11) + susp)) begin
          transmitting = 0; sending_tx = 0;
        end else begin
          build(tx_q[0]);   // a pending frame joins: its SOF coincides with this one
          transmitting = 1; sending_tx = 1;
        end
        fpos = 0; tpos = 0; stuff_next = 0; run = 0; last_lvl = 1; in_tail = 0; rbits.delete();
        dlc_n = -1; crc_end = -1;
        tqc = 1;
        cur_bit = sending_tx ? 0 : 1;
        drv_dom = !cur_bit;
        tx = cur_bit;
      end else begin
        if (fall && !drv_dom && st != S_IDLE && tqc != 0) begin
          // resynchronization, phase error limited to SJW
          // late edge (before the sample point): lengthen phase segment 1 by the phase error,
          // at most SJW; the edge then counts as the end of the sync segment (quantum 1)
          if (tqc <= SAMPLE) tqc = (tqc <= SJW) ? 1 : tqc - SJW;
          else if (TQ - tqc <= SJW) tqc = TQ;                     // early edge: next bit now
          else tqc = tqc + SJW;
        end
        if (tqc == TQ) tqc = 0;
        if (tqc == 0) begin
          if (st == S_FRAME && stuff_next == 0) after_stuff_check();
          bit_start();
        end
        if (tqc == SAMPLE) begin
          sampled_bit = rx;
          if (st == S_FRAME && cur_is_stuff) begin
            sample(rx);
            after_stuff_check();
          end else sample(rx);
        end
        tqc++;
      end
    end else begin
      tx = 1;
      rx_prev = rx;
    end
  end
endmodule
