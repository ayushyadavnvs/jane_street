# Ethernet work: verification hand-off

What the design session (D89-D93, and D94 if present) built and tested, and what the separate
verification pass still has to do: golden-model updates and the random differential, formal,
coverage, mutation, sigrok/vector cross-checks and stress. Every new feature is off by default
(reset values), so the existing models still describe the default configuration; each section
says which `verify/` targets must be extended for the new one.

## Status of the existing targets on the default configuration

| Target | Status after this work |
|---|---|
| `make test` (includes `make diff N=2`, `diff-can`, `test-model`, the formal runner's unit test, `test-coverage-tools`, `test-sigrok-extract`) | passes (run before every push) |
| `make test-verilator` and both CI lint commands | pass |
| `make diff` (any N) | expected to pass: the random programs never select LINE mode 3, `CRC_CFG2`, `HOSTCFG` or ui_in[5:3]; `OSRCRC` param[3] keeps its old meaning for CRCs of up to 16 bits (D91) precisely so that the random programs, which set every EXT parameter bit, still match |
| `make formal` | not run here (no SymbiYosys in this container). Expected impact: `pbe_crc` ports are 32 bits and `width_m1` 5 bits; `pbe_line` has a new input `a_early`; `pbe_engine` has new ports `crc_wide`, `pins_in_n` and 32-bit CRC ports; `pbe_host_spi` has quad ports. Harness files that instantiate these modules by port list (`verify/formal/*.sv`, `*_prepare.py`) need the new ports tied off (`crc_wide` 0, `a_early` = `a_in`, `quad_req` 0, `mosi_hi` 0) |
| `make coverage`, `make stress`, `make mutate` | not run here (long campaigns). Same port tie-offs as formal where they build a module directly |
| `make test-buses` | `golden-model/bus_models/test_buses.py` has `PERIOD_PS = 20834` (48 MHz): update to 16668 and re-derive any baud divisors from it |
| `make test-crc-vectors` | passes (run on the CRC-32 commit: the catalogue's CRCs of up to 16 bits) |
| `make sigrok*`, `make test-protocol-vectors` | not run here (no sigrok-cli; the protocol packages not installed). The benches they capture now run at 60 MHz; decoders use timestamps, so they should be unaffected, but check |

## 1. Quad host port (D89)

- **Spec:** `src/pbe_host_spi.sv` header, `src/tt_um_pbe.sv` register map (`HOSTCFG` 0x50, the pin
  list), D89.
- **To verify:**
  - Single lane is the reset state; with `HOSTCFG` = 0 and ui_in[5:3] at any value the port is
    cycle-identical to before (an equivalence check against the pre-D89 `pbe_host_spi`).
  - The mode is latched only while CS_n (synchronized) is high: a transaction never changes mode
    half-way, including the one that writes `HOSTCFG`, and including a CS_n pulse shorter than a
    clock.
  - Quad framing: nibble order (high first), D0 = ui_in[2], Q0 = uo_out[0]; the command byte, the
    auto-increment, the streaming registers (0x07, 0x16, 0x26), the read pipeline (`load_dly`)
    and the "skip the falling edge after the last bit" rule with `bitcnt` stepping by 4.
  - Exit by 8 SCK rising edges with CS_n high, in quad and in single mode; the counter resets
    when CS_n goes low; 7 edges do nothing; `quad_exit` and a `HOSTCFG` write cannot coincide
    (a write needs CS_n low).
  - uo_out[3:1]: Q3..Q1 only while quad and CS_n (synchronized) low, status otherwise; check for
    a glitch on the mux at the CS_n edges (it switches on the synchronized CS_n: a host must
    ignore those pins for 3 clocks after its CS_n edge).
  - The maximum SCK, clk / 8, in quad mode at every phase of SCK relative to clk (the read path:
    falling SCK -> synchronizer -> shift -> Q pins -> host sample at the next rising SCK).
  - `HOSTCFG` readback; reset value; unmapped neighbours (0x51-0x7F) still read 0.
- **Corner cases known:** the first transaction after `HOSTCFG` = 1 in a burst that
  auto-increments past 0x50 (writes 0x51...: harmless, unmapped); a read of the RX FIFO in quad
  mode while it is empty (the same unspecified head data as single mode); the TX-full pin is
  valid about 6 clocks after a byte's last SCK edge (`tb_eth` waits 2 clocks after `spi_byte`
  returns).
- **Targets:** golden model (`top_model.py`: the host synchronizer is 6 bits, `HOSTCFG`, quad
  shifting, the uo_out mux); `make diff` with quad transactions in the random host traffic;
  formal host properties (`verify/formal`, host block) for the quad framing and the latch; new
  coverage bins (quad bytes, exit by SCK, mode change at CS_n); a mutation or two (nibble order,
  the latch); stress: host SCK at clk / 8 with random phase and jitter in quad mode.

## 2. Manchester line coding and both-edge sampling (D90)

- **Spec:** `src/pbe_line.sv` header (Manchester paragraph), IEEE 802.3 clause 7.3.1.1 (the
  encoding), 14.3.1.2.1 and Figure 14-10 (TP_IDL), 14.3.1.3 (receiver jitter: the design was
  tuned to ±13.3 ns per edge; confirm the standard's figure, commonly quoted as 13.5 ns, and
  whether it is per edge or per interval), D90.
- **To verify:**
  - Transmit: halves floor(period_m1/2)+1 and the rest, for odd and even periods; polarity
    (`LINE[7]`); bytes and bits, LSB/MSB first; the SYNC byte; the 3-bit-time high tail after
    `END` then release; an underrun holds the level and pulses `err` once per bit time.
  - Receive: the reference loop (gain 1/4, eighths), the acceptance threshold 6 x period_m1
    eighths after the reference, carrier loss at 16 period_m1 + 8 eighths; `a_early` half-clock
    timing; frame start on any edge in `R_IDLE`; `frame_end` only when SYNC was found (or SYNC
    = 0); overrun; `frame_end` clearing an untaken byte (BUG-028 rule); clear/restart.
  - The top level's falling-edge synchronizer (`pins_n0` on negedge, `pins_n1`, `pins_n2`): reset,
    the half-cycle path in STA, and that only the Manchester receiver reads it.
  - Default equivalence: modes 0-2 cycle-identical to before for every LINE/LINE2 value (the
    formal `default` block and `check_line_model.py` cover modes 1 and 2 only: extend the model
    to mode 3, or prove mode 3 does not touch the other modes' state).
- **Corner cases known:**
  - The first transition after idle is taken as a mid-bit transition; with an idle-high
    receiver (comparator wired the other way) the first lock is wrong until the first 0/1 pair;
    the SFD search hides it for Ethernet.
  - Periods under 4 clocks are not meaningful (`tmid` and `boundary` can coincide).
  - `LINE2[6]` (idle wait) counts at the NRZ sample point, which Manchester mode does not use:
    with LINE2[6] set a Manchester transmitter would never start. Untested; document or gate it.
  - A pulse shorter than half a clock (a_d == a_in != a_early) is not an edge.
  - `mcnt` saturates at the carrier-loss threshold; the bit timer is 24-bit signed: check
    `CLKDIV` near 0xFFFF (16 x 65536 + 8 eighths must fit: it does, 21 bits).
  - Jitter tolerance was measured with independent uniform per-edge jitter (`tb_line` M7: error
    free to ±0.8 clock, failures from ±0.9). Real 10BASE-T jitter is data dependent (ISI): a
    cable model (e.g. the 802.3 twisted-pair model) would be a better stimulus. Clock offset was
    tested to ±1 % (`tb_line`) and -0.5 % (`tb_eth`).
- **Targets:** golden model (`LineModel` mode 3, `a_early`; `top_model.py` negedge samples);
  `check_line_model.py` with mode 3; formal line block; coverage bins (early/late edges,
  boundary skips, carrier loss with and without SYNC); mutations (loop gain, threshold, the
  early offset of BUG-129, the polarity); stress (`verify/stress`: Manchester with jitter,
  glitches, clock error); a sigrok cross-check (libsigrokdecode has no 10BASE-T decoder; a
  decoder in Python from 7.3.1.1, or a VCD-to-pcap path through scapy/Wireshark).

## 3. CRC-32 (D91)

- **Spec:** `src/pbe_crc.sv` header, the register map (second page +8..+C), the `OSRCRC` text in
  `src/pbe_engine.sv`, the RevEng catalogue, 802.3 clause 3.2.9 (FCS bit order), D91.
- **To verify:**
  - Every catalogue CRC of 17-32 bits (`verify/vectors/crc` against RevEng/crccheck): CRC-17/21
    (CAN FD), CRC-24 (OpenPGP, BLE), all CRC-32 variants; reflected and not; the residue of each
    inverted one.
  - Bit-identity for widths up to 16 with `CRC_CFG2` = 0 (an equivalence proof against the old
    16-bit module would close it; `tb_crc` (c) is 12,000 random clocks).
  - `OSRCRC` bytes: B2/B3 only for widths over 16; for 16 or less param[3] is ignored (the
    golden model's random programs depend on it); `LEFT` with a wide CRC does nothing.
  - Registers: `CRC_POLY_2/3` writes, the reads of +8/+9 (the CRC value), `CRC_GOOD_2/3`,
    `CRC_CFG2`, reset 0, both engines.
  - The byte-mode feed at 32 bits (the 8-clock feed is unchanged).
- **Corner cases known:** a width change without `CRCRST` keeps the register (BUG-130); after a
  wide CRC the upper bits can be non-zero until `CRCRST`.
- **Targets:** golden model CRC to 32 bits, `crc_now` 32 bits (the differential compares it as
  an integer, unchanged for narrow CRCs); `make test-crc-vectors` extended to 32-bit entries;
  formal CRC properties at 32 bits; coverage of width bit 4.

## 4. 60 MHz (D92)

- **To verify:** the routed timing (`gds` was not run, by instruction): the logic estimate grew
  from 3.61 to about 4.6-4.8 ns (D92), and the new paths are the Manchester receive compare and the CRC
  width decode; the negedge synchronizer's half-cycle path; hold with the new negedge flops.
  Every protocol's timing at 60 MHz in the sigrok and vector cross-checks (the captures change).
  `bus_models` period (above).
- **Corner cases known:** WS2812 byte-boundary low phases (0.93 / 0.53 us) are 80 ns inside
  the datasheet window; I2C target setup 267 ns (standard mode 250 ns min); USB turnaround
  3.01-3.15 bit times.

## 5. 10BASE-T programs (D93)

- **Spec:** `programs/eth_tx.pbe`, `programs/eth_rx.pbe` headers (host protocols), the README
  section, IEEE 802.3 clauses 3 (frame), 4.4.2 (interframe gap), 14.2.1.1 (link test pulses,
  16 ± 8 ms), 14.3.1.2 (transmitter, TP_IDL, link pulse template), D93.
- **To verify:**
  - Transmit: preamble/SFD, FCS, bit timing, TP_IDL, the gap (measured 10.68 us; minimum
    9.6), link pulses only while idle and never within 10 us of a frame, frame sizes 60-1514
    bytes plus FCS and beyond (the program has no limit: jabber is the host's), chunk headers of
    every size 1..255, an empty frame (`[0]` alone), host underrun (status bit 4) and abort
    after 1 ms (bit 2), status bytes when engine 0's RX FIFO is full (bit 3, lost status).
  - Receive: escapes (0x7E twice), status codes, frames with dribble bits, frames shorter than
    the FCS, overruns at every byte position, back-to-back at exactly 9.6 us, clock offset and
    jitter together, link pulses and noise between frames, a frame starting during the
    handling of the previous one's status (the program's `fend` path is about 10 clocks).
  - Full duplex through one host port: the host's scheduling (`tb_eth`: 12-byte TX bursts,
    RX_COUNT + burst reads) at the line rate with the worst-case escape density (every byte
    0x7E doubles the RX traffic: 2.5 MB/s plus TX 1.25 MB/s, close to the port's 3.75 MB/s).
  - Against a real stack: frames captured from `tb_eth` into a pcap and checked by
    scapy/Wireshark (FCS, lengths); frames from a real capture played into the receiver.
- **Corner cases known / limits:** no CSMA/CD (the partner must be full duplex), no
  auto-negotiation, no receive polarity correction, no link-integrity timer; abort leaves the
  rest of the host's frame in the TX FIFO (the host must flush or resynchronize: `tb_eth` sends
  `[0][0]`); the NLP interval depends on `TIMEOUT` (60000 at 60 MHz).
- **Targets:** a protocol vector suite (`verify/vectors/protocols`) for Ethernet frames; stress
  (host jitter, long frames, partner clock error and jitter); coverage of the programs' paths
  (abort, escape, overrun); mutations of the programs (IFG count, the second `END`, the `STAT`
  at frame start, the escape).

## 6. If present: D94 (pbe_line stuffing control, HDLC NRZI) and multi-pin IN/OUT

See D94 in `docs/DESIGN_DECISIONS.md` for what was built or why not; the same pattern applies:
model, default equivalence, coverage, and the HDLC model (`test/hdlc_model.sv`) in NRZI.
