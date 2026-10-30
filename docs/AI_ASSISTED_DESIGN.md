# AI-assisted design and verification of the PBE

How the Programmable Bit Engine was designed and checked with AI agents, what kept that work
honest, and where it went wrong. Every statement points to a commit, a design decision (D#), a
bug (BUG-###) or a file in this repository. Numbers are copied from those sources and not
re-measured here.

## 1. Workflow

### 1.1 One main design agent

Claude Code wrote the design, programs, testbenches and documentation. Its commits carry a
`Claude-Session` trailer. Most of the history, from the first design (`e874ebd`) to the
gate-level regression and the Tiny Tapeout packaging (`62d5e50`, `a56602b`, `df2e881`), was made
in one session (`session_01Fd6TYM…`). The human owner committed and pushed that work under their
own name, and the commits keep the `Co-Authored-By: Claude` trailer.

### 1.2 Parallel AI sessions on their own branches

After the first full Tiny Tapeout run passed (`df2e881`, D46), three independent tasks were
started from the same base (`e18ba95`). Each ran as a separate Claude Code session on its own
branch:

| Branch | Commit | Session | Work |
|---|---|---|---|
| `docs/routed-results` | `c0dbdb1` (06:56 UTC) | `session_01NQ8TMU1nF5…` | Record the routed results next to the estimates (D45, D46, D18) |
| `fix/reviewer-fixes` | `908907c` (07:12 UTC) | `session_01NQ8TMTHF9J…` | Five reviewer findings (BUG-038–042, D47–D49) |
| `fix/timing-48mhz` | `f362614` (07:25 UTC) | `session_01NQ8TMSM82K…` | Instruction register for 48 MHz (D50, BUG-043–045) |

The main line took `908907c` as a fast-forward and then merged the other two branches
(`8e4aebf` at 07:55:05, `ea28f91` at 07:55:25 UTC). Both merges had conflicts in
`docs/DESIGN_DECISIONS.md`, and `8e4aebf` also had conflicts in `docs/BUG_LOG.md` and
`src/pbe_engine.sv`; the merge messages list them. Each branch commit says `make test` passed
before it was pushed. The `regression` workflow passed on each branch head (runs 8, 9 and 10)
and on the merged `ea28f91` (run 11).

### 1.3 An independent verification agent

A second, independent AI agent from another vendor wrote the verification, without changing the
design. The repository shows that this work is separate, but it does not name the vendor:

- the four commits `07f824d`, `aaa85b0`, `e2674a1` and `2d62b89` (phases 1–3 and the CI
  dependency) have a different author identity and time zone and no `Claude-Session` trailer;
- `verify/golden-model/REPORT.md` gives the baseline as "`ea28f91` on `verify/golden-model`".
  That branch was not pushed: its commits arrived on `main` directly, and `git ls-remote` shows
  no `verify/golden-model`;
- D51 sets the rule: "no instruction, register, protocol program, or RTL behavior is changed".
  Under "Parallel work" it records that "separate agents own the engine/line model, sigrok
  tests, and third-party bus tests; the coordinator owns the top-level model, integration and
  phase commits".

The verification agent built its oracle from the written contract: the header comments of
`src/pbe_engine.sv`, `src/tt_um_pbe.sv`, `src/pbe_crc.sv` and `src/pbe_line.sv`, the README and
D50. It did not read the RTL's internal state to make its predictions (D51,
`verify/golden-model/model/ENGINE_FINDINGS.md`). This is the point of using a second vendor: an oracle
written by the same agent from the same reading would share that agent's mistakes.

## 2. The rules that keep AI work honest

`CLAUDE.md` is in the repository and every session reads it. It has three rules:

1. Every design decision goes in `docs/DESIGN_DECISIONS.md`, with its alternatives and the
   reason for the choice. When a new protocol forces a change, the old decision is marked
   **Changed** and keeps its reasoning. There are 54 decisions (D1–D54). The table "Changes
   forced by new protocols" has 25 rows, from SPI splitting the shift register (D9) to the
   48 MHz instruction register (D50). Two of those rows record protocols that needed no change.
2. Every bug goes in `docs/BUG_LOG.md`: the code before, the code after, and the test that fails
   before the fix and passes after it. Entries are never deleted.
3. `make test` in `pbe_v1/` must pass before a push, and it must exit non-zero on any failure.
   That rule exists because of BUG-007: a failing simulation once exited with code 0.

### 2.1 The bug log in numbers

The log has 57 entries, BUG-001 to BUG-057. Its own summary table stops at BUG-045 and leaves
out BUG-038–042, so the classification below comes from the entries themselves.

The tables below count BUG-001 to BUG-057, the log when this was written. Round 2 of the
verification added BUG-058 to BUG-073, and merging it added BUG-074 (the SRAM prototype's
refetch, logged on `main` as BUG-058) to BUG-076 (D64); they are not classified here yet.

**By category.** *Design* means RTL, protocol programs, the assembler and the host-firmware
protocol. *Test* means our own testbenches, models and verification harnesses. *Tool* means
simulators, synthesis, lint, CI configuration and third-party libraries or decoders.

| Category | Count | Bugs |
|---|---|---|
| Design | 21 | 008, 009, 010, 011, 012, 013, 015, 017, 019, 022, 028, 030, 031, 032, 033, 038, 039, 040, 041, 042, 043 |
| Test | 23 | 001, 002, 003, 004, 007, 014, 016, 018, 020, 021, 023, 025, 026, 027, 029, 034, 037, 047, 048, 049, 054, 055, 056 |
| Tool | 13 | 005, 006, 024, 035, 036, 044, 045, 046, 050, 051, 052, 053, 057 |

**By how each bug was found**, using each entry's "Found by" or "How found" text:

| How found | Count | Bugs |
|---|---|---|
| Our own testbench: first run, bring-up, a test written before the code | 23 | 001–003, 005, 006, 013–016, 018, 021–025, 027–029, 031–035 |
| Mutation check (a test still passed with the feature removed) | 2 | 004, 026 |
| AI review of the first design ("AI review, finding #1–#5") | 5 | 007, 008, 009, 011, 012 |
| Design, completeness, speed or timing review in the main session | 6 | 010, 017, 019, 020, 030, 043 |
| External reviewer | 5 | 038–042 |
| CI gate-level run; for 037, the move to Icarus 13 | 2 | 036, 037 |
| Flip-flop count after synthesis | 1 | 044 |
| Lint (Verilator 5.020) | 1 | 045 |
| Independent verification (phases 1–3, and publishing it) | 12 | 046–057 |

BUG-050 and BUG-051 are unfixed bugs in the stock sigrok USB request decoder. They stay as a
strict check that is expected to fail (`make sigrok-full`). BUG-024, BUG-035 and BUG-045 are
simulator or lint limits that were worked around. No independent check (phases 1–3) found an RTL
bug in its finite runs (`verify/golden-model/REPORT.md`).

### 2.2 Representative entries: the AI's own mistakes, caught by the process

- **BUG-023: static initializers.** The AI wrote `int bytes_before = tgt_bytes;` inside a
  procedural block. In SystemVerilog that initializer runs once, at time 0, which caused a false
  failure in Test 10. Icarus does warn about it, but an output filter written earlier hid the
  warning, the same trap as BUG-005. The fix splits the declaration from the assignment. A lint
  step in `pbe_v1/Makefile` now fails `make test` on that warning, and the lint was itself
  checked against a file that has the problem.
- **BUG-037: Icarus 13.** `tb_pbe.sv` used `scl_stretched` before its declaration. Icarus 12
  accepted that; Icarus 13, which Tiny Tapeout's `gl_test` uses, refused it. It was found only
  when the gate-level regression ran with Tiny Tapeout's simulator (third CI run, fixed in
  `df2e881`). The job now uses that same Icarus build and writes the end of its output as an
  annotation, so a failure can be read.
