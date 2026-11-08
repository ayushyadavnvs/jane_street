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
- 2026-11-08: session 1. Gauged knowledge. Next: install KLayout, download the fork's gds
  artifacts, send run URL and file list.

## What Ayush knows
- Verilog and basic digital design. No ASIC physical design yet.
- Knows the flow order in theory (synth -> floorplan -> place -> CTS -> route -> STA -> DRC -> LVS)
  and basic STA (setup/hold, slack, post-route RC). Knows SRAM saves area, has one port, needs power.
- Gaps filled in session 1 (check later): PDN is its own step after floorplan; STA runs at
  several stages and corners, signoff uses extracted parasitics (SPEF); hold buffers come
  after CTS; SRAM read is synchronous (one-cycle latency); a macro is a placement/routing
  blockage described by LEF (abstract) + .lib (timing) + GDS (layout).
- Has never used KLayout or downloaded Actions artifacts. Cloned jane_street and his
  SRAM-example fork in ~.

## Open questions / to revisit
