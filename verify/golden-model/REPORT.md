# PBE verification report — 2026-10-29

Source baseline: `ea28f91` on the `verify/golden-model` branch (since merged; the files now
live in this directory, `verify/golden-model/`). Verification-only changes;
`src/`, protocol programs and workflow triggers are unchanged. No GDS, physical,
synthesis or gate-level flow was invoked. Phase commits are deliberately separate.

## Setup and commands

```sh
python3 -m venv ../.venv
../.venv/bin/python -m pip install -r ../verify/golden-model/differential/requirements.txt
make test                          # existing SV tests, model units, two-seed smoke
make diff N=1000 SEED=0x504245      # long random top-level campaign
make diff N=3 CYCLES=2000 SEED=0x504245 # saved model regression
make diff-line                     # standalone line-coder differential
make diff-engine-line              # engine/coder/CRC composition
```

Run these inside `pbe_v1/`, with `iverilog` and `vvp` in PATH. `PYTHON=...` can
select an explicit interpreter; the Makefile detects the checkout's `.venv`.
All cocotb runners inspect XML and return nonzero on failed or absent tests.
Generated diagnostics live in `pbe_v1/build/` (ignored); selected result summaries
are committed under `verify/golden-model/evidence/`.

## Phase 1: independent executable specification

`model/pbe_model.py` implements the engine and line coder, and lazily exports the
top-level model in `model/top_model.py`. The latter models program memory, host
SPI framing/pipeline, register reads/writes, two synchronized input stages, two
engines, four 16-byte FIFOs, sticky IRQ/status, wraparound FLAG_BASE mappings,
clear priority and per-pin ownership. It never reads RTL state to set predictions.

`differential/run.py` loads programs and configurations through the host SPI
pins and compares all three output buses every clock. The test initialises program
memory to NOP before reset to define otherwise unspecified stopped-engine fetches;
all program writes under test are through SPI. FIFO memory remains unreset.
For unwritten FIFO speculative prefetch, the expected unknown MISO bit must also
be unknown in RTL; the other 23 output bits still compare. Final FIFO contents,
CRC, flags and status/count register reads are checked. Failure JSON includes
seed, clock, PC, instruction, both states and recent pin inputs.

A directed prelude plus random valid programs exercise all eight opcodes, PIN,
WAIT, JMP, FIFO, FLAG/MOV and EXT suboperations. Random programs use bounded
branch targets, 0–15 delays, pin/flag waits, timeout enabled/disabled, CLKDIV 0/1
and larger values. Host activity includes TX writes, RX reads, flag set/clear,
restart, status clears and writes to running program memory. Pin stimulus changes
independently every clock once execution begins. Coverage counts executed
instructions, not merely generated words. This is functional coverage, not RTL
branch/toggle coverage, and a finite seed campaign does not prove correctness.

## Phase 1 recorded results

- Existing seven SystemVerilog testbench executables: PASS (protocol tests 0–12,
  engine restart/operations, line coding and D50 checks).
- Independent Python model unit tests: 20 pass (13 engine/line + 7 top/FIFO).
- Top differential: **32 seeds, 883,486 compared clocks, PASS**, starting
  `0x504245`, 2,000 random-stimulus iterations per seed plus host transactions;
  141.67 seconds for this longer campaign. All **8/8 opcode** and **34/34
  suboperation** bins were executed (including reserved EXT7). Exact counts are
  in `evidence/phase1/top_32seeds.json`.
- Standalone line coder: **80,160 clocks, PASS**, 160 configuration combinations.
- Engine/coder composition: **64,064 clocks, PASS**, 64 configurations.
- No RTL/specification disagreement found by those finite runs. BUG-046 through
  BUG-048 describe the tool and model defects found and corrected.
- The longer 32-seed campaign is separate from `make test`'s two-seed smoke.
  The complete `make test` gate passed in 131.71 seconds on this host; its
  added two-seed differential smoke took 7.33 seconds.
  `N=1000` is supported; it was not represented as an executed campaign here.

## Tools

- Python startup banner reported 3.10.14; that historical runtime was not independently
  probed. Round-2 launcher and embedded probes measure 3.10.12 (BUG-073).
  Icarus Verilog/vvp 12.0 (stable).
- cocotb 2.0.1, find_libpython 0.5.1.
- Stock sigrok and third-party bus library versions/results are in the phase reports.
- No external dependency is installed automatically by a test target.

## Findings and next steps

Every confirmed model/tool defect and unresolved decoder disagreement is listed
in `docs/BUG_LOG.md`, with before/after snippets and reproduction commands.
No behavioral RTL change is permitted by this verification task.

Next: SymbiYosys proofs of FIFO acceptance/count invariants, host SPI framing and
line-coder safety; wider CRC vectors from the reveng catalogue; Verilator coverage
with coverage-directed generation for branches and simultaneous-event corners.
The unmodified SPI programs support mode 0; testing modes 1–3 needs additional
programs and is deliberately outside this no-design-change task.

## Phase 2: external waveform decoding

`make sigrok` captures external protocol pins with `PBE_SIGROK` and checks stock
UART, SPI, I2C, 1-Wire, Modbus, WS2812 and USB decoder results: **22/22 pass**.
The full USB request decoder has two reproducible disagreements on injected
malformed traffic and lost-ACK retransmission; `make sigrok-full` exposes those
as **22/24, nonzero exit**. Packet-level and isolated valid-request decoding
agree. BUG-049 records the fixed capture extractor defect; BUG-050/051 retain
unfixed decoder failures. See [PHASE2.md](PHASE2.md), with raw selected output
and JSON receipts under `evidence/phase2/`.

Install sigrok-cli separately; `SIGROK_CLI=/path/to/sigrok-cli` selects its binary.
Normal `make test` needs no sigrok binary: only the extraction regression joins it.

## Phase 3: third-party pin-only bus tests

Install `bus_models/requirements.txt` (in this directory), then run from `pbe_v1/`:

```sh
make test-buses CASES=3 BUS_SEED=20261029
```

Six endpoints (UART TX/RX, SPI controller/peripheral, I2C controller/target) passed
18 randomized cases, with independent data, gaps, baud/rate choices, stretching
and ±1% external clock error where applicable. The final SPI-gap rerun and six-test
smoke pass too. SPI modes 1–3 explicitly report unsupported because the unchanged
programs implement mode 0. [PHASE3.md](PHASE3.md) and
[test results](bus_models/results.json) detail settings and limitations.

BUG-052/053 document local adapters for cocotbext-spi compatibility and I2C master
stretch sampling. Stock failures remain reproducible; installed libraries are
unchanged. BUG-054–056 record corrected testbench timing/service/stimulus defects.
No RTL bug was established by these finite simulation campaigns. Formal proofs,
CRC catalogue expansion and Verilator coverage remain the next verification work.

## Final integration gate and local tool paths

The final-source `make test` passed in **129.17 s**, including 20 model unit tests,
the capture-boundary regression and a **7.45 s** fixed-seed differential smoke.
The final-source 18-case bus run passed in **61.18 s**. The coordinator also
reran the saved-capture sigrok comparisons: 22/22 pass; the strict full-request
run returns exit 1 with the two documented disagreements (22/24).

Tools were made available locally without a system installation. For this
workspace session, the simulator is available with:

