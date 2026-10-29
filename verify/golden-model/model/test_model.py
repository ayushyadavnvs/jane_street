"""Directed specification checks for the golden engine, independent of HDL."""
import unittest

from pbe_model import EngineModel, LineModel


def instruction(op, arg=0, delay=0):
    return op << 13 | arg << 4 | delay


NOP = instruction(6, 3 << 7)


class EngineSpecificationTests(unittest.TestCase):
    def test_unwritten_program_is_harmless_while_stopped_and_rejected_when_run(self):
        from model.top_model import PBEModel
        top = PBEModel()
        top.edge()
        top.edge()
        self.assertIsNone(top.engines[0].instr_q)
        self.assertEqual(top.outputs[:2], (0, 0))
        top.run = 1
        with self.assertRaisesRegex(ValueError, 'uninitialized program instruction at address 0'):
            top.edge()

    def program(self, *words):
        return list(words) + [NOP] * (128 - len(words))

    def start(self, model, program):
        model.step(program, restart=True)
        model.step(program)  # D50: target fetch, no instruction execution.

    def test_sequential_delay_and_relative_branch(self):
        for divider in (0, 1, 4):
            model = EngineModel(run=True, clkdiv=divider, start_pc=64)
            program = self.program()
            program[64] = instruction(0, 1 << 3, 3)  # DRV1 with delay 3
            program[65] = instruction(0, 0, 0)  # DRV0
            program[66] = instruction(3, 0, 0)  # relative branch to 64
            self.start(model, program)
            edges = []
            for cycle in range(80):
                effects = model.step(program)
                if effects['execute']:
                    edges.append((cycle, effects['instruction_pc']))
            self.assertEqual(edges[1][0] - edges[0][0], 4 * (divider + 1))
            self.assertEqual(edges[3][1], 64)
            self.assertEqual(edges[3][0] - edges[2][0], max(2, divider + 1))

    def test_wait_unblocks_between_ticks_and_restarts_divider(self):
        model = EngineModel(run=True, clkdiv=7)
        program = self.program(instruction(2, 1 << 3), instruction(0, 1 << 3))
        self.start(model, program)
        while not model.blocked:
            model.step(program, pins_in=0)
        effects = model.step(program, pins_in=1)
        self.assertTrue(effects['execute'])
        self.assertEqual(model.div_cnt, 0)
        for _ in range(7):
            self.assertFalse(model.step(program, pins_in=1)['execute'])
        self.assertTrue(model.step(program, pins_in=1)['execute'])

    def test_restart_cancels_side_effects_keeps_output_level(self):
        model = EngineModel(run=True)
        program = self.program(instruction(0, 1 << 3), instruction(6, 0))
        self.start(model, program)
        model.step(program)
        self.assertEqual((model.pins_out, model.pins_oe), (1, 1))
        effects = model.step(program, restart=True)
        self.assertFalse(effects['execute'])
        self.assertEqual(effects['flag_set'], 0)
        self.assertEqual((model.pins_out, model.pins_oe), (1, 0))

    def test_fifo_blocks_and_overflow_irq_is_sticky(self):
        model = EngineModel(run=True)
        program = self.program(instruction(5, 0), instruction(6, 3 << 7 | 3 << 4 | 2 << 2),
                               instruction(5, 256))
        self.start(model, program)
        self.assertFalse(model.step(program)['tx_pop'])
        self.assertTrue(model.blocked)
        self.assertTrue(model.step(program, tx_empty=False, tx_data=0xa5)['tx_pop'])
        model.step(program)  # MOV ISR, OSR
        self.assertEqual(model.isr, 0xa5)
        self.assertTrue(model.step(program, rx_full=True)['irq'])
        self.assertFalse(model.step(program, rx_full=True)['irq'])
        effects = model.step(program, rx_full=False)
        self.assertEqual((effects['rx_push'], effects['rx_data'], model.isr), (True, 0xa5, 0))
        self.assertTrue(model.status & 8)
        model.step(program, host_ovf_clr=True)
        self.assertFalse(model.status & 8)

    def test_flag_wait_all_modes(self):
        for condition, previous, current in ((0, 1, 0), (1, 0, 1), (2, 0, 1), (3, 1, 0)):
            model = EngineModel(run=True)
            program = self.program(instruction(2, 2 << 6 | 32 | condition << 3))
            self.start(model, program)
            model.flags_prev = previous << 2
            self.assertTrue(model.step(program, flags=current << 2)['execute'])

    def test_memory_write_refetches_blocked_instruction(self):
        model = EngineModel(run=True)
        program = self.program(instruction(5, 0))
        self.start(model, program)
        model.step(program)
        model.step(program, pm_wr=True)
        self.assertFalse(model.iv)
        self.assertEqual(model.pc, 0)
        program[0] = instruction(0, 1 << 3)
        self.assertFalse(model.step(program)['execute'])
        self.assertTrue(model.step(program)['execute'])
        self.assertEqual(model.pins_out, 1)

    def test_timeout_disabled_and_enabled(self):
        program = self.program(instruction(5, 0), instruction(0, 1 << 3))
        model = EngineModel(run=True, timeout=0, line_cfg=1)
        self.start(model, program)
        for _ in range(20):
            model.step(program)
        self.assertTrue(model.blocked)
        self.assertFalse(model.tmo_seen)
        model.configure(timeout=2)
        model.step(program)
        self.assertTrue(model.tmo_seen)
        self.assertFalse(model.iv)
        self.assertEqual(model.pc, 1)

    def test_crc_vectors_direct_wire_order(self):
        # Independent catalogue checks, using the canonical check string.
        # https://reveng.sourceforge.io/crc-catalogue/16.htm#crc.cat.crc-16-modbus
        # https://reveng.sourceforge.io/crc-catalogue/all.htm#crc.cat.crc-8-maxim-dow
        for width, polynomial, init, reflected, check in ((16, 0x8005, True, True, 0x4b37),
                                                       (8, 0x31, False, True, 0xa1)):
            config = (width - 1) | int(init) << 4 | int(reflected) << 5 | 64
            model = EngineModel(run=True, crc_cfg=config, crc_poly=polynomial)
            program = self.program()
            self.start(model, program)
            for byte in b'123456789':
                model.osr = byte
                model.instr_q = instruction(0, 4 << 3)
                for bit in range(8):
                    model.instr_q = instruction(0, 4 << 3)
                    model.step(program)
            self.assertEqual(model.crc_now, check)

    def test_status_parity_and_crc_inversion(self):
        model = EngineModel(run=True, crc_cfg=15 | 16, crc_good=0xffff)
        program = self.program(instruction(7, 2 << 6), instruction(7, 1 << 6 | 2))
        self.start(model, program)
        model.par_in = 1
        model.tmo_seen = True
        model.rx_ovf = True
        self.assertEqual(model.status, 15)
        model.step(program)
        self.assertEqual(model.isr, 15)
        self.assertEqual(model.status, 10)
        model.step(program)
        self.assertEqual(model.osr, 0)

    def test_byte_crc_feed_holds_next_instruction_eight_clocks(self):
        model = EngineModel(run=True, coder_cfg=33, clkdiv=19,
                            crc_cfg=7 | 64, crc_poly=0x31)
        program = self.program(instruction(4, 256 | 0xa5), instruction(0, 4 << 3),
                               instruction(0, 7 << 6 | 1 << 3))
        self.start(model, program)
        model.step(program)
        model.step(program)
        self.assertEqual(model.cf_cnt, 8)
        for _ in range(8):
            self.assertFalse(model.step(program)['execute'])
        self.assertTrue(model.step(program)['execute'])
        # LSB-first A5 (10100101 on the wire), polynomial x^8+x^5+x^4+1.
        self.assertEqual(model.crc_now, 0x09)


