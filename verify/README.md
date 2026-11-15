# Independent verification

Checks of the PBE that are not the design's own testbenches (D63, D64 in
`docs/DESIGN_DECISIONS.md`). The design and its SystemVerilog benches are in `pbe_v1/`. Run every
target from `pbe_v1/`; the targets are in `pbe_v1/Makefile` and point here. Generated files go
to the ignored `pbe_v1/build/`.

| Directory | What it is | Make target (in `pbe_v1/`) |
|---|---|---|
| `golden-model/` | Python model, random differential, sigrok decoding, third-party bus models; all reports and recorded evidence (all rounds); CAN: `model/can_model.py` and the `pbe_bsync` differential, `sigrok/can_verify.py` (D73) | `make test-model`, `make diff`, `make diff-can`, `make sigrok`, `make sigrok-can`, `make test-buses` (see its README) |
| `formal/` | SymbiYosys properties of the FIFO (and its mark/rewind), host SPI, line coder, engine and CAN coder (`bsync`), and the default-configuration equivalence with the pre-CAN design (`default`), with a source-aware runner | `make formal [FORMAL_BLOCK=fifo\|host\|line\|engine\|bsync\|default\|ethernet\|modern]` |
| `vectors/crc/` | CRC unit against the RevEng catalogue and crccheck; wide entries include explicit prefeed-assisted seeds | `make test-crc-vectors [WIDE=1]` |
| `vectors/protocols/` | USB (LUNA, usb-protocol) and Modbus (PyModbus) packets through the chip's pins | `make test-protocol-vectors` |
| `coverage/` | Verilator line/toggle/branch/expression coverage and named functional bins | `make coverage`, `make test-coverage-tools` |
| `stress/` | Pin-level clock error, jitter, glitches, host backlog and concurrent protocols | `make stress`, `make stress-characterize`, `make stress-strict` |
| `mutation/` | 24 single-site RTL faults on scratch copies; each runs `make test` and `make diff` | `make mutate` |
| `ethernet/` | Independent D89–D94 host/CRC/Manchester/HDLC checks, wire codecs, vectors and stress; see its README and the open jitter defect | `make test-ethernet-corners`, `make test-wire-vectors`, `make stress-ethernet`, `make coverage-ethernet`, `make mutate-ethernet` |
| `spec_boundaries/` | Keeps the counterexamples to the old, stronger program-window and write-cancellation text (BUG-058/059) | part of `make test` |

Results: `golden-model/REPORT.md`. Python requirements: `golden-model/differential/`,
`golden-model/bus_models/`, `vectors/crc/` and `vectors/protocols/` each have a
`requirements.txt`; `ethernet/` adds its pinned wire dependencies. Formal and coverage need the OSS CAD Suite (Yosys, SBY, Yices, Verilator).
