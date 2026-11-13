"""Architectural examples from D89/D91 and the RevEng ISO-HDLC check."""
import unittest
from model.top_model import HostSPI, PBEModel
from model.pbe_model import EngineModel, LineModel

class EthernetModelContracts(unittest.TestCase):
    def test_quad_command_nibbles_and_latch(self):
        h=HostSPI();h.edge(2,0,quad_req=1)
        self.assertTrue(h.quad)
        for nibble in (0x9,0x6,0xa,0x5):
            h.edge(nibble << 2,0,quad_req=0)
            h.edge((nibble << 2)|1,0,quad_req=0)
        self.assertEqual(h.wr,(0x16,0xa5))
        self.assertTrue(h.quad) # request cannot change an active transaction
        h.edge(2,0,quad_req=0)
        self.assertFalse(h.quad)

    def test_exit_only_on_eighth_idle_rise_and_reset_by_cs(self):
        h=HostSPI()
        for _ in range(7):
            h.edge(2,0);h.edge(3,0)
            self.assertFalse(h.quad_exit)
        h.edge(0,0) # a selected transaction breaks the idle-edge count
        for _ in range(7):
            h.edge(2,0);h.edge(3,0)
            self.assertFalse(h.quad_exit)
        h.edge(2,0);h.edge(3,0)
        self.assertTrue(h.quad_exit)
        h.edge(2,0)
        self.assertFalse(h.quad_exit)

    def test_wide_crc_registers_and_hostcfg(self):
        m=PBEModel()
        for e in range(2):
            p=0x30+16*e
            m.write(p+8,0xc1);m.write(p+9,4)
            m.write(p+10,0xdd);m.write(p+11,0xc7);m.write(p+12,0xff)
            self.assertEqual(m.config[e]['crc_poly'],0x04c10000)
            self.assertEqual(m.read(p+10),0xdd)
            self.assertEqual(m.read(p+11),0xc7)
            self.assertEqual(m.read(p+12),1)
        m.write(0x50,0xff)
        self.assertEqual(m.read(0x50),1)
        self.assertTrue(all(m.read(a)==0 for a in range(0x51,0x80)))

    def test_crc32_iso_hdlc_check_and_byte_selection(self):
        m=EngineModel(run=True,crc_wide=1,crc_cfg=0x7f,crc_poly=0x04c11db7)
        nop=[0xd800]*256
        m.step(nop,host_crc_init=True)
        for byte in b'123456789':
            for i in range(8):
                m.instr_q=0x0200 # PIN OUT, feeding one wire-order bit
                m.iv=True;m.osr=(byte >> i)&1
                m.step(nop)
        self.assertEqual(m.crc_now ^ 0xffffffff,0xcbf43926)
        for b in range(4):
            param=(b&1)|((b>>1)<<3)|2|4 # INV; LEFT must do nothing for CRC-32
            m.instr_q=0xe000 | ((64|param)<<4);m.iv=True
            m.step(nop)
            self.assertEqual(m.osr,(0xcbf43926 >> (8*b))&255)

    def test_first_manchester_reference_and_carrier_deadline(self):
        m=LineModel()
        q=dict(cfg=0xb3,period_m1=3,in_msb_first=1,out_msb_first=1)
        m.step(clear=True,**q)
        # The first early edge establishes the rising-clock reference. A later
        # short interval is a boundary, not a new mid-bit; carrier ends at 13.
        sequence=[(0,0)]*6+[(1,0),(1,1),(0,0)]+[(0,0)]*5
        ends=[]
        for i,(level,early) in enumerate(sequence):
            m.step(a_in=level,a_early=early,b_in=1-level,**q)
            if m.frame_end: ends.append(i)
        self.assertEqual(ends,[13])

if __name__=='__main__':unittest.main()
