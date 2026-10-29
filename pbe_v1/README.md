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
| `src/pbe_line.sv` | Line coder (one per engine): NRZ/NRZI, bit stuffing, pair mode, SYNC hunt |
| `src/pbe_host_spi.sv` | Host register port (SPI peripheral, mode 0) |
| `src/pbe_fifo.sv` | 16 × 8-bit FIFO |
| `tools/pbe_asm.py` | Assembler: `.pbe` text → 128-word hex image; labels relative to each program's start |
| `programs/*.pbe` | UART TX, UART RX, SPI controller and peripheral, I2C controller (with SMBus PEC) and target, 1-Wire controller, Modbus RTU master, WS2812 LEDs, USB low-speed device |
| `test/tb_pbe.sv` | End-to-end testbench, drives only the chip's pins (waveforms: `vvp sim.vvp +vcd`) |
| `test/tb_proto.sv` | Second end-to-end testbench: WS2812, SPI peripheral, I2C target |
| `test/tb_usb.sv` | USB: a host model enumerates the device; a firmware model on the host port |
| `test/tb_host.svh` | Host-port helpers both testbenches include |
| `test/tb_engine_restart.sv` | Unit test: restart cancels the instruction in flight |
| `test/tb_engine_ops.sv` | Unit test: `JEQ`/`JNE`/`MOV`, inverted CRC, CRC good value (USB CRC16) |
| `test/tb_line.sv` | Unit test: the line coder in USB, CAN and HDLC styles against reference models |
| `test/tb_fetch.sv` | Instruction fetch: instruction timing at CLKDIV 0, 1, 3; host writes to program memory picked up |
| `synth/synth.ys.in` | Yosys script for an area estimate with IHP standard cells |

## Run