```sh
export PATH=/tmp/pbe_review_a70001b_00au7u71/bin:$PATH
make test
make test-buses CASES=3 BUS_SEED=20261029
```

For the locally extracted sigrok packages:

```sh
export LD_LIBRARY_PATH=/tmp/pbe-sigrok-root/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
export SIGROKDECODE_DIR=/tmp/pbe-sigrok-root/usr/share/libsigrokdecode/decoders
make sigrok SIGROK_CLI=/tmp/pbe-sigrok-root/usr/bin/sigrok-cli
```

Those `/tmp` tools are session-local; on another machine install the listed
compiler/decoder versions normally. The Python dependencies live in the
checkout's ignored `.venv`, with pinned requirement files checked in.

# Round 2 — audit, formal, vectors, coverage and robustness

Branch `verify/round2` starts at `verify/golden-model` commit `2d62b89`. These
sections supersede the stronger round-1 independence and unconditional-window
interpretations. Report assumptions, bounded checks, proofs and counterexamples
separately. Physical-design/GDS/gate-level workflows remain untouched.

## Round 2 phase 0: audit and open items

- [ROUND2_MODEL_AUDIT.md](ROUND2_MODEL_AUDIT.md) inventories93 grouped rules,
  separating original specification text, implementation-informed cycle priorities
  and unspecified inputs. Shared priorities provide observational conformance,
  not independent architectural proof. Six headers clarify existing behavior;
  comment/string-aware comparison confirms unchanged HDL behavior.
- Original physical-PC and actual-instruction64-word fence assertions and same-
  edge PM-write cancellation fail as expected; the observed contracts pass in
  `verify/spec_boundaries/check_spec_boundaries.py`. No window protection/cancellation was added.
  Correctly sampled D50 valid-instruction/RAM equality remains a formal property.
- BUG-060 fixes invented zero bytes in partial PM writes using byte validity.
  Two new tests failed before and pass now. All24 model unit tests pass.
- [ROUND2_MUTATIONS.md](ROUND2_MUTATIONS.md):24 faults,48 actual make invocations;
  initial test23/24, separate one-seed diff17/24. The sole combined survivor
  (empty-pop guard removal) is caught by a new FIFO boundary test and rerun.
  Per-check blind spots, original comment-hash interruption and reconstructed
  summary provenance remain visible. This is finite fault sensitivity, not RTL
  coverage or exhaustive verification.
- [ROUND2_USB.md](ROUND2_USB.md): USB1.1 chapters7/8 and independent stock packet
  replays locate both disagreements in request-decoder state/ACK handling.
  Fresh `make sigrok`:22PASS,2exact XFAIL,exit0; strict run22PASS,2FAIL,exit1.
  BUG-062 exception/exit0 is rejected rather than expected away. Five independent
  extraction/classification/exception/replay unit tests pass with stock sources
  installed; ordinary test environments explicitly skip optional stock replay.
- BUG-058/059 clarify misleading contracts;060 repairs model validity;061 closes
  FIFO boundary coverage;062 hardens external-tool result handling. No behavioral
  RTL repair was made. D55–57 record decisions, alternatives and new tool versions.
- Run `make test`, long `make mutate`, `make sigrok`, strict `make sigrok-full`,
  or `python ../verify/golden-model/sigrok/usb_decoder_repro.py --decoder /path/to/usb_request/pd.py`.
  Long audits remain separate from the default gate.

Mutation table from the initial campaign (the separate one-seed diff column
keeps its original blind spots; M21 was caught by the added boundary rerun):

| ID | Injected fault | First detecting `make test` check | Separate `make diff` |
|---|---|---|---|
| M01 | ALWAYS jump never taken | `tb_engine_ops`: 27 RX bytes vs 8 | Caught |
| M02 | Invert X-nonzero jump | `tb_engine_ops`: wrong CRC/result byte | Caught |
| M03 | Invert PIN_HI jump | `tb_proto`: SPI peripheral reply differs | Caught |
| M04 | Load DLY + 1 | `tb_fetch`: edge gap 2 vs 1 clocks | Caught |
| M05 | Tick uses `>` instead of `>=` | `tb_fetch`: edge gap 2 vs 1 clocks | Caught |
| M06 | Invert FIFO empty | `tb_fetch`: RX count 2 vs 1 | Caught |
| M07 | Invert FIFO pointer full comparison | `tb_fetch`: RX count 0 vs 1 | Caught |
| M08 | FIFO count + 1 | `tb_fetch`: RX count 2 vs 1 | Caught |
| M09 | Drop host FLAG_CLR | `tb_usb`: status stage is not DATA1 ZLP | Survives |
| M10 | Drop both engines' flag clear | `tb_proto`: I2C target fails address ACK | Caught |
| M11 | Swap OSR output MSB/LSB selection | `tb_engine_ops`: wrong result byte | Caught |
| M12 | Swap ISR input shift direction | `tb_proto`: SPI RX 88 vs 11 | Caught |
| M13 | Invert CRC initial all-ones/zero | `tb_engine_ops`: wrong CRC byte | Caught |
| M14 | Complement CRC feedback top-bit reduction | `tb_engine_ops`: wrong CRC byte | Caught |
| M15 | Drop D50 invalidation on PM write | `tb_fetch`: rewritten stopped instruction gives no RX byte | Caught |
| M16 | Drop D50 PC rewind on PM write | `tb_fetch`: rewritten stopped instruction gives 00 vs 33 | Survives |
| M17 | Exchange stuffing thresholds 5 and 6 | `tb_line`: wrong USB frame duration | Survives |
| M18 | Disable TX stuffing | `tb_line`: wrong USB frame duration | Survives |
| M19 | Timeout uses `>` instead of `>=` | `test_diff.random_differential` inside `make test`: flags diverge | Caught |
| M20 | Reverse output pin ownership | `tb_fetch`: simulation watchdog (expected output edges absent) | Caught |
| M21 | Allow FIFO pop while empty | **Initial suite survives; new `tb_fifo_robustness` catches** | Survives |
| M22 | Allow exec during restart | `tb_engine_restart`: PULL pop during restart | Survives |
| M23 | Invert transmit parity | `tb_pbe`: 72 Modbus parity errors | Survives |
| M24 | Invert FIFO readiness | `tb_engine_ops`: RX count 0 vs 8 | Caught |

Phase0 commit gate: `make test` **PASS**,151.42seconds, including24 model tests,
standalone FIFO boundaries, retained spec-counterexample wrapper and fixed-seed
clock comparisons. The optional installed-stock replay was also run separately
with all5 extraction/decoder tests passing. `evidence/round2/phase0_gate.json`
records the gate and unchanged HDL token comparison for all six source files.

## Round 2 phase 1: formal properties and explicit counterexamples

The final source-aware collection matches **108/108 expected outcomes**, with
the following actual results kept distinct:

| Evidence | Jobs | Scope |
|---|---:|---|
| Unbounded temporal k-induction PASS | 2 | 16-byte FIFO and synchronized host SPI |
| BMC assertions PASS | 79 | 64 line compositions, 12 line reactions, 3 engine tasks |
| Cover PASS | 15 | 22 reached statements across FIFO/host/line/engine |
| Original properties FAIL, expected | 12 | 10 line boundaries and 2 PC fences |

