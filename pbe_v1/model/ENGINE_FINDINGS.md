# Engine and line oracle verification notes

## Sources and representation

The instruction comments in `src/pbe_engine.sv`, CRC wire-order comments in
`src/pbe_crc.sv`, line-code comments in `src/pbe_line.sv`, README instruction
table and D50 are the contract. The model uses bounded Python integers for
architectural registers and an explicit fetch-valid state for D50. Its line
coder expands queued transfers into Python bit lists, inserts stuff bits at
wire slots, and accumulates received bits in lists; it does not import RTL or
derive expected values from DUT signals. Internal DUT signals may be printed
for a mismatch, but do not determine expected values.

`effects()` describes transactions consumed by the next edge. A top-level
caller must evaluate both engines before changing shared state. `step()` then
updates one edge. Memory is read before a simultaneous host write. The caller
applies that write afterwards. Reset and restart are separate: restart releases
pin enables but retains output levels, cancels instruction effects, clears
engine status, restarts CRC, and redirects fetch to START_PC.

Timer sampling, frame/end indications and error indications are registered
interfaces. The engine observes coder events on the following edge. The receive
sampler retains a sample already due on an input-edge clock and recentres
subsequent samples; this is the synchronous meaning of midpoint sampling used
in the RTL. CLKDIV 0 and 1 are included in cycle comparisons; their receive
quality is not evidence that a two-sample-per-bit receiver can resolve arbitrary
external traffic at those divider values.

Reserved EXT sub-op 7 and PIN END while the coder is disabled perform no
instruction action. Random core tests keep coder mode in documented modes
0/1/2. JMP X-- tests nonzero before decrementing, as the existing assembler and
programs require. CRC-good compares the internal wire-order accumulator;
CRC register reads may be reversed. FIFO overrun remains sticky through STAT;
STAT clears receive parity and timeout only.

## Independent model checks

Run `python3 -m unittest discover -s model -p test_model.py -v` from `pbe_v1`.
Thirteen directed checks cover tick/delay timing at CLKDIV 0/1/4; taken branch
refill and relative addresses; between-tick WAIT completion; restart cancellation
and retained levels; FIFO blocking, overrun and IRQ; four flag-WAIT modes; program
write refetch; disabled/enabled timeout; CRC and inverted OSRCRC; STAT clearing;
eight-clock byte CRC feeding; independently constructed expected stuffing/NRZI
bitstreams and pair end-of-frame; receive loopback for every stuffing mode; and
safe handling of an unspecified instruction fetched while stopped, with a clear
error if the caller attempts to execute uninitialized program memory.

The `123456789` CRC checks are CRC-16/MODBUS = `0x4b37` and
CRC-8/MAXIM-DOW = `0xa1`, checked against the catalogue on 2026-10-29:

- https://reveng.sourceforge.io/crc-catalogue/16.htm#crc.cat.crc-16-modbus
- https://reveng.sourceforge.io/crc-catalogue/all.htm#crc.cat.crc-8-maxim-dow

These are two initial catalogue checks, not an exhaustive CRC catalogue sweep.

## Line differential result

`python model/check_line_model.py` uses cocotb 2.0.1 and Icarus 12.0, with an even
20,832 ps full clock period and 1 ps simulation precision. The fixed seed is
`0x504245`. The initial completed run compared 80,160 clocks (9.14 seconds),
covering all 160 products of NRZ/NRZI, four stuffing modes, pair/no-pair,
bit/byte, and CLKDIV 0/1/3/7/19. Sync, input/output bit ordering, queued data,
frame ends, input pin changes and receive consumption vary reproducibly.
Drive, both output levels, readiness, received-valid/data, frame-end and error
are compared every clock. No RTL disagreement was observed in that run.

`python model/check_engine_line_model.py` exercises the engine/coder composition,
CRC byte feed, random programs, pins/flags/FIFO interfaces, timeout settings,
host clears, restarts, stopped cycles and program writes. Its completed run
matched 64,064 clocks (16.28 seconds), with fixed seed `0x454c494e45` across 64
configuration trials. Pre-edge TX pop, RX push/data, flag set/clear and IRQ and
post-edge pins, enables, status, CRC and PC all agreed. No RTL disagreement was
observed in that run.

## Infrastructure defect discovered during bring-up

The initial standalone line runner printed a failing cocotb test (no timescale)
but returned process status zero because cocotb_tools.runner.test() did not
raise for test assertion failures outside pytest. This could make `make test`
silently pass a failed simulation. Parent documentation records this centrally
as the runner-result propagation bug; no RTL was changed.

Before:

```python
runner.test(...)
```

After:

```python
results = runner.test(...)
tests, failures = get_results(results)
if not tests or failures:
    raise SystemExit(f'line model differential failed: {failures}/{tests} failures')
```

Regression: `PBE_LINE_INJECT_FAILURE=1 python model/check_line_model.py` deliberately
fails in the simulator and must return nonzero. The ordinary invocation must
pass. An explicit `timescale=('1ns', '1ps')` fixes the original precision error.
This is an infrastructure mutation check, not a discovered RTL bug or failing
random seed.

## Model defect found by independent review

A newly constructed top-level model correctly represented unwritten program
words as `None`, but its second stopped clock tried to decode that unspecified
word and raised a Python `TypeError`. Hardware is allowed to fetch uninitialized
RAM while stopped; that fetch has no architectural effects. Executing an
uninitialized word remains unsupported and must fail explicitly.

Before:

```python
word = self.instr_q
op, arg, delay = word >> 13, word >> 4 & 511, word & 15
```

After:

```python
unknown_instruction = self.instr_q is None
word = 0xd800 if unknown_instruction else self.instr_q
# Decode the placeholder only for timing/readiness while stopped.
if unknown_instruction and execute:
    raise ValueError('uninitialized program instruction ...')
```

Regression `test_unwritten_program_is_harmless_while_stopped_and_rejected_when_run`
failed before with `TypeError` on `PBEModel(); edge(); edge()`. It now permits
stopped clocks, retains `instr_q is None`, drives no pins, and checks that
starting the engine raises a descriptive `ValueError`. A no-op is never
executed in place of unspecified memory. The full model unit suite has 20
passing tests including the seven top-level contract checks.

No core-ISA or line-coder RTL fix is proposed. Hardware source remains unchanged.
