#!/usr/bin/env python3
"""Run pin-only third-party bus models; never invokes synthesis or physical design."""
import argparse
import os
import xml.etree.ElementTree as ET
from pathlib import Path
from cocotb_tools.runner import get_runner

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--seed', type=int, default=20261029)
    ap.add_argument('--cases', type=int, default=3)
    ap.add_argument('--test', default=None, help='cocotb test name, default all')
    ap.add_argument('--stock-i2c', action='store_true', help='reproduce upstream pre-stretch SDA sampling bug')
    ap.add_argument('--stock-spi', action='store_true', help='reproduce upstream cocotb 2 import incompatibility')
    ap.add_argument('--spi-mode', type=int, default=0,
                    help='existing programs implement mode 0 only; other modes fail explicitly')
    args = ap.parse_args()
    if args.cases < 1:
        ap.error('--cases must be positive')
    if args.spi_mode != 0:
        ap.error('SPI modes 1/2/3 are unsupported by the unmodified protocol programs')
    os.environ['PBE_BUS_SEED'] = str(args.seed)
    os.environ['PBE_BUS_CASES'] = str(args.cases)
    os.environ['PBE_ROOT'] = str(ROOT)
    os.environ['PBE_STOCK_I2C'] = '1' if args.stock_i2c else '0'
    os.environ['PBE_STOCK_SPI'] = '1' if args.stock_spi else '0'
    runner = get_runner('icarus')
    sources = [ROOT/'src'/name for name in (
        'pbe_fifo.sv', 'pbe_host_spi.sv', 'pbe_crc.sv', 'pbe_line.sv',
        'pbe_engine.sv', 'tt_um_pbe.sv')]
    build = ROOT/'pbe_v1/test/bus_models/sim_build'
    runner.build(sources=sources+[HERE/'bus_top.sv'], hdl_toplevel='bus_top',
                 build_dir=build, build_args=['-g2012'], timescale=('1ns','1ps'))
    (build/'results.xml').unlink(missing_ok=True)
    runner.test(hdl_toplevel='bus_top', test_module='test_buses',
                test_dir=HERE, build_dir=build, testcase=args.test,
                seed=args.seed, results_xml=str(build/'results.xml'))
    if not (build/'results.xml').is_file():
        raise SystemExit('bus-model simulation produced no results.xml')
    result = ET.parse(build/'results.xml').getroot()
    tests = result.findall('.//testcase')
    if not tests or result.findall('.//failure') or result.findall('.//error'):
        raise SystemExit('bus-model regression did not pass; see results.xml')

if __name__ == '__main__':
    main()
