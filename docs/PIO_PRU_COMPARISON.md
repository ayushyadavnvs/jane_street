# The PBE against RP2040 PIO and TI PRU-ICSS

The competition asks entrants to "look at the PIO state machines on the RP2040 or the PRU cores
on TI's Sitara parts, and consider what you'd do differently". This document gives our answer.
D2 already notes that the PBE follows PIO's idea of instructions made from protocol primitives,
"we deliberately differ from it ... instead of copying it". The sections below say where it
differs, where PIO or PRU is better, and why we chose otherwise.

## Sources

- **RP2040:** *RP2040 Datasheet*, Raspberry Pi Ltd, chapter 3 "PIO": §3.1 Overview, §3.2
  Programmer's Model, §3.4 Instruction Set, §3.5 Functional Details (side-set, FIFO joining,
  autopush/autopull, clock dividers, GPIO mapping, forced and EXEC'd instructions).
  <https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf>
- **PRU-ICSS:** *AM335x PRU-ICSS Reference Guide*, Texas Instruments, SPRUHF8A, and the PRU-ICSS
  chapter of the *AM335x Technical Reference Manual* (SPRUH73).
- **PBE:** `src/pbe_engine.sv` (instruction set, header comment), `src/tt_um_pbe.sv` (register
  map), `pbe_v1/README.md`, and `docs/DESIGN_DECISIONS.md` (D#).

The external facts below are the documented, headline features of each part. See the last
section for how far each one could be checked in this session.

## Side by side

| | RP2040 PIO | AM335x PRU-ICSS | PBE (this design) |
|---|---|---|---|
| **What it is** | Two PIO blocks inside a microcontroller | Two 32-bit RISC cores inside an application processor | Two protocol engines that are the whole chip: an ASIC on 6×4 Tiny Tapeout tiles (D46) |
| **Machines** | 4 state machines per block, 8 in all | 2 PRU cores | 2 engines (D3) |
| **Instruction set** | 9 instructions (JMP, WAIT, IN, OUT, PUSH, PULL, MOV, IRQ, SET), 16 bits each | General 32-bit load/store RISC with 32-bit instructions: arithmetic, logic, branches, memory access, multiply | 8 opcodes, 16 bits: `[15:13] OP | [12:4] ARG | [3:0] DLY`. `EXT` adds 7 sub-ops for CRC, status and compare jumps, and `FLAG` action 3 holds `MOV` (D5, D6, D40) |
| **Instruction memory** | 32 instructions per block, shared by its 4 state machines | 8 KB instruction RAM per core (2K instructions), plus 8 KB data RAM per core and 12 KB shared RAM | 128 × 16-bit words shared by both engines. Each engine runs in its own 64-word window: jumps are relative to `START_PC` (D4). The host can only write it (D14) |
| **Data registers** | 32-bit OSR and ISR, 32-bit scratch X and Y | 32 general registers (R0–R31) of 32 bits | 8-bit OSR and ISR, 8-bit X counter (D9, D32) |
| **Timing model** | One instruction per (divided) clock. A 5-bit field is shared between a delay and side-set. Clock divider 16.8 fractional | One instruction per 200 MHz clock for most instructions; timing comes from counting instructions | Each instruction issues on a tick (one clock every `CLKDIV + 1`, 16-bit integer divider) and then idles `DLY` (0–15) ticks (D5, D7). Blocked instructions are checked every clock, and the divider restarts when they complete (D7). Since D50 instructions run from an instruction register: at `CLKDIV` ≥ 1 timing is exactly `(DLY+1)(CLKDIV+1)`; at `CLKDIV` 0 a taken jump costs one clock, and a tick that falls on that bubble is held, never lost |
| **FIFOs** | 4 × 32-bit TX and RX per state machine, can be joined into one 8-deep FIFO; autopush/autopull at a set bit count; DMA | No FIFOs to the host; data moves through memory (data RAM, shared RAM, SoC memory over the system bus) | 16 × 8-bit TX and RX per engine (D10). Explicit `PULL`/`PUSH`, no autopull (D32). Sticky RX-overflow status with an IRQ (D33). `RX_COUNT`/`TX_COUNT` and a TX-only flush (D43) |
| **Pin mapping** | Base and count per group (OUT, SET, IN, side-set) and a JMP pin, over the GPIO bank | Direct I/O through R30 (out) and R31 (in); enhanced GPIO modes (parallel capture, shift in, shift out) | Pins relative to a per-engine `PIN_BASE` (mod 8), a separate `JMP_PIN`, and a per-pin `PIN_OWN` mask choosing the engine that drives each pin (D8, D15). Every pin action covers push-pull, release and open drain (`OUTOD`) |
| **IRQ and flags** | 8 IRQ flags per block that state machines set, clear and wait on; some reach the processor's interrupts | Interrupt controller (INTC) mapping system events to the PRUs and the host | 8 flags; each engine sees 4 through `FLAG_BASE`, so two programs never collide but can share flags on purpose (D11, BUG-017). `WAIT FLAG`, `JMP FLAG0/FLAG1`, `FLAG n, IRQ` to the host; the host sets and clears single flags (`FLAG_SET`/`FLAG_CLR`) |
| **CRC** | None | Done in software on the core | A CRC unit per engine: any polynomial up to 16 bits, init 0 or all ones, reflected output, fed by `OUT` and/or `IN` bits, `NOCRC` per instruction, a settable "good" value for inverted CRCs, inverted output (D29, D41). Used by Modbus, 1-Wire, SMBus PEC and USB |
| **Parity** | None | Software | Send and receive parity in two flip-flops; `OUTPAR`, odd/even/none (D30) |
| **Line coding** | None: NRZI or bit stuffing is written in instructions | None in the core | A line coder per engine: NRZ/NRZI, three stuffing rules (6 ones for USB, 5 ones for HDLC, 5 equal bits for CAN), differential pair with SE0, SYNC hunt, byte or bit transfers, re-centring on every edge (D39). Unit-tested in USB, CAN and HDLC styles |
| **Timeouts** | None in hardware: a WAIT waits for ever unless another state machine or the CPU intervenes | Software counters or the IEP timer | `TIMEOUT` per engine: a `WAIT`, `PULL` or `PUSH` blocked that many ticks is abandoned with no side effects, and the engine jumps to `TIMEOUT_PC` (D31). It ends SPI-peripheral transactions (D35) and tells Modbus frame gaps apart (D47) |
| **Compare** | `JMP X!=Y` and `JMP X--` / `Y--` | Full ALU | `JEQ`/`JNE` (ISR against OSR) and `JLINE` (line coder saw a frame end) (D40) |
| **Host interface** | Memory-mapped on the system bus; DMA; the CPU can `EXEC` an instruction | System bus (OCP) both ways; the host loads and controls the cores | An SPI peripheral on 4 pins (mode 0, host SCK ≤ clk/8) with a 7-bit register map; programs load through `PM_ADDR`/`PM_DATA` in one burst (D12, D13). Status and IRQ pins on `uo_out` |
| **Cost and target** | A peripheral sharing a microcontroller die with CPUs, RAM and other I/O | A subsystem of a large application processor | The whole chip: 337,779 µm² of cells estimated after D50 (Yosys, about 37 % of 916,229 µm²); the first routed run, before D50, used 44.3 %, including 3,590 hold-fix cells (D45, D50). 48 MHz, chosen so USB low speed is exactly 32 clocks a bit (D18) |

## What PIO and PRU do better

- **Side-set.** PIO can drive up to 5 pins as a side effect of any instruction, at no extra
  cycle. The PBE drives one pin per `PIN` instruction. A clock and data change together costs
  us two instructions, or the line coder's pair mode for complementary pins. That is cheap
  because our `DLY` field fills the gaps (D5), but the PBE cannot change two unrelated pins in
  the same clock.
- **More machines.** PIO has 8 state machines; the PBE has 2. D3 chose two because no protocol
  so far needed more, and area was then 15–21 %. The cost shows in the I2C target: a single
  engine cannot watch SDA while it waits on SCL, so the target takes both engines (D37), and
  nothing else can run beside it.
- **Autopull and autopush, wider registers.** PIO refills the OSR without an instruction, and
  its 32-bit shift registers handle words. The PBE spends a `PULL`/`PUSH` per byte and hides it
  in a delay. D32 records why: every protocol so far has a gap at byte boundaries, and if one
  ever does not, autopull is the cheaper fix than wider registers.
- **No jump penalty.** A PIO `JMP` takes one cycle. Since D50 a taken jump at `CLKDIV` 0 costs
  the PBE one clock more, the price of cutting the 48 MHz worst path in two. Programs at
  `CLKDIV` ≥ 1 see no change (D50, `tb_fetch`).
- **DMA and the CPU bus.** PIO's FIFOs feed DMA on a 32-bit bus, and the CPU can `EXEC` any
  instruction. The PBE's host is an off-chip microcontroller on a 4-wire SPI link, so a host
  write takes microseconds. USB's 5 µs turnaround is met only because the engine answers tokens
  itself (D42).
- **PRU: a full processor.** A 32-bit RISC core with 8 KB of program memory, multiply and data
  memory runs protocol stacks, not just bit timing. The PBE's 64-word windows hold one
  protocol's bit layer. USB endpoint 0 fills its window exactly, and a HID endpoint does not fit
  (D42).

## Why we chose differently

| Choice | Decision | Reason |
|---|---|---|
| A delay on every instruction, not side-set | D5 | Protocol timing is mostly "do X, then hold". UART TX is 8 words. A 16-bit word has no room for both |
| `WAIT` checked every clock, divider restarts on completion | D7 | A short edge is never missed, and the following bits are timed from the edge. UART RX samples mid-bit with no extra hardware |
| Open drain as a pin action | D8 | I2C, SMBus and 1-Wire need no special pins and no pindir tricks |
| Two engines, relative pins and flags | D3, D8, D11 | The same program runs on either engine and on any pins. Two flag-using protocols run side by side without editing either one (BUG-017) |
| CRC, parity, timeout and line coder in hardware | D29–D31, D39 | These are what makes a CPU-free protocol engine stop at UART and SPI. Each is general: the CRC unit serves 4 protocols, and the coder is unit-tested in USB, CAN and HDLC styles. v2's USB-only line unit was retired for this reason (D28) |
| A small instruction set on an 8-bit datapath | D2, D9, D32 | PRU's generality costs a RISC core; PIO's 32-bit datapath suits a CPU bus that the PBE does not have. Bytes match the FIFOs and the SPI host link |
| An SPI register port, not a bus | D12 | The chip has no CPU. Any microcontroller, including the Tiny Tapeout demo board's RP2040, drives 4 wires, and the 8 bidirectional pins stay free for protocols |

## What our architecture makes possible

**Implemented and tested:**

- **USB low speed in one engine, with no processor in the bit-level loop.** `usb_dev.pbe`
  (64 words) decodes NRZI, unstuffs, checks PID, address, endpoint, CRC5 and CRC16, and answers
  every token with ACK, NAK, STALL or data in about 3 bit times (measured 3.00–3.19 bit times
  after D50; allowed 2–7.5). The host firmware works at its own pace behind USB's NAK flow
  control: it supplies descriptors, patches the address after SET_ADDRESS, resends a packet
  whose ACK was lost, and handles bus reset (D42, D49). Test 11 enumerates the device from a
  host model at ±1.5 %. On PIO, the same job needs code for NRZI, stuffing and CRC, which the
  datasheet's instruction set does not provide in hardware (see the table above).
- **Two protocols at once.** Test 3 runs UART on engine 0 and I2C on engine 1. Test 6 runs a
  1-Wire Search ROM on engine 0 and I2C on engine 1, from two host processes sharing the host
  port. The 1-Wire program sits at word 64, which also tests jumps relative to `START_PC`
  (D4, D11).
- **Cooperation through shared flags.** In the I2C target, the two engines share one flag
  window: a watcher engine flags START and STOP while the bit engine shifts data, and the host
  ACKs or NACKs an address by clearing a flag or restarting the bit engine (D37, Test 10).
- **Passive watching.** `i2c_watch.pbe` (8 words) watches SDA and SCL and drives nothing.
  Test 10 checks that the chip ignores another device's transfer.

**Proposed, not built:**

- **Protocol sniffing.** A general sniffer that logs another bus's traffic to the host, as
  `i2c_watch.pbe` does for START and STOP. The input path, FIFOs and line coder's receive side
  already exist; a sniffer program for each protocol has not been written or tested.
- **Fault injection.** With the line coder off, a program can produce any bit pattern: wrong
  stuffing, a bad CRC (by sending a fixed `OSR` instead of `OSRCRC`), short pulses or missing
  stop bits. That could test other devices against malformed traffic. Today such faults are
  injected by our testbench models (for example `h_bad_stuff` in `tb_usb.sv`, BUG-040), not by
  a PBE program.
- **More protocols on the same hardware.** HDLC and CAN framing are covered by the coder's unit
  tests (D39) but have no full program. Manchester (MIL-STD-1553) and an abort-on-edge vector
  are listed as next steps (D35, D39).

## How far the external facts were checked

The datasheet and reference-guide hosts were blocked in this session (network policy), so the
documents could not be fetched again. Web search results confirmed these points:

- **RP2040:** two PIO blocks with four state machines each; a 32-instruction memory shared by
  the four; ISR, OSR, X and Y; the nine instructions; TX and RX FIFOs per state machine;
  autopull and side-set (the SDK's register definitions).
- **AM335x PRU-ICSS:** 32-bit load/store RISC at 200 MHz; 8 KB instruction RAM and 8 KB data
  RAM per PRU; 12 KB shared RAM; R30/R31 as output and input; a single-cycle multiplier with
  accumulator; an INTC; the MII_RT Ethernet module.

Not re-checked here: PIO's 5-bit delay/side-set field, FIFO joining to 8, the 16.8 divider and
the count of 8 IRQ flags. Also not re-checked: the PRU's enhanced GPIO modes, and whether
PRU-ICSS has any CRC hardware outside the cores, for example in MII_RT's Ethernet frame
handling. The "CRC: done in software" entry describes the PRU cores only. Check these against
the datasheets above before quoting them outside this repository.
