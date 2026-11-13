`timescale 1ns / 1ps
// A 10BASE-T link partner for tb_eth, written from IEEE 802.3 (clauses 3, 7.3.1.1 and 14), not
// from the RTL (D93).
//
// Receiver (the chip's TD+/TD- pair). The differential is P (TD+ high, TD- low), N (the
// reverse) or 0 (equal: idle). Transitions are timestamped; a burst of them separated from
// the next by more than 1 us is one event:
//   - a link pulse (NLP): 0 -> P -> 0; its width must be 60..200 ns (one bit time, 100 ns,
//     nominal), and successive pulses 8..24 ms apart (16 ms +- 8 ms, clause 14.2.1.1);
//   - a frame: 0 -> N first (the preamble's first bit, a 1, is low then high). Bits are found
//     by their mid-bit transitions, each expected one bit time (100 ns) after the last one,
//     within +-30 ns; a transition half way is a bit boundary. N -> P is a 1 (clause 7.3.1.1:
//     the first half of a bit is its complement). Checked: every mid-bit interval within
//     100 ns +- 1 ns (the chip's clock is exact here); 64 bits of preamble and SFD exactly
//     (62 alternating, starting with 1, then 1 1: 7 x 0x55, 0xD5, LSB first); a whole number of
//     bytes after it; the FCS (the last 4 bytes) against a CRC-32 computed here (reflected,
//     byte-wise, poly 0xEDB88320, clause 3.2.9); TP_IDL: after the last bit the line goes (or
//     stays) P and is held P for 2 to 4.5 bit times after its last transition, then 0
//     (clause 14.3.1.2.1); the inter-frame gap from the end of a frame's last bit to the next
//     frame's first transition is at least 9.6 us (96 bit times, clause 4.4.2).
// Transmitter (the chip's RD input, the receive comparator's output: 1 while RD+ > RD-).
//   send_frame: preamble, SFD, the bytes in tx_buf (the FCS appended, or a wrong one), TP_IDL
//   (3 bit times high), then idle low; bit time 100 ns x (1 + ppm), each transition moved by
//   a uniform +-jitter (a deterministic generator). send_nlp: one 100 ns pulse.
module eth_model (
    input  wire  tdp,
    input  wire  tdm,
    output logic rd
);
  initial rd = 0;

  int errors = 0;
  bit lenient = 0;        // a corrupted frame is expected (underrun tests): count, do not fail
  int bad_events = 0;
  task automatic fail(input string msg);
    if (lenient) begin
      bad_events++;
      $display("  (10BASE-T model, expected) %s", msg);
    end else begin
      errors++;
      $display("  FAIL (10BASE-T model): %s", msg);
    end
  endtask

  // ---------------- CRC-32, byte-wise and reflected (the other formulation) ----------------
  logic [7:0] crc_buf[2048];
  function automatic logic [31:0] crc32(input int n);
    logic [31:0] c;
    c = 32'hFFFF_FFFF;
    for (int i = 0; i < n; i++) begin
      c = c ^ {24'b0, crc_buf[i]};
      for (int k = 0; k < 8; k++) c = c[0] ? (c >> 1) ^ 32'hEDB8_8320 : c >> 1;
    end
    return ~c;
  endfunction

  // ---------------- receiver ----------------
  // the differential: 1 = P, -1 = N, 0 = idle
  function automatic int diff_lvl();
    return (tdp && !tdm) ? 1 : (!tdp && tdm) ? -1 : 0;
  endfunction
  real tr_t[$];
  int  tr_l[$];   // the level after each transition
  int  cur_lvl = 0;
  always @(tdp or tdm) begin
    if (diff_lvl() != cur_lvl) begin
      cur_lvl = diff_lvl();
      tr_t.push_back($realtime);
      tr_l.push_back(cur_lvl);
    end
  end

  // results, read by the bench
  logic [7:0] rx_bytes[$];   // all decoded frames' bytes (without preamble, SFD; with the FCS)
  int  rx_len[$];            // bytes per frame
  bit  rx_fcs_ok[$];
  real rx_start[$], rx_end[$];
  real nlp_t[$], nlp_w[$];
  real ifg_min = 1e12, tpidl_min = 1e12, tpidl_max = 0;
  int  frames_seen = 0;
  bit  rx_quiet_check = 0;   // when set, any activity is an error

  // process a burst of transitions (all with gaps under 1 us)
  real bt[$];
  int  bl[$];
  task burst();  // static: Icarus 12 and real locals in automatic tasks (BUG-127)
    int nb, idx, nbits, last_l;
    bit done;
    real last_mid, t_end, w, hold_from;
    bit  bits[$];
    logic [7:0] b;
    bit ok;
    begin : body
      nb = bt.size();
      if (rx_quiet_check) fail($sformatf("activity at %0.0f ns while the line must be idle", bt[0]));
      if (bl[0] == 1) begin  // a link pulse?
        if (nb != 2 || bl[1] != 0) begin
          fail($sformatf("a burst at %0.0f ns that starts positive is not a single pulse (%0d transitions)", bt[0], nb));
          disable body;  // (no `return` from tasks in Icarus 12)
        end
        w = bt[1] - bt[0];
        if (w < 60.0 || w > 200.0) fail($sformatf("link pulse at %0.0f ns is %0.1f ns wide (60..200)", bt[0], w));
        if (nlp_t.size() > 0 && (bt[0] - nlp_t[$] < 8.0e6 || bt[0] - nlp_t[$] > 24.0e6))
          fail($sformatf("link pulses %0.3f ms apart (8..24 ms)", (bt[0] - nlp_t[$]) / 1e6));
        if (rx_end.size() > 0 && bt[0] - rx_end[$] < 9600.0)
          fail($sformatf("a link pulse %0.0f ns after a frame", bt[0] - rx_end[$]));
        nlp_t.push_back(bt[0]);
        nlp_w.push_back(w);
        disable body;  // (no `return` from tasks in Icarus 12)
      end
      if (bl[0] != -1) begin
        fail($sformatf("a burst at %0.0f ns starts at level %0d", bt[0], bl[0]));
        disable body;  // (no `return` from tasks in Icarus 12)
      end
      // a frame: the first mid-bit transition is N -> P, half a bit after the start
      if (nb < 3 || bl[1] != 1 || bt[1] - bt[0] < 35.0 || bt[1] - bt[0] > 65.0) begin
        fail($sformatf("frame at %0.0f ns: no mid-bit transition 50 ns after the start", bt[0]));
        disable body;  // (no `return` from tasks in Icarus 12)
      end
      bits.delete();
      bits.push_back(1);
      last_mid = bt[1];
      idx = 2;
      done = 0;
      while (!done && idx < nb && bl[idx] != 0) begin
        if (bt[idx] - last_mid > 20.0 && bt[idx] - last_mid < 80.0) begin  // a bit boundary
          if (idx + 1 < nb && bl[idx+1] != 0 && bt[idx+1] - last_mid > 70.0 && bt[idx+1] - last_mid < 130.0) idx++;
          else done = 1;  // the last bit's boundary transition into TP_IDL
        end
        if (!done) begin
          if (bt[idx] - last_mid < 70.0 || bt[idx] - last_mid > 130.0) begin
            fail($sformatf("frame at %0.0f ns: a transition %0.1f ns after a mid-bit one", bt[0], bt[idx] - last_mid));
            disable body;  // (no `return` from tasks in Icarus 12)
          end
          if (bt[idx] - last_mid < 99.0 || bt[idx] - last_mid > 101.0)
            fail($sformatf("frame at %0.0f ns, bit %0d: %0.2f ns after the last (100 +- 1)", bt[0], bits.size(), bt[idx] - last_mid));
          bits.push_back(bl[idx] == 1);
          last_mid = bt[idx];
          idx++;
        end
      end
      t_end = last_mid + 50.0;  // the end of the last bit cell
      // TP_IDL: the line is P from its last transition, then 0
      if (bl[nb-1] != 0 || (nb >= 2 && bl[nb-2] != 1)) begin
        fail($sformatf("frame at %0.0f ns does not end positive then idle", bt[0]));
      end else begin
        hold_from = bt[nb-2];
        w = bt[nb-1] - hold_from;
        if (w < tpidl_min) tpidl_min = w;
        if (w > tpidl_max) tpidl_max = w;
        if (w < 200.0 || w > 450.0) fail($sformatf("frame at %0.0f ns: TP_IDL high for %0.1f ns (200..450)", bt[0], w));
        if (nb - 2 != idx && !(nb - 2 == idx - 1)) ;  // (the TP_IDL transition is the last P one)
      end
      // preamble and SFD
      ok = bits.size() >= 64;
      for (int i = 0; ok && i < 62; i++) if (bits[i] != (i % 2 == 0)) ok = 0;
      if (ok && !(bits[62] && bits[63])) ok = 0;
      if (!ok) begin
        fail($sformatf("frame at %0.0f ns: preamble/SFD wrong (%0d bits)", bt[0], bits.size()));
        disable body;  // (no `return` from tasks in Icarus 12)
      end
      nbits = bits.size() - 64;
      if (nbits % 8 != 0) fail($sformatf("frame at %0.0f ns: %0d bits after the SFD", bt[0], nbits));
      for (int i = 0; i < nbits / 8; i++) begin
        for (int k = 0; k < 8; k++) b[k] = bits[64 + i * 8 + k];
        rx_bytes.push_back(b);
        crc_buf[i] = b;
      end
      rx_len.push_back(nbits / 8);
      if (nbits / 8 >= 5) begin
        logic [31:0] c, f;
        c = crc32(nbits / 8 - 4);
        f = {crc_buf[nbits/8-1], crc_buf[nbits/8-2], crc_buf[nbits/8-3], crc_buf[nbits/8-4]};
        rx_fcs_ok.push_back(c == f);
      end else rx_fcs_ok.push_back(0);
      if (rx_end.size() > 0 && bt[0] - rx_end[$] < ifg_min) ifg_min = bt[0] - rx_end[$];
      if (rx_end.size() > 0 && bt[0] - rx_end[$] < 9600.0)
        fail($sformatf("inter-frame gap %0.0f ns (at least 9600)", bt[0] - rx_end[$]));
      if (nlp_t.size() > 0 && bt[0] - nlp_t[$] < 1000.0) fail("a frame right after a link pulse");
      rx_start.push_back(bt[0]);
      rx_end.push_back(t_end);
      frames_seen++;
    end
  endtask

  initial begin
    forever begin
      #200;
      if (tr_t.size() > 0 && $realtime - tr_t[$] > 1000.0 && cur_lvl == 0) begin
        bt.delete();
        bl.delete();
        foreach (tr_t[i]) begin
          bt.push_back(tr_t[i]);
          bl.push_back(tr_l[i]);
        end
        tr_t.delete();
        tr_l.delete();
        burst();
      end
    end
  end

  // ---------------- transmitter ----------------
  int unsigned lcg = 32'h5EED_0001;
  function automatic real urand();
    lcg = lcg * 32'd1664525 + 32'd1013904223;
    return real'(lcg >> 8) / 16777216.0;
  endfunction
  logic [7:0] tx_buf[2048];
  int  tx_lv[$];
  real tx_t0, tx_t;
  bit  tx_busy = 0;
  // n bytes from tx_buf; bad_fcs: the FCS's last byte flipped
  task send_frame(input int n, input real ppm, input real jit, input bit bad_fcs);
    logic [31:0] f;
    logic [7:0] b;
    real half;
    tx_busy = 1;
    for (int i = 0; i < n; i++) crc_buf[i] = tx_buf[i];
    f = crc32(n);
    tx_buf[n] = f[7:0];
    tx_buf[n+1] = f[15:8];
    tx_buf[n+2] = f[23:16];
    tx_buf[n+3] = f[31:24] ^ (bad_fcs ? 8'h01 : 8'h00);
    tx_lv.delete();
    for (int i = -8; i < n + 4; i++) begin
      b = i < -1 ? 8'h55 : i == -1 ? 8'hD5 : tx_buf[i];
      for (int k = 0; k < 8; k++) begin  // LSB first; first half the complement
        tx_lv.push_back(!b[k]);
        tx_lv.push_back(b[k]);
      end
    end
    for (int k = 0; k < 6; k++) tx_lv.push_back(1);  // TP_IDL: 3 bit times high
    tx_lv.push_back(0);
    half = 50.0 * (1.0 + ppm * 1e-6);
    tx_t0 = $realtime + 1.0;
    for (int i = 0; i < tx_lv.size(); i++) begin
      if (i == 0 ? tx_lv[0] != rd : tx_lv[i] != tx_lv[i-1]) begin
        tx_t = tx_t0 + i * half + (2.0 * urand() - 1.0) * jit;
        if (tx_t < $realtime) tx_t = $realtime;
        #(tx_t - $realtime);
        rd = tx_lv[i];
      end
    end
    tx_busy = 0;
  endtask

  task send_nlp();
    rd = 1;
    #100;
    rd = 0;
  endtask
endmodule