- **BUG-043: a bubble after every instruction.** The first draft of the 48 MHz fix (D50) loaded
  the instruction register every clock, so each instruction took at least 2 clocks at
  CLKDIV 0. A timing review spotted the problem before the draft was written. Run as a
  mutation, the draft broke the SPI peripheral at 2 MHz (Test 9: MISO changed while SCLK was
  high, wrong bytes), and `tb_fetch` failed 11 timing checks. The final design prefetches the
  next word, so only a taken jump costs a clock.
- **BUG-044: Yosys merged the copies of `pc`.** `(* keep *)` on the variable did not stop
  `opt_merge` from folding the three fan-out copies back into one register. A small test showed
  7 flip-flops instead of 28. The attribute now sits on the `always_ff`.
- **BUG-007: a failing test exited 0.** Found by the first AI review. With a deliberately
  broken design the simulation printed 5 FAILs and returned 0. `$fatal` fixed it, and the
  `CLAUDE.md` rule above came from it.
- **BUG-047: an error in the oracle, not the design.** The verification agent's own model
  treated speculative empty-FIFO MISO bits as known and discarded unreset FIFO storage between
  seeds. Its differential test exposed this (seed 5259847, cycle 22298). The model was fixed;
  the RTL was unchanged.

### 2.3 Independent review: five protocol bugs, each fixed test-first

