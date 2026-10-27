# Design decisions

The decisions behind the Programmable Bit Engine (PBE): what was chosen, the alternatives
considered, and why. Decisions that a new protocol forced us to change are marked
**Changed** with the protocol that caused it, so the reasoning behind both versions is kept.

Keep this file current: add an entry for every new decision, and when a decision changes,
mark the old one **Changed** instead of deleting it.

| Version | Folder | Protocols |
|---|---|---|
| v1 | `pbe_v1/` | UART, SPI, I2C, 1-Wire, Modbus RTU |
| v2 | `pbe_v2/` | v1 plus low-speed USB |

## Changes forced by new protocols

| Protocol that arrived | What it broke | Change | Entry |
|---|---|---|---|
| SPI (full duplex) | One shift register cannot send and receive on the same clock | Split into OSR (out) and ISR (in) | D9 |
| I2C | Controller program is 34 words; memory held 32 | Program memory 32 → 64 words, 6-bit PC | D4 |
| I2C (via D4) | 64 words no longer fit the direct-mapped register window | Pointer + data register for loading programs | D13 |
| I2C | Needs START/STOP/repeated START, but the engine cannot branch on data bits | Host requests them through shared flags | D19 |
| USB | NRZI, bit stuffing and CRC per bit are too slow and need state the engine lacks | Hardware USB line unit on opcode 111 | D20 |
| USB | A packet must leave the chip without gaps; 4-byte FIFOs cannot hold one | FIFOs 4 → 16 bytes (v2) | D10 |
| USB | 50 MHz gives 33.3 clocks per USB bit | Target clock 48 MHz | D18 |
| USB (via D20) | Opcode 111 now does something, so `NOP` = `0xE000` became `UTX` | `NOP` re-encoded as a no-op `FLAG` | D6, BUG-008 |
| 1-Wire, Modbus RTU | Nothing: both are programs on the existing instructions | — | D25, D26 |
| Modbus RTU (its test) | Restart could glitch a high pin low, a false start bit | Restart releases pins but keeps their values | D24, BUG-013 |

---

## D1. Hardware description language

- **Chosen:** SystemVerilog, restricted to what Yosys reads (`logic`, `always_ff`,
  `always_comb`, packed buses, no interfaces, structs or unpacked port arrays).
