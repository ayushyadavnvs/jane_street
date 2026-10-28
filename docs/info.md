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
- a CRC unit (any polynomial up to 16 bits), a parity bit and a wait timeout;
- an optional line coder: NRZ/NRZI, bit stuffing and a differential pair with SE0, as
  low-speed USB needs;
- 16-byte TX and RX FIFOs to the host, and a window of 4 of 8 shared flags.

The two engines share a 128 × 16-bit program memory, so two protocols can run at once.

Programs written and tested so far (in `pbe_v1/programs`):
- UART TX and RX;
- SPI controller and peripheral;
- I2C controller (with SMBus PEC) and I2C target;
- 1-Wire controller;
- Modbus RTU master (RS-485);
- WS2812 LEDs;
- a USB 1.1 low-speed device (control endpoint).

The full documentation, register map and design decisions are in the repository: `pbe_v1/README.md`,
`docs/DESIGN_DECISIONS.md` and `docs/BUG_LOG.md`.

## How to test

The host talks to the chip over SPI mode 0. Use `ui[0]` SCK (at most clk/8), `ui[1]` CS_n,
`ui[2]` MOSI and `uo[0]` MISO.
- **Transaction:** a command byte (bit 7 = write, bits 6..0 = register address), then data bytes.
- **Burst:** the address auto-increments, except for the program memory and the FIFO data
  registers, which can be streamed.

Example, a UART loopback (what the Tiny Tapeout test does):
1. Load the UART programs: write 0 to `0x06` (program pointer), then stream the 128 words of
   `pbe_v1/test/uart_image.hex` (high byte first) into `0x07`.
2. Engine 0 (UART TX on pin 0):
   - `0x10` CLKDIV = 49 (tick = half a bit at 480 kbaud and 48 MHz);
   - `0x12` = 0 (pin base);
   - `0x14` = 0 (LSB first);
   - `0x15` = 0 (start at word 0).
3. Engine 1 (UART RX on pin 1):
   - `0x20` = 24;
   - `0x22` = 1;
   - `0x23` = 0;
   - `0x25` = 8 (start at word 8);
   - `0x03` = 0x02 (pin 1 belongs to engine 1).
4. Connect `uio[0]` to `uio[1]`, and write 0x33 to `0x00` to restart and run both engines.
5. Write bytes to `0x16` (engine 0's TX FIFO). They come back in `0x26` (engine 1's RX FIFO);
   `0x0B` says how many are waiting.

Other protocols are set up the same way. Each program's header lists its settings.

## External hardware

None needed for the loopback test. Depending on the protocol loaded:
- pull-up resistors for I2C or 1-Wire;
- an RS-485 transceiver for Modbus RTU;
- WS2812 LEDs;
- for USB low speed: a 1.5 kΩ pull-up on D− (`uio[0]`) and a USB connector. The electrical
  levels are still to be checked against the I/O pads.
