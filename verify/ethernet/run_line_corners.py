#!/usr/bin/env python3
"""External-port line corners: full 16-bit divider, short glitches and flag run reset."""
import argparse,sys
from pathlib import Path
from cocotb_tools.runner import get_runner
from cocotb_tools.check_results import get_results
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--source-dir',type=Path,default=ROOT/'src');a=p.parse_args()
sys.path.insert(0,str(ROOT/'verify/coverage'));build=ROOT/'pbe_v1/build/line_corners';r=get_runner('icarus')
r.build(sources=[a.source_dir/'pbe_line.sv'],hdl_toplevel='pbe_line',build_dir=build,build_args=['-g2012'],timescale=('1ps','1ps'))
result=r.test(hdl_toplevel='pbe_line',test_module='test_line_limits',test_dir=ROOT/'verify/coverage',build_dir=build,results_xml=str(build/'results.xml'))
tests,fail=get_results(result)
if tests!=3 or fail:raise SystemExit(f'line corners failed {fail}/{tests}')
