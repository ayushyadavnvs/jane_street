"""Regression for a phase marker sharing a protocol start-edge timestamp."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('sigrok_verify', Path(__file__).parents[1]/'tools'/'sigrok_verify.py')
sigrok_verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sigrok_verify)


class CaptureBoundary(unittest.TestCase):
    def test_start_edge_before_or_after_phase_marker(self):
        header = ('$timescale 1ps $end\n'
                  '$var wire 1 ! p0 $end\n'
                  '$var integer 32 ) sigrok_phase $end\n'
                  '$enddefinitions $end\n#0\n1!\nb1 )\n')
        for changes in ('0!\nb10 )\n', 'b10 )\n0!\n'):
            with self.subTest(changes=changes), tempfile.TemporaryDirectory() as tmp:
                source, dest = Path(tmp)/'in.vcd', Path(tmp)/'out.vcd'
                source.write_text(header+'#100000\n'+changes+'#200000\n1!\n')
                sigrok_verify.crop_vcd(source, 2, dest)
                result = dest.read_text()
                # Preserve idle and the first edge even if the marker follows
                # that edge in VCD file order (Icarus may emit either order).
                self.assertIn('#0\n1!\n', result)
                self.assertIn('#100\n0!\n', result)
                self.assertIn('#110\n1!\n', result)


if __name__ == '__main__':
    unittest.main()
