#!/usr/bin/env python3
"""Decode tb_debug's JTAG and SWD pins with sigrok's stock `jtag` and `swd` decoders (D77).

tb_debug runs its concurrent phase (+ONLY=both: jtag.pbe on engine 0 and swd.pbe on engine 1
at CLKDIV = 0, every scenario) with PBE_SIGROK, which dumps the pins and prints what the
testbench's host sent and received (SIGROK_JTAG, SIGROK_SWD lines). The pins are rewritten as
a six-signal VCD at 1 ns resolution and decoded by sigrok-cli; nothing in the decoders is
changed. The capture uses targets that drive TDO and SWDIO 20 ns after their clock edge
(PBE_TCO).

Known decoder limitation (expected failure): sigrok's swd decoder samples the target's bits
(ACK, read data, parity) at the falling edge of SWCLK. ADIv5 only requires them valid at the
host's sample point (before the next rising edge), and swd.pbe reads them 62.5 ns after the
rising edge at CLKDIV = 0. make test's targets drive 50 ns late, after the falling edge (the
high phase is 41.7 ns at 8 MHz), so on that capture the decoder reads every target bit one
cycle late. The second run checks that exact signature: the switch and the first request are
decoded right (the host's bits, sampled at rising edges) and the first ACK is ERROR (it read
1,1,0: the turnaround's pulled-up 1 and the first two ACK bits). The JTAG decoder samples TDO
at the rising edge, which the 50 ns target meets, so JTAG must pass on both captures.

JTAG: every IR and DR scan the decoder reports (TDI and TDO bit strings, from its own 16-state
TAP machine) must equal the scan the host made, in order.
SWD: the decoder's annotations must be exactly the expected sequence: LINERESET and JTAG->SWD
for the switch, then for every transaction its register name (computed here from APnDP, RnW
and A[3:2]), the ACK, the data for an OK, and the decoder's parity-error annotation (the
computed then the received parity bit) for the two transactions with a deliberate parity
error. No NOREPLY or ERROR may appear.
"""
import argparse
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PBE = ROOT / 'pbe_v1'
TEST = PBE / 'test'
BUILD = PBE / 'build/sigrok_debug'
SRC = [ROOT / 'src' / f'{n}.sv' for n in
       ('pbe_fifo', 'pbe_host_spi', 'pbe_crc', 'pbe_line', 'pbe_bsync', 'pbe_engine', 'tt_um_pbe')]
PINS = {'p0': 'tck', 'p1': 'tms', 'p2': 'tdi', 'p3': 'tdo', 'p4': 'swclk', 'p5': 'swdio'}


def rewrite_vcd(src, dest):
    """The bench's pins (ps timescale) as a 1 ns VCD with sigrok-friendly names. A released
    line is pulled up, so x and z read as 1."""
    lines = src.read_text().splitlines()
    ids = {}
    for line in lines:
        if line.startswith('$var'):
            f = line.split()
            if f[4] in PINS:
                ids[f[3]] = PINS[f[4]]
    sym = {n: chr(33 + i) for i, n in enumerate(PINS.values())}
    out = ['$timescale 1 ns $end', '$scope module top $end']
    out += [f'$var wire 1 {sym[n]} {n} $end' for n in PINS.values()]
    out += ['$upscope $end', '$enddefinitions $end']
    t = 0
    for line in lines:
        if line.startswith('#'):
            t = int(line[1:]) // 1000
        elif len(line) >= 2 and line[0] in '01xz' and line[1:] in ids:
            out += [f'#{t}', ('0' if line[0] == '0' else '1') + sym[ids[line[1:]]]]
    out.append(f'#{t + 1000}')
    dest.write_text('\n'.join(out) + '\n')


def sigrok(cli, vcd, stack, ann):
    res = subprocess.run([cli, '-i', str(vcd), '-I', 'vcd', '-P', stack, '-A', ann],
                         capture_output=True, text=True, check=True)
    return [l.split(': ', 1)[1] for l in res.stdout.splitlines() if ': ' in l]


def swd_name(ap, rw, addr):
    """The register names sigrok's swd decoder prints (ADIv5 DPv1 names, SELECT.DPBANKSEL = 0)."""
    if ap:
        return f'{rw} AP{addr:x}'
    if rw == 'R':
        return {0: 'IDCODE', 4: 'R CTRL/STAT', 8: 'RESEND', 0xC: 'RDBUFF'}[addr]
    return {0: 'W ABORT', 4: 'W CTRL/STAT', 8: 'W SELECT', 0xC: 'W RESERVED'}[addr]


