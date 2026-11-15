# Blind generality benchmark

**List committed on 2026-11-15, before any program, testbench or model for these protocols was
written.** This commit is the evidence that the set was not chosen after seeing what works.

## Why

The competition's main judging point is flexibility: can the chip be reprogrammed to support
protocols it was not designed for? This benchmark answers it with protocols picked in advance.
None of them was considered when the engine's instruction set and hardware were designed, and
none has a program in the repository at this commit.

The work is done by an independent implementer (Claude, an AI model, working from the public
protocol specifications and this repository's documentation) and the results are recorded
whatever they are.

## The list (fixed)

1. **DMX512 transmitter:** 250 kbaud 8N2, break >= 88 us, mark after break >= 8 us, start code
   and up to 512 slots.
2. **MIDI in and out:** 31.25 kbaud, running status on receive.
3. **LIN 2.x commander:** break, 0x55 sync, protected ID with parity, data, classic and enhanced
   checksum.
4. **IR NEC remote:** transmit (38 kHz carrier, 9 ms / 4.5 ms leader, pulse-distance bits,
   repeat code) and receive (demodulated input).
5. **Wiegand 26 and 34 reader:** two open-drain data lines, pulses of about 50 us, parity check.
6. **I2S transmitter:** controller (BCLK, LRCLK, SD), 16-bit stereo, from the TX FIFO.
7. **DShot600 transmitter:** 16-bit frames (11-bit throttle, telemetry bit, 4-bit CRC), 1.67 us
   bits, 0 = 37.5 % high, 1 = 75 % high.
8. **MDIO controller:** IEEE 802.3 clause 22: preamble, read and write frames, turnaround,
   MDC <= 2.5 MHz.

Then, the same kind of program-only work: SPI modes 1, 2 and 3 for the SPI controller and the
SPI peripheral (mode 0 exists); the I2C controller at 100 kHz and 400 kHz; UART at 9600 and
115200 baud.

## Rules

- **No RTL change at all:** `src/` is untouched from this commit to the last one of the
  benchmark. Programs, testbenches, models and documents only.
- A protocol **works** only if its testbench passes against an independent model written from
  the specification, in `make test`.
- **Works with limits** states the limit.
- **Can't** states exactly which hardware feature is missing.
- Failures are recorded as they are. A failure that points to a general instruction-set or
  hardware upgrade is useful evidence, and is written down as such.
- For each protocol: the result, the program size in words, and the time it took to write.

## Results

To be filled in as each protocol is attempted, in the order of the list.