Expected failures remain failed assertions with counterexample traces. The
108/108 number means expectation matches; it does not mean every requested
unconditional property was proved. No behavioral RTL repair was made.

- [ROUND2_FORMAL_FIFO_HOST.md](ROUND2_FORMAL_FIFO_HOST.md): FIFO occupancy,
  ignored boundary operations, flush and arbitrary selected-item ordering prove
  inductively at depth 32. Host framing/write/read/address properties prove at
  depth 24 under legal synchronized mode-0 timing (SCK ≤ clk/8), including
  arbitrary pauses and partial-byte aborts. Cover-only fixed clock spacing is
  separately disclosed; proof assumptions allow longer pauses.
- [ROUND2_FORMAL_ENGINE.md](ROUND2_FORMAL_ENGINE.md): safety/reset/restart and
  correctly sampled D50 memory equality pass BMC 40. Timeout passes BMC 50 for
  TIMEOUT 1–5/CLKDIV 0–3 and a permanently blocked WAIT with stable run/config.
  A deadline forces actual timeout progress. Physical prefetch PC leaves the
  proposed region at step 66; the current instruction leaves at step 67. Both
  original assertions fail explicitly. Four-state known-output simulation
  supplements the two-state engine checks; it is not inferred from formal PASS.
- [ROUND2_FORMAL_LINE.md](ROUND2_FORMAL_LINE.md): all 32 functional modes with
  both shift orders pass 64 BMC cases at depth 164, two arbitrary bytes/16 bit
  transfers, detectable sync and period 3. Pair mode checks exact length;
  single-wire checks a payload prefix and allows idle suffix; unstuffed single
  payloads additionally require regular zero bits. Twelve stuff-reaction cases
  and 12 nonvacuity covers pass depth 48. Original all-rate/no-sync/exact-length
  and unconditional-error claims retain ten failures. Period 0 never samples
  receive data (BUG-066); single-wire idle-high stuffing violations are normal
  frame ends, as specified. These limits are not repaired by changing hardware.
- BUG-063 fixes a wrapping induction observer, BUG-064 qualifies restart with
  prior reset, BUG-067 reads effective SBY option overrides, BUG-068 corrects
  unreachable cover goals and BUG-071 extracts actual cover locations. Before
  failures and corrected results remain in evidence; metadata corrections do
  not change solver outcomes. Independent read-only review found no blocking
  engine/property-source soundness issue and identified BUG-071 before commit.

Run from `pbe_v1/`, with the D55 formal tools on PATH:

```sh
make formal
make formal FORMAL_BLOCK=engine
make formal FORMAL_ARGS=--collect
python3 -m unittest discover -s ../verify/formal -p 'test_*.py'
```

The aggregate receipt is `evidence/round2/formal/aggregate_results.json`, with
compressed per-job logs under `formal/logs/` in that evidence directory.
Collection checks expanded configurations and every copied input hash, so
pre-fix observer/pilot results cannot silently substitute for final jobs.
D58 records assumptions, alternatives and evidence boundaries. Phase1 pre-commit `make test` **PASS**,132.07seconds: all SV benches,24 model
unit tests,3 formal-receipt tests,5 decoder/extraction unit tests (optional stock
replay explicitly skipped when absent), and49,010 differential clocks. Raw gate
log and source provenance are retained in `evidence/round2/phase1_gate*`.

## Round 2 phase 2: independent catalogue and protocol vectors

The unchanged CRC RTL passes **22 native catalogue configurations**, covering
**220 valid payload/codewords and 22 corrupted checksums**. Three additional
catalogue entries require arbitrary initial seeds and are explicitly unsupported,
not counted as RTL passes. USB and Modbus pin-level tests also pass with
externally generated expected packet bytes; no behavioral RTL change was made.

- [ROUND2_CRC_VECTORS.md](ROUND2_CRC_VECTORS.md): program-used CRC families plus
  16 additional configurations span widths 3–16. Each native configuration checks
  `123456789`, empty data and eight seeded random payloads against crccheck and
  pinned RevEng check/residue records. Tests exercise byte-by-byte raw state,
  idle preservation, init-over-feed priority, exact-width checksum append,
  CRC_GOOD acceptance/rejection and a flipped checksum bit. Raw state, reflected
  catalogue residue and final XOR are reported separately; software XOR does
  not become a claimed hardware register. This is a direct primitive test;
  existing engine/program integration tests provide separate evidence.
- [ROUND2_PROTOCOL_VECTORS.md](ROUND2_PROTOCOL_VECTORS.md): LUNA generates USB
  token/data/handshake packets and CRC bytes; usb-protocol checks PID nibbles.
  Seeds `0x50424532` and `0x50424533` each pass **38 host packets and 13 final
  device responses**, including wrong-address/bad-CRC rejection, descriptor
  chunks, vendor transfers, zero-length data and STALL. Recorded USB runs take
  2.009 s and 2.188 s respectively, excluding compilation. Response byte checks
  use independent packets while retaining the existing bus serializer/monitor
  and firmware model; exhaustive USB or physical pad conformance is not claimed.
- PyModbus FramerRTU supplies full Modbus ADUs, including CRC bytes, and decodes
  actual captured traffic. **Seven cases pass** at 19,200/115,200 baud with
  varied data/counts and 8E1/8N2. A corrupt-CRC response is rejected, and a
  two-character gap reports a partial invalid frame. The latter's timing check
  comes from the wire bench/program, not PyModbus. The run takes 43.096 s,
  excluding compilation. BUG-065 records the corrected USB response-count check
  and Icarus queue-expression adaptation, with fail-before/pass-after evidence.

Run from `pbe_v1/` after explicitly installing the pinned requirement files:

```sh
make test-crc-vectors
make test-protocol-vectors
# Longer reproducible CRC payload sweep:
../.venv/bin/python ../verify/vectors/crc/run.py --seed 0x435243 --random-cases 100
# Select a protocol or another reproducible seed:
../.venv/bin/python ../verify/vectors/protocols/run.py --protocol usb --seed 0x50424533
```

Evidence is under `evidence/round2/crc/` and `evidence/round2/vectors/protocol*`:
fixed inputs, external-library metadata, source hashes, XML/PASS output and
failed harness bring-up transcripts are retained. Missing/failing tests and
unexpected packets return nonzero. D59 records decisions, alternatives and
actual tool versions. These longer targets remain separate from `make test`;
Phase2 pre-commit `make test` **PASS**,130.69seconds, including49,010
differential clocks; see `evidence/round2/phase2_gate*`.

## Round 2 phase 3: Verilator functional and structural coverage

The final hardened coverage campaign hits **92/92 named functional bins**.
It runs the ordinary SV benches under Verilator, the unchanged per-clock top
oracle (`N=2 CYCLES=600 SEED=0x504245`) and the independent 160-configuration
line sweep. Three initial misses (flag-edge WAITs and overflow-status clear)
are closed by observable directed tests. No RTL/program behavior changed.

[COVERAGE.md](COVERAGE.md) defines every bin and the aggregation boundary.
The 92 bins are a logical union across engines/test roots, not a promise that
each instance, every operand or both outcomes of each jump were covered.
Original RTL source points are also coalesced across copies, with instrumentation
and benches excluded:

