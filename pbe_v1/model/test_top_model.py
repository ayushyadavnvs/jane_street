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
        m=PBEModel(); m.program=[0xd800]*128
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
        self.assertEqual(m.read(0x12),7); self.assertEqual(m.read(0x15),127)

    def test_program_byte_order_pointer_wrap(self):
        m=PBEModel(); m.write(6,254)
        m.write(7,0x12); m.write(7,0x34)
        self.assertEqual(m.program[127],0x1234)
        self.assertEqual(m.read(6),0)

    def test_tx_only_flush_leaves_rx(self):
        m=PBEModel(); m.program=[0xd800]*128
        m.tx[0].edge(push=True,data=0xab); m.rx[0].edge(push=True,data=0xcd)
        m.host.wr=(14,1); m.edge()
        self.assertEqual(m.tx[0].count,0)
        self.assertEqual(m.rx[0].contents,[0xcd])

if __name__ == '__main__': unittest.main()
