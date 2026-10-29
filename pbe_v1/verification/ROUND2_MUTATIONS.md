# Round 2: mutation sensitivity audit

The initial campaign exercised 24 one-site RTL mutations in temporary copies. Each
copy ran **both** the real `make test` target and a separate
`make diff N=1 CYCLES=600 SEED=0x504245`, regardless of the first result. The
initial suite caught **23/24** mutations; its separate one-seed differential
campaign caught **17/24**. The remaining mutation exposed a missing empty-FIFO
boundary test. After adding `tb_fifo_robustness.sv` to `make test`, rerunning that
same mutation caught it immediately. Thus **24/24 selected mutations have a
recorded detecting check**, with the original survivor and its corrective rerun
retained separately. This is sensitivity evidence for these finite faults, not
proof of implementation correctness or complete mutation coverage.

No mutated RTL was written to the repository's `src/`, and no RTL behavior was
changed. No synthesis, GDS, gate-level or physical-design flow ran.

## Reproduction

From `pbe_v1/`, with the documented Python/cocotb and Icarus environment:

```sh
# Independent long-running audit, deliberately separate from make test:
../.venv/bin/python tools/mutate.py --jobs 3 --n 1 --cycles 600 --seed 0x504245
# Reproduce only the corrected coverage gap:
../.venv/bin/python tools/mutate.py --only M21 --jobs 1 \
  --out verification/evidence/round2/mutations/fifo-gap-rerun
```

The script validates each replacement occurs exactly once, freezes one baseline
copy for all workers, and runs each mutant in its own scratch directory. It
records the before/after code, source hashes, commands, process exit status,
elapsed time, first failing check and compressed raw logs. It returns nonzero if
any mutant survives. Compile/dependency errors, unexplained process failures and
wall-clock timeouts are inconclusive, not detected faults; wall-clock timeout
kills the entire subprocess group. A testbench's intentional simulation watchdog
is reported explicitly as that check's failure. Default timeout is 360 seconds
per make target. Jobs run concurrently only against independent scratch copies.

Tools: Python startup banner reported 3.10.14; the historical campaign did not
record an independent runtime probe. Current launcher/embedded probes report
3.10.12 (BUG-073); original logs remain unchanged. Icarus Verilog/vvp 12.0 and
cocotb 2.0.1. The original
campaign used three workers. Baseline RTL commit: `2d62b89` (same HDL behavior as
round 1); exact SHA-256 hashes and the comment-only audit are in
`evidence/round2/mutations/summary.json`.

## Results

“Survives” below means this specific one-seed **separate** differential invocation
returned zero; it does not mean that the mutation survived all checks. `make
test` itself also includes its two-seed differential smoke. For M19 that smoke
was the first detecting check. Every reported caught result had a nonzero process
exit, so no `$display` alone is counted as enforcement.

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

The short differential has identifiable blind spots: its random protocol core
runs with the line coder disabled (M17/M18); the particular host schedule does
not sensitise the host flag-clear/D50 rewind faults (M09/M16); restart coincident
with a ready FIFO instruction is not deliberately scheduled (M22); its program
and data do not expose the parity error (M23); RX reads are guarded by nonempty
model state (M21). Existing directed benches cover the first six. Each remains
a useful candidate for broader differential stimulus; a one-seed pass is never
presented as a caught mutation.

## Survivor, corrective test and nonzero enforcement

M21 was the only mutation surviving the union of original checks. The top-level
random host reads RX only when its model count is nonzero, and the existing
benches did not assert the isolated FIFO's behavior on empty pop. The FIFO
contract explicitly says empty pops are ignored; deleting its guard changes
an empty count from 0 to 31 in the 16-deep FIFO.

New `test/tb_fifo_robustness.sv` drives this boundary without host/engine gating.
It also checks reset, all 16 accepted pushes/pops, byte order, ignored full
push, repeated empty pop and flush. The unchanged design passes. The identical
M21 fault now fails `make test` with:

```text
FATAL: tb_fifo_robustness.sv:15: FIFO boundary: empty pop must be ignored count=31 empty=0 full=0
```

Before test coverage:

```make
# No standalone FIFO boundary test in make test.
```

After test coverage:

```make
cd test && iverilog -g2012 -o fifo_robustness.vvp tb_fifo_robustness.sv ../src/pbe_fifo.sv && vvp -n fifo_robustness.vvp
```

Unchanged FIFO code (no repair needed):

```systemverilog
if (pop && !empty) rptr <= rptr + 1'b1;
```

Fault injected only in scratch:

```systemverilog
if (pop) rptr <= rptr + 1'b1;
```

Original M21 exits: `make test` 0, `make diff` 0. Corrective rerun:
`make test` 2 (caught), separate `make diff` 0 (same documented stimulus gap).
Evidence is in `evidence/round2/mutations/fifo-gap-rerun/`. This coverage gap is
BUG-061; it is not a discovered defect in the tracked RTL.

## Evidence provenance and runner improvement

All 48 original make invocations completed and wrote per-mutant receipts and
raw logs. The original runner then rejected its final literal source-hash check
because the parallel specification audit had edited RTL comments. Its aggregate
exit was therefore 1, and it did not originally emit `summary.json`. All
original source-file hashes recorded in the mutation receipts match `HEAD`.
Comment/string-aware token hashing independently established that current HDL
behavior is byte-for-byte equivalent after stripping comments and whitespace.
The checked-in original-campaign summary was reconstructed explicitly from the
24 preserved receipts and 48 logs and records this provenance; it is not a
fabricated successful runner exit. No per-mutant evidence was discarded or
rewritten.

The runner now freezes a single immutable baseline before scheduling workers.
Its default remains strict against checkout source changes. The explicit
`--allow-comment-changes` flag permits only edits whose comment-stripped HDL hash
stays identical; behavioral changes still raise. It also avoids mistaking
cocotb's harmless “install pytest for better AssertionError messages” hint for
the first failure. The reconstructed summary reparses those diagnostic fields
from the raw logs; original JSON receipts preserve the initial parser's output.
The M21 corrective rerun used the corrected runner and exited zero normally.
