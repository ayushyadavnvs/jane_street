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

## Tiny Tapeout

The top module is `tt_um_ayushyadavnvs_pbe` (6×4 tiles, 48 MHz, `CLOCK_PERIOD` 20.833 ns). Every
push runs the Tiny Tapeout flow on GitHub Actions (`gds` workflow): LibreLane synthesis, place
and route, timing and DRC for IHP `sg13cmos5l`, the Tiny Tapeout precheck, and the cocotb
test on the routed netlist.

## Clock frequency

The competition rules I could find set no clock frequency. Tiny Tapeout sets the ceiling:
the clock input pad is specified up to about 66 MHz, and the demo board's RP2040 can generate
1 Hz to 66.5 MHz (tinytapeout.com/specs/clock).

| | Value |
|---|---|
| Logic limit (slow corner, ABC estimate) | ~4.9 ns per cycle, roughly 200 MHz before wire delay |
| Tiny Tapeout limit | ~66 MHz |
| Planned clock | 48 MHz: USB low speed is exactly 32 clocks per bit, and timing has ~4× margin |

The design works at any clock up to that limit; each engine's `CLKDIV`
turns the clock into the bit rate a protocol needs.

| Results (Yosys + ABC estimate, before place and route) | Area (6×4 = 916,229 µm²) | Worst logic path, slow corner |
|---|---|---|
| Version 1 | 333,913 µm² (36%) | 4.33 ns |
