// Assertion-only instrumentation. Parameters are the real FIFO WIDTH/ADDR_BITS.
// Without F_MARK: the original contract, with mark and rewind held at 0 (D70: no mark means
// exactly the old FIFO). With F_MARK: mark and rewind free, checked against a pointer model.
  localparam integer F_DEPTH = 1 << ADDR_BITS;
  reg f_past_valid = 0;
  reg [ADDR_BITS:0] f_count = 0;
  (* anyseq *) reg f_choose;
  reg f_tracking = 0;
  reg [ADDR_BITS:0] f_ahead = 0;
  reg [ADDR_BITS-1:0] f_slot = 0;
  reg [WIDTH-1:0] f_value = 0;
  reg f_seen_full = 0;
  reg f_seen_rejected_pop = 0;
  reg f_seen_rejected_push = 0;
  reg f_delivered = 0;
  wire f_push = push && f_count < F_DEPTH;
  wire f_pop = pop && f_count != 0;
  wire [ADDR_BITS-1:0] f_position = rptr[ADDR_BITS-1:0] + f_ahead[ADDR_BITS-1:0];
  always @(posedge clk) begin
    f_past_valid <= 1;
    if (!f_past_valid) assume(!rst_n);
    else assume(rst_n);
`ifndef F_MARK
    assume(!mark && !rewind);
    if (f_past_valid) begin
      assert(!held && mptr == rptr);   // no mark is ever held: the old FIFO
      assert(count == f_count);
      assert(count <= F_DEPTH);
      assert(empty == (f_count == 0));
      assert(full == (f_count == F_DEPTH));
      assert(!(empty && full));
      if (f_tracking) begin
        assert(f_ahead < f_count);
        assert(f_slot == f_position);
        assert(mem[f_slot] == f_value);
        if (f_ahead == 0) assert(dout == f_value);
      end
      if ($past(rst_n && flush)) assert(empty && count == 0);
      if ($past(rst_n && !flush && full && push && !pop)) assert(count == $past(count));
      if ($past(rst_n && !flush && empty && pop && !push)) assert(count == 0);
    end
    if (!rst_n || flush) begin
      f_count <= 0;
      f_tracking <= 0;
    end else begin
      case ({f_push, f_pop})
        2'b10: f_count <= f_count + 1'b1;
        2'b01: f_count <= f_count - 1'b1;
        default: ;
      endcase
      if (!f_tracking && f_choose && f_push) begin
        f_tracking <= 1;
        f_ahead <= f_count - (f_pop ? 1'b1 : 1'b0);
        f_value <= din;
        f_slot <= wptr[ADDR_BITS-1:0];
      end else if (f_tracking && f_pop) begin
        if (f_ahead == 0) begin f_tracking <= 0; f_delivered <= 1; end
        else f_ahead <= f_ahead - 1'b1;
      end
      if (full) f_seen_full <= 1;
      if (full && push) f_seen_rejected_push <= 1;
      if (empty && pop) f_seen_rejected_pop <= 1;
    end
    cover(f_past_valid && f_seen_full && f_delivered);
    cover(f_past_valid && f_seen_rejected_pop && f_seen_rejected_push && f_delivered);
    cover(f_past_valid && flush && count == F_DEPTH);
    cover(f_past_valid && count > 0 && count < F_DEPTH && push && pop);
`endif
  end
`ifdef F_MARK
  // Pointer model of D70: write, read and mark positions; the mark follows the read position
  // until MARK holds it; REWIND returns to it; while held, `full` counts from it. Data
  // integrity follows: a push writes only mem[wptr] and is refused when full, so the slots
  // from the held mark to wptr are never written while they can still be read again.
  reg [ADDR_BITS:0] g_w = 0, g_r = 0, g_m = 0;
  reg g_held = 0, g_reread = 0;
  wire [ADDR_BITS:0] g_base = g_held ? g_m : g_r;
  // differences sized to the pointers: compared with the 32-bit F_DEPTH they would be computed
  // in 32 bits and go negative when the pointers wrap
  wire [ADDR_BITS:0] g_used = g_w - g_base, g_ahead = g_r - g_base;
  wire g_full = g_used == F_DEPTH;
  always @(posedge clk) begin
    if (f_past_valid) begin
      assert(wptr == g_w && rptr == g_r && held == g_held);
      assert(held ? mptr == g_m : mptr == rptr);
      assert(count == g_w - g_r);
      assert(empty == (g_w == g_r));
      assert(full == g_full);
      assert(g_used <= F_DEPTH);
      assert(g_ahead <= g_used);
    end
    if (!rst_n || flush) begin
      g_w <= 0; g_r <= 0; g_m <= 0; g_held <= 0;
    end else begin
      if (push && !g_full) g_w <= g_w + 1'b1;
      if (rewind) begin
        if (g_held) g_r <= g_m;
        if (g_held && g_r != g_m) g_reread <= 1;
      end else if (pop && g_w != g_r) g_r <= g_r + 1'b1;
      if (mark && !rewind) begin
        g_m <= g_r; g_held <= 1;
      end
    end
    cover(f_past_valid && g_reread && !empty);
    cover(f_past_valid && g_held && full && count < F_DEPTH);
  end
`endif
