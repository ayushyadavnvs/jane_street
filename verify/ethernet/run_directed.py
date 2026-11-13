#!/usr/bin/env python3
"""Run focused architectural corner programs with the independent pin oracle."""
import argparse,json,os,sys
from pathlib import Path
from cocotb_tools.runner import get_runner
from cocotb_tools.check_results import get_results
HERE=Path(__file__).resolve().parent;ROOT=HERE.parents[1];PBE=ROOT/'pbe_v1';GM=ROOT/'verify/golden-model'
def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--sim',choices=('icarus','verilator'),default='icarus')
    p.add_argument('--source-dir',type=Path,default=ROOT/'src')
    p.add_argument('--coverage-output',type=Path)
    a=p.parse_args()
    sys.path[:0]=[str(HERE),str(GM),str(GM/'differential')]
    os.environ['PBE_ETHERNET']='1';os.environ['PBE_TWO_STATE']=str(int(a.sim=='verilator'))
    build=PBE/'build/ethernet_directed'/a.sim;build.mkdir(parents=True,exist_ok=True)
    args=['-g2012'] if a.sim=='icarus' else ['--timing','-Wno-fatal','--output-groups','0']
    if a.coverage_output:
        if a.sim!='verilator':p.error('coverage requires Verilator')
        args+=['--coverage','--assert','--compiler-include','verilated_cov.h']
    sram=ROOT/'macros/RM_IHPSG13_1P_256x16_c2_bm_bist'
    models=[sram/'RM_IHPSG13_1P_256x16_c2_bm_bist.v',sram/'RM_IHPSG13_1P_core_behavioral_bm_bist.v']
    r=get_runner(a.sim)
    r.build(sources=sorted(a.source_dir.glob('*.sv'))+models,hdl_toplevel='tt_um_ayushyadavnvs_pbe',
            build_dir=build,build_args=args,defines={'FUNCTIONAL':1},timescale=('1ps','1ps'))
    if a.coverage_output:a.coverage_output.unlink(missing_ok=True)
    result=r.test(hdl_toplevel='tt_um_ayushyadavnvs_pbe',test_module='test_directed',
        test_dir=HERE,build_dir=build,results_xml=str(build/'results.xml'),
        plusargs=[f'+verilator+coverage+file+{a.coverage_output.resolve()}'] if a.coverage_output else [])
    tests,failures=get_results(result)
    if tests!=3 or failures:raise SystemExit(f'directed corners failed {failures}/{tests}')
    if a.coverage_output and (not a.coverage_output.exists() or not a.coverage_output.stat().st_size):
        raise SystemExit('missing/empty directed-corner coverage')
if __name__=='__main__':main()
