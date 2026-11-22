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

`src/` is byte-for-byte the same as at the list commit (`git diff 856050e -- src` is empty).
Every bench below is in `make test` (`make test-blind`). "Time" is wall-clock from the first
line of the program to the bench passing, simulation included, by the AI implementer.

| # | Protocol | Result | Program (words) | Time | Bench (model) |
|---|---|---|---|---|---|
| 1 | DMX512 transmitter | **Works.** Passed at the first run | `dmx512_tx` (18) | 3 min | `tb_dmx`: an E1.11 receiver; 24, 513 and slowly fed slots; break 100 µs, mark after break 18 µs, edges within 3 ns of the 4 µs grid |
| 2 | MIDI in and out | **Works.** Passed at the first run | `midi_in` (85); out is `uart_tx` (8) unchanged, at 31.25 kbaud | 3 min | `tb_midi`: a MIDI 1.0 reference parser; 51 bytes with running status, real-time bytes inside messages and a system exclusive, expanded to 58; sender 1 % fast and slow |
| 3 | LIN 2.x commander | **Works with limits:** the host computes and checks the protected ID's parity and the checksum (classic and enhanced); the engine does the break, sync, bytes, the response and its timeout. The engine does not compare its echo (no bit-error detection) | `lin_commander` (49) | 8 min | `tb_lin`: a LIN 2.2A responder and header checker; published and subscribed frames, classic and enhanced checksum, a wrong checksum, no responder, at 19200 and 9600 baud |
| 4 | IR NEC transmit and receive | **Works with a limit on transmit:** one extra pin is used as a 1-bit scratch register (the bit is shifted out onto it and tested there). Receive works as is | `ir_nec_tx` (103), `ir_nec_rx` (48) | 26 min (22 of simulation) | `tb_ir`: an NEC decoder that measures the carrier (26.34 µs, 50 %) and every burst and space within 5 %, and an NEC remote 5 % fast and slow; frame, repeat code, extended frame, noise, a cut frame; both directions at once |
| 5 | Wiegand 26 and 34 reader | **Works with a limit:** it takes both engines (one watches the two lines, the other counts bits, checks both parities and times the frame out) | `wiegand` (92) + `wiegand_watch` (12) | 19 min (12 of simulation) | `tb_wiegand`: a reader-output model; 20-100 µs pulses 200 µs - 2 ms apart, both formats, wrong leading and trailing parity, a card cut off |
| 6 | I2S transmitter | **Works with a limit:** the sample rate is 60 MHz / (32 N) for a whole N, set by the program's delays: 48.08 kHz as written (+0.16 %); 44.1 kHz would be 1.2 % off. BCLK is exactly uniform | `i2s_tx` (119) | about 15 min | `tb_i2s`: a Philips-format receiver; 240 stereo samples streamed, a pause (silence, clocks running), every BCLK period 650.1 ns, set-up 250 ns |
| 7 | DShot600 transmitter | **Works.** The 4-bit checksum is computed by the CRC unit (polynomial x⁴ + 1) | `dshot600` (64) | 3 min | `tb_dshot`: an ESC-side decoder; 210 frames, every bit 1666.8 ns, highs 616.7 and 1250.1 ns, its own checksum check |
| 8 | MDIO controller (clause 22) | **Works.** Passed at the first run | `mdio` (73) | 2 min | `tb_mdio`: a PHY with the worst-case 300 ns output delay; ID reads, 6 registers written and read back, an absent PHY, at 2 MHz and 1 MHz; set-up 83 ns, no bus fight |

**Summary: 8 of 8 run with no hardware change; 4 with no limit, 4 with a stated limit; none
"can't".** Three programs passed at their first simulation; the others needed fixes to the
program (5 bugs, BUG-177 to 179, 181, 183, 184) or only to the test (the rest of BUG-175 to 186).

### Step 3: more of the same kind of work

