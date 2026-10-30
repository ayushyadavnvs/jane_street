#!/usr/bin/env python3
"""Replay minimal *packet-layer* inputs into unmodified stock usb_request.

No PBE, RTL, waveform extraction, line-coding implementation or patched decoder is
involved. A tiny sigrok API stub only records emitted annotations/binary output;
the installed decoder's actual decode/handle_transfer methods run unchanged.
This isolates request-layer bugs; pin-waveform decoding remains sigrok_verify.py.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import types


def load_decoder(path):
    stub = types.ModuleType('sigrokdecode')
    stub.Decoder = object
    stub.OUTPUT_BINARY, stub.OUTPUT_ANN, stub.SRD_CONF_SAMPLERATE = 0, 1, 2
    original = sys.modules.get('sigrokdecode')
    sys.modules['sigrokdecode'] = stub
    try:
        spec = importlib.util.spec_from_file_location('stock_usb_request', path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    finally:
        if original is None:
            del sys.modules['sigrokdecode']
        else:
            sys.modules['sigrokdecode'] = original
    return module.Decoder, stub


def run_case(decoder_class, srd, option, case):
    d = decoder_class()
    annotations, events = [], []
    d.options = {'in_request_start': option}
    d.register = lambda kind: kind
    def record(ss, es, output, data):
        # Real sigrok requires integer sample numbers, including annotations.
        if not isinstance(ss, int) or not isinstance(es, int):
            raise TypeError('annotation sample numbers must be integers')
        if output == srd.OUTPUT_ANN:
            annotations.append(data[1][0])
    d.put = record
    d.start()
    d.metadata(srd.SRD_CONF_SAMPLERATE, 100_000_000)
    now = 0

    def packet(category, name, info):
        nonlocal now
        before = d.transaction_state
        # A 100 MS/s packet interface at nominal LS rate, with three bit
        # times between packet boundaries. Exact encoded waveform timing is
        # tested separately by sigrok_verify.py; this is packet-layer input.
        now += 200
        bits = 19 if category == 'HANDSHAKE' else 35
        if category == 'DATA':
            bits += 8 * len(info[2])
        end = now + round(bits * 100 / 1.5)
        d.decode(now, end, ['PACKET', [category, name, info]])
        now = end
        events.append({'packet': name, 'before': before, 'after': d.transaction_state})

    def token(name): packet('TOKEN', name, [0x80, 0, 0, 0, 0])
    def data(name, payload, crc=0): packet('DATA', name, [0x80, 0, list(payload), crc])
    def hs(name='ACK'): packet('HANDSHAKE', name, [0x80, 0])
    def setup(payload): token('SETUP'); data('DATA0', payload); hs()

    descriptor = bytes.fromhex('12 01 10 01 ff 00 00 08 34 12 78 56 00 01 00 00 00 01')
    if case == 'missing-handshake':
        token('SETUP')
        data('DATA0', bytes.fromhex('80 06 00 02 00 00 09 00'), crc=0x1234)
        # No response to corrupt data. Stock packet PD forwards PACKET even
        # when separately annotating CRC16 ERROR; request PD ignores that field.
        now += 10_000  # 100 us idle: well above the 18 LS-bit timeout
        setup(bytes.fromhex('00 05 15 00 00 00 00 00'))
        token('IN'); data('DATA1', b''); hs()
        expected = '00 05 15 00 00 00 00 00'
        observed = sum(expected in a for a in annotations)
        limitation = observed == 0 and any('SETUP token in state DATA RECEIVED' in a for a in annotations)
        expectation = {'set_address_requests': 1}
        actual = {'set_address_requests': observed}
    elif case == 'empty-in-timeout':
        token('IN'); hs('NAK')
        # Empty transfer has ss_data=None. first-ack tries to annotate it on
        # timeout, submit substitutes the request's integer start sample.
        try:
            token('IN')
            now += 10_000
            token('IN')
        except TypeError as exc:
            return {'case': case, 'in_request_start': option,
                    'known_limitation_reproduced': option == 'first-ack',
                    'exception': str(exc), 'annotations': annotations, 'events': events}
        return {'case': case, 'in_request_start': option,
                'known_limitation_reproduced': option == 'submit',
                'exception': None, 'annotations': annotations, 'events': events}
    else:
        setup(bytes.fromhex('80 06 00 01 00 00 12 00'))
        token('IN'); data('DATA1', descriptor[:8])  # ACK absent
        now += 10_000  # ACK timeout before the host issues its retry
        token('IN'); hs('NAK')  # retry while endpoint requeues its packet
        token('IN'); data('DATA1', descriptor[:8]); hs()
        token('IN'); data('DATA0', descriptor[8:16]); hs()
        token('IN'); data('DATA1', descriptor[16:]); hs()
        token('OUT'); data('DATA1', b''); hs()
        observed = next((a for a in annotations if a.startswith('SETUP in:')), '')
        assembled = observed.split('][')[-1].split(']')[0].split() if observed else []
        expectation = {'descriptor_bytes': 18}
        actual = {'descriptor_bytes': len(assembled)}
        limitation = len(assembled) == 26 and assembled[:8] == assembled[8:16]
    return {'case': case, 'in_request_start': option, 'expected': expectation,
            'actual': actual, 'known_limitation_reproduced': limitation,
            'annotations': annotations, 'events': events}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    directory = os.environ.get('SIGROKDECODE_DIR', '/usr/share/libsigrokdecode/decoders')
    parser.add_argument('--decoder', type=Path, default=Path(directory)/'usb_request/pd.py')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    klass, srd = load_decoder(args.decoder)
    results = [run_case(klass, srd, option, case)
               for option in ('submit', 'first-ack')
               for case in ('missing-handshake', 'lost-ack-nak-retry', 'empty-in-timeout')]
    report = {'decoder_path': str(args.decoder),
              'decoder_sha256': hashlib.sha256(args.decoder.read_bytes()).hexdigest(),
              'boundary': 'stock request decoder with synthetic packet inputs; no PBE waveform',
              'cases': results}
    text = json.dumps(report, indent=2)+'\n'
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text)
    else:
        print(text, end='')
    return 0 if all(r['known_limitation_reproduced'] for r in results) else 1


if __name__ == '__main__':
    sys.exit(main())
