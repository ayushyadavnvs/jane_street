// General CRC unit, one per engine. Any polynomial up to 16 bits.
//
// One bit per step, shifted in at the bottom of a shift-left register (the polynomial's top
// term is implied). Feed bits in the order they are on the wire. For CRCs sent LSB first
// (Modbus CRC-16, 1-Wire CRC-8) read the result bit-reversed (out_rev); for CRCs sent MSB
// first (CAN CRC-15) read it plain. A frame followed by its own correct CRC leaves the
// register at zero for every CRC without a final inversion, and at a fixed residual for CRCs
// sent inverted (USB CRC16: 0x800d). "CRC ok" means the register equals `good`.
// Reset sets the register to zero regardless of init_ones. init wins over a coincident
// step and loads zero/all width bits set; each step XORs bit_in with the old top bit,
// shifts left with zero at bit 0, conditionally XORs poly, then masks to the width.
// out_rev reverses only width bits and zero-extends; good compares the raw 16-bit state.
// Live width/poly/good changes do not themselves initialize or mask the stored state.
//
//   Modbus CRC-16: poly 0x8005, 16 bits, init all ones, reversed output
//   1-Wire CRC-8:  poly 0x31,    8 bits, init zero,     reversed output
//   USB CRC16:     poly 0x8005, 16 bits, init all ones, reversed output, sent inverted, good 0x800d
module pbe_crc (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        init,       // load the initial value
    input  logic        step,       // shift in bit_in
    input  logic        bit_in,
    input  logic [15:0] poly,
    input  logic [3:0]  width_m1,   // CRC width - 1
    input  logic        init_ones,
    input  logic        out_rev,
    input  logic [15:0] good,       // the register value that means "ok"
    output logic [15:0] value,      // the CRC field, ready to send LSB first if out_rev
    output logic        ok
);
  logic [15:0] crc, rev;

  wire [15:0] top  = 16'h0001 << width_m1;
  wire [15:0] mask = {top[14:0], 1'b0} - 1'b1;  // width 16: wraps to all ones
  wire        fb   = bit_in ^ |(crc & top);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) crc <= '0;
    else if (init) crc <= init_ones ? mask : '0;
    else if (step) crc <= ({crc[14:0], 1'b0} ^ (fb ? poly : 16'h0000)) & mask;
  end

  always_comb begin
    for (int i = 0; i < 16; i++) rev[i] = (4'(i) <= width_m1) ? crc[width_m1 - 4'(i)] : 1'b0;
  end

  assign value = out_rev ? rev : crc;
  assign ok    = (crc == good);
endmodule
