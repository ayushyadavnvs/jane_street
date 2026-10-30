# Program memory: flip-flops or SRAM? (investigation, October 2026)

Branch `investigate/sram`. Decision entry: D62 in `docs/DESIGN_DECISIONS.md` (a proposal).
Proof of concept: `src/pbe_pmem_sram.sv`, the `USE_SRAM` branch of `src/tt_um_pbe.sv`,
`macros/RM_IHPSG13_1P_256x16_c2_bm_bist/`, and the flow change set in `sram/`. The default
build (no `USE_SRAM`) is unchanged; `make test` runs both.

## Summary

- **The macros exist for CMOS5L and the Tiny Tapeout flow installs them.** In IHP-Open-PDK,
  `ihp-sg13cmos5l/libs.ref/sg13cmos5l_sram` is a symlink to the SG13G2 SRAM library: 20
  single-port (`1P`) and 10 dual-port (`2P`) macros, with GDS, LEF, Liberty (3 corners), CDL
  and a Verilog model each. The macros use Metal1 to Metal4 only, which is what a CMOS5L Tiny
  Tapeout block may use. Our flow (`tt-gds-action@ttihp27a`, LibreLane 3.1.0.dev4) installs
  PDK commit `89d42ee`, whose SRAM files are byte-identical to today's `dev` branch.
- **Other CMOS5L Tiny Tapeout projects already pass the full flow with them.**
  TeslaCoilerOW/ttihp-protocol-emulator (8 × `RM_IHPSG13_1P_64x16_c2`, including a 6x4
  build) and, by its notes, tt_um_loom (`RM_IHPSG13_1P_512x16`) pass `gds`, `precheck` and
  `gl_test`. The precheck allows the SRAM's layers on CMOS5L.
- **The flip-flop memory is about half of our chip.** In the first routed run it is
  **246,900 µm²: 55 % of the standard-cell area and 27 % of the 6x4 die**, counting the
  2,048 flip-flops, their write logic, the read multiplexers, the address buffer trees, the
  2,048 tie cells on their unused resets, and **2,048 of the 3,590 hold buffers** (one per
  memory bit, 33,443 µm²).
- **Recommendation: one `RM_IHPSG13_1P_256x16_c2_bm_bist` per engine, both written by the
  host** (option b with mirrored writes). Expected: about **185,000 µm² less** (utilization
  about 50 % → about 29 %), the worst-path problem of D45/D50 gone (no more 128-way
  multiplexer tree on `pc`), and room for **256 words** (twice today) at no extra area, or
  512 with the 512 × 16 macro. The programs, `START_PC` and the host's view stay the same.
- **The main risk is the power hookup.** On CMOS5L the block's power stripes and the SRAM's
  power pins are both on Metal4, so the stripes must land exactly on the macro's power
  columns. The two passing projects show the method; `sram/` applies it to our floorplan
  and checks it without tools. Nothing here has been through LibreLane yet.

## 1. Which SRAM macros exist for sg13cmos5l

### 1.1 Where they are

