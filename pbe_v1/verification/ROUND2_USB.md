# Round 2 USB decoder audit — 2026-10-29

Scope: verification tooling only. No PBE RTL behavior, protocol program, installed
sigrok source or workflow changed. These findings characterize the external
request decoder; they do not establish complete USB conformance of the PBE.

## Primary specification and decoder configuration

Reviewed the original **Universal Serial Bus Specification, Revision 1.1,
September 23, 1998**, chapters 7 and 8, obtained from the
[ALSA mirror of the original specification](https://www.alsa-project.org/files/pub/manuals/usb/usb11.pdf).
This is the USB specification itself, not an explanatory article. The
[IEEE archive provenance](https://ieeemilestones.ethw.org/File%3AUsb11.pdf)
independently identifies its copy as downloaded from USB-IF in 2007. Legacy
usb.org and Bitsavers fetches returned 403 in this environment. The successfully
downloaded specification is 2,021,447 bytes, SHA256
`eb7632510f087e6b57f212e456f8377d6747901cb6d30a7d6baae4d193ecbaba`.
It is not redistributed in this repository.

Specification rules used here, paraphrased:

- Chapter7, Table 7-1 and sections 7.1.8–10: low-speed J is D+ = 0, D- = 1;
  K is the inverse. Data rate is 1.5 Mb/s. NRZI toggles for zero; stuffing inserts
  zero after six ones; sync precedes packet fields; EOP includes SE0 then J.
- Sections 8.7.1–2: corrupt packets are discarded without acknowledgment.
  The timeout covers both token/data and data/handshake boundaries. A device
  times out after 16–18 bit times; the host waits at least 18 before its next token.
- Section 8.6.4 and Figure 8-18: missing/corrupt ACK causes identical data/PID
  retransmission; the receiver discards duplicate data and acknowledges it.

Exact stock stack now pinned in `tools/sigrok_verify.py`:

```text
usb_signalling:dp=p1:dm=p0:signalling=low-speed,usb_packet:signalling=low-speed,usb_request:in_request_start=submit
```

The captured bus is the low-speed device-side segment: p1=D+, p0=D-. Both
physical and packet layers require explicit low-speed options; packet decoder's
default is full-speed. `usb_request` has one option, `in_request_start`, which
controls request/PCAP start timestamps. Both `submit` and `first-ack` were tried;
neither resolves BUG-050 or BUG-051. The latter introduces another stock error,
BUG-062, discussed below. Tool versions: sigrok-cli 0.7.2, libsigrok 0.5.2,
libsigrokdecode 0.5.3; exact decoder hashes and specification metadata are in
`evidence/round2/usb/sources.json`.

## BUG-050: malformed packet leaves the request state stuck

This is an external request-decoder defect, not a low-speed option mismatch or
missing SOP in the extraction. The full packet layer reconstructs SET_ADDRESS;
the isolated clean waveform reconstructs the request. Independently of any PBE
waveform, `tools/usb_decoder_repro.py` passes a SETUP/DATA0 with no handshake,
waits 100 us (well beyond 18 low-speed bits), and then passes a valid SET_ADDRESS.
Stock `decode()` rejects the new SETUP in `DATA RECEIVED`.

Source root cause, unchanged stock `usb_request/pd.py` lines 332–349: timeout
recovery is entered only in `TOKEN RECEIVED`; every other non-IDLE state rejects
the next token. Additionally stock `usb_packet` emits its packet summary even
when separately reporting a CRC error; `usb_request` consumes that packet summary
without inspecting the CRC value. Corrupt data therefore reaches `DATA RECEIVED`,
where no timeout exists. No RTL or external decoder fix is claimed.

## BUG-051: lost ACK, intervening NAK, then successful retry duplicates bytes

The packet-input reproduction makes the causal chain explicit:

1. Valid GET_DESCRIPTOR SETUP, then IN/DATA1(first 8 bytes), without host ACK.
2. After timeout, another IN is rejected while state remains `DATA RECEIVED`.
3. The endpoint NAK while requeuing is incorrectly associated with the previous
   DATA1. `handle_transfer()` appends that stale data even with handshake NAK.
4. A subsequent acknowledged IN/DATA1 appends the same 8 bytes again. DATA0 (8 bytes),
   DATA1 (2 bytes) and status then finish an incorrectly assembled 26-byte descriptor.

Thus the earlier description "no toggle de-duplication" was incomplete: the
missing data/handshake timeout loses transaction association, and unconditional
control-IN append makes the stale NAK completion visible as duplicated bytes.
The relevant unchanged stock code is `request['data'] += self.transaction_data`
in the `SETUP IN`/`IN` branch (lines 240–241), without an ACK condition or PID
history. The decoder does not store the received data PID in `decode()`.
Both option values reproduce 26 instead of 18. The full pin capture separately
shows identical DATA1 retries and the valid-window control requests remain exact.

## BUG-062: first-ack option raises TypeError but sigrok exits 0

On the full capture, `in_request_start=first-ack` reaches an empty BULK-IN timeout.
The request initializes `ss_data=None`; because no data arrived it remains None.
`handle_request()` passes it as the annotation's start sample. Native sigrok
rejects that value with `TypeError: argument 1 must be int, not None`, prints a
traceback, continues with partial annotations, and exits 0. The packet-input
reproducer contains the minimal empty IN/NAK, then IN/timeout sequence. Its API
stub enforces the same integer-sample requirement; `submit` succeeds and
`first-ack` reproduces the exception.

Before, `Checks.decode()` required nonempty stdout and exit0, which could accept
partial output after a decoder exception. After, it also rejects stderr traceback
or `Calling ... decode() failed`, returning an error. The regression
`DecoderExitStatus.test_nonempty_stdout_and_exit_zero_do_not_hide_decoder_exception`
fails before that guard and passes after. Installed stock source remains unchanged.
Exact native command/stdout/stderr are in `first_ack_full.*` under the evidence
folder. This new finding is separate from the two expected request mismatches.

## Expected failures without hiding new failures

The default sigrok run now always executes the full request trace. It labels only
these two exact stock 0.5.3 signatures **XFAIL**, including their reasons in JSON:

- SET_ADDRESS count 0 instead of 1, with the specific SETUP/DATA-RECEIVED error.
- Descriptor lengths [18, 26] instead of [18, 18], with the specific IN/DATA-RECEIVED error.

A different decoder version, changed actual values, missing error signature,
exception, missing tool or primary comparison failure remains a failure. If the
specification comparison begins passing, its result is PASS. XFAIL is not counted
as PASS. `--full-usb-request`/`make sigrok-full` retains strict behavior and exits 1
on the two disagreements. No malformed waveform is rewritten to placate a decoder.

## Reproduction and evidence

From `pbe_v1/`, with the reported tools available:

```sh
make sigrok SIGROK_CLI=/path/to/sigrok-cli
make sigrok-full SIGROK_CLI=/path/to/sigrok-cli  # deliberately exits 1 on stock 0.5.3
python3 tools/usb_decoder_repro.py --decoder /path/to/decoders/usb_request/pd.py
SIGROKDECODE_DIR=/path/to/decoders python3 -m unittest discover -s test -p test_sigrok_extract.py -v
```

The packet-input reproducer calls the actual unmodified stock class with a tiny
output API stub. It has no PBE source dependency, NRZI encoder or waveform cropper;
it isolates request-layer state handling. This deliberately complements rather
than replaces stock pin-level decoding. Without installed decoder source the
optional stock-reproduction unit test is explicitly skipped; `make sigrok` itself
requires the tool and fails if missing.

Recorded reuse-capture run: **22 PASS, 2 XFAIL, 0 unexpected failures, exit 0**.
Strict run: **22 PASS, 2 FAIL, exit 1**. Five extraction/classification/exception/
stock-reproduction unit tests pass with the source installed; the stock test
covers six cases across both request-option values. Receipts and raw USB output
are under `verification/evidence/round2/usb/`. Fresh complete `make sigrok` (all three benches recompiled and simulated) also
passed: **22 PASS, 2 XFAIL, 0 unexpected failures, exit 0**. The fresh USB bench
measured response turnaround of 3.00–3.19 bit times and reported PASS; its receipt
and exact fresh waveform hashes are included. No physical flow was run.
