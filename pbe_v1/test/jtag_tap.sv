`timescale 1ns / 1ps
// An IEEE 1149.1 test access port, written from the standard (not from jtag.pbe), for tb_debug.
//
// - The 16-state TAP controller, advanced by TMS at every rising edge of TCK; Test-Logic-Reset
//   at power-up (there is no TRST*).
// - Instruction register of IRLEN bits; Capture-IR loads ...0001 (1149.1 7.1.1: the two least
//   significant bits are 01). Test-Logic-Reset selects IDCODE (the device has one, 1149.1 7.2.1).
// - Instructions: IDCODE (32-bit device identification, bit 0 = 1), USER (a 32-bit data
//   register: Capture-DR loads it, Update-DR writes it), BYPASS (all ones, 1 bit, captures 0);
//   every other opcode selects BYPASS (1149.1 8.4.1: unused opcodes are BYPASS).
// - Capture and shift happen at the rising edge of TCK in Capture-xR and Shift-xR; Update-xR
//   latches at the falling edge; TDO changes at the falling edge (after TCO ns) and is driven
//   only in Shift-DR and Shift-IR (1149.1 4.5.1), high-impedance otherwise.
module jtag_tap #(
    parameter int          IRLEN   = 4,
    parameter logic [31:0] IDCODE  = 32'h4BA00477,
    parameter logic [31:0] USER0   = 32'h00000000,   // the USER register after power-up
    parameter logic [IRLEN-1:0] I_IDCODE = 'b1110,
    parameter logic [IRLEN-1:0] I_USER   = 'b1010,
    parameter real         TCO     = 8.0
) (
    input  logic tck,
    input  logic tms,
    input  logic tdi,
    output logic tdo,      // the value, meaningful while tdo_en
    output logic tdo_en
);
  typedef enum logic [3:0] {
    TLR, RTI, SEL_DR, CAP_DR, SH_DR, EX1_DR, PAU_DR, EX2_DR, UPD_DR,
    SEL_IR, CAP_IR, SH_IR, EX1_IR, PAU_IR, EX2_IR, UPD_IR
  } state_t;

  state_t state = TLR;
  logic [IRLEN-1:0] ir = I_IDCODE, ir_sr = '0;
  logic [31:0] user = USER0, dr_sr = '0;
  int unsigned updates_dr = 0, updates_ir = 0;

  function automatic state_t next(input state_t s, input logic m);
    case (s)
      TLR:    return m ? TLR    : RTI;
      RTI:    return m ? SEL_DR : RTI;
      SEL_DR: return m ? SEL_IR : CAP_DR;
      CAP_DR: return m ? EX1_DR : SH_DR;
      SH_DR:  return m ? EX1_DR : SH_DR;
      EX1_DR: return m ? UPD_DR : PAU_DR;
      PAU_DR: return m ? EX2_DR : PAU_DR;
      EX2_DR: return m ? UPD_DR : SH_DR;
      UPD_DR: return m ? SEL_DR : RTI;
      SEL_IR: return m ? TLR    : CAP_IR;
      CAP_IR: return m ? EX1_IR : SH_IR;
      SH_IR:  return m ? EX1_IR : SH_IR;
      EX1_IR: return m ? UPD_IR : PAU_IR;
      PAU_IR: return m ? EX2_IR : PAU_IR;
      EX2_IR: return m ? UPD_IR : SH_IR;
      default: return m ? SEL_DR : RTI;  // UPD_IR
    endcase
  endfunction

  // the data register the current instruction selects: its length
  function automatic int dr_len();
    if (ir == I_IDCODE || ir == I_USER) return 32;
    return 1;  // BYPASS
  endfunction

  always @(posedge tck) begin
    case (state)
      CAP_DR: dr_sr <= (ir == I_IDCODE) ? IDCODE : (ir == I_USER) ? user : 32'd0;
      SH_DR:  dr_sr <= (dr_sr >> 1) | (32'(tdi) << (dr_len() - 1));
      CAP_IR: ir_sr <= IRLEN'(1);
      SH_IR:  ir_sr <= {tdi, ir_sr[IRLEN-1:1]};
      default: ;
    endcase
    state <= next(state, tms);
  end

  always @(negedge tck) begin
    case (state)
      UPD_DR: begin if (ir == I_USER) user <= dr_sr; updates_dr++; end
      UPD_IR: begin ir <= ir_sr; updates_ir++; end
      TLR:    ir <= I_IDCODE;
      default: ;
    endcase
    tdo    <= #(TCO) (state == SH_IR) ? ir_sr[0] : dr_sr[0];
    tdo_en <= #(TCO) (state == SH_DR || state == SH_IR);
  end

  initial begin
    tdo = 1'b1;
    tdo_en = 1'b0;
  end
endmodule