| Source point type | Hit / total | Coverage |
|---|---:|---:|
| Line | 190 / 191 | 99.5% |
| Toggle, directional transitions | 3,186 / 4,062 | 78.4% |
| Branch | 278 / 292 | 95.2% |
| Expression | 443 / 461 | 96.1% |

The remaining source line is a reachable unused-register no-op at
`src/tt_um_pbe.sv:235`; it was not exercised. Toggle/branch/expression misses
remain visible in annotations. Raw `verilator_coverage` counts include benches,
instrumentation and hierarchy copies and have different denominators; their
verbatim report is retained alongside the logical summary. 100% named bins
does not mean 100% RTL structural coverage, proof or hardware validation.

BUG-069 records scratch diagnostic-format/annotation-cwd fixes. BUG-072 adds
fresh nonempty dump requirements across bench/diff/line launch paths, actual
program-image rebuild prerequisites, and isolated differential diagnostics.
Seven fast harness tests pass; restoring old artifact acceptance makes the
three missing/stale/empty negative regressions fail. The complete campaign
was rerun under the hardened checks and preserves all metrics. Previous
successful data under the weaker artifact policy remains explicitly archived.

BUG-073 corrects Python provenance: live launcher and embedded Icarus/Verilator
`sys.version` probes report **3.10.12**, while cocotb startup logs print
3.10.14. The banner is retained, and no cause is inferred. CRC/coverage receipts
and D59 now use the measured runtime; before/after receipt checks are saved.
This is a metadata correction, not a change to verification outcomes.

Run from `pbe_v1/` with the recorded Verilator/C++ toolchain and Python dependencies:

```sh
make coverage
make test-coverage-tools
../.venv/bin/python ../verify/coverage/run.py --jobs 2 --reuse-builds
```

Selected `.dat`, LCOV, annotated sources, user-bin manifests, checks, raw logs
and hashes are in `evidence/round2/coverage/`; version probes are under
`evidence/round2/python_runtime/`. Only builds with matching source/include
signatures are reused. Failures and absent/stale/empty data return nonzero.
The default Icarus gate remains the four-state evidence: Verilator's two-state
`$isunknown` behavior is not an X-freedom proof. D60 records assumptions,
alternatives and versions. Phase-3 final `make test` passed in **128.23 s**, with
all seven new coverage-tool tests; the coordinator retains its gate receipt.

## Round 2 phase 4: optional stress and robustness

The final required pin-stress run passes **22/22 observations** in **58.94 s**.
Full characterization records **33 observations: 28 PASS and 5 FAIL**; its five
adverse observations remain failures in strict mode. The isolated random
supplement also passes **8 seeds and 276,039 compared clocks**, with 5,000 random
stimulus iterations per seed, in 54.47 s. No RTL, program or canonical-bench
behavior changed and no physical-design flow ran.

[ROUND2_STRESS.md](ROUND2_STRESS.md) and `evidence/round2/stress/` preserve exact
stimulus settings, data/status, source hashes, raw logs and strict evaluator exits.

- UART RX/TX pass the required ±2% clock-error cases. RX also passes this seed's
  independent ±2% per-bit jitter at ±2% average error, delayed digital rising
  crossings of four chip clocks, and a one-clock idle glitch. The sampled RX
  ±3%, ±4% and ±5% points pass; **±6% is the first tested clock-error failure**,
  and ±8% fails too. This is a tested-pattern boundary, not a guaranteed margin.
- A one-clock pulse centered in a data bit changes `00` to `08`. The simple
  single-sample UART 8N1 program has no dedicated framing-error record/majority
  vote, so this and the larger clock-error cases are exposed corruption
  limitations. Generic engine parity/CRC bits are not treated as valid UART 8N1
  framing diagnostics. They are not established RTL/spec disagreements.
- Slow UART RX service preserves all 16 bytes at FIFO capacity. With 20 bytes
  offered, the FIFO and blocked PUSH preserve the first 17 and lose the final
  three; sticky overflow (`STATUS=0x0b`) and IRQ assert. A subsequent `42` byte
  arrives correctly after draining without restart. Host service is withheld
  through the burst plus another 1 ms, then delayed by 100 bit times per read.
- Twelve rounds run UART TX and SPI controller on different engines/pins,
  restart and flush both between complete transfers, and check UART/MOSI/MISO
  bytes exactly. The final run measures 1,336 overlapping chip clocks each round.
  The separate random-program differential adds restart/host/program-write
  traffic; random programs are not claimed to implement named protocols.

Run from `pbe_v1/`, using the existing pinned bus-model dependencies:

```sh
make stress                 # strict required-only campaign: 22 passing cases
make stress-characterize    # all 33; retains five FAIL labels, collection exits 0
make stress-strict          # all 33; expected nonzero on the five adverse cases
# Reevaluate saved observations without simulating:
../.venv/bin/python ../verify/stress/run.py \
  --check-results ../verify/golden-model/evidence/round2/stress/stress_characterization.json
```

The final required run includes a 200 ms simulation-time whole-driver watchdog,
1 ms caller read deadlines, bounded FIFO draining and measured mixed-protocol
overlap. The earlier full characterization preceded the added whole-driver
watchdog/overlap counter; stimulus and expected byte checks are unchanged.
No caller deadline occurred in either completed campaign. A finite caller deadline
or watchdog bounds the harness, and does not prove universal no-hang behavior or
program self-recovery. Four-chip-clock delayed digital crossings approximate
threshold timing; analog slew, metastability and pad electrical behavior remain
outside this simulation. I2C, Modbus, USB, 1-Wire and WS2812 stress margins, every
pulse phase/width and mid-byte restart atomicity remain unmeasured here.

D61 records this approach, alternatives, actual tool versions and boundaries.
BUG-070 records the corrected evidence-export launcher that had resolved the
virtualenv Python symlink into system Python. Its before/after reevaluation
receipts show expected strict/required/characterization exits of 1/0/0 after the
fix; it did not change simulator outcomes. The stress targets remain separate
from default `make test`.

Final phase4 pre-commit `make test` **PASS**,128.68seconds, including all SV
benches,24 model tests,3 formal metadata tests,7 coverage guards,5 decoder
unit tests and49,010 differential clocks. Gate receipts/logs are in
`evidence/round2/phase4_gate*`. The source audit confirms all six HDL lexical
token streams, protocol programs and workflows unchanged from `2d62b89`; only
RTL header comments changed. This is source preservation, not a synthesis
equivalence proof. No physical-design or gate-level flow ran.

Recommended next work:

- Extend formal engine/line contracts across the currently restricted rates,
  coder configurations, all blocking operations and stable/live configuration
  cases. Preserve existing counterexamples and state assumptions explicitly;
  FIFO/host induction does not extend bounded engine/line results automatically.
- Close the remaining structural coverage points, including the reachable
  second-page register default and missing branch/expression/toggle transitions.
  The named-bin 100% result does not cover all operands, counter values or
  every instance/outcome; D50 invalidation-event coverage is separate from
  checking actual refill behavior.
- Expand catalogue/payload testing while retaining native CRC seed limits:
  zero/all-one initialization cannot express the three arbitrary-init catalogue
  entries. Keep host XOR transformations distinct from native hardware support,
  and extend primitive vectors through real program/engine integration.
