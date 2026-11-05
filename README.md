# Jane Street protocol emulator ASIC

Entry for the Jane Street protocol emulator ASIC competition (Tiny Tapeout, IHP CMOS5L 130 nm,
up to 6×4 tiles, due 18 January 2027).

| Folder | What |
|---|---|
| `src/` | The RTL (SystemVerilog) and the Tiny Tapeout flow configuration `config.json`; `pbe_v1/src` links here |
| `info.yaml`, `docs/info.md`, `test/` | Tiny Tapeout project description, datasheet page, and the cocotb test that also runs on the gate-level netlist |
| `.github/workflows/` | `gds` (Tiny Tapeout flow: LibreLane place and route for IHP CMOS5L, precheck, gate-level test), `test` (cocotb), `docs`, `regression` (`pbe_v1` `make test` and a Verilator lint) |
| `pbe_v1/` | Programmable Bit Engine: two engines with CRC, parity, timeout and line-coder hardware, the protocol programs (see Protocols below), the testbenches and the assembler |
| `diagrams/pbe-diagrams.html` | Block diagrams and instruction format (open in a browser) |
| `verify/` | Independent verification (D63, D64): the golden model, differential, sigrok and bus-model checks (`verify/golden-model/`, with the reports and evidence), formal properties, reference vectors, coverage, stress and mutation testing; run from `pbe_v1/` with `make` |
| `macros/`, `sram/` | The proposed SRAM program memory (D62): IHP's macro views, and the flow change set (`docs/SRAM_INVESTIGATION.md`) |
| `ihp_lib/` | IHP sg13g2 standard-cell timing libraries, used by `make synth` and `make timing` |

## Protocols: 13 implemented and tested

Every protocol is a program loaded at run time into the engines' program memory (64 words
per engine window); none is a fixed hardware block. Each has an end-to-end testbench in
`pbe_v1/test`, run by `make test`.

| # | Protocol | Program (words) | What is tested |
|---|---|---|---|
| 1 | UART TX and RX | `uart_tx` (8), `uart_rx` (8) | Loopback between the two engines; also on the routed netlist (cocotb) |
| 2 | SPI controller | `spi_ctrl` (16) | Against a mode-0 peripheral model |
| 3 | SPI peripheral | `spi_periph` (21) | Driven by a controller model at 2 MHz |
| 4 | I2C controller | `i2c_ctrl` (34) | Write, read with repeated START, NACK, clock stretching |
| 5 | SMBus PEC | `i2c_ctrl` + CRC unit as CRC-8 | Write Word and Read Word with PEC checked both ways |
| 6 | I2C target | `i2c_target` (58) + `i2c_watch` (8) | A fast-mode controller reading and writing the target |
| 7 | 1-Wire controller | `onewire_ctrl` (36) | Two DS18B20-style devices: Search ROM, CRC-8, CONVERT T with strong pull-up |
| 8 | Modbus RTU master (RS-485) | `modbus_rtu` (62) | Hardware CRC-16, parity and timeout; 1.5-character gap rule; 19200 and 115200 baud |
| 9 | WS2812 LEDs | `ws2812` (8) | Bit timing at 800 kbit/s |
| 10 | USB 1.1 low-speed device | `usb_dev` (64) | Full enumeration by a host model: SET_ADDRESS, stall, NAK, resend, bus reset, stuffing and CRC errors |
| 11 | CAN 2.0A node (2.0B tolerant) | `can_node` (61) | Against reference CAN nodes: 125k-1 Mbit/s, arbitration, ACK, error frames, error-passive and bus-off, extended frames, two engines as two nodes |
| 12 | JTAG controller | `jtag` (42) | Against an IEEE 1149.1 TAP model: IDCODE, BYPASS, DR scans, a chain of two TAPs |
| 13 | ARM SWD host | `swd` (64) | Against an ADIv5 SW-DP model: DPIDR, DP/AP access, WAIT, FAULT, parity errors |

Two protocols can run at once, one per engine (e.g. JTAG and SWD, or I2C and 1-Wire), and
both engines can be CAN nodes.

## Verification in brief

The design is checked by several independent layers; details in
[`docs/AI_ASSISTED_DESIGN.md`](docs/AI_ASSISTED_DESIGN.md) and [`verify/README.md`](verify/README.md).

