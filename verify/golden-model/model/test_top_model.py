"""Top-level contract tests with explicit expected architectural outcomes."""
import unittest
from model.top_model import FIFO, PBEModel

class TestTopModel(unittest.TestCase):
    def test_fifo_boundary_and_flush(self):
        f=FIFO()
        for i in range(16): f.edge(push=True,data=i)
        self.assertEqual(f.contents,list(range(16)))
        f.edge(push=True,data=99,pop=True)
        self.assertEqual(f.contents,list(range(1,16)))
        f.edge(flush=True)
        f.edge(push=True,data=42,pop=True)
        self.assertEqual(f.contents,[42])

    def test_reset_preserves_unreset_backing_storage(self):
        m=PBEModel()
        m.tx[0].edge(push=True,data=0xa5)
        m.program[0]=0x1234
        m.reset()
        self.assertEqual(m.tx[0].count,0)
        self.assertEqual(m.tx[0].mem[0],0xa5)
        self.assertEqual(m.program[0],0x1234)

    def test_host_prefetch_unknown_shift(self):
        m=PBEModel(); h=m.host
        h.load=2
        h.edge(0,None)
        self.assertIsNone(h.miso)
        h.edge(2,0)
        self.assertEqual(h.miso,0)

    def test_flag_wrap_and_clear_priority(self):
        m=PBEModel(); m.program=[0xd800]*512
        m.write(0x18,7); m.write(0x28,0)
        for e in m.engines:
            e.instr_q=0xc010; e.iv=True; e.pc=1
        m.run=3; m.edge()
        self.assertEqual(m.flags,3)
        m.host.wr=(9,3); m.edge()
        self.assertEqual(m.flags,0)

    def test_pin_ownership_and_register_truncation(self):
        m=PBEModel(); m.write(3,0xaa)
        m.engines[0].pout=0xff; m.engines[0].poe=0xff
        m.engines[1].pout=0; m.engines[1].poe=0
        self.assertEqual(m.outputs[:2],(0x55,0x55))
        m.write(0x12,0xff); m.write(0x15,0xff)
        self.assertEqual(m.read(0x12),7); self.assertEqual(m.read(0x15),255)  # 8-bit START_PC (D82)

    def test_program_byte_order_pointer_carry(self):
        # D82: word 127's low byte carries into PM_ADDR_H[0] (word 128)
        m=PBEModel(); m.write(6,254)
        m.write(7,0x12); m.write(7,0x34)
        self.assertEqual(m.program[127],0x1234)
        self.assertEqual((m.read(15),m.read(6)),(1,0))

    def test_engine_select_and_wrap_within_engine(self):
        # D82: PM_ADDR_H[1] selects engine 1's memory; word 255 wraps to 0 of the same engine
        m=PBEModel(); m.write(15,3); m.write(6,254)
        for b in (0x12,0x34,0x56,0x78): m.write(7,b)
        self.assertEqual(m.program[256+255],0x1234)
        self.assertEqual(m.program[256+0],0x5678)
        self.assertIsNone(m.program[255]); self.assertIsNone(m.program[0])
        self.assertEqual((m.read(15),m.read(6)),(2,2))

    def test_write_refetches_only_its_engine_twice(self):
        # D82, BUG-074: a write to engine 1's memory invalidates engine 1 at the write and one
        # clock later; engine 0 is untouched. After reset both refetch once.
        m=PBEModel(); m.program=[0xd800]*512
        self.assertEqual(m.pm_wr_q,[True,True])
        m.edge(); m.edge()
        for e in m.engines: self.assertTrue(e.iv)
        m.write(15,2); m.host.wr=(7,0xd8); m.edge()
        self.assertTrue(m.engines[0].iv); self.assertFalse(m.engines[1].iv)
        m.edge()
        self.assertTrue(m.engines[0].iv); self.assertFalse(m.engines[1].iv)
        m.edge()
        self.assertTrue(m.engines[1].iv)

    def test_partial_program_word_stays_unspecified_until_both_bytes_written(self):
        m=PBEModel()
        m.write(7,0xd8)  # Only the high byte is known; low byte was never written.
        self.assertIsNone(m.program[0])
        m.reset()  # Reset must retain the one known byte, without inventing the other.
        self.assertIsNone(m.program[0])
        m.write(6,1); m.write(7,0x13)
        self.assertEqual(m.program[0],0xd813)
        m.write(6,0); m.write(7,0x80)
        self.assertEqual(m.program[0],0x8013)

    def test_rewriting_one_unknown_word_half_does_not_initialize_other_half(self):
        m=PBEModel()
        for high in (0x12,0x34):
            m.write(6,0); m.write(7,high)
            self.assertIsNone(m.program[0])
        m.write(7,0x56)
        self.assertEqual(m.program[0],0x3456)

    def test_tx_only_flush_leaves_rx(self):
        m=PBEModel(); m.program=[0xd800]*512
        m.tx[0].edge(push=True,data=0xab); m.rx[0].edge(push=True,data=0xcd)
        m.host.wr=(14,1); m.edge()
        self.assertEqual(m.tx[0].count,0)
        self.assertEqual(m.rx[0].contents,[0xcd])

if __name__ == '__main__': unittest.main()