- Add protocol-by-protocol glitch-phase, framing, FIFO starvation and recovery
  tests, checking exact data or documented error/timeout/NAK outcomes. Prioritize
  UART framing/error handling, USB retransmission/recovery and bus-stall bounds.
  Then measure physical pins and implementation timing independently; no
  routed/GDS/gate-level, board or analog evidence was produced by this work.


## Round 2 command reference

Run in `pbe_v1/`. Session-local tool paths (install the recorded versions normally
on another machine; these `/tmp` paths are not portable):

```sh
export PATH=/tmp/pbe_review_a70001b_00au7u71/bin:/tmp/pbe-round2-tools/oss-cad-suite/bin:$PATH
make test
make formal
make test-crc-vectors test-protocol-vectors
make coverage
make stress
# Extended characterization retains the five adverse labels:
make stress-characterize
# Supported long campaign, NOT executed as part of this report:
make diff N=10000 SEED=0x504245 CYCLES=1200
```

Python dependencies are pinned in `verify/golden-model/differential/requirements.txt`,
`verify/vectors/crc/requirements.txt`, `verify/vectors/protocols/requirements.txt`
and `verify/golden-model/bus_models/requirements.txt`; install them explicitly in the virtual
environment. No target installs dependencies. `make stress-strict` deliberately
returns nonzero for the retained five adverse observations. `make sigrok` retains
two verified USB decoder XFAILs; `make sigrok-full` remains strict and nonzero.

All five phase commits remain on `verify/round2`; no main merge or push was
performed for this round. D55–61 and BUG-058–073 record approach, corrections,
limits and evidence; the adverse UART observations are operating-envelope
limitations, not established RTL/spec defects.

## Re-run after merging round 2 with main (2026-10-30)

