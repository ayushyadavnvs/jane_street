// Program memory in SRAM (D62, D82): the default build.
//
// One IHP RM_IHPSG13_1P_256x16_c2_bm_bist (single port, 256 x 16, synchronous read) per engine.
// Each engine has its own 256-word image: a host write goes only to the memory of the engine
// that PM_ADDR_H selects (D82), so the two engines have 512 independent words.
//
// The macro reads at a clock edge: the engine gives it pc_d, the address pc takes at that edge,
// so after the edge DOUT is the word at pc, which is what the flip-flop memory's read gives
// (D50's stage 1 is now inside the macro). DOUT keeps its value while the macro is not read.
//
// A write uses that macro's port for that clock, so its read at that edge does not happen and
// its DOUT is stale for one clock. The top level gives that engine (only) a refetch at the
// write and again one clock later; the second refetch reads the word the first one wanted
// (BUG-074). The other engine's macro is not touched, so it keeps running undisturbed.
//
// Tie-offs, checked against IHP's datasheet and Tiny Tapeout's ttihp-cmos5l-sram-example
// (src/project.v): A_DLY = 1 (mandatory), the BIST port off (A_BIST_EN = 0, its inputs 0).
// A_MEN is tied to 1: the macro is read every clock. The example drives MEN from a register
// that is 0 in reset; here no write can happen in reset (wr_en is a reset flip-flop), and the
// reads in reset are refetched after it (pm_wr_q's reset value), so a constant 1 is enough.
// The write controls, the write address and data come from flip-flops through a small decode
// (wr_en/wr_addr/wr_data of pbe_host_spi, the pointer). The read address does not: it is the
// engine's pc_next, so that the read lines up with D50's prefetch. That path (engine state ->
// pc_next -> A_ADDR, setup about -0.6 ns at the slow corner) must be checked in the flow's STA.
//
// Instance names after Yosys flattens the design (MACROS / PDN_MACRO_CONNECTIONS in
// src/config.json, docs/SRAM_8x4_FLOW_STEPS.md): u_pmem.u_sram0 (engine 0), u_pmem.u_sram1
// (engine 1). They are written out, not made by a generate loop, so that the names have no
// brackets to escape in the flow's configuration.
module pbe_pmem_sram (
    input  logic        clk,
    input  logic [1:0]  pm_wr,    // host write to engine e's memory this clock
    input  logic [8:0]  pm_ptr,   // byte pointer: word = [8:1], [0] = 0 high byte
    input  logic [7:0]  wr_data,
    input  logic [15:0] pc_d,     // each engine's next read address (8 bits per engine)
    output logic [31:0] instr     // each engine's word at pc (16 bits per engine)
);
  wire [15:0] bm  = pm_ptr[0] ? 16'h00ff : 16'hff00;
  wire [15:0] din = {wr_data, wr_data};
  wire [7:0]  addr0 = pm_wr[0] ? pm_ptr[8:1] : pc_d[7:0];
  wire [7:0]  addr1 = pm_wr[1] ? pm_ptr[8:1] : pc_d[15:8];

  RM_IHPSG13_1P_256x16_c2_bm_bist u_sram0 (
      .A_CLK(clk), .A_MEN(1'b1), .A_WEN(pm_wr[0]), .A_REN(!pm_wr[0]), .A_ADDR(addr0),
      .A_DIN(din), .A_BM(bm),
      .A_DLY(1'b1),  // the datasheet: must be tied to 1
      .A_DOUT(instr[15:0]),
      .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0),
      .A_BIST_REN(1'b0), .A_BIST_ADDR(8'h00), .A_BIST_DIN(16'h0000), .A_BIST_BM(16'h0000)
  );

  RM_IHPSG13_1P_256x16_c2_bm_bist u_sram1 (
      .A_CLK(clk), .A_MEN(1'b1), .A_WEN(pm_wr[1]), .A_REN(!pm_wr[1]), .A_ADDR(addr1),
      .A_DIN(din), .A_BM(bm),
      .A_DLY(1'b1),  // the datasheet: must be tied to 1
      .A_DOUT(instr[31:16]),
      .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0),
      .A_BIST_REN(1'b0), .A_BIST_ADDR(8'h00), .A_BIST_DIN(16'h0000), .A_BIST_BM(16'h0000)
  );
endmodule
