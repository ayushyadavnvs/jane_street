# Design decisions

The decisions behind the Programmable Bit Engine (PBE): what was chosen, the alternatives
considered, and why. Decisions that a new protocol forced us to change are marked
**Changed** with the protocol that caused it, so the reasoning behind both versions is kept.

Keep this file current: add an entry for every new decision, and when a decision changes,
mark the old one **Changed** instead of deleting it.

| Version | Folder | Protocols |
|---|---|---|
| v1 | `pbe_v1/` | UART, SPI controller and peripheral, I2C controller and target, SMBus PEC, 1-Wire, Modbus RTU, WS2812, USB low-speed device (control endpoint); CRC unit, parity bit, WAIT timeout, line coder |
| v2 (retired, D28) | branch `archive/v2-usb` | v1 plus low-speed USB; lessons in `docs/USB_NOTES.md` |

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
| Two protocols at once (I2C + 1-Wire) | Shared FLAG0/FLAG1: each engine took the other's requests | 8 flags, engine-relative via `FLAG_BASE`; host `FLAG_SET`/`FLAG_CLR` | D11, D27, BUG-017 |
| USB (v2) | Opcode 111 and a line unit became USB-only: the engine drifted away from general | v2 retired; general features instead | D28 |
| Modbus RTU, 1-Wire | Host had to compute CRC and parity; 3.5-character silence limited Modbus to 19200 baud | General CRC unit, parity bit, WAIT timeout on opcode 111 / pin action 6 | D6, D26, D29–D31 |
| 1-Wire (strong pull-up) + I2C at once | 35 + 34 words did not fit the shared 64-word memory; Modbus alone is 56 | 128-word memory, jumps relative to `START_PC` | D4, D13 |
| Modbus 8N2, 1-Wire inverted CRC-16 | `OUTPAR` always sent parity; "CRC ok = zero" cannot check inverted CRCs | No-parity bit in `LINE_CFG`; CRC value readable by the host | D29, D30 |
| WS2812, SPI peripheral | Nothing: both are programs on the existing instructions (the SPI peripheral uses the timeout vector to see the end of a transaction) | — | D34, D35 |
| SMBus PEC | The I2C controller fed its ACK bits into the CRC, but a PEC covers bytes only | The ACK slot's `IN` is marked `NOCRC` (program change) | D36, BUG-022 |
| I2C target | START/STOP are SDA edges while SCL is high: one engine cannot wait on two pins at once | Both engines run it, sharing flags: one watches for START/STOP, one shifts bits (no hardware change) | D37 |
| USB (back in v1) | NRZI, bit stuffing and a 32-clock bit with no gaps cannot be done one instruction per bit; SE0 needs both pins at once | A general line coder (NRZ/NRZI, three stuffing rules, pair mode, SYNC hunt, byte transfers) | D39 |
| USB | The device must pick its reply by PID and address within 7.5 bit times | `JEQ`/`JNE`/`JLINE` and `MOV`; opcode 111 now has one free sub-op | D6, D32, D40 |
| USB | Its CRC16 is sent inverted: "CRC ok = zero" never holds | `CRC_GOOD`: "ok" = the register equals a set value (USB's residual 0x800d) | D29, D41 |
| USB | A packet must leave without gaps and a SETUP arrives at line rate | FIFOs 4 → 16 bytes (now in v1) | D10 |
| USB | New per-engine settings, but +0..+F were full | Second register page per engine at 0x30 / 0x40 | D32, D44 |
| USB (its firmware) | Burst reads could lose a byte; a flush on SETUP threw away an OUT record | `RX_COUNT`/`TX_COUNT` registers, `TX_FLUSH` | D43, BUG-030, BUG-031 |
| 48 MHz (USB, D18) in the first routed run | 0.586 ns of setup slack: pc → program memory → decode → next pc in one clock, through long buffer chains | An instruction register with a prefetch; four copies of the read address. A taken jump costs one clock more at CLKDIV = 0 | D7, D18, D50 |

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

## D4. Shared program memory, 32 → 64 → 128 words — **Changed (I2C, then two protocols at once)**

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
- **Changed again (1-Wire strong pull-up made it 35 words):** 1-Wire + I2C (69 words) no longer
  fit, and Modbus (56) could not run beside anything but UART TX.
- **Chosen now (decided with you):** 128 words, and every jump (`JMP`, `JCRCBAD`, the timeout) is
  relative to the engine's `START_PC`. Each engine works in its own 64-word window, any two
  programs of up to 64 words can run together, and programs load anywhere (the assembler labels
  each program from 0). The PC stays an absolute 7-bit address, so the add happens on the jump
  path, not the instruction-fetch path. Same idea as `PIN_BASE` and `FLAG_BASE`.
- **Alternatives:** two separate 64-word memories (same area, but loaded separately and no
  shared code); squeezing programs onto a 2 µs 1-Wire tick to fit 64 words (fragile, and Modbus
  still could not share).
- **Cost:** 164,095 → 262,618 µm² (18 % → 29 % of 6×4). I estimated +49,000 µm² beforehand; the
  real cost is about twice that, because doubling the words also doubles both engines'
  128-way read multiplexers. Worst logic path 3.97 ns.
- **Next option:** latches instead of flip-flops for program memory (31 µm² per bit instead of
  ~67 µm² for a flip-flop with its write multiplexer) could save about 70,000 µm². Program memory
  is written rarely by the host, which suits latches, but latch timing in the Tiny Tapeout flow
  needs checking first.

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
| 111 | `EXT` sub-ops: `CRCRST`, `OSRCRC`, `STAT`, `JCRCBAD`, `JEQ`, `JNE`, `JLINE` (7 of 8 used) | **Changed:** was reserved; v2 used it for USB (D20, retired). Then general extensions (D29–D31). **Changed again (USB in v1):** sub-ops 4–6 are the compare and line-event jumps (D40); sub-op 7 stays free |

- **`NOP` — Changed (USB):** The assembler originally emitted opcode 111 with argument 0 for
  `NOP`. That was harmless in v1 but in v2 the same word is `UTX`. `NOP` is now `FLAG` with
  action 3, which has no effect in either version (BUG-008).
- **`MOV` — added (USB in v1):** `FLAG` action 3 with a non-zero destination field is
  `MOV dst, src` (D40). `NOP` (`0xD800`, destination 0) is still a no-op, as BUG-008 requires.
- **`PIN p, END` — added (USB in v1):** pin action 7 ends a line-coder frame (D39).

## D7. Timing: tick divider, WAIT checks every clock and restarts the divider — **Changed (48 MHz place and route, D50)**

- **Chosen:** Each engine has a 16-bit `CLKDIV`; one tick every `CLKDIV + 1` clocks.
  A blocked instruction (WAIT, PULL, PUSH, USB) is re-checked every clock, and when it
  completes the tick divider restarts.
- **Alternatives:** Re-check only on ticks; free-running divider.
- **Why:** Re-checking every clock means a short edge is never missed. Restarting the
  divider means the next instructions are timed from the moment the condition was met. This
  is what lets UART RX land its samples in the middle of each bit without extra hardware.
- **Changed (the first routed run at 48 MHz):** instructions now run from an instruction
  register (D50). With `CLKDIV` ≥ 1 every time above is exactly as before. With `CLKDIV` = 0
  (and under the line coder) a taken jump takes one clock more, and a tick that falls on that
  fetch bubble is held for the clock instead of being lost.

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

## D10. FIFOs, 4 → 16 bytes — **Changed (USB, v2; and in v1 since USB came back)**

- **Chosen originally:** 4-byte TX and RX FIFO per engine; `PULL`/`PUSH` block when
  empty/full.
- **Changed in v2:** A USB packet must leave the chip without gaps, but the host feeds
  bytes at most at ~6 Mbit/s over SPI with polling in between. The host now queues the whole
  packet (up to 16 bytes) before sending.
- **Alternatives:** Faster host link; a separate packet buffer. A deeper FIFO is the
  simplest and also helps SPI bursts.
- **Cost:** about 32,800 µm², most of v2's growth.
- **Changed in v1 (USB, D42):** the same reason, now in v1. A low-speed IN packet (PID and up to
  8 bytes) and a SETUP record (14 bytes) each fit; v1 measured +33,121 µm². Every protocol gains
  host-latency tolerance. Two tests leaned on the old depth: the I2C target's "more than the
  FIFO holds" write grew from 5 to 20 bytes so it still makes the engine stretch SCL on a full
  FIFO; the Modbus overflow round still overflows (18 bytes for 9 characters).

## D11. Flags — **Changed (running two protocols at once)**

- **Chosen originally:** 4 flags shared by both engines and writable by the host. Engines can
  set, clear, wait on and branch on them; `FLAG n, IRQ` interrupts the host.
- **Why:** The cheapest way for engines to coordinate, and the way the host asks the
  I2C program for START/STOP (D19) and the USB program to send (D20).
- **Changed:** protocols that use flags could not run on both engines at once (D27, BUG-017).
- **Chosen now:** 8 flags. Each engine sees 4 of them starting at its `FLAG_BASE` (engine
  register +8): "FLAG n" in a program is physical flag `(FLAG_BASE + n) mod 8`. Defaults: engine
  0 has flags 0–3, engine 1 has flags 4–7. Overlapping bases make flags shared again when the
  engines must signal each other (the planned USB responder). The host changes single flags
  through `FLAG_SET` (0x08) and `FLAG_CLR` (0x09), so it never overwrites the other engine's flags.
- **Alternatives considered:**
  1. Let `JMP` test all 4 flags and give each program different flag numbers. Rejected: needs a
     wider condition field, and every program would have to be edited for every pairing.
  2. Fully private flags per engine. Rejected: engines could no longer coordinate.
  3. Relative flags with a base, like `PIN_BASE` for pins. Chosen: programs do not change,
     and sharing is still a configuration choice.
- **Cost:** about 2,700 µm² (+2 %).

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
  advances it. A program loads in one SPI burst. With 128 words (D4) the pointer uses all 8 bits.
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
- **Margin:** worst path ~4.9 ns at the slow corner (logic plus flip-flop overhead) vs 20.8 ns
  per cycle, roughly 4×.
- **Changed (the margin, first routed run):** that estimate had no wires. Routed, the same path
  took 19.6 ns and left 0.586 ns of slack at the slow corner, mostly in buffer chains on the
  program counter. The clock stays at 48 MHz (USB needs it); the path was cut in two instead
  (D50).

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

## D20. USB: a hardware line unit (v2) — **Retired (D28)**

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
- **Two host processes** (for protocols running at once) share the host port through a fair
  ticket lock (BUG-018), and the tests change flags through `flag_set` / `flag_clear` /
  `flag_get` helpers that know each engine's flag window.
- **Testbench clock = planned clock (48 MHz)** since BUG-020; it had been 50 MHz.
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

## D25. 1-Wire controller (program only) — **Changed (strong pull-up)**

- **Now 36 words.** FLAG0 has two meanings: with nothing queued it requests a reset; set *after*
  a byte is queued it requests a strong pull-up after that byte (DQ driven hard high from 6 µs
  after the last slot until the host clears FLAG0), which parasite-powered devices need during
  CONVERT T. The idle loop therefore checks for queued bytes before FLAG0.
  - **Changed (BUG-038):** the program tests FLAG0 *before* pushing the byte seen, and the
    pull-up path pushes only after driving DQ high. A `PUSH` blocks while the RX FIFO is full,
    and the pull-up must not wait for the host (a DS18B20 needs it within 10 µs). Was 35 words.
  - **Alternative:** a separate flag for the pull-up. Rejected: `JMP` can only test FLAG0 and
    FLAG1, and FLAG1 is single-slot mode.
- **CRCs** are checked with the CRC unit through the host registers (D29): CRC-8 by "CRC ok",
  inverted CRC-16 by reading the CRC value.
- The text below describes the first version.

### First version

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

## D26. Modbus RTU master — **Changed (CRC, parity, timeout hardware; frame validity, D47)**

- **Changed (D47):** the receiver now rejects a frame with a pause of more than 1.5 characters,
  and the timeout is 1.5 characters at every baud rate (it was 3.5 characters up to 19200 baud
  and 1.75 ms above). 62 words.
- **Before D47:** `programs/modbus_rtu.pbe`, 56 words, uses the CRC unit (D29), the parity bit (D30) and
  the timeout (D31). The host sends only data bytes; the engine adds parity and appends the CRC,
  checks received parity and CRC, finds start bits with `WAIT FALL` (exact, instead of a 2-tick
  poll) and ends a frame with the timeout. The 19200-baud limit is gone (tested at 115200).
  FLAG0 is used inside the program as "in a frame". The text below describes the first version.

### First version (program only)

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
- **Not checked by the receiver:** the 1.5-character maximum gap inside a frame. **Changed:**
  checked since D47 (BUG-039).

## D27. Shared flags limit which protocols can run together — **Resolved by D11**

- **Observation:** `JMP` can only test FLAG0 and FLAG1, and flags are shared by both engines.
  I2C, USB TX, 1-Wire and Modbus all use FLAG0 or FLAG1, so two of them cannot run on the two
  engines at the same time. UART and SPI use no flags and can run next to any of them.
- **Resolved:** engine-relative flags (D11, BUG-017). The new test runs a 1-Wire Search ROM on
  engine 0 and I2C on engine 1 at the same time.

## D28. Retire v2; keep the engine general

- **Decision:** v2 (low-speed USB) is retired. Its source stays on the GitHub branch
  `archive/v2-usb`; what it taught is in `docs/USB_NOTES.md`.
- **Why:** v2 worked, but most of its hardware was USB-only: a line unit with its own fixed
  CRCs, and all 8 sub-ops of opcode 111 spent on USB. That pulled the engine away from being a
  general protocol engine, and every fix had to be made in two copies.
- **Alternatives:** keep both copies (rejected: double work, drift); merge them behind a USB
  build option (rejected for now: still USB-specific hardware).
- **Plan for USB later:** bring it back on general features that other protocols also use:
  the CRC unit (D29), a line coder with NRZI/stuffing/Manchester modes, compare-and-branch on
  received data, and `MOV X, ISR` (see `docs/USB_NOTES.md`, section 4).
- **Done:** USB is back in v1 (D39–D44). The line coder has NRZ and NRZI, three stuffing rules
  and a pair mode; Manchester waits for a protocol that needs it (1553). The coder is
  unit-tested in USB, CAN and HDLC styles, so it is not USB-only hardware.

## D29. General CRC unit

- **Chosen:** `src/pbe_crc.sv`, one per engine. A shift-left register with any polynomial up to
  16 bits and a set width; initial value all zeros or all ones; result read plain or
  bit-reversed. It is fed by the bits the engine shifts: `OUT`/`OUTOD` and/or `IN`, chosen in
  `CRC_CFG`; an instruction marked `NOCRC` (e.g. a parity bit or the CRC bytes themselves) is
  left out. "CRC ok" = register is zero, which holds after a frame plus its own CRC for every
  CRC without a final inversion (Modbus CRC-16, 1-Wire CRC-8, CAN CRC-15).
- **Instructions (opcode 111):** `CRCRST`, `OSRCRC LO/HI` (load a CRC byte to send), `JCRCBAD`.
  The host can also restart the CRC and read "CRC ok" through the engine's `STATUS` register,
  which is how the unchanged 1-Wire program gets a hardware CRC-8 check.
- **Changed (1-Wire inverted CRC-16):** reading +9/+A now returns the CRC's current value instead
  of the polynomial. Devices such as the DS2408 and DS2431 send their CRC-16 inverted, where
  "zero" is never the result; the host reads the value and compares it with the received bytes.
  Polynomial read-back is lost, which only a debugging host would miss.
  - **Alternatives:** a residual-compare register (no register slot free); a final-inversion
    option (engine-side checks for inverted CRCs would still need a residual).
- **Alternatives:**
  1. Host computes CRCs (the first Modbus/1-Wire versions). Works for slow protocols, but the
     engine cannot act on the result, which USB and CAN need.
  2. Fixed CRCs, like v2's USB unit. Rejected: a new protocol would need new hardware.
  3. A final-inversion option. Left out: no current protocol needs it (USB does; see notes).
- **Changed (USB):** USB's CRC16 is sent inverted, so a good packet leaves the register at the
  residual 0x800d, not zero, and the device must check it before it ACKs. "CRC ok" now means
  the register equals `CRC_GOOD` (default 0, so every earlier program is unchanged), and
  `OSRCRC ..., INV` sends the inverted field (D41).
- **Verified:** a Python model of the same register gives Modbus `C4 0B` for `01 03 00 00 00 02`,
  1-Wire CRC-8 `1C` for the DS18B20 scratchpad, and zero after a frame plus its CRC.
- **Cost:** ~3,600 µm² per engine, plus its registers.

## D30. Parity bit

- **Chosen:** two flip-flops per engine. Send parity: XOR of the bits `OUT`/`OUTOD` shifted since
  the last OSR load; the new pin action `OUTPAR` (6) drives it, inverted when `LINE_CFG[7]`
  selects odd parity. Receive parity: XOR of the bits `IN` sampled since the last `STAT`; with the
  parity bit included it must come out even (or odd), and `STAT` reports an error otherwise.
- **Why separate from the CRC:** parity is a 1-bit CRC (polynomial x+1), but Modbus needs parity
  per character and CRC-16 per frame at the same time.
- **Alternative:** host supplies the parity bit (first Modbus version): costs a FIFO byte per
  character and host work. Rejected now that the cost is two flip-flops.
- **Changed (Modbus 8N2, BUG-019):** `LINE_CFG[6]` = no parity: `OUTPAR` sends 1 (the second stop
  bit) and no receive parity error is reported. The same Modbus program then does 8E1, 8O1 and
  8N2.


## D31. WAIT timeout through a timeout vector

- **Chosen:** per engine, `TIMEOUT` (16 bits, in ticks; 0 = off) and `TIMEOUT_PC` (in
  `LINE_CFG`). If `WAIT`, `PULL` or `PUSH` stays blocked for `TIMEOUT` ticks, the engine abandons
  it (no side effects), jumps to `TIMEOUT_PC` and sets "timeout happened", which `STAT` and the
  `STATUS` register report.
- **Why a vector:** no instruction bits were free: `JMP`'s 8 conditions and `WAIT`'s 9 argument
  bits are all used, and using the delay field would break existing programs. With a vector,
  every existing program works unchanged (timeout off by default).
- **Alternatives:** a `JMP TIMEOUT` condition (would need to drop an existing condition); a
  timeout field in `WAIT` (no room); a second engine as a timer (wastes an engine).
- **Uses:** Modbus end of frame and exact start detection at any baud rate (done); I2C stuck-bus
  recovery, UART idle-line detection and CAN bus-idle detection (later).
- **Cost:** ~2,800 µm² per engine (counter and limit).

## D32. Register and opcode budget

- **Changed (USB):** the second register page (D44) holds the new per-engine settings, and
  sub-ops 4–6 of opcode 111 became `JEQ`, `JNE`, `JLINE` (D40). Sub-op 7 is the last free one;
  `MOV` went into the unused bits of `FLAG` action 3 instead. `STATUS` uses 5 of 8 bits.
- **Engine registers:** +0 to +F are now all used (+7 is free only by accident of history:
  it was v2's `BITDIV`). New per-engine settings will need a second register window.
  `LINE_CFG` is full too ([5:0] timeout PC, [6] no parity, [7] odd parity), and `STATUS` uses 4
  of 8 bits.
- **Opcodes:** opcode 111 has sub-ops 4–7 free. Planned users: compare-and-branch on received data,
  `MOV X, ISR`, line-coder operations. When those run out: 24-bit instructions (program memory
  +50 %, ~+25,000 µm²) or a second opcode page.
- **OSR/ISR stay 8 bits:** byte boundaries cost one `PULL`/`PUSH` tick, which every protocol so far
  hides in a delay. Needed only for a protocol at one tick per bit with no gap between bytes, and
  then "auto-pull" is cheaper than wider registers.

## D33. RX overflow is reported, not silent

- **Chosen:** a `PUSH` that finds the RX FIFO full sets a sticky `STATUS[3]` bit (also in `STAT`)
  and raises IRQ once. The engine still waits for room, as before.
- **Why:** with 4-byte FIFOs a slow host can fall behind (at 115200 baud it has ~95 µs per
  character). The data is then damaged either way; the point is that the host finds out.
- **Alternatives:** drop the byte and keep going (keeps timing, loses data silently); deeper
  FIFOs (area; v2 needed 16 bytes for USB and paid ~32,800 µm²).

## D34. WS2812 (NeoPixel) LED driver: a program, timed by delays

- **Chosen:** `programs/ws2812.pbe`, 8 words, tick = 2 clocks (41.7 ns at 48 MHz). Each bit is
  three pin instructions: `DRV1 [9]` (0.42 µs), `OUT [9]` (a 1 stays high for another 0.42 µs, a
  0 goes low), `DRV0 [8]`, and `JMP X--`: 30 ticks = 1.25 µs. High times are 0.42 / 0.83 µs
  (datasheet 0.4 / 0.8 µs ± 150 ns); the `PULL`/`SET` at a byte boundary make that bit's low phase
  125 ns longer, still in spec. The engine waits in `PULL` with the line low, so a frame ends
  (the LEDs latch after 50 µs low) simply when the host stops sending.
- **Host requirement:** 800 kbit/s is 100 kB/s with a 4-byte FIFO (40 µs of data). The host
  bursts the bytes into the FIFO and pauses while the TX-full pin (`uo_out[6]`) is high. At a
  host SCK of clk/16 a byte takes 2.7 µs, against 10 µs on the LED line. An underrun stretches
  a low phase out of spec, and one of 50 µs latches the LEDs mid-frame.
- **Alternatives:** a hardware PWM or one-shot pulse unit (WS2812-specific: rejected, D28); one
  instruction per bit with the delay chosen by the data (no instruction reads OSR into the delay
  field).
- **Tested (Test 8):** a decoder measures every high and low against the datasheet and rebuilds
  the bytes: 2 frames of 5 LEDs. Mutations caught: `DRV1 [4]` (high too short) and `DRV0 [3]`
  (low too short).

## D35. SPI peripheral (device): a program; the timeout vector ends a transaction

- **Chosen:** `programs/spi_periph.pbe`, 21 words, mode 0, CLKDIV 0. It waits for CS low and puts
  bit 7 on MISO, then loops: wait SCLK rise → `IN` MOSI → wait fall → `OUT` MISO. A reply byte the
  host has not queued goes out as 0xFF (`SET OSR, 0xFF` and `JMP TX_EMPTY`).
- **End of transaction:** the engine is blocked in `WAIT sclk, RISE` when CS rises, and a
  `WAIT` cannot watch two pins. The timeout vector (D31) breaks the wait: after `TIMEOUT` ticks
  with no clock, the routine at word 1 checks CS (`JMP PIN_HI`, the JMP pin is CS). If CS is high,
  it releases MISO and waits for the next select; if CS is still low (the controller paused), it
  goes back to waiting for the clock.
- **Limits (documented in the program):**
  - SCLK up to 2 MHz at 48 MHz. After the 8th rising edge the engine needs about 10 clocks to
    store the byte and load the next reply before the falling edge. Tested at 2 MHz.
  - The first SCLK edge comes at least 250 ns after CS falls.
  - A reply byte must be queued before the previous byte's last rising edge.
  - CS must stay high for at least `TIMEOUT` ticks between transactions. MISO is released
    within `TIMEOUT` ticks of CS rising, not at once: on a shared MISO line that gap matters.
  - `TIMEOUT` must be longer than the longest SCLK high phase.
- **Alternative for later:** a general "abort on pin edge" vector (like the timeout vector, but
  fired by an edge on a chosen pin). It would end SPI transactions at once and also serve I2C
  target STOP detection and UART break. That's hardware, so it waits for a second protocol that
  needs it badly.
- **Tested (Test 9):** a mode-0 controller model at 2 MHz that samples MISO just before each
  rising edge, three transactions: replies queued, 0xFF defaults (also for the very first byte),
  and a pause longer than the timeout inside a transaction. A monitor checks that MISO changes
  only while SCLK is low. Mutations caught: either `SET OSR, 0xFF` removed (the first one only
  after BUG-026), timeout routine always ending the transaction, MISO never released.

## D36. SMBus PEC: the I2C controller plus the CRC unit as CRC-8

- **Chosen:** no new hardware and one program change. The CRC unit is set to CRC-8, poly 0x07,
  init 0, plain output (`CRC_CFG` 0x87), fed by `IN` bits only. The I2C controller reads back
  every bit it sends, so `IN` sees each byte on the bus in both directions, including addresses.
  The ACK slot's `IN` is marked `NOCRC`, because a PEC covers bytes, not ACK bits (BUG-022).
- **Host protocol:** restart the CRC (`STATUS` write bit 0) at the start of a message, not at a
  repeated START: the PEC covers both address bytes.
  - Write: after the last byte, read the CRC value (+9) and send it as the PEC.
  - Read: receive the PEC like a data byte. `STATUS` bit 1 ("CRC ok") is then set only if it
    was right.
- **Alternatives:** the host computes the PEC (works, but costs host time per byte); feeding the
  CRC from `OUTOD` too (would count each bit twice, since the program both drives and reads it).
- **Tested (Test 7, in `tb_pbe`):**
  - The device model computes its own PEC. The testbench's CRC-8 is first checked against the
    standard check value (0xF4 for "123456789").
  - Write Word with PEC: the engine's PEC must equal the model's, and the device's CRC over the
    message plus the PEC must be 0.
  - Read Word with PEC: once with the right PEC (CRC ok = 1) and once with a corrupted one
    (CRC ok = 0).

## D37. I2C target: two engines share the job through flags

- **Chosen:** `programs/i2c_target.pbe` (58 words, bit engine) on one engine and
  `programs/i2c_watch.pbe` (8 words) on the other. Both engines use the same pins and the same
  `FLAG_BASE`, so they see the same four flags (D27).
  - The watcher waits for SDA edges and checks SCL. A fall while SCL is high sets FLAG0
    (START); a rise while SCL is high sets FLAG3 (STOP, with IRQ). It drives nothing.
  - The bit engine shifts the address and data bits on SCL edges. After each SCL fall it checks
    FLAG0, so a repeated START restarts the address phase.
- **Why two engines:** START/STOP are SDA edges while SCL is high. A single engine blocked in
  `WAIT scl` cannot see an SDA edge. The alternatives each need hardware:
  - a `WAIT` on two pins (no free argument bits, D32);
  - a pin-change flag;
  - the abort-on-edge vector of D35.

  The cost is that the I2C target uses both engines, so nothing else can run beside it.
- **The host decides, the engine stretches SCL:**
  - After the address byte, the engine holds SCL low, pushes the address and sets FLAG2 (with
    IRQ). The host ACKs by clearing FLAG2 (the engine waits in `WAIT FLAG 2, LOW`). It NACKs by
    restarting the engine, which releases both lines and waits for the next START.
  - For reads, the engine holds SCL until the host has queued the next byte.
  - I2C allows any amount of clock stretching, so host latency only slows the bus.
  - The host can therefore answer any address, several addresses or the general call; there is
    no address-comparator hardware.
- **Rejected in review (first draft):** a NACK queued as a byte. In that draft the engine then
  decided "did we ACK?" by reading SDA in the ACK slot. On a bus with several targets, another
  device's ACK pulls SDA low, and the engine would have joined someone else's transfer. Test 10
  now covers this.
- **Timing:**
  - SDA changes at least 300 ns after SCL falls. `WAIT scl, FALL [12]` covers the I2C hold rule:
    a transmitter must bridge SCL's undefined falling region.
  - SDA is set up at least 333 ns before the engine releases a stretched SCL (`[15]`; standard
    mode needs 250 ns).
  - Measured: hold ≥ 333 ns, setup ≥ 333 ns.
- **Host rule:** read FLAGS *after* draining the RX FIFO. The engine sets FLAG2 one clock after
  pushing an address, so if FLAG2 was still clear, the drained bytes were all data.
- **Tested (Test 10):** a fast-mode controller model that supports stretching:
  - a write of a pointer plus five bytes (more than the RX FIFO holds);
  - a read of three bytes after a repeated START;
  - another device's address, ACKed by that device and followed by two bytes: our chip must not
    touch SDA and must pass nothing to the host;
  - a read after that.

  Monitors check that SDA never changes while SCL is high, the hold and setup times, and that
  stretching happened. Mutations caught: the watcher's START flag removed, the repeated-START
  check removed, the hold delay removed (104 ns), the setup delay cut (83 ns).

## D38. A second end-to-end testbench

- **Chosen:** tests 8–10 live in `test/tb_proto.sv`; the host-port helpers (SPI framing, register
  access, FIFOs, flags) moved to `test/tb_host.svh`, which both testbenches include.
  `make test` runs all three testbenches; `make test-proto` runs only the new one (3 s, against
  ~2 min for `tb_pbe`).
- **Why:** `tb_pbe.sv` had grown past 1,100 lines and two minutes per run; the new protocols use
  their own pin models and need nothing from the old tests' state.
- **Lint step:** `make test` first fails on Icarus's "Static variable initialization" warning
  (BUG-023).

## D39. Line coder: a general serializer between the shift registers and the pins

- **Chosen:** `src/pbe_line.sv`, one per engine, off by default (`LINE` = 0). Settings:
  - **mode:** NRZ, or NRZI (0 = change level);
  - **stuffing:** after 6 ones (USB), after 5 ones (HDLC) or after 5 equal bits (CAN);
  - **pair mode:** pin base + 1 carries the complement, SE0 ends a frame;
  - **transfers:** byte or bit;
  - **SYNC:** a frame-start pattern.
- **What it does:**
  - **Bit timing:** it owns the bit timing (`CLKDIV` becomes the bit time, and instructions then
    run every clock), because a stuffed bit must cost the program nothing. That was v2's lesson.
    (Since D50 a taken jump takes 2 clocks.)
  - **Transmit:** one queued entry. A frame starts with a 2-bit-time gap and the SYNC byte,
    and `PIN p, END` ends it (pair mode: SE0, SE0, J, then release).
  - **Receive:** samples mid-bit and re-centres on every edge. It hunts for SYNC, unstuffs
    (a stuff bit with the wrong value is a line error), and reports the end of a frame as an
    event: SE0 then J in pair mode; otherwise 8 idle bits, or a stuffing violation at the
    idle level.
  - An `IN` waits for a byte or the event. An unread byte is dropped when its frame ends
    (BUG-028).
- **CRC in byte mode:** an `OUT` or `IN` hands over 8 bits at once, so the CRC unit takes them
  one per clock afterwards, and the next instruction waits those 8 clocks. That keeps the
  CRC unit bit-serial and keeps `NOCRC` per instruction.
- **Why general:** the same block covers USB (NRZI, 6 ones, pair), HDLC/SDLC (NRZI, 5 ones,
  flag as SYNC) and CAN (NRZ, 5 equal bits, bit transfers). `tb_line.sv` tests all three
  against reference models written independently of the RTL.
- **Alternatives:**
  1. v2's USB line unit: rejected, USB-only (D28).
  2. Host pre-encodes NRZI and stuffing: almost no hardware, but the device would then ACK
     packets without checking their CRC, and the host would have to stream at line rate.
  3. Bit-by-bit in instructions: at 32 clocks per bit there is no "branch on this bit".
- **Not yet:** a Manchester mode (1553), CAN's sample point and resynchronization jump width.
  A non-pair frame ends only by idle or a stuffing violation.
- **Cost:** 12,141 µm² per coder. I estimated 6–8k: the two 16-bit bit timers (transmit and
  receive) are most of the difference, and could be one, since the coder is half duplex.

## D40. Compare and move instructions

- **Chosen:**
  - `JEQ label` / `JNE label`: jump if ISR equals / differs from OSR (opcode 111, sub-ops 4, 5).
  - `JLINE label`: jump if the line coder saw the end of a frame, and clear the event (sub-op 6).
  - `MOV dst, src` with dst and src in {X, OSR, ISR} and src 0 = zero (`FLAG` action 3).
- **Why:** a USB device must choose ACK, NAK, STALL or DATA from the PID and address within
  7.5 bit times, and the host is far too slow for that. `JEQ` against `SET OSR` constants checks
  bytes; `MOV X, ISR` keeps the PID while the address bytes arrive, and later counts bytes.
- **Also for:** Modbus slave addresses, the I2C target address check on the engine, CAN IDs,
  the 1553 terminal address, and any loop with a received count (`MOV X, ISR`).
- **Why `JNE` too:** the USB program is exactly 64 words; each `JNE` saves the `JMP` after a
  `JEQ`. That spent another sub-op, so `MOV` went into `FLAG` action 3 instead.
- **Tested:** `tb_engine_ops.sv` (unit test) checks every compare and move, and that `NOP` is
  still a no-op.

## D41. CRC good value and inverted CRC output

- **Chosen:** a per-engine `CRC_GOOD` register: "CRC ok" means register == `CRC_GOOD` (0 by
  default). `OSRCRC LO|HI, INV` loads the inverted CRC byte.
- **Why:** USB sends its CRC16 inverted. A good packet leaves the register at 0x800d. Our model
  of the CRC unit gives the field `dd 94` for the real-trace packet `DATA0 80 06 00 01 00 00 40 00`,
  and 0x800d after any good packet. The unit test checks both values in RTL.
- **Also for:** the 1-Wire inverted CRC-16 (DS2408, DS2431), which the host had to check by
  reading the value (D29); and CRC-16/X.25 (HDLC).
- **Alternative:** a final-inversion flag with the residual worked out in hardware: more logic
  for the same result.

## D42. USB low-speed device: control endpoint 0, one engine

- **Chosen:** `programs/usb_dev.pbe`, exactly 64 words.
  - **Received tokens:** checks PID, address and endpoint (with the CRC5 included, by comparing
    the token's 2nd and 3rd bytes with two `SET OSR` constants). It receives SETUP/OUT data,
    checks the CRC16 against the residual, and ACKs only good packets.
  - **IN tokens:** sends the host-queued packet with the CRC appended, NAK when nothing is
    queued, or STALL. It reports the host's ACK.
  - **Settings:** CLKDIV 31 (32 clocks a bit at 48 MHz), coder 0x36, SYNC 0x80, CRC16 0x8005,
    CRC_GOOD 0x800d.
- **Host side:**
  - The firmware answers at its own pace: USB's NAK flow control means the engine NAKs IN
    tokens until data is queued, so the host never has to meet the 5 µs turnaround.
  - Records go to the RX FIFO: `[D2]` for an ACK, and `[token] [DATA PID] [n bytes] [255 − n]
    [status]` for data. The count makes records that pile up in the FIFO separable; the
    firmware parses them from the end (a status byte is below 0x20, an ACK is 0xD2).
  - After SET_ADDRESS, the firmware rewrites the two address words in program memory.
  - It uses `RX_COUNT`, `TX_FLUSH` and flags (FLAG0 = IN packet queued, FLAG1 = STALL,
    FLAG2 = record).
  - It also resends an IN packet whose ACK was lost and handles a bus reset (D49).
  - A data packet is ACKed only when its CRC is good *and* the line coder saw no error (D48).
- **Scope: endpoint 0 only.** A HID keyboard also needs an interrupt IN endpoint, about 10 more
  words, and a program window is 64 words (6-bit jump targets). What would make room:
  - a one-level `CALL`/`RET`;
  - jumps relative to the PC, so a program could use the whole memory;
  - USB on both engines (receive and transmit).

  These are open. EP0 covers what V-USB's common gadgets use: enumeration and vendor requests.
- **Limits:**
  - A SETUP record is 14 bytes, so the firmware must read it before the next SETUP arrives
    (USB's own flow guarantees that).
  - Electrical: plain I/O pins switch faster than USB's 75–300 ns edges (works in practice,
    as with V-USB, but not compliant). The pad voltage still needs checking.
  - Full speed is impossible at 4 clocks per bit.
- **Tested (Test 11, `tb_usb.sv`):** a USB host model at ±1.5 % enumerates the device:
  - GET_DESCRIPTOR (device; configuration 9 and 18 bytes), SET_ADDRESS, SET_CONFIGURATION,
    STALL for an unsupported request, and a vendor write and read;
  - refused: a SETUP with a flipped bit, one with a missing stuff bit, one with a wrong stuff
    bit but intact data and CRC (BUG-040), tokens for the old address and with a bad CRC5;
  - a lost ACK (the same DATA1 packet comes again, BUG-041) and a 10 ms bus reset after
    SET_ADDRESS (address 0 again, BUG-042);
  - no reply: keep-alives and a bus reset;
  - two records piled up and split apart.

  The device's CRCs are checked by the host model's own CRC code. Every turnaround is
  2.97–3.05 bit times (allowed 2–7.5), and host and device never drive the bus at the same time.
  Mutations caught:
  - no edge re-centring;
  - no stuffing;
  - a 1-bit gap (turnaround 1.97);
  - no frame-end drop;
  - no CRC5 check;
  - no CRC check before the ACK;
  - "CRC ok" back to zero.

## D43. Host port: FIFO counts and a TX-only flush

- **Chosen:**
  - `RX_COUNT` (0x0A/0x0B) and `TX_COUNT` (0x0C/0x0D): bytes in each engine's FIFOs.
  - `TX_FLUSH` (0x0E): empties an engine's TX FIFO only.
- **Why:**
  - A burst read of an RX FIFO could lose a byte arriving during the burst (BUG-030). With the
    count, the host reads exactly the bytes that are there.
  - The USB firmware must drop a stale IN reply when a SETUP arrives. Flushing both FIFOs threw
    away the OUT record already arriving behind the SETUP (BUG-031).
- **Also for:** any protocol whose host reads in bursts, or aborts a queued transmission.

## D44. A second register page per engine

- **Chosen:** 0x30 + 0x10·e: +0 `LINE` (coder), +1 `SYNC`, +2/+3 `CRC_GOOD`.
- **Why:** the first page (+0..+F) was full (D32). The free +7 slot alone could not hold four
  bytes of new settings.

## D45. Area and timing after USB — **Changed (first routed run: timing)**

| | Area | Share of 6×4 tiles | Worst logic path (slow corner) |
|---|---|---|---|
| Before USB (D34–D38) | 262,618 µm² | 29 % | 3.97 ns |
| With USB features | 333,841 µm² | 36.4 % | 4.33 ns (~5.2 ns with flip-flop overheads, budget 20.8 ns) |

Breakdown of the +71,223 µm²:

| Part | Area |
|---|---|
| FIFOs 4 → 16 bytes | 33,121 µm² |
| Two line coders | 24,283 µm² |
| Instructions, `CRC_GOOD`, byte-mode CRC feed, registers | ~13,800 µm² |

My estimate was about +50k µm²: 40 % low, as with the 128-word memory (D4). The coder was the
part I under-estimated most.

### Routed results (first full Tiny Tapeout run, commit df2e881)

| | Estimate (Yosys + ABC, above) | Routed (LibreLane, measured in CI) |
|---|---|---|
| Area / utilization | 333,841 µm², 36.4 % of 6×4 tiles | 44.3 % utilization (instance utilization 0.501) |
| Cells | — | 21,745 without fill; 73,420 instances with fill |
| Hold-fix delay cells | not estimated | 3,590 (about +14.9 % area) |
| Worst setup path, slow corner | 4.33 ns logic, ~5.2 ns with flip-flop overheads | ~20.3 ns |
| Setup worst slack, slow corner (budget 20.833 ns) | ~15.6 ns (implied) | 0.586 ns |

Static timing at a 20.833 ns clock, all corners:

| Corner | Setup worst slack | Hold worst slack |
|---|---|---|
| slow (1.08 V, 125 °C) | 0.586 ns | 0.602 ns |
| typ (1.20 V, 25 °C) | 7.95 ns | 0.284 ns |
| fast (1.32 V, −40 °C) | 12.344 ns | 0.106 ns |

Design-rule warnings (not failures): 277 max fanout; max slew 114 at the slow corner and 11 at
typ; max capacitance about 60–70. Antenna violations are 0 after repair, and DRC and LVS are
clean (0 design violations).

- **Area:** the estimate held up reasonably. Most of the gap to 44.3 % is the hold-fix cells,
  which a logic-only synthesis cannot see; the rest is placement buffering and resizing.
- **Hold cells: expected, kept.** Tiny Tapeout's 0.25 ns clock uncertainty plus the 0.1 ns hold
  margin apply to every direct flop-to-flop path (program memory, FIFO memories, shift
  registers, synchronizers), and those paths have almost no logic between flops, so the flow
  pads them with delay cells. Hold is met at every corner.
- **Timing estimate — Changed (first routed run):** the estimate was optimistic by about 4×.
  The worst routed path runs from `g_eng[1].u_eng.pc` through buffer chains into the mux4 tree
  that reads the 128 × 16 program memory, then through decode to the next state: ~20.3 ns at
  the slow corner against our ~5 ns. The method (D22) leaves out wire delay, and that path is
  dominated by it: the PC drives the select lines of the whole 128-way read multiplexer, a
  huge fan-out that place and route must buffer into long chains spread across the die. ABC's
  `stime` sees only the logic depth. Setup is still met at every corner, but with 0.586 ns
  at the slow corner, not the ~4× margin assumed in D18.

  This is a limit of the method, which D22 already stated ("wire delay and clock skew are not
  included"), not a tool bug, so it has no `BUG_LOG` entry. From now on, the routed STA report
  is the timing figure; the ABC estimate is only for comparing RTL changes with each other.
- **Follow-up:**
  - An instruction register now cuts the program-memory path in two (D50); the clock stays at
    48 MHz. Its routed slack is still to be measured by the next `gds` run.
  - The physical-design flow is paused (`gds` and `gl_regression` by hand only, D46) until the
    RTL is final.

## D46. Tiny Tapeout packaging

- **Chosen:** the repository root is the Tiny Tapeout project, built from the IHP template
  (`ttihp-verilog-template`, actions `ttihp27a`, PDK `ihp-sg13cmos5l`):
  - `info.yaml`: 6×4 tiles, 48 MHz, language SystemVerilog, the pinout;
  - `src/`: the RTL and `config.json`, the template's file with `CLOCK_PERIOD` 20.833 ns;
  - `docs/info.md`: the datasheet page;
  - `test/`: a cocotb test;
  - `.github/workflows`: `gds`, `test`, `docs`, plus our `regression`.
- **Top module:** renamed `tt_um_ayushyadavnvs_pbe`, because Tiny Tapeout requires the GitHub
  user in the name. The file stays `src/tt_um_pbe.sv`.
- **Layout:** the RTL moved from `pbe_v1/src` to `src/`, because Tiny Tapeout requires the
  sources in `./src`. `pbe_v1/src` is now a link to `../src`, so `pbe_v1` (Makefile,
  testbenches, synthesis) is unchanged and stays the design's home. Alternatives:
  - a separate Tiny Tapeout repository: two copies of the RTL would drift, as v2 did (D28);
  - moving all of `pbe_v1` to the root: a large, noisy move for no gain.
- **Where the flow runs:** on GitHub Actions, as Tiny Tapeout intends. A local run needs
  LibreLane's tool set (OpenROAD, Magic, KLayout, Netgen) through Nix or Docker; Docker is not
  available in this workspace, and fetching LibreLane's Nix environment was not permitted here.
- **The cocotb test** (`test/test.py`) is small on purpose, because the `gl_test` job runs it on
  the routed netlist. It checks a register write and read-back, then loads the UART programs
  and loops a byte stream from engine 0 to engine 1 through `uio[0]` → `uio[1]`. Without the
  loopback it fails ("received []"). The full suite stays in `pbe_v1/test`, on the RTL.
- **Gate level:** a separate workflow, `gl_regression`. It runs after each `gds` run and on
  testbench changes, using the netlist of the latest `gds` run. At first it was a job inside
  `gds`, but then every testbench fix needed a 2.5-hour rebuild. It takes the routed
  netlist and the PDK's cell models, as Tiny Tapeout's `gl_test` does, and runs our full
  end-to-end testbenches (`tb_proto`, `tb_usb`, `tb_pbe`) on it: `make test-gl` in `pbe_v1`.
  The testbenches look only at the pins, except one I2C monitor that reads the flags register
  inside the design. That monitor is left out at gate level (`GL_TEST`), and the NOP check now
  reads the flags through the host port instead.
- **Lint:** Verilator with all warnings showed three, now fixed: a 3-bit index on a 16-bit
  vector (same behaviour, now written as 4 bits) and two deliberately unused bits. The
  `regression` workflow lints with `-Wall` on every push.
- **Clock period:** 20.833 ns (48 MHz), not the template's 20 ns. The cocotb test runs at
  20.834 ns, because cocotb needs an even number of picoseconds.
- **Changed: when the flow runs.** At first `gds` ran on every push to `src/`, `info.yaml` or
  `test/`, and `gl_regression` ran after it and on every testbench push. Both are now run by
  hand only (`gl_regression` still follows a `gds` run). The first full run passed; the RTL
  is now being finished (reviewer fixes, the 48 MHz timing fix) before physical design
  resumes. Otherwise each RTL push would start a 2.5-hour build, and each testbench push would
  test new tests against an old netlist. RTL tests (`regression`) still run on every push.
- **First full run (commit df2e881), measured in CI:**
  - **`gds`:** success in 2 h 18 min, of which detailed routing took 1 h 30 min and Magic DRC
    25 min. Precheck 9/9 passed; `gl_test` (the cocotb test on the routed netlist) passed 2/2.
  - **`gl_regression`** (run 40810602581, `make test-gl`: `tb_proto`, `tb_usb`, `tb_pbe` on the
    routed netlist with the PDK cell models): all passed, in 3 h 05 min, inside GitHub's 6-hour
    job limit.
  - Area, timing and the comparison with the estimates are in D45.

## D47. Modbus RTU: a pause of more than 1.5 characters makes a frame invalid

- **Rule:** Modbus over serial line, §2.5.1.1: the characters of a frame follow each other with
  at most 1.5 character times of silence; a frame with a longer pause must be discarded. A
  frame ends after 3.5 characters of silence. Before this the program waited 3.5 characters
  inside a frame, so a 2-character pause was accepted (BUG-039).
- **Chosen:** `TIMEOUT` = 1.5 characters (+ 9 ticks, as before, because the program starts
  waiting 9 ticks before the stop bit ends): 141 ticks at 1/8 bit. The timeout routine, if in a
  frame, watches the line for 2 more characters in an X loop (`JMP PIN_LO` / `JMP X--`, 2 ticks
  a pass, 88 passes):
  - silence: the frame ends as before (FLAG2, IRQ), after 3.5 characters in all;
  - a start bit: the frame is invalid. FLAG3 is set at once; the program receives nothing more,
    and waits for 3.5 characters of silence (the same loop with X = 153, restarted by every low
    sample), then ends the frame with FLAG2 and IRQ. The host discards a frame with FLAG3 set.
- **Why a flag, not a status value:** the status byte is per character and the frame is only
  known to be invalid after the pause; FLAG3 is the engine's last free flag and needs no RX
  FIFO space. FLAG2 and IRQ still mark the end, so the host's frame loop is unchanged.
- **Why FLAG3 at once but IRQ only at the end:** one more word (an `IRQ` in `bad`) would make
  65; the host sees FLAG3 whenever it looks, and the IRQ comes when the line is quiet and the
  next frame may start.
- **Alternatives:**
  - a second timeout value in hardware (1.5 and 3.5): a register and a comparator for one
    protocol, against 6 words of program;
  - keep receiving after the pause and mark only the end: simpler, but the junk would fill the
    RX FIFO; the rule says discard.
- **Above 19200 baud:** the spec recommends fixed timers (750 µs and 1.75 ms) there, to spare
  slow CPUs; it does not forbid character-based ones. This engine counts in characters at every
  rate, so a 2-character pause is caught at 115200 baud too, and the frame end comes after
  3.5 characters (about 0.33 ms at 115200) instead of 1.75 ms. A host that wants the fixed
  750 µs can set `TIMEOUT` to it; the watch after it stays 2 characters (frame end at
  750 µs + 2 characters).
- **Cost:** 6 words (56 → 62 of 64).
- **Known limit (not new):** while idle, a timeout every 1.5 characters runs 2 instructions
  (`tmo`, `JMP TX_EMPTY`) before `WAIT rx, FALL` waits again; a start edge in those 2 ticks
  would be missed. It was the same with 3.5 characters, only rarer.
- **Tested (Test 5):** a 2-character pause in a response at 19200 and 115200 baud is reported
  invalid (4 characters before the pause, none after); a 1-character pause at both rates is a
  valid frame; all earlier rounds (parity error, bad CRC, 8N2, RX overflow) still pass.

## D48. JCRCBAD means "packet bad": CRC not ok or a line error

- **Problem (BUG-040):** a USB packet with a wrong stuff bit but intact data and CRC was ACKed.
  `STAT` cleared the line error before `JCRCBAD`, and `JCRCBAD` looked only at the CRC.
- **Chosen:**
  - `JCRCBAD` jumps when the CRC is not ok **or** the line error is set.
  - `CRCRST` clears the line error: it marks the start of a new checked packet. (An error in
    the very clock of the `CRCRST` is kept.)
  - `STAT` **no longer clears** the line error. It still reports it (bit 4) and still clears
    parity and timeout.
- **Why STAT stops clearing it:** USB's program does `STAT` then `JCRCBAD`, so the record gets
  the status and the jump decides on the same packet; a clear in `STAT` would hide the error from
  the jump. With `CRCRST` as the clear, the error's scope is one packet: from its `CRCRST` to the
  next one. The host's own clear (`STATUS[3]`) and restart still work.
  - **Alternative:** keep `STAT` clearing and swap the program's order (`JCRCBAD` before
    `STAT`): then the record and the ACK decision would need two code paths, and the 64-word
    USB program has no room.
  - **Alternative:** a separate `JLERR` jump: sub-op 7 is the last one free; "packet bad" is the
    test every checked protocol wants (USB, HDLC, CAN), so one jump covers both.
- **Programs:** `usb_dev.pbe` does `CRCRST` first in `dat`, before the DATA PID, so an error
  anywhere in the data packet counts (an error in the token before it does not). The firmware
  treats status bit 4 as bad, like bit 1 clear. Modbus uses `STAT` without the line coder, so
  its line error is always 0; no other program uses `JCRCBAD`.
- **Cost:** one OR gate and the clear on `CRCRST`.

## D49. USB host firmware: resend an IN packet whose ACK was lost; handle bus reset

- **Retransmission (BUG-041):** the engine sends an IN packet once; if the host's ACK is lost
  (or corrupted) the TX FIFO is empty and the next IN gets a NAK, and the host never gets its
  data. USB's rule is that the device sends the same packet (same DATA PID) until it is ACKed.
  - **Chosen:** in the firmware. It keeps the last IN packet; if `TX_COUNT` = 0 and no `[0xD2]`
    record came for about 100 µs (a host ACKs within 7.5 bit times, 5 µs, and the record
    reaches the firmware within tens of µs), it queues the same bytes again and sets FLAG0.
    Meanwhile the engine NAKs, which USB allows.
  - **Alternative:** in the program, by not popping the packet until the ACK (a "peek" read of
    the TX FIFO): needs FIFO hardware for one protocol, and the program has no room.
- **Bus reset (BUG-042):** a reset (SE0 for at least 2.5 µs; hosts send 10 ms) must bring the
  device back to address 0. The engine sees it only as a long EOP.
  - **Chosen:** the firmware polls `PINS`; SE0 seen twice, 2.5 µs or more apart (one register
    read takes about 6 µs), is a reset. EOPs last 1.33 µs and are at least ~12 µs apart, so two
    EOPs cannot pass for one. It then rewrites program words 6 and 9 to `0x9000` and `0x9100`
    (`SET OSR` 0x00 and 0x10: address 0), clears FLAG0–2, flushes the TX FIFO and forgets any
    transfer.
  - **Alternative:** a reset event from the line coder (SE0 longer than N bits), as an IRQ:
    hardware for USB only, and the host polling every 50 µs is enough for a 10 ms reset.
- **The firmware model** (`tb_usb.sv`) does both on a 50 µs timer in the same process as the
  record handler, like a firmware main loop, so the two never race. The test waits 6000 clocks
  (was 3000) after SET_ADDRESS for the address switch, since a timer poll may come first; USB
  allows 2 ms.


## D50. An instruction register cuts the clock's worst path in two

- **Problem:** the first full Tiny Tapeout run (LibreLane, routed) met 48 MHz with only
  0.586 ns of setup slack at the slow corner (1.08 V, 125 °C; typical 7.95 ns, fast 12.3 ns).
  The worst path ran from `g_eng[1].u_eng.pc[1]` through the program memory read to the next
  state, all in one clock. From the routed report (`55-openroad-stapostpnr`, slow corner):

  | Part of the path | Delay |
  |---|---|
  | Clock to Q of `pc[1]` | 0.33 ns |
  | `pc[1]` fan-out: a chain of 11 buffers (5 of them `buf_1`, with slews up to 2.1 ns) | 9.15 ns |
  | The mux4 tree of the 128 × 16 memory (`assign instr = pmem[pc]`) | 2.89 ns |
  | Decode, `ready`, `exec`, next state (another fan-out chain, a hold buffer) | 7.25 ns |
  | Data path in all | 19.6 ns (clock period 20.83 ns) |

  `pc` fans out to every first-level multiplexer of all 16 bits (ABC: 1,878 loads on `pc[0]`).
  That fan-out was also behind most of the slow corner's 277 max-fanout, 114 max-slew and
  about 65 max-cap warnings. The logic-only estimate (`make timing`, 4.2 ns, D45) had missed
  all of it: wires and fan-out were three quarters of the routed delay.
- **Chosen:**
  1. **An instruction register.** Each engine executes `instr_q`, not the memory output. The
     memory is read at `pc`, which now means the word *after* the current instruction. When an
     instruction executes and does not jump, `instr_q` takes that word, so sequential code
     still runs one instruction per clock. A taken jump (JMP, JCRCBAD, JEQ, JNE, JLINE, the
     timeout) loads `pc` with its target and clears the valid bit `iv`; the next clock fetches
     the target (a bubble). Reset and restart also clear `iv`.
  2. **A tick that falls on a bubble is held** for that clock (`tick = tick_due && iv`, and the
     divider and delay counter wait), so it is late, never lost.
  3. **Host writes:** a write to the program memory (`pm_wr`, any word) clears `iv` and fetches
     the instruction that runs next again. So the host can rewrite the word a stopped or
     blocked engine sits on, as the USB firmware does after SET_ADDRESS (D42).
  4. **Four copies of the read address.** `pc` and three copies (`pc_copy`) each address 4 of
     the 16 bits, so each drives a quarter of the multiplexers. The copies are in an
     `always_ff` marked `(* keep *)`: without it Yosys merges them back into one register
     (BUG-044).
- **Stages:** (1) `pc` → memory multiplexers → `instr_q`; (2) `instr_q` → decode → `ready` →
  `exec` → next state, including `pc`.
- **Instruction timing** (in the comment at the top of `pbe_engine.sv`):
  - `CLKDIV` ≥ 1: (DLY + 1) × (CLKDIV + 1) clocks, exactly as before. The next tick is at least 2
    clocks after the instruction that jumped, and after a blocked instruction completes the
    divider restarts, so the bubble always fits in between. `tb_fetch` gives the same edge
    timings on the old and the new RTL at CLKDIV 1 and 3.
  - `CLKDIV` = 0, and with the line coder: DLY + 1 clocks, plus 1 for a taken jump. The first
    instruction after a restart starts 1 clock later. A host write to the program memory makes
    the engine slip by 1 clock.
- **Program timing:**

  | Program | Mode | Effect |
  |---|---|---|
  | UART, SPI controller, I2C controller (and PEC), 1-Wire, Modbus RTU, WS2812 | CLKDIV ≥ 1 | None |
  | SPI peripheral (D35) | CLKDIV 0 | The tight path, from the 8th rising edge to `WAIT sclk, FALL`, has no taken jump: still 8 clocks of the 12 in a 2 MHz half period. The `JMP X--` and `JMP bit` each take 1 clock more. Test 9 passes at 2 MHz |
  | I2C target and watcher (D37) | CLKDIV 0 | Polling loops take 3 clocks instead of 2, and the watcher waits 1 clock longer after a `JMP PIN_LO`. Hold and setup times come from the `[12]`/`[15]` delays, which are unchanged. Test 10 passes |
  | USB device (D42) | line coder | A few taken jumps on the reply path: turnaround 2.97–3.05 → 3.00–3.19 bit times (allowed 2–7.5). The byte-mode CRC feed already holds the next instruction for 8 clocks, and the `OUT`/`IN` handshakes with `pbe_line` take no jumps, so neither changes. Each byte still has 256 clocks. Test 11 passes |

- **Alternatives:**
  1. **A bubble after every instruction** (`instr_q` loaded from `pmem[pc]` every clock, `pc` the
     current word, as first suggested): the same cut, but every instruction takes at least 2
     clocks at CLKDIV 0. Run as a mutation, it breaks the SPI peripheral at 2 MHz (Test 9:
     MISO changes while SCLK is high, wrong bytes in both directions), because the path after
     the 8th rising edge grows from 8 to 16 clocks against a 12-clock half period. USB still
     passes, at 3.19–3.35 bit times. Rejected (BUG-043).
  2. **Read both `pmem[pc]` and `pmem[pc + 1]`:** no bubble even on jumps, but a second set of
     multiplexers for both engines, about as large as the memory read itself. A 1-clock bubble
     on taken jumps costs no program any margin.
  3. **Register the read address in the top level:** a stage between the next-pc logic and the
     memory. It cuts the same path, but every instruction then needs 2 clocks, as in 1.
  4. **A lower clock:** ruled out: USB low speed needs exactly 32 clocks per bit (D18).
  5. **Clear `iv` only when the write hits the current or the next word:** two 7-bit comparators
     and an address port to spare one clock per host write. Writes are rare (program loading,
     the USB address patch), so any write refetches.
- **Unit testbenches unchanged:** they connect the engine by port name and leave the new
  `pm_wr` input unconnected (z). A default value on the port would fix that, but Verilator
  5.020 (the lint in CI) rejects it (BUG-045). `pm_wr` is therefore used only in `if`
  conditions, where z reads as false. In the chip it is always driven.
- **Measured** (`make timing`, Yosys/ABC logic only, IHP slow library, no wires):

  | | Worst logic path | Levels | Largest fan-out on it |
  |---|---|---|---|
  | Before (`pc[0]` → memory → decode → `flags`) | 4.20 ns | 36 | 1,878 (`pc[0]`) |
  | After, stage 2 (`instr_q[10]` → pin index → `wait_ok` → `exec` → state) | 3.45 ns | 21 | 10 |
  | After, stage 1 alone (`pc[0]` → memory → `instr_q`; one read port, 4 bits per copy not modelled) | 1.20 ns | 17 | 1,825 |

  The logic numbers drop only by 18 %, because the logic was never the problem.
- **Expected routed slack** (an estimate from the routed report, not a new run):
  - **Stage 1:** clock to Q, the `pc` buffer chain and the multiplexers, about 12.8 ns with
    today's chain. With a quarter of the loads on each copy, the chain should lose 2–3 of its
    weak stages (about 1.3 ns each). So about 9–10 ns, or 10–11 ns of slack.
  - **Stage 2:** the decode-to-state part was 7.25 ns, plus clock to Q and the `instr_q` fan-out:
    about 8 ns.
  - **Unchanged paths:** the worst path that did not start at `pc` was `clkdiv` → divider
    compare → `tick` → `issue` → `exec` → state, at 8.16 ns of slack. It has a `nor4_2` driving
    0.33 pF with a 4.3 ns slew. It is now the likely worst path.
  - **So:** about 8 ns of slack at the slow corner, up from 0.586 ns: the worst data path goes
    from 19.6 ns to about 12–13 ns. The `exec`/`tick` fan-out is the next thing to cut if more is
    needed (for example a registered `tick`).
- **Cost** (`make synth`, typical library): +76 flip-flops (per engine: `instr_q` 16, `iv` 1,
  three copies of `pc` 21), area 333,913 → 337,779 µm² (+3,866 µm², +1.2 %).
- **Tested:** `tb_fetch.sv` (Test 12), end to end through the pins and the host port:
  - **Timing:** at CLKDIV 0, 1 and 3, every edge of a program of `PIN TOG` instructions (DLY 0,
    1 and 2, taken and untaken jumps, a `WAIT` on a pin) against the rule above.
  - **Host writes:** (a) the host rewrites the word a stopped engine is parked on, then runs it
    without a restart; (b) the host rewrites word 0, then restarts; (c) the host rewrites the
    low byte of a running engine's blocked `WAIT FLAG 0, HIGH` into `LOW`, and the engine must
    go on without the flag changing.
  - **Mutations caught:** no refetch on a host write ((a) and (c) fail), refetch at `pc` instead
    of the current word ((a) fails), a tick lost on a bubble (CLKDIV 0 fails), and a bubble
    after every instruction (CLKDIV 0 fails, and Test 9 fails). The old RTL fails exactly the
    three taken-jump gaps at CLKDIV 0.

## D51. Independent verification without changing the design

- **Decision (2026-10-29):** add a Python executable specification, clock-by-clock RTL
  differential tests, stock sigrok decoding, and maintained third-party protocol models.
  This is verification work: no instruction, register, protocol program, or RTL behavior is
  changed. GDS, gate-level regression, synthesis and physical design are outside this work.
- **Alternatives:** more checks inside the existing SystemVerilog protocol models are useful
  but share assumptions with the design. A specification-driven Python model provides a
  separate oracle; external decoders and bus libraries provide additional independent views.
- **Model boundary:** instruction semantics come from `src/pbe_engine.sv`'s header, the
  register map from `src/tt_um_pbe.sv`'s header, CRC/line framing from their headers and D50.
  Reset, two-stage input synchronization, simultaneous events, pre-edge FIFO acceptance and
  host read staging are explicit. Undefined unwritten storage is represented, not assigned
  a convenient hardware reset value. No simulated engine state is copied into the oracle.
- **Stimulus and observation:** real host SPI pins load programs and configurations, drive
  FIFO traffic and modify memory while running. Each clock compares `uio_out`, `uio_oe`,
  `uo_out`; completed runs also compare FIFO contents, flags, CRC and host status readbacks.
  A test-only NOP initialization of program memory makes stopped-engine fetches deterministic;
  subsequent program loads and modifications use the host port. FIFO storage is unreset.
- **Timing:** cocotb 2 uses an even 20,832 ps period (approximately 48 MHz); exact real
  48 MHz cannot be represented by an integer number of picoseconds. Directed engine tests
  check D50 independently at dividers 0, 1 and larger values. The line coder has a separate
  differential campaign, so failures can be localized before engine integration.
- **Reproducibility:** `make diff N=1000 SEED=0x504245` runs consecutive seeds, logs the first
  mismatching clock/PC/instruction and both states, and writes coverage plus a failure JSON.
  Saved model/tool regression seeds live in `test/differential/regressions.json`. The short
  fixed-seed smoke is part of `make test`; extensive campaigns remain explicit targets.
- **Failure policy:** disagreements are classified as RTL, model, tool or underspecified
  text. Record before/after evidence and reproductions in `BUG_LOG.md`. Unfixed external-tool
  failures remain explicit failing commands; they do not justify changing RTL. Runner XML
  must contain tests and no failures, since the simulator process's exit code alone is
  insufficient with cocotb's Python runner.
- **Parallel work:** separate agents own the engine/line model, sigrok tests, and third-party
  bus tests; the coordinator owns the top-level model, integration and phase commits. Shared
  source is inspected, and only verification files and the three VCD testbench opt-ins change.
- **Tools, results and limits:** see `pbe_v1/verification/REPORT.md` and phase-specific reports
  for exact versions, commands, measured coverage and decoder/library limitations. Evidence
  here is behavioral simulation only; it makes no new routed timing, silicon or board claim.

## D52. Decode captured protocol pins with stock sigrok layers

- **Decision:** add an off-by-default `PBE_SIGROK` testbench define for scalar
  external pins and phase markers, then decode generated VCDs using unmodified
  sigrok decoders. Preserve the existing optional full-design `+vcd` captures.
- **Alternative:** writing another protocol decoder would repeat assumptions.
  The stock UART/SPI/I2C/1-Wire/Modbus/WS2812/USB decoder stacks are independent.
- **Extraction:** retain preceding idle levels and coalesce same-timestamp VCD
  updates, with 10 ns sample spacing and fixed pre/post padding. Preserve original
  hashes, boundaries, commands and decoder stdout. The capture-boundary regression
  is part of the default test suite and requires no sigrok installation.
- **USB limitation:** valid windows check ten control requests; the complete
  packet trace independently checks corrupt traffic and identical retransmission.
  An additional strict full-request target retains two known stock-decoder
  failures (BUG-050/051). Neither those failures nor window selection changes RTL.
- **Results:** 22/22 primary checks pass from fresh simulations; strict full-request
  comparison is 22/24 on libsigrokdecode 0.5.3. Versions, commands and boundaries
  are in `pbe_v1/verification/PHASE2.md` and its checked-in evidence.

## D53. Third-party bus endpoints attach only to chip pins

- **Decision:** use pinned cocotbext UART/SPI/I2C libraries through a test-only
  scalar-pin fixture. Load/configure/read the actual chip exclusively through
  host SPI. A resolved digital bus uses pull-ups and low-dominant wired signals.
- **Alternatives:** hierarchical memory/FIFO deposits would speed setup but bypass
  host behavior; handwritten endpoints would offer less independence. Neither is
  used in these bus tests. The fixture is not an analog pad or contention model.
- **Random settings:** independent endpoint bytes, gaps, UART baud choices, SPI
  mode-0 clock choices and I2C rates/stretching. Three cases cycle -1%, nominal,
  +1% error for externally timed UART, peripheral SPI and target I2C. Controller
  SPI/I2C vary program dividers. The original SPI programs only support mode 0;
  selecting modes 1–3 fails with an explicit unsupported-mode message.
- **Compatibility:** cocotbext-spi 0.5.0 needs local cocotb-2 API/time adapters;
  cocotbext-i2c 0.1.2 needs receive sampling after actual SCL-high when stretched.
  The library implementations remain installed unchanged. The test file names
  these adaptations, and `--stock-spi`/`--stock-i2c` reproduce their failures with
  nonzero exits. No design change is used to satisfy an endpoint assumption.
- **Stretch stimulus:** an independent low-phase stretcher only starts after an
  existing SCL falling edge; a callback delay that creates extra edges is invalid
  stimulus and was rejected (BUG-056). A target's host-response latency separately
  tests legitimate target clock stretching.
- **Evidence:** six endpoints, 18 randomized cases pass; final randomized SPI gap
  rerun and six-endpoint smoke also pass. Full settings, versions, limits and
  reproducible bugs are in `pbe_v1/verification/PHASE3.md` and bus `results.json`.

## D54. Bootstrap Python verification dependencies in GitHub regression

- **Decision:** the existing regression workflow selects Python 3.11 and installs
  `pbe_v1/test/differential/requirements.txt` before the expanded `make test`.
  The new model and differential smoke remain mandatory, with failures propagated.
- **Alternative:** silently skipping the differential test when cocotb is absent
  would make local and CI verification differ and could produce misleading passes.
- **Scope:** dependency setup only. No RTL, protocol, GDS or gate-level workflow
  change. The two physical-flow entry points retain their existing triggers.
- **Evidence:** missing-dependency import fails with an unconfigured interpreter;
  the pinned environment imports cocotb 2.0.1 and runs the suite. See BUG-057.

## D55. Round-2 verification records contracts, negative checks and tool versions

- **Scope:** branch `verify/round2` starts at `verify/golden-model` commit `2d62b89`.
  Complete the round-1 audit before formal/vector/coverage phases. Run `make test`
  successfully before each phase commit; long jobs stay separate. Do not merge
  to main or invoke physical-design/GDS/gate-level flows.
- **Model independence:** distinguish original specified ISA rules from exact
  cycle priorities learned from implementation. The rule inventory in
  `pbe_v1/verification/ROUND2_MODEL_AUDIT.md` preserves that provenance. Header
  additions document existing behavior; they do not retrospectively make a
  shared model assumption independent. Behavioral HDL remains unchanged.
- **Alternatives:** calling every model agreement an independent specification
  check would overstate evidence. Tightening RTL or restricting formal inputs to
  hide the original stronger window/write claims would conceal counterexamples.
  Retain those assertions as explicit expected failures and document the observed
  contract separately (BUG-058/059).
- **Tools installed locally:** OSS CAD Suite archive `20260727`; Yosys
  `0.67+94 (7defa5186-dirty)`; SBY `v0.67-4-gfea6e46`; Yices `2.7.0` revision
  `05178c03ddf49c6bba63c5c7153774c11a5da12d`; Bitwuzla `0.9.1`;
  Verilator `5.051 devel v5.050-99-gf8fb1d664 (mod)`. The bundle is extracted in
  `/tmp/pbe-round2-tools/oss-cad-suite`, not installed into the system. Downloading
  the suite does not invoke its physical-design tools. Icarus12/cocotb2.0.1 and
  the pinned round-1 libraries remain available; receipts record each actual tool.
- **Limits:** finite simulation, BMC, induction proofs, decoder agreement and RTL
  coverage are different evidence. Report assumptions, depth, result and traces
  separately. A two-state formal model alone cannot establish absence of X values
  in a four-state simulator. A failed requested property remains visible.

## D56. Mutation sensitivity is measured using isolated fault copies

- **Decision:** mutate one exact RTL site at a time in an immutable scratch-copy
  baseline, run actual `make test` and `make diff` for every fault, retain raw
  compressed logs plus source hashes and per-check receipts. Never commit a mutant.
- **Alternatives:** compilation errors, infrastructure failures and wall-time
  timeouts do not demonstrate a test detecting a hardware fault. They are recorded
  separately. A simulation watchdog is specifically identified rather than called
  a byte-level assertion failure. Mutant jobs use separate directories.
- **Result:** 24 faults tested; initial suite catches23, separate one-seed diff
  catches17. The sole combined survivor is empty-FIFO pop guard removal. Add an
  independent boundary test and rerun that mutant; it now fails with count31.
  Preserve the original survivor and correction rather than rewriting history.
- **Provenance:** the first aggregate source-hash guard correctly rejected a
  concurrent comment-only audit edit after all48 make invocations finished. Its
  summary is explicitly reconstructed from receipts; it is not claimed as a
  successful original runner exit. The revised runner freezes a baseline and
  offers opt-in comment-only equivalence, with literal hashes strict by default.
- **Evidence:** `ROUND2_MUTATIONS.md` and `evidence/round2/mutations/`. Keep `make
  mutate` separate from the short default gate. BUG-061 records the new boundary
  test, without modifying the correct FIFO RTL.

## D57. Keep full USB decoder disagreements as exact expected failures

- **Decision:** always run full low-speed request decode in `make sigrok`, pin both
  signalling/packet low-speed options and `in_request_start=submit`, distinguish
  PASS/verified exact XFAIL/unexpected FAIL, and keep `sigrok-full` strict. Changed
  versions/results, absent signatures and exceptions are not expected failures.
- **Evidence:** USB1.1 chapters7/8, original PDF hash and source references are in
  `ROUND2_USB.md`. Synthetic packets sent to the unchanged stock request class
  reproduce both defects without PBE waveforms. Both request-start options fail;
  first-ack adds BUG-062. This characterizes tools, not complete PBE conformance.
- **Root cause:** missing DATA/handshake timeout leaves DATA RECEIVED stuck. A
  retry IN is rejected; its NAK finishes stale data, unconditionally appended to
  control IN before an acknowledged retry appends it again. This refines BUG-051.
- **Alternatives:** suppressing traces, treating every failure as expected, or
  editing RTL to fit a decoder would hide faults. Exact independently reproduced
  signatures retain negative evidence. Reject stderr tracebacks even with nonempty
  stdout and exit0; installed decoder source remains unchanged (BUG-062).

## D58. Formal evidence keeps assumptions, bounded checks and failed claims separate

- **Decision:** use one SBY configuration per block, assertion-only generated
  copies in ignored `pbe_v1/build/formal/generated/`, and a source-aware runner.
  Tracked RTL transitions are unchanged. `make formal` is a separate long target;
  the default simulation gate does not install tools or run proofs.
- **Unbounded proofs:** 16-byte FIFO occupancy/boundaries/flush and arbitrary
  selected-item order pass temporal k-induction; synchronized mode-0 host SPI
  framing, addresses, bus strobes and staged read data also pass induction.
  FIFO inputs are arbitrary after one initial reset. Host assumptions enforce
  SCK high/low phases of at least four clocks and legal CS/SCK transitions;
  arbitrary pauses and partial-byte CS aborts remain allowed. Cover-only host
  timing fixes phases to four clocks to accelerate search; proof timing is not
  restricted to that single rate.
- **Bounded checks:** engine safety and coupled pre-edge D50 RAM equality use
  BMC 40, coder off/divider 0. Timeout BMC 50 covers a permanently blocked WAIT,
  TIMEOUT 1–5, CLKDIV 0–3, stable run/config and no host refetch/restart; its
  independent tick-age and clock deadline prevent a vacuous never-issuing pass.
  Four-state reset/restart simulation supplements two-state formal checking.
- **Line scope:** 64 mode/order combinations send two symbolic bytes or 16 bit
  transfers, matched shift direction, detectable nonzero sync and period 3;
  BMC 164 includes a completion deadline at cycle 160. Pair modes assert exact
  length for arbitrary payload. Stuffed single-wire modes assert payload-prefix
  delivery and allow idle suffixes; unstuffed single-wire payload additionally
  has a zero every fourth bit. Twelve arbitrary-input stuff-reaction BMC jobs
  and 12 reachable-response cover jobs use depth 48. Shared encoder/decoder
  composition does not independently prove the stuffing algorithm's merits.
- **Retained failures:** original physical/actual PC fences, period-0 reception,
  no-sync/idle-high/exact-length single-wire claims and unconditional stuff-error
  claims remain explicit failed properties with traces. Twelve expected failures
  are not counted as proofs or passing assertions. No RTL restriction was added
  to hide them. Host/engine/cover monitor corrections and receipt metadata bugs
  are recorded separately (BUG-063/064/066/067/068/071).
- **Alternatives:** BMC alone cannot replace induction for FIFO/host safety;
  assuming away all original failing assertions would misstate the request;
  changing source behavior to satisfy a test would defeat verification. A global
  all-rate/all-protocol claim is rejected in favor of named contracts/depths.
- **Provenance and tools:** `formal/run.py --collect` compares every expanded
  task configuration and copied source against the checkout, rejects missing
  statuses, unrelated expected-failure errors, timeouts and stale inputs, checks
  induction evidence, and records effective last-option overrides. SBY
  v0.67-4-gfea6e46, Yosys 0.67+94 and Yices 2.7.0 produced the results; Icarus
  supplies the separate four-state simulation. Existing D55 records bundle and
  alternate-solver versions. No physical-design/gate-level flow was invoked.
- **Result:** 108 jobs match their explicit expectation: 2 induction proofs,
  79 bounded assertion passes, 15 successful cover jobs reaching 22 statement events across jobs,
  and 12 failed original properties. Contracts, raw compressed logs, exact
  hashes, counterexample VCDs and aggregate receipt accompany the three block
  reports. This is finite/assumption-qualified verification, not tapeout sign-off.

## D59. Reference vectors use external CRC and protocol encoders against captured RTL traffic

- **Decision:** test the real `pbe_crc` public ports with fixed primary RevEng
  catalogue records and independent `crccheck`; test USB and Modbus through the
  chip pins using packets generated by maintained external libraries. Keep
  these longer vector targets separate from default `make test`. Targets never
  install dependencies automatically or modify RTL/protocol programs.
- **CRC contract:** pin poly/width/init/refin/refout/xorout/check/residue metadata
  for 25 catalogue entries, including every CRC family used by the programs and
  at least ten extra configurations across widths 3–16. Twenty-two native
  configurations pass ASCII `123456789`, empty data, eight seeded random payloads
  each, exact-width appended checksum/residue, raw CRC_GOOD and corrupted-checksum
  checks. Three arbitrary-init configurations are explicitly unsupported and
  not counted as RTL passes. Feed bit order and raw/reflected output remain
  distinct; xorout is an explicit software transformation, not a new register.
  USB catalogue residue B001 corresponds to raw CRC_GOOD 800D; CRC5 residue 06
  corresponds to raw good 0C. CRC-12/UMTS exercises unequal input/output reflection.
- **CRC boundary:** direct-unit testing establishes primitive behavior, not
  automatic configuration in an unchanged program. USB's program checks its
  supported token CRC5 pattern rather than adding dynamic arbitrary-token CRC5
  logic. The primitive accepts only zero/all-one native seeds; arbitrary xorout
  values may require host/software work. No internal CRC state is forced.
- **USB vectors:** LUNA packet helpers generate PID/token/data/handshake bytes
  and CRC5/CRC16; usb-protocol additionally validates PID complement nibbles.
  The latter release lacks a raw CRC packet encoder, so using LUNA is an
  explicit alternative to writing a local encoder. Retain the existing bus
  serializer/receiver and firmware model, while expected complete packet bytes
  come from the external helpers. Two seeds each pass 38 host packets and 13
  final DUT responses, including rejection, descriptors, vendor data and STALL.
- **Modbus vectors:** PyModbus FramerRTU builds request/response ADUs and checks
  actual captured frames independently. Seven pin-level cases cover varied
  addresses/counts/data, 19,200/115,200 baud, 8E1/8N2, a corrupt CRC and a two-
  character mid-frame gap. The electrical gap assertion belongs to the wire
  bench/program status; PyModbus has no electrical-time input.
- **Alternatives and limits:** handwritten CRC/PID generators or golden-model
  self-comparison would share more implementation assumptions. Independent
  packet bytes do not independently validate the retained serializer, receiver,
  firmware behavior or analog pads, nor establish complete USB/Modbus conformance.
  No unsupported hardware feature is introduced to fit a catalogue entry.
- **Tools/provenance:** primary RevEng catalogue accessed 2026-10-29; crccheck
  1.3.1, cocotb 2.0.1, Icarus/vvp 12.0; measured Python 3.10.12 for CRC and
  protocol runs. The earlier CRC 3.10.14 entry came from the cocotb banner and
  is corrected by launcher/embedded probes in phase 3 (BUG-073), with old
  receipts/logs preserved. Protocol pins use luna-usb 0.2.3, usb-protocol 0.9.2 and pymodbus
  3.11.3. Requirements, catalogue anchors, commands, generated tasks, hashes,
  raw outputs and before/after BUG-065 evidence are checked in with the two
  vector reports. Only simulation runs; no physical-design flow is invoked.

## D60. Coverage reports logical obligations separately from raw tool instances

- **Decision:** build/run the normal SV benches under Verilator with coverage,
  then reuse the same per-clock top differential oracle and independent line
  sweep. Add observation-only cover instrumentation in ignored scratch sources;
  never change tracked RTL, protocol programs or assertions to obtain a hit.
  Keep `make coverage` as a separate long target and `make test-coverage-tools`
  as seven fast harness regressions. The ordinary gate remains Icarus/four-state.
- **Functional obligations:** aggregate 92 named bins by logical name across
  engines and test roots: 8 opcodes, 22 sub-ops, 8 JMP conditions, 8 pin/flag
  WAIT conditions, 3 timeout/overflow/D50 events, 10 STATUS set/clear transitions,
  32 active line modes and simultaneous running engines. Initial 89/92 gaps
  close with observable WAIT FLAG RISE/FALL and overflow-clear tests. A hit does
  not imply every engine, operand or taken/not-taken outcome was exercised.
  D50's bin observes an invalidation request; separate fetch assertions check
  the refill. Final functional coverage is 92/92.
- **Structural aggregation:** coalesce identical original RTL source points
  across hierarchies/benches, excluding testbench and appended instrumentation.
  A source point is covered if any instance hits it. Final counts are line
  190/191, toggle 3,186/4,062, branch 278/292, expression 443/461. Preserve the
  raw vendor report separately because it includes testbenches, instrumentation
  and per-hierarchy copies with different denominators. Neither denominator is
  silently substituted for the other. The remaining line is a reachable unused-
  address no-op, not an exclusion or declaration of unreachability.
- **Artifact/provenance rules:** every successful simulation must create a new
  regular nonempty data file. Clear old dumps before launch and before full
  aggregation; propagate compile, assertion, XML and missing-data failures.
  Refresh existing program-image make dependencies before snapshotting hex;
  require source/include signatures for reused builds; isolate differential
  diagnostics by build. Negative regressions retain failure evidence (BUG-072).
  Scratch diagnostic-format and annotation-cwd adaptations are explicit tool
  fixes (BUG-069), with failed originals retained.
- **Alternatives/limits:** a raw per-copy percentage alone obscures logical
  obligations, while reporting only 100% bins hides unexercised structural
  behavior. Keep both. Verilator is two-state: `$isunknown` cannot prove X
  freedom there. Only the model-marked unspecified empty-FIFO MISO bit is masked;
  known outputs remain checked, and the separate Icarus four-state gate remains
  authoritative for those X checks. Preserve three negative contract runs as
  expected failures, not successful assertion traces used to improve coverage.
- **Tools and outcome:** Verilator/verilator_coverage 5.051 devel
  (`v5.050-99-gf8fb1d664`), GCC/G++ 11.4.0, cocotb 2.0.1 and measured Python
  3.10.12. Launcher and embedded Icarus/Verilator probes resolve the misleading
  3.10.14 banner as a metadata discrepancy (BUG-073), without asserting its
  cause. The hardened complete campaign preserves 92/92 bins and all reported
  source metrics. Raw logs, data, hashes, annotations and old artifact-policy
  receipts are retained; no physical-design or synthesis flow is invoked.

## D61. Stress observations preserve adverse results and distinguish deadlines from recovery

- **Decision:** run the optional stress campaign separately from default `make
  test`, using a new external-pin fixture, the existing host/program helpers,
  and independent UART/SPI endpoints. Keep RTL, protocol programs and canonical
  benches unchanged. Expected data comes from fixed or seeded bytes; only pin
  and documented host-register observations determine the outcome.
- **Exit contract:** `make stress` runs the 22 required observations strictly;
  `make stress-characterize` runs all 33 and permits evidence collection to
  complete while retaining five FAIL labels. `make stress-strict` runs all 33
  with a nonzero result for any failed observation. Characterization is an
  explicit alternative to aborting before collecting later margins; it never
  converts an adverse observation into a PASS. Reevaluation of the saved full
  evidence returns strict/required/characterization exits 1/0/0.
- **Measured scope:** UART RX/TX at approximately 500 kbaud passes the required
  ±2% clock-error cases. RX also passes this seed's ±2% independent per-bit
  jitter at ±2% average error, a four-chip-clock delayed digital rising crossing,
  and a one-chip-clock idle glitch. Sampled RX ±3%, ±4% and ±5% pass; the first
  failing sampled points are ±6%, with failures also at ±8%. A centered
  one-chip-clock data pulse changes `00` to `08`. These are finite observed
  operating points, not guaranteed margins over all payloads/phases/rates.
- **Host and concurrency:** 16 UART bytes survive a complete burst plus another
  1 ms without host service and 100-bit pauses between subsequent reads. Of 20
  incoming bytes, the FIFO plus blocked PUSH preserve the first 17; the last
  three are lost while the engine cannot sample. Sticky RX overflow and IRQ
  assert, and a new `42` byte is received after draining without a restart.
  Twelve rounds run UART TX on E0 and SPI controller on E1 with disjoint pins,
  restart/flush both between completed transfers, and compare all UART/MOSI/
  MISO bytes. Each final round measures 1,336 overlapping chip clocks. An
  isolated identical-source differential supplement passes eight seeds and
  276,039 compared clocks with 5,000 stimulus iterations per seed.
- **Deadlines and limits:** the final required run uses a 200 ms simulation-time
  whole-driver watchdog, finite count-qualified drain loops and 1 ms caller
  read deadlines. The earlier full characterization preceded the whole-driver
  watchdog and overlap counter; its byte comparisons/stimulus are unchanged.
  Neither run encounters a caller deadline. A watchdog only bounds the test;
  it does not prove self-recovery or a universal no-hang property. UART's
  single-sample 8N1 program has no dedicated framing-error record or majority
  vote, so the adverse data/clock cases remain visible corruption limitations,
  not asserted RTL defects or cleanly reported protocol failures.
- **Alternatives and evidence boundary:** preserve incorrect bytes and status
  rather than changing the program, relaxing expected data or presenting
  injected corruption as success. A delayed digital threshold crossing is a
  reproducible simulator approximation, not analog slew, metastability or pad
  characterization. I2C, Modbus, USB, 1-Wire and WS2812 stress margins, systematic
  pulse-phase sweeps and mid-byte restart atomicity remain unmeasured here.
- **Tools/provenance:** Python launcher and independently probed embedded runtime
  3.10.12 (startup banner says 3.10.14; see BUG-073), cocotb 2.0.1, cocotbext-uart 0.1.4, cocotbext-spi 0.5.0 with its
  existing documented compatibility adapter, and Icarus/vvp 12.0 stable.
  The clock uses the nearest even integer period, 20,834 ps. Seed `0x50424534`,
  exact bytes/status, raw logs, XML, source hashes, evaluator exits and the
  isolated differential receipt are retained under `evidence/round2/stress/`.
  BUG-070 records a corrected evidence-export interpreter invocation. No
  dependency installs occur in targets and no physical-design flow is invoked.
