# Phase 2: independent stock sigrok waveform decoding

The verification code changes testbenches and tools only. No design RTL, protocol
program, generated netlist, GDS flow or gate-level workflow was changed or run.

## Run

With Icarus Verilog 12, Python 3 and sigrok-cli on PATH:

```sh
cd pbe_v1
python3 tools/sigrok_verify.py
# Reuse captures produced with -DPBE_SIGROK:
python3 tools/sigrok_verify.py --vcd-dir test --output /tmp/pbe-sigrok-valid
# Deliberately expose the stock USB request decoder's two disagreements:
python3 tools/sigrok_verify.py --vcd-dir test --output /tmp/pbe-sigrok-full --full-usb-request
python3 -m unittest discover -s test -p test_sigrok_extract.py
```

`--sigrok-cli /absolute/path/sigrok-cli` or `SIGROK_CLI` selects the decoder binary.
The normal command runs all three existing protocol benches, then all decoders.
Missing tools, decoder initialization failures, simulation failures and unexpected
decoded data return nonzero. No sigrok dependency is added to ordinary RTL tests.
The full-trace option returns nonzero on libsigrokdecode 0.5.3 because the two
known discrepancies are actual failed comparisons, not converted to passes.

Artifacts include the exact subprocess arguments, stdout/stderr, compact and
cropped VCDs, capture hashes, phase boundaries, tool versions and JSON comparison
results. The default output directory is `test/sigrok_results/`. The checked-in
`verification/evidence/phase2/` files are the dated execution receipt; fresh runs
produce their own artifacts. Waveforms remain generated artifacts.

## Capture and independence

`PBE_SIGROK` is off by default. It enables eight scalar external bus-pin wires
(`p0` through `p7`) and an integer test-phase marker in `tb_pbe.sv`, `tb_proto.sv`
and `tb_usb.sv`. The existing optional `+vcd` full-design dumps are preserved.
No internal engine state is passed to any decoder. The marker selects the
existing test's protocol interval; all bytes are interpreted by stock sigrok
protocol decoders rather than new Python protocol implementations.

The original captures have a 1 ps timebase. Expanding 262 ms of that data would
create about 262 billion samples. The extractor instead emits a 10 ns VCD
(100 MS/s), coalescing changes within a sample and preserving all relative timing
at that resolution. This is much finer than the fastest relevant protocol bit
(WS2812 1.25 us; USB low-speed about 667 ns; SPI peripheral 500 ns). It adds
1 us of the recorded pre-phase pin state and 100 us of final pin state to allow
start detection and end flushing. These pads do not alter relative timing within
the selected transfer. The exact extraction is recorded in `waveforms.json`.

VCD signal order at one timestamp is arbitrary. The extractor groups all updates
at a timestamp and takes its initial pin levels from the preceding timestamp.
`test_sigrok_extract.py` checks both marker-before-edge and edge-before-marker;
the earlier extractor lost the first USB SOP, and this regression fails with
that earlier initialization. See `crop_before_fix.txt` for the observed failure.

USB request decoding uses five independent valid windows: initial enumeration,
SET_ADDRESS, descriptor reads at the new address, configuration/vendor requests,
and enumeration after the reset. The full original USB capture is additionally
passed to `usb_packet` to check packet-level contents, including error injection
and retransmission. The optional full `usb_request` run documents its inability
to recover from malformed traffic and suppress duplicate retry data.

## Executed checks

Run on 2026-10-29. Both the scalar-capture simulations and the selected stock
decoder comparisons were executed; no result in the following table is inferred
from source review alone.

| Protocol / stock decoder | Comparison with original testbench | Result |
|---|---|---|
| UART / `uart` | Exact six bytes `55 a3 00 ff 0f 80`, 480000 baud, 8N1 | PASS |
| SPI controller / `spi` | MOSI `a5 5a 7e`, MISO `3c c3 81`, mode 0 | PASS |
| SPI peripheral / `spi` | Seven MOSI and seven MISO bytes across three transactions, including a pause and default `ff` replies | PASS |
| I2C controller / `i2c` | Exact pointer/write/read bytes, including repeated START and stretching waveform | PASS |
| I2C target / `i2c` | Exact 24 written data/pointer bytes and four read bytes, including another target's transfer on the shared bus | PASS |
| 1-Wire / `onewire_link,onewire_network` | Both ROM IDs; complete power-up and converted scratchpads; block and its inverted CRC16 bytes as contiguous decoded byte sequences | PASS |
| Modbus / `uart,modbus` | Normal round at 19200 baud, 8E1: exact eight request/nine response bytes and both stock decoder CRC16 checks | PASS |
| WS2812 / `rgb_led_ws281x` | Exact ten RGB annotations corresponding to two five-LED GRB frames | PASS |
| USB / `usb_signalling,usb_packet,usb_request` | Ten valid-window control requests: exact setup, reassembled data, ACK/STALL, including address change, configuration, vendor read/write and reset | PASS |
| USB / `usb_packet` on full waveform | SET_ADDRESS and vendor payload; identical repeated DATA1; bad CRC5 and CRC16 injected by the original bench | PASS |
| USB / `usb_request` on full waveform | SET_ADDRESS recovery after malformed packets; retry de-duplication | Two decoder disagreements, preserved as strict failures |