| Item | Result | Programs (words) | Bench |
|---|---|---|---|
| SPI controller, modes 1, 2, 3 | **Works.** Mode 0's four instructions reordered | `spi_ctrl_m1`, `_m2`, `_m3` (16 each) | `tb_spimodes`: a peripheral model per mode that also checks the clock's idle level; 6 bytes both ways |
| SPI peripheral, modes 1, 2, 3 | **Works**, at 2 MHz as mode 0 | `spi_periph_m1` (20), `_m2` (21), `_m3` (20) | `tb_spimodes`: a controller model per mode; queued replies, the 0xFF default, 2 transactions |
| UART at 9600 and 115200 baud | **Works**, no program change (`CLKDIV` 3124/1562 and 259/129) | `uart_tx` (8), `uart_rx` (8) | `tb_rates`: a receiver sampling at the exact rate (worst edge 0.1 % / 1.4 % of a bit off the grid); a sender at the nominal rate and 2 % fast and slow, 30 bytes each |
| I2C controller at 100 and 400 kHz | **Works**, no program change (`CLKDIV` 85 and 21) | `i2c_ctrl` (34) | `tb_rates`: an I2C target (write 3, repeated START, read back 3, NACK) checking UM10204 timing: 99.7 kHz with SCL low 5.73 µs / high 4.30 µs (limits 4.7 / 4.0); 389.6 kHz with 1.47 / 1.10 µs (limits 1.3 / 0.6) |

### What the limits say about the instruction set

Each limit comes from one missing general feature, not from the protocol:

1. **No test of a data bit.** `JMP` tests a pin, a flag, X or the FIFO, never a bit of OSR or
   ISR. IR NEC transmit needed a scratch pin for it; MIDI in classifies a byte by testing the
   wire while its bits arrive (it works, but only because the data is on a pin at that moment).
   *Upgrade:* a jump on the bit that `OUT` would send next (or on ISR's newest bit).
2. **No adder.** LIN's checksum (a sum with carry) and the ID parity (the parity of chosen
   bits) go to the host. *Upgrade:* an add-with-carry into a register, or an up-counter.
3. **One counter, one wait, one timeout per engine.** Wiegand needs to watch two pins, count
   bits and time a frame out: more than one engine has, so it took both. *Upgrade:* a wait on
   either of two pins (or a pin mask), or a second counter.
4. **Timing by adding up delays.** I2S and DShot are exact because every path through the
   program was balanced by hand to the same number of clocks (and around the `PAGE` prefix,
   BUG-183). It works, but each rate is its own program. *Upgrade:* side-set (a clock pin
   toggled by the instruction that moves the data), which would also free the instruction
   slots the clock edges take.

These are the same upgrades `docs/STATUS.md` lists as candidates (multi-pin IN/OUT, side-set,
an up-counter/compare); the benchmark gives each one a protocol that would use it.

## Generality table: every protocol

Groups: **(a)** a program only, written after the hardware it runs on existed, with no RTL
change; **(b)** a program on the general hardware the engine started with; **(c)** it needed
new hardware, built to be general (and since used by other protocols); **(d)** it needed
protocol-specific hardware.