class LineSpecificationTests(unittest.TestCase):
    def test_known_transmit_bits_stuffing_nrzi_and_frame_end(self):
        payload = [0x52, 0xff, 0xff, 0x00, 0xa5]
        for mode in (1, 2):
            for style in range(4):
                source = [(byte >> bit) & 1 for byte in [0x80] + payload for bit in range(8)]
                stuffed, run, previous = [], 0, 1
                threshold = 6 if style == 1 else 5
                for bit in source:
                    stuffed.append(bit)
                    run = (run + 1 if bit else 0) if style != 3 else (run + 1 if bit == previous else 1)
                    previous = bit
                    if style and run == threshold:
                        inserted = 0 if style != 3 else 1 - previous
                        stuffed.append(inserted)
                        run, previous = (0 if style != 3 else 1), inserted
                expected, level = [], 1
                for bit in stuffed:
                    level = bit if mode == 1 else level if bit else 1 - level
                    expected.append(level)
                model = LineModel()
                observed, index, last_slot, end = [], 0, -20, False
                for cycle in range(2000):
                    put = model.tx_ready and index < len(payload)
                    finish = model.tx_ready and index == len(payload) and not end
                    byte = payload[index] if put else 0
                    index += int(put)
                    end |= finish
                    model.step(cfg=mode | style << 2 | 16 | 32, sync=0x80,
                               period_m1=19, tx_put=put, tx_end=finish, tx_data=byte)
                    if model.drive and cycle - last_slot >= 20:
                        observed.append(model.a_out)
                        last_slot = cycle
                self.assertEqual(observed[:len(expected)], expected)
                self.assertEqual(observed[len(expected):], [0, 0, 1])
                self.assertFalse(model.drive)

    def test_loopback_sync_and_all_stuffing_modes(self):
        payload = [0x52, 0xff, 0, 0xa5]
        for mode in (1, 2):
            for style in range(4):
                tx, rx = LineModel(), LineModel()
                index, end, received = 0, False, []
                for _ in range(2000):
                    a, b = (tx.a_out, tx.b_out) if tx.drive else (1, 0)
                    cfg = mode | style << 2 | 16 | 32
                    rx.step(cfg=cfg, sync=0x80, period_m1=19, a_in=a, b_in=b, rx_take=rx.rx_valid)
                    if rx.rx_valid:
                        received.append(rx.rx_data)
                    put = tx.tx_ready and index < len(payload)
                    finish = tx.tx_ready and index == len(payload) and not end
                    byte = payload[index] if put else 0
                    index += int(put)
                    end |= finish
                    tx.step(cfg=cfg, sync=0x80, period_m1=19, tx_put=put, tx_end=finish, tx_data=byte)
                self.assertEqual(received, payload)


if __name__ == '__main__':
    unittest.main()