| What | Where (verified 2026-10-29) |
|---|---|
| CMOS5L SRAM library | `ihp-sg13cmos5l/libs.ref/sg13cmos5l_sram`, a symlink to `../../ihp-sg13g2/libs.ref/sg13g2_sram`, on IHP-Open-PDK `dev` (7b41fd1) and at `89d42ee`. CMOS5L is not on `main` yet |
| Views per macro | `gds/`, `lef/`, `lib/` (typ 1.20 V 25 °C, slow 1.08 V 125 °C, fast 1.32 V −55 °C), `cdl/`, `verilog/` (model + behavioural core), `doc/` (datasheet) |
| PDK the flow installs | LibreLane 3.1.0.dev4 `pdk_hashes.yaml`: `ihp-sg13: 89d42ee6d2fd…` (and our run's `pdk.json` says the same). `tt-gds-action@ttihp27a` picks LibreLane 3.1.0.dev4 for `ihp-sg13cmos5l`; its precheck uses the same commit |
| Identical files | `git diff 89d42ee 7b41fd1 -- ihp-sg13g2/libs.ref/sg13g2_sram` is empty; SHA-256 of our vendored copy in `macros/…/README.md` |
| Layers | LEF pins and obstructions: Metal1–Metal4 only. GDS: 22 layers (Activ, GatPoly, Cont, pSD, NWell, Metal1–4 with pin/res, Via1–3, SRAM.drawing, DigiBnd.drawing, prBoundary), all in tt-support-tools `precheck/tech_data.py` `valid_layers_ihp_sg13cmos5l` (SRAM and DigiBnd were added there by tt-support-tools PR #187) |
| What a CMOS5L block may use | tt-support-tools `tech.py` `IHPCmos5lTech`: "Projects may use up to Metal4, TopMetal1 is reserved for the chip-level power grid"; `RT_MAX_LAYER = Metal4` |

### 1.2 The candidates

Areas from the LEF (`SIZE`), times from the Liberty files (port A; the worst entry of each
table), `sram/tools/sram_lib_timing.py`. A Tiny Tapeout IHP tile is 202.08 × 154.98 µm
(31,318 µm²); our 6x4 die is 1289.28 × 710.64 µm (916,214 µm²).

| Macro | Words × bits | Ports | W × H (µm) | Area (µm²) | Tiles | µm²/bit | clk → DOUT slow / typ / fast (ns) |
|---|---|---|---|---|---|---|---|
| `RM_IHPSG13_1P_64x16_c2` | 64 × 16 | 1 | 236.80 × 64.36 | 15,240 | 0.49 | 14.9 | 5.30 / 3.17 / 1.95 |
| `RM_IHPSG13_1P_256x8_c3_bm_bist` | 256 × 8 | 1 | 236.80 × 74.10 | 17,547 | 0.56 | 8.6 | — |
| **`RM_IHPSG13_1P_256x16_c2_bm_bist`** | **256 × 16** | **1** | **236.80 × 118.78** | **28,127** | **0.90** | **6.9** | **5.30 / 3.18 / 1.96** |
| `RM_IHPSG13_1P_512x16_c2_bm_bist` | 512 × 16 | 1 | 236.80 × 191.34 | 45,309 | 1.45 | 5.5 | 6.56 / 3.93 / 2.42 |
| `RM_IHPSG13_1P_1024x16_c2_bm_bist` | 1024 × 16 | 1 | 236.80 × 336.46 | 79,674 | 2.54 | 4.9 | 7.42 / 4.46 / 2.74 |
| `RM_IHPSG13_1P_256x32_c2_bm_bist` | 256 × 32 | 1 | 416.64 × 118.78 | 49,488 | 1.58 | 6.0 | — |
| `RM_IHPSG13_2P_64x32_c2` | 64 × 32 | 2 | 702.83 × 74.87 | 52,621 | 1.68 | 25.7 | 5.52 / 3.30 / 2.02 |
| `RM_IHPSG13_2P_256x16_c2_bm_bist` | 256 × 16 | 2 | 419.95 × 136.97 | 57,521 | 1.84 | 14.0 | 5.39 / 3.18 / 1.98 |
| `RM_IHPSG13_2P_512x16_c2_bm_bist` | 512 × 16 | 2 | 402.61 × 219.77 | 88,482 | 2.83 | 10.8 | 6.67 / 3.99 / 2.45 |
| Flip-flops today (routed, all overheads, §2) | 128 × 16 | 2 read, 1 write | — | 246,900 | 7.9 | 120.6 | (in the pc path, D45) |

Also in the library: 1P 1024×8/32/64, 2048×32/64, 4096×8/16, 512×8/32/64, 256×48/64, 64×64,
8192×32; 2P 64×22, 256×8/32, 512×8/32, 1024×32.

**A 16-bit-wide macro exists** (64, 256, 512, 1024, 4096 words; 1P and 2P), so no width
adaptation is needed.

Common to all macros (Liberty and datasheet `RM_IHPSG13_1P_256x16_c2_bm_bist.txt`):

| | slow | typ | fast |
|---|---|---|---|
| Setup: `A_ADDR` / `A_DIN` / `A_WEN`, `A_MEN` / `A_REN` (ns) | −0.07 / −0.05 / 0.97 / 0.65 | 0.06 / 0.08 / 0.69 / 0.49 | 0.11 / 0.12 / 0.50 / 0.38 |
| Hold: `A_ADDR` / `A_DIN` / `A_MEN` (ns) | 1.38 / 0.90 / 0.91 | 0.93 / 0.56 / 0.66 | 0.64 / 0.36 / 0.48 |
| Minimum clock pulse (ns) | 0.40 | 0.21 | 0.12 |

- **Interface:** synchronous, one-cycle access: `A_ADDR`, `A_DIN`, `A_WEN`, `A_REN`, `A_MEN`
  sampled on the rising `A_CLK`. `A_BM` is a **per-bit write mask**, so the host's byte
  writes need no read-modify-write. `A_DOUT` holds its value until the next read (the model's
  `dr_r` register). `A_DLY` must be tied to 1. The `_bm_bist` variants add a BIST port, tied
  off. Write and read together is write-through.
- **2P macros:** two complete ports (each with clock, address, data in and out); "there is no
  conflict handling included" (datasheet).
- **Signal pins:** Metal2, all on the bottom edge (y = 0). **Supply pins:** `VDD!`,
  `VDDARRAY!` and `VSS!` as vertical Metal4 columns 2.81 µm wide (§3.6).

### 1.3 Tiny Tapeout projects on CMOS5L that use them

| Project | Macro | State (from its repository, read 2026-10-29) |
|---|---|---|
| [TeslaCoilerOW/ttihp-protocol-emulator](https://github.com/TeslaCoilerOW/ttihp-protocol-emulator) | 8 × `RM_IHPSG13_1P_64x16_c2` (instruction memories) | README: official `gds`, `precheck` and `gl_test` pass on 8x4 (e.g. run 36714406904); a 6x4 variant passes too (`docs/notes/6x4.md`, run 36391218297). Uses `tt-gds-action@ihp-cmos5l` |
| [thomasgilbert481/tt_um_loom](https://github.com/thomasgilbert481/tt_um_loom) | `RM_IHPSG13_1P_512x16_c2_bm_bist` | Has `src/pdn_cfg.tcl` and the macro; per TeslaCoilerOW's `docs/notes/hardening.md`, branch `sram-smoke` passed gds, precheck (KLayout DRC 0) and gl_test (run 35377845679). Second-hand: not checked by us |
| [Sashwath-s/ttihp-pinwheel](https://github.com/Sashwath-s/ttihp-pinwheel) | `RM_IHPSG13_1P_512x16_c2_bm_bist` | Config and PDN script; README: "Not done yet: GDS run" |

The competition page encourages SRAM for instruction memory. No rule against macros in a
6x4 design was found; the TeslaCoilerOW 6x4 build is one. One project notes that shuttle
admission of a macro "needs an answer from the organisers"; asking on the Tiny Tapeout
Discord before committing is cheap.

### 1.4 How the flow handles a macro

- **Placement:** LibreLane `MACROS` in `src/config.json`: per instance a fixed location and
  orientation, plus the GDS, LEF, Liberty per corner, a black-box netlist (`nl`) and the CDL.
  Instance names are the flattened RTL paths; LibreLane's CheckMacroInstances rejects others.
  Our names (from `make synth-sram`): `u_pmem.g_mem[0].u_sram`, `u_pmem.g_mem[1].u_sram`.
- **Power:** `PDN_MACRO_CONNECTIONS` ties `VDD!` and `VDDARRAY!` to `VPWR`, `VSS!` to `VGND`.
  The physical hookup is the hard part on CMOS5L (§3.6).
- **DRC/LVS:** Magic's CMOS5L rules lack the SRAM exceptions (loom saw about 58k in-macro
  errors), so the reference projects set `ERROR_ON_MAGIC_DRC` false and extract the macro as
  a black box (`MAGIC_EXT_ABSTRACT_CELLS`). The Tiny Tapeout precheck's KLayout DRC is the
  sign-off and passed for them.
- **Corners:** the CMOS5L STA corners are `nom_typ_1p20V_25C`, `nom_slow_1p08V_125C`,
  `nom_fast_1p32V_m40C`. Liberty keys `*_typ_*`, `*_slow_*`, `*_fast_*` give each its own
  file (the fast file is characterised at −55 °C).

## 2. What the flip-flop memory costs

### 2.1 Routed (measured)

The latest public `gds` run, [40780097577](https://github.com/ayushyadavnvs/jane_street/actions/runs/40780097577)
(commit 2776422, before D50; the run D45 reports), artifact `tt_submission`. The script
`sram/tools/pmem_cost.py` (method below) walks the routed netlist
`tt_um_ayushyadavnvs_pbe.v` with the CMOS5L typ Liberty areas.

| Part | Cells | Area (µm²) | Of which hold buffers |
|---|---|---|---|
| Memory flip-flops (`\pmem[w][b]`, `dfrbpq_1`) | 2,048 | 100,329 | — |
| Write logic: their D-input cone (enable mux2 per bit, decode, `wr_data` buffer tree) | 5,149 | 78,308 | **2,048 `dlygate4sd3_1`, 33,443 µm²** |
| Read multiplexers (mux4/mux2 fed by memory bits, their buffers) | 1,443 | 50,045 | 0 |
| `pc` select buffer trees (buffers driving only read-mux selects) | 368 | 3,364 | 2 |
| Tie-high cells on the flip-flops' unused resets | 2,048 | 14,864 | — |
| **Program memory in all** | **11,056** | **246,909** | **2,048 (33,443 µm²)** |
| Whole block (standard cells, no fill/decap) | 24,413 | 452,199 | 3,590 (58,623 µm²) |

- **Share:** 54.6 % of the standard-cell area, 26.9 % of the die. The metric
  `design__instance__area__stdcell` is 452,208 µm²; utilization 0.501.
- **Hold buffers:** exactly one per memory bit sits in each bit's hold-up loop (flip-flop →
  enable mux → flip-flop, almost no logic, against Tiny Tapeout's 0.25 ns clock uncertainty
  and 0.1 ns margin). That is 57 % of all 3,590 hold buffers.
- **Method:** write logic = the backward cone of the memory flip-flops' D pins, keeping only
  cells whose loads are all in that cone; read = cells reached forward from the memory bits
  through mux data inputs and buffers; select trees = buffers whose loads are all read-mux
  select pins. Cells shared with other logic are not counted, so these are lower bounds.
- **Not counted:** the pc buffer chains of the worst path (they also feed other logic), the
  D50 instruction registers and pc copies (+3,866 µm² in synthesis, D50, not routed yet).

### 2.2 Synthesis (`make synth`, Yosys 0.33, IHP typ library)

| | Today (flip-flops) | `USE_SRAM` (`make synth-sram`) |
|---|---|---|
| Standard-cell area | 337,264 µm² | 142,892 µm² (the macros are black boxes) |
| Flip-flops / mux2 / mux4 | 3,494 / 3,124 / 1,527 | 1,405 / 1,078 / 179 |
| The memory alone (`pm_flops`, a copy of the memory block with its two read ports) | 192,134 µm² (57 % of the total): flops 100,329, mux2 38,150, mux4 51,210 | — |

The synthesis view sees 192k µm²; routing adds the hold buffers, the ties and the buffer
trees (§2.1): about 247k µm².

## 3. Architectures

### 3.1 The comparison

Area: routed estimates from §2.1; "saved" is against today's 452k µm² of standard cells.

| | (a) Flip-flops (today) | **(b) 1P SRAM per engine, host writes both** | (c) One shared 2P SRAM | (d) One shared 1P SRAM, time-multiplexed | (e) Hybrid: SRAM + flop cache | (f) Latches instead of flip-flops |
|---|---|---|---|---|---|---|
| Macro(s) | — | 2 × 1P 256×16 (2 × 28,127 µm²) | 2P 256×16 (57,521 µm²) | 1P 256×16 (28,127 µm²) | 1 or 2 × 1P + 1–2k flop bits | — |
| Area saved | 0 | **≈ 185k µm²** (−247k, + 56k macros, + ≈ 5k glue and hold) | ≈ 184k µm² | ≈ 213k µm² | < (b) | ≈ 37k µm² (latch 30.8 vs flop 49.0 µm²; muxes stay) |
| Utilization (≈) | 50 % | **29 %** | 29 % | 26 % | > 29 % | 46 % |
| Program words | 128, 64-word windows | 128 (PoC); **256 shared** with an 8-bit pc; 512 with 2 × 512×16 (+34k µm²); or 2 × 256 private | 256 shared | 256 shared | as (b) | 128 |
| Instruction rate | 1 per clock (D50) | 1 per clock (D50, unchanged) | 1 per clock | **1 per 2 clocks** per engine | 1 per clock on a hit | 1 per clock |
| Host write | 1 refetch | engine refetches twice (2 bubbles) | one port shared with the host: as (b) | steals read slots | as (b) | 1 refetch |
| Timing | pc → 128-way mux (D45 worst path; D50 cut it) | stage 1 = macro access 5.3 ns slow + wire; no mux tree | same as (b) | as (b), plus an arbiter | cache tags in the fetch path | as (a), plus latch timing |
| TT flow risk | none (proven) | Metal4 power hookup (proven by two projects, §1.3); 2 macros | no CMOS5L precedent for 2P; one macro but 420 µm wide | as (b), 1 macro | highest | latch STA and hold in the TT flow |
| Verdict | baseline | **recommended** | same area as (b), fewer options, no precedent | breaks the SPI peripheral at 2 MHz (BUG-043) | complexity without a need | saves 1/5 of (b) |

### 3.2 (b) in detail: one single-port SRAM per engine

- **Shared memory kept by mirroring:** the host writes the same word into both macros, so
  both hold the same image. Each engine reads its own copy through its own port. To programs,
  the assembler and the host this is the shared memory of D4, unchanged.
- **Optional split later:** a "private" bit (for example `PM_ADDR` bit 8) could write only
  one macro, giving each engine 256 words of its own (512 in all), at no area cost.
- **Host writes:** a write takes the port, so that clock's read does not happen and `DOUT`
  is stale for one clock. Both engines refetch at the write (as today) and once more one
  clock later (`pm_wr_q`). The cost is one more bubble per written byte, two in all. Only an
  engine at `CLKDIV` 0 notices (it slips 2 clocks instead of 1), and only while the host is
  writing. The USB firmware's run-time patch of words 6 and 9 passes Test 11 this way.

### 3.3 How the synchronous read fits D50's prefetch

D50 reads the memory at `pc` (the word after the current instruction) and takes the word
into `instr_q` at the next edge. The macro registers its address at an edge and gives the
data after it. So the macro is given **`pc_d`, the value `pc` takes at that edge** (a new
engine output, the existing `pc_next`). After the edge, `DOUT` is the word at `pc`, exactly
what the flip-flop read gives; `instr_q` takes it at the next edge as before.

- D50's stage 1 (`pc` → multiplexers → `instr_q`) becomes the macro's access: 5.30 ns slow
  plus the wire to the engine and `instr_q`'s setup, about 7–8 ns, with no fan-out (each
  `DOUT` bit has one load per engine).
- D50's stage 2 now ends at the macro's address pins (setup −0.07 ns at slow, better than a
  flip-flop's 0.31 ns) instead of at `pc` and its three copies, which drove 1,344 mux selects.
  `pc_copy` is no longer needed (it stays in the RTL, unused in the SRAM build; synthesis
  removes it).
- No change to the engine's behaviour, instruction timing or the D50 timing rule. The only
  engine change is the new output.

### 3.4 Growing programs beyond 64 words

The 64-word window comes from the instruction format, not from the memory:

- `JMP`: `ARG[8:6]` condition, `ARG[5:0]` target; the EXT jumps (`JCRCBAD`, `JEQ`, `JNE`,
  `JLINE`): `ARG[8:6]` sub-op, `ARG[5:0]` target; the timeout vector: `LINE_CFG[5:0]`.
  **No ARG bit is free** for a 7th or 8th target bit.
- **Proposed: a page register.** EXT sub-op 7 (the only free one, D32) becomes `PAGE p`:
  taken jumps go to `START_PC + {p, target}`. Restart and the timeout set the page to 0;
  sequential code crosses pages without help because `pc` is absolute. Cost: 2 flip-flops per
  engine, an 8-bit adder instead of 7, and one instruction per far jump. The assembler gets a
  `PAGE` mnemonic and checks that each jump's target is in the page in force.
- **Also needed for 256 words:** `pc`/`pc_d`/`START_PC` 7 → 8 bits (`START_PC`'s register
  has bit 7 free), and a 9th bit for the host's byte pointer (`PM_ADDR` is `[7:0]`; register
  0x0F is free for `PM_ADDR_H`). The macro's address bit 7 is tied to 0 in the proof of
  concept.
- Alternative without an instruction: a jump stays in the current 64-word page of the program
  (`target = START_PC + {(pc − START_PC)[7:6], addr}`). Simpler, but a program cannot jump
  back to an earlier page, so loops and the timeout handler would have to sit in one page.

### 3.5 Gate-level simulation

- IHP's model `RM_IHPSG13_1P_256x16_c2_bm_bist.v` with `-DFUNCTIONAL` uses its behavioural
  core (`RM_IHPSG13_1P_core_behavioral_bm_bist.v`); without it, the timing-check branch needs
  `$setuphold` delayed signals, which Icarus does not model. The RTL tests, the TT cocotb test
  and the GL flags already define `FUNCTIONAL`.
- The macro is a black box in the routed netlist, so GL simulation needs the model file as
  an extra source: `test/Makefile` (Tiny Tapeout `gl_test`) and `pbe_v1` `make test-gl`
  (our `gl_regression`), both in `sram/flow.patch`. This is the reference projects' setup.
- The model's memory starts as X (as the flip-flops do in RTL); every test loads its program
  through the host port first.

### 3.6 Risk to the Tiny Tapeout flow

1. **Power (the main risk).** A CMOS5L block's PDN is vertical Metal4 stripes only
   (`FP_PDN_MULTILAYER` 0; TopMetal1 belongs to the chip), and the macro's supply pins are
   vertical Metal4 columns. Same-layer shapes cannot be joined by a via, so LibreLane's default
   macro grid (Metal4 → TopMetal1) is empty. The method that passed (tt_um_loom, then
   TeslaCoilerOW): choose the stripe pitch and offset so that the stripes crossing each macro
   lie inside same-net power columns, and let pdngen draw them through the macro (it cuts
   stripes at fixed macros, so a wrapper releases them while drawing). The 256×16 macro has
   the same column lattice as their 64×16 and 512×16: `VDD!`/`VDDARRAY!` at
   x = 4.26 + 11.24 k and 151.05 + 11.24 k, `VSS!` 5.62 µm to the right of each.
   - Our settings: `FP_PDN_VWIDTH` 2.1 (the template's), `FP_PDN_VSPACING` 3.52,
     `FP_PDN_VPITCH` 67.44 (6 × 11.24), `FP_PDN_VOFFSET` 25.40; macros at x = 415.68 and
     685.44 (11.04 + 67.44 k, k = 6, 10). Each macro gets 4 VPWR and 4 VGND stripes, every one
     inside a column of its net, 0.02 µm from one edge at worst (the same margin as the
     passing projects). `sram/check_sram_floorplan.py` checks this from the LEF.
   - The VPWR stripes cross the gap between `VDD!` (bottom) and `VDDARRAY!` (top) columns,
     where the LEF has an obstruction. The GDS has no Metal4, Via3 or TopMetal1 there under
     any of our stripes (`check_sram_floorplan.py --gds`, 0 shapes), so the stripe joins only
     `VDD!` to `VDDARRAY!` (both VPWR). Magic will report it as an illegal overlap;
     `ERROR_ON_ILLEGAL_OVERLAPS` is set false for that.
   - These keys sit below the template's "DO NOT CHANGE" line; both passing projects changed
     them and passed precheck.
   - 19 stripe pairs instead of 25 (pitch 67.44 instead of 50): a little more IR drop, at half
     the current utilization.
2. **Placement:** the Tiny Tapeout pins are all on the top edge (x 29–192 µm), so the macros go
   on the bottom edge, flipped (`FS`) so their pins face the core. Two macros take
   2 × 236.8 µm of the 1289 µm width and 119 µm of the 711 µm height; the stripes still reach
   both block edges, as the precheck's power-port rule needs.
3. **Hold and timing at the macro:** hold requirements of 0.6–1.4 ns at the address and data
   pins. `DIN` and `BM` come almost straight from host-port flip-flops, so the flow will add
   delay cells there: at most about 250 cells (≈ 4k µm²) on 2 × 43 pins, against the 2,048
   memory hold buffers removed. The macro's clock pin is a CTS sink.
4. **DRC/LVS:** `ERROR_ON_MAGIC_DRC` false and `MAGIC_EXT_ABSTRACT_CELLS` as in §1.4; the
   precheck's KLayout DRC (with the SRAM rules) is the real check.
5. **Run time:** about 9,000 fewer cells (21,745 → about 13,000, ties not counted) should
   shorten the 2.5–4 h `gds` run.

### 3.7 Test impact

- `make test` now also runs `test-sram`: `tb_fetch`, `tb_usb`, `tb_proto` and `tb_pbe` on the
  SRAM build (IHP's model). All pass, as do both builds' Verilator lint and the TT cocotb test
  with `sram/flow.patch` applied (2 of 2). The engine-only testbenches do not use the top level.
- Mutations of the SRAM path (BUG-074):

  | Mutation | Caught |
  |---|---|
  | One refetch only, at the write (the stale-`DOUT` hazard) | yes: `tb_fetch` (a), "byte 0 is 11, expected 33" |
  | No refetch after reset (`pm_wr_q` resets to 0) | no: every test writes the program first, which refetches |
  | Refetch only one clock after the write | no: an instruction would need to complete in the clock just after a host write; not provoked by any test |

- After a gds run: `make test-gl` on the routed netlist with the model.

## 4. Recommendation

**Option (b): two `RM_IHPSG13_1P_256x16_c2_bm_bist`, one per engine, written together.**

| | Expected |
|---|---|
| Area | −247k µm² of standard cells, + 56k µm² of macros, + ≈ 5k µm² of glue and hold: **≈ 185k µm² saved**; utilization ≈ 50 % → ≈ 29 % |
| Cells | ≈ 21.7k → ≈ 13k (not counting ties); hold buffers ≈ 3,590 → ≈ 1,800 |
| Program size | 128 words in the PoC (no other change); **256 shared** after step 5 below; 512 with the 512×16 macro (+34k µm²) or private halves |
| Timing | D45's worst path (pc → 128-way multiplexers) disappears; stage 1 ≈ 7–8 ns at slow; the next worst path should be D50's `clkdiv` → `tick` → `exec` (≈ 12.7 ns) |
| Behaviour | Unchanged except 2 bubbles per host write instead of 1 (CLKDIV 0 only) |
| Schedule risk (deadline 18 Jan 2027, about 11 weeks) | Low to medium. RTL and tests done here (1 day). The flow is the unknown: plan 2–3 `gds` runs (3–4 h each) for the PDN and DRC. The flip-flop build stays one define away, so there is always a fallback |

### Steps

1. Merge this branch's RTL (`USE_SRAM` off by default changes nothing; `make test` runs both).
2. Ask the Tiny Tapeout organisers (Discord) to confirm an IHP SRAM macro is accepted in a 6x4
   CMOS5L project on ttihp27a.
3. `git apply sram/flow.patch` (adds `pbe_pmem_sram.sv` to `info.yaml`, puts `sram/config.json`
   into `src/config.json`, and adds the macro model to `test/Makefile` and `make test-gl`).
   Run `python3 sram/check_sram_floorplan.py` and `cd pbe_v1 && make test`.
4. Run `gds` by hand (Actions → gds → Run workflow). Check: `OpenROAD.GeneratePDN` log
   (`PBESRAM … checked` for both macros, no `PBESRAM ERROR`), the grid-error reports, LVS 0,
   setup and hold at all corners, `magic__illegal_overlap__count` (expect a few per VPWR
   stripe), the precheck (KLayout DRC, pin check), `gl_test`, then `gl_regression`.
5. Grow to 256 words: 8-bit `pc`/`pc_d`/`START_PC`, `PM_ADDR_H`, the macro's address bit 7,
   the assembler's 256-word image; then the `PAGE` instruction (§3.4) when a program needs
   more than 64 words (CAN, SWD, LIN). Tests: a program that crosses a page and jumps back.
6. Update D4, D45 and D50 (mark **Changed**) when the SRAM build becomes the design.

### How to run the flow by hand

Do not let it run automatically; it is manual only (D46).

```
git checkout -b sram-flow investigate/sram
git apply sram/flow.patch
python3 sram/check_sram_floorplan.py          # stripe/column alignment from the LEF
cd pbe_v1 && make test && cd ..              # both builds
git commit -am "Try the SRAM program memory in the flow" && git push -u origin sram-flow
# GitHub: Actions → gds → Run workflow → branch sram-flow
```

## 5. Sources

- IHP-Open-PDK, `dev` branch: `ihp-sg13cmos5l/libs.ref/sg13cmos5l_sram` (symlink) and
  `ihp-sg13g2/libs.ref/sg13g2_sram/{lef,lib,gds,verilog,doc}`;
  `ihp-sg13cmos5l/libs.tech/librelane/config.tcl` (PDN layers). <https://github.com/IHP-GmbH/IHP-Open-PDK/tree/dev>
- LibreLane 3.1.0.dev4 (PyPI), `librelane/pdk_hashes.yaml` and
  `scripts/openroad/common/pdn_cfg.tcl`, `scripts/openroad/pdn.tcl`.
- TinyTapeout/tt-gds-action, branch `ttihp27a`: `action.yml` (LibreLane version for CMOS5L),
  `precheck/action.yml` (PDK commit). <https://github.com/TinyTapeout/tt-gds-action/tree/ttihp27a>
- TinyTapeout/tt-support-tools `main` (02abf73): `tech.py` (`IHPCmos5lTech`),
  `tech/ihp-sg13cmos5l/tile_sizes.yaml`, `tech/ihp-sg13cmos5l/def/tt_block_6x4_pgvdd.def`,
  `precheck/tech_data.py`; PR #187 (SRAM and DigiBnd layers on CMOS5L).
  <https://github.com/TinyTapeout/tt-support-tools>, <https://github.com/TinyTapeout/tt-support-tools/pull/187>
- Our gds run 40780097577, artifact `tt_submission` (`stats/metrics.csv`, routed netlist,
  `pdk.json`). <https://github.com/ayushyadavnvs/jane_street/actions/runs/40780097577>
- TeslaCoilerOW/ttihp-protocol-emulator: README, `src/config.json`, `src/sram_pdn_cfg.tcl`,
  `docs/notes/hardening.md`, `docs/notes/6x4.md`, `test/Makefile`.
- thomasgilbert481/tt_um_loom: `src/config.json`, `src/pdn_cfg.tcl`.
- Sashwath-s/ttihp-pinwheel: `src/config.json`, `src/pdn_cfg.tcl`, `macro/…/README.md`.
- Jane Street, Protocol emulator ASIC competition. <https://blog.janestreet.com/protocol-emulator-asic-competition/>
- This repository: `src/tt_um_pbe.sv`, `src/pbe_engine.sv`, D4, D32, D45, D46, D50, BUG-043.
