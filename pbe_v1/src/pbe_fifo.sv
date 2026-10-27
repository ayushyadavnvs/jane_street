// Small synchronous FIFO used between the host interface and each engine.
// Push while full and pop while empty are ignored.
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
    output logic [WIDTH-1:0] dout,
    output logic             empty,
    output logic             full
);
  localparam int DEPTH = 1 << ADDR_BITS;

  logic [WIDTH-1:0] mem[DEPTH];
  logic [ADDR_BITS:0] wptr, rptr;  // extra bit tells full from empty

  assign empty = (wptr == rptr);
  assign full  = (wptr[ADDR_BITS-1:0] == rptr[ADDR_BITS-1:0]) && (wptr[ADDR_BITS] != rptr[ADDR_BITS]);
  assign dout  = mem[rptr[ADDR_BITS-1:0]];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wptr <= '0;
      rptr <= '0;
    end else if (flush) begin
      wptr <= '0;
      rptr <= '0;
    end else begin
      if (push && !full) wptr <= wptr + 1'b1;
      if (pop && !empty) rptr <= rptr + 1'b1;
    end
  end

  // Storage has no reset: it is never read before it is written.
  always_ff @(posedge clk) begin
    if (push && !full) mem[wptr[ADDR_BITS-1:0]] <= din;
  end
endmodule