Round 2 was merged with `main` on branch `integrate/round2` and its files moved under `verify/`
(D64; main's D55, D56 and BUG-058 became D62, D63 and BUG-074). The targets were re-run from
`pbe_v1/` on the merged tree with the recorded tool versions (Icarus 12.0, cocotb 2.0.1,
Yosys 0.67+94, SBY v0.67-4-gfea6e46, Yices 2.7.0, Verilator 5.051 devel from OSS CAD Suite
`20260727`, sigrok-cli 0.7.2 with libsigrokdecode 0.5.3) but Python 3.13 rather than 3.10:

| Target | Result | Against round 2 |
|---|---|---|
| `make test` | exit 0, 5 min 56 s; now also runs `make test-sram` (D62) | same checks: 24 model, 3 formal-receipt, 7 coverage-guard, 5 extraction tests; spec boundaries 4/4; 49,010 differential clocks |
| `make formal` and `FORMAL_ARGS=--collect` | 108/108 matched: 2 proofs, 79 BMC, 15 covers (22 statements), 12 expected counterexamples | every job's status identical |
| `make test-crc-vectors` | 22 configurations, 220 payloads, 22 corrupted checksums; 3 unsupported | identical, 31,102 cycles |
| `make test-protocol-vectors` | USB PASS, Modbus 7 cases PASS | generated vectors and simulator output byte-identical |
| `make stress` | 22/22 in 60.3 s | all 22 observations identical |
| `make sigrok` / `make sigrok-full` | 22 PASS + 2 XFAIL, exit 0 / 22/24, script exit 1 | identical |
| `make coverage` | 92/92 bins; line 190/191, branch 278/292, toggle 3,230/4,106 (78.7 %), expression 458/477 (96.0 %) | line, branch and bins identical. Toggle and expression changed only in the two files main's SRAM prototype touched: the new `pc_d` port (+44 toggle points, all hit) and +16 expression points in `tt_um_pbe.sv`, one missed: the constant `1'b0` term of the `_unused_pc_d` sink |
| `make diff N=2` | PASS, 51,306 clocks (1,200 cycles per seed) | not run in round 2 at this length |
| `mutate.py --only M21` | `make test` caught by `tb_fifo_robustness`, `make diff` survived | identical to the recorded rerun (after BUG-076) |

The full 24-mutant campaign (`make mutate`) was not re-run.

## Coverage rerun after CAN, JTAG/SWD and the race fix (2026-11-06)

Branch `fix/race-coverage`. Verilator 5.051 devel (OSS CAD Suite 2026-07-27, as recorded), G++
13.3.0, Python 3.13.18, cocotb 2.0.1. The round-2 and 2026-10-30 rows above stay as they were.
Details are in [COVERAGE.md](COVERAGE.md) ("Rerun ... 2026-11-06"); the evidence is in
`evidence/rerun_2026-11-06/coverage/`.

| Target | Result | Against the earlier records |
|---|---|---|
| `make coverage` on main (d0c298f) | stopped: `tb_line` E4 `55 clocks ... expected 1 bit (48..54)` | a testbench race (BUG-102); reproduced with `run.py --only tb_line` |
| `make coverage` (fixed tree) | exit 0; 13 benches PASS (now with `tb_debug`, BUG-106), differential and line sweep PASS | — |
| functional bins | **130/130**: the 92 round-2 bins and 38 new CAN bins (D73) | first fixed run 129/130 (`bsync_late_join`, BUG-105), closed by `tb_line` E2b |
| line | 265/269 (98.5 %) | 190/191; +78 points from CAN, LINE2, FIFO mark/rewind, new registers |
| branch | 482/510 (94.5 %) | 278/292 |
| expression | 852/908 (93.8 %) | 443/461 (round 2), 458/477 (10-30) |
| toggle | 4,450/5,394 (82.5 %) | 3,186/4,062 (round 2), 3,230/4,106 (10-30, + the SRAM `pc_d` port) |
| `make test` | exit 0 (Icarus 12.0) | — |
| `make test-verilator` (new, D80) | 5 benches PASS, logs identical to Icarus (Verilator 5.020, the CI's) | — |

Missed lines: the unused-address default (round 2's line, moved), and the three host clears of
STATUS bits 5–7, which `can_node`'s `CRCRST` makes unnecessary in every bench program. The five
`pbe_bsync` lines missed before E7–E9 are covered: the SOF glitch, the bit error in its own
active flag, REC > 127 → 119 on a success, and the 14/8-dominant-bit rule. No RTL bug turned up
there. The run found one RTL bug, BUG-104: the first sample after reset. It surfaced through the
reset-release audit, not through a coverage gap.

# Round 3 — D89–D94 Ethernet verification

**RTL findings:** BUG-145 is repaired: Manchester now ignores LINE2[6] idle qualification,
with a minimal fail-before/pass-after test and one mode guard. BUG-151 remains open:
valid per-crossing ±13.5 ns jitter can corrupt/split received Ethernet frames. A minimum
60-byte frame reproduces it in Icarus and Verilator. This campaign does **not** establish
10BASE-T compliance. No recovery-loop retuning, program changes, GDS, gate-level workflow,
merge or intermediate push is included.

The branch starts at feature/ethernet `3cca934`. Historical sections/evidence above remain
unchanged. D95–D100 document the approach; BUG-138 onward distinguish RTL, model, harness,
fixture and tool findings. The owner superseded stage pushes: complete the work locally
and defer pushing until the end.

## Default compatibility and integration

| Target | Round-3 result | Comparison / qualification |
|---|---|---|
| `make test` | PASS | Full Icarus 12 gate, including the existing protocol benches and new minimal idle-wait, timeout and parity regressions |
| `make test-verilator` | PASS, all six selected benches | Icarus/Verilator normalized logs identical; the earlier five-bench count predates the current recipe |
| Both exact CI lint commands | PASS | SRAM black-box and FF fallback, all warnings enabled |
| Default differential, N=2 / CYCLES=600 / seed 0x504245 | PASS, **50,663 clocks**, every counter identical | Exact JSON equality with untouched `3cca934`; the older 49,010-clock record predates PAGE/SRAM/current stimulus and cannot honestly be claimed for this checkout |
| `make test-crc-vectors` | PASS: 22 native configurations, 220 payloads, 22 corrupt codewords rejected, 3 unsupported, **31,102 clocks** | Existing narrow result/cycle count retained; this primitive's legacy clock metadata remains unchanged |
| `make test-buses` | PASS: six endpoints × three cases at 60 MHz | 18-case result retained; I2C controller additionally rerun after deriving 21/42/85 divisors from the actual seven-phase bit schedule |
| `make test-protocol-vectors` | PASS: USB and seven Modbus cases | Independent package checks retained; SRAM inputs supplied and receipt-path export repaired |
| `make sigrok` | **22 PASS + 2 documented USB XFAIL**, exit zero | Same external decoder disagreements; UART decoder corrected from the old 480 kbaud setting to actual 600 kbaud, using the same fresh capture |
| `make stress` | **22/22 PASS** | Every required observation identical to round 2; saved comparison is `{}` |
| Default `make coverage` | **140/140 old functional bins** | Old-bin closure retained; structural point totals reflect the wider/new hardware and are reported below |
| Original 24 mutants | Initial 23/24 combined; final **24/24 caught** after focused regressions | Initial M19 timeout is not a kill. Separate default one-seed differential catches 17/24; seven survivors remain disclosed |
| Existing formal matrix | 112 non-default jobs source-validated against original RTL; old pre-CAN engine equivalence exposes PAGE counterexample | No claim that the historical overbroad engine property still holds; see formal domains below |
| Model / coverage-tool guards | **34 model tests + 7 coverage-tool guards PASS** | Fresh/empty/stale coverage-file failures remain checked; no exit-zero-only coverage acceptance |

Default harness changes explicitly tie off new ports, zero-extend narrow CRC inputs,
retain complete wider output comparisons, and include the FUNCTIONAL IHP SRAM models.
The assembler adapter supplies separate 256-word engine memories. No old expected payload,
mutation fault, protocol assertion or historical evidence was edited to manufacture equality.
The sole RTL change is `idle_wait = cfg2[6] && !manch`. Legacy default differential/CRC
primitive tests retain their original 20832-ps reference period for cycle comparisons; the
new Ethernet campaign and external protocol checks use 16668 ps or independent partner
clocks. These digital results make no physical-frequency timing claim.

## Golden reference and random differential

The Python model was extended from D89–D94/public interface specifications: quad framing,
HOSTCFG and idle-SCK recovery; queued-bit Manchester halves and receive reference age;
CRC widths to 32, high registers and OSRCRC byte selection; per-unit stuffing tags and
flag-delimited receive. Model predictions never consume RTL state. Diagnostic state reads
only explain disagreements. Initial phase/overshoot clarifications after a mismatch are
explicitly implementation-informed cycle contracts (D96, BUG-142), not independent proofs.

- Original line differential remains independently runnable: 160 configurations / 80,160 clocks.
- New D90/D94 line differential: **240 configurations / 192,241 clocks PASS**, both polarities,
  orders, bit/byte and single/pair forms; periods 4/5/6/7/20 clocks, SYNC absent/D5, ignored
  Manchester LINE fields, stuffing control and flag framing.
- Directed host/engine tests: six widths × sixteen OSRCRC parameters × two engines; high
  CRC/value/good registers; retained state on live shrink; captured/uncaptured short CS,
  partial nibble abort, seven/eight recovery clocks, counter reset, mux and mode latch;
  simultaneous STUFFOFF/ON and Manchester idle-wait exception. **Three tests PASS in both simulators.**
- Full-divider/line corners: **three PASS**. At period 65536 the carrier ends exactly 131072
  clocks after its intentional first edge; a half-sample-only glitch produces no data/end;
  flag-delimited continuous-one runs emit ends every six sampled bits.
- Large campaign: **PASS: 1,000 seeds, 1,200 random iterations per seed, **20,951,842 checked clocks**, seed 0x504245; Verilator 5.051**. Verilator's two-state treatment is limited to model-marked
  unspecified empty-FIFO output lanes; all known output bits and every clock are compared.
  Icarus supplies four-state default, directed and failing-seed replay evidence.

The first 1,000-seed Icarus attempt stopped at global index 983 / seed 5260828 because the
checker compared a STATUS snapshot taken before a host transaction with a later prefetched
byte. The autonomous coder can update status while engines are stopped. BUG-155 fixes the
read expectation at actual sampling time; the per-clock pin oracle, final status/FIFO checks
and explicit directed values remain. The exact global-index replay now passes 30,688 clocks.
That failed campaign is retained and is not counted as a 1,000-seed pass. Replay preserves
the global index because index zero intentionally uses the coverage prelude.

## Formal results and assumptions

There are two source lineages: the unchanged baseline before the one-line repair and the
repaired RTL. The 112 existing FIFO/host/line/engine/bsync jobs were collected only after
expanded configurations and **every copied input hash** matched the original `3cca934`
worktree. Their results are 3 unbounded proofs, 81 bounded passes, 16 covers and 12 explicit
assertion counterexamples. The repair-only unbounded equivalence below transfers the old
line-mode behavior; it does not relabel those old receipts as new-source solver runs.

| Check | Result | Domain / depth |
|---|---|---|
| Existing FIFO and single-lane host induction | 3 unbounded PASS | FIFO induction depths 32/32, cover 64; host induction depth 24, cover 224; `!quad` is proved, not assumed as hidden DUT state |
| Existing line checks | 76 BMC PASS, 12 cover PASS, 10 expected assertion counterexamples | Round-trip depth 164, stuff/cover depth 48 where specified; longer wall-time budget, no reduced depth |
| Existing engine / bsync | 5 BMC PASS, 2 cover PASS, 2 expected PC/window counterexamples | Engine safety/fetch/SRAM depths 40, timeout 50, activity cover 20, window counterexamples 70; bsync BMC 70 / cover 90 |
| Pre-CAN line default | BMC PASS | Depth 18; old modes, LINE2=0, new controls off |
| Pre-CAN engine historical goal | Expected assertion counterexample | Depth 8; PAGE-relative jump semantics invalidate the old arbitrary-PC/start-address claim |
| Additional page-zero engine compatibility | BMC PASS | Depth 8, START_PC=0, no PAGE prefix, public fetch PC <=64; explicitly additional restricted goal |
| D88 engine vs D94 engine | BMC PASS | Depth 8; full 8-bit PC/PAGE and arbitrary live configuration; new mode/flag/control encodings disabled, dividers/timeouts <4 |
| Quad/single host framing and latch | Unbounded induction PASS | Depth 32; legal synchronized mode-0 timing, four-clock SCK phases; request can change during selection |
| Pre-D89 single-lane host equivalence | Unbounded induction PASS | Depth 4; arbitrary pin timing and extra MOSI lanes, quad request disabled, full common state/output comparison |
| CRC coefficient reference, widths 17–32 | Unbounded induction PASS | Depth 8; symbolic fixed width, dynamic polynomial/good/input/init/reflection, repeated asynchronous reset |
| Pre-D91 narrow CRC equivalence | Unbounded induction PASS | Depth 8; live width changes, full raw state, value and good comparator; high poly/good halves zero |
| Manchester timer range | Unbounded induction PASS | Depth 8; symbolic divider 3..FFFF; signed timer stays within proven representable range |
| Manchester polarity 0 / 1 | Two BMC PASS | Depth 260 each: independent IEEE TX halves, preamble/SFD, arbitrary payload, tail, recovered byte and deadline at six clocks/bit |
| Stuff tags / flag framing | Two BMC PASS | Depth 80 each; queued/shifter tags, on precedence, reset/clear, pending stuff bit, low-level frame end, continued receive and run reset |
| New host / Manchester / stuff / flag covers | Four cover PASS | Depth 224 / 260 / 80 / 80; nonvacuity only, not safety proofs |
| Pre-D90 legacy line equivalence | Unbounded equivalence PASS, 402 cells (common reset) | Every LINE2 value and 16-bit period, modes 0–2, LINE[6]=0 and ctl=0; old always-on stuffing exposed as constant observation state |
| One-line repair preservation | Unbounded equivalence PASS, 575 cells (common reset) | Original `3cca934` vs repair, modes 0–2; **all LINE2, LINE[6], ctl, early samples and other external inputs free** |

The successful new Ethernet SBY block has **13/13 matched: 5 induction, 4 BMC, 4 covers**.
Together the separately source-validated SBY groups account for **129 results: 8 induction,
88 bounded passes, 20 covers and 13 expected counterexamples**. The two Yosys equivalence
runs above are additional. Expected counterexamples remain false properties, not proofs.

The historical engine check remains a failing check; it was not silently replaced by the
page-zero domain. The modern D88 miter preserves PAGE semantics for the Ethernet comparison.
A broad structural engine-equivalence pilot left 35 cells unproved and supplies **no**
unbounded engine proof. Initial host observer UNKNOWN, CRC-reference reset counterexample,
wall-time cutoffs and this incomplete pilot are retained separately from successful results.
Manchester formal round trip is synchronous and bounded; it proves no analog/jitter margin.
Wide CRC live-width transitions are directed tests, not an arbitrary-changing-wide-width proof.

## External CRC and wire vectors

The primary RevEng 17plus catalogue and crccheck 1.3.1 agree for **24 configurations,
240 payloads and 24 corrupted codewords rejected**, without skipping a wide catalogue entry.
Twenty use native zero/all-ones initialization. Four 24-bit seeds use explicit software
prefeed prefixes: BLE e58efb, FLEXRAY-A 1624bb, FLEXRAY-B 67d13f, OPENPGP b111c9. These are
prefeed-assisted checks, not an arbitrary seed-load register. All widths 17..32 additionally
receive synthetic external-library checks in coverage mode. ISO-HDLC's 123456789 check is
0xCBF43926 and reflected residue 0xDEBB20E3; raw PBE CRC_GOOD is the reversed 0xC704DD7B.

Scapy 2.8.0 supplies actual Ethernet bytes; binascii supplies FCS. A separate stateless
IEEE-half-cell decoder checks captured public TX pins, seven 55 bytes + D5, every data/FCS
bit, raw residue, bit period, three-bit TP_IDL and IFG measured from the last FCS bit.
Eight frames of 60,61,255,256,512,1514,1600,32640 bytes pass; the jumbo contains each chunk
length 1..255. The measured tail is 300024 ps. Empty [0] produces no frame. Actual decoded
packets are saved as pcap without FCS, with FCS/timing sidecars; no real-NIC provenance is claimed.

External receive checks pass exact escaped payload/FCS/status for good and corrupted frames,
runts of 0..3 bytes after SFD, 1..7 ignored dribble bits, an eighth bit producing an extra ff
byte and bad CRC, link pulses and short noise. Independent CRC-16/IBM-SDLC and NRZI/flag/
zero-deletion codecs validate HDLC transmit and receive for 4- and 256-byte frames. Existing
HDLC benches add NRZ/NRZI rates, shared flags, bad CRC and abort cases. No golden-model code
is imported by these wire codecs or expected payload calculations.

## Coverage

Default instrumentation remains 140 bins. Extended instrumentation adds 79 new events:
**219/219 hit**. All 18 selected SV benches, the old differential/line sweep, 240-config new
line sweep, directed register/host programs, wide CRC vectors/width sweep and independent
wire vectors pass and produce fresh nonempty Verilator dumps. The two final missing bins
were closed by directed simultaneous STUFFOFF/ON and Manchester LINE2[6] transfers.

| Original RTL source points | Default run | Extended run |
|---|---|---|
| Toggle | 7954 / 13030 | **8849 / 13030** |
| Expression | 1924 / 2320 | **1942 / 2323** |
| Line points | 553 / 641 | **564 / 641** |
| Branch | 920 / 1120 | **949 / 1120** |
| Distinct source line locations | See baseline receipt | **291 / 295** |

Counters coalesce identical source points across bench roots/instances and exclude appended
instrumentation/testbench source from RTL percentages. The new guard adds expression points.
These are actual simulator data, not a claim of every operand/configuration/path. Complete
point counts are in the summary; 4,810 unhit logical points are enumerated in
`evidence/round3/coverage/structural-gaps.json.gz`, without claiming they are unreachable. The
four unhit source locations and their reachability explanations are **the reachable, unexercised CAN host-clear bodies in pbe_engine.sv (arb/bit-error/sent at lines 620/622/624), and the reachable no-op reserved second-page write default in tt_um_pbe.sv (line 320). They are disclosed gaps, not classified as unreachable**.

Named bins cover each new mode/corner category; they are not exhaustive cross-products.
Not exhaustively tested: all real-valued host/glitch phases, every RX-overrun byte position,
all 65536 divider values, all frame lengths, arbitrary live mode changes during a frame,
all early/late/ISI patterns, physical CDC/metastability and routed timing. The period-FFFF
corner plus symbolic range proof covers timer representability; it is not a full-divider
Manchester lock proof. No bin count is used to excuse the independently failing jitter cases.

## Mutation sensitivity

Old 24-fault results: initial make-test catches 23 and M19 times out; separate differential
catches 17 and seven survive. A timeout is not detection. Exact timeout and parity tests
near the front of the normal gate catch M19/M23 in seconds, yielding **24/24 combined**.
Old raw results and separate differential blind spots remain available.

| New fault | Detector | Final result |
|---|---|---|
| E01 quad nibble order | Public-pin directed oracle | Caught |
| E02 mode latch while selected | Public-pin directed oracle | Caught |
| E03 Manchester polarity | 240-config per-clock line oracle | Caught |
| E04 Manchester lock threshold | Same | Caught |
| E05 early-edge offset | Same | Caught |
| E06 high CRC width decode | Independent wide catalogue | Caught |
| E07 CRC reflection | Independent wide catalogue | Caught |
| E08 queued stuffing tag | 240-config line oracle | Caught |
| E09 STUFFON precedence | Same | Caught |
| E10 flag run reset | Directed continuous-one end intervals | Caught; original random survivor retained |
| P01 short IFG loop | Canonical external Ethernet bench | Caught, minimum gap 5.03 us |
| P02 second END replaced with NOP | Independent pin completion barrier | Caught; completion 716724 ps before last FCS bit; initial payload-only survivor retained |
| P03 frame-start STAT replaced with NOP | Frame after idle timeout | Caught, leaked status 04 |
| P04 extra escape PUSH replaced with NOP | Independent dense-escape RX record | Caught |

Final campaign: **14/14 caught; no inconclusive result or survivor in the final frozen campaign**. Frozen source/test manifests, source site before/after,
commands, executable hashes, failure reasons and logs are retained. Early missing-venv,
ambiguous-site and bare-assertion diagnostic outcomes are inconclusive pilots, not kills.
The initial STAT replacement also clobbered X and is superseded by the single-effect NOP.
No compile error, timeout or unexplained nonzero exit earns a kill.

## Digital stress and margins

IEEE 802.3-2012 clause 14.3.1.3.1 requires ±13.5 ns relative to **each ideal zero crossing**;
adjacent intervals can vary by 27 ns. The previously measured ±0.8-clock value is 13.3344 ns,
slightly below that limit. Primary IEEE text was inspected at the my-wire.de PDF mirror
cited in D99; no copyrighted PDF is redistributed. This digital spacing-dependent stimulus
is an ISI proxy, not an analog cable/equalizer/squelch model.

| Stress | Observed delivery / status outcome |
|---|---|
| Quad host, 16 phases across a 16668-ps clock, clk/8 minimum phases | PASS; alternating cases add uniform 0..2000-ps half-phase delay; minimum 66672 ps, maximum 68672 ps |
| Normal 256-byte full duplex at those host phases | PASS, exact RX bytes + FCS/status 02, TX status clear |
| Required ±13500-ps crossings, two seeds × uniform/alternating/spacing-dependent × ±100 ppm | **6/12 delivery FAIL**: uniform 4/4 PASS; alternating slow 2/2 PASS, fast 0/2; spacing-dependent 0/4 |
| Minimum legal 60-byte frame, spacing-dependent ±13500 ps, -100 ppm | **FAIL in both simulators**: 30 bytes, bad CRC/status 00; complete stimulus and actual bytes retained |
| Uniform beyond-limit 14/15/18/20 ns and adversarial patterns | **uniform passes at 14 and 15 ns, fails at 18 and 20 ns for the sampled seed; alternating and spacing-dependent fail at all four levels**; finite sampled margins, not compliance bounds |
| ±1000 / ±10000 ppm without added jitter, 1514-byte frames | PASS for all four sampled offsets |
| Back-to-back RX, exactly 9.6 us after last FCS bit | PASS, two exact frames/status 02 |
| Worst-case escaped full duplex, 1514 bytes | **Delivery FAIL**: TX status 00; RX 954 bytes/status 18. Asymptotic escaped-RX + TX payload demand approaches the 3.75-MB/s host raw limit before command/count/chunk overhead |
| TX 30-us starvation | Corrupt delivery, correct status 10; no timeout bit |
| TX >1-ms starvation | Correct abort status 14; [0][0] resynchronization then complete frame/status 00 |
| Host absent during RX | 17 retained prefix bytes/status 18; next intact frame status 0a reflects sticky overflow; explicit host clear then next frame/status 02 |

The local six-clock bit is 100008 ps (about -80 ppm relative to ideal 10 MHz). Source offsets
are recorded both relative to ideal and to this simulated local clock; source ±100 ppm gives
approximately -20/+180 ppm relative offsets. Jitter applies only to actual transitions and
nonmonotonic stimuli are rejected. Host jitter never shortens a half-phase below four clocks;
this is not a claim for faster-than-specified SCK or arbitrary duty cycle.

The final stress target returns **nonzero: three tests PASS, one required-jitter test FAIL**.
Correct error flags are reported separately from successful delivery. The 1514-byte stress
frame has finite header/FCS overhead, so its raw data demand is slightly below the asymptotic
3.75-MB/s figure; required command/count/CS/chunk traffic still exceeds usable capacity. Normal link pulse
16±8-ms interval/100-ns pulse and no-pulse-during-frame behavior remain checked by the
canonical Ethernet bench in the integration/coverage campaigns. Analog voltage/template,
link-integrity features, auto-negotiation, CSMA/CD and routed 60-MHz setup/hold are unverified
or unsupported as documented by D93; prohibited physical/gate-level flows were not run.

## Reproduction and evidence

Use OSS CAD Suite **2026-07-27**, Verilator **5.051 devel**, Yosys **0.67+94**, bundled SBY/Yices,
Icarus/vvp **12.0**, Python **3.12.4**, cocotb **2.0.1**, stock sigrok-cli **0.7.2** and
libsigrokdecode **0.5.3**. Put Icarus 12 ahead of the suite's Icarus 14. Only add the suite's
bin directory for targets requiring Verilator/formal. Disable compiler output grouping to
fit the two-CPU/eight-GiB runner; no assertion/instrumentation/stimulus is dropped.
Install the existing per-target pinned requirements and `verify/ethernet/requirements.txt`.

From `pbe_v1/`:

```sh
make test
make test-verilator
# Run both exact lint commands in .github/workflows/regression.yaml.
make formal FORMAL_JOBS=1 FORMAL_ARGS='--timeout 1800'
make coverage
make coverage-ethernet
make stress
make mutate JOBS=1
make mutate-ethernet
make sigrok
make test-buses
make test-crc-vectors
make test-crc-vectors WIDE=1
make test-protocol-vectors
make test-ethernet-corners
make test-wire-vectors
make diff ETHERNET=1 N=1000 CYCLES=1200
make stress-ethernet   # currently NONZERO: BUG-151 remains open
```

Additional scripts from repository root:

```sh
.venv/bin/python verify/formal/legacy_equiv.py
.venv/bin/python verify/formal/legacy_equiv.py --repair-only
.venv/bin/python verify/ethernet/run_line_corners.py
.venv/bin/python verify/ethernet/run_wire.py --sim verilator --test-module test_program_corners
.venv/bin/python verify/ethernet/run_wire.py --test-module test_jitter_reproducer
.venv/bin/python verify/golden-model/differential/run.py --ethernet --n 1 \
  --seed 0x504245 --start-index 983 --cycles 1200
```

The minimum-jitter reproducer is also intentionally nonzero. The recorded large campaign
uses `differential/run.py --ethernet --sim verilator --n 1000 --cycles 1200 --seed 0x504245`;
the ordinary `make diff` command above uses Icarus unless explicitly invoking the runner.

Selected raw logs, hashes, initial failures, counterexamples, actual frame bytes/edge times,
pcap, coverage counts and mutation receipts are under **evidence/round3/**. Generated binaries,
VCDs, annotated source and full build trees stay in ignored `pbe_v1/build/`; historical evidence
is preserved. Read `evidence/round3/README.md` for source lineage and intentionally failing
results. The saved receipts, not planned commands or mere completion banners, determine
which checks passed. No claim here extends digital simulation/formal bounds to physical
silicon or full standards compliance.
