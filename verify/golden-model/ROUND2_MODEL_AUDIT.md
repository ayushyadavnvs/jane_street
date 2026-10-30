# Round 2: model provenance and specification-boundary audit

Baseline audited: `2d62b89`, before round-2 changes. Read `REPORT.md` and `CLAUDE.md`
first. This audit covers all behavioral methods of `model/pbe_model.py` and
`model/top_model.py`, against the original comment headers of `src/pbe_engine.sv`,
`src/tt_um_pbe.sv`, `src/pbe_line.sv`, `src/pbe_crc.sv`, `src/pbe_fifo.sv`,
`src/pbe_host_spi.sv`, and D50. Paths beginning `src/` are repository-root paths
(`pbe_v1/src` is a symlink).

The original claim of a model written only from those original headers is too
strong. The Python representation differs from RTL, and it does not import live
RTL state, but several exact priorities, reset values, counters and pipelines
match implementation details absent from the original headers. Passing those
checks establishes conformance to a documented **observational cycle contract**;
it cannot independently validate the architectural merits of that shared rule.
The tables below preserve this distinction after clarification. A newly written
comment is not evidence that an old model was historically independent.

Classification:

- **S**: stated in the original header or D50; source phrase identifies the rule.
- **C**: missing/ambiguous in the original text, confirmed against the unchanged
  implementation; comments now clarify the existing behavior. This is a shared
  cycle-contract assumption, not independent evidence of correctness.
- **U**: unspecified/unsupported input or representational boundary. The oracle
  must not turn this into a promised architectural behavior.
- **F**: confirmed model/specification defect, repaired as recorded below.

Rows group directly related bitwise operations, but enumerate all observable
rules in the two model modules; logging counters, diagnostic dictionaries and
Python collection layout are listed separately from circuit behavior.

## Engine: `EngineModel`

