# Round2: bounded engine properties and retained counterexamples

These are **BMC results**, not induction proofs. The separate FIFO and host
proofs are unbounded safety proofs; this engine report does not inherit that
claim. No behavioral RTL was edited. `formal/engine_prepare.py` generates an
assertion-only copy under ignored `build/formal/generated/`; one extra input
connects the current memory word to the observer. The functional logic is copied
unchanged and all additional state/logic is verification-only.

## Tasks and boundaries

| Task | Actual scope | Bound | Expected result |
|---|---|---:|---|
| invariants | flag set/clear disjoint; TX pop only nonempty; RX push only nonfull; reset/restart register/enable/PC values, retained output latch |40|PASS|
| fetch | valid instruction equals coupled RAM[(pc-1) mod128], with arbitrary writes, run pauses and restarts |40|PASS|
| timeout | permanently blocked WAIT, timeout1–5, CLKDIV0–3, stable run/config and no disruptive host writes/restarts; reaches target5 and sticky status within timeout+2 counted ticks |50|PASS|
| activity | TX pop and RX push are reachable, rather than assuming all traffic away |20|two covers reached|
| pc_window | original physical prefetch-PC stays within START_PC+0…63 |70|FAIL counterexample|
| instruction_window | original valid executing instruction address stays in that region |70|FAIL counterexample|

The core configuration uses coder off, divider0, start_pc an arbitrary stable
7-bit value, CRC disabled, parity disabled and timeout0. Program memory has128
unreset symbolic16-bit words. Writes are arbitrary addresses/full16-bit data,
strictly coupled to pm_wr; full-word writes include every possible byte-write
result. Run/restart/FIFO boundary flags, input pins and flags can vary every
clock. The D50 comparison uses **pre-edge** RAM and instruction state, not a
post-write old-instruction cancellation assertion. This is the actual freshness
property, unlike BUG-059's original prose overclaim.

Timeout uses a fixed WAIT HIGH on an input held low, followed by NOP words; the
handler begins at5. The independent tick-age observer checks the requested
bound and the target/sticky status after a timeout. A clock deadline40 forces
completion for every selected timeout/divider combination, preventing a broken
never-issuing engine from vacuously satisfying the tick bound. This is not a
proof over every16-bit timeout/divider, arbitrary host disruptions, coder stalls,
or all blocking opcodes. Those cases require additional bounds/proofs.

For window tasks the program is all NOPs, START_PC0, run continuously enabled.
The physical PC reaches64 while instruction63 is current; that original property
fails at formal step66. The valid instruction subsequently reaches64 and the
second assertion fails at step67. Both traces are retained. These failures are
observable contract boundaries from BUG-058, not hidden by assumptions or fixed
by changing the design.

## X-state distinction

Yices/Yosys bit-vector checking is two-state. A passing Boolean property cannot
prove absence of simulator X values or power-up analog uncertainty. The explicit
reset register/enable checks are useful state assertions, but are not called
four-state X proofs. `test/tb_engine_known_reset.sv`, part of normal Icarus
`make test`, separately checks `$isunknown` after reset/restart for all64 coder
bit-field combinations with known digital inputs/program data. It also checks
restart releases enables. Reserved mode3 combinations are tested only for known
reset state, not promoted to supported protocol modes. Uninitialized external
traffic and electrical behavior remain outside that simulation claim.

## Reproduce

From `pbe_v1/`, with the recorded formal suite in PATH:

```sh
make formal FORMAL_BLOCK=engine
# Validate existing result inputs/configs exactly, without rerunning solvers:
make formal FORMAL_BLOCK=engine FORMAL_ARGS=--collect
```

The runner records actual PASS/FAIL separately from whether it matches an
explicit expectation. A retained counterexample remains a failed property.
Missing statuses, changed input hashes, changed task configs, timeouts,
unexpected passes and unrelated failures make collection fail. Raw logs and
traces live in `build/formal/engine_*`; selected artifacts and hashes are copied
into `verification/evidence/round2/formal/engine/`.

Tools: SBY v0.67-4-gfea6e46, Yosys0.67+94, smtbmc with Yices2.7.0. Hardware reset
is asserted for the first formal clock; asynchronous cells use standard
async2sync/dffunmap formal preprocessing. No physical-design flow is invoked.

## Observer corrections

BUG-064: the initial restart-value assertion used `$past(restart)` without
qualifying the prior reset. A trace with reset low and restart high properly
reset the DUT PC to0, but the observer incorrectly expected arbitrary START_PC1.
The observer now uses `$past(rst_n && restart)`; the same bounded task passes.
The original step2 trace/log are retained as a harness failure, not an RTL bug.

BUG-067: the result collector initially read the first `mode`/`depth` option in
expanded SBY config text. Task-specific overrides occur later, so an activity
cover was mislabeled as BMC and a stuffing bound could be overstated. It now
uses the last value, matching SBY; a two-option regression verifies effective
mode/depth. Solver outputs were unchanged. The old receipt is retained explicitly
as incorrect metadata, and corrected collection distinguishes covers from BMC.
