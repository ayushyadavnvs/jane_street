#!/usr/bin/env python3
"""Decode the pins of the protocols added in D84-D88 with sigrok's stock decoders.

Each testbench, built with PBE_SIGROK, dumps its pins to a VCD and prints what its host sent and
received (SIGROK_<PROTO> lines). The pins are rewritten as a 1 ns VCD and decoded by sigrok-cli;
nothing in the decoders is changed. A missing sigrok-cli is a failure, never a skipped pass.

  ps2      tb_ps2 (ps2_host.pbe): sigrok `ps2` samples DATA at every falling CLK edge. Known
           decoder limitation (libsigrokdecode 0.5.3): it stores a bit before testing its count,
           so a word completes on the 12th falling edge, not the 11th; between device bytes it
           takes the next byte's start bit as the 12th and loses the framing. The capture is given
           one extra CLK pulse, with DATA high, in the middle of every gap where CLK stays high for 60 us
           (within a frame the model's CLK is high 40 us), when DATA is high there (a a frame releases it
           20 us after its last rising edge, the next pulls it low 20 us before its first fall; it is low only in
           the timeout scenario, a request to send that is never clocked); a pulse
           while DATA is high and no word is open is ignored by the decoder, so it only
           completes a pending word and carries no data. Device
           bytes decode as sent; host commands decode too, because the host changes DATA one tick
           after a falling edge, so the falling edges see start, 8 data and parity (the 11th, the
           "stop", is the device's ACK). Every word and its parity verdict must equal, in order,
           the host's records: device bytes (a parity error must be "Parity error") and commands.
  gpio     tb_gpio (gpio_expander.pbe): sigrok `spi` (CPOL 0, CPHA 0, MSB first, 8-bit words, no
           chip select: no pin frames the shifting) on the shared shift clock, the 595 data
           (MOSI) and the 165 data (MISO); every 3 words must equal the 24 bits the host wrote
           and read in that exchange.
  qspi     tb_qspi (qspi_flash.pbe): sigrok `spi` on SCK, CS# and IO0 (as MOSI) decodes the
           single-line phase of every transaction: the command and address bytes must equal what
           the host sent (the quad data phase has no stock decoder in libsigrokdecode 0.5.3).
"""
import argparse
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PBE = ROOT / 'pbe_v1'
TEST = PBE / 'test'
BUILD = PBE / 'build/sigrok_proto2'
SRC = [ROOT / 'src' / f'{n}.sv' for n in
       ('pbe_fifo', 'pbe_host_spi', 'pbe_crc', 'pbe_line', 'pbe_bsync', 'pbe_engine', 'pbe_pmem_sram', 'tt_um_pbe')]
SRAM = ROOT / 'macros/RM_IHPSG13_1P_256x16_c2_bm_bist'
SRAM_MODEL = [SRAM / 'RM_IHPSG13_1P_256x16_c2_bm_bist.v', SRAM / 'RM_IHPSG13_1P_core_behavioral_bm_bist.v']

BENCH = {
    'ps2':  ('tb_ps2', ['ps2_dev.sv'], 'ps2_image.hex', 'PASS: PS/2 host', {'p0': 'clk', 'p1': 'data'}),
    'gpio': ('tb_gpio', ['hc_chain.sv'], 'gpio_image.hex', 'PASS: GPIO expander',
             {'p0': 'sck', 'p1': 'sdo', 'p2': 'sdi', 'p3': 'rclk', 'p4': 'ld'}),
    'qspi': ('tb_qspi', ['qspi_flash_model.sv'], 'qspi_image.hex', 'PASS: QSPI',
             {'p0': 'sck', 'p1': 'cs', 'p2': 'io0', 'p3': 'io1', 'p4': 'io2', 'p5': 'io3'}),
}


