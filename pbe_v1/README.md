# Programmable Bit Engine (PBE)

A reprogrammable protocol emulator for the Jane Street protocol emulator ASIC competition
(Tiny Tapeout, IHP CMOS5L 130 nm). Two small engines run short programs that drive, release
and read 8 bidirectional pins. UART, SPI, I2C and others are programs loaded at runtime.

## Layout

| Path | What |
|---|---|
| `src/tt_um_pbe.sv` | Top level: pin map, register map, program memory, FIFOs, pin mux |
| `src/pbe_engine.sv` | One engine: decoder, PC/branch, timing and timeout, pin unit, X counter, OSR/ISR, parity |
| `src/pbe_crc.sv` | General CRC unit (one per engine) |
| `src/pbe_host_spi.sv` | Host register port (SPI peripheral, mode 0) |
| `src/pbe_fifo.sv` | 4 × 8-bit FIFO |
| `tools/pbe_asm.py` | Assembler: `.pbe` text → 64-word hex image |
| `programs/*.pbe` | UART TX, UART RX, SPI controller, I2C controller, 1-Wire controller, Modbus RTU master |
| `test/tb_pbe.sv` | End-to-end testbench, drives only the chip's pins (waveforms: `vvp sim.vvp +vcd`) |
| `test/tb_engine_restart.sv` | Unit test: restart cancels the instruction in flight |
| `synth/synth.ys.in` | Yosys script for an area estimate with IHP standard cells |

## Run

```sh
make test                                  # Icarus Verilog
make synth                                 # area, IHP library in ../ihp_lib
make timing                                # critical path, slow corner
```

## Pins

| Pin | Use |
|---|---|
| `ui_in[0..2]` | host SCK, CS_n, MOSI (host SCK at most clk / 8) |
| `uo_out[0]` | host MISO |
| `uo_out[1]` | IRQ |
| `uo_out[7:2]` | status: running, RX has data, TX full (per engine) |
| `uio[7:0]` | protocol pins |

The full register map is in the header comment of `src/tt_um_pbe.sv`. Programs are loaded by
writing a byte pointer to `PM_ADDR` (0x06) and then streaming bytes into `PM_DATA` (0x07).
Program memory holds 64 words shared by both engines; each engine has its own start address.

## Instruction set

16 bits: `[15:13] OP | [12:4] ARG | [3:0] DELAY`. Each instruction issues on a tick and then
idles DELAY more ticks. A tick is one clock every (CLKDIV + 1) clocks, set per engine.

| OP | Mnemonic | Does |
|---|---|---|
| 000 | `PIN p, DRV0/DRV1/REL/TOG/OUT/OUTOD/OUTPAR` | Drive, release or toggle a pin; OUT sends the next OSR bit; OUTOD is open drain; OUTPAR sends the parity of the bits sent since the last OSR load. `OUT`/`OUTOD` take an optional `, NOCRC` |
| 001 | `IN p [, NOCRC]` | Shift a pin into the ISR (and the receive parity, and the CRC unless `NOCRC`) |
| 010 | `WAIT p, LOW/HIGH/RISE/FALL` (or `WAIT FLAG n, …`) | Block until true; checked every clock; restarts the tick timer |
| 011 | `JMP [cond,] label` | ALWAYS, X--, PIN_HI, PIN_LO, TX_EMPTY, TX_READY, FLAG0, FLAG1 (6-bit address) |
| 100 | `SET X/OSR, n` | Load the loop counter or the OSR |
| 101 | `PULL` / `PUSH` | TX FIFO → OSR, or ISR → RX FIFO (block when empty/full) |
| 110 | `FLAG n, SET/CLR/IRQ` | Shared flags between engines, or interrupt the host. Action 3 does nothing: the assembler's `NOP` (`0xD800`) |
| 111 | `CRCRST`, `OSRCRC LO/HI`, `STAT`, `JCRCBAD label` | Restart the CRC; load a CRC byte into the OSR; ISR ← {timeout happened, CRC ok, parity error}; jump if the CRC is not zero. Sub-ops 4–7 free |

**Timeout:** if `WAIT`, `PULL` or `PUSH` stays blocked for `TIMEOUT` ticks (engine register
+C/+D, 0 = never), the engine abandons it and jumps to `TIMEOUT_PC` (`LINE_CFG[5:0]`, +E).

**CRC unit:** polynomial (+9/+A), and `CRC_CFG` (+B): width − 1, initial value all ones,
reversed output, fed by `OUT` bits, fed by `IN` bits. "CRC ok" means the register is zero. The
host can restart it and read the status through `STATUS` (+F).

## Flags

Programs use `FLAG0`–`FLAG3`, which are relative to the engine: engine e's FLAG n is physical
flag `(FLAG_BASE + n) mod 8`. By default engine 0 has flags 0–3 and engine 1 has flags 4–7, so
two protocols that use flags can run on the two engines at once. The host sets and clears
single flags with `FLAG_SET` (0x08) and `FLAG_CLR` (0x09), and reads all 8 at `FLAGS` (0x04).
In the host protocols below, "set FLAG1" means the running engine's FLAG1.

## I2C host protocol (`programs/i2c_ctrl.pbe`)

Each I2C byte is two TX FIFO bytes, `[data] [ack]`, and returns two RX FIFO bytes,
`[byte seen on SDA] [ACK bit]`:

