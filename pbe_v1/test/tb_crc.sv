`timescale 1ns / 1ps
// Unit test of the CRC unit (pbe_crc) at 32 bits (D91), against values from outside the RTL:
//  (a) the check values ("123456789") of the reveng catalogue: CRC-32 (ISO-HDLC, the Ethernet
//      FCS) 0xCBF43926, CRC-32/BZIP2 0xFC891918, CRC-32/MPEG-2 0x0376E6E7, CRC-32C (iSCSI)
//      0xE3069283, CRC-32/POSIX (cksum's CRC, before its length bytes) 0x765E7680;
//  (b) Ethernet frames: the FCS from a byte-wise table-free reflected CRC-32 written here
//      (poly 0xEDB88320, the other formulation), fed to the unit in wire order (LSB first);
//      the unit's inverted, reversed value sent low byte first must equal it, and a receiver
//      fed the frame and its FCS must stop at the residue 0xC704DD7B (0xDEBB20E3 reflected);
//      a frame with one bit flipped must not;
//  (c) bit-identity with the 16-bit unit of before D91 (ref_pbe_crc16.sv) for random widths
//      1-16, polynomials, init, reversal and good values, with random init/step sequences.
module tb_crc;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;
  task automatic check(input bit ok, input string msg);
    if (!ok) begin
      errors++;
      $display("  FAIL: %s", msg);
    end
  endtask

  logic        init = 0, step = 0, bit_in = 0, init_ones = 0, out_rev = 0;
  logic [31:0] poly = 0, good = 0;
  logic [4:0]  wm1 = 0;
  wire  [31:0] value;
  wire         ok;
  pbe_crc dut (.clk, .rst_n, .init, .step, .bit_in, .poly, .width_m1(wm1), .init_ones, .out_rev,
               .good, .value, .ok);

  // the reference 16-bit unit, on the same inputs (16-bit slices)
  wire [15:0] value16;
  wire        ok16;
  ref_pbe_crc16 ref16 (.clk, .rst_n, .init, .step, .bit_in, .poly(poly[15:0]), .width_m1(wm1[3:0]),
                       .init_ones, .out_rev, .good(good[15:0]), .value(value16), .ok(ok16));

  task automatic crc_init();
    @(negedge clk) init = 1;
    @(negedge clk) init = 0;
  endtask
  task automatic feed_bit(input bit b);
    @(negedge clk) begin step = 1; bit_in = b; end
    @(negedge clk) step = 0;
  endtask
  task automatic feed_byte(input logic [7:0] d, input bit lsb_first);
    for (int k = 0; k < 8; k++) feed_bit(lsb_first ? d[k] : d[7-k]);
  endtask

  // ---- the independent reference: reflected CRC-32, byte-wise, poly 0xEDB88320 ----
  // (of the module-level frame[0..n-1]: Icarus 12 and array arguments, BUG-127)
  logic [7:0] frame[1514];
  function automatic logic [31:0] crc32_ref(input int n);
    logic [31:0] c;
    c = 32'hFFFF_FFFF;
    for (int i = 0; i < n; i++) begin
      c = c ^ {24'b0, frame[i]};
      for (int k = 0; k < 8; k++) c = c[0] ? (c >> 1) ^ 32'hEDB8_8320 : c >> 1;
    end
    return ~c;
  endfunction

  logic [7:0] chk[9];
  initial for (int i = 0; i < 9; i++) chk[i] = 8'h31 + 8'(i);  // "123456789"

  // one catalogue CRC: poly, init all ones?, reflected (LSB first and reversed out)?, xorout
  task automatic catalogue(input string name, input logic [31:0] p, input bit ones, input bit refl,
                           input logic [31:0] xorout, input logic [31:0] expect_v);
    logic [31:0] v;
    poly = p; wm1 = 5'd31; init_ones = ones; out_rev = refl;
    crc_init();
    for (int i = 0; i < 9; i++) feed_byte(chk[i], refl);
    @(negedge clk) v = value ^ xorout;
    check(v == expect_v, $sformatf("%s check value %08x, catalogue %08x", name, v, expect_v));
    $display("(a) %-14s \"123456789\" -> %08x (catalogue %08x)", name, v, expect_v);
  endtask

  int n;
  initial begin
    logic [31:0] fcs, sent;
    logic [7:0] fb[4];
    repeat (3) @(negedge clk);
    rst_n = 1;

    // (a)
    catalogue("CRC-32",        32'h04C1_1DB7, 1, 1, 32'hFFFF_FFFF, 32'hCBF4_3926);
    catalogue("CRC-32/BZIP2",  32'h04C1_1DB7, 1, 0, 32'hFFFF_FFFF, 32'hFC89_1918);
    catalogue("CRC-32/MPEG-2", 32'h04C1_1DB7, 1, 0, 32'h0000_0000, 32'h0376_E6E7);
    catalogue("CRC-32C",       32'h1EDC_6F41, 1, 1, 32'hFFFF_FFFF, 32'hE306_9283);
    catalogue("CRC-32/POSIX",  32'h04C1_1DB7, 0, 0, 32'hFFFF_FFFF, 32'h765E_7680);

    // (b) Ethernet frames: 60 bytes (minimum without FCS), 514, 1514, random contents
    poly = 32'h04C1_1DB7; wm1 = 5'd31; init_ones = 1; out_rev = 1; good = 32'hC704_DD7B;
    for (int s = 0; s < 3; s++) begin
      n = s == 0 ? 60 : s == 1 ? 514 : 1514;
      for (int i = 0; i < n; i++) frame[i] = 8'($urandom);
      frame[0] = 8'hFF;  // a broadcast destination
      fcs = crc32_ref(n);
      crc_init();
      for (int i = 0; i < n; i++) feed_byte(frame[i], 1);
      @(negedge clk) sent = ~value;  // inverted, reversed: bytes 0..3 go out low byte first
      check(sent == fcs, $sformatf("Ethernet %0d bytes: FCS %08x, reference %08x", n, sent, fcs));
      fb[0] = sent[7:0]; fb[1] = sent[15:8]; fb[2] = sent[23:16]; fb[3] = sent[31:24];
      for (int k = 0; k < 4; k++) feed_byte(fb[k], 1);  // a receiver feeds the FCS too
      @(negedge clk) check(ok && dut.crc == 32'hC704_DD7B,
                           $sformatf("Ethernet %0d bytes: residue %08x, want C704DD7B", n, dut.crc));
      // the same frame with one bit flipped
      crc_init();
      for (int i = 0; i < n; i++) feed_byte(i == n / 2 ? frame[i] ^ 8'h10 : frame[i], 1);
      for (int k = 0; k < 4; k++) feed_byte(fb[k], 1);
      @(negedge clk) check(!ok, $sformatf("Ethernet %0d bytes: a flipped bit still gave the residue", n));
      $display("(b) Ethernet frame of %0d bytes + FCS %08x: matches the reference; residue C704DD7B; a flipped bit is caught", n, fcs);
    end

    // (c) widths up to 16: bit-identical to the old unit. From reset: (b) left 32-bit state in
    // the register, which a width change does not clear (the documented live-change rule).
    begin
      int bad;
      bad = 0;
      @(negedge clk) rst_n = 0;
      @(negedge clk) rst_n = 1;
      for (int t = 0; t < 300; t++) begin
        poly = {16'h0000, 16'($urandom)};
        good = {16'h0000, 16'($urandom)};
        wm1 = 5'($urandom_range(0, 15));
        init_ones = $urandom_range(0, 1);
        out_rev = $urandom_range(0, 1);
        for (int k = 0; k < 40; k++) begin
          @(negedge clk) begin
            init = ($urandom_range(0, 15) == 0);
            step = $urandom_range(0, 1);
            bit_in = $urandom_range(0, 1);
          end
          @(posedge clk) #1;
          if (value != {16'h0000, value16} || ok != ok16) bad++;
        end
        if (t % 50 == 0) good = {16'h0000, value16};  // sometimes "ok" is true
      end
      @(negedge clk) begin init = 0; step = 0; end
      check(bad == 0, $sformatf("(c) %0d clocks differ from the 16-bit unit", bad));
      $display("(c) 300 random CRCs of 1-16 bits, 12000 clocks: identical to the 16-bit unit");
    end

    if (errors == 0) $display("PASS: CRC unit");
    else $fatal(1, "FAILED with %0d error(s)", errors);
    $finish;
  end
endmodule