def rewrite_vcd(src, dest, pins):
    """The bench's pins (ps timescale) as a 1 ns VCD with sigrok-friendly names; x/z read 1."""
    lines = src.read_text().splitlines()
    ids = {}
    for line in lines:
        if line.startswith('$var'):
            f = line.split()
            if f[4] in pins:
                ids[f[3]] = pins[f[4]]
    sym = {n: chr(33 + i) for i, n in enumerate(pins.values())}
    out = ['$timescale 1 ns $end', '$scope module top $end']
    out += [f'$var wire 1 {sym[n]} {n} $end' for n in pins.values()]
    out += ['$upscope $end', '$enddefinitions $end']
    t = 0
    for line in lines:
        if line.startswith('#'):
            t = int(line[1:]) // 1000
        elif len(line) >= 2 and line[0] in '01xz' and line[1:] in ids:
            out += [f'#{t}', ('0' if line[0] == '0' else '1') + sym[ids[line[1:]]]]
    out.append(f'#{t + 1000}')
    dest.write_text('\n'.join(out) + '\n')


def capture(name):
    tb, models, image, passed, pins = BENCH[name]
    d = BUILD / name
    d.mkdir(parents=True, exist_ok=True)
    subprocess.run(['make', '-C', str(PBE), f'test/{image}'], check=True, capture_output=True)
    shutil.copyfile(TEST / image, d / image)
    sim = d / f'{name}.vvp'
    subprocess.run(['iverilog', '-g2012', '-DPBE_SIGROK', '-DFUNCTIONAL', '-I', str(TEST), '-o', str(sim),
                    str(TEST / f'{tb}.sv')] + [str(TEST / m) for m in models] + [str(s) for s in SRC + SRAM_MODEL],
                   check=True, capture_output=True)
    log = subprocess.run(['vvp', '-n', str(sim)], cwd=d, capture_output=True, text=True)
    if passed not in log.stdout:
        print(log.stdout[-2000:])
        sys.exit(f'FAIL: the testbench {tb} itself failed')
    vcd = d / f'{name}.vcd'
    rewrite_vcd(d / f'{tb}_pins.vcd', vcd, pins)
    return log.stdout, vcd


def sigrok(cli, vcd, stack, ann):
    res = subprocess.run([cli, '-i', str(vcd), '-I', 'vcd', '-P', stack, '-A', ann],
                         capture_output=True, text=True, check=True)
    return [l.split(': ', 1)[1] for l in res.stdout.splitlines() if ': ' in l]


def report(name, bad, ok_msg):
    if bad:
        print(f'FAIL {name}:')
        for b in bad[:10]:
            print('  ' + b)
        return 1
    print(f'PASS {name}: {ok_msg}')
    return 0


def pad_idle_clock(src, dest, gap=60_000):
    """Add a 1 us CLK pulse in the middle of every gap where CLK stays high for `gap` ns (see ps2)."""
    head, events, t = [], [], 0
    lines = src.read_text().splitlines()
    sym = {}
    for line in lines:
        if line.startswith('$var'):
            f = line.split()
            sym[f[4]] = f[3]
    for line in lines:
        if line.startswith('#'):
            t = int(line[1:])
        elif line[:1] in '01' and line[1:] in sym.values():
            events.append((t, line))
        elif not events:
            head.append(line)
    c = sym['clk']
    clk_ev = [(t, l[0]) for t, l in events if l[1:] == c]
    dat_ev = [(t, l[0]) for t, l in events if l[1:] == sym['data']]

    def data_at(t):
        v = '1'
        for te, ve in dat_ev:
            if te > t:
                break
            v = ve
        return v
    extra = []
    for (t0, v0), (t1, v1) in zip(clk_ev, clk_ev[1:]):
        m = (t0 + t1) // 2
        if v0 == '1' and v1 == '0' and t1 - t0 >= gap and data_at(m) == '1':  # (not a pending request)
            extra += [(m, '0' + c), (m + 1000, '1' + c)]
    if clk_ev and clk_ev[-1][1] == '1':           # and after the last frame
        t0 = clk_ev[-1][0]
        extra += [(t0 + 60_000, '0' + c), (t0 + 61_000, '1' + c)]
    out = head
    for t, l in sorted(events + extra, key=lambda e: e[0]):
        out += [f'#{t}', l]
    out.append(f'#{t + 1000}')
    dest.write_text('\n'.join(out) + '\n')


