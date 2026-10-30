# Independent verification

Checks of the PBE that are not the design's own testbenches (D63, D64 in
`docs/DESIGN_DECISIONS.md`). The design and its SystemVerilog benches are in `pbe_v1/`. Run every
target from `pbe_v1/`; the targets are in `pbe_v1/Makefile` and point here. Generated files go
to the ignored `pbe_v1/build/`.

| Directory | What it is | Make target (in `pbe_v1/`) |
|---|---|---|
| `golden-model/` | Python model, random differential, sigrok decoding, third-party bus models; all reports and recorded evidence (both rounds) | `make test-model`, `make diff`, `make sigrok`, `make test-buses` (see its README) |
| `formal/` | SymbiYosys properties of the FIFO, host SPI, line coder and engine, with a source-aware runner | `make formal [FORMAL_BLOCK=fifo\|host\|line\|engine]` |
| `vectors/crc/` | CRC unit against the RevEng catalogue and crccheck | `make test-crc-vectors` |
| `vectors/protocols/` | USB (LUNA, usb-protocol) and Modbus (PyModbus) packets through the chip's pins | `make test-protocol-vectors` |
| `coverage/` | Verilator line/toggle/branch/expression coverage and named functional bins | `make coverage`, `make test-coverage-tools` |
| `stress/` | Pin-level clock error, jitter, glitches, host backlog and concurrent protocols | `make stress`, `make stress-characterize`, `make stress-strict` |
| `mutation/` | 24 single-site RTL faults on scratch copies; each runs `make test` and `make diff` | `make mutate` |
| `spec_boundaries/` | Keeps the counterexamples to the old, stronger program-window and write-cancellation text (BUG-058/059) | part of `make test` |

Results: `golden-model/REPORT.md`. Python requirements: `golden-model/differential/`,
`golden-model/bus_models/`, `vectors/crc/` and `vectors/protocols/` each have a
`requirements.txt`; formal and coverage need the OSS CAD Suite (Yosys, SBY, Yices, Verilator).
