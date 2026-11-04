#!/usr/bin/env python3
"""Copy pbe_bsync and add observation-only properties; build old/new pairs for the default check."""
from pathlib import Path
import subprocess
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
OUT = ROOT / 'pbe_v1/build/formal/generated'
BASE = '797314f'   # main before CAN: "default configuration = today's behaviour" compares with it


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    src = (ROOT / 'src/pbe_bsync.sv').read_text()
    assert src.count('endmodule') == 1
    props = (HERE / 'bsync_properties.svh').read_text()
    (OUT / 'bsync_formal.sv').write_text(src.replace('endmodule', props + '\nendmodule'))
    old = {}
    for name in ('pbe_line', 'pbe_engine', 'pbe_crc'):
        text = subprocess.check_output(['git', 'show', f'{BASE}:src/{name}.sv'], cwd=ROOT, text=True)
        for n in ('pbe_line', 'pbe_engine', 'pbe_crc'):
            text = text.replace(f'module {n} ', f'module {n}_old ').replace(f'{n} u_', f'{n}_old u_')
        old[name] = text
    (OUT / 'default_old.sv').write_text('\n'.join(old.values()))


if __name__ == '__main__':
    main()
