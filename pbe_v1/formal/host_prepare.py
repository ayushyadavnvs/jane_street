#!/usr/bin/env python3
"""Generate assertion-only host SPI source in ignored build/, never edit RTL."""
from pathlib import Path
import argparse
PBE=Path(__file__).resolve().parents[1]
def prepare(out=None):
    out=Path(out) if out else PBE/'build/formal/generated/host_formal.sv'
    source=(PBE/'src/pbe_host_spi.sv').read_text()
    assert source.count('endmodule')==1
    props=(Path(__file__).parent/'host_properties.svh').read_text()
    out.parent.mkdir(parents=True,exist_ok=True)
    out.write_text(source.replace('endmodule', props+'\nendmodule'))
    return out
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--out',type=Path);a=p.parse_args()
    print(prepare(a.out))
