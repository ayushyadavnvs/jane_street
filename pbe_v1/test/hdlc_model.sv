`timescale 1ns / 1ps
// An HDLC/SDLC line model (NRZ), written from ISO/IEC 13239 (flags 0x7E, zero-bit insertion
// after five 1s, abort = seven or more 1s, FCS-16 = CRC-16/X.25: CRC-CCITT reflected, init
// 0xFFFF, sent inverted, low byte first, good residue 0xF0B8), not from the PBE programs. D88.
//
// Transmitter (`line`): sends frames from `tx_frames` as a bit stream at BIT_NS per bit (a
//   different rate from the receiver's, to test clock recovery). Each frame: an opening flag
//   (shared with the previous frame's closing flag when frames are back to back), the stuffed
//   bytes and FCS, a closing flag; then idle 1s (mark) until the next frame. Per-frame options:
//   flip one bit of the FCS (a CRC error), or abort after k bytes (seven 1s, no FCS, no flag).
// Receiver (on `rx_line`): recovers the clock from the edges (re-centred at every edge, sampled
//   mid-bit), finds flags, deletes stuffed 0s, detects aborts, checks the bit count and the FCS
//   residue; good frames go to `rx_good`, every frame's verdict to `rx_log`.
module hdlc_model (
    output logic line = 1,
    input  wire  rx_line
);
  real BIT_NS = 1000.0;     // the transmitter's bit time (set by the bench)
  bit  NRZI = 0;            // NRZI line coding (ISO/IEC 13239: a 0 is a transition, a 1 none)
  real RX_BIT_NS = 1000.0;  // the receiver's nominal bit time
  // ---------------- FCS ----------------
  logic [7:0] all[$];       // the frame being sent
  // CRC-16/X.25 of the bytes in `all` (before the FCS is appended)
  logic [15:0] crc_c;
  task automatic crc_x25;
    logic [7:0] x;
    crc_c = 16'hFFFF;
    foreach (all[i]) begin
      x = all[i];
      crc_c ^= {8'h00, x};
      for (int k = 0; k < 8; k++) crc_c = crc_c[0] ? (crc_c >> 1) ^ 16'h8408 : crc_c >> 1;
    end
  endtask

  // ---------------- transmitter ----------------
  // Frames to send, as parallel queues: add the bytes to tx_bytes, then call add_frame.
  logic [7:0] tx_bytes[$];
  int  q_len[$], q_abort[$], q_flags[$];
  bit  q_bad[$], q_share[$];
  int  n_sent = 0;
  bit  tx_busy = 0;
  bit  last_was_flag = 0;   // the line just carried a closing flag (sharable)

  // bad: flip an FCS bit; abort_after: send seven+ 1s instead of byte k (-1: none);
  // flags: extra flags before the frame; share: no idle before it, and start with the
  // previous frame's closing flag (after an abort: directly with an opening flag)
  task automatic add_frame(input int len, input bit bad, input int abort_after, input int flags, input bit share);
    q_len.push_back(len);
    q_bad.push_back(bad);
    q_abort.push_back(abort_after);
    q_flags.push_back(flags);
    q_share.push_back(share);
  endtask

  task automatic send_bit(input bit b);
    if (!NRZI) line = b;
    else if (!b) line = !line;
    #(BIT_NS);
  endtask
  task automatic send_flag;
    for (int i = 0; i < 8; i++) send_bit(i != 0 && i != 7);  // 0 1 1 1 1 1 1 0
  endtask

  task automatic send_frame(input int len, input bit bad, input int abort_after, input int flags, input bit share);
    logic [15:0] fcs;
    logic [7:0] x;
    int ones;
    bit b, stop;
    ones = 0;
    stop = 0;
    if (!(share && last_was_flag)) send_flag;
    for (int i = 0; i < flags; i++) send_flag;
    all = {};
    for (int i = 0; i < len; i++) all.push_back(tx_bytes.pop_front());
    crc_x25;
    fcs = ~crc_c;
    if (bad) fcs ^= 16'h0010;
    all.push_back(fcs[7:0]);
    all.push_back(fcs[15:8]);
    for (int i = 0; i < all.size() && !stop; i++) begin
      if (abort_after >= 0 && i == abort_after) begin
        for (int k = 0; k < 7; k++) send_bit(1);  // abort: seven 1s (the fewest)
        stop = 1;
      end else begin
        x = all[i];
        for (int k = 0; k < 8; k++) begin
          b = x[k];
          send_bit(b);
          ones = b ? ones + 1 : 0;
          if (ones == 5) begin
            send_bit(0);   // zero-bit insertion
            ones = 0;
          end
        end
      end
    end
    if (!stop) send_flag;
    last_was_flag = !stop;
  endtask

  initial begin
    line = 1;
    forever begin
      while (q_len.size() == 0) #(100);   // (Icarus does not wake a `wait` on a queue's size)
      tx_busy = 1;
      while (q_len.size() > 0) begin
        int len, ab, fl;
        bit bad, sh_;
        len = q_len.pop_front();
        bad = q_bad.pop_front();
        ab = q_abort.pop_front();
        fl = q_flags.pop_front();
        sh_ = q_share.pop_front();
        send_frame(len, bad, ab, fl, sh_);
        n_sent++;
        if (!(q_share.size() > 0 && q_share[0])) begin   // (share: no idle before the next)
          last_was_flag = 0;
          if (!NRZI) line = 1;   // (NRZI: 1s are no transitions: the level stays)
          #(BIT_NS * 16);        // mark idle
        end
      end
      tx_busy = 0;
    end
  end

  // ---------------- receiver ----------------
  // the frames received: rx_data holds their bytes back to back, rx_len their lengths, and
  // rx_verdict 0 good, 1 CRC error, 2 abort, 3 not a whole number of bytes
  logic [7:0] rx_data[$];
  int rx_len[$], rx_verdict[$];
  int n_flags = 0, n_aborts = 0;

  logic [7:0] sh = 8'h00;   // the last 8 raw bits (bit 7 newest)
  int ones = 0;             // consecutive raw 1s
  bit in_frame = 0;         // a flag has been seen and no abort since
  bit bits_q[$];            // destuffed bits since the last flag (the next flag's 0 1 1 1 1 1 too)
  logic [7:0] cur[$];

  task automatic close_frame(input int why);  // -1: a flag; 2: an abort
    int v;
    logic [15:0] c;
    logic [7:0] x;
    int n;
    n = bits_q.size();
    cur = {};
    if (why < 0) n -= 6;                   // the closing flag's 0 1 1 1 1 1 are not data
    for (int i = 0; i + 8 <= n; i += 8) begin
      for (int k = 0; k < 8; k++) x[k] = bits_q[i + k];
      cur.push_back(x);
    end
    if (why >= 0) v = why;
    else if (n % 8 != 0) v = 3;
    else begin
      c = 16'hFFFF;
      foreach (cur[i]) begin
        c ^= {8'h00, cur[i]};
        for (int k = 0; k < 8; k++) c = c[0] ? (c >> 1) ^ 16'h8408 : c >> 1;
      end
      v = (c == 16'hF0B8) ? 0 : 1;
    end
    if (n >= 8) begin                      // flags back to back and idle carry no frame
      foreach (cur[i]) rx_data.push_back(cur[i]);
      rx_len.push_back(cur.size());
      rx_verdict.push_back(v);
    end
  endtask

  // one received (raw) bit
  task automatic rx_bit(input bit b);
    sh = {b, sh[7:1]};
    if (sh == 8'h7E) begin                 // 0 1 1 1 1 1 1 0 (oldest first): a flag
      n_flags++;
      if (in_frame) close_frame(-1);
      in_frame = 1;
      ones = 0;
      bits_q = {};
    end else if (b) begin
      ones++;
      if (ones == 7) begin                 // an abort (or the start of idle)
        if (in_frame && bits_q.size() > 8) begin
          n_aborts++;
          close_frame(2);
        end
        in_frame = 0;
        bits_q = {};
      end else if (in_frame && ones < 6) bits_q.push_back(1'b1);
    end else begin
      if (ones != 5 && in_frame) bits_q.push_back(1'b0);   // after five 1s: a stuffed 0, deleted
      ones = 0;
    end
  endtask

  // clock recovery: re-centre at every edge, sample every RX_BIT_NS from mid-bit
  realtime next_s = 0;
  logic rx_prev = 1;
  always @(rx_line) next_s = $realtime + RX_BIT_NS / 2;
  initial begin
    forever begin
      #1;
      if (next_s > 0 && $realtime >= next_s) begin
        rx_bit(NRZI ? rx_line == rx_prev : rx_line);
        rx_prev = rx_line;
        next_s = next_s + RX_BIT_NS;
      end
    end
  end
endmodule
