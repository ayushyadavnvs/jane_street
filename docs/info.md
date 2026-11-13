<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

The Programmable Bit Engine is a protocol emulator: instead of fixed UART, SPI or I2C blocks it has
**two small programmable engines** that run short programs (8 to 64 instructions) driving,
releasing and reading the eight `uio` pins. A host loads the programs at runtime over an SPI
register port, so new protocols need no new silicon.

Each engine has:
- a 16-bit instruction set with 8 opcodes: pin drive/read, wait for a pin or flag, jumps,
  shift registers, FIFO access, flags and compare/CRC operations; every instruction carries
  a delay of 0–15 ticks;
- a CRC unit (any polynomial up to 32 bits: CRC-32 for Ethernet), a parity bit and a wait timeout;
- an optional line coder: NRZ/NRZI, bit stuffing and a differential pair with SE0, as
  low-speed USB needs; or a bit-synchronous coder for CAN (readback, arbitration, error
  frames and error counters in hardware);
- 16-byte TX and RX FIFOs to the host, and a window of 4 of 8 shared flags.

Each engine has its own 256 × 16-bit program memory, an IHP SRAM macro (512 words in all), so
two protocols can run at once, each with up to 256 words.

Programs written and tested so far (in `pbe_v1/programs`):
- UART TX and RX;
- SPI controller and peripheral;
- I2C controller (with SMBus PEC) and I2C target;
- 1-Wire controller;
- Modbus RTU master (RS-485);
- WS2812 LEDs;
- a USB 1.1 low-speed device (control endpoint);
- a CAN 2.0A node (standard IDs, 125k-1M bit/s): arbitration, ACK, CRC-15, error flags,
  error-passive and bus-off handled by the chip;
- a JTAG controller (IEEE 1149.1: TMS sequences and TDI/TDO scans of any length, TCK up to
  8 MHz) and an ARM SWD host (ADIv5 SW-DP: line reset, JTAG-to-SWD switch, DP/AP reads and
  writes with ACK, WAIT/FAULT handling and parity checking, SWCLK up to 8 MHz). They are
  42 + 64 words, so both run at once, one per engine;
- 10BASE-T Ethernet, transmit and receive (D93): preamble, FCS (CRC-32), TP_IDL and link
  pulses on one engine, clock recovery, SFD search and FCS check on the other, with the host
  streaming frames in real time over the quad host port.

The full documentation, register map and design decisions are in the repository: `pbe_v1/README.md`,
`docs/DESIGN_DECISIONS.md` and `docs/BUG_LOG.md`.

## How to test

The host talks to the chip over SPI mode 0. Use `ui[0]` SCK (at most clk/8), `ui[1]` CS_n,
`ui[2]` MOSI and `uo[0]` MISO.
- **Quad mode (D89)**, for streams such as 10 Mbit Ethernet: write 1 to `0x50` (`HOSTCFG`); from
  the next CS_n high every SCK carries 4 bits, high nibble first, so a byte is 2 SCK cycles
  (3.75 MB/s each way at SCK = 7.5 MHz, 60 MHz clock). Pins in quad mode:

  | Signal | Pin |
  |---|---|
  | D0..D3 (host to chip) | `ui[2]`, `ui[3]`, `ui[4]`, `ui[5]` |
  | Q0..Q3 (chip to host) | `uo[0]`, `uo[1]`, `uo[2]`, `uo[3]` (only while CS_n is low; with CS_n high `uo[1..3]` are IRQ and the running bits as usual) |
  | SCK, CS_n | `ui[0]`, `ui[1]` (unchanged) |

  `uo[4..7]` (RX has data, TX full) keep their meaning in quad mode. Back to single lane: write
  0 to `0x50`, or send 8 SCK pulses with CS_n high (works in either mode), or reset.
- **Transaction:** a command byte (bit 7 = write, bits 6..0 = register address), then data bytes.
- **Burst:** the address auto-increments, except for the program memory and the FIFO data
  registers, which can be streamed.
- **Program memory:** a 10-bit byte pointer {engine, word[7:0], byte}: `0x06` `PM_ADDR` holds
  [7:1] word[6:0] and [0] the byte (0 high), `0x0F` `PM_ADDR_H` holds [0] word[7] and [1] the
  engine. Each byte written to `0x07` `PM_DATA` advances {word, byte}; word 255 wraps to word 0
  of the same engine. Each engine's `START_PC` (`0x15`, `0x25`) is 8 bits.

Example, a UART loopback (what the Tiny Tapeout test does):
1. Load the UART programs. `pbe_v1/test/uart_image.hex` holds 512 words: engine 0's memory
   (words 0-255), then engine 1's. For each engine e: write `e << 1` to `0x0F` (`PM_ADDR_H`:
   engine e, word bit 7 = 0) and 0 to `0x06` (`PM_ADDR`), then stream that engine's 256 words
   (high byte first) into `0x07` (`PM_DATA`).
