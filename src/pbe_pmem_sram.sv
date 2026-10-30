// Program memory in SRAM (D62, a proposal; used only when USE_SRAM is defined).
//
// One IHP RM_IHPSG13_1P_256x16_c2_bm_bist (single port, 256 x 16, synchronous read) per engine.
// The host writes every copy at once, so the engines still see one shared program image, as
// with the flip-flop memory (START_PC, 64-word windows, the assembler's images: all unchanged).
//
// The macro reads at a clock edge: the engine gives it pc_d, the address pc takes at that edge,
// so after the edge DOUT is the word at pc, which is what the flip-flop memory's read gives
// (D50's stage 1 is now inside the macro). DOUT keeps its value while the macro is not read.
//
// A write uses the port for that clock, so the read at that edge does not happen and DOUT is
// stale for one clock. The top level gives the engines a refetch (pm_wr) at the write and again
// one clock later; the second refetch reads the word the first one wanted.
module pbe_pmem_sram #(
    parameter int ENGINES = 2
) (
    input  logic                 clk,
    input  logic                 pm_wr,     // host write this clock
    input  logic [7:0]           pm_ptr,    // byte pointer: word = [7:1], [0] = 0 high byte
    input  logic [7:0]           wr_data,
    input  logic [ENGINES*7-1:0] pc_d,      // each engine's next read address
    output logic [ENGINES*16-1:0] instr     // each engine's word at pc
);
  wire [15:0] bm = pm_ptr[0] ? 16'h00ff : 16'hff00;

  for (genvar e = 0; e < ENGINES; e++) begin : g_mem
    // The top address bit is unused for now: 128 words, as with the flip-flops.
    wire [7:0] addr = pm_wr ? {1'b0, pm_ptr[7:1]} : {1'b0, pc_d[e*7+:7]};

    RM_IHPSG13_1P_256x16_c2_bm_bist u_sram (
        .A_CLK      (clk),
        .A_MEN      (1'b1),
        .A_WEN      (pm_wr),
        .A_REN      (!pm_wr),
        .A_ADDR     (addr),
        .A_DIN      ({wr_data, wr_data}),
        .A_BM       (bm),
        .A_DLY      (1'b1),  // the datasheet: must be tied to 1
        .A_DOUT     (instr[e*16+:16]),
        .A_BIST_CLK (1'b0),
        .A_BIST_EN  (1'b0),
        .A_BIST_MEN (1'b0),
        .A_BIST_WEN (1'b0),
        .A_BIST_REN (1'b0),
        .A_BIST_ADDR(8'h00),
        .A_BIST_DIN (16'h0000),
        .A_BIST_BM  (16'h0000)
    );
  end
endmodule
