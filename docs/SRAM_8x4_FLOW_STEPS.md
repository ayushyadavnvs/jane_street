# The SRAM program memory on an 8x4 tile: the flow steps

A guide for the part of D82 that is physical design: making the Tiny Tapeout flow (LibreLane,
run by the `gds` workflow) place the two IHP SRAM macros, power them, and harden the design on
8x4 tiles. The RTL and the tests are already done on this branch (`feature/sram-8x4`); this file
explains what is left, step by step, and **why** each step is needed.

Everything here follows Tiny Tapeout's working example,
[`TinyTapeout/ttihp-cmos5l-sram-example`](https://github.com/TinyTapeout/ttihp-cmos5l-sram-example)
(checked at commit `15ac9bc`, 5 Nov 2026; it uses the same `tt-gds-action@ttihp27a` as our `gds`
workflow). Its README, section "Using this in your own design", is the source of steps 1-5; read
it next to this file. Where this file says "the example", it means that repository.

Contents: [0. Background](#0-background-what-the-flow-must-do-that-it-did-not-before) ·
[1. Copy the files](#1-copy-the-example-files) · [2. info.yaml](#2-infoyaml) ·
[3. src/config.json](#3-srcconfigjson) · [4. Placement](#4-placement-where-the-two-macros-go) ·
[5. Run](#5-run-the-gds-workflow-on-this-branch) · [6. Check](#6-what-to-check-afterwards) ·
[7. Failure modes](#7-expected-failure-modes-and-what-they-mean) · [8. Fallback](#8-if-it-cannot-be-made-to-work)

---

## 0. Background: what the flow must do that it did not before

Until now the whole design was **standard cells**: small gates that the flow places in rows and
wires up itself. An SRAM macro is different: a pre-drawn block (236.8 × 118.78 µm, about the size
of a whole Tiny Tapeout tile), designed by IHP, that the flow must treat as a fixed object. Three
things follow:

1. **The flow must know the macro exists and where its files are** (layout `.gds`, abstract
   `.lef`, timing `.lib`). That is the `MACROS` key in `src/config.json`.
2. **Something must decide where it goes.** The placer moves standard cells, but a macro of this
   size is placed by hand (`location`, `orientation`).
3. **It must get power.** Standard cells get power from rails along their rows. The macro has its
   own supply pins (`VDD!`, `VDDARRAY!`, `VSS!`) that must be wired to the chip's `VPWR` and
   `VGND`. On SG13CMOS5L this is the hard part:
   - Tiny Tapeout's tile power grid is a single layer of **vertical Metal4 stripes** (TopMetal1
     is reserved for the chip-level grid).
   - The macro's supply pins are **also vertical Metal4 columns** (11.24 µm apart).
   - Two shapes on the same layer only connect if they overlap: there is no via between Metal4
     and Metal4. So a stripe must run **exactly over** a column.
   - OpenROAD's power-grid generator (pdngen) **cuts its stripes around macros**, so on its own
     it would leave the macro unpowered.

   The example solves this with a flow step of its own, `Project.ExtendPowerStripes`
   (`librelane_plugin_sram_pdn.py` + `odb_stripes.py`, adapted from Ken Pettit's
   [ihp-um-janestreet-prism](https://github.com/kdp1965/ihp-um-janestreet-prism)). It runs right
   after pdngen, moves the stripes that cross the macro onto its power columns, completes the
   VPWR/VGND pairs and runs them over the full height of the core.

   Our old attempt (`sram/flow.patch`, D62) only chose a stripe pitch that lands on the columns
   and had no such step; the macros could have been left unpowered (BUG-110). That is why it was
   deleted, and why this guide follows the example instead.

What the RTL side has already done for you (D82):

| Item | Where |
|---|---|
| The wrapper with two macro instances, `u_pmem.u_sram0` (engine 0) and `u_pmem.u_sram1` (engine 1) | `src/pbe_pmem_sram.sv` |
| `A_DLY` tied to 1, BIST port tied off (checked against the datasheet and the example's `src/project.v`) | `src/pbe_pmem_sram.sv` |
| The black box for synthesis and lint | `src/sram_bb.v` (the example's file) |
| The cocotb test (and so `gl_test`) simulates IHP's model | `test/Makefile` (`SRAM_MODEL`, `-DFUNCTIONAL -DSIM`) |
| `make test-gl` (the `gl_regression` workflow) has the model | `pbe_v1/Makefile` (`GL_SRC`) |

The instance names are the ones Yosys gives after flattening the hierarchy:
`tt_um_ayushyadavnvs_pbe` → `u_pmem` (the wrapper) → `u_sram0` / `u_sram1`, written with dots:
**`u_pmem.u_sram0`** and **`u_pmem.u_sram1`**. `cd pbe_v1 && make synth` prints them at the end,
so you can check them after any RTL change. (They are written out in the wrapper, not made by a
`for` loop, so that the names have no `[0]` brackets to escape in JSON.)

## 1. Copy the example files

From the example repository, copy:

| From the example | To our repository | What it is |
|---|---|---|
| `librelane_plugin_sram_pdn.py` | repository root | defines the `Project.ExtendPowerStripes` step |
| `odb_stripes.py` | repository root | the OpenDB script that step runs |
| `src/pdn_cfg.tcl` | `src/pdn_cfg.tcl` | LibreLane's power-grid script without its per-macro grid |
| `src/sram_bb.v` | `src/sram_bb.v` | **already done** (D82), keep ours |

**Why the root?** LibreLane loads any `librelane_plugin_*.py` file from the directory it runs in,
which is the repository root in the `gds` workflow. In `src/` it would not be found, and the flow
would stop with an unknown step.

**Why `pdn_cfg.tcl`?** The default script also builds a power grid *inside* each macro. On this
tile that grid has nothing to attach to (same-layer problem above), and OpenROAD fails with
`PDN-0232` / `PDN-0233`. The example's copy leaves the macro grid out, and the new step does the
connection instead.

**Licence.** All three files are Apache-2.0, like our repository. Keep their headers exactly as
they are (they name Tiny Tapeout B.V., Ken Pettit's project and the LibreLane/OpenLane
contributors). Add a credit line to the root `README.md`, for example:

> The SRAM power step (`librelane_plugin_sram_pdn.py`, `odb_stripes.py`), `src/pdn_cfg.tcl` and
> `src/sram_bb.v` come from Tiny Tapeout's `ttihp-cmos5l-sram-example` (Apache-2.0), adapted
> from Ken Pettit's `ihp-um-janestreet-prism`.

## 2. `info.yaml`

Two changes:

```yaml
  tiles: "8x4"          # was "6x4"
  ...
  source_files:
    - "pbe_fifo.sv"
    - "pbe_host_spi.sv"
    - "pbe_crc.sv"
    - "pbe_line.sv"
    - "pbe_bsync.sv"
    - "pbe_engine.sv"
    - "pbe_pmem_sram.sv"   # new: the wrapper with the two macros
    - "tt_um_pbe.sv"
    - "sram_bb.v"          # new: the macro as a black box, last
```

**Why `8x4`?** The tiles set the die size: 8x4 is **1724.16 × 710.64 µm**
(Tiny Tapeout's `tt-support-tools`, `tech/ihp-sg13cmos5l/tile_sizes.yaml`). Two macros stacked
take a 237 µm × 285 µm corner; the logic (about 199,000 µm² of standard cells, `make synth`) has
the rest. Jane Street and Tiny Tapeout have confirmed 8x4 for us.

**Why `sram_bb.v`?** Yosys (in LibreLane) needs to know the macro's ports, or it stops with
"module not found". `sram_bb.v` declares the module with ports and no contents, marked
`(* blackbox *)`; the layout comes from `MACROS` (step 3). Put it **last**: it starts with
`` `default_nettype none ``, which then applies to the files after it. (The cocotb test defines
`SIM`, which skips the box so that IHP's model is used instead.)

**Do not** list the IHP model files (`macros/.../*.v`) in `info.yaml`: they are simulation only.
`test/Makefile`'s `PROJECT_SOURCES` already has the same list as above.

## 3. `src/config.json`

Our `src/config.json` is Tiny Tapeout's default with our clock. Copy the example's
**"IHP SRAM macro" section** (from `"meta"` down to `ERROR_ON_ILLEGAL_OVERLAPS`) and put it after
`"CLOCK_PORT": "clk",`, just before the `"Configuration docs"` comment, as in the example. Then
change it for **two** instances with **our** names. The result should be:

```json
  "//": "======== IHP SRAM macros (RM_IHPSG13_1P_256x16_c2_bm_bist), one per engine (D82) ========",

  "//": "Insert the Project.ExtendPowerStripes step (librelane_plugin_sram_pdn.py) after the PDN generator.",
  "meta": {
    "flow": "Classic",
    "substituting_steps": { "+OpenROAD.GeneratePDN": "Project.ExtendPowerStripes" }
  },

  "//": "Both at x = 3.36 (stacked macros must share x); u_sram0 at the bottom flipped (FS),",
  "//": "u_sram1 above it upright (N): their pin edges face each other across a routing gap.",
  "MACROS": {
    "RM_IHPSG13_1P_256x16_c2_bm_bist": {
      "instances": {
        "u_pmem.u_sram0": { "location": [3.36, 3.78],   "orientation": "FS" },
        "u_pmem.u_sram1": { "location": [3.36, 170.10], "orientation": "N" }
      },
      "gds": ["pdk_dir::libs.ref/sg13cmos5l_sram/gds/RM_IHPSG13_1P_256x16_c2_bm_bist.gds"],
      "lef": ["pdk_dir::libs.ref/sg13cmos5l_sram/lef/RM_IHPSG13_1P_256x16_c2_bm_bist.lef"],
      "lib": {
        "*_typ_*": ["pdk_dir::libs.ref/sg13cmos5l_sram/lib/RM_IHPSG13_1P_256x16_c2_bm_bist_typ_1p20V_25C.lib"],
        "*_fast_*": ["pdk_dir::libs.ref/sg13cmos5l_sram/lib/RM_IHPSG13_1P_256x16_c2_bm_bist_fast_1p32V_m55C.lib"],
        "*_slow_*": ["pdk_dir::libs.ref/sg13cmos5l_sram/lib/RM_IHPSG13_1P_256x16_c2_bm_bist_slow_1p08V_125C.lib"]
      }
    }
  },

  "//": "Each SRAM has two supply rails (VDD!, VDDARRAY!) and one ground rail (VSS!).",
  "PDN_MACRO_CONNECTIONS": [
    "u_pmem.u_sram0 VPWR VGND VDD! VSS!",
    "u_pmem.u_sram0 VPWR VGND VDDARRAY! VSS!",
    "u_pmem.u_sram1 VPWR VGND VDD! VSS!",
    "u_pmem.u_sram1 VPWR VGND VDDARRAY! VSS!"
  ],

  "PDN_CFG": "dir::pdn_cfg.tcl",
  "EXTEND_STRIPES_SRAM_ARRAY_EVERY_OTHER": true,
  "ERROR_ON_PDN_VIOLATIONS": 0,
  "RUN_MAGIC_DRC": 0,
  "ERROR_ON_ILLEGAL_OVERLAPS": 0,
```

And **below** the "DO NOT CHANGE" line, replace `"FP_PDN_VPITCH": 50.0,` and keep the width,
adding spacing and offset, exactly as the example does:

```json
  "FP_PDN_VPITCH": 44.96,
  "FP_PDN_VWIDTH": 2.1,
  "FP_PDN_VSPACING": 3.52,
  "FP_PDN_VOFFSET": 6.15,
```

What each key does, and why:

| Key | Why |
|---|---|
| `meta.substituting_steps` | `"+OpenROAD.GeneratePDN"` means "insert after GeneratePDN": the new step runs right after pdngen, on its stripes, before placement. `"flow": "Classic"` keeps the rest of the standard flow. |
| `MACROS` | Declares the macro type once, with its views from the PDK (`pdk_dir::` is the installed PDK; `sg13cmos5l_sram` links to the SG13G2 SRAM library, the same files as our `macros/` folder), and each **instance** by its flattened name with a fixed location (lower-left corner, µm) and orientation. The `lib` entries give the timing per corner, so STA can time paths to and from the macro. |
| `PDN_MACRO_CONNECTIONS` | Tells the flow which macro pins are power: "instance, chip power net, chip ground net, macro power pin, macro ground pin". Each macro has **two** supply pins, so **two lines per instance**, four in all. Missing the `VDDARRAY!` line would leave the bit cells unpowered (LVS would catch it). |
| `PDN_CFG` | Our copy of the example's `pdn_cfg.tcl` (step 1); `dir::` means relative to `src/`. |
| `EXTEND_STRIPES_SRAM_ARRAY_EVERY_OTHER` | Adds a VPWR/VGND pair on every other column pair over the bit-cell arrays: more metal into the memory, less IR drop. The example used it (11 + 11 stripes per macro). |
| `ERROR_ON_PDN_VIOLATIONS` 0 | pdngen checks the macro's connections **before** the new step makes them, so it reports errors that are expected at that point. |
| `RUN_MAGIC_DRC` 0 | Magic reports many false errors inside IHP's macros; the Tiny Tapeout precheck runs the full KLayout DRC on the final GDS instead, and that one must pass. |
| `ERROR_ON_ILLEGAL_OVERLAPS` 0 | Magic sees the macro only through its LEF abstract, where Metal4 is an obstruction; the stripes over it look like overlaps although the real GDS has no metal there. |
| `FP_PDN_VPITCH` 44.96 | 4 × 11.24 µm, the macro's power-column pitch: every stripe of the tile grid can land on a column. |
| `FP_PDN_VWIDTH` 2.1 | Must fit inside the 2.81 µm-wide columns. |
| `FP_PDN_VSPACING` 3.52 | 2.1 + 3.52 = 5.62 µm from a VPWR stripe to its VGND stripe, the macro's own VDD-to-VSS distance. |
| `FP_PDN_VOFFSET` 6.15 | Puts the first VPWR stripe at 2.88 + 6.15 = 9.03 µm from the die edge (2.88 µm is the core's left edge on every tile size: 6 sites of 0.48 µm, `LEFT_MARGIN_MULT` 6). With the macro at x = 3.36, that is over its left bit-cell array's first column. |

Do not add `VERILOG_DEFINES`: the SRAM is the default build now (`USE_SRAM` is gone, D82).

## 4. Placement: where the two macros go

```
 y (µm)
 710.64 ┬──────────────────────────────────────────────────────────── die top (8x4)
        │
 288.88 ┤ ┌────────────────────┐
        │ │ u_pmem.u_sram1  N  │   upright: pins on its bottom edge, facing down
        │ │ 236.8 × 118.78     │
 170.10 ┤ └──────pins──────────┘
        │       routing gap 47.54 µm (12.6 rows): pins of both macros, tie cells,       standard
        │       the nets out to the logic on the right                                    cells
 122.56 ┤ ┌──────pins──────────┐                                                          (engines,
        │ │ u_pmem.u_sram0  FS │   flipped about x: pins on its top edge, facing up       FIFOs, ...)
        │ │ 236.8 × 118.78     │
   3.78 ┤ └────────────────────┘
      0 ┴─┬────────────────────┬──────────────────────────────────────────── 1724.16
         3.36               240.16                                         x (µm)
```

| Instance | Location (x, y) | Orientation | Occupies x | Occupies y |
|---|---|---|---|---|
| `u_pmem.u_sram0` (engine 0) | (3.36, 3.78) | `FS` | 3.36 - 240.16 | 3.78 - 122.56 |
| `u_pmem.u_sram1` (engine 1) | (3.36, 170.10) | `N` | 3.36 - 240.16 | 170.10 - 288.88 |

How these numbers come about:

- **x = 3.36 for both.** The example's README (item 4) recommends x = 3.36 + n × 11.24: there the
  stripe lattice (step 3) falls on the left bit-cell array's power columns, and the step moves
  nothing. Item 5: macros **stacked** above each other **must have the same x**, because each
  stripe runs the full height of the tile and crosses both; a different x would put the other
  macro off its columns. 3.36 (n = 0) is the leftmost: the corner keeps the rest of the die in
  one free rectangle for the logic.
- **Orientation `FS` below, `N` above.** The macro's signal pins are all on one edge (its bottom
  edge in the LEF, on Metal2). `N` keeps them at the bottom; `FS` flips the macro about the
  horizontal axis, so they come to the top. With the lower one `FS` and the upper one `N`, both
  pin edges face the gap between them: short wires, and the logic reaches both from the same
  channel. The step supports only these two orientations (it checks and stops otherwise).
- **y on row boundaries.** Standard-cell rows are 3.78 µm tall and start at y = 3.78
  (`BOTTOM_MARGIN_MULT` 1). A macro edge on a row boundary (y = n × 3.78) leaves no unusable
  slivers of rows. 3.78 = 1 × 3.78 (the first row, as in the example); the lower macro's top is
  3.78 + 118.78 = 122.56 (not on a boundary, which is fine for the top edge).
- **The gap: 170.10 = 45 × 3.78**, so the upper macro starts 47.54 µm above the lower one.
  - Each macro has about 59 signal pins in use (8 address, 16 data in, 16 write mask, 16 data
    out, CLK, WEN, REN), and about 50 more tied to constants (BIST port, `A_DLY`, `A_MEN`), which
    need tie cells close to the pins. All of that leaves through the gap.
  - With a routing pitch of about 0.5 µm, a 47 µm gap has ~90 tracks on each horizontal
    routing layer: room for both macros' ~120 signal nets, with space left for the placer to put
    the tie cells and buffers there too. (The Metal4 stripes take some of the vertical tracks.)
  - The step's default `EXTEND_STRIPES_PIN_FACE_MARGIN` (3 µm) keeps its via stacks away from
    the pin edges, so they do not block the pins.
  - A smaller gap (154.98 = 41 × 3.78, 32.4 µm) is possible if the floorplan gets tight; a
    larger one costs nothing much on an 8x4 die. If global routing reports congestion around
    the macros (§7), move the upper macro up by a few rows (keep y = n × 3.78).
- **Space for the logic.** The macros take 237 × 285 µm in the lower-left corner; the die is
  1724 × 711 µm. The standard cells (about 199,000 µm² from `make synth`, plus buffers) have
  ~1.13 mm², about 18 % filled at the start. `PL_TARGET_DENSITY_PCT` 60 can stay.

## 5. Run the gds workflow on this branch

1. Commit the changes of steps 1-3 on `feature/sram-8x4` and push.
2. Before pushing, run the quick local checks (they do not need LibreLane):
   - `cd pbe_v1 && make test` (the full regression must pass);
   - `cd test && make` (the cocotb test with IHP's model; check `results.xml` has no failures);
   - `cd pbe_v1 && make synth` (prints `u_pmem.u_sram0` and `u_pmem.u_sram1`: the names in
     `MACROS` must match exactly).
3. On GitHub: **Actions** → **gds** (left column) → **Run workflow** (right) → **Use workflow
   from: Branch `feature/sram-8x4`** → **Run workflow**. The workflow is manual only (D46).
4. It takes 2.5-4 hours. The jobs: `gds` (LibreLane), then `precheck`, `gl_test` and `viewer`.
5. When it is done, open the run: the job summary of `gds` shows the flow's metrics; the
   artifact (`tt_submission` and the `runs/wokwi/` step directories) holds the logs and reports
   named below. Download it.
6. If `gds`, `precheck` and `gl_test` pass, run **gl_regression** the same way (Actions →
   gl_regression → branch): it runs our full testbenches (`make test-gl`) on the routed netlist,
   with IHP's model for the macros.

## 6. What to check afterwards

A green workflow is necessary but not enough: some problems (an unpowered macro, a slow path)
only show in the reports. Check each of these:

1. **Precheck passes** (the `precheck` job): KLayout DRC with the SRAM rules, the power-port pin
   check (every power port must run the full height; the step tidies the stripes for this), the
   tile size and pins.
2. **Both macros got stripes.** Open the `*-project-extendpowerstripes` step log
   (`runs/wokwi/NN-project-extendpowerstripes/`). It must have `[INFO]` lines **for both
   `u_pmem.u_sram0` and `u_pmem.u_sram1`**, such as
   `u_pmem.u_sram0: VPWR: N tile stripes replaced by M on the macro's tracks`, the
   `array-every-other` pairs and `pairs` per region, and the `via stacks ... down to the SRAM`
   counts. One macro missing means it has no power. `[WARNING] ... moved ... onto a column` is
   harmless (the stripe was not on the lattice); `[WARNING] no free VPWR column` or `has no pin`
   is not.
3. **LVS matches** (the `*-netgen-lvs` step, and the flow's summary: `lvs__errors` 0). LVS
   compares the layout with the netlist, including the macros' supply pins: an unconnected
   `VDDARRAY!` shows here.
4. **IR drop: all shapes connected.** `runs/wokwi/*-openroad-irdropreport/irdrop.rpt` must say
   that all shapes on VPWR and VGND are connected (no floating shapes), and the worst drop should
   be small (tens of mV at most at 1.2 V).
5. **Timing at every corner** (`runs/wokwi/*-openroad-stapostpnr/`, `summary.rpt` and the
   per-corner reports): setup and hold met at all corners, no max-slew/cap violations. Look at
   the **slow corner (1.08 V, 125 °C) setup at 48 MHz (20.833 ns)** in particular. Paths to watch:
   - into the macros' `A_ADDR` pins: they come from the engine's `pc_next`, combinational on
     purpose (D82), not from a flip-flop. Our estimate is 3.6 ns of logic, and the macro's
     address setup is negative (about -0.6 ns), so there should be a lot of slack;
   - out of `A_DOUT` (the macro's clock-to-output is 5.06 ns at the slow corner) into the
     engines' instruction registers: short logic after it;
   - hold at the macros' inputs (the `.lib` asks for up to ~0.85 ns of hold at the slow corner):
     the resizer adds hold buffers, which is fine.
   The first routed run of the old design had only 0.586 ns of setup slack (D50); with the read
   multiplexers gone it should be much better.
6. **Utilization** (the job summary, or `*-openroad-*` reports): around 20-30 % of the 8x4 core.
   Much higher means something unexpected was synthesized.
7. **`gl_test` passes** (the cocotb test on the routed netlist, with IHP's model): it loads both
   engines' memories, checks `PM_ADDR_H` and an 8-bit `START_PC`, and runs UART TX → RX.
8. Then `gl_regression` (`make test-gl`).

Record the numbers (slack per corner, utilization, stripe counts) in `docs/DESIGN_DECISIONS.md`
(a new entry, or under D82) and anything that went wrong in `docs/BUG_LOG.md`, as CLAUDE.md asks.

## 7. Expected failure modes, and what they mean

| What you see | What it means | What to do |
|---|---|---|
| The flow stops at the start: unknown step `Project.ExtendPowerStripes` | The plugin was not loaded | `librelane_plugin_sram_pdn.py` and `odb_stripes.py` must be at the repository **root**, with those exact names |
| Linter / Yosys: module `RM_IHPSG13_1P_256x16_c2_bm_bist` not found | The black box is missing | Add `sram_bb.v` to `info.yaml`'s `source_files` |
| Errors about `default_nettype` / implicit nets in our files | `sram_bb.v` is not last | Put it at the end of `source_files` |
| `MACROS`: instance `u_pmem...` not found, or the macros appear at a random place | Name mismatch | Copy the names from `make synth`'s output; they are case and dot sensitive |
| `PDN-0232` / `PDN-0233` | The default PDN script tried to build a grid in the macro | `PDN_CFG` must point at our copy: `dir::pdn_cfg.tcl`, the file in `src/` |
| The step stops: "only R0 (N) and MX (FS) are supported" | Wrong orientation | Use `N` or `FS` only |
| `[WARNING] ... no free VPWR/VGND column`, or LVS shows `VDD!`/`VDDARRAY!`/`VSS!` unconnected | A macro is not (fully) powered | Check x = 3.36 for both, the four `PDN_MACRO_CONNECTIONS` lines and the four `FP_PDN_*` values |
| Placement errors: macro overlaps, outside the core, off the row grid | Location wrong | Keep y = n × 3.78, x = 3.36, the upper top (288.88) well inside 710.64 |
| Global routing congestion (`GRT` overflow) near the macros | The gap is too narrow for the pins | Move `u_sram1` up by a few rows (e.g. 177.66 = 47 × 3.78) |
| Magic DRC errors in the SRAM, `magic__illegal_overlap__count` > 0 | Expected (abstract vs GDS) | Fine with the two keys set to 0; the precheck's KLayout DRC is what counts |
| Precheck: a power port that does not run the full height | The step's tidy did not merge a stripe | Look for `partial-height` warnings in the step log |
| Precheck KLayout DRC errors near the macros | Real spacing problem (stripe to pin, via in the pin band) | Read the marker positions; `EXTEND_STRIPES_PIN_FACE_MARGIN` and `EXTEND_STRIPES_CLEARANCE` (step variables) control the distances |
| IR-drop report lists unconnected shapes | A stripe stopped short of the macro or a via stack is missing | The step log tells which macro and net; usually a placement or name mismatch |
| STA setup violation at the slow corner on a path to `u_pmem.u_sram*/A_ADDR` | `pc_next` is slow after routing | Report the path; the remedies are in D82 (registering the address costs a clock per fetch) — talk it over before changing RTL |
| STA hold violations at macro inputs | Clock skew to the macros | Usually fixed by the resizer; if not, raise `PL_RESIZER_HOLD_SLACK_MARGIN` / `GRT_RESIZER_HOLD_SLACK_MARGIN` a little |
| `gl_test`: module `RM_IHPSG13...` not found | The model is missing in the gate-level run | `test/Makefile` must still add `SRAM_MODEL` for both RTL and GL (it does now) |
| `gl_test`: "A_DLY must be tied to 1" and `$stop` | The model's own check failed | Should not happen (it is tied in the wrapper); means the netlist lost the tie |

## 8. If it cannot be made to work

The flip-flop program memory stays in the RTL behind `PBE_PMEM_FF` (64 words per engine, the same
registers and programs; D82). It is the insurance for the deadline: with `"VERILOG_DEFINES":
["PBE_PMEM_FF"]` in `src/config.json`, without the SRAM section and the `FP_PDN_*` changes,
without `pbe_pmem_sram.sv` and `sram_bb.v` in `info.yaml` and `test/Makefile`'s
`PROJECT_SOURCES`, and with `-DPBE_PMEM_FF` in `test/Makefile`'s `COMPILE_ARGS`, the memory is
flip-flops again: the same number of them (2 × 64 × 16) as the shared 128-word memory that has
passed the flow on 6x4 (D45, D50). `make synth FF=1` gives its area (366,093 µm²), and
`make test-ff` its tests. Programs must then sit below word 64 of each engine's memory.
