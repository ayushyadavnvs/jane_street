# Jane Street protocol emulator ASIC

Entry for the Jane Street protocol emulator ASIC competition (Tiny Tapeout, IHP CMOS5L 130 nm,
8×4 tiles, due 18 January 2027).

| Folder | What |
|---|---|
| `src/` | The RTL (SystemVerilog) and the Tiny Tapeout flow configuration `config.json`; `pbe_v1/src` links here |
| `info.yaml`, `docs/info.md`, `test/` | Tiny Tapeout project description, datasheet page, and the cocotb test that also runs on the gate-level netlist |
| `.github/workflows/` | `gds` (Tiny Tapeout flow: LibreLane place and route for IHP CMOS5L, precheck, gate-level test), `test` (cocotb), `docs`, `pages` (the website), `regression` (`pbe_v1` `make test`, a Verilator lint and `make test-verilator`) |
| `pbe_v1/` | Programmable Bit Engine: two engines with CRC (up to 32 bits), parity, timeout and line-coder (NRZ, NRZI, Manchester) hardware, the protocol programs (see Protocols below), the testbenches and the assembler |
| `diagrams/pbe-diagrams.html` | Block diagrams and instruction format (open in a browser) |
| `site/` | The project website (D105): `site/build.py` builds it from this repository and the latest GDS run; the `pages` workflow publishes it to GitHub Pages with the 3D layout viewer |
| `verify/` | Independent verification (D63, D64): the golden model, differential, sigrok and bus-model checks (`verify/golden-model/`, with the reports and evidence), formal properties, reference vectors, coverage, stress and mutation testing; run from `pbe_v1/` with `make` |
| `macros/` | The program memory's SRAM macro (D62, D82): IHP's views and simulation model; the flow steps are in `docs/SRAM_8x4_FLOW_STEPS.md` |
| `docs/STATUS.md` | Where the project stands: what `main` contains, open branches and issues, the plan |
| `ihp_lib/` | IHP sg13g2 standard-cell timing libraries, used by `make synth` and `make timing` |

## Protocols: 27 implemented and tested

Every protocol is a program loaded at run time into the engines' program memory (up to 256
words per engine, D82, D83); none is a fixed hardware block. Each has an end-to-end testbench in
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
| 14 | PS/2 host (keyboard, mouse) | `ps2_host` (74) | Against a keyboard model: scan codes, 0xED LEDs with 0xFA ACKs, reset, ID, parity and framing errors, no ACK, timeout |
| 15 | 24-bit GPIO expander (74HC595 / 74HC165) | `gpio_expander` (33) | Against 74HC595 and 74HC165 models chained 3 deep: random exchanges at 6.9 and 2 MHz, input snapshot, latched outputs, setup and hold |
| 16 | Logic analyser and waveform generator | `la_capture` (30), `wavegen` (16) | 4 channels with level/edge triggers against an independent stimulus, bursts to 4 MS/s, sustained 1 MS/s with the host reading, overflow reported; the generator's edges timestamped on their grid at up to 6 MS/s |
| 17 | Quad SPI controller (flash) | `qspi_flash` (125) | Against a quad SPI NOR flash model: JEDEC ID, 0x03, 0x0B, 0x6B (1-1-4), 0xEB (1-4-4), quad page program, at 16/6 MHz SCK (single/quad) |
| 18 | HDLC / SDLC (NRZ and NRZI) | `hdlc_tx` (41), `hdlc_rx` (43) | Against an ISO 13239 model: flags, zero-bit insertion/deletion, CRC-16/X.25, back-to-back frames, CRC error, aborts, NRZI line coding (D94); 1-2 Mbit/s both ways, 4 Mbit/s transmit |
| 19 | 10BASE-T Ethernet | `eth_tx` (52), `eth_rx` (17) | Against an IEEE 802.3 link-partner model: frames of 64-1518 bytes both ways with the FCS (CRC-32) in hardware, Manchester at 10 Mbit/s, clock offset and edge jitter, link pulses, loopback, TX underrun and RX overrun reported (D93, D101) |
| 20 | DMX512 transmitter | `dmx512_tx` (18) | Blind benchmark: against an E1.11 receiver: break, mark after break, 513 slots |
| 21 | MIDI in and out | `midi_in` (85), `uart_tx` | Blind benchmark: running status expanded in the engine, checked against a MIDI 1.0 reference parser |
| 22 | LIN 2.x commander | `lin_commander` (49) | Blind benchmark: against a LIN 2.2A responder; the host computes ID parity and checksum (no adder) |
| 23 | IR NEC remote, TX and RX | `ir_nec_tx` (103), `ir_nec_rx` (48) | Blind benchmark: 38 kHz carrier, frames, repeat code, ±5 % timing; TX uses a scratch pin |
| 24 | Wiegand 26 / 34 reader | `wiegand` (92) + `wiegand_watch` (12) | Blind benchmark: both parity checks, 20-100 µs pulses; uses both engines |
| 25 | I2S transmitter | `i2s_tx` (119) | Blind benchmark: 16-bit stereo at 48.08 kHz, every BCLK period equal, against a Philips-format receiver |
| 26 | DShot600 transmitter | `dshot600` (64) | Blind benchmark: exact 1.667 µs bits, the checksum from the CRC unit, against an ESC-side decoder |
| 27 | MDIO controller (clause 22) | `mdio` (73) | Blind benchmark: against a PHY with a 300 ns output delay, 2 MHz |

