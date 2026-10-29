#!/usr/bin/env python3
"""Primary-catalogue checks and independent crccheck oracle against real pbe_crc."""
import argparse
import os
from pathlib import Path
import sys
from cocotb_tools.runner import get_runner
from cocotb_tools.check_results import get_results
HERE=Path(__file__).resolve().parent
PBE=HERE.parents[1]
def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--seed',type=lambda x:int(x,0),default=0x435243)
    p.add_argument('--random-cases',type=int,default=8)
    a=p.parse_args()
    if a.random_cases<0:p.error('random-cases must be nonnegative')
    os.environ.update(PBE_CRC_SEED=str(a.seed),PBE_CRC_RANDOM=str(a.random_cases))
    sys.path.insert(0,str(HERE))
    runner=get_runner('icarus');build=PBE/'build/reference_crc'
    runner.build(sources=[PBE/'src/pbe_crc.sv'],hdl_toplevel='pbe_crc',build_dir=build,
                 build_args=['-g2012'],timescale=('1ps','1ps'))
    result=runner.test(hdl_toplevel='pbe_crc',test_module='test_catalogue',test_dir=HERE,
                       build_dir=build,results_xml=str(build/'results.xml'))
    tests,failures=get_results(result)
    if not tests or failures:raise SystemExit(f'CRC catalogue failed: {failures}/{tests}')
if __name__=='__main__':main()
