# Phase 3: third-party protocol endpoints, 2026-10-29

This is RTL simulation verification only. No RTL or protocol program is changed,
and the runner invokes only Icarus, VVP and cocotb. It never invokes synthesis,
GDS, gate-level workflows, or a physical-design tool. The common verification
design decision and the numbered bug records are maintained in the repository's
living design-decision and bug documents.

## Reproduce

From the repository root, with `iverilog` and `vvp` on `PATH`:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r verify/golden-model/bus_models/requirements.txt
.venv/bin/python verify/golden-model/bus_models/run.py --seed 20261029 --cases 3
```

`--test uart_tx`, `uart_rx`, `spi_controller`, `spi_peripheral`,
`i2c_controller`, or `i2c_target` selects one endpoint test. `--cases` controls
the cases per selected endpoint. The fixed seed is mixed with the endpoint's
name, so selecting one test preserves its random stimulus. A case logs its
settings and exchanged bytes. `sim_build/results.xml` carries pass/fail results;
missing/empty results or any failure make the runner exit nonzero, including
an import error before cocotb starts a test. A previous XML is deleted first.

`--spi-mode 1`, `2`, or `3` exits with an explicit unsupported-mode error. Both
existing SPI programs specify mode 0. Testing additional modes would require
different programs, outside the user's request to leave the design unchanged.
No successful test here is represented as evidence for those modes.

## Independence and timing

The test fixture instantiates the complete Tiny Tapeout top. All program loads,
configuration, FIFO pushes/pops, status and flags use actual host SPI pins.
Endpoint models attach to the resolved protocol pins. There are no hierarchical
DUT reads, deposits, forces, or memory shortcuts. The fixture's scalar aliases
exist solely to provide single-pin handles to the third-party libraries.

The test fixture represents external release/high as 1 and low as 0, uses pull-ups
on undriven pins and resolves low against other drivers. It does not model analog
rise/fall times, metastability or electrical contention. Assertions compare
protocol bytes and host results, not internal architectural state.

The engine clock is 20,834 ps, an even integral picosecond period accepted by
cocotb 2 (47.998464 MHz, approximately -32 ppm from 48 MHz). Endpoint UART baud
uses the actual simulated clock rate. External endpoint settings cycle through
-1%, nominal, and +1% relative clock errors. SPI periods are rounded to an even
number of picoseconds. I2C endpoint timing uses the stock library's integral
nanosecond timers.

## Exercised behavior

| Endpoint | Independent library | Cases and checks |
|---|---|---|
| UART TX | `cocotbext-uart.UartSink` | 8N1, random bytes, random host/inter-byte gaps; 96/192/384-clock bit choices; -1/0/+1% receiver baud; byte equality |
| UART RX | `cocotbext-uart.UartSource` | independent 8N1 input, random bytes/gaps, same rate choices and clock errors; RX FIFO equality |
| SPI controller | `cocotbext-spi.SpiSlaveBase` | mode 0, MSB first; random CLKDIV 7/13/31 and random full-duplex bytes; verifies MOSI and RX replies |
| SPI peripheral | `cocotbext-spi.SpiMaster` | mode 0; 0.5/1/2 MHz nominal choices, -1/0/+1% clock error; random inter-byte spacing 6–20 us and transaction gaps; queued replies and final default 0xFF; RX equality |
| I2C controller | `cocotbext-i2c.I2cMemory` | CLKDIV 17/35/68, random memory pointer/data, ACK, last-byte NACK, repeated START, STOP; independent 5–20 us low-phase stretches on random falling edges; memory and RX comparisons |
| I2C target | `cocotbext-i2c.I2cMaster` plus documented stretch sampling correction | both engines, target+watcher, shared flags; 100/200/400 kbit/s nominal choices and -1/0/+1%; host service latency stretches SCL; address 0x50 write/read and byte equality |

For the recorded default seed, the peripheral also passes at approximately
2.02 MHz (+1% on 2 MHz). This is one simulated margin case and does not expand
the program's documented approximate 2 MHz operating limit. The random settings
are selections, not an exhaustive cross-product. The core model and ISA coverage
belong to Phase 1; these protocol tests do not measure opcode coverage.

Not covered here: modes 1–3, other UART frame formats, I2C arbitration,
address-NACK policy, simultaneous unrelated protocols, malformed electrical
waveforms, exhaustive baud/divider ranges, FIFO saturation, or physical timing.
Existing SystemVerilog tests cover some of these separately.

## Third-party compatibility and observed issues

No RTL bug was found by this endpoint suite. The following issues occurred in
the verification tools/harness; code-before/code-after and reproductions are
included so the main BUG_LOG can track them without changing the design.

### cocotbext-spi 0.5.0 and cocotb 2

Before: `from cocotb.clock import BaseClock` raises `ImportError`; after:
the test module restores the legacy base's signal-retaining constructor before
importing the unchanged installed library. Before: the SPI endpoint reads
`scalar.value.integer`, raising `AttributeError` on cocotb 2's `Logic`; after:
a local compatibility property returns `int(value)`. Before: its SPI clock uses
`get_sim_steps(period_in_seconds)` on floating-point reciprocals, raising
`ValueError: Unable to accurately represent ...`; after: a local subclass
passes the period as an even integer number of picoseconds to the same library
clock implementation. Wire shifting and byte assembly remain third-party code.

Failing regression: `run.py --cases 1 --test spi_controller --stock-spi`
(ImportError, nonzero). Passing regression: omit `--stock-spi`; both SPI tests
pass under cocotb 2. The initial intermediate scalar/clock errors and their
corrections are also exercised by the same two passing tests.

### cocotbext-i2c 0.1.2 samples before the stretched high phase

The stock `I2cMaster.recv_bit()` samples SDA before releasing SCL and waiting for
the actual high phase:

```python
await self._half_bit_t
b = bool(int(self.sda.value))
self._set_scl(1)
while not int(self.scl.value):
    await RisingEdge(self.scl)
