"""Negative regressions for BUG-072: exit 0/PASS cannot stand in for coverage."""
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parent))
from run import call,refresh_images
from data_file import clear_coverage,require_coverage
ROOT=Path(__file__).resolve().parents[2]
PBE=ROOT/'pbe_v1'                    # the design
GM=ROOT/'verify/golden-model'

class CoverageArtifacts(unittest.TestCase):
    def fake_sim(self,body,stale=False):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);data=root/'coverage.dat'
            if stale:data.write_text('old counters')
            result=call([sys.executable,'-c',body],root,root/'run.log',marker='PASS',coverage_file=data)
            return result
    def test_success_exit_without_dump_fails(self):
        self.assertFalse(self.fake_sim("print('PASS')")['passed'])
    def test_stale_dump_without_replacement_fails(self):
        result=self.fake_sim("print('PASS')",stale=True)
        self.assertFalse(result['passed']);self.assertIn('fresh nonempty',result['coverage_error'])
    def test_empty_dump_fails(self):
        self.assertFalse(self.fake_sim("open('coverage.dat','w').close();print('PASS')")['passed'])
    def test_fresh_dump_passes(self):
        result=self.fake_sim("open('coverage.dat','w').write('new counters');print('PASS')")
        self.assertTrue(result['passed']);self.assertGreater(result['coverage_bytes'],0)
    def test_failed_simulation_with_dump_still_fails(self):
        self.assertFalse(self.fake_sim("open('coverage.dat','w').write('new');print('PASS');raise SystemExit(1)")['passed'])
    def test_program_image_prerequisites_refresh_changed_program(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);(root/'program.pbe').write_text('new program')
            (root/'image.hex').write_text('stale image')
            os.utime(root/'image.hex',(100,100));os.utime(root/'program.pbe',(200,200))
            (root/'Makefile').write_text('image.hex: program.pbe\n\tcp $< $@\n')
            refresh_images(root,['image.hex'])
            self.assertEqual((root/'image.hex').read_text(),'new program')
    def test_differential_output_directory_isolation(self):
        sys.path.insert(0,str(GM));sys.path.insert(0,str(GM/'differential'))
        spec=importlib.util.spec_from_file_location('test_diff_paths',GM/'differential/test_diff.py')
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        with patch.dict(os.environ,{'PBE_DIFF_OUTPUT_DIR':'/tmp/pbe-cov-audit-output'}):
            self.assertEqual(module.output_path('coverage.json'),Path('/tmp/pbe-cov-audit-output/coverage.json'))
            self.assertEqual(module.output_path('failure-1.json'),Path('/tmp/pbe-cov-audit-output/failure-1.json'))
        with patch.dict(os.environ,{},clear=True):
            self.assertEqual(module.output_path('coverage.json'),PBE/'build/differential/coverage.json')

if __name__=='__main__':unittest.main(verbosity=2)
