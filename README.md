# Jane Street protocol emulator ASIC

Entry for the Jane Street protocol emulator ASIC competition (Tiny Tapeout, IHP CMOS5L 130 nm,
up to 6×4 tiles, due 18 January 2027).

| Folder | What |
|---|---|
| `pbe_v1/` | Programmable Bit Engine: two engines; UART, SPI, I2C, 1-Wire and Modbus RTU programs, all tested |
| `pbe_v2/` | Version 1 plus a low-speed USB line unit and 16-byte FIFOs, USB packets tested both ways |
| `diagrams/pbe-diagrams.html` | Block diagrams and instruction format (open in a browser) |
| `ihp_lib/` | IHP sg13g2 standard-cell timing libraries, used by `make synth` and `make timing` |

Each version has its own README with the register map, instruction set and results.
Design reasoning is in `docs/DESIGN_DECISIONS.md` and every bug with its fix in `docs/BUG_LOG.md`.
Tools: `iverilog`, `yosys`, `python3`. In either version folder: `make test`, `make synth`, `make timing`.

## Clock frequency

The competition rules I could find set no clock frequency. Tiny Tapeout sets the ceiling:
the clock input pad is specified up to about 66 MHz, and the demo board's RP2040 can generate
1 Hz to 66.5 MHz (tinytapeout.com/specs/clock).

| | Value |
|---|---|
| Logic limit (slow corner, ABC estimate) | ~4.9 ns per cycle, roughly 200 MHz before wire delay |
| Tiny Tapeout limit | ~66 MHz |
| Planned clock | 48 MHz: USB low speed is exactly 32 clocks per bit, and timing has ~4× margin |

The design works at any clock up to that limit; each engine's `CLKDIV` (and `BITDIV` for USB)
turns the clock into the bit rate a protocol needs.

| Results | Area (6×4 = 916,229 µm²) | Worst logic path, slow corner |
|---|---|---|
| Version 1 | 143,373 µm² (16%) | 3.97 ns |
| Version 2 | 192,048 µm² (21%) | 3.93 ns |
