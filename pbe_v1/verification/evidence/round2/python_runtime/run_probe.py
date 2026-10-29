#!/usr/bin/env python3
"""Record sys.version inside an actual cocotb simulator, independently of its banner."""
import argparse,sys
from pathlib import Path
from cocotb_tools.runner import get_runner
from cocotb_tools.check_results import get_results
HERE=Path(__file__).resolve().parent;PBE=HERE.parents[3]
p=argparse.ArgumentParser();p.add_argument('--sim',choices=['icarus','verilator'],default='icarus');a=p.parse_args()
build=PBE/'build/python_runtime_probe'/a.sim
sys.path.insert(0,str(HERE));runner=get_runner(a.sim)
runner.build(sources=[PBE/'src/pbe_crc.sv'],hdl_toplevel='pbe_crc',build_dir=build,
             build_args=['-g2012'] if a.sim=='icarus' else ['-Wno-fatal'],timescale=('1ps','1ps'))
result=runner.test(hdl_toplevel='pbe_crc',test_module='runtime_probe',test_dir=HERE,build_dir=build,
                  results_xml=str(build/'results.xml'),extra_env={'PBE_RUNTIME_PROBE_OUT':str(build/'runtime.json')})
tests,failures=get_results(result)
if not tests or failures:raise SystemExit('Runtime probe failed')
print((build/'runtime.json').read_text())