```sh
make test                                  # Icarus Verilog, all testbenches
make test-proto                            # only tb_proto (WS2812, SPI peripheral, I2C target)
make test-usb                              # only tb_usb
make test-sram                             # end-to-end testbenches on the SRAM program memory (D55, also in make test)
make synth                                 # area, IHP library in ../ihp_lib
make synth-sram                            # the same with USE_SRAM (macros as black boxes)
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
Program memory holds 128 words shared by both engines. An engine runs the program that starts at
its `START_PC`, and all its jumps are relative to that address, so each engine has its own
64-word window and a program can be loaded anywhere.

## Instruction set

16 bits: `[15:13] OP | [12:4] ARG | [3:0] DELAY`. Each instruction issues on a tick and then
idles DELAY more ticks. A tick is one clock every (CLKDIV + 1) clocks, set per engine.
An instruction therefore takes (DELAY + 1) × (CLKDIV + 1) clocks. At CLKDIV = 0 (and with the
line coder, where instructions run every clock) a taken jump takes one clock more: the engine
runs from an instruction register and must fetch the jump's target first (D50).

| OP | Mnemonic | Does |
|---|---|---|
| 000 | `PIN p, DRV0/DRV1/REL/TOG/OUT/OUTOD/OUTPAR/END` | Drive, release or toggle a pin; OUT sends the next OSR bit; OUTOD is open drain; OUTPAR sends the parity of the bits sent since the last OSR load; END ends a line-coder frame. `OUT`/`OUTOD` take an optional `, NOCRC` |
| 001 | `IN p [, NOCRC]` | Shift a pin into the ISR (and the receive parity, and the CRC unless `NOCRC`) |
| 010 | `WAIT p, LOW/HIGH/RISE/FALL` (or `WAIT FLAG n, …`) | Block until true; checked every clock; restarts the tick timer |
| 011 | `JMP [cond,] label` | ALWAYS, X--, PIN_HI, PIN_LO, TX_EMPTY, TX_READY, FLAG0, FLAG1 (6-bit address) |
| 100 | `SET X/OSR, n` | Load the loop counter or the OSR |
| 101 | `PULL` / `PUSH` | TX FIFO → OSR, or ISR → RX FIFO (block when empty/full) |
| 110 | `FLAG n, SET/CLR/IRQ`, `MOV dst, src` | Shared flags between engines, or interrupt the host. Action 3 is `MOV` between X, OSR and ISR (source `0` = zero); with no destination it does nothing: the assembler's `NOP` (`0xD800`) |
| 111 | `CRCRST`, `OSRCRC LO/HI [, INV]`, `STAT`, `JCRCBAD label`, `JEQ label`, `JNE label`, `JLINE label` | Restart the CRC (and clear the line error); load a CRC byte (inverted with `INV`) into the OSR; ISR ← {line error, RX overflow, timeout happened, CRC ok, parity error}; jump if the packet is bad (CRC not ok, or a line error since the last `CRCRST`); jump if ISR == / != OSR; jump if the line coder saw the end of a frame (and clear it). Sub-op 7 free |

**Timeout:** if `WAIT`, `PULL` or `PUSH` stays blocked for `TIMEOUT` ticks (engine register
+C/+D, 0 = never), the engine abandons it and jumps to `TIMEOUT_PC` (`LINE_CFG[5:0]`, +E).

**CRC unit:** polynomial (+9/+A), and `CRC_CFG` (+B): width − 1, initial value all ones,
reversed output, fed by `OUT` bits, fed by `IN` bits. "CRC ok" means the register equals
`CRC_GOOD` (second page, default 0; USB: 0x800d, the residual of its inverted CRC16). The
host can restart it and read the status through `STATUS` (+F), and **reading +9/+A returns the
CRC's current value**, which is how the host checks CRCs that are sent inverted.

**Parity:** `LINE_CFG[7]` selects odd parity; `LINE_CFG[6]` means no parity: `OUTPAR` then sends 1
(a second stop bit, for 8N2) and no receive parity error is reported.

**RX overflow:** a `PUSH` that finds the RX FIFO full sets `STATUS[3]` and raises IRQ, so a host
that does not keep up finds out. Write `STATUS[2]` = 1 to clear it.

**Line coder** (second register page, 0x30 for engine 0, 0x40 for engine 1: +0 `LINE`, +1 `SYNC`,
+2/+3 `CRC_GOOD`):
- **`LINE` fields:** [1:0] mode (0 off, 1 NRZ, 2 NRZI); [3:2] stuffing (0 none, 1 after 6 ones,
  2 after 5 ones, 3 after 5 equal bits); [4] pair (pin base + 1 is the complement, both low =
  SE0 ends a frame); [5] byte transfers.
- **Timing:** when it is on, `CLKDIV` is the bit time − 1, and instructions run every clock.
- **Instructions:**
  - `OUT`/`OUTOD` hand it a byte (or a bit) and wait while it is busy; `PIN p, END` ends the
    frame.
  - `IN` takes a received byte (or bit), or completes with ISR unchanged at the end of the
    frame (then `JLINE` jumps).
- **Frames:** a frame starts with a 2-bit gap and the `SYNC` byte; reception hunts for `SYNC`.
  In byte mode the CRC takes each byte's 8 bits one per clock, and the next instruction waits
  for that.
- **Errors:** a stuff bit with the wrong value, a receive overrun or a send underrun set
  `STATUS[4]` (line error). `JCRCBAD` treats it as a bad packet. `CRCRST` clears it (a new
  checked packet starts); `STAT` reports it without clearing it; the host clears it by writing
  `STATUS[3]` = 1.

**FIFO counts:**
- `RX_COUNT` (0x0A, 0x0B) and `TX_COUNT` (0x0C, 0x0D) give the bytes in each engine's FIFOs.
  Read RX FIFOs in bursts of at most `RX_COUNT` bytes.
- `TX_FLUSH` (0x0E, bit e) empties one TX FIFO and leaves the RX FIFOs alone.

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

**SMBus PEC:** set the engine's CRC unit to CRC-8: `CRC_POLY` = 0x07, `CRC_CFG` = 0x87 (8 bits,
init 0, fed by `IN` bits, which see every byte on the bus; ACK bits are `NOCRC`). Restart the
CRC (`STATUS` write bit 0) before a message's first START, not at a repeated START. To send the
PEC, read the CRC value (+9) after the last byte and send it. After receiving a PEC, `STATUS`
bit 1 (CRC ok) says whether it was right.

## I2C target host protocol (`programs/i2c_target.pbe` + `programs/i2c_watch.pbe`)

Uses both engines on the same two pins: the bit engine (owns the pins, `JMP_PIN` = 0) and the
watcher (`JMP_PIN` = 1, drives nothing), both `CLKDIV` 0, both with the same `FLAG_BASE`.
sda = pin base, scl = base + 1. The watcher sets FLAG0 on a START and FLAG3 (with IRQ) on a STOP.
The bit engine holds SCL low (clock stretching) whenever it needs the host:

- **FLAG2 with a byte in the RX FIFO:** the last byte is an address (7 bits + R/W). ACK: clear
  FLAG2. NACK: restart the bit engine, then clear FLAG2. The host matches addresses itself, so
  any address, several, or the general call work.
- **FLAG2 with the RX FIFO empty:** a read needs its next byte. Queue it, then clear FLAG2.
- **Bytes the controller writes** arrive in the RX FIFO and are ACKed by the engine (it stretches
  SCL while the FIFO is full).
- Read `FLAGS` *after* draining the RX FIFO: if FLAG2 was still clear, no address was drained.

Up to fast mode plus. SDA changes ≥ 300 ns after SCL falls and ≥ 333 ns before the engine lets
go of SCL.

## SPI peripheral host protocol (`programs/spi_periph.pbe`)

Mode 0, MSB first. Pins: sclk = pin base, mosi = +1, miso = +2, cs = +3 (active low). Settings:
`CLKDIV` 0, `JMP_PIN` = 3, `LINE_CFG` = 0x01 (timeout routine at word 1), `TIMEOUT` a little
longer than the longest SCLK high phase (64 clocks in the test). Queue reply bytes before they
are due (before the previous byte's last rising edge); with nothing queued the reply is 0xFF.
Every byte the controller sends arrives in the RX FIFO. SCLK up to 2 MHz at 48 MHz. The first
SCLK edge must come ≥ 250 ns after CS falls. CS must stay high ≥ `TIMEOUT` ticks between
transactions: that is how the engine sees the end, and when it releases MISO.

## WS2812 host protocol (`programs/ws2812.pbe`)

`CLKDIV` = 1 at 48 MHz (tick 41.7 ns), OUT MSB first, data = pin base. Queue 3 bytes per LED in
the order the LEDs expect (G, R, B), keeping the FIFO from running dry: burst-write the FIFO
register and pause while the TX-full pin (`uo_out[6]` for engine 0) is high. When the host
stops, the line stays low and the LEDs latch after 50 µs.

## USB low-speed device host protocol (`programs/usb_dev.pbe`)

Endpoint 0 (control transfers), one engine. Pins: D− = pin base (with an external 1.5 kΩ
pull-up), D+ = pin base + 1.

**Settings at 48 MHz:**

| Register | Value |
|---|---|
| `CLKDIV` | 31 |
| `SHIFT` | 0 (LSB first) |
| `CRC_POLY` | 0x8005 |
| `CRC_CFG` | 0xFF |
| `LINE_CFG` | 0x40 |
| `LINE` | 0x36 |
| `SYNC` | 0x80 |
| `CRC_GOOD` | 0x800D |

**IN packets:**
- Queue `[DATA0/DATA1 PID] [0..8 bytes]`, then set FLAG0. The engine adds the CRC.
- With nothing queued it NAKs; set FLAG1 to STALL instead (clear it at the next SETUP).

**Records in the RX FIFO**, each ending with FLAG2 and IRQ:
- `[0x2D or 0xE1] [DATA PID] [n bytes: data and CRC] [255 − n] [status]`: a SETUP or OUT data
  packet. It was ACKed only if status bit 1 (CRC ok) is set and bit 4 (line error) is clear;
  otherwise the host sends it again.
- `[0xD2]`: the host ACKed our IN packet.

**Firmware rules:**
- Read by `RX_COUNT` and parse records from the end: a status byte is below 0x20.
- Read a SETUP record (14 bytes) before the next SETUP.
- On a SETUP, drop a stale reply with `TX_FLUSH`, not the CTRL flush.
- After a SET_ADDRESS status stage, rewrite words 6 and 9 of the program (`SET OSR` with the
  token's 2nd and 3rd byte for the new address, endpoint 0).
- Keep the last IN packet until its `[0xD2]` record. If the TX FIFO has drained (`TX_COUNT` = 0)
  and no `[0xD2]` came within about 100 µs, the host's ACK was lost: queue the same packet again,
  same DATA PID, and set FLAG0.
- Bus reset: poll `PINS`; SE0 (D− and D+ low) lasting 2.5 µs or more is a reset. Then rewrite
  words 6 and 9 to `0x9000` and `0x9100` (address 0), clear FLAG0–2, flush the TX FIFO and forget
  any transfer in progress.

The engine answers every token itself in about 3 bit times.

## 1-Wire host protocol (`programs/onewire_ctrl.pbe`)

Tick = 1 µs (`CLKDIV` = clock in MHz − 1), LSB first, DQ = pin base with a pull-up.

- **Reset/presence:** with the TX FIFO empty, set FLAG0. The engine returns `0x00` if a device
  answered, `0x80` if not, then clears FLAG0.
- **Bytes:** each TX byte becomes 8 slots; the byte seen on DQ comes back. Send `0xFF` to read.
- **Single slots** (Search ROM): set FLAG1 with the TX FIFO empty. Each TX byte is then one slot
  (bit 0), and the bit seen comes back in bit 7.
- **Strong pull-up** (parasite-powered devices, e.g. a DS18B20 during CONVERT T): queue the
  byte first, then set FLAG0. 6 µs after the byte's last slot the engine drives DQ hard high,
  until the host clears FLAG0; it pushes the byte seen after turning the pull-up on, so a full
  RX FIFO cannot delay it.
- Slots are 65 µs: 6 µs low for a 1 or a read, 60 µs low for a 0, sample at 13 µs.
- CRCs: set the CRC unit up for the device's CRC (CRC-8: poly 0x31, `CRC_CFG` 0xA7; CRC-16:
  poly 0x8005, `CRC_CFG` 0xAF), restart it after the command byte, and read "CRC ok" from
  `STATUS`, or the value from +9/+A for CRCs sent inverted.

## Modbus RTU host protocol (`programs/modbus_rtu.pbe`)

RS-485 half duplex, 8E1 (or 8O1), any baud rate. Tick = 1/8 bit, LSB first, `JMP_PIN` = 1.
Pins: TX = pin base, RX = base + 1, driver enable = base + 2.
Engine settings: `CRC_POLY` = 0x8005, `CRC_CFG` = 0xFF, `LINE_CFG` = 0x01 (0x81 for 8O1, 0x41
for 8N2), `TIMEOUT` = 1.5 characters in ticks + 9 = 141 at any baud rate. `TIMEOUT_PC` = 1:
the timeout routine is the program's word 1. It watches the line 2 more characters: silence
ends the frame (3.5 characters in all), a start bit makes the frame invalid.

- **Send:** queue only the data bytes. When the request is queued and the TX FIFO is empty, set
  FLAG1; the engine adds the parity bits, appends the CRC, turns the driver off after the last
  stop bit and clears FLAG1.
- **Receive:** two RX bytes per character, `[data] [status]`: status bit 0 = parity error,
  bit 1 = CRC ok so far (so on the last character: the frame's CRC is correct). At the end of
  the frame the engine sets FLAG2 and raises IRQ.
- **Invalid frame:** a character after more than 1.5 characters of silence inside a frame
  (Modbus over serial line §2.5.1.1). The engine sets FLAG3 at once and receives nothing more
  until the line has been silent 3.5 characters; then FLAG2 and IRQ as usual. With FLAG3 set,
  discard the frame and clear FLAG3.
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
     engine's CRC unit (through `STATUS`), CONVERT T on a parasite-powered device with the strong
     pull-up (the device model fails the conversion if DQ is not held high), again with the RX
     FIFO full (the pull-up must still come within 10 µs of the last slot), a block with an
     inverted CRC-16 checked through the CRC value read-out, and the timing of every low pulse.
  5. Modbus RTU master against an RS-485 device model, using the CRC unit, parity bit and
     timeout: a normal exchange, a response with a parity error, a response with a corrupted CRC
     (both reported by the engine), an exchange at 115200 baud, one in 8N2, responses with a
     2-character pause (reported invalid) and a 1-character pause (valid) at 19200 and
     115200 baud, and an RX overflow
     (the host deliberately not reading) reported in `STATUS` and by IRQ. The device checks the
     engine-appended CRC, parity or second stop bit, driver enable and glitches on the TX line.
  6. Two flag-using protocols at once: a 1-Wire Search ROM on engine 0 while engine 1 runs I2C
     write/read rounds, from two host processes sharing the host port. The 1-Wire program sits
     at word 64, so this also checks jumps relative to `START_PC`.
  7. SMBus PEC: Write Word and Read Word against a device model that computes its own PEC;
     the engine's PEC must match, and a corrupted PEC must be reported.
  8. WS2812 (`tb_proto`): 2 frames of 5 LEDs; a decoder checks every high and low phase against
     the datasheet (± 150 ns) and rebuilds the bytes.
  9. SPI peripheral (`tb_proto`): a 2 MHz mode-0 controller model; replies queued, 0xFF defaults,
     a pause inside a transaction, MISO released after CS rises and changing only while SCLK is
     low.
  10. I2C target (`tb_proto`): a fast-mode controller model; a 20-byte write (more than the FIFO
     holds), a 3-byte read after a repeated START, another device's transfer ignored, and SDA
     hold (≥ 300 ns) and setup (≥ 250 ns) times measured.
  11. USB low-speed device (`tb_usb`): a host model at ±1.5 % enumerates it:
     - GET_DESCRIPTOR (device; configuration, 9 and 18 bytes), SET_ADDRESS, SET_CONFIGURATION,
       STALL for an unsupported request, a vendor write and read;
     - not ACKed: a SETUP with a flipped bit, one with a missing stuff bit, and one with a
       wrong stuff bit but intact data and CRC;
     - ignored: tokens for another address and with a bad CRC5;
     - no reply: keep-alives and a bus reset;
     - piled-up records split apart;
     - a lost ACK: the device sends the same DATA1 packet again;
     - a 10 ms bus reset after SET_ADDRESS: the device answers at address 0 again.

     The host model checks the device's CRCs and stuffing itself. Every reply starts 2–7.5 bit
     times after the host's EOP (measured 2.97–3.05), and host and device never drive the bus
     together.
  - The testbenches run at 48 MHz, the planned clock.
  - Unit tests:
    - a restart in the same cycle as an instruction cancels its side effects;
    - `JEQ`/`JNE`/`MOV`, the inverted CRC and the CRC good value (USB CRC16 `dd 94`, residual
      0x800d);
    - the line coder in USB, CAN and HDLC styles against reference models, USB receive at
      ±1.5 %, and a stuffing error.
  - Shortening the 1-Wire write-0 pulse, never turning the RS-485 driver off, a dead `OUTPAR`,
    a CRC check that always passes, or a timeout that never fires each make the tests fail.
    So do 10 mutations of the new programs (WS2812 pulse widths; SPI default reply, timeout
    routine, MISO release; I2C target START flag, repeated START, hold and setup delays) and
    the ACK bit feeding the PEC. And 7 mutations of the USB hardware and program:
    - no edge re-centring;
    - no stuffing;
    - a 1-bit gap;
    - no frame-end drop;
    - no CRC5 check;
    - no CRC check before the ACK;
    - "CRC ok" back to zero.
- Area, Yosys with the IHP sg13g2 typical library: 333,841 µm² of cell area. 6×4 tiles are
  1289.28 × 710.64 µm = 916,229 µm², so cells fill about 36%.
  - USB's features added 71,223 µm²: FIFOs 4 → 16 bytes 33,121, two line coders 24,283, and
    instructions and registers about 13,800.
  - The 128-word program memory (flip-flops) is still the largest part; a latch-based memory
    could save roughly 70,000 µm².
- Timing, ABC with the slow library (1.08 V, 125 °C): 4.33 ns of logic on the worst path
  (engine PC → program memory read → decode → pin select → next state). With flip-flop
  clock-to-Q and setup, about 5.2 ns, against 20.8 ns at a 48 MHz clock. This leaves out wire
  delay and clock skew, so the real place-and-route timing report is still needed.
- Not done yet:
  - the input glitch filter;
  - Tiny Tapeout `info.yaml` and docs;
  - a second USB endpoint (HID), which does not fit a 64-word program;
  - the USB electrical check (see `../docs/USB_NOTES.md`, section 5).

## Independent verification

The executable Python specification and cocotb 2 differential tests compare the
unchanged RTL every clock, with reproducible seeds and saved failure diagnostics.
Install `test/differential/requirements.txt` in a virtual environment first.

```sh
make test                         # includes model units and a short fixed-seed run
make diff N=1000 SEED=0x504245     # extensive random programs/host/pin stimulus
make diff-line                    # NRZ/NRZI/stuffing/pair/byte line oracle
make diff-engine-line             # engine + coder + CRC composition
```

See [verification/REPORT.md](verification/REPORT.md) for the approach, recorded
coverage, exact tools, bug records and additional decoder/bus test commands.
These targets run behavioral simulation only and invoke no physical-design flow.

```sh
make sigrok                       # stock waveform decoders; needs sigrok-cli
make sigrok-full                  # strict full-USB request checks (known decoder failures)
make test-buses CASES=3 BUS_SEED=20261029 # requires test/bus_models/requirements.txt
```

The bus models use the unmodified UART/SPI/I2C programs through external pins.
Their documented compatibility adapters and unsupported SPI modes are described
in [verification/PHASE3.md](verification/PHASE3.md); decoder disagreements are
preserved in [verification/PHASE2.md](verification/PHASE2.md).