def capture(tco):
    """Run tb_debug's concurrent phase with targets TCO ns late; return (stdout, the VCD)."""
    d = BUILD / f'tco{tco}'
    d.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(TEST / 'debug_image.hex', d / 'debug_image.hex')
    sim = d / 'debug.vvp'
    subprocess.run(['iverilog', '-g2012', '-DPBE_SIGROK', f'-DPBE_TCO={tco}.0', '-I', str(TEST), '-o', str(sim),
                    str(TEST / 'tb_debug.sv'), str(TEST / 'jtag_tap.sv'), str(TEST / 'swd_dp.sv')]
                   + [str(s) for s in SRC], check=True, capture_output=True)
    log = subprocess.run(['vvp', '-n', str(sim), '+ONLY=both'], cwd=d, capture_output=True, text=True)
    if 'PASS: debug ports' not in log.stdout:
        print(log.stdout[-2000:])
        sys.exit(f'FAIL: the testbench itself failed (TCO {tco} ns)')
    vcd = d / 'debug.vcd'
    rewrite_vcd(d / 'tb_debug_pins.vcd', vcd)
    return log.stdout, vcd


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--sigrok-cli', default='sigrok-cli')
    a = p.parse_args()
    if not shutil.which(a.sigrok_cli):
        sys.exit('ERROR: sigrok-cli is required; a missing tool is a failure, never a skipped pass.')
    BUILD.mkdir(parents=True, exist_ok=True)
    subprocess.run(['make', '-C', str(PBE), 'test/debug_image.hex'], check=True, capture_output=True)
    failures = check(a.sigrok_cli, *capture(20), 'TCO 20 ns')
    # make test's targets (50 ns): JTAG must pass, SWD must show the exact decoder limitation
    out, vcd = capture(50)
    failures += check(a.sigrok_cli, out, vcd, 'TCO 50 ns', jtag_only=True)
    got = sigrok(a.sigrok_cli, vcd, 'swd:swclk=swclk:swdio=swdio', 'swd')
    if got[:5] == ['LINERESET', 'JTAG->SWD', 'LINERESET', 'IDCODE', 'ERROR']:
        print('XFAIL swd, TCO 50 ns: known decoder limitation (target bits sampled at the falling '
              'edge, before a 50 ns target drives them): the first ACK decodes as ERROR, the '
              'switch and the request before it decode right')
    else:
        failures += 1
        print(f'FAIL swd, TCO 50 ns: expected the known signature, decoded {got[:6]}')
    sys.exit(1 if failures else 0)


def check(cli, stdout, vcd, label, jtag_only=False):

    jexp, sexp = [], []
    for line in stdout.splitlines():
        f = line.split()
        if f and f[0] == 'SIGROK_JTAG':
            jexp.append((f[1], int(f[2]), int(f[3], 16), int(f[4], 16)))
        elif f and f[0] == 'SIGROK_SWD':
            if f[1] == 'SWITCH':
                sexp += ['LINERESET', 'JTAG->SWD', 'LINERESET']
            elif f[1] == 'LINERESET':
                sexp.append('LINERESET')
            else:
                ap, rw, addr, ack, data, bad = f[1] == 'AP', f[2], int(f[3], 16), int(f[4], 16), f[5], int(f[6])
                sexp.append(swd_name(ap, rw, addr))
                sexp.append({0x20: 'OK', 0x40: 'WAIT', 0x80: 'FAULT'}[ack])
                if ack == 0x20:
                    d = int(data, 16)
                    sexp.append(f'0x{d:08x}')
                    if bad:
                        calc = bin(d).count('1') & 1
                        sexp.append(f'{calc}{1 - calc}')

    failures = 0
    # JTAG
    got = sigrok(cli, vcd, 'jtag:tdi=tdi:tdo=tdo:tck=tck:tms=tms', 'jtag=bitstrings-tdi:bitstrings-tdo')
    scans = []
    for i in range(0, len(got) - 1, 2):
        t, o = got[i], got[i + 1]   # "IR TDI: <bits> (0x..), n bits" then "IR TDO: ..."
        kind, bits_i = t.split()[0], t.split()[2]
        bits_o = o.split()[2]
        scans.append((kind, len(bits_i), int(bits_i, 2), int(bits_o, 2)))
    bad = [f'scan {i}: decoded {g}, host {e}' for i, (g, e) in enumerate(zip(scans, jexp)) if g != e]
    if len(scans) != len(jexp):
        bad.append(f'{len(scans)} scans decoded, {len(jexp)} made')
    if bad:
        failures += 1
        print(f'FAIL jtag, {label}:')
        for b in bad[:10]:
            print('  ' + (b if isinstance(b, str) else str(b)))
    else:
        print(f'PASS jtag, {label}: {len(scans)} IR/DR scans decoded by sigrok jtag (its own TAP state machine), '
              f'TDI and TDO bit strings equal the host\'s, 1 to 64 bits, one and two TAPs')
    if jtag_only:
        return failures
    # SWD
    got = sigrok(cli, vcd, 'swd:swclk=swclk:swdio=swdio', 'swd')
    bad = []
    for i, (g, e) in enumerate(zip(got, sexp)):
        if g != e:
            bad.append(f'annotation {i}: decoded {g!r}, expected {e!r}')
    if len(got) != len(sexp):
        bad.append(f'{len(got)} annotations decoded, {len(sexp)} expected')
    bad += [f'decoder reported {g}' for g in got if g in ('NOREPLY', 'ERROR')]
    if bad:
        failures += 1
        print(f'FAIL swd, {label}:')
        for b in bad[:10]:
            print('  ' + b)
    else:
        n = sum(1 for g in sexp if g in ('OK', 'WAIT', 'FAULT'))
        print(f'PASS swd, {label}: {len(got)} annotations from sigrok swd match: switch, line resets, {n} '
              f'transactions (register, ACK OK/WAIT/FAULT, data), 2 parity errors flagged where expected')
    return failures


if __name__ == '__main__':
    main()
