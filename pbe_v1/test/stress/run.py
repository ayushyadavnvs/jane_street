#!/usr/bin/env python3
"""Run separate pin stress tests; strict nonzero failures, optional characterization."""
import argparse
import json
import os
from pathlib import Path
import sys
import xml.etree.ElementTree as ET
from cocotb_tools.runner import get_runner

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[2]

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--check-results',type=Path,help='strictly reevaluate an existing complete observation file without simulation')
    p.add_argument('--seed',type=lambda x:int(x,0),default=0x50424534)
    p.add_argument('--required-only',action='store_true',help='omit beyond-margin characterization cases')
    p.add_argument('--characterize',action='store_true',help='allow recorded failing observations; never converts them to PASS')
    p.add_argument('--output',type=Path,default=ROOT/'pbe_v1/build/stress')
    a=p.parse_args()
    if a.check_results:
        return evaluate(json.loads(a.check_results.read_text()),a.required_only,a.characterize)
    out=a.output.resolve();out.mkdir(parents=True,exist_ok=True)
    result=out/'observations.json';result.unlink(missing_ok=True)
    os.environ.update(PBE_ROOT=str(ROOT),PBE_STRESS_OUTPUT=str(result),PBE_STRESS_SEED=str(a.seed),
                      PBE_STRESS_REQUIRED_ONLY=str(int(a.required_only)),PBE_STOCK_I2C='0',PBE_STOCK_SPI='0')
    sources=[ROOT/'src'/f'{n}.sv' for n in ('pbe_fifo','pbe_host_spi','pbe_crc','pbe_line','pbe_engine','tt_um_pbe')]
    r=get_runner('icarus')
    r.build(sources=sources+[HERE/'stress_top.sv'],hdl_toplevel='stress_top',build_dir=out,build_args=['-g2012'],timescale=('1ns','1ps'))
    xml=out/'results.xml';xml.unlink(missing_ok=True)
    r.test(hdl_toplevel='stress_top',test_module='test_stress',testcase='pin_stress',test_dir=HERE,
           build_dir=out,seed=a.seed,results_xml=str(xml))
    cases=ET.parse(xml).getroot()
    if not cases.findall('.//testcase') or cases.findall('.//failure') or cases.findall('.//error'):
        raise SystemExit('Stress simulation/driver failed; observations may be incomplete')
    data=json.loads(result.read_text())
    code=evaluate(data,a.required_only,a.characterize)
    result.write_text(json.dumps(data,indent=2)+'\n')
    return code


def evaluate(data,required_only,characterize):
    rows=[row for row in data['cases'] if row['required'] or not required_only]
    expected=22 if required_only else 33
    if len(rows)!=expected:raise SystemExit(f'Expected {expected} completed cases, observed {len(rows)}')
    failed=[x for x in rows if x['status']!='PASS']
    data.update(characterization=characterize,required_only=required_only,
                summary={'cases':len(rows),'passed':len(rows)-len(failed),'failed':len(failed),
                         'failed_cases':[x['case'] for x in failed]})
    print(json.dumps(data['summary'],indent=2),flush=True)
    return 1 if failed and not characterize else 0

if __name__=='__main__':sys.exit(main())
