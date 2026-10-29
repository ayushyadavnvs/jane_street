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
    p.add_argument('--sim',choices=('icarus','verilator'),default='icarus')
    p.add_argument('--coverage',action='store_true',help='Verilator line/toggle/user coverage')
    p.add_argument('--source-dir',type=Path,default=PBE/'src',help='Optional scratch-only coverage-instrumented RTL')
    p.add_argument('--build-dir',type=Path)
    p.add_argument('--coverage-output',type=Path)
    a=p.parse_args()
    if a.coverage and a.sim != 'verilator': p.error('--coverage requires --sim verilator')
    build=(a.build_dir or PBE/'build'/('differential' if a.sim=='icarus' else 'differential_verilator')).resolve()
    flags=['-g2012'] if a.sim=='icarus' else ['--timing','-Wno-fatal']
    if a.coverage:
        flags+=['--coverage','--assert','--compiler-include','verilated_cov.h']
        if a.source_dir.resolve() == (PBE/'src').resolve():
            import importlib.util
            spec=importlib.util.spec_from_file_location('pbe_cov_prepare',PBE/'coverage/prepare.py')
            module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
            a.source_dir=module.prepare()

    os.environ['PBE_TWO_STATE']='1' if a.sim=='verilator' else '0'
    coverage_output=(a.coverage_output or build/'coverage.dat').resolve()

    if a.n < 1 or a.cycles < 1: p.error('n and cycles must be positive')
    os.environ.update(PBE_N=str(a.n),PBE_SEED=str(a.seed),PBE_CYCLES=str(a.cycles),PBE_DIFF_OUTPUT_DIR=str(build))
    sys.path[:0]=[str(PBE),str(Path(__file__).parent)]
    r=get_runner(a.sim)
    r.build(sources=list(a.source_dir.resolve().glob('*.sv')),hdl_toplevel='tt_um_ayushyadavnvs_pbe',
            build_dir=build,build_args=flags,timescale=('1ps','1ps'))
    if a.coverage:
        sys.path.insert(0,str(PBE/'coverage'))
        from data_file import clear_coverage, require_coverage
        clear_coverage(coverage_output)
    r.test(hdl_toplevel='tt_um_ayushyadavnvs_pbe',test_module='test_diff',testcase=a.testcase,
           test_dir=PBE,results_xml=str(build/'results.xml'),
           plusargs=[f'+verilator+coverage+file+{coverage_output}'] if a.coverage else [])
    if a.coverage: require_coverage(coverage_output)
    results=ET.parse(build/'results.xml').getroot()
    cases=results.findall('.//testcase')
    if not cases or results.findall('.//failure') or results.findall('.//error'):
        raise SystemExit('Differential simulation failed; see results.xml')
if __name__ == '__main__': main()
