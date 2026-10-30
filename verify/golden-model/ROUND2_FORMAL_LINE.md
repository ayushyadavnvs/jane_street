# Round 2 line-coder bounded verification

Source baseline is phase 0 commit `6130fa7`; no behavioral RTL is changed. The
prepared file in `build/formal/generated/line_formal.sv` copies the original
transition logic and adds parameter-controlled observation-only assertions.
`verify/formal/line_prepare.py` is the only source-preparation step; the design files
are never overwritten or instrumented in place.

Run from `pbe_v1/` with the formal tools on PATH:

```sh
python3 ../verify/formal/line_prepare.py
python3 ../verify/formal/line_run.py --jobs 2
```

For one named task, from `verify/formal/`:

```sh
sby -f -d ../../pbe_v1/build/formal/line_one line.sby rt_nrzi_s1_pair_byte_lsb
sby -f -d ../../pbe_v1/build/formal/line_counterexample line.sby original_period0
```

There is one SBY file for this block. Its tasks encode all 32 functional
combinations of 2 encodings, 4 stuffing choices, 2 wiring choices and 2 transfer
widths. Both shift orders produce 64 bounded round-trip cases. This is **BMC,
not an inductive or unbounded proof**. The engine is `smtbmc yices` using Yosys
formal, async-reset conversion and DFF unmapping. Verified tool versions: Yosys 0.67+94
(`7defa5186-dirty`), SBY v0.67-4-gfea6e46 and Yices 2.7.0. Tool versions and aggregate
phase 1 commands are also recorded in the central report/design decision.

## Checked contract and assumptions

Every bounded round-trip instance sends two arbitrary symbolic bytes, or 16
symbolic bit transfers, under the same 16-bit payload. The payload is `anyconst`,
so the solver quantifies over every allowed payload rather than one sampled
vector. The source obeys tx_ready, queues a single END, and the sink consumes
rx_valid immediately. NRZ/NRZI and all four stuffing modes are covered. Both
ends share shift direction, configuration and a four-clock bit period
(period_m1=3). This is not a proof over all divider values, clock errors,
inter-byte gaps or live configuration changes.

The sync byte is nonzero and chosen so its transmitted bits are 00000001 for
both shift orders. This begins with a detectable start, and the receiver does
not confuse idle-leading payload bits with absence of a frame. It is not a
universal assertion about arbitrary/no sync values.

- All 32 pair-mode instances quantify over unrestricted 16-bit payload and assert
  exact output count, byte/bit equality, no TX/RX err and successful END/release.
- The 24 stuffed single-line instances quantify over unrestricted payload, but
  check the first requested payload units; termination can generate idle suffix
  samples. Those samples are consumed and discarded. This is a **payload-prefix
  contract**, not exact-length frame delivery.
- The 8 unstuffed single-line instances additionally require every fourth
  payload bit to be 0 (positions 3,7,11,15). This excludes the documented
  eight-idle-high EOF pattern. It is an explicitly restricted subset, not an
  assertion that arbitrary unstuffed single-wire bytes round-trip.

Assertions check every observed payload transfer, absence of errors each clock,
and completion with nonzero traffic at cycle 160. BMC depth 164 includes that
deadline. It covers the 24 wire bits (sync+16 payload), inserted stuff bits,
two-bit initial gap and pair EOP/release. The assumption presatisfiability
check is active at each step, and no assumption uses DUT receive/data/error
outputs to force success. The fixed completion assertion prevents a vacuous
pass with no data sent or received.

## Stuff-error semantics

Twelve additional BMC tasks cover NRZ/NRZI × three enabled stuffing modes ×
pair/single wiring. They drive independent `anyseq` synchronized line levels at
every clock, with no producer framing assumption, and check depth 48:

```text
active receiver, sample due, not SE0, stuff bit expected, wrong decoded bit
    => next registered err
except single-wire a_in=1
    => next registered frame_end
```

The exception is explicitly in the original line header: an idle-level stuffing
violation terminates a single-wire frame. It is not an error to be fixed in RTL.
Observation assertions are injected within the copied module because they need
to identify an actual decoded stuff slot. They do not duplicate the transmit
or receive transition logic. Twelve separate cover tasks establish reachability
of a violation followed by the applicable err/frame_end response. Six retained
original-error counterexamples establish the idle-termination exception for
each single-wire mode. Stuffing-off has no expected stuff slot and is covered
by round-trip tasks rather than a vacuous stuff-error property.

This local reaction property uses the DUT's definition of an expected stuff
slot; it does not independently prove that the slot count is correct. Likewise,
two instances with the same encoder/decoder defect could agree in a round trip.
The separate known-wire-bit checks, mutation campaign and external protocol
decoders provide complementary independence. No claim of independent stuffing
conformance is inferred solely from these composition checks.

## Original stronger claims remain executable

The unconditional requests are retained as named tasks with `expect fail`.
SBY's outer exit 0 means an expected outcome was matched; the receipt explicitly
records the underlying formal status **FAIL** and its trace, never a proof.

