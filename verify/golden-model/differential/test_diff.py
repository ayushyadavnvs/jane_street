"""Clock-by-clock pin oracle; host stimulus traverses the real SPI port.

Internal RTL reads are diagnostic/final-state checks only. No engine state is
copied to the oracle. Test-only memory initialisation avoids unspecified Xs:
128 NOP words before reset; all subsequent program writes use the host pins.
"""
import json
import os
from pathlib import Path
import random
from collections import Counter
import cocotb
from cocotb.triggers import Timer
from model.top_model import PBEModel

ROOT=Path(__file__).resolve().parents[3]/'pbe_v1'


def word(op,arg=0,dly=0): return op << 13 | (arg & 511) << 4 | dly


def random_program(rng):
    result=[]
    for i in range(63):
        op=rng.randrange(8); dly=rng.choice([0,0,0,1,2,rng.randrange(16)])
        if op == 0: arg=rng.randrange(8) << 6 | rng.randrange(8) << 3 | rng.randrange(2)
        elif op == 1: arg=rng.randrange(8) << 6 | rng.randrange(2) << 5
        elif op == 2: arg=rng.randrange(8) << 6 | rng.randrange(2) << 5 | rng.randrange(4) << 3
        elif op in (3,7): arg=rng.randrange(8) << 6 | rng.randrange(64)
        elif op == 4: arg=rng.randrange(512)
        elif op == 5: arg=rng.randrange(2) << 8
        else: arg=rng.randrange(4) << 7 | rng.randrange(64)
        result.append(word(op,arg,dly))
    result.append(word(3,0))
    return result

def coverage_program():
    """Bounded sequential prelude; branches target the next word.

    Pin WAITs see independent random inputs. Flag levels are set explicitly;
    random campaigns also exercise flag edges through host writes.
    """
    p=[]
    def add(op,arg=0): p.append(word(op,arg))
    for act in range(8): add(0,act << 3)
    add(1,0)
    add(4,1); add(4,256 | 0xa5)
    for action in range(4): add(6,action << 7)
    for dst in range(1,4):
        for src in range(4): add(6,384 | dst << 4 | src << 2)
    add(5,0); add(5,256)
    for sub in range(8): add(7,sub << 6 | len(p)+1 if sub in (3,4,5,6) else sub << 6)
    for cond in range(8): add(3,cond << 6 | len(p)+1)
    for cond in range(4): add(2,cond << 3)
    # Level waits on flags, each made ready by an instruction ahead of it.
    add(6,128); add(2,32); add(6,0); add(2,32 | 8)
    add(3,0)
    return (p+[word(6,384)]*64)[:64]


class Harness:
    def __init__(self,dut,seed):
        self.dut=dut; self.model=PBEModel(); self.seed=seed
        self.rng=random.Random(seed); self.ui=2; self.pins=0
        self.random_pins=False
        self.history=[]; self.coverage=Counter(); self.clocks=0

    async def reset(self):
        d=self.dut
        d.clk.value=0; d.rst_n.value=0; d.ui_in.value=2; d.uio_in.value=0; d.ena.value=1
        for i in range(128):
            d.pmem[i].value=0xd800
            self.model.program[i]=0xd800
        for _ in range(3):
            await Timer(10416,unit='ps'); d.clk.value=1
            await Timer(10416,unit='ps'); d.clk.value=0
        d.rst_n.value=1
        await self.step()

    def rtl_state(self):
        d=self.dut
        es=[]
        for i in range(2):
            e=d.g_eng[i].u_eng
            es.append({k:str(getattr(e,k).value) for k in
                       ('pc','instr_q','iv','div_cnt','dly_cnt','blocked','x','osr','isr','pout','poe')})
        return dict(engines=es,flags=str(d.flags.value),irq=str(d.irq_pend.value))

    def mismatch(self,why):
        payload=dict(seed=self.seed,cycle=self.clocks,reason=why,
                     model=self.model.state(),rtl=self.rtl_state(),last_stimulus=self.history[-64:])
        out=ROOT/'build'/'differential'/f'failure-{self.seed}.json'
        out.parent.mkdir(parents=True,exist_ok=True); out.write_text(json.dumps(payload,indent=2))
        raise AssertionError(json.dumps(payload,indent=2))

    async def step(self,ui=None,pins=None):
        if ui is not None: self.ui=ui
        if pins is not None: self.pins=pins
        elif self.random_pins: self.pins=self.rng.randrange(256)
        d=self.dut; d.clk.value=0; d.ui_in.value=self.ui; d.uio_in.value=self.pins
        await Timer(10416,unit='ps')
        self.history.append([self.ui,self.pins])
        effects=self.model.edge(self.ui,self.pins)
        for ef in effects:
            if ef['execute']:
                ins=ef['instruction']; op=ins >> 13; arg=ins >> 4 & 511
                self.coverage[f'op:{op}']+=1
                if op in (0,2,3,5,6,7):
                    sub={0:arg >> 3 & 7,2:arg >> 3 & 3,3:arg >> 6,
                         5:arg >> 8,6:arg >> 7,7:arg >> 6}[op]
                    self.coverage[f'sub:{op}:{sub}']+=1
        d.clk.value=1
        await Timer(10416,unit='ps')
        self.clocks+=1
        uo=str(d.uo_out.value)
        # An empty RX FIFO can be speculatively prefetched after its last byte.
        # Preserve that single unknown MISO bit; all other bits still compare.
        expected_unknown=self.model.host.miso is None
        if expected_unknown and uo[-1].lower() not in ('x','z'): self.mismatch('expected unspecified empty-FIFO MISO')
        actual=(int(d.uio_out.value),int(d.uio_oe.value),int(uo[:-1]+'0',2) if expected_unknown else int(uo,2))
        expected=self.model.outputs
        if actual != expected: self.mismatch(f'outputs actual={actual}, expected={expected}')
        # Catch silent divergences before a late visible symptom.
        if int(d.flags.value) != self.model.flags: self.mismatch('flags')
        if int(d.run.value) != self.model.run: self.mismatch('run')
        d.clk.value=0

    async def clocks_wait(self,n):
        for _ in range(n): await self.step()

    async def transfer(self,byte):
        rx=0
        for bit in range(7,-1,-1):
            self.ui=(byte >> bit & 1) << 2
            for _ in range(4): await self.step()
            bit_value=str(self.dut.uo_out.value)[-1]
            rx=rx << 1 | (int(bit_value) if bit_value in '01' else 0)
            self.ui |= 1
            for _ in range(4): await self.step()
        return rx

    async def host(self,addr,data=None,count=1):
        self.ui=0; await self.clocks_wait(4)
        await self.transfer(addr | (128 if data is not None else 0))
        values=[]
        for b in data if data is not None else [0]*count:
            values.append(await self.transfer(b))
        self.ui=2; await self.clocks_wait(5)
        return values

    async def write(self,addr,data): await self.host(addr,[data] if isinstance(data,int) else data)

    async def setup(self,programs,divs=(0,1),timeout=3):
        # Real SPI loading and all configuration share the same edge oracle.
        await self.write(6,0)
        await self.write(7,[b for prog in programs for w in prog for b in (w >> 8,w & 255)])
        await self.write(3,0xf0)
        for e in range(2):
            a=0x10+16*e
            await self.write(a,[divs[e],0,e*4,self.rng.randrange(8),self.rng.randrange(4),e*64])
            await self.write(a+8,self.rng.randrange(8))
            await self.write(a+9,[5,128,0xff,timeout,0,0x40 | self.rng.randrange(64)])
            await self.write(a+6,[self.rng.randrange(256) for _ in range(16)])
        await self.write(0,0x33)

    def check_final(self):
        d=self.dut; m=self.model
        for e in range(2):
            for key,model_fifo in (('u_txf',m.tx[e]),('u_rxf',m.rx[e])):
                f=getattr(d.g_eng[e],key)
                if int(f.count.value) != model_fifo.count: self.mismatch(f'{e} {key} count')
                ptr=int(f.rptr.value)
                actual=[int(f.mem[(ptr+i)&15].value) for i in range(model_fifo.count)]
                if actual != model_fifo.contents: self.mismatch(f'{e} {key} contents')
            status=int(d.g_eng[e].u_eng.status.value)
            if status != m.engines[e].status: self.mismatch(f'{e} status {status} != {m.engines[e].status}')
            crc=int(d.g_eng[e].u_eng.crc_now.value)
            if crc != m.engines[e].crc_now: self.mismatch(f'{e} CRC')
        for addr in (0,1,2,3,4,5,6,10,11,12,13,0x1f,0x2f):
            # read() is separately exercised via host below; this checks end-state oracle availability.
            assert m.read(addr) is not None