Protocols 20-27 are the **blind generality benchmark** ([`docs/GENERALITY.md`](docs/GENERALITY.md)):
eight protocols listed and committed before any attempt, written as programs with no RTL
change. All eight run (four with a stated limit); SPI modes 1-3 were added the same way.

Two protocols can run at once, one per engine (e.g. JTAG and SWD, or I2C and 1-Wire), and
both engines can be CAN nodes. An engine-to-engine FIFO link (D102, off by default) lets one
engine hand its received bytes straight to the other: the UART ↔ I2C bridge (`bridge_uart`,
`bridge_i2c`, D103, tested in `tb_bridge`) turns commands on a UART into I2C transactions
with no host in the loop.

## Verification in brief

The design is checked by several independent layers; details in [`verify/README.md`](verify/README.md).

| Layer | What it shows |
|---|---|
| Directed testbenches (`pbe_v1/test`, 22 benches) | Every protocol end to end against a model of the device on the other side of the wire |
| Gate level | The full testbenches on the routed netlist from the Tiny Tapeout flow (`gl_regression`), and the cocotb test in `gl_test` |
| Golden model + random differential testing | A Python model written from the specification, compared every clock with the RTL on random programs and host traffic (the Ethernet round: 1,000 seeds, about 21 million clocks) |
| Independent decoders and bus models | sigrok's stock decoders (UART, SPI, I2C, 1-Wire, Modbus, WS2812, USB, CAN, JTAG, SWD, PS/2) and third-party cocotb bus models agree with the testbenches |
| Formal (SymbiYosys) | Full proofs for the FIFO and the host SPI port; bounded checks for the line coder, the engine, CAN mode and the Manchester receiver; every expected result matches (one induction proof of the Manchester timer's range is still open, BUG-165) |
| Mutation testing | Deliberately injected RTL bugs, all caught by the test suite: 24 in the core, 14 more in the Ethernet hardware |
| Reference vectors | CRC configurations up to 32 bits from the reveng catalogue; USB, Modbus, HDLC and Ethernet frames from independent references |
| Functional coverage and stress | 130/130 functional coverage bins under Verilator 5.051 (line 98.5 %, branch 94.5 %), and 219/219 for the Ethernet round; clock error, edge jitter, glitches, a slow host and both engines at once |
| Two simulators | `make test-verilator`: unit benches under Icarus and Verilator must give identical logs, in CI (D80) |
| Lint and CI | Verilator `-Wall` lint, the unit benches under Verilator and Icarus with identical logs (a race check, D80), and `make test` on every push |

Every design decision is recorded with its alternatives in
[`docs/DESIGN_DECISIONS.md`](docs/DESIGN_DECISIONS.md) (104 so far), and every bug with the code
before and after and the test that caught it in [`docs/BUG_LOG.md`](docs/BUG_LOG.md) (174 so far).
A one-clock difference between Icarus and Verilator in one CAN unit test turned out to be a
testbench race (BUG-102); fixing it also exposed a real reset bug in the line coders (BUG-104).

`pbe_v1/README.md` has the register map, instruction set, host protocols and results.
Design reasoning is in `docs/DESIGN_DECISIONS.md` and every bug with its fix in `docs/BUG_LOG.md`.
A low-speed USB version (v2) was built and then retired to keep the engine general; its code is
on the branch `archive/v2-usb` and its lessons are in `docs/USB_NOTES.md`.
Tools: `iverilog`, `yosys`, `python3`. In `pbe_v1/`: `make test`, `make synth`, `make timing`.
In `test/`: `make` runs the Tiny Tapeout cocotb test (needs `cocotb`).

## Write-ups

- [`docs/PIO_PRU_COMPARISON.md`](docs/PIO_PRU_COMPARISON.md): what the PBE does differently from
  the RP2040 PIO and TI's PRU-ICSS, what they do better, and what our architecture makes
  possible.

## Tiny Tapeout

The top module is `tt_um_ayushyadavnvs_pbe` at **60 MHz** (`CLOCK_PERIOD` 16.667 ns, D92) on
**8×4 tiles**. The program memory is an IHP SRAM macro per engine (256 words each, D82);
`info.yaml` and `src/config.json` place and power the two macros as
`docs/SRAM_8x4_FLOW_STEPS.md` explains. The host port is SPI with 1 or 4 data lanes (D89).

The Tiny Tapeout flow runs on GitHub Actions (`gds` workflow, started by hand while the RTL is
being finished): LibreLane synthesis, place and route, timing and DRC for IHP `sg13cmos5l`,
the Tiny Tapeout precheck, and the cocotb test on the routed netlist. `gl_regression` then runs
the full testbenches on the routed netlist.

The SRAM power step (`librelane_plugin_sram_pdn.py`, `odb_stripes.py`), `src/pdn_cfg.tcl` and
`src/sram_bb.v` come from Tiny Tapeout's `ttihp-cmos5l-sram-example` (Apache-2.0), adapted
from Ken Pettit's `ihp-um-janestreet-prism`.

## Clock frequency and layout results

The competition rules I could find set no clock frequency. Tiny Tapeout sets the ceiling:
the clock input pad is specified up to about 66 MHz, and the demo board's RP2040 can generate
1 Hz to 66.5 MHz (tinytapeout.com/specs/clock). 60 MHz gives 10BASE-T exactly 6 clocks per
bit (3 per Manchester half-bit); each engine's `CLKDIV` turns the clock into the bit rate any other protocol
needs.

Latest routed result (GDS run 43698688003, commit d5e4461, 8×4 = 1,225,257 µm², 60 MHz):

| | Slow (1.08 V, 125 °C) | Typical | Fast |
|---|---|---|---|
| Setup slack | +1.19 ns | +2.53 ns | +3.36 ns |
| Hold slack | +0.60 ns | +0.29 ns | +0.11 ns |

| | Value |
|---|---|
| Area | 389,114 µm² of standard cells + 2 × 28,127 µm² of SRAM macros; 36.9 % utilization |
| Checks | Precheck, LVS, antenna and routing DRC clean; the cocotb test and the full testbenches (`gl_regression`) passed on the routed netlist |
| Logic-only worst path (slow corner, Yosys + ABC) | 4.16 ns, in the Ethernet receive clock recovery |

Timing is met at every corner. The slow-corner margin moves with placement (the run before,
without the link, had +0.24 ns), so every RTL change gets a new GDS run. Earlier results (the 48 MHz flip-flop build, D45; the first SRAM build at
48 MHz with +6.81 ns slow-corner slack) are in `docs/DESIGN_DECISIONS.md`.
