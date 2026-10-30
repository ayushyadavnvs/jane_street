# Independent USB and Modbus protocol vectors

Install `requirements.txt` into the verification virtualenv explicitly. From
`pbe_v1/`, with Icarus/vvp on PATH:

```sh
../.venv/bin/python ../verify/vectors/protocols/run.py
../.venv/bin/python ../verify/vectors/protocols/run.py --seed 0x50424533
../.venv/bin/python ../verify/vectors/protocols/run.py --protocol usb
../.venv/bin/python ../verify/vectors/protocols/run.py --protocol modbus
```

The runner builds optional verification tasks into the existing `tb_usb.sv` and
`tb_pbe.sv` with `PBE_PROTOCOL_REFERENCE`. Normal benches do not enable that define.
Generated `.svh` includes, simulator executables, packet manifests, exact commands
and stdout/stderr live under `build/reference_protocols/` by default. A failure,
missing dependency, missing PASS marker or mismatch exits nonzero.

USB packet bytes come from Great Scott Gadgets' LUNA test packet encoders, with
USB protocol PID validation. Modbus request and response frames come from
`pymodbus.framer.rtu.FramerRTU.buildFrame`. The unmodified programs run through the
chip pins; the checked-in PBE Python model is not used. The existing bus serializers
and host-port firmware models remain part of the test environment.

The report, coverage and limits are in `../../golden-model/ROUND2_PROTOCOL_VECTORS.md`.
This target does not run synthesis, physical design or gate-level simulation.