```

The target may still be stretching while its host queues the first bit. The
test-only `StretchAwareMaster` moves the sample after that wait:

```python
await self._half_bit_t
self._set_scl(1)
while not int(self.scl.value):
    await RisingEdge(self.scl)
b = bool(int(self.sda.value))
```

Failing regression:
`run.py --seed 20261029 --cases 1 --test i2c_target --stock-i2c`.
Expected `d5637ebf`, observed stock `55e3febf` (first data bit sampled during
host-response stretching). Passing regression: the identical command without
`--stock-i2c`, expected and observed `d5637ebf`. This is an explicitly adapted
third-party master, not a claim that the stock master passed.

### Harness issues corrected during bring-up

1. Before: runner trusted `runner.test()` and returned 0 after an import failure.
   After: remove old results, require a new XML with at least one test and no
   failure/error. The `--stock-spi` reproducer proves nonzero exit; all positive
   tests prove the normal exit path.
2. Before: UART TX waited `12 * bit_clocks` then read six bytes, producing
   `QueueEmpty` with only two complete characters. After: wait
   `(len(data)+1) * 12 * bit_clocks`; `uart_tx`, same seed/case, passes.
3. Before: target service sampled RX_COUNT once, then FLAGS; an address could
   arrive between them, causing address `a0` to appear among payload bytes.
   After: when FLAG2 is set, recheck/drain RX_COUNT before classifying a request.
   `i2c_target`, same seed/case, then receives exactly `2f7da1c26b`.
4. Before: a subclass delayed the memory library's `handle_read()` while its
   base asserted SCL low during the high phase, creating a spurious clock edge;
   controller read expected `1a31ca40`, observed `1a63ffff`. After: use stock
   memory callbacks and a separate stretcher that asserts only following an
   existing SCL falling edge. Same seed/case passes with 30 random stretches.
   This rejects an invalid test stimulus, rather than weakening a DUT assertion.

## Recorded environment and outcome

Python 3.10.14; Icarus Verilog/VVP 12.0 stable; cocotb 2.0.1;
cocotbext-uart 0.1.4; cocotbext-spi 0.5.0; cocotbext-i2c 0.1.2;
cocotb-bus 0.3.0; find_libpython 0.5.1; scapy 2.8.0.

Default seed `20261029`, 3 cases per endpoint: **6 tests, 18 cases passed**;
21.09738366 ms simulation in 59.27 s wall time. The later SPI spacing
randomization is checked by a separate three-case SPI-peripheral rerun; see
`verify/golden-model/bus_models/results.json` for its recorded status and the expected-failure
regressions. These times are observations on this host, not CI runtime promises.
The final source also passes all six endpoint tests with `--cases 1` in 19.61 s;
the build directory is left with that successful `results.xml`.

Upstream sources used to inspect the endpoint APIs and compatibility:
[UART](https://github.com/alexforencich/cocotbext-uart),
[SPI](https://github.com/schang412/cocotbext-spi),
[I2C](https://github.com/alexforencich/cocotbext-i2c).

Next: expand seeds and boundary timing; add SymbiYosys proofs for FIFO, host SPI
and line coder invariants, catalogue-grounded CRC vectors, and Verilator coverage.

Final-source confirmation: `make test-buses CASES=3 BUS_SEED=20261029` passed
all six tests / 18 cases, including the final randomized SPI gaps, in 61.18 s
(command wall time), with 21.32120333 ms simulated. See
`verify/golden-model/evidence/phase3/results.json` for settings and summary.
