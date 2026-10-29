# Jane Street protocol emulator ASIC

Entry for the Jane Street protocol emulator ASIC competition (Tiny Tapeout, IHP CMOS5L 130 nm,
up to 6×4 tiles, due 18 January 2027).

| Folder | What |
|---|---|
| `src/` | The RTL (SystemVerilog) and the Tiny Tapeout flow configuration `config.json`; `pbe_v1/src` links here |
| `info.yaml`, `docs/info.md`, `test/` | Tiny Tapeout project description, datasheet page, and the cocotb test that also runs on the gate-level netlist |
| `.github/workflows/` | `gds` (Tiny Tapeout flow: LibreLane place and route for IHP CMOS5L, precheck, gate-level test), `test` (cocotb), `docs`, `regression` (`pbe_v1` `make test` and a Verilator lint) |
| `pbe_v1/` | Programmable Bit Engine: two engines with CRC, parity, timeout and line-coder hardware; programs for UART, SPI controller and peripheral, I2C controller and target, SMBus PEC, 1-Wire, Modbus RTU, WS2812 and a USB low-speed device, all tested |
| `diagrams/pbe-diagrams.html` | Block diagrams and instruction format (open in a browser) |
| `ihp_lib/` | IHP sg13g2 standard-cell timing libraries, used by `make synth` and `make timing` |

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
