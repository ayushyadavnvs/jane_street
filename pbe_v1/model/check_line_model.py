"""Run the focused line-coder differential test (requires cocotb 2.x/Icarus)."""
import os
from pathlib import Path

from cocotb_tools.runner import get_runner
from cocotb_tools.check_results import get_results


if __name__ == '__main__':
    root = Path(__file__).resolve().parents[1]
    runner = get_runner('icarus')
    build = root / 'build' / 'line_model'
    runner.build(sources=[root / 'src/pbe_line.sv'], hdl_toplevel='pbe_line',
                 build_dir=build, always=True, build_args=['-g2012'], timescale=('1ns', '1ps'))
    results = runner.test(hdl_toplevel='pbe_line', test_module='test_line_cocotb',
                test_dir=root / 'model', build_dir=build,
                extra_env={'PYTHONPATH': str(root / 'model') + os.pathsep + os.environ.get('PYTHONPATH', '')})
    tests, failures = get_results(results)
    if not tests or failures:
        raise SystemExit(f'line model differential failed: {failures}/{tests} failures')
