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