| ID | Model site and rule | Original source / disposition |
|---|---|---|
| E01 | instruction fields, widths, opcode/sub-op decoding and ignored argument bits | **S**, engine `Instruction word`, opcode table. Values supplied directly to Python must fit the port widths; top register writes enforce widths. |
| E02 | reset PC/instruction-valid/divider/delay/block/registers/latches/history/parity/status/feed/CRC to zero | **C**, engine cycle-contract reset paragraph; top reset paragraph. Original headers did not specify full reset state. Line outputs reset to idle separately. |
| E03 | restart cancels the executing instruction and all its FIFO/flag/IRQ side effects | **C**, engine cycle-contract restart paragraph; previously only an inline implementation comment. |
| E04 | restart clears enables/registers/parity/status/counters/feed count, keeps output latch and previous pin/flag samples | **C**, engine cycle-contract reset/restart paragraph. `instr_q`/feed-shift contents may retain but are invalid/unused. |
| E05 | restart/host init/CRCRST initialize CRC; reset initializes zero regardless of init-ones | **C**, CRC reset/init paragraph and engine restart paragraph. |
| E06 | all execute/readiness/side-effect decisions use pre-edge state | **C**, engine cycle-contract; top edge contract. Python ordering deliberately models synchronous edge semantics. |
| E07 | tick every CLKDIV+1; coder mode bypasses instruction divider | **S**, engine timing and line-coder paragraphs. |
| E08 | `due` uses >=; divider is 16 bits; DLY is four bits; changing CLKDIV live can make a tick due immediately | **C**, live pre-edge config and counter contract. >= matters if a host decreases divider under a running engine; wrapping is port-width arithmetic. |
| E09 | issue on valid instruction with zero delay, or every clock if already blocked; release restarts divider | **S**, engine timing and WAIT/PULL/PUSH blocking paragraphs; **C** for precise old-state issue combination. |
| E10 | DLY is loaded after issue, ticks decrement it, blocked issue does not decrement DLY | **S**, `idles DLY more ticks`; **C** for retained DLY through refetch. |
| E11 | instruction register prefetch, PC points to next word, branch target refill bubble, tick held through bubble | **S**, engine fetch header and D50 chosen 1–2. |
| E12 | empty fetch fills while stopped; PC increments on refill even with run=0 | **C**, engine cycle-contract fetch/stopped paragraph. A stopped engine can hold unknown memory without executing it. |
| E13 | run=0 freezes issue/divider/timeout, but history, line events/coder, host clears and pending CRC bits continue | **C**, engine cycle-contract stopped paragraph. Clearing run is not an abort/reset of an active frame. |
| E14 | pin/adjacent coder/JMP indices wrap mod 8 | **S**, engine `Pin numbers ... (mod 8)`; pair adjacency inherits physical 3-bit index. |
| E15 | DRV0/DRV1/TOG drive; REL only clears enable; OUT consumes bit; OUTOD latches 0 and enables iff bit=0; END off does nothing | **S** for named pin acts; **C** for latch/enable side effects and END off, engine cycle-contract pin paragraph. |
| E16 | output/in shifts are eight bits, zero-filled; bit ordering follows SHIFT; byte coder OUT leaves OSR unchanged | **S**, engine shift/line paragraphs and top SHIFT map; **C** for byte OUT OSR retention and exact fill, cycle-contract pin paragraph. |
| E17 | IN coder-valid byte replaces ISR, bit shifts; frame-end release leaves ISR; parity still XORs old coder data bit on an IN released by end | **S** for ISR and frame-end behavior; **C** for parity side effect, engine cycle-contract. CRC does not feed without valid data. |
| E18 | WAIT pin/flag low/high/rise/fall; flag index ignores ARG8; history updated every clock, even stopped/bubble | **S** for conditions and flag bits; **C** for sample history cadence, engine cycle-contract WAIT paragraph. No edge event queue. |
| E19 | eight JMP conditions; X-- branches on old X, decrements only nonzero, never underflows from zero | **S**, opcode condition list; **C** for decrement interpretation, engine cycle-contract. |
| E20 | SET X/OSR and PULL overwrite register; PUSH captures old ISR then zeroes ISR | **S**, opcode table. |
| E21 | PULL stalls empty; PUSH stalls full; later pop/push acceptance uses the same pre-edge FIFO state | **S**, blocking and opcode paragraphs; **C** for simultaneous top/host case, FIFO cycle contract. |
| E22 | full-PUSH marks overflow even before readiness; IRQ emitted only first time while sticky overflow was clear | **S** for sticky status+IRQ; **C** for first-only IRQ/reassertion behavior, engine cycle-contract status paragraph. |
| E23 | FLAG set/clear selects one relative flag; IRQ action independent of flag index; MOV source zero and destination zero NOP | **S**, opcode table; physical flag mapping is top-level. |
| E24 | every OSR load resets TX parity, OUT/OUTOD accumulates selected bit, OUTPAR does not shift/feed CRC | **S**, parity and CRC paragraphs; **C** for MOV/OSRCRC loads included, engine cycle-contract. |
| E25 | receive parity accumulates IN since STAT; MOV/PUSH ISR writes do not clear parity; odd/no-parity flags alter error/OUTPAR | **S**, parity paragraph; **C** for non-STAT ISR writes and frame-end IN detail, cycle-contract. |
| E26 | status bit packing; CRC equality, raw sticky line/overflow/timeout, parity error | **S**, EXT STAT table and top STATUS map. |
| E27 | STAT snapshots old status then clears parity/timeout, leaves line error/overflow | **S**, EXT STAT table; **C** for old-state snapshot/collision timing. |
| E28 | OSRCRC uses old CRC value, low/high byte, optional inversion | **S**, opcode table; **C** for old-state snapshot when init/feed coincides. |
| E29 | JCRCBAD combines CRC mismatch/line error; JEQ/JNE compare ISR/OSR; JLINE consumes sticky event | **S**, opcode table. New line-end event wins over JLINE consumption: **C**, engine cycle-contract. |
| E30 | host timeout/overflow/line clears; clear beats newly asserted overflow/line error; CRCRST preserves coincident coder error absent host clear | **S** for host clear meaning; **C** for simultaneous priority, engine cycle-contract. Timeout assertion later in engine update wins over host timeout clear. |
| E31 | reserved EXT7 executes as no-op with normal delay/sequential fetch | **S**, opcode table `reserved, executes as nothing`. |
| E32 | timeout=0 disables abort; nonzero threshold; relative timeout target and sticky status | **S**, timeout paragraph and top LINE_CFG map. |
| E33 | timeout counts old blocked state on valid ticks, compares old count each clock, readiness beats abort, no timeout in bubble, 16-bit wrap | **C**, engine cycle-contract timeout paragraph. First unsuccessful issue begins blocking; it does not itself increment blocked count. |
| E34 | timeout also applies to coder TX/IN and byte-feed stalls, not just WAIT/PULL/PUSH | **C**, engine cycle-contract, previously omitted by prose. Bounds need stable configuration/run and no refetch/restart disturbance. |
| E35 | six-bit relative branch target addition wraps 128, but sequential PC can escape a 64-word region | **F**, BUG-058: original engine/top `64-word window` promise misleading; headers corrected. Requested unconditional invariant must retain a counterexample. |
| E36 | PM write invalidates both engines on any address; old ready instruction may execute on same edge; stalled current or successor/branch target refetched | **F**, BUG-059: original `never ... stale copy` wording overstates D50 atomicity; header corrected. **S** D50 chosen 3 supports next-to-run refetch, not cancellation. |
| E37 | restart > timeout/taken branch > nonbranch PM-refetch address priority; PM invalidation last; DLY/blocked state retained across refetch | **C**, engine cycle-contract fetch paragraph. Partial same-edge PM write never retroactively changes an old execute. |
| E38 | line pins override normal latch only while coder drive=1; enables OR coder mask; pin ownership applied afterwards | **S**, engine coder pin paragraph/top ownership; **C** for combinational merge of retained normal enables, engine/top cycle contract. |
| E39 | line_end/err are registered pulses sampled next edge into sticky state | **C**, engine cycle-contract and line cycle contract; exact event latency absent originally. |
| E40 | active byte CRC feed globally prevents any next instruction until 8 later feed edges, including no-op and unrelated ops | **S**, engine line-coder CRC paragraph; **C** for all-op readiness override. |
| E41 | byte CRC wire order honors shift direction, queues old OSR/RX byte; init beats feed but queue count still advances; feed continues while stopped | **S** for wire order and eight subsequent clocks; **C** for collision/stop behavior, engine/CRC cycle contract. |
| E42 | unknown instruction represented as None, decode placeholder only while idle; attempting unknown execution raises ValueError | **U**, simulation oracle guard, not hardware behavior. Hardware can execute X/unspecified state. No correctness promise for an unwritten/partial program. |

