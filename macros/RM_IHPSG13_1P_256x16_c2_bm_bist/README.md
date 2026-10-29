# RM_IHPSG13_1P_256x16_c2_bm_bist

IHP's 256 x 16 single-port SRAM, the proposed program memory (D55; one per engine). Used only
with `USE_SRAM` (`make test-sram`, `make synth-sram`, `sram/flow.patch`).

**Source:** [IHP-Open-PDK](https://github.com/IHP-GmbH/IHP-Open-PDK)
`ihp-sg13g2/libs.ref/sg13g2_sram/` (`ihp-sg13cmos5l/libs.ref/sg13cmos5l_sram` is a symlink to
it), commit `89d42ee6d2fd9b50b86a1aada6fee6673c3e6008`: the PDK that LibreLane 3.1.0.dev4 (our
`tt-gds-action@ttihp27a`) installs. The files are unmodified and identical on `dev`
(`7b41fd1`, 2026-10-28). Copyright IHP PDK Authors, Apache-2.0 (`LICENSE.IHP-Open-PDK`).

| File | SHA-256 | Use |
|---|---|---|
| `RM_IHPSG13_1P_256x16_c2_bm_bist.gds` | `763ddd53d812e0400c2cb89af192a0000d7b3f27e049de93aef41a2be9b547c6` | layout |
| `RM_IHPSG13_1P_256x16_c2_bm_bist.lef` | `bea0d602296a03ea2020420501767ff321f53186d7444ea0faefa4d49dac047b` | abstract: 236.8 x 118.78 um, signal pins Metal2 on the bottom edge, supply pins Metal4 columns |
| `RM_IHPSG13_1P_256x16_c2_bm_bist.cdl` | `f7918bfd22caa5b317bd2222adbdf700588e93c9c55a131a753fa6227abb2c53` | LVS netlist |
| `..._typ_1p20V_25C.lib` | `6f4cca1ed508f879a35bdc15a9de2d027f81ec0eeec0d6c8ab27d05f5edad445` | timing |
| `..._slow_1p08V_125C.lib` | `a04cff61cb4befb2290427db1ff2cb1c31c8d5990dca53ee3e5d1cc621679cd9` | timing |
| `..._fast_1p32V_m55C.lib` | `c28bb80737d7a7daea14b9d259380c7e1dfc27c71c3ad1223a5387d8515ebe4b` | timing (stands in for the −40 °C corner) |
| `RM_IHPSG13_1P_256x16_c2_bm_bist.v` | `645c475787b077da4dbd15856c68bbae46aa9846a155239eb895ed2de7511053` | simulation model; compile with `FUNCTIONAL` |
| `RM_IHPSG13_1P_core_behavioral_bm_bist.v` | `d0a6258f8e9c93d1d5b1f78c0a1d66f30d28b1ad8037e5e07f53d1a4e3670b12` | its behavioural core |
| `RM_IHPSG13_1P_256x16_c2_bm_bist.txt` | — | IHP's datasheet |

`RM_IHPSG13_1P_256x16_c2_bm_bist_bb.v` is ours: the interface as a black box, for synthesis,
lint and the flow's `nl` view. Never list the model files in `info.yaml`.