| Protocol | Program (words) | General hardware it uses | RTL added for it | Group |
|---|---|---|---|---|
| UART TX, RX | `uart_tx` (8), `uart_rx` (8) | pins, X, shift registers, FIFOs | none (the first programs) | b |
| SPI controller, mode 0 | `spi_ctrl` (16) | the same | none | b |
| I2C controller | `i2c_ctrl` (34) | open-drain pins, flags | none | b |
| SMBus PEC | `i2c_ctrl` | CRC unit as CRC-8 | none (D36) | a |
| SPI peripheral, mode 0 | `spi_periph` (21) | timeout vector | none (D35) | a |
| WS2812 | `ws2812` (8) | instruction delays | none (D34) | a |
| 1-Wire controller | `onewire_ctrl` (36) | open-drain pins, flags, CRC unit | none (D25) | a |
| I2C target | `i2c_target` (58) + `i2c_watch` (8) | both engines, shared flags | none for it (D37); it uses the per-engine flag base, added so two flag-using protocols can run at once (D11, D27) | a |
| Modbus RTU master | `modbus_rtu` (62) | CRC unit, parity, timeout | the CRC unit, the parity bit and the timeout vector (D29-D31) | c |
| USB 1.1 low-speed device | `usb_dev` (64) | line coder (NRZI, stuffing, pair), CRC | the line coder, JEQ/JNE/MOV, the CRC good value (D39-D41) | c |
| CAN 2.0A node | `can_node` (61) | CRC-15, FIFO mark/rewind | **the bit-synchronous block `pbe_bsync`: arbitration, error flags and confinement, the 2.0B frame follower (D66, D68, D74). CAN-specific** | **d** |
| JTAG controller | `jtag` (42) | pins, X | none (D75) | a |
| ARM SWD host | `swd` (64) | parity, open-drain turnaround | none (D76) | a |
| PS/2 host | `ps2_host` (74) | parity, timeout, open-drain | none (D84) | a |
| 24-bit GPIO expander | `gpio_expander` (33) | pins, X | none (D85) | a |
| Logic analyser, generator | `la_capture` (30), `wavegen` (16) | FIFOs, JMP pin | none (D86) | a |
| Quad SPI controller | `qspi_flash` (125) | PAGE | none (D87) | a |
| HDLC / SDLC, NRZ | `hdlc_tx` (41), `hdlc_rx` | line coder (stuffing after 5 ones), CRC-16 | none (D88) | a |
| HDLC / SDLC, NRZI | the same, `hdlc_rx` (43) | line coder | stuffing off/on and flag-delimited frames in the line coder (D94) | c |
| 10BASE-T Ethernet | `eth_tx` (52), `eth_rx` (17) | line coder (Manchester), CRC-32, quad host port | Manchester coding, the 32-bit CRC, the quad host port, 60 MHz (D89-D92) | c |
| UART <-> I2C bridge | `bridge_uart` (18), `bridge_i2c` (161) | FIFO link | the engine-to-engine FIFO link (D102) | c |
| **DMX512 transmitter** | `dmx512_tx` (18) | flags | **none** (D106) | **a (blind)** |
| **MIDI in / out** | `midi_in` (85), `uart_tx` (8) | JMP pin, flags | **none** (D107) | **a (blind)** |
| **LIN commander** | `lin_commander` (49) | timeout vector, flags | **none** (D108) | **a (blind)** |
| **IR NEC TX / RX** | `ir_nec_tx` (103), `ir_nec_rx` (48) | JMP pin, flags, timeout | **none** (D109) | **a (blind)** |
| **Wiegand 26 / 34** | `wiegand` (92), `wiegand_watch` (12) | both engines, shared flags, parity, two timeouts | **none** (D110) | **a (blind)** |
| **I2S transmitter** | `i2s_tx` (119) | instruction delays, PULL NOWAIT, PAGE | **none** (D111) | **a (blind)** |
| **DShot600** | `dshot600` (64) | CRC unit (4 bits), instruction delays | **none** (D112) | **a (blind)** |
| **MDIO controller** | `mdio` (73) | pins, X | **none** (D113) | **a (blind)** |
| **SPI modes 1-3** | 3 x `spi_ctrl_mN` (16), 3 x `spi_periph_mN` (20-21) | timeout vector | **none** (D114) | **a (blind)** |

Counts: of the 19 protocols before the benchmark, 3 are (b), 12 are (a), 3 are (c) (Modbus,
USB, Ethernet) and 1 is (d) (CAN). HDLC is counted once, as (a); its NRZI variant and the
bridge (not one of the 19) are (c). The benchmark adds 8 protocols and the SPI modes, all (a).
The only protocol-specific hardware in the chip is CAN's. The classification of the earlier
protocols is taken from their decision entries (the D numbers given).