## Top, FIFO and host: `top_model.py`

| ID | Model site and rule | Original source / disposition |
|---|---|---|
| T01 | two engines, 128 words shared program memory, four 16-byte FIFOs, eight flags/pins | **S**, top map/engine pages and FIFO-depth comment. |
| T02 | 16-entry FIFO circular storage and pointer arithmetic; count uses extra wrap bit | **S** for depth/count; **C** for exact acceptance behavior, FIFO header. Circular arrays/pointer representation are not the only possible implementation. |
| T03 | simultaneous full push+pop accepts pop only; empty push+pop accepts push only; intermediate both | **S** logically from `Push while full and pop while empty are ignored`; **C** clarifies pre-edge occupancy explicitly in FIFO header. |
| T04 | flush wins over pointers but accepted push can still alter old physical slot; no storage reset | **C**, FIFO clarified header. This storage matters to later invalid empty reads, not queued-byte ordering. |
| T05 | FIFO head unqualified asynchronous read exposes stale/unknown even when empty | **C**, FIFO/top clarified header. Original inline `never read before ... written` was false for host speculative read. Logical consumption still requires !empty. |
| T06 | reset preserves FIFO/PM storage but zeros pointers/config/status; FLAG_BASE={0,4}; synchronizers idle host=2, pins=0 | **S** for flag-base reset; **C** for other reset state, top clarified header. |
| T07 | two-stage synchronized inputs, host/engine consume pre-edge second stage; ui high bits and ena ignored | **C**, top clarified edge contract. Original top map named synchronized PINS but no latency/stage count. |
| T08 | all output status bit placement, IRQ OR, run indication, per-pin ownership of value and enable | **S**, top pins and PIN_OWN map. Ownership switch is combinational: **C**, top clarified contract. |
| T09 | all mapped reads: STATUS, config, flags, PM_ADDR, FIFO counts/data, CRC value not polynomial | **S**, top register map. STATUS packing and read/write asymmetry explicitly stated. |
| T10 | unmapped/write-only reads 0, unmapped writes ignored, narrow config writes truncate/read zero-extend | **C**, top clarified contract; originally widths imply truncation but reserved read behavior absent. |
| T11 | CTRL always writes run bits along with restart/flush; self-clearing action bits independent; TX_FLUSH leaves RX | **S**, CTRL/TX_FLUSH map; **C** explicitly confirms run replacement on an action-only write. |
| T12 | host FLAGS replacement wins; otherwise clear beats simultaneous sets from either engine/host | **C**, top clarified priority contract; not originally in FLAG map. |
| T13 | IRQ W1C wins simultaneous assertion, retains unrelated engine IRQ | **C**, top clarified priority contract; W1C alone did not define collision. |
| T14 | FLAG_BASE modulo mapping for set/clear/read/WAIT, overlapping bases allowed | **S**, FLAGS map. Old configuration governs same-edge engine events: **C**, top edge contract. |
| T15 | PM_DATA high byte at even pointer, low at odd, increment modulo256; no PM readable path | **S**, PM_ADDR/PM_DATA map; no-reset/old-byte retention **C**, top clarified contract. |
| T16 | first PM byte write previously fabricated a zero neighbor; now tracks byte-valid mask and retains partial data over reset | **F**, BUG-060; model repaired, RTL untouched. Both-byte initialization is required for deterministic execution. |
| T17 | byte writes to divider/poly/timeout/CRC-good preserve the other byte; full byte config stores reserved bits | **S**, split register map; **C**, top live-config contract. No atomic multi-byte register transaction is promised. |
| T18 | engines both see old flags/FIFO/input/config; all effects computed before shared updates; read staging sees old register mux | **C**, top clarified edge contract. Engine iteration order does not grant one engine early visibility. |
| T19 | host write pulse consumed next edge; program byte update follows old instruction sample; engine configuration refreshed for immediate output mux | **C**, top/host clarified edge contract; D50 only partially specified this. |
| H01 | mode0 rising sample/falling shift, command R/W and 7-bit address, MSB-first bytes | **S**, host header. |
| H02 | byte count modulo8, one registered bus pulse after each data byte, write no event for command byte | **S** for transaction framing; **C** exact pulse latency, host clarified header. |
| H03 | read byte loads two edges after command/data completion; skip falling edge immediately after byte completion | **C**, host clarified header, D43 and old implementation comments support FIFO-pop intent. |
| H04 | exact stream-address exemptions 07/16/26; other increment including wrap127->0 | **S**, host stream-register prose plus top map; **C** exact modulo, host clarified header. |
| H05 | CS high clears partial framing/load/transmit data, retains address/rx/write mode/SCK history; previous bus pulse still commits | **C**, host clarified header; partial frame abandonment follows transaction boundary but retained state unspecified before audit. |
| H06 | reset clears all host state and MISO; writes have unspecified payload MISO, read prefetch may show stale/unknown FIFO head | **C** reset/read-staging contract; **U** architectural payload on write/empty read. Model reproduces implementation output for these cycles. |
| H07 | unknown byte represented by separate bit mask; shifting eventually yields known0; PBEModel.outputs substitutes0 while harness checks unknown separately | **U**, Icarus four-state observation policy, not physical hardware output contract. Unknown need not remain X on another simulator/initialized hardware. |
| H08 | host clock/SCK/CS synchronizer timing valid for >=4 clk per half-bit; no metastability model | **S**, SCK<=clk/8 host header; **U** setup/hold, analog metastability and out-of-rate input behavior. |

