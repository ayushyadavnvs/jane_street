# SRAM program memory: the flow change set (D62, a proposal)

Nothing in this folder is used by the default build or by the `gds` workflow until
`flow.patch` is applied. The findings are in `docs/SRAM_INVESTIGATION.md`.

| File | What it is |
|---|---|
| `flow.patch` | The change set: `info.yaml` (adds `pbe_pmem_sram.sv`), `src/config.json` (becomes `config.json` below), `test/Makefile` (the macro model for the cocotb RTL and `gl_test` runs, `USE_SRAM`), `pbe_v1/Makefile` (the model in `make test-gl`) |
| `config.json` | The proposed `src/config.json`: today's file plus `VERILOG_DEFINES`, `MACROS` (two `RM_IHPSG13_1P_256x16_c2_bm_bist`, bottom edge, `FS`), `PDN_MACRO_CONNECTIONS`, `PDN_CFG`, the Magic keys and the stripe lattice (`FP_PDN_VPITCH` 67.44, `VSPACING` 3.52, `VOFFSET` 25.40, `VWIDTH` 2.1) |
| `pdn_cfg.tcl` | LibreLane 3.1.0.dev4's PDN script without its macro grid; draws the Metal4 stripes through the macros and checks that each lies on a supply column of its own net |
| `check_sram_floorplan.py` | Checks `config.json` against the macro LEF without EDA tools; `--gds` (needs `gdstk`) also checks the GDS under the stripes |
| `tools/pmem_cost.py` | Measures the flip-flop memory's cost in a routed netlist (`tt_submission`) |
| `tools/sram_lib_timing.py` | Summarises a macro's Liberty timing |

The macro's views are in `macros/RM_IHPSG13_1P_256x16_c2_bm_bist/` (see its README).

## Trying it in the flow (by hand)

The `gds` workflow is manual only (D46). On a branch of its own:

```
git checkout -b sram-flow investigate/sram
git apply sram/flow.patch
python3 sram/check_sram_floorplan.py      # must print OK
cd pbe_v1 && make test && cd ..          # flip-flop and SRAM builds
git commit -am "Try the SRAM program memory in the flow"
git push -u origin sram-flow
```

Then GitHub, Actions, `gds`, Run workflow, branch `sram-flow`. In the results check:

- `*-openroad-generatepdn` log: `PBESRAM u_pmem.g_mem[0].u_sram: checked` and `[1]`, no
  `PBESRAM ERROR`; the `VPWR`/`VGND` grid-error reports empty;
- LVS clean, setup and hold met at all three corners, the macro's pins in the hold report;
- `magic__illegal_overlap__count`: a few per VPWR stripe over a macro is expected (they cross
  the macro's VDD!/VDDARRAY! split over a LEF obstruction with no metal in the GDS);
- the precheck job (KLayout DRC with the SRAM rules, the power-port pin check) and `gl_test`;
- then `gl_regression` (`make test-gl` with the macro model).

## Moving the macros

Only to x = 11.04 + 67.44 k (k an integer), orientation `N` or `FS`, and not closer than 20 µm
to each other: there the stripe lattice lands on their power columns. Re-run
`check_sram_floorplan.py` after any change of a location or an `FP_PDN_*` key. A new instance
name must match the flattened RTL path (`make synth-sram` prints them).

## Sources of the method

TeslaCoilerOW/ttihp-protocol-emulator (`src/sram_pdn_cfg.tcl`, `docs/notes/hardening.md`) and
thomasgilbert481/tt_um_loom (`src/pdn_cfg.tcl`), both Apache-2.0, which passed the Tiny Tapeout
CMOS5L `gds`, `precheck` and `gl_test` jobs with IHP 1P macros of the same power-column
lattice. `pdn_cfg.tcl` here is our own, from LibreLane's default script.
