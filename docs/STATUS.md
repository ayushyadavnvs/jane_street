# Project status and hand-off

The starting point for anyone (person or AI session) picking up the work. Read `CLAUDE.md` first,
then this file. Details live in `docs/DESIGN_DECISIONS.md` (the why), `docs/BUG_LOG.md` (every bug)
and `verify/golden-model/REPORT.md` (the verification record). Last updated 2026-11-14.

## The project

- **What:** the Programmable Bit Engine (PBE), an entry in Jane Street's protocol-emulator ASIC
  competition. Two programmable engines run protocols as programs loaded at run time; a host talks
  to the chip over an SPI register port.
- **Process and size:** Tiny Tapeout, IHP SG13CMOS5L (130 nm), **8x4 tiles** (confirmed by Jane
  Street and Tiny Tapeout for the March 2027 shuttle).
- **Deadline:** 18 January 2027. Planned RTL freeze: about 3 January.
- **Clock:** 48 MHz on `main`; **60 MHz** on `feature/ethernet` (not yet confirmed by a GDS run).

## What `main` contains (159650f)

- Two engines, each with its own **256-word IHP SRAM** program memory (D82) and the `PAGE` prefix
  for programs over 64 words (D83); CRC unit (up to 16 bits), parity, timeouts, 16-byte FIFOs,
  shared flags; line coder (NRZ/NRZI, bit stuffing, differential pair); CAN bit-synchronous
  block on both engines.
- **18 protocols as programs** (see the table in `README.md`): UART, SPI controller and
  peripheral, I2C controller and target, SMBus PEC, 1-Wire, Modbus RTU, WS2812, USB low-speed
  device, CAN 2.0A (2.0B tolerant), JTAG, SWD, PS/2 host, 24-bit GPIO expander, logic analyser /
  waveform generator, quad SPI, HDLC (NRZ).
- **Last GDS run on main's hardware** (run 43211046516, commit 05fb513, SRAM at 8x4, 48 MHz):
  precheck, LVS, antenna and routing DRC clean; both SRAMs powered (IR drop 0.16 mV); setup slack
  +6.81 ns at the slow corner, hold met at all corners; utilization 27 %; gate-level regression
  passed on the routed netlist.

## Open branches

| Branch | Tip | State |
|---|---|---|
| `feature/ethernet` | 57d1c4c | **Ready for a GDS run at 60 MHz.** Quad host port (D89), Manchester line coding (D90), CRC up to 32 bits (D91), 60 MHz (D92), 10BASE-T TX and RX programs with `tb_eth` (D93), HDLC NRZI via stuffing control (D94), the verification round below, and the receive clock-recovery fix (D101, BUG-151: 12/12 required ±13.5 ns jitter cases). Logic-only path 4.00 ns; synth area 277,617 µm². Includes `verify/ethernet`. |
| `verify/ethernet` | 6453473 | Merged into `feature/ethernet`. Round-3 verification (D95–D100, BUG-138–160): golden model + 1,000-seed differential, formal, CRC/Ethernet/HDLC vectors, coverage 219/219, mutation 14/14, stress. |
| `feature/bridge` | (in progress) | Engine-to-engine FIFO link, CAN-to-CAN gateway, UART ↔ I2C bridge, two coverage follow-ups. Based on `feature/ethernet`. |
| `verify/ethernet-download` | d37d0de | Only a transport copy of the verification bundle. **Can be deleted** (owner to confirm). |
| `learn/notes` | 709b06a | The owner's learning notes from the tutor session. Not for merging. |

Merge order planned: `feature/ethernet` (after its GDS run passes) → `feature/bridge` → `main`.

## Open issues

- **60 MHz timing:** not yet confirmed in layout. The GDS run on `feature/ethernet` decides it.
- **BUG-165:** the formal induction proof of the Manchester receive timer's range is incomplete
  (simulation and bounded checks pass). For the next verification round.
- **Ethernet limits** (documented in the round-3 report): a worst-case full-duplex 1514-byte frame
  full of escaped bytes exceeds the quad host port's bandwidth; the host must keep the TX FIFO fed
  (a 30 µs stall corrupts the frame, and it is reported). No analog/compliance testing yet.
- **Coverage:** 4 RTL lines unhit on main (the host clearing CAN status bits 5–7 and an unused
  register address); being closed on `feature/bridge`. Branch/expression/toggle misses still need
  a review pass before the freeze.
- **Not yet done:** FPGA prototype with real devices; the GitHub Pages site; the final
  submission package.

## Plan, in order (one background session at a time)

1. **Owner:** start the GDS run on `feature/ethernet` (Actions → gds → Run workflow → branch
   `feature/ethernet`); review timing at 60 MHz, area, and the gate-level regression.
2. Review and merge `feature/bridge`; verification of the FIFO link (its TODO file).
3. **Blind generality benchmark:** about 10 protocols never targeted (e.g. DMX512, MIDI, LIN, IR
   NEC/RC5, DALI, I2S, SDI-12, Wiegand, DShot, SSI/BiSS, MDIO, Microwire), programs only, no RTL
   change; record which work and why the others don't.
4. General ISA upgrades guided by the benchmark: multi-pin IN/OUT, side-set, an up-counter/compare.
5. Demos: live protocol monitor and fault injection (programs).
6. FPGA prototype on the KV260 (Kria-PYNQ, Python host library, real devices), including an
   Ethernet demo (RJ45 jack with magnetics, a fast comparator, Wireshark on a PC).
7. RTL freeze (about 3 January), final verification pass, final GDS + gate-level runs, the
   submission package (datasheet, verification evidence, demo videos, GitHub Pages site).

## Waiting on the owner

- Start the 60 MHz GDS run on `feature/ethernet`.
- The UltraScale+ board model, and whether Kria-PYNQ on the KV260 is OK.
- Ethernet demo parts: RJ45 jack with integrated magnetics (e.g. HR911105A), a fast comparator
  (e.g. TLV3501).
- Whether to delete `verify/ethernet-download`.
- Reply from Jane Street on how supporting material (docs, verification reports, videos) is
  submitted.
- Paper: which paper and venue (methodology, architecture or open-silicon), if any.

## How work is done here

- **`CLAUDE.md` rules:** every decision in `DESIGN_DECISIONS.md` and every bug in `BUG_LOG.md` in
  the same change; `make test` in `pbe_v1/` before every push; commits authored as Ayush Yadav with
  no AI attribution lines.
- **Before every push of RTL work** also run `make test-verilator` and both lint commands from
  `.github/workflows/regression.yaml` (a missed lint once broke CI: BUG-114).
- **Layout flow:** the `gds` and `gl_regression` workflows run only when started by hand. Only the
  owner starts them. `gl_regression` follows a `gds` run automatically.
- **Sessions:** one background work session at a time, each on its own branch; the orchestrating
  session reviews (structure, numbering, authorship, `make test`, lint, CI, area/timing) and asks
  the owner before merging into `main`. Deeper verification is handed to a separate verifier
  through a `*_VERIFICATION_TODO.md` file.
- **Tools:** Icarus 12 and Verilator 5.020 for `make test`; the OSS CAD Suite 2026-07-27
  (Verilator 5.051, SymbiYosys) for coverage and formal, with the system Icarus kept first on PATH.