| Transfer | data | ack | Returned ACK bit |
|---|---|---|---|
| Write a byte | the byte | `0x80` (release SDA) | 0 = peripheral ACKed, 1 = NACK |
| Read a byte | `0xFF` | `0x00` to ACK, `0x80` to NACK the last byte | what we sent |

Set `FLAG0` for a START or repeated START (it happens when the next byte is queued) and `FLAG1`
for a STOP (it happens right away; the engine clears the flag when done). Only set either while
the TX FIFO is empty. Clock stretching is handled by `WAIT scl, HIGH`. SCL = tick / 7, low for
4 ticks and high for 3. At 48 MHz: `CLKDIV` = 17 for fast mode (381 kHz), 68 for standard mode
(99 kHz).

## 1-Wire host protocol (`programs/onewire_ctrl.pbe`)

Tick = 1 µs (`CLKDIV` = clock in MHz − 1), LSB first, DQ = pin base with a pull-up.

- **Reset/presence:** with the TX FIFO empty, set FLAG0. The engine returns `0x00` if a device
  answered, `0x80` if not, then clears FLAG0.
- **Bytes:** each TX byte becomes 8 slots; the byte seen on DQ comes back. Send `0xFF` to read.
- **Single slots** (Search ROM): set FLAG1 with the TX FIFO empty. Each TX byte is then one slot
  (bit 0), and the bit seen comes back in bit 7.
- Slots are 65 µs: 6 µs low for a 1 or a read, 60 µs low for a 0, sample at 13 µs.

## Modbus RTU host protocol (`programs/modbus_rtu.pbe`)

RS-485 half duplex, 8E1 (or 8O1), any baud rate. Tick = 1/8 bit, LSB first, `JMP_PIN` = 1.
Pins: TX = pin base, RX = base + 1, driver enable = base + 2.
Engine settings: `CRC_POLY` = 0x8005, `CRC_CFG` = 0xFF, `LINE_CFG` = 0x01 (0x81 for odd
parity), `TIMEOUT` = end-of-frame silence in ticks + 9 (3.5 characters = 317 up to 19200 baud,
1.75 ms above). The program must be loaded at word 0 (its timeout routine is word 1).

- **Send:** queue only the data bytes. When the request is queued and the TX FIFO is empty, set
  FLAG1; the engine adds the parity bits, appends the CRC, turns the driver off after the last
  stop bit and clears FLAG1.
- **Receive:** two RX bytes per character, `[data] [status]`: status bit 0 = parity error,
  bit 1 = CRC ok so far (so on the last character: the frame's CRC is correct). At the end of
  the frame the engine sets FLAG2 and raises IRQ.
- FLAG0 is used inside the program.

## Status

- Simulation (`make test`, exits non-zero on any failure), all through the chip's pins:
  0. `NOP` has no side effects.
  1. UART TX → UART RX loopback, 6 bytes, plus an independent UART monitor.
  2. SPI mode 0 full duplex, 3 bytes.
  3. I2C on engine 1 (pins 4–5) while engine 0 sends UART: write 2 registers, read them back
     with a repeated START, and a NACK from a missing address. The peripheral model stretches
     the clock 20 times; removing `WAIT scl, HIGH` from the program makes the test fail.
     Runs at fast-mode speed and checks every SCL low (≥ 1.3 µs) and high (≥ 0.6 µs) phase,
     and that the STOP flag clears only after the STOP.
  4. 1-Wire with two DS18B20-style device models: presence and absence, READ ROM, Search ROM
     finding both devices, MATCH ROM + READ SCRATCHPAD, CRC-8 checked both by the host and by the
     engine's CRC unit (through `STATUS`), and the timing of every low pulse.
  5. Modbus RTU master against an RS-485 device model, using the CRC unit, parity bit and
     timeout: a normal exchange, a response with a parity error, a response with a corrupted CRC
     (both reported by the engine), and an exchange at 115200 baud. The device checks the
     engine-appended CRC, parity, stop bits, driver enable and glitches on the TX line.
  6. Two flag-using protocols at once: a 1-Wire Search ROM on engine 0 while engine 1 runs I2C
     write/read rounds, from two host processes sharing the host port.
  - Unit test: a restart in the same cycle as an instruction cancels its side effects.
  - Shortening the 1-Wire write-0 pulse, never turning the RS-485 driver off, a dead `OUTPAR`,
    a CRC check that always passes, or a timeout that never fires each make the tests fail.
- Area, Yosys with the IHP sg13g2 typical library: 164,095 µm² of cell area. 6×4 tiles are
  1289.28 × 710.64 µm = 916,229 µm², so cells fill about 18%. The CRC unit, parity bit and
  timeout add about 20,700 µm² for both engines.
- Timing, ABC with the slow library (1.08 V, 125 °C): 3.80 ns of logic on the worst path
  (engine PC → program memory read → decode → pin select → next state). With flip-flop
  clock-to-Q and setup, about 4.7 ns, against 20.8 ns at a 48 MHz clock. This leaves out wire
  delay and clock skew, so the real place-and-route timing report is still needed.
- Not done yet: the input glitch filter, Tiny Tapeout `info.yaml` and docs, USB (see
  `../docs/USB_NOTES.md`).
