"""Run the engine/line-coder composition differential (no physical flow)."""
import os
from pathlib import Path

from cocotb_tools.check_results import get_results
from cocotb_tools.runner import get_runner


if __name__ == '__main__':
    here = Path(__file__).resolve().parent             # verify/golden-model/model
    root = here.parents[2] / 'pbe_v1'                  # the design (src, build)
    build = root / 'build' / 'engine_line_model'
    runner = get_runner('icarus')
    runner.build(sources=[root / ('src/' + name) for name in ('pbe_crc.sv', 'pbe_line.sv', 'pbe_engine.sv')],
                 hdl_toplevel='pbe_engine', build_dir=build, always=True,
                 build_args=['-g2012'], timescale=('1ns', '1ps'))
    results = runner.test(hdl_toplevel='pbe_engine', test_module='test_engine_line_cocotb',
                          test_dir=here, build_dir=build,
                          extra_env={'PYTHONPATH': str(here) + os.pathsep + os.environ.get('PYTHONPATH', '')})
    count, failed = get_results(results)
    if not count or failed:
        raise SystemExit(f'engine/line differential failed: {failed}/{count} failures')
