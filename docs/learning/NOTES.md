# Learning notes: GDS flow, then design and verification

Running notes from tutoring sessions, so a later session can pick up where the last one stopped.
Branch `learn/notes` only.

## Plan
1. Read a finished run: Ayush's fork of `TinyTapeout/ttihp-cmos5l-sram-example`
   (artifacts, GDS in KLayout, precheck, `*-extendpowerstripes` log, `irdrop.rpt`,
   STA per corner, utilization).
2. Local flow on that example (TT local-hardening guide), OpenROAD GUI on intermediate steps.
3. SRAM flow-config on `feature/sram-8x4` (Ayush does the edits; tutor reviews diffs).
   First real GDS run of PBE with SRAM, then read its results.
4. Later: the design (ISA, register map, D50 fetch timing, pbe_line, pbe_bsync, programs).
5. Later: verification (testbenches, GL sim, golden model, formal, mutation, coverage).
6. Later: timing closure with his own reports.

## Status
- 2026-11-08: session 1. Gauged knowledge.
- 2026-11-12: KLayout 0.30.13 installed. Fork run: actions/runs/42174634387 (gds 4m27s,
  precheck 10/10, 130 cells, 7325 fill/decap, 47 dlygate4sd3 hold cells, util 2.291 %).
  Artifacts downloaded to ~/tt/sram-example-run (via the Artifacts box at the very bottom of
  the run page, below all job summaries). Opened GDS in KLayout; found the SRAM cell
  (boundary 189/4, 236.8 x 118.78 in its own coordinates). Listed the 71 flow steps.
  Saw MACROS position (3.36, 3.78) in KLayout; saw Metal4 (50/0) tile stripes continuing
  over the SRAM onto its own (gapped) Metal4 columns = ExtendPowerStripes.
  Mapped the 71 LibreLane steps to stages (lint 01-04, synth 05-09, floorplan 13-19,
  PDN 20-23, place 24-35, CTS+hold 36-39, route 40-52, fill 53, RCX 55, signoff STA 56,
  IR drop 57, GDS 58-61, LVS 63-66, final checks 67-71; no DRC in flow, precheck does it).
  Read signoff STA summary (hold worst 0.137 fast corner, setup worst 9.68 slow, not reg2reg)
  and walked line by line through the worst hold path (flop -> 2 dlygates -> sram/A_BM[14];
  SRAM lib hold 0.217 + uncertainty 0.25). Understands pin/net lines, Time column, MET,
  hold slack = arrival - required, hold independent of clock period.
  Skipped for now: max.rpt (setup path), clock-skew questions.
- 2026-11-12 (later): Ayush asked to move on to the PBE flow. Plan: quick read of the example's
  extendpowerstripes log, irdrop.rpt, LVS, metrics; then docs/SRAM_8x4_FLOW_STEPS.md steps
  1-3 on feature/sram-8x4 (he edits, tutor reviews diff); start CI run; set up local flow
  while it runs.

## What Ayush knows
- Verilog and basic digital design. No ASIC physical design yet.
- Knows the flow order in theory (synth -> floorplan -> place -> CTS -> route -> STA -> DRC -> LVS)
  and basic STA (setup/hold, slack, post-route RC). Knows SRAM saves area, has one port, needs power.
- Gaps filled in session 1 (check later): PDN is its own step after floorplan; STA runs at
  several stages and corners, signoff uses extracted parasitics (SPEF); hold buffers come
  after CTS; SRAM read is synchronous (one-cycle latency); a macro is a placement/routing
  blockage described by LEF (abstract) + .lib (timing) + GDS (layout).
- Understands: hold buffers can hurt setup; fill/decap; SRAM bits live in bitcells.
- Had never used KLayout or downloaded Actions artifacts. Cloned jane_street and his
  SRAM-example fork in ~.

## Open questions / to revisit
