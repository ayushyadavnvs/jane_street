#!/usr/bin/env python3
"""Primary-catalogue checks and independent crccheck oracle against real pbe_crc."""
import argparse
import os
from pathlib import Path
import sys
from cocotb_tools.runner import get_runner
from cocotb_tools.check_results import get_results
HERE=Path(__file__).resolve().parent
PBE=HERE.parents[2]/'pbe_v1'  # the design
def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--wide',action='store_true',help='all RevEng 17–32 bit CRCs, including explicit host-prefeed initialization')
    p.add_argument('--seed',type=lambda x:int(x,0),default=0x435243)
    p.add_argument('--random-cases',type=int,default=8)
    p.add_argument('--sim',choices=['icarus','verilator'],default='icarus')
    p.add_argument('--source-dir',type=Path,default=PBE/'src')
    p.add_argument('--coverage-output',type=Path)
    a=p.parse_args()
    if a.random_cases<0:p.error('random-cases must be nonnegative')
    os.environ['PBE_CRC_WIDE']='1' if a.wide else '0'
    os.environ.update(PBE_CRC_SEED=str(a.seed),PBE_CRC_RANDOM=str(a.random_cases))
    sys.path.insert(0,str(HERE))
    runner=get_runner(a.sim);build=PBE/('build/reference_crc_wide' if a.wide else 'build/reference_crc')
    args=['-g2012'] if a.sim=='icarus' else ['--timing','-Wno-fatal','--output-groups','0']
    if a.coverage_output:args+=['--coverage','--assert','--compiler-include','verilated_cov.h'];a.coverage_output.unlink(missing_ok=True)
    os.environ['PBE_CRC_WIDTH_SWEEP']='1' if a.coverage_output else '0'
    runner.build(sources=[a.source_dir/'pbe_crc.sv'],hdl_toplevel='pbe_crc',build_dir=build,
                 build_args=args,timescale=('1ps','1ps'))
    result=runner.test(hdl_toplevel='pbe_crc',test_module='test_catalogue',test_dir=HERE,
                       build_dir=build,results_xml=str(build/'results.xml'),plusargs=[f'+verilator+coverage+file+{a.coverage_output.resolve()}'] if a.coverage_output else [])
    if a.coverage_output and (not a.coverage_output.exists() or not a.coverage_output.stat().st_size):raise SystemExit('missing CRC coverage')
    tests,failures=get_results(result)
    if not tests or failures:raise SystemExit(f'CRC catalogue failed: {failures}/{tests}')
if __name__=='__main__':main()
