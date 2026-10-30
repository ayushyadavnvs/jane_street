#!/usr/bin/env python3
"""Decode *external protocol pins* from existing benches with unmodified sigrok PDs.

No RTL/protocol semantics are implemented here. VCD extraction only crops bench
phase markers and rounds picosecond timestamps to 10 ns (100 MS/s); the stock
sigrok decoders interpret the resulting waveforms. Every subprocess, stdout,
stderr, waveform hash and byte/packet comparison is retained under --output.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3] / 'pbe_v1'  # the design
USB_STACK = ('usb_signalling:dp=p1:dm=p0:signalling=low-speed,'
             'usb_packet:signalling=low-speed,usb_request:in_request_start=submit')

SRC = [ROOT / 'src' / (x + '.sv') for x in
       ('pbe_fifo', 'pbe_host_spi', 'pbe_crc', 'pbe_line', 'pbe_engine', 'tt_um_pbe')]


def call(command, output, *, cwd=ROOT):
    proc = subprocess.run([str(x) for x in command], cwd=cwd, capture_output=True)
    output.with_suffix('.stdout').write_bytes(proc.stdout)
    output.with_suffix('.stderr').write_bytes(proc.stderr)
    output.with_suffix('.command.json').write_text(json.dumps([str(x) for x in command], indent=2)+'\n')
    if proc.returncode:
        raise RuntimeError(f'{command[0]} exited {proc.returncode}; see {output}.stderr')
    return proc.stdout


def capture(output):
    """Run normal pin benches with verification-only compact dumps enabled."""
    targets = ['uart', 'spi', 'mixed', 'nop', 'ow', 'modbus', 'ws2812', 'spi_periph', 'i2c_target', 'usb', 'conc']
    call(['make', *[f'test/{x}_image.hex' for x in targets]], output / 'images')
    for bench in ('tb_pbe', 'tb_proto', 'tb_usb'):
        sim = output / (bench+'.vvp')
        call(['iverilog', '-g2012', '-DPBE_SIGROK', '-s', bench, '-o', sim,
              ROOT / 'test' / (bench+'.sv'), *SRC], output / (bench+'_compile'), cwd=ROOT/'test')
        log = call(['vvp', '-n', sim], output / (bench+'_simulation'), cwd=ROOT/'test')
        if b'PASS\n' not in log:
            raise RuntimeError(f'{bench} did not print PASS')
        shutil.copyfile(ROOT/'test'/(bench+'_pins.vcd'), output/(bench+'_pins.vcd'))


def read_vcd(path):
    """Read only scalar p0..p7 and integer sigrok_phase in compact Icarus VCD."""
    ids, changes, state = {}, [], ['1'] * 8
    now, phase = 0, 0
    text = path.read_text()
    if not re.search(r'\$timescale\s+1ps\s+\$end', text):
        raise ValueError('Expected 1 ps VCD timescale')
    for line in text.splitlines():
        line = line.strip()
        if line.startswith('$var'):
            fields = line.split()
            ids[fields[3]] = fields[4]
        elif line.startswith('#'):
            now = int(line[1:])
        elif line.startswith('b'):
            value, code = line[1:].split()
            if ids.get(code) == 'sigrok_phase':
                phase = int(value, 2)
                changes.append((now, phase, tuple(state)))
        elif line[:1] in ('0', '1', 'x', 'z'):
            name = ids.get(line[1:], '')
            if re.fullmatch('p[0-7]', name):
                # Initial unknowns occur before reset; selected phases start afterwards.
                state[int(name[1])] = line[0]
                changes.append((now, phase, tuple(state)))
    # VCD variable order within a timestamp is arbitrary. Assign the final
    # phase and pin values together so a phase marker cannot lose its first SOP.
    grouped = {}
    for event in changes:
        grouped[event[0]] = event
    return list(grouped.values()), now


def crop_vcd(path, phase, dest, *, pad_ns=100_000, head_ns=1_000):
    changes, end = read_vcd(path)
    phases = {phase} if isinstance(phase,int) else set(phase)
    selected = [x for x in changes if x[1] in phases]
    if not selected:
        raise ValueError(f'{path}: missing sigrok_phase {phase}')
    start = selected[0][0]
    following = [x[0] for x in changes if x[0] > start and x[1] not in phases]
    stop = min(following) if following else end
    previous = [x for x in changes if x[0] < start]
    levels = previous[-1][2] if previous else selected[0][2]
    if set(levels)-set('01'):
        raise ValueError(f'{path}: unknown protocol pins at phase {phase} start')
    # Coalesce deltas within one 10 ns sample to avoid zero-duration glitches.
    samples = {0: levels}
    for timestamp, _, values in selected:
        samples[(timestamp-start)//10_000+head_ns//10] = values
    with dest.open('w') as out:
        out.write('$timescale 10ns $end\n$scope module pins $end\n')
        for i in range(8):
            out.write(f'$var wire 1 {chr(33+i)} p{i} $end\n')
        out.write('$upscope $end\n$enddefinitions $end\n')
        previous = (None,)*8
        for sample, values in sorted(samples.items()):
            diff = [f'{v}{chr(33+i)}\n' for i, v in enumerate(values) if v != previous[i]]
            if diff:
                out.write(f'#{sample}\n'+''.join(diff))
            previous = values
        out.write(f'#{(stop-start)//10_000+(head_ns+pad_ns)//10}\n')
    return {'original_sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
            'phase': phase, 'start_ps': start, 'stop_ps': stop,
            'sample_period_ns': 10, 'head_pad_ns': head_ns, 'tail_pad_ns': pad_ns}


class Checks:
    def __init__(self, cli, output):
        self.cli, self.output, self.results = cli, output, []

    def decode(self, name, wave, stack, *, annotation=None, binary=None):
        command = [self.cli, '-i', str(wave), '-I', 'vcd', '-P', stack]
        if binary:
            command += ['-B', binary]
        elif annotation:
            command += ['-A', annotation]
        result = call(command, self.output/name)
        # libsigrok 0.5 can exit zero on initialization failure: never count empty
        # stdout as success. A comparison below also requires non-empty data.
        stderr = (self.output/name).with_suffix('.stderr').read_text(errors='replace')
        if 'Traceback (most recent call last)' in stderr or re.search(r'Calling .* decode\(\) failed', stderr):
            raise RuntimeError(f'{name}: stock decoder exception; inspect stderr')
        if not result:
            raise RuntimeError(f'{name}: empty decoder output; inspect stderr')
        return result if binary else result.decode()

    def equal(self, name, got, expected):
        ok = got == expected
        self.results.append({'check':name, 'status':'PASS' if ok else 'FAIL',
                             'expected':expected.hex() if isinstance(expected,bytes) else expected,
                             'actual':got.hex() if isinstance(got,bytes) else got})
        print(f'{"PASS" if ok else "FAIL"}: {name}', flush=True)

    def sequence(self, name, got, expected):
        ok = expected in got
        self.results.append({'check':name, 'status':'PASS' if ok else 'FAIL',
                             'expected_sequence':expected.hex(), 'actual':got.hex()})
        print(f'{"PASS" if ok else "FAIL"}: {name}', flush=True)

    def known_limitation(self, name, got, expected, *, known_actual, verified, reason, strict=False):
        """Accept only the exact independently reproduced external-tool signature.

        A changed/unrecognized failure stays FAIL. A resolved limitation is PASS.
        Strict mode makes the same known discrepancy an ordinary failing check.
        """
        status = ('PASS' if got == expected else
                  'XFAIL' if verified and got == known_actual and not strict else 'FAIL')
        self.results.append({'check': name, 'status': status, 'expected': expected,
                             'actual': got, 'known_actual': known_actual,
                             'reason': reason, 'strict': strict})
        print(f'{status}: {name}', flush=True)

    def contains(self, name, text, expected):
        missing = [x for x in expected if x.lower() not in text.lower()]
        self.results.append({'check':name, 'status':'FAIL' if missing else 'PASS',
                             'expected_substrings':expected, 'missing':missing})
        print(f'{"FAIL" if missing else "PASS"}: {name}', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--full-usb-request', action='store_true',
                        help='strict mode: make the two documented full-trace decoder limitations fail (normally XFAIL)')
    parser.add_argument('--sigrok-cli', default=os.environ.get('SIGROK_CLI', 'sigrok-cli'))
    parser.add_argument('--output', type=Path, default=ROOT/'test'/'sigrok_results')
    parser.add_argument('--vcd-dir', type=Path, help='reuse compact PBE_SIGROK VCDs (skip simulation)')
    args = parser.parse_args()
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=True)
    cli = shutil.which(args.sigrok_cli)
    if not cli:
        print('ERROR: sigrok-cli is required; missing tools are failures, never skipped passes.', file=sys.stderr)
        return 2
    version = call([cli, '--version'], output/'versions').decode()
    if 'sigrok-cli' not in version:
        raise RuntimeError('sigrok initialization failed; see versions.stderr')
    if not args.vcd_dir:
        capture(output)
    source = args.vcd_dir.resolve() if args.vcd_dir else output
    manifest = {}
    for name, bench, phase in [('uart','pbe',1),('spi_ctrl','pbe',2),('i2c_ctrl','pbe',3),
                               ('onewire','pbe',4),('modbus','pbe',50),('ws281x','proto',8),
                               ('spi_periph','proto',9),('i2c_target','proto',10),
                               ('usb','usb',[11,110,111,112,113,114,115,116]),
                               ('usb_clean_initial','usb',11),('usb_clean_address','usb',111),
                               ('usb_clean_descriptors','usb',113),('usb_clean_vendor','usb',114),
                               ('usb_clean_reset','usb',116)]:
        manifest[name] = crop_vcd(source/f'tb_{bench}_pins.vcd', phase, output/f'{name}.vcd')
    (output/'waveforms.json').write_text(json.dumps(manifest,indent=2)+'\n')
    checks = Checks(cli, output)
    try:
        got = checks.decode('uart_decode', output/'uart.vcd', 'uart:rx=p0:baudrate=480000',binary='uart=rx')
        checks.equal('UART 480000 baud 8N1 bytes',got,bytes.fromhex('55 a3 00 ff 0f 80'))
        for name, mosi, miso in [('spi_ctrl','a5 5a 7e','3c c3 81'),
                                 ('spi_periph','11 22 33 44 55 60 61','3c a5 ff 5a c3 ff ff')]:
            stack = 'spi:clk=p0:mosi=p1:miso=p2:cs=p3:cpol=0:cpha=0'
            for pin, expected in [('mosi',mosi),('miso',miso)]:
                got = checks.decode(f'{name}_{pin}',output/f'{name}.vcd',stack,binary=f'spi={pin}')
                checks.equal(f'{name} {pin} bytes',got,bytes.fromhex(expected))
        for name, scl, sda, written, read in [
            ('i2c_ctrl',5,4,'10 de ad 10','de ad'),
            ('i2c_target',1,0,'10 de ad be ef 01 '+' '.join(f'{0x30+i:02x}' for i in range(5,20))+' 11 77 88','ad be ef 01')]:
            stack = f'i2c:scl=p{scl}:sda=p{sda}'
            for mode, expected in [('data-write',written),('data-read',read)]:
                got = checks.decode(f'{name}_{mode}',output/f'{name}.vcd',stack,binary=f'i2c={mode}')
                checks.equal(f'{name} {mode} bytes',got,bytes.fromhex(expected))
        ow = checks.decode('onewire_decode',output/'onewire.vcd','onewire_link:owr=p6,onewire_network',annotation='onewire_network')
        checks.contains('1-Wire Read/Search/Match ROM IDs',ow,
                        ['ROM: 0x2c000800003c5a28','ROM: 0x1b000800003c5b28'])
        ow_data = bytes(int(x,16) for x in re.findall(r'Data: 0x([0-9a-fA-F]{2})',ow))
        for label, expected in [('powerup scratchpad','be 50 05 4b 46 7f ff 0c 10 1c'),
                                ('converted scratchpad','be 91 01 4b 46 7f ff 0c 10 70'),
                                ('block with inverted CRC16','aa 11 22 33 44 55 66 77 88 1e b4')]:
            checks.sequence('1-Wire '+label,ow_data,bytes.fromhex(expected))
        stack = 'uart:tx=p0:rx=p1:baudrate=19200:parity=even,modbus'
        for pin, expected in [('tx','01 03 00 00 00 02 c4 0b'),('rx','01 03 04 12 34 56 78 81 07')]:
            got = checks.decode(f'modbus_{pin}',output/'modbus.vcd',stack,binary=f'uart={pin}')
            checks.equal(f'Modbus 19200 baud 8E1 {pin} bytes',got,bytes.fromhex(expected))
        mb = checks.decode('modbus_decode',output/'modbus.vcd',stack,annotation='modbus')
        checks.equal('Modbus stock decoder validates both CRC16 fields',mb.count('CRC correct'),2)
        ws = checks.decode('ws281x_decode',output/'ws281x.vcd','rgb_led_ws281x:din=p0',annotation='rgb_led_ws281x=rgb')
        got = re.findall(r'#[0-9a-fA-F]{6}',ws)
        expected = [f'#{(0xff-0x33*led if frame else 1<<led):02x}{0x10*led+frame:02x}{0xa5^(0x11*led):02x}'
                    for frame in range(2) for led in range(5)]
        checks.equal('WS2812 two frames / ten GRB pixels',got,expected)
        stack = USB_STACK
        usb = '\n'.join(checks.decode(name+'_requests',output/(name+'.vcd'),stack,
                                     annotation='usb_request')
                        for name in ('usb_clean_initial','usb_clean_address','usb_clean_descriptors',
                                     'usb_clean_vendor','usb_clean_reset'))
        # Full setup bytes, reassembled payload and handshake, in bench order.
        got_requests = [[bytes.fromhex(req).hex(),bytes.fromhex(data).hex(),status]
                        for req,data,status in re.findall(
                            r'SETUP (?:in|out): \[([0-9A-F ]*)\]\[([0-9A-F ]*)\] : (ACK|STALL|timeout)',usb)]
        descriptor = '12 01 10 01 ff 00 00 08 34 12 78 56 00 01 00 00 00 01'
        config = '09 02 12 00 01 01 00 80 32 09 04 00 00 00 ff 00 00 00'
        expected_requests = [
            ('80 06 00 01 00 00 40 00',descriptor,'ACK'),
            ('00 05 15 00 00 00 00 00','','ACK'),
            ('80 06 00 01 00 00 12 00',descriptor,'ACK'),
            ('80 06 00 02 00 00 09 00','09 02 12 00 01 01 00 80 32','ACK'),
            ('80 06 00 02 00 00 ff 00',config,'ACK'),
            ('00 09 01 00 00 00 00 00','','ACK'),
            ('80 06 02 03 09 04 40 00','','STALL'),
            ('40 01 00 00 00 00 03 00','aa bb cc','ACK'),
            ('c0 02 00 00 00 00 04 00','cc bb aa 55','ACK'),
            ('80 06 00 01 00 00 40 00',descriptor,'ACK')]
        expected_requests = [[bytes.fromhex(req).hex(),bytes.fromhex(data).hex(),status]
                             for req,data,status in expected_requests]
        checks.equal('USB ten valid control requests: exact setup, data and handshake',
                     got_requests,expected_requests)
        checks.equal('USB valid windows have no request decoder state errors',usb.count('ERR:'),0)
        full = checks.decode('usb_full_requests',output/'usb.vcd',stack,annotation='usb_request')
        # These are external-tool expected failures, not waived PBE assertions.
        # Exact observed signatures, known version and clean/packet checks below
        # prevent an unrelated new failure from being silently called XFAIL.
        known_version = bool(re.search(r'libsigrokdecode\s+0\.5\.3(?:/|\s|$)', version))
        address = '00 05 15 00 00 00 00 00'
        checks.known_limitation('USB full trace SET_ADDRESS reconstruction',
            full.count(address), 1, known_actual=0,
            verified=known_version and 'ERR: received SETUP token in state DATA RECEIVED' in full,
            reason='BUG-050: stock 0.5.3 has no DATA RECEIVED timeout; ROUND2_USB.md and packet-input reproduction',
            strict=args.full_usb_request)
        request_payloads = [bytes.fromhex(x) for x in re.findall(
            r'SETUP in: \[ 80 06 00 01 00 00 12 00 \]\[([0-9A-F ]+)\]',full)]
        checks.known_limitation('USB lost ACK descriptor lengths',
            [len(x) for x in request_payloads], [18,18], known_actual=[18,26],
            verified=known_version and 'ERR: received IN token in state DATA RECEIVED' in full,
            reason='BUG-051: stock 0.5.3 loses transaction association and unconditionally appends IN data; ROUND2_USB.md',
            strict=args.full_usb_request)
        data_packets = checks.decode('usb_data_packets',output/'usb.vcd',stack,
                                    annotation='usb_packet=packet-data0:packet-data1')
        checks.contains('USB packet decoder SET_ADDRESS and vendor payload',data_packets,
                        ['DATA0 [ 00 05 15 00 00 00 00 00 ]','DATA1 [ CC BB AA 55 ]'])
        checks.contains('USB packet decoder sees identical DATA1 retransmission',data_packets,
                        ['DATA1 [ 12 01 10 01 FF 00 00 08 ]\nusb_packet-1: DATA1 [ 12 01 10 01 FF 00 00 08 ]'])
        packets = checks.decode('usb_packet_decode',output/'usb.vcd',stack,annotation='usb_packet=crc5-err:crc16-err')
        checks.contains('USB injected bad CRC5/CRC16 are visible independently',packets,['CRC5 ERROR','CRC16 ERROR'])
    finally:
        (output/'results.json').write_text(json.dumps({'versions':version,'checks':checks.results},indent=2)+'\n')
    failed = [r for r in checks.results if r['status']=='FAIL']
    passed = sum(r['status']=='PASS' for r in checks.results)
    expected = sum(r['status']=='XFAIL' for r in checks.results)
    print(f'{passed}/{len(checks.results)} checks passed; {expected} documented external-tool XFAIL; '
          f'{len(failed)} unexpected/strict failures; evidence: {output}')
    return bool(failed)

if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError) as exc:
        print(f'ERROR: {exc}',file=sys.stderr)
        sys.exit(2)
