// Assertion-only instrumentation of pbe_bsync (D66, D68), CAN configuration, period 4 clocks
// (integration then takes 44 steps, so frames and error frames fit in the bound).
  reg f_past = 0;
  reg f_lost = 0, f_wait = 0, f_seen_flag = 0, f_seen_lost = 0, f_now = 0;
  reg [5:0] f_since = 0;
  always @(posedge clk) begin
    f_past <= 1;
    if (!f_past) assume(!rst_n); else assume(rst_n);
    assume(period_m1 == 16'd3);
    assume(cfg2[2:0] <= 3'd2);                       // sample point inside the 4-clock bit
    assume(cfg == 8'h0D || cfg == 8'h2D);           // NRZ, stuffing 5 equal, units of 1 or 8
    assume(!tx_put || tx_ready);                      // the engine's handshake
    if (f_past && rst_n && !clear) begin
      // F1: a node that lost arbitration does not drive again in that frame
      if (f_lost && cs == C_FRAME) assert(!drive);
      // F2: the error flag (or bus-off) starts at the next bit start: within one bit after an
      // error detected at a sample point, within two after LINECTL ERROR issued before the
      // sample point (that bit may still be resynchronized once)
      if (f_wait) assert(f_since <= (f_now ? 6'd10 : 6'd6));
      // F3: an active error flag drives dominant for its whole length
      if (cs == C_EFLAG && flag_on && !flag_pas) assert(drive);
      // a silent node never drives inside a frame
      if (cs == C_FRAME && silent) assert(!drive);
    end
    if (!rst_n || clear) begin
      f_lost <= 0; f_wait <= 0; f_since <= 0;
    end else begin
      if (cs != C_FRAME) f_lost <= 0;
      if (arb_lost) begin f_lost <= 1; f_seen_lost <= 1; end
      if (err && frame_end) begin f_wait <= 1; f_since <= 0; f_now <= ctl && ctl_param[4] && ctl_param[2]; end
      else if (f_wait) begin
        f_since <= f_since + 1'b1;
        if ((cs == C_EFLAG && flag_on) || cs == C_BUSOFF) begin f_wait <= 0; f_seen_flag <= 1; end
      end
    end
    cover(f_past && arb_lost);
    cover(f_past && cs == C_EFLAG && flag_on && !flag_pas);
  end
