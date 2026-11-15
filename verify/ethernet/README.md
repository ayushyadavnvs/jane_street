# D89–D94 independent verification

See [round 3](../golden-model/REPORT.md#round-3--d89d94-ethernet-verification) for actual
results, bounds, source lineage and open defects. The only RTL repair is the documented
Manchester LINE2 idle-wait exception. **The ±13.5-ns receiver jitter defect remains open.**

Install `requirements.txt` into the repository virtual environment. Use Icarus/vvp 12 for
four-state checks and OSS CAD Suite 2026-07-27 / Verilator 5.051 for compiled campaigns.
No target downloads dependencies or invokes a physical/gate-level workflow.

From `pbe_v1/`:

```sh
make test-ethernet-corners  # public host pins, per-clock reference, three directed tests
make test-wire-vectors     # Scapy/binascii Ethernet, independent HDLC codecs; Verilator
make coverage-ethernet     # old bins plus new modes; reports structural/functional gaps
make mutate-ethernet       # 14 single-site hardware/program faults; isolated snapshots
make stress-ethernet       # currently NONZERO for required jitter failures
```

From repository root:

```sh
.venv/bin/python verify/ethernet/run_line_corners.py
.venv/bin/python verify/ethernet/run_wire.py --sim verilator --test-module test_program_corners
.venv/bin/python verify/ethernet/run_wire.py --test-module test_jitter_reproducer
.venv/bin/python verify/ethernet/run_wire.py --sim verilator --test-module test_jitter_reproducer
```

The last two commands are expected to fail with `BUG-151`: a minimum 60-byte Ethernet
frame at -100 ppm and spacing-dependent ±13500-ps edge jitter delivers only 30 bytes/status 0.
Do not change the recovery loop simply to make this test pass. The spacing-dependent
stimulus is a digital ISI proxy; it supplies no analog cable/equalizer compliance claim.

`pin_top.sv` connects only chip pins. `pin_driver.py` loads/configures ordinary Ethernet
or HDLC programs through the public quad port and decodes the escaped host records.
`wire_codecs.py` imports Scapy and crccheck, and uses binascii CRC-32; it imports no PBE
model or RTL-derived state. Its transmitter decoder samples half-cell centers, not the
DUT's clock-recovery algorithm. The directed architectural tests additionally use the
independent cycle oracle; they are separately identified in the report.

Each wire module has its own `pbe_v1/build/<module-without-test_>/<sim>/` directory, with
input hashes, cocotb XML and observations. Full vector runs also save actual decoded pcap
packets. Stress stores seeds, ideal/relative clock offsets, actual received records and
compressed failing stimulus copies in round-3 evidence. A failure must not overwrite a
successful vector run's receipt. Coverage uses explicitly supplied instrumented sources and
requires a fresh nonempty data file. Simulator exit status remains meaningful.

Normal host jitter keeps every SCK half-phase at least four chip clocks; no faster SCK claim
is made. Error-report contracts and successful payload delivery are separate observations.
Worst-case full-duplex escaping can exceed usable host bandwidth after command overhead.

`tb_manchester_idle_wait.sv`, `tb_timeout_boundary.sv` and `tb_parity_boundary.sv` are small
external-interface regressions included near the beginning of normal `make test`.
