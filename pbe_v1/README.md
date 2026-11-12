# Programmable Bit Engine (PBE)

A reprogrammable protocol emulator for the Jane Street protocol emulator ASIC competition
(Tiny Tapeout, IHP CMOS5L 130 nm). Two small engines run short programs that drive, release
and read 8 bidirectional pins. UART, SPI, I2C and others are programs loaded at runtime.

## Layout

| Path | What |
|---|---|
| `src/tt_um_pbe.sv` | Top level: pin map, register map, program memory, FIFOs, pin mux |
| `src/pbe_pmem_sram.sv` | Program memory: one IHP SRAM macro (256 × 16) per engine (D82) |
| `src/sram_bb.v` | The macro as a black box, for synthesis, lint and the flow (Tiny Tapeout's) |
| `src/pbe_engine.sv` | One engine: decoder, PC/branch, timing and timeout, pin unit, X counter, OSR/ISR, parity |
| `src/pbe_crc.sv` | General CRC unit (one per engine) |
| `src/pbe_line.sv` | Line coder (one per engine): NRZ/NRZI, bit stuffing, pair mode, SYNC hunt |
| `src/pbe_host_spi.sv` | Host register port (SPI peripheral, mode 0) |
| `src/pbe_fifo.sv` | 16 × 8-bit FIFO |
| `tools/pbe_asm.py` | Assembler: `.pbe` text → 512-word hex image (engine 0's 256 words, then engine 1's), `prog.pbe@engine:word`; labels relative to each program's start |
| `programs/*.pbe` | UART TX, UART RX, SPI controller and peripheral, I2C controller (with SMBus PEC) and target, 1-Wire controller, Modbus RTU master, WS2812 LEDs, USB low-speed device, CAN 2.0A node (`can_node.pbe`), JTAG controller (`jtag.pbe`), SWD host (`swd.pbe`), PS/2 host (`ps2_host.pbe`), 24-bit GPIO expander (`gpio_expander.pbe`), logic analyser (`la_capture.pbe`) and waveform generator (`wavegen.pbe`), quad SPI controller (`qspi_flash.pbe`), HDLC transmitter and receiver (`hdlc_tx.pbe`, `hdlc_rx.pbe`) |
| `test/tb_pbe.sv` | End-to-end testbench, drives only the chip's pins (waveforms: `vvp sim.vvp +vcd`) |
| `test/tb_proto.sv` | Second end-to-end testbench: WS2812, SPI peripheral, I2C target |
| `test/tb_usb.sv` | USB: a host model enumerates the device; a firmware model on the host port |
| `test/tb_debug.sv` | JTAG and SWD against `jtag_tap.sv` (IEEE 1149.1 TAP) and `swd_dp.sv` (ADIv5 SW-DP), alone and at once, fastest and slowest clock |
| `test/tb_ps2.sv` | PS/2 host against `ps2_dev.sv` (a keyboard written from the protocol description) (D84) |
| `test/tb_gpio.sv` | 24-bit GPIO expander against `hc_chain.sv` (74HC595 and 74HC165 models, 3 deep) (D85) |
| `test/tb_la.sv` | Logic analyser and waveform generator against an independent stimulus and timestamps (D86) |
| `test/tb_qspi.sv` | Quad SPI controller against `qspi_flash_model.sv` (a NOR flash: 9F, 03, 0B, 6B, EB, 06, 05, 32) (D87) |
| `test/tb_hdlc.sv` | HDLC transmitter and receiver against `hdlc_model.sv` (ISO/IEC 13239, NRZ) (D88) |
| `test/tb_host.svh` | Host-port helpers both testbenches include |
| `test/tb_engine_restart.sv` | Unit test: restart cancels the instruction in flight |
| `test/tb_engine_ops.sv` | Unit test: `JEQ`/`JNE`/`MOV`, inverted CRC, CRC good value (USB CRC16) |
| `test/tb_line.sv` | Unit test: the line coder in USB, CAN and HDLC styles against reference models |
| `test/tb_page.sv` | `PAGE` (D83): a 202-word program over four pages, the timeout vector, stop and restart, host writes, cross-page timing |
| `test/tb_fetch.sv` | Instruction fetch: instruction timing at CLKDIV 0, 1, 3; host writes to program memory picked up; separate memories, pointer carries, `START_PC` 252 wrapping, the refetch cost, the reset refetch (D82) |
| `synth/synth.ys.in` | Yosys script for an area estimate with IHP standard cells |

## Run

```sh
make test                                  # Icarus Verilog, all testbenches
make test-proto                            # only tb_proto (WS2812, SPI peripheral, I2C target)
make test-usb                              # only tb_usb
make test-debug                            # only tb_debug (JTAG, SWD); ONLY=jtag|swd|both|slow
make test-proto2                           # only the D84-D88 protocols (PS/2, GPIO expander, logic analyser, QSPI, HDLC)
make test-ff                               # tb_usb and tb_proto on the flip-flop fallback (PBE_PMEM_FF, also in make test)
make test-verilator                        # tb_line and 5 more under Verilator and Icarus: both pass, identical logs (D80)
make synth                                 # area of the standard cells, IHP library in ../ihp_lib; the SRAM macros
                                           #   are black boxes (src/sram_bb.v); prints their instance names
make synth FF=1                            # the same for the flip-flop fallback
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

The full register map is in the header comment of `src/tt_um_pbe.sv`.

**Program memory (D82).** Each engine has its own 256 × 16 memory, an IHP SRAM macro: 512 words
in all. The host writes it through a 10-bit byte pointer {engine, word[7:0], byte}:

| Register | Address | Bits |
|---|---|---|
| `PM_ADDR` | 0x06 RW | [7:1] word[6:0], [0] byte (0 high, 1 low) |
| `PM_ADDR_H` | 0x0F RW | [0] word[7], [1] engine (0 or 1); [7:2] read 0 |
| `PM_DATA` | 0x07 W | writes the byte, then {word, byte} += 1 |

To load engine e's program at word w: write `PM_ADDR_H` = {e, w[7]}, `PM_ADDR` = {w[6:0], 0},
then stream the words (high byte first) into `PM_DATA` in one burst. The pointer carries from the
low byte into the next word and from word 127 into 128, and wraps from word 255 to word 0 of the
**same** engine: a burst never spills into the other engine's memory. The program memory is
write only. A write refetches only the engine whose memory it writes, costing it 2 clocks at
`CLKDIV` 0 (BUG-074); the other engine runs on undisturbed.

An engine runs the program that starts at its `START_PC` (8 bits, in its own memory), and all
its jumps are relative to that address (6-bit targets, mod 256), so each program has a 64-word
window and can be loaded anywhere. The assembler's images hold both memories (`@engine:word`).

**Programs over 64 words (D83).** A program may use its engine's whole memory: four pages of 64
words, page n being its words 64n..64n+63. A jump goes to its 6-bit target in its own page, or
in page p if `PAGE p` executed just before it (a one-shot prefix: it applies to the next
instruction only; restart, a timeout and a line-event jump clear it). The assembler inserts the
`PAGE` itself when a jump's label is in another page, and says so; each one is one more
instruction time. The timeout vector (`TIMEOUT_PC`) is in page 0. `.org n` places code at a
word. In the flip-flop fallback all pages are the same 64 words.
With `PBE_PMEM_FF` (the flip-flop fallback) each engine has 64 words: writes to words 64-255 are
dropped, and `pc`/`START_PC` address the 64 words mod 64.

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
| 101 | `PULL [NOWAIT]` / `PUSH` / `MARK` / `REWIND` | TX FIFO → OSR, or ISR → RX FIFO (block when empty/full); `NOWAIT`: an empty TX FIFO gives 0xFF; `MARK`/`REWIND` hold the TX FIFO read position and read again from it, for retransmission (D70) |
| 110 | `FLAG n, SET/CLR/IRQ`, `MOV dst, src` | Shared flags between engines, or interrupt the host. Action 3 is `MOV` between X, OSR and ISR (source `0` = zero); with no destination it does nothing: the assembler's `NOP` (`0xD800`) |
| 111 | `CRCRST`, `OSRCRC LO/HI [, INV] [, LEFT]`, `STAT`, `JCRCBAD label`, `JEQ label`, `JNE label`, `JLINE label` | Restart the CRC (and clear the line error); load a CRC byte (inverted with `INV`) into the OSR; ISR ← {line error, RX overflow, timeout happened, CRC ok, parity error}; jump if the packet is bad (CRC not ok, or a line error since the last `CRCRST`); jump if ISR == / != OSR; jump if the line coder saw the end of a frame (and clear it). `STAT` also gives [5] arbitration lost, [6] bit error, [7] frame sent; `LEFT` left-justifies the CRC to 16 bits (D71). Sub-op 7: `LINECTL W1..W8 [, ARB]` / `LINECTL STUFFOFF|STUFFON|ERROR` for the bit-synchronous coder (param[5] = 0, D67); `PAGE p` (param[5] = 1, p = param[1:0], D83): the next instruction's jump target is in page p |

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

**LINE2 and the bit-synchronous (CAN) coder** (second page +4, D65-D68): [2:0] sample point
(0 default, 1/2/3 = 62.5/75/87.5 %), [3] resync on falling edges only, [4] receive on pin base +
1, [5] bit-synchronous mode (`pbe_bsync`: one bit timer, readback, arbitration, units of 1-8
bits, the CRC fed from the line, the CAN frame tail, error flags, TEC/REC, bus-off), [6] wait
for bus idle before a frame, [7] CAN frame follower (extended frames and r0 recessive walked by
the coder, D74). Error counters: +5 `CAN_TEC`, +6 `CAN_REC`, +7 `CAN_STATE`
([0] TEC[8], [1] error-passive, [2] bus-off). `STATUS` write bits [4]/[5]/[6] clear
arbitration lost / bit error / frame sent.

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
  packet. It was ACKed only if status bit 1 (CRC ok) is set and bit 4 (line error, in the
  token or the data packet) is clear; otherwise the host sends it again.
- A token with a line error (e.g. a wrong stuff bit) gets no answer at all (D79).
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

## CAN host protocol (`programs/can_node.pbe`)

A CAN 2.0A node (standard IDs) in 61 words, TXD on pin base, RXD on pin base + 1 to a CAN
transceiver. Settings, the frame format in the TX FIFO, the RX records and the limits are in
the program's header (D72). 125k, 250k and 500k at a 75 % or 87.5 % sample point; 1 Mbit/s at
75 % only. Tested by `tb_can` against two reference nodes written from ISO 11898-1 (DLC 0-8,
remote frames, arbitration, missing ACK, CRC/stuff/form/bit errors, error-passive, bus-off and
recovery, both engines as nodes, extended frames and standard/extended arbitration), by sigrok's `can` decoder (`make sigrok-can`) and by a random
differential of the coder (`make diff-can`).

## JTAG host protocol (`programs/jtag.pbe`)

IEEE 1149.1 controller in 42 words. TCK = pin base, TMS = + 1, TDI = + 2, TDO = + 3; LSB first
(`SHIFT` = 0). Records `[cmd] [n − 1] [bits]`, n = 1..8: `0` clocks TMS = bits (TDI kept), `1`
shifts n TDI bits with TMS = 0, `2` the same with TMS = 1 on the last bit. Each shift record
returns a byte with the n TDO bits in its top bits (RX >> (8 − n)); longer scans are several
records. TDI/TMS change one tick after TCK falls; TDO is read while TCK is high. TCK = 8 MHz at
CLKDIV = 0, else 48 MHz / (5 (CLKDIV + 1)). Board: pull-up on TDO, pull-down on TCK (D75).

## SWD host protocol (`programs/swd.pbe`)

ARM ADIv5 SW-DP host in 64 words. SWCLK = pin base, SWDIO = + 1 (pull-up on SWDIO, pull-down
on SWCLK); LSB first, `LINE_CFG` = 0 (even parity). Records: `[0x00] [b]` 8 host-driven bits
(line reset = 7 × 0xFF + 0x00; JTAG-to-SWD = line reset, 0x9E, 0xE7, line reset, 0x00);
`[0x01] [req]` read; `[0x02] [req] [d0..d3] [p]` write (`req` = the 8-bit request with its
parity, `p` bit 0 = the data parity). RX: `[ack]` (0x20 OK, 0x40 WAIT, 0x80 FAULT, 0xE0 no
response), and for an OK read `[d0..d3] [status]` (bit 0 = parity error, checked by the
engine). WAIT/FAULT: no data phase, a write's data bytes are dropped. SWCLK = 8 MHz at
CLKDIV = 0, else 48 MHz / (5 (CLKDIV + 1)) (D76).

Both are tested by `tb_debug` against target models written from the standards, at CLKDIV 0
and 0xFFFF and both at once, and by sigrok's `jtag` and `swd` decoders (`make sigrok-debug`,
D77).

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

## PS/2 host protocol (`programs/ps2_host.pbe`)

PS/2 keyboard or mouse host in 74 words (D84). CLK = pin base, DATA = + 1, both open-drain
with external pull-ups (1-10 kΩ; a level shifter for a 5 V device). Settings: `CLKDIV` = 239
(5 µs tick), LSB first, `JMP_PIN` = 1, `LINE_CFG` = 0x81 (odd parity, timeout vector at word 1),
`CRC_CFG` = 0, `CRC_GOOD` = 0xFFFF, `TIMEOUT` = 4000 (20 ms). The device drives the clock
(10-16.7 kHz); each clock phase must last 3 ticks.

- TX FIFO: one byte per command; the engine inhibits (CLK low 160 µs), requests to send, sends
  8 bits, the odd parity bit (computed from the bits read back from the wire) and the stop bit,
  and reads the device's ACK.
- RX FIFO, two-byte records: `[byte][status]` from the device (0x00 good, bit 0 parity error,
  0x80 stop bit 0, bit 3 RX overflow); `[cmd][0x20]` sent and ACKed, `[cmd][0xA0]` not ACKed;
  `[0x00][0x04]` timeout (the device stopped clocking or never answered a request to send).
- A device byte that has started is received before a queued command is sent.

Tested by `tb_ps2` against a keyboard model (`ps2_dev.sv`) and by sigrok's `ps2` decoder
(`make sigrok-proto2 PROTO2=ps2`).

## GPIO expander host protocol (`programs/gpio_expander.pbe`)

24 outputs (three 74HC595) and 24 inputs (three 74HC165) in 33 words (D85). Pins: SCK = pin
base (595 SRCLK and 165 CLK), SDO = + 1 (595 SER), SDI = + 2 (165 QH), RCLK = + 3, LD# = + 4
(165 SH/LD#). `SHIFT` = 0x03, `CLKDIV` 0 (SCK 6.86 MHz) or n ≥ 1 (SCK = 48 MHz / (6 (n + 1))).

- One exchange per record: TX `[o0] [o1] [o2]`, RX `[i0] [i1] [i2]`. o0 ends in the last 595
  of the chain, o2 in the first; i0 is the first 165 (whose QH is SDI), i2 the last; bit 7 is
  QH / input H.
- Inputs are sampled when the exchange starts (LD# low); all 24 outputs change together when it
  ends (RCLK rises). To read only, send the current outputs again.

Tested by `tb_gpio` against 74HC595/74HC165 models with datasheet timing checks, and by
sigrok's `spi` decoder (`make sigrok-proto2 PROTO2=gpio`).

## Logic analyser and generator host protocols (`programs/la_capture.pbe`, `programs/wavegen.pbe`)

Two programs, one per engine (D86). `CLKDIV` ≥ 1 (uniform sample clocks), LSB first.

- **Capture** (30 words): channels 0..3 = pin base + 0..3; trigger pin = `JMP_PIN`. TX
  `[mode][n-1]`: mode 0 now, 1 high, 2 low, 3 rising edge, 4 falling edge; then n bytes in the
  RX FIFO, two samples each (bits 3..0, then 7..4). One sample every 6 (CLKDIV + 1) clocks
  (4 MS/s at `CLKDIV` 1); channel k is read k ticks after channel 0. The first sample is 3 ticks
  after the trigger is seen. Bursts of 16 bytes at any rate; sustained with burst reads at
  `CLKDIV` ≥ 6 (1.14 MS/s). A full FIFO pauses the capture and sets `STATUS` bit 3.
- **Generator** (16 words): A = pin base, B = + 1. TX `[n-1][n bytes]`, 4 samples per byte
  (bits 1..0 first: A = even bit, B = odd bit), one every 4 (CLKDIV + 1) clocks (6 MS/s at
  `CLKDIV` 1); B changes one tick after A. Sustained at `CLKDIV` ≥ 3 with 15 bytes queued
  first; an empty FIFO holds the current sample. The last sample is held after a record.

Tested by `tb_la` (D86).

## Quad SPI host protocol (`programs/qspi_flash.pbe`)

SPI mode 0 controller for 1-1-1, 1-1-4, 1-4-4 and 4-4-4 commands, 125 words (D87). Pins: SCK =
pin base, CS# = + 1, IO0..IO3 = + 2..5 (pull-ups on IO0-IO3). `SHIFT` = 0x03, `CLKDIV` 0.

- TX records, one per phase; CS# falls with the first and rises with `[0x00]`:
  `[0x01][n-1][bytes]` single write (IO0), `[0x02][n-1]` single read (IO1), `[0x03][n-1][bytes]`
  quad write, `[0x04][n-1]` quad read, `[0x05][n-1]` dummy clocks (IOs released), `[0x00]` end.
  RX: the bytes read.
- 0x6B (1-1-4): `[01][03][6B][A2][A1][A0] [05][07] [04][n-1] [00]`;
  0xEB (1-4-4): `[01][00][EB] [03][03][A2][A1][A0][00] [05][03] [04][n-1] [00]`.
- SCK at `CLKDIV` 0: 16 MHz single write, 9.6 MHz single read, 8 MHz quad write, 6 MHz quad
  read (2.8 MB/s with the loop); long reads pause SCK while the RX FIFO is full.

Tested by `tb_qspi` against a flash model, and by sigrok's `spi` decoder on the single-line
phase (`make sigrok-proto2 PROTO2=qspi`).

## HDLC host protocol (`programs/hdlc_tx.pbe`, `programs/hdlc_rx.pbe`)

HDLC/SDLC framing in NRZ (D88): flags, zero-bit insertion and deletion (the line coder's
"after 5 ones" stuffing), CRC-16/X.25, aborts. Transmit on one engine, receive on the other.
Both: `CLKDIV` = bit time − 1, `LINE` = 0x09, `SYNC` = 0, LSB first, `CRC_POLY` = 0x1021,
`LINE_CFG` = 0x40.

- **Transmit** (`CRC_CFG` 0x7F; TXD = pin base): TX `[n-1][n bytes]` per frame; the engine adds
  the FCS and the flags (shared between back-to-back frames; mark idle after). Up to 4 Mbit/s.
- **Receive** (`CRC_CFG` 0x9F, `CRC_GOOD` 0xD0F9, `JMP_PIN` 0; RXD = pin base): first write one
  byte d = ceil((bit time in clocks / 2 + 4) / 10) to this engine's TX FIFO (the abort check).
  RX: each frame's bytes (FCS included; 0x7E doubled), then `[0x7E][status]`: 0x02 good, other
  values ≤ 0x1F CRC error / overflow / line error, 0x40 abort, 0x80 not whole bytes. Up to
  2 Mbit/s.
- NRZI is not possible without hardware (D88: a pbe_line `LINECTL STUFFOFF/STUFFON` and a
  "violation ends the frame at either level" option).

Tested by `tb_hdlc` against an HDLC model (no stock sigrok decoder exists).

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
     at word 130 of engine 0's memory, so this also checks jumps relative to a `START_PC` ≥ 128.
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
- Area now (D82, `make synth`): 198,770 µm² of standard cells, plus two SRAM macros of
  28,127 µm² each, on an 8x4 tile (1724.16 × 710.64 µm): about 21 %. The flip-flop fallback
  (`make synth FF=1`) is 366,093 µm². The figures below are from before D82.
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
Install `../verify/golden-model/differential/requirements.txt` in a virtual environment first.

```sh
make test                         # includes model units and a short fixed-seed run
make diff N=1000 SEED=0x504245     # extensive random programs/host/pin stimulus
make diff-line                    # NRZ/NRZI/stuffing/pair/byte line oracle
make diff-engine-line             # engine + coder + CRC composition
```

See [verify/golden-model/REPORT.md](../verify/golden-model/REPORT.md) for the approach, recorded
coverage, exact tools, bug records and additional decoder/bus test commands.
These targets run behavioral simulation only and invoke no physical-design flow.

```sh
make sigrok                       # stock waveform decoders; needs sigrok-cli
make sigrok-debug                 # stock jtag and swd decoders on tb_debug (D77)
make sigrok-proto2                # stock ps2 and spi decoders on the D84-D88 benches; PROTO2=ps2|gpio|qspi
make sigrok-full                  # strict full-USB request checks (known decoder failures)
make test-buses CASES=3 BUS_SEED=20261029 # requires ../verify/golden-model/bus_models/requirements.txt
```

The bus models use the unmodified UART/SPI/I2C programs through external pins.
Their documented compatibility adapters and unsupported SPI modes are described
in [verify/golden-model/PHASE3.md](../verify/golden-model/PHASE3.md); decoder disagreements are
preserved in [verify/golden-model/PHASE2.md](../verify/golden-model/PHASE2.md).

Round 2 (D55-D61; files under `../verify/`, D64) adds formal properties, reference vectors,
coverage, stress and mutation testing. The long targets stay out of `make test`:

```sh
make formal                       # SymbiYosys FIFO, host SPI, line coder, engine (OSS CAD Suite)
make test-crc-vectors             # needs ../verify/vectors/crc/requirements.txt
make test-protocol-vectors        # needs ../verify/vectors/protocols/requirements.txt
make coverage                     # Verilator line/toggle/branch/expression and named bins
make stress                       # pin-level clock error, jitter, backlog, concurrency
make mutate                       # 24 single-site RTL faults on scratch copies
```

Results are in [verify/golden-model/REPORT.md](../verify/golden-model/REPORT.md) ("Round 2").
