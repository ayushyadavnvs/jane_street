#!/usr/bin/env python3
"""Copy unmodified line logic and add formal observation-only assertions."""
import argparse
from pathlib import Path

PBE = Path(__file__).resolve().parents[2] / 'pbe_v1'  # the design


def prepare(out=None):
    out = Path(out) if out else PBE / "build/formal/generated/line_formal.sv"
    source = (PBE / "src/pbe_line.sv").read_text()
    assert source.count("module pbe_line (") == 1
    assert source.count("endmodule") == 1
    source = source.replace("module pbe_line (", "module pbe_line #(parameter FORMAL_CHECKS=0, parameter FORMAL_ORIGINAL_STUFF=0) (")
    properties = (Path(__file__).parent / "line_properties.svh").read_text()
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(source.replace("endmodule", properties + "\nendmodule"))
    return out


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path)
    print(prepare(parser.parse_args().out))