An external reviewer found five protocol-level problems that every existing test had passed.
All five were fixed in one session on `fix/reviewer-fixes` (`908907c`). Each fix came with a test
that fails on the old code:

| Bug | Problem | Decision | Test that failed before |
|---|---|---|---|
| BUG-038 | 1-Wire: with the RX FIFO full, `PUSH` blocked before the strong pull-up, so a parasite-powered DS18B20 could miss its 10 µs window | D25 (program order) | Test 4: CONVERT T with the RX FIFO full: `no strong pull-up` |
| BUG-039 | Modbus RTU accepted a frame with a pause of more than 1.5 characters (Modbus over serial line §2.5.1.1) | D47 | Test 5, rounds 5–8: `frame reported valid` |
| BUG-040 | USB: a packet with a wrong stuff bit but intact data and CRC was ACKed | D48 | Test 11: `device ACKed a packet with a wrong stuff bit` |
| BUG-041 | USB: an IN packet whose ACK was lost was never sent again | D49 | Test 11: `firmware resent 0 packets, expected 1` |
| BUG-042 | USB: a bus reset did not bring the address back to 0 | D49 | Test 11: `firmware saw 0 bus resets, expected 1` |

## 3. Verification layers

Status after round 2 of the independent verification (branch `verify/round2`, D55-D61) was
merged with `main` (D64). All three groups below are in the repository; round 2's files are under
`verify/` (D63, D64). "In CI" means the `regression` workflow (`.github/workflows/regression.yaml`)
runs it on every push. Its run on `2d62b89`, run 12, passed; that was before round 2 enlarged
`make test`, which passes locally on the merged branch (exit 0, about 6 minutes) and has not run in
CI yet.

### 3.1 In `make test` (CI on every push)

| Layer | What | Where |
|---|---|---|
| Directed SystemVerilog testbenches | 9 executables: `tb_fifo_robustness`, `tb_engine_known_reset`, `tb_engine_restart`, `tb_engine_ops`, `tb_fetch`, `tb_line`, `tb_usb`, `tb_proto`, `tb_pbe` (shared host helpers in `tb_host.svh`). Tests 0–12, all through the chip's pins except the unit tests. `tb_fifo_robustness` was added when mutation M21 survived (BUG-061); `tb_engine_known_reset` checks four-state reset and restart outputs, which two-state formal cannot | `pbe_v1/test`, `pbe_v1/Makefile` |
| SRAM program memory | `make test-sram`: `tb_fetch`, `tb_usb`, `tb_proto`, `tb_pbe` again with `USE_SRAM` and IHP's macro model (D62) | `pbe_v1/Makefile` |
| Device models | Written apart from the RTL (D21): UART monitor, SPI peripheral, I2C register device with clock stretching, two DS18B20-style 1-Wire devices, RS-485 Modbus device, WS2812 decoder, mode-0 SPI controller, fast-mode I2C controller, USB host at ±1.5 % with its own CRC code, USB device-firmware model, and reference coders for USB, CAN and HDLC | the testbenches above |
| Hand mutation checks | Features broken on purpose to show that a test fails, as listed in D34–D37, D42, D50 and `pbe_v1/README.md` (Status). Two of these exposed weak tests (BUG-004, BUG-026) | the same tests |
| Testbench lint | `make test` fails on Icarus's static-initializer warning (BUG-023) | `pbe_v1/Makefile` `LINT` |
| Verilator lint | `--lint-only -Wall` on the whole RTL, and again with `USE_SRAM` (D46, BUG-045) | `regression.yaml` |
| Specification boundaries | The documented program-window and write contracts pass; the three original, stronger claims are kept as expected counterexamples (BUG-058/059) | `verify/spec_boundaries` |
| Python executable specification, unit tests | `make test-model`: 24 unit tests, engine, line coder, top level and FIFOs | `verify/golden-model/model` |
| Tool self-tests | 3 formal-receipt tests (BUG-067, BUG-071), 7 coverage-artifact guards (BUG-072), 5 capture-extraction and decoder-replay tests (BUG-049, BUG-062); none needs the external tool | `verify/formal`, `verify/coverage`, `verify/golden-model/sigrok` |
| Random differential smoke | `make diff N=2 CYCLES=600 SEED=0x504245`: random programs, host traffic and pin stimulus compared with the RTL every clock; 49,010 clocks | `verify/golden-model/differential` |

### 3.2 Run by hand

