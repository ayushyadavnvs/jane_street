"""Pin-only asynchronous quad host; programs/configuration use the public registers."""
import importlib.util
import random
from pathlib import Path
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge,Timer,Lock
from cocotb.utils import get_sim_time
ROOT=Path(__file__).resolve().parents[2]
PERIOD_PS=16668
spec=importlib.util.spec_from_file_location('asm',ROOT/'pbe_v1/tools/pbe_asm.py')
asm=importlib.util.module_from_spec(spec);spec.loader.exec_module(asm)

class Records:
    def __init__(self):self.pending=bytearray();self.escape=False;self.frames=[]
    def feed(self,values):
        for b in values:
            if self.escape:
                if b==0x7e:self.pending.append(b)
                else:self.frames.append((bytes(self.pending),b));self.pending.clear()
                self.escape=False
            elif b==0x7e:self.escape=True
            else:self.pending.append(b)

class Host:
    def __init__(self,d,seed=0x455448):
        self.d=d;self.ui=2;self.quad=False;self.lock=Lock()
        self.rng=random.Random(seed);self.phase_ps=0;self.jitter_ps=0;self.symmetric=False
        self.rx=[[],[]];self.records=Records();self.reader_on=False
        self.half_durations=[]
    async def delay(self,clocks):await Timer(round(clocks*PERIOD_PS),unit='ps')
    async def start(self):
        cocotb.start_soon(Clock(self.d.clk,PERIOD_PS,unit='ps').start())
        await self.reset()
    async def reset(self):
        self.ui=2;self.quad=False;self.d.ui_in.value=2;self.d.rst_n.value=0
        self.d.incoming.value=0;self.d.loopback.value=0;self.d.hdlc.value=0
        self.rx=[[],[]];self.records=Records();self.half_durations=[]
        for _ in range(8):await FallingEdge(self.d.clk)
        self.d.rst_n.value=1
        await self.delay(8)
        if self.phase_ps:await Timer(self.phase_ps,unit='ps')
    def bit(self,index):return int(self.d.uo_out.value[index])
    async def half(self):
        delta=self.rng.randint(-self.jitter_ps if self.symmetric else 0,self.jitter_ps)
        delay=4*PERIOD_PS+delta
        assert delay>0
        self.half_durations.append(delay)
        await Timer(delay,unit='ps')
    async def cs(self,high):
        await self.delay(3)
        self.ui=(self.ui&~2)|(int(high)<<1);self.d.ui_in.value=self.ui
        await self.delay(3)
    async def byte(self,value,sample=False):
        width=4 if self.quad else 1;answer=0
        for shift in range(8-width,-1,-width):
            self.ui=(self.ui&0xc2)|(((value>>shift)&((1<<width)-1))<<2)
            self.d.ui_in.value=self.ui
            await self.half()
            if sample:
                chars=str(self.d.uo_out.value)[-width:]
                if any(c not in '01' for c in chars):raise AssertionError('unknown host read sample '+chars)
                answer=(answer<<width)|int(chars,2)
            self.ui|=1;self.d.ui_in.value=self.ui
            await self.half()
            self.ui&=~1;self.d.ui_in.value=self.ui
        return answer
    async def write(self,addr,*data):
        async with self.lock:
            await self.cs(0);await self.byte(128|addr)
            for b in data:await self.byte(b)
            await self.cs(1)
    async def read(self,addr,count=1):
        async with self.lock:
            await self.cs(0);await self.byte(addr)
            result=[await self.byte(0,sample=True) for _ in range(count)]
            await self.cs(1)
            return result if count!=1 else result[0]
    async def quad_on(self):
        await self.write(0x50,1);self.quad=True
        assert await self.read(0x50)==1
    async def load(self,names):
        await self.write(0,0xc0)
        for engine,name in enumerate(names):
            program,_,_=asm.assemble((ROOT/'pbe_v1/programs'/f'{name}.pbe').read_text(),0,name)
            assert len(program)<=256
            words=program+[0xd800]*(256-len(program))
            await self.write(15,engine<<1);await self.write(6,0)
            await self.write(7,*[b for w in words for b in (w>>8,w&255)])
    async def ethernet(self):
        await self.quad_on();await self.load(('eth_tx','eth_rx'))
        await self.write(3,0xfc)
        for e in range(2):
            a=0x10+16*e;p=0x30+16*e
            await self.write(a,5,0,e*2,0,0,0)
            await self.write(a+9,0xb7,0x1d,0x7f if e==0 else 0xbf)
            await self.write(p+8,0xc1,4)
            await self.write(p+12,1)
            await self.write(a+12,*((0x60,0xea,0x41) if e==0 else (0,0,0x40)))
            await self.write(p,0x33 if e==0 else 0x23,0 if e==0 else 0xd5)
        await self.write(0x42,0x7b,0xdd)
        await self.write(0x4a,4,0xc7)
        assert await self.read(0x12)==0 and await self.read(0x22)==2
        assert await self.read(0x30)==0x33 and await self.read(0x40)==0x23
        await self.write(0,0x33)
    async def hdlc_config(self,period=48,nrzi=True):
        await self.quad_on();await self.load(('hdlc_tx','hdlc_rx'))
        self.d.hdlc.value=1;self.d.incoming.value=1
        await self.write(3,0xfc)
        for e in range(2):
            a=0x10+16*e;p=0x30+16*e
            await self.write(a,(period-1)&255,(period-1)>>8,e*2,0,0,0)
            await self.write(a+9,0x21,0x10,0x7f if e==0 else 0x9f)
            await self.write(a+12,0,0,0x40)
            await self.write(p,(0x0a if nrzi else 0x09)|(0x40 if e else 0),0)
        await self.write(0x42,0xf9,0xd0)
        await self.write(0,0x33)
    async def reader(self):
        self.reader_on=True
        while self.reader_on:
            for e in (1,0):
                if self.bit(4+e):
                    count=await self.read(0x0a+e)
                    assert 0<=count<=16
                    if count:
                        values=await self.read(0x16+16*e,count=count)
                        if isinstance(values,int):values=[values]
                        self.rx[e].extend(values)
                        if e:self.records.feed(values)
            await self.delay(2)
    async def send_stream(self,stream,burst=12,pause_after=None,pause_us=0):
        at=0;paused=False;deadline=get_sim_time(unit="us")+len(stream)*3+3000
        while at<len(stream):
            assert get_sim_time(unit="us")<deadline,("TX FIFO progress timeout",at,len(stream),self.rx[0])
            if pause_after is not None and at>=pause_after and not paused:
                await Timer(round(pause_us*1e6),unit='ps');paused=True
            if self.bit(6):await self.delay(8);continue
            async with self.lock:
                await self.cs(0);await self.byte(0x96)
                for _ in range(min(burst,len(stream)-at)):
                    await self.delay(2)
                    if self.bit(6):break
                    await self.byte(stream[at]);at+=1
                    if pause_after is not None and at==pause_after and not paused:break
                await self.cs(1)
    async def stop_reader(self,task):
        self.reader_on=False;await task