The primary decoder run has **22/22 comparison checks passing**. The optional
full-trace request run has **22/24 passing**, with the two failures below. Each
of `tb_pbe`, `tb_proto` and `tb_usb` independently printed `PASS` while capturing.
The normal command is a separate, longer verification job and is not included in
the short default differential smoke test.

## Decoder disagreements, with reproduction

These are limitations observed in the unchanged third-party libsigrokdecode
0.5.3 `usb_request` decoder, not established RTL bugs. The lower packet layer
recovers the actual bytes, the isolated valid requests decode correctly, and the
existing pin-level USB bench passes. No third-party decoder was patched.

1. **Missing SET_ADDRESS after malformed traffic.** Following the intentionally
   corrupt SETUP/data packets, the request decoder stays in `DATA RECEIVED`.
   It prints `ERR: received SETUP token in state DATA RECEIVED` and omits the
   `00 05 15 00 00 00 00 00` request. `usb_packet` decodes that setup payload and
   an isolated valid window reconstructs the control request correctly. The
   full request decoder code only times out a pending `TOKEN RECEIVED` state,
   leaving `DATA RECEIVED` unable to recover when the handshake never came.

2. **Descriptor data counted twice after a lost ACK.** The original bench loses
   the ACK for the first eight descriptor bytes. The device repeats the same
   DATA1, then sends DATA0 and the final DATA1. The request decoder's assembled
   descriptor contains 26 bytes rather than 18: it appends the first eight-byte
   DATA1 twice. At the packet layer the two packets are correctly identical.
   The request decoder appends IN transfer data without tracking duplicate
   PID/toggle and acknowledgment history.

Reproduce both with `--full-usb-request`; the JSON records expected lengths
`[18, 18]` and actual `[18, 26]`, and the missing SET_ADDRESS bytes. This strict
command must remain failing until the relevant external decoder version is
changed and its behavior is independently verified.

## Tools and environment

- Icarus Verilog compiler/runtime **12.0 stable**.
- Python **3.10.12** for extraction/comparisons; no Python package required.
- sigrok-cli **0.7.2**.
- libsigrok **0.5.2**; libsigrokdecode **0.5.3** (embedded Python 3.10).
- Ubuntu package versions: `sigrok-cli 0.7.2-1`, `libsigrok4 0.5.2-3build1`,
  `libsigrokdecode4 0.5.3-2ubuntu1`, `libserialport0 0.1.1-4`,
  `libhidapi-hidraw0 0.11.2-1`.

For this run the package files were downloaded and extracted under `/tmp`; no
system installation occurred. sigrok's libusb backend initializes even for VCD
input; the restricted sandbox rejects that initialization. The offline decoder
commands were therefore run with sandbox escalation. The tool may exit zero
while printing only `libusb_init() returned LIBUSB_ERROR_OTHER`; the script
explicitly requires a real version response and nonempty decoder output, so
that environment failure cannot become a pass.

## Boundaries and next steps

This is digital RTL simulation and independent digital protocol interpretation.
It does not prove pad electrical behavior, analog timing, routed 48 MHz closure,
physical hardware function or exhaustive protocol conformance. The stock 1-Wire
network decoder does not verify ROM CRC itself; the compared byte sequences
include the known expected CRC bytes, while existing bench/CRC-unit tests provide
separate checks. Modbus external decoding currently selects the normal 19200-baud
round; original benches still exercise the error and higher-baud rounds.

Next extend the independent decoder jobs to every Modbus baud/parity/error phase,
assert I2C ACK/NACK/address event ordering, and expand packet-level USB transaction
checks around each malformed scenario. Formal FIFO/host-SPI/line-coder proofs,
CRC catalogue vectors and Verilator coverage complement these checks.
