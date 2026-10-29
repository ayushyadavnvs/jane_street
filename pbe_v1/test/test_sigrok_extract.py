"""Regression for a phase marker sharing a protocol start-edge timestamp."""
import importlib.util
from pathlib import Path
import tempfile
import os
import unittest
from unittest.mock import patch

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


class ExpectedExternalLimitations(unittest.TestCase):
    def test_only_verified_exact_signature_is_expected_failure(self):
        checks = sigrok_verify.Checks(None, None)
        for actual, verified, strict, status in [
                ([18,26], True, False, 'XFAIL'),
                ([18,26], True, True, 'FAIL'),
                ([18,26], False, False, 'FAIL'),
                ([18,27], True, False, 'FAIL'),
                ([18,18], True, False, 'PASS')]:
            with self.subTest(actual=actual, verified=verified, strict=strict):
                checks.known_limitation('test', actual, [18,18], known_actual=[18,26],
                                        verified=verified, strict=strict, reason='test reason')
                self.assertEqual(checks.results[-1]['status'], status)
                self.assertEqual(checks.results[-1]['reason'], 'test reason')

    def test_usb_low_speed_and_request_option_are_explicit(self):
        self.assertEqual(sigrok_verify.USB_STACK,
                         'usb_signalling:dp=p1:dm=p0:signalling=low-speed,'
                         'usb_packet:signalling=low-speed,usb_request:in_request_start=submit')


class DecoderExitStatus(unittest.TestCase):
    def test_nonempty_stdout_and_exit_zero_do_not_hide_decoder_exception(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp)
            (output/'broken.stderr').write_text(
                'srd: TypeError: Calling usb_request-1 decode() failed: argument 1 must be int, not None\n')
            checks = sigrok_verify.Checks('sigrok-cli', output)
            with patch.object(sigrok_verify, 'call', return_value=b'partial annotations'):
                with self.assertRaisesRegex(RuntimeError, 'stock decoder exception'):
                    checks.decode('broken', Path('wave.vcd'), sigrok_verify.USB_STACK)


class StockRequestReproduction(unittest.TestCase):
    def test_installed_stock_decoder_both_options(self):
        decoder = Path(os.environ.get('SIGROKDECODE_DIR',
                       '/usr/share/libsigrokdecode/decoders'))/'usb_request/pd.py'
        if not decoder.is_file():
            self.skipTest('optional stock sigrok decoder absent; run make sigrok separately')
        location = Path(__file__).parents[1]/'tools'/'usb_decoder_repro.py'
        module_spec = importlib.util.spec_from_file_location('usb_decoder_repro', location)
        repro = importlib.util.module_from_spec(module_spec)
        module_spec.loader.exec_module(repro)
        klass, srd = repro.load_decoder(decoder)
        for option in ('submit', 'first-ack'):
            for case in ('missing-handshake', 'lost-ack-nak-retry', 'empty-in-timeout'):
                with self.subTest(option=option, case=case):
                    result = repro.run_case(klass, srd, option, case)
                    self.assertTrue(result['known_limitation_reproduced'], result)


if __name__ == '__main__':
    unittest.main()
