#!/usr/bin/env python3
"""Reuse the independent per-clock line oracle for all 32 functional line bins."""
import os,sys
from pathlib import Path
from cocotb_tools.runner import get_runner
from cocotb_tools.check_results import get_results
from data_file import clear_coverage, require_coverage
ROOT=Path(__file__).resolve().parents[2]
PBE=ROOT/'pbe_v1'                    # the design
MODEL=ROOT/'verify/golden-model/model'
sys.path[:0]=[str(MODEL),str(Path(__file__).resolve().parent)]
name='ethernet_line_sweep' if os.getenv('PBE_LINE_ETHERNET')=='1' else 'line_sweep'
r=get_runner('verilator');build=PBE/'build/coverage'/('obj_'+name)
r.build(sources=[PBE/'build/coverage/src/pbe_line.sv'],hdl_toplevel='pbe_line',build_dir=build,
        build_args=['--output-groups','0','--timing','--coverage','--assert','-Wno-fatal','--compiler-include','verilated_cov.h'],timescale=('1ps','1ps'))
coverage_file=PBE/'build/coverage'/(name+'.dat')
clear_coverage(coverage_file)
result=r.test(hdl_toplevel='pbe_line',test_module=['test_line_ethernet','test_line_limits'] if os.getenv('PBE_LINE_ETHERNET')=='1' else 'test_line_cocotb',test_dir=MODEL,build_dir=build,
              results_xml=str(build/'results.xml'),plusargs=[f'+verilator+coverage+file+{coverage_file}'])
require_coverage(coverage_file)
tests,failures=get_results(result)
if not tests or failures:raise SystemExit(f'line sweep failures {failures}/{tests}')
