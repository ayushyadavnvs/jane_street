# Round 2 independent USB and Modbus vectors

Verification-only extension: existing protocol programs and RTL behavior are
unchanged. Optional `PBE_PROTOCOL_REFERENCE` includes select generated tasks in
`tb_usb.sv` and `tb_pbe.sv`; default `make test` continues using the original
scenarios. No synthesis, physical-design or gate-level flow runs here.

## Reference sources and independence

[Great Scott Gadgets LUNA packet helpers](https://github.com/greatscottgadgets/luna/blob/main/luna/gateware/test/contrib/usb_packet.py)
provide `token_packet`, `data_packet` and `handshake_packet`, including PID,
CRC5 and CRC16 generation. The pinned package is `luna-usb==0.2.3`. Its packet
helpers originate in the independent ValentyUSB test infrastructure. The
[USB protocol library](https://github.com/greatscottgadgets/python-usb-protocol),
`usb-protocol==0.9.2`, additionally validates PID complement nibbles. It has no
raw token/data CRC encoder in that release, which is why LUNA's helpers are used.
No encoder source is copied into the PBE repository.

[PyModbus's RTU framer](https://github.com/pymodbus-dev/pymodbus/blob/v3.11.3/pymodbus/framer/rtu.py),
`pymodbus==3.11.3`, builds complete request and response ADUs from
`ReadHoldingRegistersRequest`/`ReadHoldingRegistersResponse` using `buildFrame`.
The external framer computes wire-order CRC bytes. Actual captured DUT frames are
also fed to `FramerRTU.decode`, with the appropriate client/server decoder.

The local adapter converts LUNA's LSB-first bit strings to byte literals, generates
SV stimulus/check tasks and launches Icarus. It contains no CRC algorithm or
second PBE ISA model. The bytes are serialized through the existing `tb_usb`
`hs_send` bus model and `tb_pbe` Modbus peer, and device replies are decoded by
those existing wire monitors. Expected packets and CRC bytes come from the
external libraries, rather than the monitors' CRC functions. This is independent
packet-content checking, with the original bus serializer/receiver and device
firmware models retained as a stated evidence boundary.

## USB scenarios

A generated bank contains 19 distinct packet vectors: SETUP/IN/OUT tokens, a valid
token addressed elsewhere, a deliberately flipped CRC5 token, ACK/NAK/STALL
handshakes, setup/data packets, a deliberately flipped CRC16 packet, descriptor
chunks, zero-length DATA1, seven vendor bytes and their returned payload. The
seeded vendor payload begins `ff ff` to force stuffing in the existing serializer.

The library-generated packets are fed into the device and check:

- Correct-address SETUP/DATA0 acknowledged; wrong-address and bad-CRC5 tokens
  produce no response; corrupt DATA0 produces no ACK and one bad firmware record.
- Device descriptor returned as DATA1(8 bytes), DATA0(8 bytes), DATA1(2 bytes),
  including exact packet CRC16 bytes, with host ACKs and OUT status.
- Vendor OUT of seven bytes, status IN zero-length DATA1, vendor IN of the reversed
  bytes plus `55`, and status OUT. All data/handshake packets compare exactly.
- Unsupported descriptor request acknowledged at SETUP and then STALL on IN.
- Bus contention remains zero; response stuffing monitor reports no errors;
  response turnaround remains within the bench's USB 1.1 bounds of 2–7.5 bit times.

Thirteen final DUT responses are compared in their expected order. Any interim
NAKs while firmware queues a reply are retried using the same independent IN
packet; every sent raw packet and received final response is retained in the log.
The NAK vector exists in the library bank; no host NAK transmission is claimed.
This finite packet test does not establish exhaustive USB conformance, analog
pad behavior, or hardware operation.

## Modbus scenarios

Seven request/response cases run the existing `modbus_rtu.pbe` program, which
transmits each request using its hardware CRC and parity and samples the peer
response. The first case matches the existing known frames:

```text
request:  01 03 00 00 00 02 c4 0b
response: 01 03 04 12 34 56 78 81 07
```

Remaining cases have seeded device IDs, register addresses, register counts of
1–3 and register values. Settings include 19,200/115,200 baud, 8E1 and 8N2. The
complete raw request (including DUT-generated CRC) must match PyModbus's ADU.
Responses must match byte-for-byte, with correct engine parity/CRC status and
peer checks for stop bits and RS-485 driver ownership. Request inter-character
gaps must remain within 1.5 characters.

A deliberately corrupt response CRC must clear the engine CRC-good status and be
rejected by PyModbus. A two-character gap after the fourth response byte must set
the program's invalid-frame flag and report only the first four bytes; the partial
ADU is also rejected by the external framer. The framer has no electrical-time
input: the gap check comes from the real simulated wire interval and the PBE
program's reported status, rather than a claim that PyModbus validates UART timing.

## BUG-065: verification harness bring-up fixes

No RTL defect was found in these protocol tests. Two local harness mistakes were
caught before accepting the results:

1. Before: `if len(actual) != 14: raise RuntimeError(...)` rejected a passing USB
   simulation because the directed scenario has 13 final responses. After: compare
   captured response IDs to the complete expected sequence generated alongside
   the stimulus, then compare each complete packet. The expectation is generated
   from the planned scenarios, never from DUT output. The former script exits 1
   with `USB expected14 captured responses, got13`; the corrected run passes.
2. Before: generated SV used `mb_par[i][0]` and
   `mb_par[mb_par.size()-1][1]`. Icarus 12 rejects this variable queue-index plus
   bit-select combination with 20 elaboration errors. After: assign the queue
   element to `mb_x` first, then inspect `mb_x[0]`/`mb_x[1]`, as the existing bench
   does. The same library vectors now compile and run. This is a simulator-facing
   test adaptation, with no change to packet bytes or hardware behavior.

Reproduced before-fix scripts were kept under `/tmp`, never in the committed RTL.
Their nonzero exits and exact compiler errors are in
`evidence/round2/vectors/protocol_bug065_before_*`; the passing run and generated
reference tasks are retained beside them.

## Run and evidence

Install `test/reference_protocols/requirements.txt`, then from `pbe_v1/` run:

```sh
../.venv/bin/python test/reference_protocols/run.py --seed 0x50424532
# The integration Makefile target invokes the same runner:
make test-protocol-vectors
```

`--protocol usb` or `--protocol modbus` selects one job. Each seed is reproducible.
Generated files, source hashes, tool versions and exact commands live in
`build/reference_protocols/`; selected receipts are checked in under
`verification/evidence/round2/vectors/protocol*`. Missing tools, compilation or
simulation errors, missing PASS markers and unexpected captured frames return
nonzero. The target installs nothing and is separate from the short default gate.

Final seed `0x50424532`: **USB PASS, 38 host packets, 13 final device responses,
2.009 s; Modbus PASS, seven cases, 43.096 s**. The second USB seed `0x50424533`
also passed with 38 host packets and 13 responses in 2.188 s. Exact timings and
packet contents are in the checked-in `protocol_results.json` and
`protocol_second_seed_results.json`. Python 3.10.12 and Icarus/vvp 12.0 stable
were used. These are wall-clock simulation run times; compilation is additional.

Next: extend independently generated USB addresses/endpoints, data lengths and
lost-ACK cases; add Modbus functions beyond holding-register reads and exception
responses; compare additional wire captures with stock decoders; stress clock
error/jitter separately from these packet-content vectors.
