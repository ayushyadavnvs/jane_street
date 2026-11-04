#!/usr/bin/env python3
"""Decode tb_can's bus with sigrok's stock `can` decoder (D72).

For each bit rate the CAN testbench runs its "rates" scenario with PBE_SIGROK, which dumps the
wired-AND bus and prints every frame the chip's engine 0 recorded (SIGROK_EXPECT). The bus is
rewritten as a one-signal VCD at 10 ns resolution and decoded by sigrok-cli's `can` decoder.
Every decoded frame must match the expected list (ID, RTR, DLC, data), carry the CRC-15 that
this script computes independently (CRC-15/CAN over the destuffed bits, not from the RTL), and
be acknowledged, and the decoder must report no rule violation ("must ..." annotations).
"""
import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PBE = ROOT / 'pbe_v1'
BUILD = PBE / 'build/sigrok_can'
SRC = [ROOT / 'src' / f'{n}.sv' for n in
       ('pbe_fifo', 'pbe_host_spi', 'pbe_crc', 'pbe_line', 'pbe_bsync', 'pbe_engine', 'tt_um_pbe')]
RATES = {0: 125000, 1: 250000, 2: 500000, 3: 1000000}


def crc15(bits):
    crc = 0
    for b in bits:
        fb = b ^ (crc >> 14 & 1)
        crc = (crc << 1) & 0x7FFF
        if fb:
            crc ^= 0x4599
    return crc


def frame_crc(fid, rtr, dlc, data):
    bits = [0] + [fid >> i & 1 for i in range(10, -1, -1)] + [rtr, 0, 0] + [dlc >> i & 1 for i in range(3, -1, -1)]
    n = 0 if rtr else min(dlc, 8)
    for b in range(n):
        byte = data >> (56 - 8 * b) & 255
        bits += [byte >> i & 1 for i in range(7, -1, -1)]
    return crc15(bits)


def segments(src, rate):
    """The bus as (time, level) changes in 10 ns units, cut into one piece per frame at
    recessive gaps of at least 9 bit times (only the end of a frame has more than 6), so each
    frame is decoded on its own."""
    changes, t, last = [], 0, None
    for line in src.read_text().splitlines():
        if line.startswith('#'):
            t = int(line[1:]) // 10000   # the bench's VCD is in ps
        elif line in ('0!', '1!', 'x!'):
            v = 0 if line == '0!' else 1
            if v != last:
                changes.append((t, v))
                last = v
    gap = 9 * 100_000_000 // rate   # longer than any recessive run inside a frame (6 bits)
    pieces, cur = [], []
    for i, (t, v) in enumerate(changes):
        if v == 0 and cur and t - cur[-1][0] >= gap and cur[-1][1] == 1:
            pieces.append(cur)
            cur = []
        cur.append((t, v))
    if cur:
        pieces.append(cur)
    return [p for p in pieces if any(v == 0 for _, v in p)]


def write_piece(piece, dest, rate):
    start = piece[0][0] - 2 * 100_000_000 // rate
    out = ['$timescale 10 ns $end', '$scope module top $end', '$var wire 1 ! can_bus $end',
           '$upscope $end', '$enddefinitions $end', '#0', '1!']
    for t, v in piece:
        out += [f'#{t - start}', f'{v}!']
    out.append(f'#{piece[-1][0] - start + 20 * 100_000_000 // rate}')
    dest.write_text('\n'.join(out) + '\n')


