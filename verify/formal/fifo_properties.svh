// Assertion-only instrumentation. Parameters are the real FIFO WIDTH/ADDR_BITS.
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
    if (f_past_valid) begin
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
  end