## CRC and line model: `EngineModel` CRC path, `LineModel`

| ID | Model site and rule | Original source / disposition |
|---|---|---|
| C01 | width1..16, implied polynomial top, MSB feedback, left shift with zero LSB, poly XOR, width mask | **S**, CRC header for shift/poly; **C** explicit recurrence in clarified CRC paragraph resolves ambiguous `shifted in at bottom`. |
| C02 | init zero/all-ones, init wins feed, reset zero | **S** configurations; **C** priority/reset, clarified CRC header. |
| C03 | reversed output reverses only selected width, zero extends; CRC-good compares raw16-bit state | **S**, CRC value/reversal/good prose; **C** exact width and comparison, clarified CRC header. |
| C04 | changing width/poly/good does not itself reset/re-mask state | **C**, clarified CRC header. Raw state can retain high bits until next init/step. |
| C05 | no native catalogue refin/xorout preprocessing; OSRCRC inversion and bit input order are software operations | **S**, unit's actual interface. Catalogue vector adapter must distinguish transformation from raw CRC configuration. |
| L01 | mode NRZ/NRZI, byte/bit width, stuffing rules/thresholds, pair mode | **S**, line header cfg table. Mode3 remains **U**; model's current fallthrough NRZ-like result is not promised. |
| L02 | reset/clear empties TX/RX and pulses, drive0, output level1/0, previous level1; model cfg0 normalizes to clear | **C**, line cycle clarification; **U** standalone cfg0 with clear=0: integration requires clear on disabled coder. Model convenience not a promise for that unsupported standalone input. |
| L03 | one-entry TX queue, readiness=queue empty; payload expanded into wire-order bit list | **S**, line TX header. Python deque is representation, not RTL dependency. |
| L04 | queues consumed from old state, simultaneous tx_end wins tx_put, end-with-no-frame discarded; producer must honor tx_ready | **C**, line cycle clarification. Sending while not ready is **U**; model can reproduce overwrite but tests must not rely on it. |
| L05 | start gap two full bit periods, first bit following registered kick; gap doesn't drive, sync prepended if nonzero | **S** gap/sync; **C** registered first-bit timing, line cycle clarification. |
| L06 | boundaries use ==period_m1, counters16bits; kick resets timer; active configuration read live | **C**, line cycle clarification. Configuration changes mid-frame are **U** for protocol-valid results. |
| L07 | stuffing includes sync, spans entry boundaries; CAN first run state/inserted bit counts1, one-stuff reset0; stuffed bits also NRZI encoded | **S** stuffing rules; **C** exact initialization/cross-byte scope, line cycle clarification. |
| L08 | underrun raises err each bit boundary and holds drive/level until later data/end | **C**, line cycle clarification; err port originally named underrun but recovery/hold unspecified. |
| L09 | pair end two SE0 periods then idle one period and release; single releases immediately; release retains output latches | **S** frame end slots/release; **C** retained output values and release-edge timing. |
| L10 | half-duplex receiver disabled during any non-idle TX phase, including gap/EOP, not merely drive high | **C**, line cycle clarification; original module description says optional stage but no detailed RX suppression. |
| L11 | receiver starts on low input level (not necessarily transition), SE0 has start priority, idle polarity1 | **S** line idle/frame start; **C** level versus edge distinction, line cycle clarification. |
| L12 | sampler compares old counter to floor(period_m1/2)+1; current edge recenters next timer but does not cancel old due sample | **C**, line cycle clarification; original `mid-bit` insufficient for per-clock prediction. |
| L13 | RX NRZI compares current level against last sampled level initialized1; bit/byte assembly follows IN shift order | **S** cfg/shift semantics; **C** previous-level initialization. |
| L14 | sync sliding window starts zero and can match before8 observed bits; matched sync not delivered | **S** sync suppression; **C** partial reset-window semantics, line cycle clarification. |
| L15 | wrong stuff bit err, except single idle-high run ends frame without err; run/last state advances even when violation | **S** line frame termination/error prose; **C** exact recovery state, line cycle clarification. |
| L16 | idle-high eighth sample can also perform normal final RX delivery; frame_end asserted then unread valid cleared next edge | **S** end/drop intent; **C** delayed registered clear and same-edge delivery, line cycle clarification. |
| L17 | SE0 receiver waits until sampled non-SE0; high=frame_end, low abort-to-idle without frame_end; no check SE0 length | **S** SE0 then idle definition; **C** no duration enforcement and abort detail, line cycle clarification. |
| L18 | RX overrun replaces rx_data with new unit and pulses err; same-edge rx_take permits replacement without err; old frame_end clear wins | **C**, line cycle clarification; original err port names overrun but not overwrite/priority. |
| L19 | period_m1=0 receiver cannot sample (counter0 vs compare1); pair/single arbitrary unframed payload not guaranteed round-trip | **U** for universal protocol claim: exact cycle behavior modeled, no minimum receive bit time originally promised. Retain bounded counterexamples rather than assuming a pass. |