def check_ps2(cli):
    out, vcd = capture('ps2')
    exp = []
    for line in out.splitlines():
        f = line.split()
        if f and f[0] == 'SIGROK_PS2':
            b, s = int(f[1], 16), int(f[2], 16)
            if s == 0x04:
                continue                      # a timeout: nothing was clocked
            exp.append((b, 'Parity error' if s == 0x01 else 'Parity OK'))
    padded = vcd.with_name('ps2_padded.vcd')
    pad_idle_clock(vcd, padded)
    got = sigrok(cli, padded, 'ps2:clk=clk:data=data', 'ps2=word:parity-ok:parity-err')
    words = []
    for g in got:
        if g.startswith('Data: '):
            words.append([int(g[6:], 16), None])
        elif g in ('Parity OK', 'Parity error') and words:
            words[-1][1] = g
    words = [tuple(w) for w in words]
    bad = [f'word {i}: decoded {g}, host record {e}' for i, (g, e) in enumerate(zip(words, exp)) if g != e]
    if len(words) != len(exp):
        bad.append(f'{len(words)} words decoded, {len(exp)} expected')
    n_err = sum(1 for e in exp if e[1] == 'Parity error')
    return report('ps2', bad, f'{len(words)} words decoded by sigrok ps2 in both directions equal the host\'s '
                              f'records, in order; {n_err} parity error flagged where the host reported it')


def check_gpio(cli):
    out, vcd = capture('gpio')
    exp = []
    for line in out.splitlines():
        f = line.split()
        if f and f[0] == 'SIGROK_GPIO':
            exp.append((f[1].upper(), f[2].upper()))   # out bytes, in bytes (hex strings)
    stack = 'spi:clk=sck:mosi=sdo:miso=sdi:cpol=0:cpha=0:bitorder=msb-first:wordsize=8'
    mosi = [v.upper() for v in sigrok(cli, vcd, stack, 'spi=mosi-data')]
    miso = [v.upper() for v in sigrok(cli, vcd, stack, 'spi=miso-data')]
    # group into 3-byte transfers
    got = [(''.join(mosi[i:i + 3]), ''.join(miso[i:i + 3])) for i in range(0, len(mosi), 3)]
    bad = [f'transfer {i}: decoded {g}, host {e}' for i, (g, e) in enumerate(zip(got, exp)) if g != e]
    if len(got) != len(exp):
        bad.append(f'{len(got)} transfers decoded, {len(exp)} made')
    return report('gpio', bad, f'{len(got)} 24-bit transfers decoded by sigrok spi: the bytes shifted into '
                               f'the 595s and out of the 165s equal the host\'s')


def check_qspi(cli):
    out, vcd = capture('qspi')
    exp = []
    for line in out.splitlines():
        f = line.split()
        if f and f[0] == 'SIGROK_QSPI':
            exp.append(f[1].upper())          # the single-line bytes of one transaction
    res = subprocess.run([cli, '-i', str(vcd), '-I', 'vcd', '-P',
                          'spi:clk=sck:mosi=io0:cs=cs:cpol=0:cpha=0:bitorder=msb-first:wordsize=8',
                          '-A', 'spi=mosi-transfer'], capture_output=True, text=True, check=True)
    got = [l.split(': ', 1)[1].replace(' ', '').upper() for l in res.stdout.splitlines() if ': ' in l]
    bad = [f'transaction {i}: decoded {g}, expected to start with {e}' for i, (g, e) in enumerate(zip(got, exp))
           if not g.startswith(e)]
    if len(got) != len(exp):
        bad.append(f'{len(got)} transactions decoded, {len(exp)} made')
    return report('qspi', bad, f'{len(got)} transactions: sigrok spi decodes the command and address bytes '
                               f'on IO0 exactly as the host sent them')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--sigrok-cli', default='sigrok-cli')
    p.add_argument('only', nargs='*', default=['ps2', 'gpio', 'qspi'])
    a = p.parse_args()
    if not shutil.which(a.sigrok_cli):
        sys.exit('ERROR: sigrok-cli is required; a missing tool is a failure, never a skipped pass.')
    BUILD.mkdir(parents=True, exist_ok=True)
    fails = 0
    for name in a.only:
        fails += {'ps2': check_ps2, 'gpio': check_gpio, 'qspi': check_qspi}[name](a.sigrok_cli)
    sys.exit(1 if fails else 0)


if __name__ == '__main__':
    main()
