#!/usr/bin/env python3
"""Independent Ethernet/HDLC pin vectors and asynchronous-host stress."""
import argparse,os,sys,json,hashlib,subprocess
from pathlib import Path
from cocotb_tools.runner import get_runner
from cocotb_tools.check_results import get_results
HERE=Path(__file__).resolve().parent;ROOT=HERE.parents[1];PBE=ROOT/'pbe_v1'
def main():
 p=argparse.ArgumentParser();p.add_argument('--test-module');p.add_argument('--stress',action='store_true');p.add_argument('--sim',default='icarus',choices=['icarus','verilator']);p.add_argument('--source-dir',type=Path,default=ROOT/'src');p.add_argument('--coverage-output',type=Path);a=p.parse_args();module=a.test_module or ('test_wire_stress' if a.stress else 'test_wire_vectors')
 sys.path.insert(0,str(HERE));profile=module.removeprefix('test_')
 build=PBE/'build'/profile/a.sim;build.mkdir(parents=True,exist_ok=True)
 os.environ['PBE_WIRE_RESULTS']=str(build/'observations.json');os.environ['PBE_WIRE_OUTPUT']=str(build)
 sram=ROOT/'macros/RM_IHPSG13_1P_256x16_c2_bm_bist'
 sources=[*sorted(a.source_dir.glob('*.sv')),HERE/'pin_top.sv',sram/'RM_IHPSG13_1P_256x16_c2_bm_bist.v',sram/'RM_IHPSG13_1P_core_behavioral_bm_bist.v']
 args=['-g2012'] if a.sim=='icarus' else ['--timing','-Wno-fatal','--output-groups','0']
 if a.coverage_output:args+=['--coverage','--assert','--compiler-include','verilated_cov.h'];a.coverage_output.unlink(missing_ok=True)
 r=get_runner(a.sim);r.build(sources=sources,hdl_toplevel='pin_top',build_dir=build,build_args=args,defines={'FUNCTIONAL':1},timescale=('1ps','1ps'))
 (build/'inputs.json').write_text(json.dumps({str(x.relative_to(ROOT)):hashlib.sha256(x.read_bytes()).hexdigest() for x in sources+[HERE/'pin_driver.py',HERE/'wire_codecs.py',HERE/(module+'.py')]},indent=2))
 result=r.test(hdl_toplevel='pin_top',test_module=module,test_dir=HERE,build_dir=build,results_xml=str(build/'results.xml'),plusargs=[f'+verilator+coverage+file+{a.coverage_output.resolve()}'] if a.coverage_output else [])
 tests,fail=get_results(result)
 if not tests or fail:raise SystemExit(f'wire failure {fail}/{tests}')
 if a.coverage_output and (not a.coverage_output.exists() or not a.coverage_output.stat().st_size):raise SystemExit('missing coverage')
if __name__=='__main__':main()
