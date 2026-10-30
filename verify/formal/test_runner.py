"""Receipt metadata must use SBY's last task-specific option override."""
import importlib.util
from pathlib import Path
import unittest
s=importlib.util.spec_from_file_location('formal_runner',Path(__file__).with_name('run.py'))
r=importlib.util.module_from_spec(s);s.loader.exec_module(r)
class FormalReceiptTests(unittest.TestCase):
    def test_task_override_is_effective_mode_and_depth(self):
        cfg='[options]\nmode bmc\ndepth 164\nmode cover\ndepth 48\n[engines]\nsmtbmc yices\n'
        self.assertEqual(r.option(cfg,'mode'),'cover')
        self.assertEqual(r.option(cfg,'depth'),'48')
    def test_missing_option_is_unspecified(self):
        self.assertIsNone(r.option('[options]\nmode bmc\n','depth'))
    def test_cover_locations_include_smtbmc_step_text(self):
        log=('SBY engine_0: Reached cover statement in step 3 at engine_formal: engine_formal.sv:51.5-51.19 (cover_a)\n'
             'SBY engine_0: Reached cover statement in step 195 at host: observer.sv:9.1-9.8 (cover_b)\n')
        self.assertEqual(r.cover_locations(log),[
            'engine_formal: engine_formal.sv:51.5-51.19 (cover_a)',
            'host: observer.sv:9.1-9.8 (cover_b)'])
if __name__=='__main__':unittest.main()
