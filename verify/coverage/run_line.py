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
sys.path.insert(0,str(MODEL))
r=get_runner('verilator');build=PBE/'build/coverage/obj_line_sweep'
r.build(sources=[PBE/'build/coverage/src/pbe_line.sv'],hdl_toplevel='pbe_line',build_dir=build,
        build_args=['--timing','--coverage','--assert','-Wno-fatal','--compiler-include','verilated_cov.h'],timescale=('1ps','1ps'))
coverage_file=PBE/'build/coverage/line_sweep.dat'
clear_coverage(coverage_file)
result=r.test(hdl_toplevel='pbe_line',test_module='test_line_cocotb',test_dir=MODEL,build_dir=build,
              results_xml=str(build/'results.xml'),plusargs=[f'+verilator+coverage+file+{PBE/"build/coverage/line_sweep.dat"}'])
require_coverage(coverage_file)
tests,failures=get_results(result)
if not tests or failures:raise SystemExit(f'line sweep failures {failures}/{tests}')