def decode(cli, vcd, rate):
    stack = f'can:can_rx=can_bus:nominal_bitrate={rate}:sample_point=75'
    res = subprocess.run([cli, '-i', str(vcd), '-I', 'vcd', '-P', stack, '-A', 'can'],
                         capture_output=True, text=True, check=True)
    frames, cur, violations = [], None, []
    for line in res.stdout.splitlines():
        text = line.split(': ', 1)[1] if ': ' in line else line
        if 'must' in text:
            violations.append(text)
        m = re.match(r'Identifier: (\d+)', text)
        if m:
            cur = dict(id=int(m.group(1)), rtr=0, dlc=None, data=[], crc=None, ack=None)
            frames.append(cur)
        elif cur is None:
            continue
        elif text.startswith('Remote transmission request:'):
            cur['rtr'] = int('remote' in text)
        elif text.startswith('Data length code:'):
            cur['dlc'] = int(text.split(':')[1])
        elif text.startswith('Data byte'):
            cur['data'].append(int(text.split(':')[1], 16))
        elif text.startswith('CRC-15 sequence:'):
            cur['crc'] = int(text.split(':')[1], 16)
        elif text.startswith('ACK slot:'):
            cur['ack'] = text.split(':')[1].strip()
    return frames, violations


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--sigrok-cli', default='sigrok-cli')
    p.add_argument('--rates', default='0,1,2,3')
    a = p.parse_args()
    if not shutil.which(a.sigrok_cli):
        sys.exit('ERROR: sigrok-cli is required; a missing tool is a failure, never a skipped pass.')
    BUILD.mkdir(parents=True, exist_ok=True)
    subprocess.run(['make', '-C', str(PBE), 'test/can_image.hex'], check=True, capture_output=True)
    shutil.copyfile(PBE / 'test/can_image.hex', BUILD / 'can_image.hex')
    sim = BUILD / 'can.vvp'
    subprocess.run(['iverilog', '-g2012', '-DPBE_SIGROK', '-I', str(PBE / 'test'), '-o', str(sim), str(PBE / 'test/tb_can.sv'),
                    str(PBE / 'test/can_ref_node.sv')] + [str(s) for s in SRC], check=True, capture_output=True)
    failures = 0
    for r in [int(x) for x in a.rates.split(',')]:
        log = subprocess.run(['vvp', '-n', str(sim), '+ONLY=rates', f'+RATE={r}'], cwd=BUILD,
                             capture_output=True, text=True)
        if 'PASS: CAN node' not in log.stdout:
            print(f'FAIL {RATES[r]}: the testbench itself failed'); failures += 1; continue
        expected = []
        for line in log.stdout.splitlines():
            if line.startswith('SIGROK_EXPECT'):
                _, fid, rtr, dlc, data = line.split()
                expected.append(dict(id=int(fid, 16), rtr=int(rtr), dlc=int(dlc), data=int(data, 16)))
        frames, bad = [], []
        for k, piece in enumerate(segments(BUILD / 'tb_can_bus.vcd', RATES[r])):
            vcd = BUILD / f'can_{RATES[r]}_{k}.vcd'
            write_piece(piece, vcd, RATES[r])
            got, violations = decode(a.sigrok_cli, vcd, RATES[r])
            frames += got
            remote_with_dlc = k < len(expected) and expected[k]['rtr'] and expected[k]['dlc'] > 0
            if not remote_with_dlc:   # see the known limitation below
                bad += [f'frame {k}: {v}' for v in violations]
        if len(frames) != len(expected):
            bad.append(f'{len(frames)} frames decoded, {len(expected)} expected')
        known = 0
        for i, (f, e) in enumerate(zip(frames, expected)):
            if e['rtr'] and e['dlc'] > 0:
                # Known decoder limitation (libsigrokdecode 0.5.3, decoders/can/pd.py): the data
                # field's end is dlc_start + 3 + dlc2len(DLC) * 8 even for a remote frame, so a
                # remote frame with DLC > 0 is read as if it had data, and its CRC, ACK and EOF
                # land on the wrong bits. The fields before the DLC are still checked.
                if (f['id'], f['rtr'], f['dlc']) != (e['id'], 1, e['dlc']):
                    bad.append(f'frame {i}: decoded {f}, expected {e}')
                known += 1
                continue
            n = 0 if e['rtr'] else min(e['dlc'], 8)
            data = [e['data'] >> (56 - 8 * b) & 255 for b in range(n)]
            want = frame_crc(e['id'], e['rtr'], e['dlc'], e['data'])
            if (f['id'], f['rtr'], f['dlc'], f['data']) != (e['id'], e['rtr'], e['dlc'], data):
                bad.append(f'frame {i}: decoded {f}, expected {e}')
            if f['crc'] != want:
                bad.append(f'frame {i}: CRC-15 {f["crc"]}, independent {want:#06x}')
            if f['ack'] != 'ACK':
                bad.append(f'frame {i}: ACK slot {f["ack"]}')
        if bad:
            failures += 1
            print(f'FAIL {RATES[r]} bit/s:')
            for b in bad[:10]:
                print('  ' + b)
        else:
            print(f'PASS {RATES[r]} bit/s: {len(frames)} frames decoded by sigrok can, '
                  f'IDs, RTR, DLC, data and CRC-15 match, all ACKed, no rule violations '
                  f'({known} remote frame(s) with DLC > 0 checked up to the DLC: decoder limitation)')
    sys.exit(1 if failures else 0)


if __name__ == '__main__':
    main()
