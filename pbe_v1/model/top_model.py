"""PBE register/FIFO/pin reference, specification: tt_um_pbe header + D50.

The model has separate old-state evaluation and edge commit: host transactions,
engine side effects, synchronizers and FIFO accepts all see pre-edge values.
No RTL is read at runtime. Unwritten memory is deliberately None (unspecified).
"""
from .pbe_model import EngineModel


class FIFO:
    def __init__(self):
        self.mem = [None] * 16
        self.rptr = self.wptr = 0

    @property
    def count(self): return (self.wptr-self.rptr) & 31
    @property
    def empty(self): return self.count == 0
    @property
    def full(self): return self.count == 16
    @property
    def data(self): return self.mem[self.rptr & 15]
    @property
    def contents(self): return [self.mem[(self.rptr+i) & 15] for i in range(self.count)]

    def edge(self, push=False, data=0, pop=False, flush=False):
        # Boundary acceptance uses occupancy before this edge, including simultaneous operations.
        accept_push, accept_pop = push and not self.full, pop and not self.empty
        if accept_push: self.mem[self.wptr & 15] = data
        if flush: self.rptr = self.wptr = 0
        else:
            if accept_push: self.wptr = (self.wptr+1) & 31
            if accept_pop: self.rptr = (self.rptr+1) & 31


class HostSPI:
    """Mode-0 byte framing. Pulses are consumed by the register bus on the next edge.

    Read staging is explicitly two clocks after byte completion (D43 FIFO-pop
    pipeline), and the first following falling edge does not shift a fresh byte.
    """
    def __init__(self):
        self.addr = self.tx = self.rx = self.bits = self.load = self.prev_sck = 0
        self.command = self.write = False
        self.wr = self.rd = None
        self.tx_unknown = 0

    @property
    def miso(self): return None if self.tx_unknown & 128 else self.tx >> 7

    def edge(self, pins, rd_data):
        sck, cs, mosi = pins & 1, (pins >> 1) & 1, (pins >> 2) & 1
        rising, falling = sck and not self.prev_sck, self.prev_sck and not sck
        self.prev_sck = sck
        self.wr = self.rd = None
        if cs:
            self.bits = self.load = self.tx = self.tx_unknown = 0
            self.command = False
            return
        old_bits, old_load = self.bits, self.load
        self.load = (old_load << 1) & 3
        if old_load & 2:
            self.tx = 0 if rd_data is None else rd_data
            self.tx_unknown = 255 if rd_data is None else 0
        if rising:
            self.rx = ((self.rx << 1) | mosi) & 255
            self.bits = (old_bits+1) & 7
            if old_bits == 7:
                if not self.command:
                    self.command = True
                    self.write = bool(self.rx & 128)
                    self.addr = self.rx & 127
                    if not self.write: self.load = 1
                else:
                    if self.write: self.wr = (self.addr, self.rx)
                    else:
                        self.rd = self.addr
                        self.load = 1
                    if self.addr not in (7, 0x16, 0x26): self.addr = (self.addr+1) & 127
        if falling and old_bits:
            self.tx = (self.tx << 1) & 255
            self.tx_unknown = (self.tx_unknown << 1) & 255


