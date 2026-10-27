# Programmable Bit Engine (PBE), version 2

Version 2 adds a low-speed USB line unit to each engine (opcode `111`) and grows the FIFOs from
4 to 16 bytes so a whole USB packet can be queued. Version 1 is unchanged in `../pbe_v1`.

A reprogrammable protocol emulator for the Jane Street protocol emulator ASIC competition
(Tiny Tapeout, IHP CMOS5L 130 nm). Two small engines run short programs that drive, release
and read 8 bidirectional pins. UART, SPI, I2C and others are programs loaded at runtime.

## Layout

| Path | What |
|---|---|
| `src/tt_um_pbe.sv` | Top level: pin map, register map, program memory, FIFOs, pin mux |
| `src/pbe_engine.sv` | One engine: decoder, PC/branch, timing, pin unit, X counter, OSR/ISR |
| `src/pbe_host_spi.sv` | Host register port (SPI peripheral, mode 0) |
| `src/pbe_usb_line.sv` | Low-speed USB line unit: NRZI, bit stuffing, SYNC/EOP, CRC5/CRC16, edge re-centring |
| `src/pbe_fifo.sv` | 16 × 8-bit FIFO |
| `tools/pbe_asm.py` | Assembler: `.pbe` text → 64-word hex image |
| `programs/*.pbe` | UART TX, UART RX, SPI controller, I2C controller, USB packet TX, USB packet RX |
| `test/tb_pbe.sv` | End-to-end testbench, drives only the chip's pins |
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
| 000 | `PIN p, DRV0/DRV1/REL/TOG/OUT/OUTOD` | Drive, release or toggle a pin; OUT sends the next OSR bit; OUTOD is open drain |
| 001 | `IN p` | Shift a pin into the ISR |
| 010 | `WAIT p, LOW/HIGH/RISE/FALL` (or `WAIT FLAG n, …`) | Block until true; checked every clock; restarts the tick timer |
| 011 | `JMP [cond,] label` | ALWAYS, X--, PIN_HI, PIN_LO, TX_EMPTY, TX_READY, FLAG0, FLAG1 (6-bit address) |
| 100 | `SET X/OSR, n` | Load the loop counter or the OSR |
| 101 | `PULL` / `PUSH` | TX FIFO → OSR, or ISR → RX FIFO (block when empty/full) |
| 110 | `FLAG n, SET/CLR/IRQ` | Shared flags between engines, or interrupt the host. Action 3 does nothing: the assembler's `NOP` (`0xD800`) |
| 111 | USB sub-ops (below) | Low-speed USB line unit |

### USB sub-ops (opcode 111, D+ = pin base, D- = pin base + 1)

The line unit does the bit timing itself (`BITDIV` = clocks per bit − 1, 31 at 48 MHz), so
the engine runs with `CLKDIV = 0` and only has to keep the 1-bit holding register fed.

| Mnemonic | Does |
|---|---|
| `UTX [NOCRC]` | Queue the next OSR bit; NRZI and stuffing are automatic. Blocks while the holding bit is full |
| `URX label` | Take the next decoded bit into the ISR, or jump to `label` at end of packet. Blocks until one arrives |
| `UEOP` | End the packet (SE0, SE0, J, then release) after the queued bits |
| `CRC` | Restart CRC5 and CRC16 |
| `OSRCRC LO/HI` | Load the OSR with a CRC16 field byte, ready to send |
| `STAT` | ISR ← {stuffing error, CRC16 ok, CRC5 ok} |
| `UIDLE` | Block until the packet, EOP included, is on the wire |
| `JCRCBAD label` | Jump if the CRC16 check failed |

The receiver samples each bit in its middle, re-centres on every D+ edge, strips SYNC and
stuffed bits, and checks CRCs with the standard residuals (CRC5 `01100`, CRC16 `0x800D`).

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

## USB host protocol

- `programs/usb_tx.pbe`: queue `[PID] [data...]` in the TX FIFO, then set FLAG0 to send, plus
  FLAG1 to append the CRC16 (DATA packets). A handshake is just `[PID]` with FLAG0.
- `programs/usb_rx.pbe`: every packet arrives in the RX FIFO as `[PID] [bytes...] [status]`,
  status bit 0 = CRC5 ok (tokens), bit 1 = CRC16 ok (DATA), bit 2 = bit-stuffing error
  (reject the packet).

## Status

- Simulation (`make test`, 48 MHz clock, exits non-zero on any failure), all through the chip's pins:
  0. `NOP` has no side effects (in v2 it used to send a USB bit).
  1. UART TX → UART RX loopback, 6 bytes, plus an independent UART monitor.
  2. SPI mode 0 full duplex, 3 bytes.
  3. I2C on engine 1 while engine 0 sends UART, with 20 clock stretches, at fast-mode speed
     with every SCL low and high phase checked against the I2C spec.
  4. USB low speed, checked by testbench models written independently of the RTL:
     - Engine 0 sends a DATA0 GET_DESCRIPTOR packet (CRC16 `DD 94`, matching real USB traces),
       an ACK handshake, and a DATA1 packet that needs 6 stuffed bits. A decoder checks every
       byte, every stuffed bit and the EOP length.
     - Engine 1 receives a SETUP token at +1.5% bit rate, the same token with a bad CRC5 at
       −1.5%, a DATA0 packet full of stuffed bits at −1.5%, and that packet with a flipped bit.
       Good CRCs pass and bad ones are flagged. A packet with a bit-stuffing violation is
       flagged in status bit 2.
     - Turning off the receiver's edge re-centring, or the transmitter's bit stuffing, makes
       the test fail, so both features are really exercised.
  - Unit test: a restart in the same cycle as an instruction cancels its side effects.
- Area, Yosys with the IHP sg13g2 typical library: about 7,480 cells, 2,028 flip-flops,
  189,389 µm² of cell area, about 21% of the 6×4 tiles (916,229 µm²). Compared with version 1
  (141,141 µm²), the USB logic adds about 15,600 µm² (one line unit is 5,733 µm²) and the
  16-byte FIFOs add about 32,800 µm².
- Timing, ABC with the slow library: 3.96 ns of logic on the worst path, about 4.8 ns with
  flip-flop overhead, against 20.8 ns at 48 MHz. Wire delay and clock skew are not included.

## What a complete USB device still needs

This version moves USB packets in both directions. A device that a PC can enumerate also needs:

1. **A fast responder.** A device must answer a token within about 7.5 bit times (5 µs), far
   too fast for a host over SPI. The plan: engine 1 receives, engine 0 transmits, and they
   signal each other through the shared flags. Engine 0 sends a DATA packet the host queued in
   advance, or NAK if nothing is queued, and ACKs good DATA packets on its own. This needs one
   more instruction to branch on the received PID, for example a compare of the ISR with the OSR.
2. **Control transfers on the host side.** The host microcontroller answers SETUP requests
   (GET_DESCRIPTOR, SET_ADDRESS, …) by queuing replies ahead of the next IN token.
3. **Electrical checks.** Low speed USB uses 3.3 V signalling and a 1.5 kΩ pull-up on D−. The
   Tiny Tapeout I/O voltage and drive must be checked against that. Bit-banged low-speed USB on
   small microcontrollers (V-USB on AVR) works with this kind of plain digital I/O.
4. **Full speed (12 Mbit/s) is out of reach:** at a ~50 MHz clock it leaves 4 clocks per bit.