2. Engine 0 (UART TX on pin 0):
   - `0x10` CLKDIV = 49 (tick = half a bit at 600 kbaud and 60 MHz);
   - `0x12` = 0 (pin base);
   - `0x14` = 0 (LSB first);
   - `0x15` = 0 (start at word 0).
3. Engine 1 (UART RX on pin 1):
   - `0x20` = 24;
   - `0x22` = 1;
   - `0x23` = 0;
   - `0x25` = 8 (start at word 8 of engine 1's memory);
   - `0x03` = 0x02 (pin 1 belongs to engine 1).
4. Connect `uio[0]` to `uio[1]`, and write 0x33 to `0x00` to restart and run both engines.
5. Write bytes to `0x16` (engine 0's TX FIFO). They come back in `0x26` (engine 1's RX FIFO);
   `0x0B` says how many are waiting.

Other protocols are set up the same way. Each program's header lists its settings.

## External hardware

None needed for the loopback test. Depending on the protocol loaded:
- pull-up resistors for I2C or 1-Wire;
- an RS-485 transceiver for Modbus RTU;
- a CAN transceiver (for example a 3.3 V one such as the TCAN334 or SN65HVD230) for CAN: TXD
  on the engine's pin base, RXD on pin base + 1, and the bus terminated with 120 Ω at each end;
- WS2812 LEDs;
- for JTAG: TCK, TMS, TDI on the engine's pin base + 0, 1, 2 and TDO on + 3, a pull-up on TDO
  and a pull-down on TCK (10–100 kΩ); for SWD: SWCLK on pin base, SWDIO on pin base + 1, a
  pull-up on SWDIO (ADIv5: 10–100 kΩ) and a pull-down on SWCLK. The pull-downs keep the clock
  low while an engine restarts (its pins are released for a few clocks). The target's I/O
  voltage must match the chip's pads (3.3 V), or use a level shifter;
- for a PS/2 keyboard or mouse: CLK on the engine's pin base, DATA on pin base + 1, a pull-up
  (1–10 kΩ) on each; PS/2 devices run at 5 V, so use a bidirectional open-drain level shifter
  (e.g. a BSS138 pair) between them and the 3.3 V pads;
- for the 24-bit GPIO expander: three 74HC595 and three 74HC165 (74HC at 3.3 V), SCK, SDO,
  SDI, RCLK and SH/LD# on pin base + 0..4; 595 SRCLR# high and OE# low, 165 CLK INH low;
  each 595's QH' to the next one's SER, each 165's QH to the SER of the one nearer the chip;
- for a quad SPI flash: SCK, CS#, IO0, IO1, IO2, IO3 on pin base + 0..5, pull-ups (10–100 kΩ)
  on CS# and IO0–IO3 (IO2/IO3 are WP#/HOLD# in single-line commands), a 3.3 V flash;
- for the logic analyser and generator: nothing (inputs and outputs at 3.3 V levels);
- for HDLC/SDLC (NRZ or NRZI): TXD on one engine's pin base and RXD on the other's, through a line
  driver for the physical layer (e.g. RS-422/RS-485 transceivers);
- for USB low speed: a 1.5 kΩ pull-up on D− (`uio[0]`) and a USB connector. The electrical
  levels are still to be checked against the I/O pads;
- for 10BASE-T Ethernet (D93), a real link needs (not yet built on a board):
  - **an RJ45 jack with 10/100 magnetics** (1:1 transformers with centre taps, e.g. an integrated
    "MagJack" such as the HR911105A, or a discrete module such as the Pulse H1102 and a plain
    jack); TD± on RJ45 pins 1/2, RD± on 3/6 (MDI);
  - **a transmit driver:** the pads cannot source the ~20 mA a 100 Ω pair needs, so buffer
    `uio[0]` (TD+) and `uio[1]` (TD−) with two fast CMOS buffers (e.g. a 74LVC2G34 at 3.3 V),
    each through a series resistor into the transformer's primary, sized with the buffer's
    output resistance so the differential peak into 100 Ω is 2.2-2.8 V (about 2 × 20-30 Ω
    total from 3.3 V); a small RC low-pass (or the magnetics' common-mode choke) for the
    harmonics limits of clause 14.3.1.2. Both pins low is the 0 V idle; the chip's TP_IDL and
    link pulses are positive (TD+ high);
  - **a receive comparator:** RD± from the transformer, terminated with 100 Ω, into a fast
    comparator (a few ns, e.g. TLV3501, LMV7219, ADCMP600) with its output on `uio[2]` (3.3 V).
    Give it an offset of a few hundred mV (a resistor divider on one input: 10BASE-T's squelch
    is about 300 mV) and some hysteresis, so that it reads a steady **low** on an idle line:
    the receiver starts a frame at the first edge, and noise on an idle pair would start
    false ones (they end silently, but cost the program time);
  - the link partner set to **10 Mbit/s full duplex** (no auto-negotiation, no collision
    handling in the programs).