| Task(s) | Stronger claim deliberately checked | Counterexample boundary |
|---|---|---|
| original_period0 | arbitrary pair-mode bytes received with one-clock bit time | RX counter never reaches midpoint comparison 1 while period_m1=0 keeps count 0. |
| original_no_sync | arbitrary pair-mode bytes with no sync | All-one NRZ payload never leaves idle-high, so no payload is received. |
| original_single_idle | arbitrary single-line bytes with no idle-run restriction | All-one payload reaches the documented idle-high EOF condition. |
| original_single_bit_suffix | single-line bits produce exactly the requested count | Payload prefix may be correct while idle termination produces additional 1 samples. |
| original_stuff_nrz_s1/s2/s3 and nrzi counterparts | every decoded stuffing violation must raise err | Single-wire idle-high violation correctly produces frame_end with no err. |

`line_run.py` treats unexpected PASS, missing status, timeout, tool failure or
unexpected counterexample as a failure. The selected JSON includes each task,
depth, actual/expected status, return code, elapsed time and failed property
location. Counterexample VCDs are copied to the evidence directory; complete
solver logs/intermediate files remain in ignored `build/formal/`.

## BUG-066: receive-rate contract omission

The original pre-audit header advertised a bit every period_m1+1 clocks and
mid-bit reception without stating an RX lower limit. At period_m1=0, rcnt
remains 0 while the midpoint comparator expects 1, so RX never samples a bit.
The phase 0 header clarification already states this explicitly; the formal
original_period0 task supplies a reproducible counterexample to the stronger
all-period receive claim. No behavioral RTL fix is proposed. The period 3
conditional tasks provide bounded evidence for the documented verification
setting, not a proof that every nonzero period works.

The saved witness for `original_period0` has payload 0x0000, sent=2,
received=0, END queued and drive released. After reset, the RX counter and
sample signal are both 0 on every recorded step. The completion assertion
fails at formal step 161, after the cycle-160 deadline. This is an actual
missing-reception counterexample, not a simulator or timeout failure.

## BUG-068: impossible cover goals in the verification observer

The first complete pilot passed all 64 payload cases and all 12 reaction BMC
cases, but eight cover jobs failed because the monitor asked for impossible
events. The before code was:

```systemverilog
cover(f_saw_violation && err);
if (!pair) cover(f_saw_idle_end && frame_end);
```

Pair mode retained a disabled cover cell that could never be reached. For NRZ
single-wire ones-style stuffing, a wrong stuff bit is necessarily 1: this is
the documented idle-high frame-end condition, so err-only is also impossible.
The corrected monitor covers the actual applicable response:

```systemverilog
cover(f_saw_violation && (err || (!pair && frame_end)));
```

The functional assertions are unchanged and still check err versus frame_end
according to the sampled condition. The original unconditional err assertion
remains an expected failure in six tasks. This changes only verification
observations, never the circuit. For example,
`cover_stuff_nrz_s1_pair` and `cover_stuff_nrz_s1_single` both failed before
and pass after. `line_cover_pilot_results.json` retains all eight original
failures, and all 98 jobs were rerun against the final observer source.

## Results

The completed final campaign matches **98/98 expected outcomes**:

| Kind | Count | Actual status | Bound |
|---|---:|---|---:|
| Framed payload round trips, assumptions above | 64 | PASS | 164 clocks |
| Stuff-violation reaction assertions | 12 | PASS | 48 clocks |
| Reachable stuff-violation response covers | 12 | PASS | 48 clocks |
| Retained stronger unconditional claims | 10 | FAIL, expected | 48 or 164 clocks |

There are 76 passing bounded-assertion jobs, 12 reached cover jobs, 10 explicit
counterexamples and **zero unbounded proofs** for this block. The final
`line_results.json` contains the task/status/depth/source hashes and observed
run times. The general runner also collected every job successfully with:

```sh
python3 ../verify/formal/run.py --block line --collect --jobs 3
```

That collection compared each expanded SBY configuration and copied input
file against the current checkout; all 98 matched. This rules out reusing
stale pre-fix observer or pilot results as final evidence.

Counterexample details are in `line_counterexample_summary.json` and the ten
`line_original_*.vcd` witnesses alongside the final receipt:

| Original claim | First failed formal step |
|---|---:|
| period0 receive, no-sync all-ones, single-line idle-high payload | 161 each |
| single-line exact-length bit delivery | 125 |
| NRZ/NRZI six-ones stuffing must always error | 27 each |
| NRZ five-ones/equal and NRZI five-ones stuffing must always error | 23 each |
| NRZI equal-bit stuffing must always error | 22 |

These are requested-property/specification-boundary counterexamples, not new
behavioral RTL fixes. The bounds and framing restrictions remain material:
passing this matrix does not establish all-rate, arbitrary-sync, exact-length
single-wire or indefinitely long frame correctness.