class PBEModel:
    def __init__(self):
        self.program = [None] * 128
        self.reset()

    def reset(self):
        retained = [list(f.mem) for f in self.tx+self.rx] if hasattr(self,'tx') else None
        self.engines = [EngineModel(), EngineModel()]
        self.tx, self.rx = [FIFO(), FIFO()], [FIFO(), FIFO()]
        if retained:
            for fifo, memory in zip(self.tx+self.rx,retained): fifo.mem=memory
        self.config = [dict(clkdiv=0,pin_base=0,jmp_pin=0,out_msb_first=0,in_msb_first=0,
                            start_pc=0,crc_poly=0,crc_cfg=0,timeout=0,line_cfg=0,
                            coder_cfg=0,sync=0,crc_good=0) for _ in range(2)]
        self.flag_base = [0, 4]
        self.run = self.flags = self.irq = self.pin_own = self.pm_ptr = 0
        self.host1 = self.host2 = 2
        self.pins1 = self.pins2 = 0
        self.host = HostSPI()
        self.cycle = 0

    @property
    def outputs(self):
        a,b = self.engines
        out = (a.pins_out & ~self.pin_own) | (b.pins_out & self.pin_own)
        oe = (a.pins_oe & ~self.pin_own) | (b.pins_oe & self.pin_own)
        uo = (self.tx[1].full << 7) | (self.tx[0].full << 6) | (not self.rx[1].empty) << 5
        uo |= (not self.rx[0].empty) << 4 | self.run << 2 | bool(self.irq) << 1 | (self.host.miso or 0)
        return out & 255, oe & 255, uo

    def read(self, addr):
        if addr == 0: return self.run
        if addr == 1:
            return sum((f.empty << (e*4+2) | f.full << (e*4+3) |
                        self.rx[e].empty << (e*4) | self.rx[e].full << (e*4+1))
                       for e,f in enumerate(self.tx))
        fixed = {2:self.irq,3:self.pin_own,4:self.flags,5:self.pins2,6:self.pm_ptr,
                 10:self.rx[0].count,11:self.rx[1].count,12:self.tx[0].count,13:self.tx[1].count}
        if addr in fixed: return fixed[addr]
        page, reg = addr >> 4, addr & 15
        if page in (1,2):
            e = page-1; c = self.config[e]; m = self.engines[e]
            values = {0:c['clkdiv'] & 255,1:c['clkdiv'] >> 8,2:c['pin_base'],3:c['jmp_pin'],
                      4:c['out_msb_first'] | c['in_msb_first'] << 1,5:c['start_pc'],
                      6:self.rx[e].data,8:self.flag_base[e],9:m.crc_now & 255,10:m.crc_now >> 8,
                      11:c['crc_cfg'],12:c['timeout'] & 255,13:c['timeout'] >> 8,
                      14:c['line_cfg'],15:m.status}
            return values.get(reg,0)
        if page in (3,4):
            c = self.config[page-3]
            return {0:c['coder_cfg'],1:c['sync'],2:c['crc_good'] & 255,3:c['crc_good'] >> 8}.get(reg,0)
        return 0

    def write(self, addr, data):
        """Commit register state only; edge() handles event ordering and FIFOs."""
        if addr == 0: self.run = data & 3
        elif addr == 2: self.irq &= ~(data & 3)
        elif addr == 3: self.pin_own = data
        elif addr == 4: self.flags = data
        elif addr == 6: self.pm_ptr = data
        elif addr == 7:
            word = self.pm_ptr >> 1
            old = self.program[word]
            old = 0 if old is None else old
            self.program[word] = (old & 0xff00 | data) if self.pm_ptr & 1 else (old & 255 | data << 8)
            self.pm_ptr = (self.pm_ptr+1) & 255
        page, reg = addr >> 4, addr & 15
        if page in (1,2):
            e=page-1; c=self.config[e]
            halves={0:('clkdiv',0),1:('clkdiv',8),9:('crc_poly',0),10:('crc_poly',8),
                    12:('timeout',0),13:('timeout',8)}
            if reg in halves:
                key,shift=halves[reg]; c[key]=(c[key] & ~(255 << shift)) | data << shift
            elif reg in (2,3): c[{2:'pin_base',3:'jmp_pin'}[reg]]=data & 7
            elif reg == 4: c['out_msb_first'],c['in_msb_first']=data & 1,(data >> 1) & 1
            elif reg == 5: c['start_pc']=data & 127
            elif reg == 8: self.flag_base[e]=data & 7
            elif reg in (11,14): c[{11:'crc_cfg',14:'line_cfg'}[reg]]=data
        if page in (3,4):
            c=self.config[page-3]
            if reg in (0,1): c[{0:'coder_cfg',1:'sync'}[reg]]=data
            elif reg in (2,3):
                shift=(reg-2)*8; c['crc_good']=(c['crc_good'] & ~(255 << shift)) | data << shift

    def edge(self, ui=2, pins=0):
        wr,rd=self.host.wr,self.host.rd
        wa,wd=wr if wr else (-1,0)
        rd_data=self.read(self.host.addr)
        signals=[]
        # Engines and FIFOs all observe old register values and old synchronized inputs.
        for e,m in enumerate(self.engines):
            m.configure(**self.config[e])
            f=sum(((self.flags >> ((self.flag_base[e]+n)&7)) & 1) << n for n in range(4))
            clear=wd if wa == 0x1f+16*e else 0
            signals.append(m.step(self.program,pins_in=self.pins2,flags=f,
                tx_data=self.tx[e].data,tx_empty=self.tx[e].empty,rx_full=self.rx[e].full,
                run=bool(self.run & (1 << e)),restart=bool(wa == 0 and wd & (16 << e)),
                pm_wr=wa == 7,host_crc_init=bool(clear & 1),host_tmo_clr=bool(clear & 2),
                host_ovf_clr=bool(clear & 4),host_lerr_clr=bool(clear & 8)))
        sets=wd if wa == 8 else 0; clears=wd if wa == 9 else 0
        for e,s in enumerate(signals):
            for n in range(4):
                sets |= bool(s['flag_set'] & 1 << n) << ((self.flag_base[e]+n)&7)
                clears |= bool(s['flag_clr'] & 1 << n) << ((self.flag_base[e]+n)&7)
            self.irq |= bool(s['irq']) << e
            flush=wa == 0 and bool(wd & (64 << e))
            self.tx[e].edge(push=wa == 0x16+16*e,data=wd,pop=s['tx_pop'],
                            flush=flush or (wa == 14 and bool(wd & 1 << e)))
            self.rx[e].edge(push=s['rx_push'],data=s['rx_data'],pop=rd == 0x16+16*e,flush=flush)
        self.flags=(self.flags | sets) & ~clears & 255
        if wr: self.write(wa,wd)
        for e,m in enumerate(self.engines): m.configure(**self.config[e])
        self.host.edge(self.host2,rd_data)
        self.host2,self.host1=self.host1,ui & 7
        self.pins2,self.pins1=self.pins1,pins
        self.cycle+=1
        return signals

    def state(self):
        return dict(cycle=self.cycle,run=self.run,flags=self.flags,irq=self.irq,
                    engines=[dict(pc=m.pc,instr=m.instr_q,x=m.x,osr=m.osr,isr=m.isr,status=m.status)
                             for m in self.engines],tx=[f.contents for f in self.tx],rx=[f.contents for f in self.rx])
