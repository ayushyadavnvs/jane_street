# Golden model and independent verification

Everything that checks the PBE against references we did not write ourselves (D51 onwards in
`docs/DESIGN_DECISIONS.md`). The design and its own SystemVerilog testbenches stay in `pbe_v1/`;
run every target from `pbe_v1/` (see `pbe_v1/Makefile`).

| Directory | What it is | Make target (in `pbe_v1/`) |
|---|---|---|
| `model/` | Python executable specification of the engine, line coder and top level, written from the specification comments; its unit tests | `make test-model`, `make diff-line`, `make diff-engine-line` |
| `differential/` | cocotb harness: random programs, host traffic and pin stimulus on the RTL and the model, compared every clock; saved regression seeds | `make diff N=... SEED=...` |
| `sigrok/` | Decodes testbench waveforms with stock sigrok decoders and compares the bytes and packets | `make sigrok`, `make sigrok-full`, `make test-sigrok-extract` |
| `bus_models/` | Third-party cocotbext UART, SPI and I2C models on the chip's pins, randomized settings | `make test-buses CASES=3` |
| `evidence/` | Recorded results of each phase (dated receipts, not regenerated) | |

Reports: [REPORT.md](REPORT.md) (overview), [PHASE2.md](PHASE2.md) (sigrok),
[PHASE3.md](PHASE3.md) (bus models), [model/ENGINE_FINDINGS.md](model/ENGINE_FINDINGS.md).

Setup: `python3 -m venv .venv` at the repository root, then
`.venv/bin/pip install -r verify/golden-model/differential/requirements.txt` (and
`bus_models/requirements.txt` for the bus models). `make test` runs the model unit tests, the
sigrok extraction test and a short differential smoke.