| Layer | What it shows |
|---|---|
| Directed testbenches (`pbe_v1/test`, 11 benches) | Every protocol end to end against a model of the device on the other side of the wire |
| Gate level | The full testbenches on the routed netlist from the Tiny Tapeout flow (`gl_regression`), and the cocotb test in `gl_test` |
| Golden model + random differential testing | A Python model written from the specification, compared every clock with the RTL on random programs and host traffic |
| Independent decoders and bus models | sigrok's stock decoders (UART, SPI, I2C, 1-Wire, Modbus, WS2812, USB, CAN, JTAG, SWD) and third-party cocotb bus models agree with the testbenches |
| Formal (SymbiYosys) | Full proofs for the FIFO and the host SPI port; bounded checks for the line coder, the engine and CAN mode; every expected result matches (113 tasks) |
| Mutation testing | 24 deliberately injected RTL bugs, all caught by the test suite |
| Reference vectors | 22 CRC configurations from the reveng catalogue; USB and Modbus packets from independent libraries |
| Functional coverage and stress | 92/92 functional coverage bins (round 2); clock error, glitches, a slow host and both engines at once (22/22) |
| Lint and CI | Verilator `-Wall` lint and `make test` on every push |

Every design decision is recorded with its alternatives in
[`docs/DESIGN_DECISIONS.md`](docs/DESIGN_DECISIONS.md) (79 so far), and every bug with the code
before and after and the test that caught it in [`docs/BUG_LOG.md`](docs/BUG_LOG.md) (101 so far).
Open: the coverage run with the new CAN bins is pending, because one CAN unit test gives a
one-clock different result under Verilator than under Icarus, which is being investigated.

`pbe_v1/README.md` has the register map, instruction set, host protocols and results.
Design reasoning is in `docs/DESIGN_DECISIONS.md` and every bug with its fix in `docs/BUG_LOG.md`.
A low-speed USB version (v2) was built and then retired to keep the engine general; its code is
on the branch `archive/v2-usb` and its lessons are in `docs/USB_NOTES.md`.
Tools: `iverilog`, `yosys`, `python3`. In `pbe_v1/`: `make test`, `make synth`, `make timing`.
In `test/`: `make` runs the Tiny Tapeout cocotb test (needs `cocotb`).

## Write-ups

- [`docs/AI_ASSISTED_DESIGN.md`](docs/AI_ASSISTED_DESIGN.md): how the design was built and
  verified with AI agents: the workflow, the rules that keep it honest, the bug log in numbers,
  the verification layers, and where the AI went wrong.
- [`docs/PIO_PRU_COMPARISON.md`](docs/PIO_PRU_COMPARISON.md): what the PBE does differently from
  the RP2040 PIO and TI's PRU-ICSS, what they do better, and what our architecture makes
  possible.

## Tiny Tapeout

The top module is `tt_um_ayushyadavnvs_pbe` (6×4 tiles, 48 MHz, `CLOCK_PERIOD` 20.833 ns). The
Tiny Tapeout flow runs on GitHub Actions (`gds` workflow, started by hand while the RTL is
being finished): LibreLane synthesis, place and route, timing and DRC for IHP `sg13cmos5l`,
the Tiny Tapeout precheck, and the cocotb test on the routed netlist. `gl_regression` then runs
the full testbenches on the routed netlist. The first full run (commit df2e881) passed both.

## Clock frequency

The competition rules I could find set no clock frequency. Tiny Tapeout sets the ceiling:
the clock input pad is specified up to about 66 MHz, and the demo board's RP2040 can generate
1 Hz to 66.5 MHz (tinytapeout.com/specs/clock).

| | Value |
|---|---|
| Logic limit (slow corner, ABC estimate) | ~4.9 ns per cycle, before wire delay |
| Routed worst setup path (slow corner) | ~20.3 ns, 0.586 ns slack at 48 MHz |
| Tiny Tapeout limit | ~66 MHz |
| Planned clock | 48 MHz: USB low speed is exactly 32 clocks per bit, timing is met at every corner, but with little slack at the slow corner (D45) |

The design works at any clock up to that limit; each engine's `CLKDIV`
turns the clock into the bit rate a protocol needs.

| Results, version 1 | Area (6×4 = 916,229 µm²) | Worst path, slow corner | Setup / hold slack, slow corner |
|---|---|---|---|
| Estimate (Yosys + ABC, before place and route) | 333,913 µm² (36 %) | 4.33 ns (logic only) | — |
| Routed (first full run, commit df2e881) | 44.3 % utilization, incl. 3,590 hold-fix cells | ~20.3 ns | 0.586 ns / 0.602 ns |

The estimate left out wires; the routed path is dominated by the program counter's fan-out into
the program-memory read multiplexer. All corners, warnings and the analysis are in
`docs/DESIGN_DECISIONS.md` D45.
