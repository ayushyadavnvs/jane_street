# Round 2 Verilator coverage

**92/92 named functional bins hit (100%).** Every normal SystemVerilog bench in
`make test` was built and executed under Verilator, followed by the unchanged
per-clock top-level golden-model oracle (`N=2 CYCLES=600 SEED=0x504245`) and the
160-configuration independent line-model sweep. A directed bench closed three
initial gaps: WAIT on rising/falling flags and RX-overflow status clearing.

The default `make test` remains the Icarus/four-state gate. Python model and
capture-extraction unit tests have no RTL source coverage to merge; their checks
remain in that gate. The Verilator campaign is the separate long `make coverage`
target and does not change tracked RTL or protocol programs.

## Reproduction and artifacts

From `pbe_v1/`, with Verilator and a C++ compiler in PATH and the pinned cocotb
requirements installed:

```sh
../.venv/bin/python coverage/run.py --jobs 2
# Reuse a compiled bench only when its source/include signature still matches:
../.venv/bin/python coverage/run.py --jobs 2 --reuse-builds
# Same differential oracle directly, using Verilator with scratch coverage:
../.venv/bin/python test/differential/run.py --sim verilator --coverage \
  --n 2 --cycles 600 --seed 0x504245
```

`coverage/prepare.py` copies RTL into ignored `build/coverage/src/`, adds named
cover statements and observation-only previous-status registers, and adds a
Verilator final coverage dump. `coverage/run.py` copies benches/includes/images
into `build/coverage/test/`, compiles with `--binary --timing --coverage --assert`,
runs their actual checks, then runs the cocotb comparisons. Each successful
simulation must also produce a freshly created nonempty coverage file; an exit
code or PASS string alone cannot satisfy the target. Existing program-image make
prerequisites are built before the image snapshot is copied. Full campaigns clear
old `.dat` inputs first; partial `--only` runs are for debugging and may aggregate
existing data. Failed compile/simulation/checks stop the target with nonzero
status; a missing differential XML/test or coverage file also fails.

`verilator_coverage --write` merges the real `.dat` files; `--annotate` and
`--write-info` produce annotated sources and LCOV at:

- `build/coverage/merged.dat`, `merged.info`, `annotated/`;
- `build/coverage/runs.json`, `summary.json`, `user_manifest.json`;
- `build/coverage/verilator_coverage.txt` (unfiltered vendor summary).

Selected immutable evidence, merged data, logs and source hashes are retained in
`verification/evidence/round2/coverage/`. The initial failed build and initial
run table are retained alongside this evidence; they are not counted as passes.
Tools: Verilator **5.051 devel** (`v5.050-99-gf8fb1d664`),
`verilator_coverage` from the same suite, GCC/G++ **11.4.0**, Python **3.10.12**,
cocotb **2.0.1**. Local tool PATH:
`/tmp/pbe-round2-tools/oss-cad-suite/bin`. No synthesis/physical flow ran.

## Functional bins

Bins are aggregated by logical name across both engine instances and across
standalone/top-level tests. They are not a claim that every engine separately
hit every bin or that every operand/data value was exercised. Opcode/sub-op/JMP/
WAIT bins require completed execution. Line-configuration bins additionally
require active transmitter/receiver state. JMP bins identify the condition
executed; they do not assert both taken and not-taken outcomes for each condition.

| Named group | Hit / total |
|---|---:|
| Eight ISA opcodes | 8 / 8 |
| PIN actions, FIFO directions, FLAG actions, EXT sub-ops (including reserved EXT7) | 22 / 22 |
| JMP conditions | 8 / 8 |
| WAIT LOW/HIGH/RISE/FALL, separately on pin and flag | 8 / 8 |
| Timeout taken, RX overflow, D50 program-write invalidation request | 3 / 3 |
| All five STATUS bits: observed set and clear transitions | 10 / 10 |
| NRZ/NRZI × four stuffing styles × single/pair × bit/byte | 32 / 32 |
| Both engines running simultaneously | 1 / 1 |
| **Total** | **92 / 92** |

Initial ordinary benches plus differential stimuli hit 89/92. New
`coverage/tb_coverage_gaps.sv` checks observable pin behavior while completing
WAIT FLAG RISE/FALL, then asserts that a full PUSH sets overflow and explicit
host clear removes it. It supplies the three missing hits without forcing
internal RTL state. The 32 line bins are closed by the existing per-clock
independent line-model sweep (80,160 clocks). Counts for every named bin are in
`summary.json`. The D50 bin is precisely `run && pm_wr && iv`: it observes an
invalidation request, not completed refill. The existing `tb_fetch` assertions
separately validate refill timing and execution of rewritten instructions.

## RTL structural coverage

The following metrics count original RTL source points, excluding testbench
code and appended instrumentation. Identical source points are coalesced across
hierarchies/test roots before calculating a combined result; a point is hit at
count ≥1. This avoids counting an unexercised copy in one standalone bench as a
new logical source obligation after another bench exercised the same RTL.

| Point type | Hit / total | Coverage |
|---|---:|---:|
| Line | 190 / 191 | 99.5% |
| Toggle (individual directional transitions) | 3,186 / 4,062 | 78.4% |
| Branch | 278 / 292 | 95.2% |
| Expression | 443 / 461 | 96.1% |

