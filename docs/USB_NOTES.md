# USB notes (from the retired v2)

v2 added low-speed USB to the engine and worked: packets went out and came in correctly,
checked by independent models. It was retired because most of the new hardware was
USB-specific (a line unit with its own CRCs, eight USB-only sub-instructions), which pulled
the engine away from being a general protocol engine. This file keeps what v2 taught us, so
USB can come back later on top of general features instead.

The full v2 source is kept on the GitHub branch `archive/v2-usb` (`git checkout archive/v2-usb`; the files are in
`pbe_v2/`). The most useful files are `pbe_v2/src/pbe_usb_line.sv` (227 lines),
`pbe_v2/programs/usb_tx.pbe`, `pbe_v2/programs/usb_rx.pbe` and the USB models in
`pbe_v2/test/tb_pbe.sv`.

## 1. Facts about low-speed USB that drove the design

| Fact | Consequence |
|---|---|
| 1.5 Mbit/s, ±1.5 % allowed for a device | 48 MHz clock gives exactly 32 clocks per bit (50 MHz gives 33.3) |
| Full speed is 12 Mbit/s | 4 clocks per bit at 48 MHz: not realistic. Low speed only |
| Lines: J (idle) = D+ low, D− high; K = D+ high, D− low; SE0 = both low | Both pins must switch together with no skew: the pair needs hardware drive |
| NRZI: a 0 is a transition, a 1 is none | The engine cannot do it in software: there is no "branch on OSR bit" |
| Bit stuffing: a 0 after six 1s, also before EOP | Needs a counter of 1s; X is already the bit counter |
| SYNC = `0x80` sent LSB first → KJKJKJKK | Can be sent as a normal byte through the encoder, starting from J |
| EOP = SE0, SE0, J, then release | |
| CRC5 on tokens, CRC16 on data, LSB first, inverted | Checked with fixed residuals: CRC5 `01100`, CRC16 `0x800D` |
| Device must answer a token within ~7.5 bit times (~5 µs) | Far too fast for the host over SPI: the engine must answer by itself |
| 1.5 kΩ pull-up on D− (low speed), 3.3 V signalling | Electrical check against Tiny Tapeout I/O still open |

Checked values (useful as test vectors):
- DATA0 GET_DESCRIPTOR `C3 80 06 00 01 00 00 40 00` has CRC16 bytes `DD 94` (matches real traces).
- SETUP token `2D 00 10` passes CRC5; `2D 00 11` fails.
- The Modbus CRC-16 is the USB CRC-16 field inverted (same polynomial and bit order):
  frame `01 03 00 00 00 01` → USB field `7B F5`, Modbus `84 0A`.

## 2. What v2 built, and what worked

**USB line unit** (`pbe_usb_line.sv`, ~5,900 µm² per engine):
- Its own bit timer (`BITDIV`) and a 1-bit holding register. The engine only had to keep the
  holding bit full; a stuffed bit costs a bit time the program never sees. **Lesson:** an
  encoder that inserts bits must own the bit timing; timing it from the engine's ticks breaks.
- NRZI encode/decode, stuffing and unstuffing, SYNC detection in hardware (the engine cannot
  branch on bits, so it cannot find the end of SYNC itself), EOP generation and detection.
- Receiver samples mid-bit and **re-centres on every D+ edge**. Without that, ±1.5 % clock error
  fails on long packets (proved by a mutation test).
- CRC5 and CRC16 both running all the time: the receive program could not branch on the PID,
  so it reported both and the host picked the right one.

**Programs:** `usb_tx.pbe` (32 words: SYNC, PID, data, optional CRC16, EOP; host sets FLAG0 to
send, FLAG1 to append CRC) and `usb_rx.pbe` (13 words: every packet arrives as PID, bytes,
status).

**FIFOs had to grow from 4 to 16 bytes:** a packet must go out without gaps and the host
cannot feed bytes fast enough through SPI with status polling, so the whole packet is queued
first. This cost ~32,800 µm², more than the USB logic itself (~15,600 µm²).

**Tests that worked well** (worth reusing): a USB decoder monitor on the chip's pins, a USB
host model sending at +1.5 % and −1.5 %, a packet with a deliberate bit-stuffing error, a
packet with a flipped bit, and mutation tests (no re-centring, no stuffing).

## 3. Bugs and limitations found in v2

| Item | What happened | Keep in mind |
|---|---|---|
| BUG-008 | `NOP` assembled to `0xE000`, which v2 decoded as `UTX` | An opcode's "do nothing" encoding must stay a no-op forever |
| BUG-009 | The receiver dropped stuffed bits without checking they were 0 | Report a stuffing error (v2 used status bit 2) |
| BUG-005, BUG-006 | Icarus Verilog: hidden compile failures; crashes with automatic tasks and queues | Static testbench tasks, never filter compiler output broadly |
| Two CRCs at once | Needed because the program could not branch on the PID | A compare instruction removes this |
| No fast responder | ACK/NAK within 5 µs needs the engine to decide by PID | Needs compare-and-branch on received data |
| Opcode 111 fully used by USB | Left no room for anything else | The main reason v2 was retired |

## 4. How to bring USB back into the general engine

USB should come back as **general features that USB happens to use**, each useful to other
protocols too:

| Need | General feature | Also used by |
|---|---|---|
| CRC5, CRC16 | The general CRC unit (added to v1 now): any polynomial and width | Modbus, 1-Wire, CAN |
| NRZI, bit stuffing, pair drive, SYNC/EOP | A **line coder** stage between the shift registers and the pins, with modes: plain / NRZI + stuff-after-6-ones (USB) / NRZ + stuff-after-5-equal (CAN) / Manchester (MIL-STD-1553, 10BASE-T). Owns the bit timing like v2's line unit | CAN, 1553, Ethernet |
| Re-centring on edges | Part of the line coder's receiver | CAN (resynchronization), 1553 |
| Branch on PID, reply within 5 µs | **Compare-and-branch on received data** (e.g. jump if ISR equals OSR) | Modbus addresses, 1553 RT address, CAN IDs |
| Variable packet length | `MOV X, ISR` (loop count from received data) | CAN DLC, Modbus byte count, 1553 word count |
| Engines cooperating (RX engine tells TX engine to ACK) | Engine-relative flags with overlapping `FLAG_BASE` (done in v1) | Any full-duplex protocol |
| Whole packet queued before sending | Deeper FIFOs, or "auto-pull" so the engine refills the OSR itself | Fast SPI |

With those in place, USB low speed becomes mostly programs plus the line coder's USB mode,
instead of a USB block bolted onto the engine.
