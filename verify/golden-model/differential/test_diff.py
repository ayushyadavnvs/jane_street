"""Clock-by-clock pin oracle; host stimulus traverses the real SPI port.

Internal RTL reads are diagnostic/final-state checks only. No engine state is
copied to the oracle. Test-only memory initialisation avoids unspecified Xs:
NOP in all 2 x 256 words of the SRAM models (D82) before reset; all subsequent
program writes use the host pins.
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


def output_path(filename):
    return Path(os.getenv('PBE_DIFF_OUTPUT_DIR',str(ROOT/'build'/'differential')))/filename


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
        # D83: often a PAGE p just before a jump, so jumps reach the other pages of the memory
        if len(result) < 62 and (op == 3 or op == 7 and arg >> 6 in (3,4,5,6)) and rng.random() < .4:
            result.insert(-1,word(7,7 << 6 | 32 | rng.randrange(4),rng.choice([0,0,1])))
    result=result[:63]
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
        self.quad_mode=False
        self.ethernet=os.getenv('PBE_ETHERNET') == '1'
        self.history=[]; self.coverage=Counter(); self.clocks=0

    async def reset(self):
        d=self.dut
        d.clk.value=0; d.rst_n.value=0; d.ui_in.value=2; d.uio_in.value=0; d.ena.value=1
        # each engine's IHP SRAM model (pbe_pmem_sram: u_sram0, u_sram1)
        for e,inst in enumerate((d.u_pmem.u_sram0,d.u_pmem.u_sram1)):
            mem=inst.i_SRAM_1P_behavioral_bm_bist.memory
            for i in range(256):
                mem[i].value=0xd800
                self.model.program[e*256+i]=0xd800
        for _ in range(3):
            await Timer(8334 if self.ethernet else 10416,unit='ps'); d.clk.value=1
            await Timer(8334 if self.ethernet else 10416,unit='ps'); d.clk.value=0
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
        out=output_path(f'failure-{self.seed}.json')
        out.parent.mkdir(parents=True,exist_ok=True); out.write_text(json.dumps(payload,indent=2))
        raise AssertionError(json.dumps(payload,indent=2))

    async def step(self,ui=None,pins=None):
        old_pins=self.pins
        if ui is not None: self.ui=ui
        if pins is not None: self.pins=pins
        elif self.random_pins: self.pins=self.rng.randrange(256)
        d=self.dut; d.clk.value=0; d.ui_in.value=self.ui; d.uio_in.value=self.pins
        if self.ethernet:
            falling = old_pins if self.random_pins and self.rng.getrandbits(1) else self.pins
            d.uio_in.value=falling
            self.model.sample_falling(falling)
            await Timer(4167,unit='ps')
            d.uio_in.value=self.pins
            await Timer(4167,unit='ps')
        else:
            await Timer(10416,unit='ps')
        self.history.append([self.ui,self.pins])
        effects=self.model.edge(self.ui,self.pins)
        for ef in effects:
            if ef['execute']:
                ins=ef['instruction']; op=ins >> 13; arg=ins >> 4 & 511
                self.coverage[f'op:{op}']+=1
                if self.ethernet:
                    for m in self.model.engines:
                        c=m.config
                        width=1+(c['crc_cfg']&15)+16*c['crc_wide']
                        self.coverage[f'crc_executed_width_{width}']+=1
                        self.coverage[f'line_executed_mode_{c["coder_cfg"]&3}']+=1
                    if op==7 and arg >> 6==1:
                        self.coverage[f'osrcrc_param_{arg&15}']+=1
                    if op==7 and arg >> 6==7 and arg&16:
                        self.coverage[f'linectl_action_{arg&3}']+=1
                if op in (0,2,3,5,6,7):
                    sub={0:arg >> 3 & 7,2:arg >> 3 & 3,3:arg >> 6,
                         5:arg >> 8,6:arg >> 7,7:arg >> 6}[op]
                    self.coverage[f'sub:{op}:{sub}']+=1
        d.clk.value=1
        await Timer(8334 if self.ethernet else 10416,unit='ps')
        self.clocks+=1
        uo=str(d.uo_out.value)
        # An empty RX FIFO can be speculatively prefetched after its last byte.
        # Icarus must preserve that unknown MISO. Verilator is two-state, so
        # mask only this model-marked unspecified bit; all known bits compare.
        unknown = self.model.unknown_outputs
        bits = uo.lower()
        if os.getenv('PBE_TWO_STATE') != '1':
            observed_unknown = sum((ch in 'xz') << i for i,ch in enumerate(reversed(bits)))
            if observed_unknown != unknown:
                self.mismatch(f'unspecified host outputs: {observed_unknown:#x} != {unknown:#x}')
        value = int(''.join('0' if ch in 'xz' else ch for ch in bits), 2) & ~unknown
        actual=(int(d.uio_out.value),int(d.uio_oe.value),value)
        expected=self.model.outputs
        if actual != expected: self.mismatch(f'outputs actual={actual}, expected={expected}')
        if os.getenv('PBE_DIAGNOSTIC_LINE') == '1':
            for i,e in enumerate(self.model.engines):
                r=d.g_eng[i].u_eng
                if int(r.l_err.value) != e.line.err:
                    self.mismatch('diagnostic coder error '+str(dict(engine=i,model=vars(e.line),
                      config=e.config,rtl={k:str(getattr(r.u_line,k).value) for k in
                       ('ts','tcnt','q_valid','q_end','tbits','tstuff','rs','rcnt','mcnt','m_thr','a_d','rbits','rx_valid','err')})))
        # Catch silent divergences before a late visible symptom.
        if int(d.flags.value) != self.model.flags: self.mismatch('flags')
        if int(d.run.value) != self.model.run: self.mismatch('run')
        d.clk.value=0

    async def clocks_wait(self,n):
        for _ in range(n): await self.step()

    async def transfer(self,byte):
        rx=0;expected_rx=0
        if self.ethernet:
            self.coverage['host_quad_bytes' if self.quad_mode else 'host_single_bytes']+=1
        width = 4 if self.quad_mode else 1
        for bit in range(8-width,-1,-width):
            self.ui=((byte >> bit) & ((1 << width)-1)) << 2
            for _ in range(4): await self.step()
            chars=str(self.dut.uo_out.value)[-width:]
            sampled=int(''.join(ch if ch in '01' else '0' for ch in chars),2)
            rx=(rx << width) | sampled
            expected_rx=(expected_rx << width) | (self.model.outputs[2]&((1<<width)-1))
            self.ui |= 1
            for _ in range(4): await self.step()
        self.last_transfer_expected=expected_rx
        return rx

    async def host(self,addr,data=None,count=1):
        self.ui=0; await self.clocks_wait(4)
        await self.transfer(addr | (128 if data is not None else 0))
        values=[];expected_values=[]
        for b in data if data is not None else [0]*count:
            values.append(await self.transfer(b))
            expected_values.append(self.last_transfer_expected)
        self.ui=2; await self.clocks_wait(5)
        self.last_host_expected=expected_values
        return values

    async def write(self,addr,data): await self.host(addr,[data] if isinstance(data,int) else data)

    async def set_quad(self, enabled):
        await self.write(0x50, int(enabled))
        self.quad_mode = bool(enabled)
        if self.ethernet:
            actual=(await self.host(0x50))[0]
            if actual != int(enabled):self.mismatch('HOSTCFG mode readback')
            self.coverage['host_enter_quad' if enabled else 'host_leave_quad']+=1

    async def idle_exit(self):
        for _ in range(8):
            self.ui=2; await self.clocks_wait(4)
            self.ui=3; await self.clocks_wait(4)
        self.ui=2; await self.clocks_wait(6)
        self.quad_mode=False
        if self.ethernet:
            actual=(await self.host(0x50))[0]
            if actual != 0:self.mismatch('eight idle SCK edges did not clear HOSTCFG')
            self.coverage['host_exit_idle_sck']+=1

    async def setup(self,programs,divs=(0,1),timeout=3,bases=(0,0)):
        # Real SPI loading and all configuration share the same edge oracle. Each engine's
        # program goes into its own memory (D82) at its START_PC, bases[e].
        for e,prog in enumerate(programs):
            await self.write(15,e << 1 | bases[e] >> 7)
            await self.write(6,(bases[e] & 127) << 1)
            await self.write(7,[b for w in prog for b in (w >> 8,w & 255)])
        await self.write(3,0xf0)
        for e in range(2):
            a=0x10+16*e
            await self.write(a,[divs[e],0,e*4,self.rng.randrange(8),self.rng.randrange(4),bases[e]])
            await self.write(a+8,self.rng.randrange(8))
            await self.write(a+9,[5,128,0xff,timeout,0,0x40 | self.rng.randrange(64)])
            await self.write(a+6,[self.rng.randrange(256) for _ in range(16)])
        if self.ethernet:
            for e in range(2):
                width,poly=self.rng.choice(((17,0x1685b),(21,0x102899),(24,0x864cfb),(32,0x04c11db7)))
                a=0x10+16*e; p=0x30+16*e
                await self.write(a+9,[poly & 255,(poly >> 8)&255,0xf0|((width-1)&15)])
                await self.write(p+8,[(poly >> 16)&255,(poly >> 24)&255])
                await self.write(p+10,[self.rng.randrange(256),self.rng.randrange(256),1])
                line=self.rng.choice((0,3,0x23,0x93,0xb3,0x09,0x49,0x4a,0x29,0x69))
                await self.write(a,[max(3,divs[e]),0])
                await self.write(p,line)
                await self.write(p+1,self.rng.choice((0,0xd5)) if line & 3 == 3 else 0)
                await self.write(p+4,self.rng.choice((0,0x40)) if line & 3 == 3 else 0)
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
    start_index=int(os.getenv('PBE_START_INDEX','0'))
    for index in range(start_index,start_index+n):
        h=Harness(dut,seed+index)
        if retained_fifos:
            for f,mem in zip(h.model.tx+h.model.rx,retained_fifos): f.mem=list(mem)
        await h.reset()
        if h.ethernet and index % 2 == 0: await h.set_quad(True)
        programs=[random_program(h.rng),random_program(h.rng)]
        if index == 0: programs[0]=coverage_program()
        divs=(index%2,h.rng.choice([0,1,2,3,7,15]))
        # START_PCs from the whole 256-word memory, 192 putting a program's end at word 255
        bases=(h.rng.choice([0,64,128,192]),h.rng.choice([0,64,128,192]))
        await h.setup(programs,divs,timeout=h.rng.choice([0,1,3,7]),bases=bases)
        h.random_pins=True
        # Host operations interleave random pin changes on every clock. The
        # seeded schedule includes streaming FIFO traffic, readback, flags,
        # restarts and running memory writes; no observation steers the model.
        for t in range(cycles):
            if h.ethernet and t%157 == 0:
                if h.rng.randrange(3) == 0: await h.idle_exit()
                else: await h.set_quad(not h.quad_mode)
            if t%113 == 0:
                kind=h.rng.randrange(8); e=h.rng.randrange(2)
                if kind == 0: await h.write(0x16+16*e,h.rng.randrange(256))
                elif kind in (1,2): await h.write(8 if kind == 1 else 9,h.rng.randrange(256))
                elif kind == 3: await h.write(0,3 | 16 << e)
                elif kind == 4:
                    await h.write(15,h.rng.randrange(4)); await h.write(6,h.rng.randrange(256))
                    await h.write(7,h.rng.randrange(256))
                elif kind == 5: await h.write(0x1f+16*e,h.rng.randrange(16))
                elif kind == 6:
                    if h.model.rx[e].count: await h.host(0x16+16*e,count=1)
                else: await h.host(h.rng.choice([0,1,2,4,10,11,12,13]))
            await h.step(pins=h.rng.randrange(256))
        # Stop both engines, then test status/flags/count/config reads through pins.
        await h.write(0,0)
        for addr in (0,1,2,3,4,6,10,11,12,13,15,0x15,0x25,0x1f,0x2f):
            actual=(await h.host(addr))[0];expected=h.last_host_expected[0]
            if actual != expected: h.mismatch(f'register {addr:02x}: {actual} != {expected}')
        h.check_final(); coverage.update(h.coverage); clocks+=h.clocks
        retained_fifos=[list(f.mem) for f in h.model.tx+h.model.rx]
        output_path('progress.json').write_text(json.dumps(dict(completed=index-start_index+1,index=index,seed=seed+index,clocks=clocks)))
    report=dict(seed=seed,seeds=n,clocks=clocks,coverage=dict(sorted(coverage.items())))
    if os.getenv('PBE_ETHERNET') == '1': report['profile']='ethernet'
    out=output_path('coverage.json'); out.write_text(json.dumps(report,indent=2))
    dut._log.info('DIFFERENTIAL %s',json.dumps(report,sort_keys=True))