- **Alternatives:** Hardcaml (Jane Street's own HDL), plain Verilog-2005, Chisel, Amaranth.
- **Why:** You asked for SystemVerilog. Tiny Tapeout's flow reads it through Yosys, and it keeps
  the testbench in the same language. Hardcaml would be the strongest signal to Jane Street
  but needs OCaml.
- **Consequence:** Per-engine arrays in the top level were flattened into buses
  (`clkdiv[e*16 +: 16]`) because Yosys and Icarus handle unpacked arrays poorly (D23).

## D2. Core architecture: a programmable engine

- **Chosen:** A tiny processor ("engine") whose instructions are the primitive actions every
  protocol is made of: drive / release / read a pin, wait, shift a bit, loop, branch, move bytes.
  Each protocol is a program loaded at runtime.
- **Alternatives:**
  1. Table-driven state machine (state × pin condition → action, next state).
  2. Hardwired UART + SPI + I2C blocks behind a mux.
  3. A general CPU core (RISC-V) bit-banging pins.
- **Why:** The competition requires reprogrammability after fabrication. (2) cannot learn new
  protocols. (1) is compact but hard to program by hand. (3) is far too slow per bit and too
  big. An engine whose instructions are the protocol primitives is small, fast enough, and
  easy to write programs for. The Raspberry Pi RP2040 PIO uses this idea; we deliberately
  differ from it (delay on every instruction, WAIT that restarts the timer, open-drain pin
  action, USB line unit) instead of copying it.

## D3. Two engines

- **Chosen:** Two identical engines.
- **Alternatives:** One engine; four engines.
- **Why:** Some protocols need two things at once: UART TX and RX are independent, and
  running two protocols side by side (UART + I2C) is a strong demo. One engine cannot do
  either. Four would multiply area for a benefit no protocol so far needs; with area use at
  15–21 %, adding engines later remains possible.

## D4. Shared program memory, 32 → 64 words — **Changed (I2C)**

- **Chosen originally:** 32 × 16-bit words shared by both engines, flip-flop based,
  each engine with its own start address (`START_PC`).
- **Changed:** The I2C controller needed 34 words. Memory became 64 words and the PC 6 bits.
- **Alternatives considered at the change:**
  1. Squeeze I2C below 32 words (merge routines, drop the TX-first check). Possible only by
     removing features or making the host protocol racy.
  2. Separate memory per engine. Wastes words when one engine runs a short program.
  3. 64 shared words.
- **Why (3):** Area use was only 10 %, so +25k µm² was affordable. The JMP address field had a
  spare bit, so the instruction format did not change. 64 words also let UART TX + I2C, or
  USB TX + USB RX, sit in memory together.
- **Cost:** v1 area 91,779 → 141,141 µm². Timing barely moved (3.56 → 3.61 ns).

## D5. Instruction format

- **Chosen:** 16 bits: `[15:13] OP | [12:4] ARG | [3:0] DELAY`. Every instruction can idle
  0–15 extra ticks after it runs.
- **Alternatives:** A separate WAIT/DELAY instruction and no delay field; wider (24-bit) words.
- **Why:** Protocol timing is mostly "do X, then hold for a moment". A delay on every
  instruction makes programs much shorter (UART TX is 8 words). 16 bits keeps memory small.

## D6. The opcode set

| OP | Instruction | Why it exists |
|---|---|---|
| 000 | `PIN p, act` | Drive 0/1, release, toggle, send an OSR bit, open-drain send. Covers push-pull, tri-state and open-drain with one pin model (D8) |
| 001 | `IN p` | Sample a pin into the ISR |
| 010 | `WAIT` | Wait for a pin or flag level or edge: start bits, clock edges, I2C clock stretching |
| 011 | `JMP cond` | Loops (X--), ACK/NACK and glitch checks (pin), host handshakes (FIFO, flags) |
| 100 | `SET X/OSR` | Bit counts and constants (USB SYNC) |
| 101 | `PULL/PUSH` | Bytes to and from the host |
| 110 | `FLAG` | Coordination between engines and with the host; host interrupt |
| 111 | v1: reserved, v2: USB sub-ops | Kept free for add-ons; used by USB in v2 (D20) |

- **`NOP` — Changed (USB):** The assembler originally emitted opcode 111 with argument 0 for
  `NOP`. That was harmless in v1 but in v2 the same word is `UTX`. `NOP` is now `FLAG` with
  action 3, which has no effect in either version (BUG-008).

## D7. Timing: tick divider, WAIT checks every clock and restarts the divider

- **Chosen:** Each engine has a 16-bit `CLKDIV`; one tick every `CLKDIV + 1` clocks.
  A blocked instruction (WAIT, PULL, PUSH, USB) is re-checked every clock, and when it
  completes the tick divider restarts.
- **Alternatives:** Re-check only on ticks; free-running divider.
- **Why:** Re-checking every clock means a short edge is never missed. Restarting the
  divider means the next instructions are timed from the moment the condition was met. This
  is what lets UART RX land its samples in the middle of each bit without extra hardware.

## D8. Pin model

- **Chosen:** Every pin has an output value, an output enable, and a synchronized input.
  Pin numbers in instructions are relative to a per-engine `PIN_BASE` (mod 8). A separate
  `JMP_PIN` selects the pin for `JMP PIN_HI/PIN_LO`.
- **Alternatives:** Fixed pin numbers in programs; separate open-drain hardware for I2C.
- **Why:** One model gives push-pull, tri-state and open-drain (value 0, toggle the enable),
  so I2C needs no special hardware. Relative pins let the same program run on any pins.

## D9. Shift registers: one → OSR + ISR — **Changed (SPI)**

- **Chosen originally:** One 8-bit shift register for both directions.
- **Changed:** SPI is full duplex. Sending and receiving on the same clock with one register
  would shift twice per bit.
- **Chosen now:** OSR (output, loaded by `PULL`, shifted by `OUT`) and ISR (input, filled
  by `IN`, emptied by `PUSH`), each with its own LSB/MSB-first setting.
- **Alternative:** One register with a combined "exchange bit" instruction. Rejected: costs
  an opcode slot and complicates every other protocol.
- **Cost:** 8 more flip-flops per engine.

## D10. FIFOs, 4 → 16 bytes — **Changed (USB, v2 only)**

- **Chosen originally:** 4-byte TX and RX FIFO per engine; `PULL`/`PUSH` block when
  empty/full.
- **Changed in v2:** A USB packet must leave the chip without gaps, but the host feeds
  bytes at most at ~6 Mbit/s over SPI with polling in between. The host now queues the whole
  packet (up to 16 bytes) before sending.
- **Alternatives:** Faster host link; a separate packet buffer. A deeper FIFO is the
  simplest and also helps SPI bursts.
- **Cost:** about 32,800 µm², most of v2's growth.

## D11. Shared flags

- **Chosen:** 4 flags shared by both engines and writable by the host. Engines can set,
  clear, wait on and branch on them; `FLAG n, IRQ` interrupts the host.
- **Why:** The cheapest way for engines to coordinate, and the way the host asks the
  I2C program for START/STOP (D19) and the USB program to send (D20).

## D12. Host interface: SPI peripheral

- **Chosen:** SPI mode 0 on `ui_in[2:0]` / `uo_out[0]`: a command byte (R/W + 7-bit address)
  then data bytes. The address auto-increments, except for streaming registers (FIFO data,
  program data) so a burst can pour bytes into one register. All host inputs pass through
  2-flip-flop synchronizers, so host SCK must be at most clk/8.
- **Alternatives:** A parallel bus on the 8 input pins plus strobes; a UART host port.
- **Why:** 4 wires, any microcontroller (or the Tiny Tapeout demo board's RP2040) can drive
  it, and it leaves the 8 bidirectional pins free for protocols.

## D13. Loading programs: direct-mapped → pointer register — **Changed (I2C, via D4)**

- **Chosen originally:** Program memory mapped at register addresses 0x40–0x7F (32 words ×
  2 bytes).
- **Changed:** 64 words need 128 bytes, more than the 7-bit address space has left.
- **Chosen now:** `PM_ADDR` (0x06) holds a byte pointer, `PM_DATA` (0x07) writes a byte and
  advances it. A program loads in one SPI burst.
- **Alternative:** An 8-bit address command. Rejected: changes the host protocol for every
  register.

## D14. Program memory is write-only

- **Chosen:** The host cannot read program memory back.
- **Why:** A third read port is a 64:1 × 16-bit mux. Engines read it through their own
  ports; tests verify programs by behaviour.

## D15. Pin ownership mask

- **Chosen:** `PIN_OWN`, one bit per pin: which engine drives it. Both engines can always
  read every pin.
- **Alternative:** Fixed priority (engine 0 wins). Rejected: silent conflicts.

## D16. Input synchronizers; glitch filter deferred

- **Chosen:** 2 flip-flops on every input pin and host input.
- **Deferred:** A glitch filter (on the diagram, not built yet). I2C in fast mode specifies
  50 ns spike suppression, so it will be needed for I2C robustness.

## D17. Pin assignment

- **Chosen:** Protocol pins on `uio[7:0]` (the only pins with output enables), host SPI on
  `ui_in[2:0]` / `uo_out[0]`, IRQ and status on `uo_out[7:1]`.

## D18. Clock frequency: 48 MHz — **Changed (USB)**

- **Chosen:** Plan for 48 MHz. The competition sets no frequency; Tiny Tapeout's clock pad is
  specified to about 66 MHz.
- **Earlier assumption:** 50 MHz, a round number with margin under 66 MHz.
- **Why changed:** USB low speed is 1.5 Mbit/s: exactly 32 clocks per bit at 48 MHz, 33.3 at
  50 MHz (1 % error). UART and I2C rates divide well from 48 MHz too.
- **Margin:** worst path ~4.8 ns at the slow corner (logic plus flip-flop overhead) vs 20.8 ns
  per cycle, roughly 4×.

## D19. Protocol host conventions

- **UART:** TX uses tick = ½ bit, RX uses tick = ¼ bit so a `WAIT LOW [1]` lands half a bit
  into the start bit. RX checks the line again there and drops glitches. Bit 7 is handled
  outside the loop so the program is back in `WAIT` inside the stop bit.
- **SPI controller:** CS stays low while the host keeps the TX FIFO fed.
- **I2C controller:** Each I2C byte is two FIFO bytes, `[data] [ack]`, and returns
  `[byte seen on SDA] [ACK bit]`. Reads and writes are the same 9-bit open-drain exchange.
  START and STOP are requested with FLAG0 and FLAG1.
  - **Alternative:** A command byte decoded by the program. Rejected: the engine cannot branch
    on data bits, so decoding would need new instructions.
  - **Changed (review):** SCL is now 4 ticks low and 3 high (it was 3 low, 4 high, which breaks
    the I2C minimum low time), and FLAG1 is cleared after STOP completes (BUG-010, BUG-011).

## D20. USB: a hardware line unit (v2) — **Changed (USB)**

- **Chosen:** A small line unit per engine on opcode 111. It does NRZI, bit stuffing and
  unstuffing, SYNC detection, EOP, CRC5 and CRC16, and re-centres sampling on every D+ edge.
  The engine still runs the packet logic: what to send, when, and what to do with what
  arrives.
- **Alternatives:**
  1. Pure software on the engine. Rejected: no way to test an OSR bit (needed for NRZI), X is
     taken by the bit counter so nothing counts 1s for stuffing, and the CRC per bit costs
     many instructions.
  2. Line unit timed by the engine's ticks. Rejected: a stuffed bit adds a bit time the
     program cannot see, so timing breaks. The line unit has its own bit timer (`BITDIV`) and a
     1-bit holding register, and the engine just keeps it fed.
- **Low speed only:** full speed (12 Mbit/s) is 4 clocks per bit at 48 MHz.
- **SYNC handled in hardware:** the engine cannot branch on bits, so the line unit strips SYNC.
- **Both CRCs always run;** the program reports both (`STAT`) and the host picks the right one
  by PID, because the program cannot branch on the PID yet.
- **Bit stuffing errors** are reported in `STAT` bit 2 (BUG-009).
- **Cost:** about 15,600 µm² for USB logic (one line unit is 5,733 µm²).
- **v2 is a separate copy** so v1 stays a clean UART/SPI/I2C design.

## D21. Verification approach

- **Chosen:** End-to-end testbench that touches only the chip's pins. Every protocol is
  checked by a model written independently of the RTL (UART monitor, SPI peripheral, I2C
  register device with clock stretching, USB decoder and USB host with ±1.5 % clock error).
  Each important feature is checked by breaking it on purpose and confirming the test fails.
  Simulator: Icarus Verilog.
- **Lessons:** A test that passed with the feature removed was strengthened (BUG-004). Icarus
  bugs with automatic tasks and queues led to static tasks for the USB helpers (BUG-006).
  A failing test must give a non-zero exit code (BUG-007).
- **Waveforms are opt-in** (`vvp sim.vvp +vcd`): 1-Wire and Modbus need ~70 ms of simulated time
  and the dump would be ~165 MB.
- **Static tasks share variables:** give every caller-side variable its own name (BUG-016).
- **Planned:** third-party protocol decoders (sigrok), a Python golden model with random
  programs, formal properties (SymbiYosys), mutation score (MCY).

## D22. Area and timing method

- **Area:** Yosys synthesis with IHP's sg13g2 standard-cell library (typical corner).
  Tiny Tapeout's CMOS5L cell list uses the same cell names; no separate CMOS5L library is
  public.
- **Timing:** OpenSTA could not be built here (a dependency from a third-party mirror was
  blocked), so timing uses ABC's `stime` with the slow-corner library (1.08 V, 125 °C).
  Flip-flop clock-to-Q (~0.57 ns) and setup (~0.31 ns) are added by hand. Wire delay and
  clock skew are not included; the place-and-route report is the final word.

## D23. Synthesis-friendly coding

- Per-engine signals in the top level are flat buses, not unpacked arrays.
- Combinational selectors are named wires (Icarus `always_comb` limitation).
- `exec` is declared before use (strict tools reject use-before-declaration).
- Storage arrays (program memory, FIFO data) have no reset, which saves area; they are
  always written before being read.

## D24. Restart cancels the instruction in flight

- **Chosen:** `exec` is forced low while `restart` is high, so an instruction that would
  complete in that cycle has no side effects (no FIFO pop or push, no flag change, no IRQ, no
  USB line unit input).
- **Alternative:** Let it complete and restart one cycle later. Rejected: the host expects
  restart to take effect at once, and the completed instruction would still act on a state
  that is being thrown away.
- **Cost:** one AND gate on the `exec` path; the worst path grew by about 0.2 ns. (BUG-012)
- **Changed (Modbus RTU test):** restart used to clear pin output values as well as enables.
  A pin driving high could then glitch low (BUG-013). Restart now only releases pins and keeps
  their values, so released lines float to their pull-ups cleanly. Programs set a value before
  toggling a pin, so the stale value is harmless.

## D25. 1-Wire controller (program only)

- **Chosen:** `programs/onewire_ctrl.pbe`, 30 words, tick = 1 µs. A write-1 slot and a read slot
  are identical on the wire (6 µs low, then released), so one slot routine does both, like the
  I2C 9-bit exchange: `OUTOD` keeps DQ low for a 0 and releases it for a 1, and `IN` samples at
  13 µs. To read, the host sends `0xFF`.
- **Reset/presence:** requested with FLAG0; a `JMP X--` loop with a 16-tick delay makes the
  480 µs pulse. The flag is cleared only when the reset is finished (lesson of BUG-011).
- **Search ROM:** needs a decision after every 2 bits read. The engine cannot branch on data, so
  FLAG1 switches the program to single slots and the host runs the search algorithm (Maxim
  AN187). 1-Wire has no maximum gap between slots, so host round trips are fine.
- **Alternatives:** a hardware 1-Wire master (rejected: the point is a reprogrammable engine);
  separate read and write routines (rejected: twice the code for identical wire activity).
- **Left to the host:** CRC8, and the strong pull-up some parasite-powered devices need
  (`PIN dq, DRV1`). Overdrive speed needs a second program with a finer tick.

## D26. Modbus RTU master (program only)

- **Chosen:** `programs/modbus_rtu.pbe`, 33 words, RS-485 half duplex on one engine: TX, RX and a
  driver-enable pin. Tick = 1/8 bit.
- **Parity:** the engine cannot compute parity, so each character is two TX bytes,
  `[data] [parity]`; the parity byte's bit 0 is sent after the data. The same program does
  8E1, 8O1 or 8N2 (send 1 as a second stop bit). Received parity comes back in a status byte.
  - **Alternative:** a parity flip-flop in the shifter (about 10 cells, pin actions 6–7 are
    free). Deferred: not needed yet.
- **End of frame (3.5 characters of silence):** `WAIT` has no timeout, so after each character
  the program polls for the next start bit in a 2-tick loop counted by X. At the end it sets
  FLAG2 and raises IRQ.
  - **Limit:** X is 8 bits, which covers the character-based timing Modbus uses up to
    19200 baud. Above that Modbus specifies fixed 1.75 ms gaps, which need more than 255 polls.
  - **Alternative:** a WAIT-with-timeout counter in hardware. Deferred; also useful for I2C
    stuck-bus recovery and CAN.
  - The 2-tick poll catches a start bit up to 1/4 bit late; sampling is aimed so the error is
    about ±1/8 bit.
- **End of request:** FLAG1, set by the host once everything is queued (TX FIFO empty). The
  engine turns the driver off after the last stop bit, then clears FLAG1.
- **CRC:** computed by the host. (v2's USB CRC unit computes the same CRC-16; Modbus is the
  inverted USB field.)
- **Not checked by the receiver:** the 1.5-character maximum gap inside a frame.

## D27. Shared flags limit which protocols can run together

- **Observation:** `JMP` can only test FLAG0 and FLAG1, and flags are shared by both engines.
  I2C, USB TX, 1-Wire and Modbus all use FLAG0 or FLAG1, so two of them cannot run on the two
  engines at the same time. UART and SPI use no flags and can run next to any of them.
- **Not changed yet.** Options: give each engine its own pair of flags (numbered relative to the
  engine), or let `JMP` test all four flags.