| Layer | What | Recorded result |
|---|---|---|
| Gate-level simulation of the routed netlist | `gl_regression` workflow → `make test-gl`. It runs after a `gds` run or by hand (D46). On the first routed netlist (`df2e881`, run 40810602581) it ran `tb_proto`, `tb_usb` and `tb_pbe`, and all passed. `tb_fetch` was added to `test-gl` later (D50) and has not run at gate level yet | D46 |
| Tiny Tapeout cocotb `gl_test` | `test/test.py`: a register round trip and a UART loopback between the engines, run on the routed netlist by the `gds` workflow (also on the RTL by `test.yaml` on every push) | 2/2 passed in the first run (D46) |
| Long random differential campaign | `make diff N=… SEED=…` | 32 seeds, 883,486 clocks compared, 8/8 opcodes and 34/34 sub-operations run, no disagreement (REPORT.md, phase 1) |
| Line coder and engine+coder differential | `make diff-line`, `make diff-engine-line` | 80,160 and 64,064 clocks, pass (REPORT.md) |
| sigrok decoding | `make sigrok`: stock UART, SPI, I2C, 1-Wire, Modbus, WS2812 and USB decoders on captured pins (D52, D57) | 22 pass and the 2 stock-decoder disagreements (BUG-050, BUG-051) as exact expected failures, exit 0; the strict `make sigrok-full` gives 22/24, exit 1 |
| cocotbext bus models | `make test-buses`: third-party UART, SPI and I2C endpoints on the chip's pins only (D53) | 6 endpoints, 18 random cases pass (PHASE3.md), with recorded adapters (BUG-052, BUG-053) |
| SymbiYosys formal properties | `make formal`: FIFO, host SPI, line coder, engine (D58) | 108/108 jobs match their expectation: 2 unbounded k-induction proofs (16-byte FIFO, host SPI), 79 bounded (BMC) passes, 15 covers reached, 12 original properties failing as expected (10 line-coder claims, 2 program-window fences). The engine and line coder are bounded only |
| Mutation testing | `make mutate`: 24 single-site RTL faults, each running `make test` and `make diff` on a scratch copy (D56) | The initial `make test` caught 23/24, the one-seed `make diff` 17/24; the survivor M21 (empty-FIFO pop) is now caught by `tb_fifo_robustness` (ROUND2_MUTATIONS.md) |
| CRC catalogue vectors | `make test-crc-vectors`: the CRC unit against the RevEng catalogue and crccheck (D59) | 22 configurations, widths 3–16: 220 payloads and 22 corrupted checksums pass; 3 entries need an arbitrary initial value and are unsupported |
| Protocol reference vectors | `make test-protocol-vectors`: USB packets from LUNA and usb-protocol, Modbus ADUs from PyModbus, through the chip's pins (D59) | USB: 38 host packets and 13 device responses, two seeds; Modbus: 7 cases at 19,200 and 115,200 baud, 8E1 and 8N2 |
| Code coverage | `make coverage`: the SV benches, the differential and the line sweep under Verilator (D60) | 92/92 named functional bins; line 190/191 (99.5 %), toggle 3,186/4,062 (78.4 %), branch 278/292 (95.2 %), expression 443/461 (96.1 %) |
| Stress and robustness | `make stress`, `make stress-characterize`: UART clock error and jitter, glitches, FIFO backlog, concurrent UART and SPI with restarts (D61) | 22/22 required observations; 33 characterized, 28 pass and 5 kept as failures (UART RX fails first at ±6 % clock error; a one-clock mid-bit glitch corrupts a byte; 3 of 20 bytes lost past FIFO capacity, with overflow flagged); random supplement 8 seeds, 276,039 clocks |

### 3.3 Not covered yet

| Layer | Status and source |
|---|---|
| Unbounded engine and line-coder proofs | Only bounded (BMC 40–164 clocks) today; only the FIFO and host SPI are proved by induction (ROUND2_FORMAL_*.md) |
| Stress of the other protocols | I2C, Modbus, USB, 1-Wire and WS2812 margins, every glitch phase and mid-byte restart are not measured (ROUND2_STRESS.md) |
| Toggle coverage | 78.4 %; the misses are visible in the annotated sources (COVERAGE.md) |
| SPI modes 1–3 | Not covered: the existing SPI programs implement mode 0, and the bus tests report the other modes as unsupported (PHASE3.md) |
| Silicon and pads | Everything above is digital simulation or formal on the RTL (and the gate-level netlist for `test-gl`); no electrical or hardware claim |

## 4. Where AI helped and where it failed

### 4.1 Estimates against routed results