## Representation and validity boundary

`effects()` and `step()` are two-phase API conveniences; calling `effects()` does
not consume an event. `coverage`, `cycles`, `snapshot()` and `state()` are
diagnostics only. `read()` is combinational; `write()` commits register/storage
only and deliberately does not perform restart/flush/FIFO events. `edge()` is
the full bus contract. Program sequences should contain exactly128 words; the
engine's modulo-`len(program)` convenience is not an architectural smaller RAM.
Direct Python configuration accepts arbitrary integers and must be supplied
port-width values, as done by top/register-driven tests. Reset is modeled as a
quiet reset operation, not simultaneous reset+host-memory-write electrical
stimulus. Unknown analog input levels, metastability, pad slew, unknown-bit
arithmetic, and RAM power-up values are outside this deterministic model.

The fixed top test initializes all program memory to NOP before its checked
campaign; it therefore does not validate execution of partially loaded words.
BUG-060 is covered by explicit model contract tests instead. Unknown empty-FIFO
MISO handling is a simulator policy, not permission to report an arbitrary
physical MISO value as deterministic. Long differential runs, mutation checks,
external decoders/library vectors, and formal assertions remain complementary
evidence; none makes these shared assumptions independent.

## Findings, reproductions and changes

**BUG-058 — specification window claim.** Before: engine `each engine works in
its own 64-word window`; top `START_PC ... (64-word window)`. After: six-bit
branch offsets added modulo128; sequential PC has no fence. A NOP stream from
START_PC=0 reaches instruction64. The original requested formal assertion must
be run and recorded as a failing assertion, with a separate conditional
well-formed-program check if desired. No control-flow restriction was inserted.
The physical PC is a prefetch cursor: pc=64 first occurs while instruction63 is
still executing, then pc=65 identifies actual instruction64. The RTL regression
demonstrates these as separate counterexamples, not one off-by-one diagnostic.

