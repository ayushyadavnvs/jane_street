"""Run the CAN-mode random differential of pbe_bsync (requires cocotb 2.x/Icarus).

Usage: check_bsync_model.py [--seed 0x43414E] [--trials 8]   (trials per kind; 3 kinds)
"""
import argparse
import os
from pathlib import Path

from cocotb_tools.runner import get_runner
from cocotb_tools.check_results import get_results


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--seed', default='0x43414E')
    p.add_argument('--trials', type=int, default=8)
    a = p.parse_args()
    here = Path(__file__).resolve().parent
    root = here.parents[2]
    runner = get_runner('icarus')
    build = root / 'pbe_v1/build/bsync_model'
    runner.build(sources=[root / 'src/pbe_bsync.sv'], hdl_toplevel='pbe_bsync',
                 build_dir=build, always=True, build_args=['-g2012'], timescale=('1ns', '1ps'))
    results = runner.test(hdl_toplevel='pbe_bsync', test_module='test_bsync_cocotb',
                          test_dir=here, build_dir=build,
                          extra_env={'PYTHONPATH': str(here) + os.pathsep + os.environ.get('PYTHONPATH', ''),
                                     'PBE_CAN_SEED': a.seed, 'PBE_CAN_TRIALS': str(a.trials)})
    tests, failures = get_results(results)
    if not tests or failures:
        raise SystemExit(f'bsync CAN differential failed: {failures}/{tests} failures')