@cocotb.test()
async def random_differential(dut):
    seed=int(os.getenv('PBE_SEED','5259845')); n=int(os.getenv('PBE_N','4'))
    cycles=int(os.getenv('PBE_CYCLES','1200')); coverage=Counter(); clocks=0
    retained_fifos=None
    for index in range(n):
        h=Harness(dut,seed+index)
        if retained_fifos:
            for f,mem in zip(h.model.tx+h.model.rx,retained_fifos): f.mem=list(mem)
        await h.reset()
        programs=[random_program(h.rng),random_program(h.rng)]
        if index == 0: programs[0]=coverage_program()
        divs=(index%2,h.rng.choice([0,1,2,3,7,15]))
        await h.setup(programs,divs,timeout=h.rng.choice([0,1,3,7]))
        h.random_pins=True
        # Host operations interleave random pin changes on every clock. The
        # seeded schedule includes streaming FIFO traffic, readback, flags,
        # restarts and running memory writes; no observation steers the model.
        for t in range(cycles):
            if t%113 == 0:
                kind=h.rng.randrange(8); e=h.rng.randrange(2)
                if kind == 0: await h.write(0x16+16*e,h.rng.randrange(256))
                elif kind in (1,2): await h.write(8 if kind == 1 else 9,h.rng.randrange(256))
                elif kind == 3: await h.write(0,3 | 16 << e)
                elif kind == 4:
                    await h.write(6,h.rng.randrange(256)); await h.write(7,h.rng.randrange(256))
                elif kind == 5: await h.write(0x1f+16*e,h.rng.randrange(16))
                elif kind == 6:
                    if h.model.rx[e].count: await h.host(0x16+16*e,count=1)
                else: await h.host(h.rng.choice([0,1,2,4,10,11,12,13]))
            await h.step(pins=h.rng.randrange(256))
        # Stop both engines, then test status/flags/count/config reads through pins.
        await h.write(0,0)
        for addr in (0,1,2,3,4,6,10,11,12,13,0x1f,0x2f):
            expected=h.model.read(addr); actual=(await h.host(addr))[0]
            if actual != expected: h.mismatch(f'register {addr:02x}: {actual} != {expected}')
        h.check_final(); coverage.update(h.coverage); clocks+=h.clocks
        retained_fifos=[list(f.mem) for f in h.model.tx+h.model.rx]
    report=dict(seed=seed,seeds=n,clocks=clocks,coverage=dict(sorted(coverage.items())))
    out=ROOT/'build'/'differential'/'coverage.json'; out.write_text(json.dumps(report,indent=2))
    dut._log.info('DIFFERENTIAL %s',json.dumps(report,sort_keys=True))
