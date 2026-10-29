#!/usr/bin/env python3
"""Run reproducible top-level model/RTL differential tests (cocotb 2.x)."""
import argparse
import os
from pathlib import Path
import sys
import xml.etree.ElementTree as ET
from cocotb_tools.runner import get_runner

PBE = Path(__file__).resolve().parents[2]

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--n',type=int,default=4,help='number of reproducible random program seeds')
    p.add_argument('--seed',type=lambda x:int(x,0),default=0x504245)
    p.add_argument('--cycles',type=int,default=1200,help='random stimulus clocks per seed')
    p.add_argument('--testcase',default='random_differential')
    a=p.parse_args()
    if a.n < 1 or a.cycles < 1: p.error('n and cycles must be positive')
    os.environ.update(PBE_N=str(a.n),PBE_SEED=str(a.seed),PBE_CYCLES=str(a.cycles))
    sys.path[:0]=[str(PBE),str(Path(__file__).parent)]
    r=get_runner('icarus')
    r.build(sources=list((PBE/'src').glob('*.sv')),hdl_toplevel='tt_um_ayushyadavnvs_pbe',
            build_dir=PBE/'build'/'differential',build_args=['-g2012'],timescale=('1ps','1ps'))
    r.test(hdl_toplevel='tt_um_ayushyadavnvs_pbe',test_module='test_diff',testcase=a.testcase,
           test_dir=PBE,results_xml=str(PBE/'build'/'differential'/'results.xml'))
    results=ET.parse(PBE/'build'/'differential'/'results.xml').getroot()
    cases=results.findall('.//testcase')
    if not cases or results.findall('.//failure') or results.findall('.//error'):
        raise SystemExit('Differential simulation failed; see results.xml')
if __name__ == '__main__': main()