- **Timing.** The AI's method was Yosys plus ABC `stime`, logic only, because OpenSTA could not
  be built in its workspace (D22). It estimated the worst path at 4.33 ns of logic, about 5.2 ns
  with flip-flop overheads, and D18 claimed "roughly 4×" margin at 48 MHz. The first routed run
  measured about 20.3 ns and 0.586 ns of setup slack at the slow corner (D45). Wires and the
  program counter's fan-out into the program-memory multiplexer (1,878 loads on `pc[0]`) made
  up about three quarters of the delay (D50). D22 had stated the limit ("wire delay and clock
  skew are not included"), but the margin claim in D18 ignored it. D45 marks the estimate
  **Changed**, and says the routed STA report is now the timing figure while ABC is used only to
  compare RTL changes with each other.
- **The fix is not measured yet.** D50 expects about 8 ns of routed slack after the instruction
  register. That is an estimate from the old routed report; the `gds` flow has not run since
  (D45 "Follow-up", D46).
- **Area.** The AI's area estimates came in low more than once: +49,000 µm² estimated against
  about twice that for the 128-word memory (D4), 6–8k against 12,141 µm² per line coder (D39),
  and +50k against +71,223 µm² for the USB features (D45). The final logic-only area held up:
  the routed utilisation is 44.3 %, and most of the gap is 3,590 hold-fix cells (D45).

### 4.2 Wrong assumptions caught by tests

- The I2C clock-stretching test passed with the stretching support removed (BUG-004). D21's
  rule since then: a feature counts as tested only once a mutation makes its test fail.
- Tests ran at 50 MHz although the plan was 48 MHz (BUG-020).
- The I2C controller fed its ACK bits into the CRC. The SMBus PEC test, written first, caught it
  (BUG-022).
- A byte left unread at the end of a frame became the next frame's first byte (BUG-028, Test 11).
- Without SE0, the idle line after a frame looked like a stuffing error (BUG-033, `tb_line`
  written before the coder).
- Third-party models do not always mean what they seem to: cocotbext-i2c samples SDA before a
  stretched SCL goes high (BUG-053), and the stock sigrok USB decoder counts a retried packet
  twice (BUG-051). These were recorded as tool bugs, not "fixed" in the design.
- Tools hide failures. A broad output filter hid a failed compile (BUG-005) and later a warning
  (BUG-023); a simulator exited 0 on failure (BUG-007); cocotb's Python runner returned success
  after a failed test (BUG-046); sigrok-cli returned 0 on a libusb error (BUG-046 addendum).
  Each runner now checks for real results, not only exit codes.

### 4.3 What a human decided

The decision records name the owner's choices in their own words:

- SystemVerilog over Hardcaml and others: "You asked for SystemVerilog" (D1).
- The 128-word program memory with jumps relative to `START_PC`: "decided with you" (D4).
- Keeping the engine general: v2 (USB) was retired, and USB came back only on hardware that
  other protocols also use (D28, `CLAUDE.md`).
- The rules in `CLAUDE.md` themselves (`1e537b5`).
- When the slow physical flow runs: `gds` and `gl_regression` are started by hand (D46).
- What each parallel session was asked to do, and when to merge it (section 1.2).

## 5. How to reproduce

From the repository root, with `iverilog`/`vvp` (12.0) and Python 3 on `PATH`:

```sh
python3 -m venv .venv
.venv/bin/pip install -r verify/golden-model/differential/requirements.txt   # cocotb 2.0.1
cd pbe_v1
make test                                  # lint, 9 testbenches, SRAM benches, spec boundaries, model and tool unit tests, 2-seed smoke
make diff N=32 SEED=0x504245 CYCLES=2000    # a longer differential campaign
make diff-line && make diff-engine-line     # line coder, engine + coder + CRC
make sigrok SIGROK_CLI=/path/to/sigrok-cli  # stock decoders; needs sigrok-cli
make sigrok-full SIGROK_CLI=/path/to/sigrok-cli   # strict USB request check; expected to fail (BUG-050/051)
../.venv/bin/pip install -r ../verify/golden-model/bus_models/requirements.txt
make test-buses CASES=3 BUS_SEED=20261029   # third-party bus models
make formal                                # SymbiYosys; needs the OSS CAD Suite on PATH
make test-crc-vectors test-protocol-vectors # after installing ../verify/vectors/*/requirements.txt
make coverage                              # Verilator coverage
make stress                                # pin-level stress, required cases
make mutate                                # 24 RTL faults on scratch copies (long)
make synth && make timing                   # area and logic-only timing estimates (D22)
cd ../test && make                          # Tiny Tapeout cocotb test on the RTL
```

The `Makefile` uses `../.venv/bin/python` when it exists. The physical flow (`gds`) and the
gate-level regression (`gl_regression`) run on GitHub Actions and are started by hand (D46).
