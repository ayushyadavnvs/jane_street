# Round 2 formal: FIFO and host SPI

Both blocks passed **unbounded k-induction** with Yices. These are assertion
proofs under the explicit synchronous input assumptions below; they are not just
bounded simulation or BMC. The separate bounded cover runs establish reachable
nontrivial traffic. Neither proof establishes analog timing, CDC metastability
behavior, or four-state X propagation.

| Block | Actual configuration | Proof | Base depth | Cover run |
|---|---|---|---:|---|
| `pbe_fifo` | 16 entries × 8 bits (`ADDR_BITS=4`) | PASS, temporal induction successful | 32 | 4/4 reached at steps 3, 18, 19, 19 (bound 64) |
| `pbe_host_spi` | Unchanged synchronized mode-0 peripheral | PASS, temporal induction successful | 24 | 4/4 reached at steps 139, 139, 195, 195 (bound 224) |

Exact solver logs, statuses, source hashes and selected cover traces are retained
under `verification/evidence/round2/formal/fifo_host*`, with the aggregate receipt
in `fifo_host_results.json`. The base-depth number is the induction configuration,
not a limit on the completed safety proof's time horizon.

## Running

From `pbe_v1/`:

```sh
python3 formal/fifo_prepare.py
python3 formal/host_prepare.py
cd formal
sby -f -d ../build/formal/fifo fifo.sby prove
sby -f -d ../build/formal/fifo_cover fifo.sby cover
sby -f -d ../build/formal/host host.sby prove
sby -f -d ../build/formal/host_cover host.sby cover
```

Each prepare script also exposes `prepare(out=None)` for the parent runner. They
read the tracked RTL and insert assertion-only instrumentation immediately before
its single `endmodule`, writing generated files exclusively into ignored
`build/formal/generated/`. No design statement is replaced. Each `.sby` reads
that generated source. The instrumentation's internal-state relationships are
**assertions**, not assumptions about correct operation. No tracked RTL behavior,
reset, port or functional logic was modified.

Tools used: SymbiYosys `v0.67-4-gfea6e46`, Yosys `0.67+94` (`7defa5186-dirty`,
OSS CAD Suite binary), Yices `2.7.0`. Local executable directory:
`/tmp/pbe-round2-tools/oss-cad-suite/bin`. Both use `smtbmc yices`, with `async2sync`
and `dffunmap` preprocessing. No synthesis/PDK/physical flow was invoked.

## FIFO properties and assumptions

Inputs `push`, `pop`, `flush` and every data bit are unconstrained every clock.
Reset is assumed low for the initial clock, then high; subsequent reset pulses
are outside this proof (unconstrained flush is covered). The ghost occupancy
accepts pushes only below 16 and pops only above zero, using pre-edge occupancy.
It does not use the RTL's full/empty flags to decide reference acceptance.

The proof asserts:

- Count equals the independent accepted-push-minus-accepted-pop occupancy, and
  remains in 0…16.
- Empty/full exactly correspond to occupancy 0/16; they cannot both be true.
- Flush empties the FIFO; a rejected full push and rejected empty pop do not
  alter occupancy. Full simultaneous push/pop accepts only pop; empty
  simultaneous push/pop accepts only push.
- An arbitrary nondeterministically chosen accepted item retains its value in
  its physical slot, advances toward the head once per accepted pop, and appears
  as `dout` when its rank reaches zero. Its rank and physical pointer relation
  are asserted as inductive invariants. Since selection is unconstrained, this
  covers any queued item's ordering and retention rather than one fixed byte.

The four covers exercise intermediate simultaneous push/pop, full then flush,
full occupancy plus eventual chosen-item delivery, and both rejected boundary
operations followed by chosen-item delivery. All are reachable. No fairness or
forced-pop assumption is needed for the safety proof. Eventual delivery itself
is not asserted without a host-consumption fairness assumption.

Storage/dout while empty is deliberately unqualified and may contain stale or
uninitialised data. There is no assertion that this unspecified value is zero or
known. Logical item order is asserted only for queued data.

## Host properties and assumptions

The host block receives already-synchronized signals. Command bytes, data bytes,
`rd_data`, CS gaps and SCK pauses are arbitrary. Assumptions are limited to the
valid timing/framing environment:

- Initial reset low, CS high, SCK low; reset then stays high.
- Each SCK high/low phase lasts at least four chip clocks (SCK ≤ clk/8).
- CS assertion begins with SCK low; CS transitions do not coincide with SCK
  transitions. Partial-byte CS aborts are allowed at all bit positions.

The byte parser independently collects sampled MOSI bits and predicts the bus:
exactly one `wr_en` per completed write-data byte, correct `wr_addr` and
`wr_data`, exactly one `rd_done` per completed read-data byte, and correct
`rd_addr`. It also asserts no simultaneous read/write strobe and no adjacent
cycle pulses. The address is predicted from the command and increments modulo
128 after each data byte, except stream addresses 07, 16 and 26.

Read bytes are predicted by capturing arbitrary `rd_data` at the specified
second chip clock after command/read-byte completion, then comparing MISO
against the expected word's MSB at each data sampling edge. This allows the
register bus data to change every clock; it does not assume a constant byte
throughout a transaction. CS high resets framing, read-load pipeline and MISO
while preserving the address and receive history as specified; previously
issued bus pulses are not retroactively canceled.

For fast **cover search only**, `FORMAL_COVER` fixes each SCK phase to exactly
four clocks. The proof task does not define it and allows arbitrarily long
pauses. The four covers demonstrate multibyte streaming writes, multibyte
incrementing reads, abort then successful write, and abort then successful read.
An initial cover run with arbitrary pauses was voluntarily interrupted while
searching (exit 130, no finding); its log is preserved. The constrained legal
clock covers all reached in approximately six seconds. This optimization adds
no assumption to the safety proof.

## Harness issue retained (BUG-063)

The first host observer represented the output position with a wrapping
three-bit index:

```systemverilog
reg [2:0] f_read_bit = 7;
wire [7:0] f_shifted_read_word = f_read_word << (7-f_read_bit);
if (f_fall && f_bit != 0) f_read_bit <= f_read_bit - 1'b1;
```

An unreachable arbitrary induction state could start with an index inconsistent
with its byte position. After enough falling edges the index wrapped from 0 to
7, making the observer resurrect old data while the DUT correctly kept shifting
zeroes. Base case passed 24 steps, induction failed, and SBY returned **UNKNOWN
(exit 4)**. That trace was an induction/harness counterexample, not an RTL
counterexample. Its original VCD and log are preserved as
`fifo_host-host-initial-trace_induct.vcd.gz` and
`fifo_host-host-initial-logfile.txt.gz`.

The observer now represents mathematical shifts with a saturating count:

```systemverilog
reg [3:0] f_read_shift = 0;
wire [7:0] f_shifted_read_word = f_read_word << f_read_shift;
if (f_fall && f_bit != 0 && f_read_shift < 8)
  f_read_shift <= f_read_shift + 1'b1;
assert(f_read_shift <= 8);
```

After eight shifts the expected word remains zero, including arbitrary
induction states. The same host proof now passes both base case and induction,
with no additional environmental assumption or RTL change. Reproduction:
`host_prepare.py`, then the `host.sby prove` command above. Restore the displayed
old monitor to reproduce UNKNOWN; retain the corrected monitor for PASS.