**BUG-059 — program-write atomicity overclaim.** Before: `refetches the current
instruction ... never run from a stale copy`. After: a ready instruction can
execute old instr_q on the same PM-write edge; the instruction that runs next
is refetched. In `EngineSpecificationTests.test_memory_write_may_execute_old_ready_word`,
an old DRV1 executes on the write edge; DRV0 replacement does not retroactively
cancel it. The old cancellation interpretation fails the preserved RTL check.
The requested `valid => instr_q == pmem[current_instruction_address]` must be
checked with correct pre-edge sampling and a current address of pc-1; it is
not automatically false merely because a ready instruction can execute on a
write edge. PM invalidation and RAM write occur on the same edge, after that
execution. We do not invent a stale-fetch counterexample where none exists.

**BUG-060 — invented unwritten PM byte.** Before:

```python
old = self.program[word]
old = 0 if old is None else old
self.program[word] = (old & 0xff00 | data) if self.pm_ptr & 1 else (old & 255 | data << 8)
```

After: `_pm_partial` retains value and a known-byte mask; `program[word]` stays
None until both bytes were written. Reset preserves these known bytes alongside
unreset RAM. Existing fully initialized words still permit normal byte writes.

Before the fix, the following new tests failed with `55296 is not None` and
`4608 is not None` respectively; after the fix both pass:

```sh
cd pbe_v1
python3 -m unittest \
  model.test_top_model.TestTopModel.test_partial_program_word_stays_unspecified_until_both_bytes_written \
  model.test_top_model.TestTopModel.test_rewriting_one_unknown_word_half_does_not_initialize_other_half
```

Only Python model behavior changed. Source changes in the six RTL files are
comments, verified by stripping comments before comparison. Clarifications
record existing reset/priority/latency facts already present in the source;
they introduce no new architecture or behavioral RTL decision. Their shared
provenance remains labelled C in this audit, and the round-2 verification
decision records this evidence boundary centrally.

The runnable RTL regression checks both the corrected contract (expected exit0)
and all three retained original stronger claims (expected exit1 plus an exact
failure marker). Unexpected passes, missing markers and simulator failures make
the wrapper fail; expected failures do not make a silent all-green claim:

```sh
cd pbe_v1
python3 ../verify/spec_boundaries/check_spec_boundaries.py
make test-model
```

