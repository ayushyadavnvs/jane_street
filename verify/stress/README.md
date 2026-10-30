# Separate pin stress campaign

Uses the dependencies in `../golden-model/bus_models/requirements.txt`. From `pbe_v1/`, run:

```sh
../.venv/bin/python ../verify/stress/run.py --required-only
../.venv/bin/python ../verify/stress/run.py --characterize
# Full strict campaign includes beyond-margin observations and exits nonzero:
../.venv/bin/python ../verify/stress/run.py
# Reevaluate retained evidence without simulating:
../.venv/bin/python ../verify/stress/run.py --check-results build/stress/observations.json
```

`--seed 0x50424534` is the default. `--output` selects an isolated build/results
directory. The characterization option records each failed observation as FAIL;
it only allows the outer characterization command to complete with exit 0. Strict
mode exits 1 if any observation failed. The required-only campaign excludes the
larger UART mismatch/data-glitch exploration and does not claim those passed.

The fixture connects only chip pins. Existing host helpers, UART sink and SPI
peripheral models are reused; canonical testbenches, RTL and protocol programs are
unchanged. Jitter is seeded per UART bit. "Slow edge" is a delayed digital rising
threshold crossing, not an analog voltage ramp. All time periods use integral
picoseconds; the chip clock period is 20834 ps.

Per-case exact data and status live in `observations.json`. The cocotb XML PASS
means the observation driver completed; the Python runner separately validates
all per-case results. A whole-driver 200 ms simulation watchdog and finite read
limits prevent the harness from waiting indefinitely. They do not prove a PBE
program will always recover by itself.

See `../golden-model/ROUND2_STRESS.md` for measured scope and limitations.
