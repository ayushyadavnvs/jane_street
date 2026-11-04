// Small synchronous FIFO used between the host interface and each engine.
// Push while full and pop while empty are ignored.
// Acceptance uses occupancy before the edge: simultaneous push+pop when full only pops,
// when empty only pushes, and at intermediate occupancy accepts both. Reset/flush zeros
// both pointers and count, with flush winning over pointer updates. Storage is unreset and
// an accepted push still writes its old write-pointer slot on a flush/reset edge; those
// bytes are not logically queued after the reset/flush. dout continuously exposes the
// head slot, even while empty (stale/unknown data); callers must qualify it with !empty.
// This is the existing storage/pointer contract, clarified in the round-2 model audit.
//
// Mark and rewind (D70, for retransmission): `mark` remembers the read position and holds it;
// `rewind` moves the read pointer back to it, so the bytes popped since the mark are read again.
// While a mark is held, `full` counts from the mark, so a push cannot overwrite bytes that a
// rewind could still need. Without a mark (reset, flush, or never marked) the mark follows the
// read pointer and every output is exactly as before. Mark and rewind in the same clock: the
// rewind wins and the mark stays where it was. A pop and a rewind in the same clock: the rewind
// wins.
module pbe_fifo #(
    parameter int WIDTH = 8,
    parameter int ADDR_BITS = 2  // depth = 2**ADDR_BITS
) (
    input  logic             clk,
    input  logic             rst_n,
    input  logic             flush,
    input  logic             push,
    input  logic [WIDTH-1:0] din,
    input  logic             pop,
    input  logic             mark,    // hold the current read position
    input  logic             rewind,  // read again from the held position
    output logic [WIDTH-1:0] dout,
    output logic             empty,
    output logic             full,
    output logic [ADDR_BITS:0] count  // bytes held
);
  localparam int DEPTH = 1 << ADDR_BITS;

  logic [WIDTH-1:0] mem[DEPTH];
  logic [ADDR_BITS:0] wptr, rptr;  // extra bit tells full from empty
  logic [ADDR_BITS:0] mptr;        // the mark (equals rptr while no mark is held)
  logic               held;

  assign empty = (wptr == rptr);
  assign full  = (wptr[ADDR_BITS-1:0] == mptr[ADDR_BITS-1:0]) && (wptr[ADDR_BITS] != mptr[ADDR_BITS]);
  assign dout  = mem[rptr[ADDR_BITS-1:0]];
  assign count = wptr - rptr;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wptr <= '0;
      rptr <= '0;
      mptr <= '0;
      held <= 1'b0;
    end else if (flush) begin
      wptr <= '0;
      rptr <= '0;
      mptr <= '0;
      held <= 1'b0;
    end else begin
      if (push && !full) wptr <= wptr + 1'b1;
      if (rewind) rptr <= mptr;
      else if (pop && !empty) begin
        rptr <= rptr + 1'b1;
        if (!held && !mark) mptr <= rptr + 1'b1;
      end
      if (mark && !rewind) begin
        mptr <= rptr;
        held <= 1'b1;
      end
    end
  end

  // Storage has no reset: logical consumers must qualify reads with !empty.
  always_ff @(posedge clk) begin
    if (push && !full) mem[wptr[ADDR_BITS-1:0]] <= din;
  end
endmodule
