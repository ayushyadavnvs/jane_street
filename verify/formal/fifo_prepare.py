#!/usr/bin/env python3
"""Generate assertion-only FIFO source in ignored build/, without editing RTL."""
from pathlib import Path
import argparse
PBE=Path(__file__).resolve().parents[2]/'pbe_v1'  # the design
def prepare(out=None):
    out=Path(out) if out else PBE/'build/formal/generated/fifo_formal.sv'
    source=(PBE/'src/pbe_fifo.sv').read_text()
    assert source.count('endmodule')==1
    props=(Path(__file__).parent/'fifo_properties.svh').read_text()
    out.parent.mkdir(parents=True,exist_ok=True)
    out.write_text(source.replace('endmodule', props+'\nendmodule'))
    return out
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--out',type=Path);a=p.parse_args()
    print(prepare(a.out))
