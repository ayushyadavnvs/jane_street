# Engine-to-engine link and bridge: verification hand-off

What the design session built (D102 link, D103 UART <-> I2C bridge, D104 coverage follow-ups),
how it was tested, and what the separate verification pass should extend. The link is off at
reset and its registers sit in slots that were unmapped (`0x17`, `0x27`, `0x3D`, `0x4D`), so the
existing models and harnesses still describe the default configuration.

## Status of the existing targets on the default configuration

| Target | Status |
|---|---|
| `make test` (includes `test-link`: `tb_link` and `tb_bridge`; `diff N=2`, `diff-can`, `test-model`, the formal runner's unit test, coverage-tool and sigrok-extract unit tests) | passes |
| `make test-verilator`, both CI lint commands (`verilator --lint-only -Wall`, SRAM and flip-flop builds) | pass |
| `make diff` (any N) | expected to pass: the random host never writes `0x17`, `0x27`, `0x3D` or `0x4D` and never reads the first two; with both links off the RX pop, TX push and TX data input are exactly the host's |
| `make formal` | not run (no SymbiYosys here). `pbe_engine`, `pbe_fifo`, `pbe_host_spi` are unchanged, so their properties are unaffected; only top-level harnesses that build `tt_um_pbe` see the change |
| `make coverage` | not run (long). `coverage/prepare.py` appends to `tt_um_pbe.sv`; the names it uses (`pm_wr_e`, `run`, `host_quad`, ...) are unchanged |
| `verify/ethernet` directed tests | not run (opt-in). `test_directed.py` bursts through `0x51`/`0x52` and expects 0: the link is deliberately not there |

## 1. Golden model (`verify/golden-model/model/top_model.py`)

- State: `link[2]` (reset 0).
- `write`: `0x17`/`0x27` bit 0 sets `link[e]`, bit 1 flushes e's RX FIFO and the other's TX
  FIFO in that clock. `0x3D`/`0x4D` writes do nothing.
- `read`: `0x17 + 16e` = `{4'b0, tx[o].full, rx[e].full, rx[e].empty && tx[o].empty, link[e]}`;
  `0x3D + 16e` = `rx[e].count + tx[o].count`.
- `edge()`, per direction e (o = 1 - e), using pre-edge state:
  `move = link[e] and not rx[e].empty and not tx[o].full and not host_push_tx[o] and not
  rx_flush[e] and not tx_flush[o]`, where `rx_flush = CTRL flush | LINK flush` and `tx_flush =
  CTRL flush | TX_FLUSH | the other direction's LINK flush`. `tx[o].full` is the mark-aware full
  (D70). A move pops `rx[e]` and pushes its head into `tx[o]` in the same edge.
  The host's pop of `rx[e]` (a read of `0x16 + 16e` completing) is suppressed while `link[e]`.
- Both links on at once are independent (a ring is legal).

## 2. Random differential (`differential/run.py`, `test_diff.py`)

- An opt-in profile (like `--ethernet`) that writes `LINK` with random values at random times,
  including bit 1, and reads `0x17`/`0x27`/`0x3D`/`0x4D` in the end-state and random host reads.
- Keep the default profile unchanged (it must not touch the new addresses).
- Seed programs that `PUSH` and `PULL` a lot (echo, bursts) so the path fills and drains; with
  random `MARK`/`REWIND` on the consumer, check the mark-aware full gating.
- Host writes to the consumer's TX FIFO and host reads of the producer's RX data register while
  linked (the priority rules above).

## 3. Formal

- A new top-level harness (or an extension of an existing one) over `tt_um_pbe` with free host
  transactions and free engine `PUSH`/`PULL` (or the FIFOs and the link glue extracted):
  - **Conservation:** per direction, bytes accepted into e's RX FIFO = bytes popped by the host
    (link off) + bytes moved + bytes still in the path + bytes flushed. No move without a pop
    and a push in the same clock.
  - **Order:** a tagged byte pushed into e's RX FIFO before another reaches the other TX FIFO
    first (a two-tag argument, as for the FIFO itself).
  - **No double pop:** never `link_mv[e]` and a host pop of `rx[e]` in the same clock; never two
    pushes into one TX FIFO in a clock.
  - **Off is off:** with `link_en == 0` the FIFO ports equal the pre-D102 expressions (an
    equivalence against the previous `tt_um_pbe` with `0x17`/`0x27` writes assumed away).
  - **Backpressure:** `rx_full[e]` (with the link on) implies `tx_full[o]` or a host push or a
    flush in that clock, or the link turned on in the last clock.
  - `LINK_FILL` = sum of the two counts, 0..32.

## 4. Coverage bins

- `link_mv[e]` for each e; `link_mv[e]` with `tx_full[o]` just cleared (a pop by engine o);
  with a held mark on `tx[o]`.
- A host push of `tx[o]` in a clock with a move pending (the "host wins" branch);
  a host read of `rx[e]`'s data while linked (the suppressed pop).
- A flush of either end while a byte is ready (the move gated off); the `LINK` flush bit.
- `LINK` written off while the path is non-empty; both links on (a ring).
- `rx_full[e]` with the link on (path full) and the engine's `ovf_now` in that state.
- `LINK_FILL` = 0, 16, 32. Read of `0x3D`/`0x4D` and of `0x17`/`0x27`.
- D104: `tb_can ONLY=hostclr` now executes the `host_arb_clr`/`host_berr_clr`/`host_sent_clr`
  bodies, and `tb_link` g the second-page write default (update `COVERAGE.md` once the
  coverage campaign is re-run).

## 5. Mutation targets (`make mutate`)

- Drop `!host_txw[O]` from `link_mv` (two pushes in one clock: one byte lost) - caught by
  `tb_link` d.
- Drop `!link_en[e]` from the host pop (double pop) - caught by `tb_link` d (no-pop check).
- Use the raw `wptr == rptr` instead of the mark-aware `full` (overwrite past a mark).
- Drop the flush gating of `link_mv` (a byte vanishes on a flush of the other end).
- Swap `O` and `e` in the TX FIFO's `din` mux.

## 6. Bridge (D103) independent checks

- Bus models: the UART terminal and the I2C register target in `tb_bridge` are behavioural;
  cross-check with `golden-model/bus_models` (cocotb) and sigrok's `uart` and `i2c` decoders on
  a VCD of `tb_bridge` (pins 0-3).
- Random command sequences (lengths 0-12, random addresses, protected registers) against a
  Python model of the command format; the terminal waits for each reply (half-duplex).
- Stress: baud error of the terminal (+-3 %), target stretching up to the limit in D103.

## 7. CAN-to-CAN gateway (deferred by the owner): the worked-out design

No more hardware is needed: the link (32-byte path, blocking `PUSH`), MARK/REWIND on the
consumer's TX FIFO and the shared flags are enough. To do: two programs and `tb_gateway` with
two separate buses of `can_ref_node`s.

- **Bit order.** The engines have no shift: units narrower than 8 bits arrive right-justified
  (`IN`) but are sent from the top of OSR (`OUT`, MSB first). Use LSB first: engine 0 (bus A,
  receive) `SHIFT` = 0x00 (IN LSB first: a unit's first bit at bit 0); engine 1 (bus B, send)
  `SHIFT` = 0x02 (OUT LSB first, IN MSB first, so its own echo parses like `can_node`'s). Every
  received unit is then a byte engine 1 can send unchanged, whatever its width.
  - Engine 1's CRC: `CRC_CFG` = 0xAE (reversed output). After the data, `OSRCRC LO` gives
    c14..c7 at bits 0..7 (W8); after those 8 bits are fed back, `OSRCRC LO` again gives c6..c0
    (W7). (With reversal `rev[i] = crc[14-i]`; feeding the CRC's own bits shifts it left 8.)
- **Record on the link (engine 0 -> engine 1):** `[u1][u2][u3][u4][n][d1..dn][verdict]` with
  units of 8, 4, 4, 3 bits (SOF+ID10..4, ID3..0, RTR/IDE/r0/DLC3, DLC2..0), n = data bytes
  (0 for remote frames, 8 for DLC >= 8), verdict 1 = good (status 0x02 or 0x0A), 0 = bad.
  - Engine 0 filters on u1 (prefix entries: 16 IDs) and on u1+u2 (exact IDs) before pushing
    anything; filtered frames are still walked to the end (else its coder flags stuff errors).
  - n needs the bit-reversed DLC2..0: an 8-entry `JEQ` table.
  - Truncated frames (error vector) are padded so engine 1 can always parse the record: OSR
    holds a phase (0 nothing pushed, 1 header: owe 3 zero bytes, 2 data: owe X+1 bytes,
    3 complete), then a bad verdict.
- **Handshake:** engine 0 sets a shared BUSY flag (its FLAG0; engine 1's FLAG_BASE = 0) before a
  record's first push and clears it after the verdict. Engine 1 starts a record only when its
  TX FIFO is non-empty and BUSY is clear: then every byte in the path belongs to complete
  records, so its blocking `PULL`s wait only for the mover (a few clocks) and it never stalls
  mid-frame on bus B.
- **Engine 1:** `MARK`, scan the record (u1..u4, n, skip n, verdict). Bad: drop (the next idle
  re-`MARK`s). Good: `REWIND`, check RXD once more (a frame started meanwhile is received
  first), send as `can_node` does with the n byte skipped by one `PULL NOWAIT`; not sent
  (arbitration lost, error) -> `REWIND` and retry; sent -> `PULL` the verdict byte. Foreign
  frames on bus B are walked by a receive-only copy of the walk (no `PULL`/`OUT`: a receiver
  that `OUT`s queued bytes would drive them).
- **Overload:** if bus A forwards faster than bus B can send, engine 0's `PUSH` blocks, its coder
  overruns, the frame is truncated and padded: frames are lost, never corrupted or reordered.