`evidence/round2/spec_boundary_checks.json` records observed output:
physical pc64/current63, actual instruction64, and a PM write edge with
out=01, oe=01, RAM[0]=0000, iv=0, next_pc=1. The model suites have24 passing
tests (15 engine/line and9 top/FIFO), including the two new PM-validity tests.

## Formal-property review before Phase1

Preserve original claims as executable checks even when they are false; report
their counterexamples before introducing a separately named constrained claim.
No conditional proof below is a proof of the stronger original claim.

| Requested property | Contract/assumptions needed and expected boundary |
|---|---|
| FIFO count and full/empty, flush, ignored boundary operations | Full induction can use reference occupancy with pre-edge acceptance. Reset establishes legal pointers. Count is modulo depth*2, with legal occupancy0..depth. Flush dominates logical pushes/pops; storage can still write and is not a queued item after flush. |
| FIFO arbitrary chosen-item ordering | Track an arbitrary *accepted* push (including identical data values), number of older items, flush epoch, and accepted pops. Empty reads do not consume. A full-edge push rejected while a simultaneous pop succeeds must not be tracked as inserted. |
| SPI one write per any byte sequence | Any bytes under mode0 framing and SCK<=clk/8. Sampling an arbitrarily fast/asynchronous sequence is not the documented interface. CS high may abandon a partial byte; a completed byte's registered pulse can still commit after CS rises. |
| SPI read returns rd_data | Compare serial bits against the value sampled by read staging two clocks after byte completion, not arbitrary live rd_data during the whole byte. FIFO pops land before staging. Skip first falling edge correctly. |
| SPI increment and CS resets | Stream addresses07/16/26 do not increment; all others wrap128. CS resets framing/load/shifter, not all internal address/history. A proof of zero address after every CS would be false. |
| Line all modes, any bytes/bits round-trip, no err | Unconditional property is false: period_m1=0 has no RX sample; no-sync frames can lose an initial idle-level prefix; single-line eight-high runs terminate frames even with arbitrary payloads. NRZ/NRZI mode3 unspecified. Keep these counterexamples. Conditional proof needs supported modes1/2, usable receive period, framing/sync beginning with a detectable transition, equal bit order, no TX/RX queue starvation/overrun, and legal single-wire idle-run restrictions (or pair termination). |
| Line every stuff violation raises err | Unconditional property false by header: single-line idle-high stuffing violation is a normal frame end. Outside that case, constrain transmitter idle/receiver active/sample due and inject the wrong decoded stuff bit at a known stuff slot. Pair-mode violations should err. |
| Engine no X after reset/restart | Immediate reset/restart latches/enables are known. A two-state SMT proof cannot by itself prove four-state X freedom; add a four-state simulator check and defined program/input assumptions for subsequent execution. Restart preserves output latch by design. |
| Engine pc within START_PC..START_PC+63 | False twice: next-word prefetch cursor can be64 during instruction63, and sequential instruction64 subsequently executes. A well-formed program that branches before its boundary can be checked separately, with modulo128 addressing, but that imposes software assumptions. |
| Blocked timeout within timeout+2 ticks | Count only valid ticks after blocking. Hold run=1 and configuration stable; prohibit restart and PM invalidations during the obligation. Assume readiness stays false until timeout, or allow successful completion as the other outcome. The unconstrained claim can be defeated by host continually clearing run/restarting/refetching. |
| FLAG set and clear mutually exclusive; safe TX pop/RX push | Expected to hold unconditionally after reset for defined inputs; engine opcode decode is exclusive, FIFO execution is readiness-gated, restart suppresses all pulses. No software-program restriction needed. |
| Valid instruction matches memory of that instruction (D50) | Track actual current address (pc-1) mod128 while valid, not prefetch pc; pair symbolic memory writes with pm_wr, and compare at consistent edge sampling. This may hold even when a ready old instruction executes on the same PM-write edge. Only atomic cancellation of that instruction is known false. Model instruction input cannot be unconstrained independently of its RAM source. |

Bounded checks need named depth, configuration range and covers demonstrating
the intended scenario was reached (blocked, frame start, stuff insertion,
selected FIFO item consumed). An induction result whose assumptions suppress
the scenario is vacuous and must not be reported as verification coverage.
