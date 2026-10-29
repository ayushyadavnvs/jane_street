# Round 2 optional stress characterization

Scope: UART timing/disturbances, slow UART RX service, and simultaneous UART TX
plus SPI-controller transfers with repeated engine restart. This is a separate
verification-only campaign; no canonical bench, RTL behavior, protocol program or
physical-design flow is changed. A finite successful campaign is not a proof of
all protocol robustness or hardware operation.

## Method and run modes

`test/stress/stress_top.sv` provides an external pin-only fixture. The suite reuses
`Chip` host-SPI/program-loading helpers and the independent
[cocotbext-uart](https://github.com/alexforencich/cocotbext-uart) sink and
[cocotbext-spi](https://github.com/schang412/cocotbext-spi) peripheral adapters from
the existing bus tests. The custom UART stimulus adds explicit timing disturbances
to a known byte sequence; it is a stimulus generator, not an expected-output model.
Expected bytes are fixed/seeded and compared with host FIFO reads or the external
UART/SPI receivers. No internal engine state steers stimulus or expectations.

The chip clock is 20834 ps (nearest even integer picoseconds to 48 MHz). Nominal UART
bits last 96 chip clocks, approximately 500 kbaud. The default seed is `0x50424534`.
A 200ms simulation-time driver watchdog, 1ms caller read deadlines and bounded
count-qualified FIFO-drain loops guard the harness. A driver timeout is a test
failure, not evidence that the protocol program recovered or reported an error.
No deadline fired in the recorded completed characterization.

From `pbe_v1/`, with the bus-test dependencies installed:

```sh
../.venv/bin/python test/stress/run.py --required-only
../.venv/bin/python test/stress/run.py --characterize
../.venv/bin/python test/stress/run.py  # strict: the five observed failures stay nonzero
```

The full characterization has33 observations: 28 PASS and 5 FAIL. Characterization
mode allows evidence collection to finish while preserving those FAIL labels;
it does not turn failures into expected passes. The strict evaluator returns 1 on
that same evidence. Required-only selects 22 baseline stress observations and
excludes the larger mismatch/data-glitch exploration. The cocotb XML PASS means
only that the observation driver completed; the runner additionally checks the
number and outcome of all observations before returning success.

## Observed timing and disturbance boundary

For the eight-byte pattern `00 ff 55 aa 81 7e 03 c0`, UART RX passed the sampled
clock-error points ±2%,±3%,±4% and±5%. The first failing sampled points were±6%;
±8% failed too. These sparse points bound this tested pattern/settings, not every
phase, payload or baud rate. No binary search or exhaustive timing margin is
claimed. UART TX was independently sampled by the library at±2% and matched.

At±2% average clock error, additional independent per-bit jitter uniformly bounded
by ±2% also passed for the recorded seed. Four-chip-clock delayed rising threshold
crossings (83.336 ns) passed. This "slow edge" model changes a digital crossing
time within its bit cell; it does not model analog slew, pad thresholds,
metastability, electrical noise or receiver hysteresis.

A one-chip-clock idle-low pulse was rejected by the program's start qualification;
all following bytes matched. A one-chip-clock pulse centered in the first byte's
fourth data-bit cell changed `00` to `08`. That FAIL remains visible. The UART program
uses one sample per data bit and provides no oversampling majority vote or UART
framing-error record. At larger clock errors it also returns incorrect bytes
without a dedicated UART error indication. General engine parity/CRC status bits
are not valid UART 8N1 framing diagnostics because this program does not sample a
parity bit. This is an observed application-program limitation under deliberately
corrupted/out-of-margin input; it is not an established RTL/spec disagreement.
No claim that every corrupt UART stream fails cleanly is made.

## Slow host and mixed-engine behavior

The host leaves UART RX unserviced through an entire burst and another 1 ms, then
waits 100 bit times between individual FIFO reads. A 16-byte burst remains lossless.
With 20 incoming bytes, the FIFO holds 16 and a blocking PUSH retains the seventeenth
byte. The final three bytes arriving while execution is blocked are not captured.
The exact first 17 bytes are recovered, sticky RX-overflow status is set
(`STATUS=0x0b`) and IRQ is asserted. This matches the specified overflow indication
and blocking behavior; it is not labeled lossless. A subsequently sent `42` byte is
received correctly after draining, without a restart, demonstrating recovery in
this particular scenario. It does not establish an unbounded host-service delay
or maximum sustainable stream rate.

Twelve mixed rounds load the unmodified UART TX program on engine 0 and SPI
controller on engine 1, with disjoint pin ownership. Every round restarts and
flushes both engines, then checks four UART bytes, four SPI MOSI bytes and four
SPI MISO replies exactly. Restarts here occur between completed transfers; they
do not establish atomicity when restarting mid-byte. The final required run also
counts chip clocks where the external UART sink is active while SPI CS is low,
requiring a positive overlap count for each round. Measured overlap ranged
1336 chip clocks per round.

An additional identical-source differential campaign uses the existing random
program generator, including both engines, asynchronous pin changes, host traffic,
restart operations and running program-memory writes. It runs in an isolated
`/tmp` copy to avoid sharing the main gate's build directory. It passed **8 seeds, 276,039 compared clocks**, with
5,000 random-stimulus iterations per seed, in 54.47 s. Its results are
reported separately; random programs are not claimed to implement named protocols.

## Individual characterization observations

| Case | Result | Observed detail |
|---|---|---|
| uart_rx_clock_minus2 | PASS | exact bytes |
| uart_rx_clock_plus2 | PASS | exact bytes |
| uart_rx_clock_minus2_jitter2 | PASS | exact bytes |
| uart_rx_clock_plus2_jitter2 | PASS | exact bytes |
| uart_rx_digital_rise_delay4 | PASS | exact bytes |
| uart_rx_idle_glitch_1clock | PASS | exact bytes |
| uart_rx_data_glitch_1clock | FAIL | actual `08ff55aa817e03c0` |
| uart_rx_clock_-3% | PASS | exact bytes |
| uart_rx_clock_+3% | PASS | exact bytes |
| uart_rx_clock_-4% | PASS | exact bytes |
| uart_rx_clock_+4% | PASS | exact bytes |
| uart_rx_clock_-5% | PASS | exact bytes |
| uart_rx_clock_+5% | PASS | exact bytes |
| uart_rx_clock_-6% | FAIL | actual `00ffd52a01fe03c0` |
| uart_rx_clock_+6% | FAIL | actual `80ffd5aa81fe83c0` |
| uart_rx_clock_-8% | FAIL | actual `00f7b5a77dc0fe3778e0` |
| uart_rx_clock_+8% | FAIL | actual `80ffb5cac1be83e0` |
| uart_tx_clock_-2% | PASS | exact bytes |
| uart_tx_clock_+2% | PASS | exact bytes |
| uart_rx_slow_host_16 | PASS | RX count 16, status 0x02, IRQ 0, 0 incoming bytes lost; recovery 42 |
| uart_rx_slow_host_20 | PASS | RX count 16, status 0x0b, IRQ 1, 3 incoming bytes lost; recovery 42 |
| concurrent_uart_spi_restart_0 | PASS | UART, SPI MOSI and SPI MISO exact; both engines restarted |
| concurrent_uart_spi_restart_1 | PASS | UART, SPI MOSI and SPI MISO exact; both engines restarted |
| concurrent_uart_spi_restart_2 | PASS | UART, SPI MOSI and SPI MISO exact; both engines restarted |
| concurrent_uart_spi_restart_3 | PASS | UART, SPI MOSI and SPI MISO exact; both engines restarted |
| concurrent_uart_spi_restart_4 | PASS | UART, SPI MOSI and SPI MISO exact; both engines restarted |
| concurrent_uart_spi_restart_5 | PASS | UART, SPI MOSI and SPI MISO exact; both engines restarted |
| concurrent_uart_spi_restart_6 | PASS | UART, SPI MOSI and SPI MISO exact; both engines restarted |
| concurrent_uart_spi_restart_7 | PASS | UART, SPI MOSI and SPI MISO exact; both engines restarted |
| concurrent_uart_spi_restart_8 | PASS | UART, SPI MOSI and SPI MISO exact; both engines restarted |
| concurrent_uart_spi_restart_9 | PASS | UART, SPI MOSI and SPI MISO exact; both engines restarted |
| concurrent_uart_spi_restart_10 | PASS | UART, SPI MOSI and SPI MISO exact; both engines restarted |
| concurrent_uart_spi_restart_11 | PASS | UART, SPI MOSI and SPI MISO exact; both engines restarted |

## Evidence, tools and remaining scope

Selected raw logs, per-case observations, strict evaluator exits and the separate
differential receipt are under `verification/evidence/round2/stress/`. The full
initial 33-case observation driver took 115.18 s wall clock and 28.649 ms simulation
time. The final required-only run passed 22/22 cases in 58.94 s (20.305 ms
simulation time). Strict reevaluation of the full observations exits 1;
required-only and explicit characterization reevaluations exit 0. Exact exits and
commands are retained in `stress_exit_checks.json`.
Tools are Python 3.10.12, cocotb 2.0.1, cocotbext-uart 0.1.4,
cocotbext-spi 0.5.0 with the documented local compatibility adapter, and
Icarus/vvp 12.0 stable. No dependency installs occur in the target.

This optional campaign does not measure I2C, Modbus, USB, 1-Wire or WS2812 stress
margins. Their earlier functional/vector tests are separate evidence. It does not
sweep glitch phase/width, parity/stop corruption, supply or analog slew, host SPI
clock margins, every protocol program under FIFO starvation, or restart at every
instruction/packet boundary. Those omissions prevent a universal "never hangs"
claim. Next extend bounded recovery/error checks protocol-by-protocol, especially
UART framing/error reporting and exhaustive glitch phase sweeps, then measure
physical pins separately. The five mismatch observations require application-level
handling or an explicit operating envelope before any stronger reliability claim.

## BUG-070: evidence-launcher interpreter symlink resolution

An ad hoc evidence reevaluation initially launched
`str(Path(sys.executable).resolve())`. Resolving the virtualenv's Python symlink
selected `/usr/bin/python3.10`, which omitted the virtualenv packages. Strict,
required-only and characterization checks all exited 1 with
`ModuleNotFoundError: No module named 'cocotb_tools'`; this was an environment
launcher failure, not a DUT stress outcome. The actual simulation commands had
already used the correct virtualenv interpreter.

After: launch `sys.executable` unchanged. Repeating the same three reevaluations
returns the expected strict 1, required-only 0 and characterization 0, with the
correct per-case summaries. Exact before commands/errors are in
`stress_bug070_before_launcher.json`; after commands/output/exits are in
`stress_exit_checks.json`. No dependency reinstall, source/RTL change or failure
waiver was used. This fix concerns the evidence-export invocation, rather than
protocol test behavior.

The initial full characterization preceded the added whole-driver watchdog and
mixed-round overlap counter; the final required-only rerun uses both. Timing
stimulus, expected byte comparisons and adverse-case labels are unchanged.
