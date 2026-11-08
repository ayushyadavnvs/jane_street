/*
 * Copyright (c) 2026 Tiny Tapeout B.V.
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

// Black-box declaration of the IHP SRAM macro, for synthesis and linting.
// The layout comes from the PDK (MACROS in src/config.json). Simulation uses
// the IHP behavioural model in test/sram_model instead, so this file is skipped
// when SIM is defined.
//
// Copied unchanged (but for this paragraph) from Tiny Tapeout's ttihp-cmos5l-sram-example
// (https://github.com/TinyTapeout/ttihp-cmos5l-sram-example, src/sram_bb.v, commit 15ac9bc),
// Apache-2.0. In this repository the model is in macros/RM_IHPSG13_1P_256x16_c2_bm_bist/ and
// test/sram_model/; pbe_v1/Makefile reads this file for `make synth`, `make timing` and lint
// (D82). For the flow it goes in info.yaml's source_files (docs/SRAM_8x4_FLOW_STEPS.md).
`ifndef SIM
/* verilator lint_off UNDRIVEN */
/* verilator lint_off UNUSEDSIGNAL */
(* blackbox *)
module RM_IHPSG13_1P_256x16_c2_bm_bist (
    input  wire        A_CLK,
    input  wire        A_MEN,
    input  wire        A_WEN,
    input  wire        A_REN,
    input  wire [7:0]  A_ADDR,
    input  wire [15:0] A_DIN,
    input  wire        A_DLY,
    output wire [15:0] A_DOUT,
    input  wire [15:0] A_BM,
    input  wire        A_BIST_CLK,
    input  wire        A_BIST_EN,
    input  wire        A_BIST_MEN,
    input  wire        A_BIST_WEN,
    input  wire        A_BIST_REN,
    input  wire [7:0]  A_BIST_ADDR,
    input  wire [15:0] A_BIST_DIN,
    input  wire [15:0] A_BIST_BM
);
endmodule
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNDRIVEN */
`endif
