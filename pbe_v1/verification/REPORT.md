# PBE verification report — 2026-10-29

Source baseline: `ea28f91` on `verify/golden-model`. Verification-only changes;
`src/`, protocol programs and workflow triggers are unchanged. No GDS, physical,
synthesis or gate-level flow was invoked. Phase commits are deliberately separate.

## Setup and commands

```sh
python3 -m venv ../.venv
../.venv/bin/python -m pip install -r test/differential/requirements.txt
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
are committed under `verification/`.

## Phase 1: independent executable specification

`model/pbe_model.py` implements the engine and line coder, and lazily exports the
top-level model in `model/top_model.py`. The latter models program memory, host
SPI framing/pipeline, register reads/writes, two synchronized input stages, two
engines, four 16-byte FIFOs, sticky IRQ/status, wraparound FLAG_BASE mappings,
clear priority and per-pin ownership. It never reads RTL state to set predictions.

`test/differential/run.py` loads programs and configurations through the host SPI
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

- Python 3.10.14; Icarus Verilog/vvp 12.0 (stable).
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

Install `test/bus_models/requirements.txt`, then run:

```sh
make test-buses CASES=3 BUS_SEED=20261029
```

Six endpoints (UART TX/RX, SPI controller/peripheral, I2C controller/target) passed
18 randomized cases, with independent data, gaps, baud/rate choices, stretching
and ±1% external clock error where applicable. The final SPI-gap rerun and six-test
smoke pass too. SPI modes 1–3 explicitly report unsupported because the unchanged
programs implement mode 0. [PHASE3.md](PHASE3.md) and
[test results](../test/bus_models/results.json) detail settings and limitations.

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
  `tools/check_spec_boundaries.py`. No window protection/cancellation was added.
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
  or `python tools/usb_decoder_repro.py --decoder /path/to/usb_request/pd.py`.
  Long audits remain separate from the default gate.

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
python3 -m unittest discover -s formal -p 'test_*.py'
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
../.venv/bin/python test/reference_crc/run.py --seed 0x435243 --random-cases 100
# Select a protocol or another reproducible seed:
../.venv/bin/python test/reference_protocols/run.py --protocol usb --seed 0x50424533
```

Evidence is under `evidence/round2/crc/` and `evidence/round2/vectors/protocol*`:
fixed inputs, external-library metadata, source hashes, XML/PASS output and
failed harness bring-up transcripts are retained. Missing/failing tests and
unexpected packets return nonzero. D59 records decisions, alternatives and
actual tool versions. These longer targets remain separate from `make test`;
Phase2 pre-commit `make test` **PASS**,130.69seconds, including49,010
differential clocks; see `evidence/round2/phase2_gate*`.
