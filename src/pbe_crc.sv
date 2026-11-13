// General CRC unit, one per engine. Any polynomial up to 32 bits (D91; up to 16 before).
//
// One bit per step, shifted in at the bottom of a shift-left register (the polynomial's top
// term is implied). Feed bits in the order they are on the wire. For CRCs sent LSB first
// (Modbus CRC-16, 1-Wire CRC-8, Ethernet's CRC-32) read the result bit-reversed (out_rev); for
// CRCs sent MSB first (CAN CRC-15, MPEG-2's CRC-32) read it plain. A frame followed by its own
// correct CRC leaves the register at zero for every CRC without a final inversion, and at a
// fixed residual for CRCs sent inverted (USB CRC16: 0x800d; CRC-32: 0xC704DD7B, which is
// 0xDEBB20E3 bit-reversed, the residue usually quoted for the reflected algorithm). "CRC ok"
// means the register equals `good`.
// Reset sets the register to zero regardless of init_ones. init wins over a coincident
// step and loads zero/all width bits set; each step XORs bit_in with the old top bit,
// shifts left with zero at bit 0, conditionally XORs poly, then masks to the width.
// out_rev reverses only width bits and zero-extends; good compares the raw 32-bit state.
// Live width/poly/good changes do not themselves initialize or mask the stored state.
// For widths up to 16 (width_m1[4] = 0) with poly[31:16] = good[31:16] = 0, every output is
// bit for bit what the 16-bit unit gave (value[31:16] = 0): tb_crc checks it.
//
//   Modbus CRC-16: poly 0x8005, 16 bits, init all ones, reversed output
//   1-Wire CRC-8:  poly 0x31,    8 bits, init zero,     reversed output
//   USB CRC16:     poly 0x8005, 16 bits, init all ones, reversed output, sent inverted, good 0x800d
//   CRC-32 (Ethernet FCS, zip, PNG): poly 0x04C11DB7, 32 bits, init all ones, reversed output,
//                  sent inverted, good 0xC704DD7B
//   CRC-32/MPEG-2: poly 0x04C11DB7, 32 bits, init all ones, plain output, sent plain, good 0
module pbe_crc (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        init,       // load the initial value
    input  logic        step,       // shift in bit_in
    input  logic        bit_in,
    input  logic [31:0] poly,
    input  logic [4:0]  width_m1,   // CRC width - 1
    input  logic        init_ones,
    input  logic        out_rev,
    input  logic [31:0] good,       // the register value that means "ok"
    output logic [31:0] value,      // the CRC field, ready to send LSB first if out_rev
    output logic        ok
);
  logic [31:0] crc, rev;

  wire [31:0] top  = 32'h0000_0001 << width_m1;
  wire [31:0] mask = {top[30:0], 1'b0} - 1'b1;  // width 32: wraps to all ones
  wire        fb   = bit_in ^ |(crc & top);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) crc <= '0;
    else if (init) crc <= init_ones ? mask : '0;
    else if (step) crc <= ({crc[30:0], 1'b0} ^ (fb ? poly : 32'h0000_0000)) & mask;
  end

  always_comb begin
    for (int i = 0; i < 32; i++) rev[i] = (5'(i) <= width_m1) ? crc[width_m1 - 5'(i)] : 1'b0;
  end

  assign value = out_rev ? rev : crc;
  assign ok    = (crc == good);
endmodule