The remaining line point is `src/tt_um_pbe.sv:235`, the reachable no-op default
for otherwise unused addresses on the second configuration pages. It was not
exercised by this campaign; it is not declared unreachable. Remaining branch,
expression and toggle misses are retained in the annotations. In particular,
this finite campaign does not toggle every program-memory/configuration bit at
every location or exercise all large divider/counter values. Further closure
should bias host register/configuration traffic and add long counter-boundary
runs. No exclusion was added merely to improve these percentages.

The raw vendor report includes testbenches, instrumentation and distinct hierarchy
copies, so its denominator and percentages differ: line 1,752/2,391 (73.3%),
toggle 13,108/33,506 (39.1%), branch 1,907/3,260 (58.5%), expression 5,204/9,041
(57.6%), and user instances 263/979 (26.9%). Those raw counts are preserved
verbatim. The **92/92** figure is specifically the manifest's logical functional
bins after aggregation, not the raw tool's per-copy user percentage.

## Simulator boundary and preserved counterexamples

The top-level differential remains the same pin/bus oracle and checks known
`uio_out`, `uio_oe`, `uo_out` bits every clock plus final FIFO/status/flags/CRC.
Only the model-marked unspecified empty-FIFO MISO bit is masked in two-state
Verilator; Icarus still requires it to be X/Z. No other output mismatch is masked.

`tb_engine_known_reset` also runs under Verilator, but `$isunknown` cannot prove
four-state absence of X in a two-state simulator. The meaningful four-state
reset/restart regression remains the Icarus `make test` run. Coverage does not
replace that evidence.

`tb_spec_boundaries` runs its normal contract test and all three deliberately
failing stronger properties. Each must exit nonzero with its expected marker;
these expected counterexamples are recorded separately, not mislabeled as normal
passing assertions or used as successful trace coverage inputs.

## Coverage harness portability (BUG-069)

The initial `tb_line` Verilator build failed on three positive-sign diagnostic
format strings, even though Icarus accepts them:

```systemverilog
$sformatf("USB RX %+0.1f %%: ...", ...)
```

The scratch bench copy changes only that printing format:

```systemverilog
$sformatf("USB RX %0.1f %%: ...", ...)
```

Tracked bench stimulus, expected values, assertions and RTL stay unchanged. The
initial compiler log with `Unknown $display-like format code: '%+'` is preserved;
the adapted copy builds and the same `tb_line` checks pass. Annotation initially
also failed because `tb_host.svh` is a relative include filename in the coverage
database. Running `verilator_coverage --annotate` from the scratch test directory
resolves that path; merge, annotation and LCOV generation now pass. Both changes
are verification/tool compatibility fixes, not RTL fixes.


## Artifact enforcement and isolation (BUG-072)

Independent review found that the first coverage runner accepted a benchmark's
exit 0/PASS without requiring its `.dat` file. The line sweep had no artifact
check; the direct differential runner checked only existence, so a previous file
could satisfy it. Initial successful data and receipts remain under
`evidence/round2/coverage/before_bug072/`; the actual final campaign is rerun with
the stronger enforcement.

Before (insufficient acceptance rule):

```python
passed = proc.returncode == 0 and 'PASS' in proc.stdout
# No fresh benchmark data check.
if coverage and not coverage_output.exists():
    raise SystemExit('missing coverage')  # can accept a stale file
```

After, all three launch paths share this enforcement:

```python
clear_coverage(expected_path)       # unlink before starting the simulator
run_simulator()
require_coverage(expected_path)     # require a new regular file with size > 0
```

Seven fast `coverage/test_harness.py` regressions check missing, stale and empty
coverage rejection; valid new data acceptance; rejection of failed simulation
with a dump; program-image regeneration; and differential output isolation.
Restoring the old acceptance policy in a scratch helper makes all three artifact
negative regressions fail as expected; the corrected policy passes all seven.
Logs and receipts for both policies are retained. Run:

```sh
../.venv/bin/python -m unittest discover -s coverage -p test_harness.py -v
```

The runner now invokes the existing 13 `make test/*_image.hex` prerequisites
before copying images. A changed `.pbe` can therefore regenerate its image or
fail the campaign instead of silently using stale hex. The regression uses an
actual temporary make dependency graph with a newer program and stale image.

The shared differential used to write `coverage.json` and failure JSON into the
fixed `build/differential/`, even when its compiled build was elsewhere. It now
receives `PBE_DIFF_OUTPUT_DIR` from `run.py` and writes artifacts to that build.
The default Icarus directory stays unchanged; Verilator coverage output is
isolated under `build/coverage/obj_diff/`. This prevents concurrent independent
runs from overwriting one another's diagnostics. The directory-isolation
regression also checks the unchanged default path. No RTL change was involved.


## Python version provenance correction (BUG-073)

The original receipt copied `3.10.14` from cocotb's startup banner. A live
launcher query and a separate test executing `sys.version` inside cocotb instead
report **3.10.12**. Both original banner logs and old receipts are preserved;
the report now uses the independently measured runtime. No mechanism is claimed
for the banner discrepancy. The corrected receipt captures the live value
rather than hard-coding a version. Reproduction scripts, runtime JSON, logs and
fail-before/pass-after receipt checks are under
`verification/evidence/round2/python_runtime/`. This changes tool provenance,
not any RTL, stimulus, comparison or recorded verification result.
