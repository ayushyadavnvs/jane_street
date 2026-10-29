"""Pin-only stress observations; exact bytes/status, finite caller deadlines."""
import json
import os
from pathlib import Path
import random
import sys
from types import SimpleNamespace

import cocotb
from cocotb.triggers import Timer, with_timeout, FallingEdge

ROOT=Path(os.environ['PBE_ROOT'])
sys.path.insert(0,str(ROOT/'pbe_v1/test/bus_models'))
from test_buses import Chip,PERIOD_PS,HZ,BytePeripheral,UartSink

SEED=int(os.environ['PBE_STRESS_SEED'])
OUTPUT=Path(os.environ['PBE_STRESS_OUTPUT'])
REQUIRED_ONLY=os.getenv('PBE_STRESS_REQUIRED_ONLY')=='1'
BIT_CLOCKS=96


async def uart_wave(c,data,*,error=0,jitter=0,rise_delay_clocks=0,idle_glitch=False,data_glitch=False):
    """Digital threshold timing only: delayed 0->1 events are not analog ramps."""
    r=random.Random(f'{SEED}/wave/{error}/{jitter}/{rise_delay_clocks}/{data.hex()}')
    nominal=BIT_CLOCKS*PERIOD_PS/(1+error)
    c.d.ext0.value=1
    await Timer(round(nominal*3),unit='ps')
    if idle_glitch:
        c.d.ext0.value=0
        await Timer(PERIOD_PS,unit='ps')
        c.d.ext0.value=1
        await Timer(round(nominal*3),unit='ps')
    previous=1
    for char,value in enumerate(data):
        bits=[0]+[(value>>i)&1 for i in range(8)]+[1]*3
        for index,bit in enumerate(bits):
            duration=round(nominal*(1+r.uniform(-jitter,jitter)))
            delay=rise_delay_clocks*PERIOD_PS if bit and not previous else 0
            if delay:
                await Timer(delay,unit='ps')
            c.d.ext0.value=bit
            remaining=duration-delay
            # A pulse around a nominal data sample, lasting exactly one chip
            # clock. No assumption that the synchronizer filters this pulse.
            if data_glitch and char==0 and index==4:
                before=remaining//2
                await Timer(before,unit='ps');c.d.ext0.value=1-bit
                await Timer(PERIOD_PS,unit='ps');c.d.ext0.value=bit
                await Timer(remaining-before-PERIOD_PS,unit='ps')
            else:
                await Timer(remaining,unit='ps')
            previous=bit
    c.d.ext0.value=1
    await Timer(round(nominal*3),unit='ps')


async def drain(c,*,pause_ps=0):
    got=[]
    # Each read is count-qualified. Allow a blocked PUSH to refill the FIFO
    # after a pop, then require two empty observations, with finite limits.
    empty=0
    for _ in range(40):
        count=await c.read(0x0a)
        if not count:
            empty+=1
            if empty==2:break
            await c.cycles(BIT_CLOCKS*4)
        else:
            empty=0
            for _ in range(count):
                got.append(await c.read(0x16))
                if pause_ps:await Timer(pause_ps,unit='ps')
    return bytes(got)


async def start_rx(c):
    await c.load(('uart_rx',0))
    await c.config(div=BIT_CLOCKS//4-1,shift=0)
    await c.write(0,0x11)
    await c.cycles(BIT_CLOCKS*3)


@cocotb.test(timeout_time=200,timeout_unit="ms")
async def pin_stress(d):
    c=Chip(d);await c.init()
    rows=[]
    payload=bytes.fromhex('00 ff 55 aa 81 7e 03 c0')

    def record(name,required,ok,**details):
        row={'case':name,'required':required,'status':'PASS' if ok else 'FAIL',**details}
        rows.append(row)
        OUTPUT.parent.mkdir(parents=True,exist_ok=True)
        OUTPUT.write_text(json.dumps({'seed':SEED,'cases':rows},indent=2)+'\n')
        d._log.info('STRESS %s %s',row['status'],name)

    scenarios=[('clock_minus2',True,dict(error=-.02)),('clock_plus2',True,dict(error=.02)),
               ('clock_minus2_jitter2',True,dict(error=-.02,jitter=.02)),
               ('clock_plus2_jitter2',True,dict(error=.02,jitter=.02)),
               ('digital_rise_delay4',True,dict(rise_delay_clocks=4)),
               ('idle_glitch_1clock',True,dict(idle_glitch=True)),
               ('data_glitch_1clock',False,dict(data_glitch=True))]
    for magnitude in (.03,.04,.05,.06,.08):
        for sign in (-1,1):scenarios.append((f'clock_{sign*magnitude:+.0%}',False,dict(error=sign*magnitude)))
    for name,required,settings in scenarios:
        if REQUIRED_ONLY and not required:continue
        await start_rx(c)
        await uart_wave(c,payload,**settings)
        await Timer(BIT_CLOCKS*PERIOD_PS*14,unit='ps')
        got=await drain(c)
        status=await c.read(0x1f);irq=await c.read(2)
        record('uart_rx_'+name,required,got==payload,settings=settings,
               expected=payload.hex(),actual=got.hex(),engine_status=status,irq=irq,
               deadline='none; waveform and bounded drain completed')

    # Independent third-party UART sink at offset baud samples the PBE TX pins.
    for error in (-.02,.02):
        await c.load(('uart_tx',0));await c.config(div=BIT_CLOCKS//2-1,shift=0)
        sink=UartSink(d.sda,baud=HZ/BIT_CLOCKS*(1+error),bits=8)
        await c.write(0,0x11)
        await c.write(0x16,*payload)
        await Timer((len(payload)+2)*14*BIT_CLOCKS*PERIOD_PS,unit='ps')
        deadline=None
        try:got=bytes(await with_timeout(sink.read(len(payload)),1,'ms'))
        except Exception as exc:
            got=b'';deadline=f'caller sink read deadline/exception: {type(exc).__name__}: {exc}'
        record(f'uart_tx_clock_{error:+.0%}',True,got==payload,
               expected=payload.hex(),actual=got.hex(),error=error,deadline=deadline)
        sink._run_cr.cancel()

    for size in (16,20):
        await start_rx(c)
        data=bytes(range(size))
        await uart_wave(c,data)
        await Timer(1,unit='ms')  # no host RX service for the entire burst +1ms
        before_count=await c.read(0x0a);before_status=await c.read(0x1f);irq=await c.read(2)
        got=await drain(c,pause_ps=BIT_CLOCKS*PERIOD_PS*100)
        expected=data if size==16 else data[:17]
        overflow=bool(before_status&8)
        okay=got==expected and before_count==16 and overflow==(size==20)
        if size==20:okay=okay and bool(irq&1)
        # Prove execution resumes after draining; no reset/restart needed.
        await uart_wave(c,b'\x42');await Timer(14*BIT_CLOCKS*PERIOD_PS,unit='ps')
        recovery=await drain(c)
        okay=okay and recovery==b'\x42'
        record(f'uart_rx_slow_host_{size}',True,okay,expected=expected.hex(),actual=got.hex(),
               offered=data.hex(),initial_rx_count=before_count,engine_status=before_status,
               irq=irq,initial_no_read_us=1000,per_byte_read_pause_bits=100,
               lost_input_bytes=size-len(got),recovery=recovery.hex(),
               classification='documented sticky overflow + blocked PUSH' if size==20 else 'lossless at FIFO capacity')

    # Two real protocol programs, disjoint pin ownership; each round restarts
    # both engines after the preceding complete transfers have reached idle.
    await c.load(('uart_tx',0),('spi_ctrl',64))
    await c.write(3,0xf0)
    await c.config(div=BIT_CLOCKS//2-1,shift=0)
    await c.config(e=1,div=7,base=4,shift=3,start=64)
    r=random.Random(f'{SEED}/concurrency')
    for round_index in range(12):
        uart=bytes(r.randrange(256) for _ in range(4))
        spi=bytes(r.randrange(256) for _ in range(4))
        replies=bytes(r.randrange(256) for _ in range(4))
        endpoint=BytePeripheral(SimpleNamespace(sclk=d.spi_sclk,mosi=d.spi_mosi,miso=d.ext6,cs=d.spi_cs),replies)
        sink=UartSink(d.sda,baud=HZ/BIT_CLOCKS,bits=8)
        overlap_clocks=0
        async def observe_overlap():
            nonlocal overlap_clocks
            while True:
                await FallingEdge(d.clk)
                if sink.active and int(d.spi_cs.value)==0:
                    overlap_clocks+=1
        overlap_task=cocotb.start_soon(observe_overlap())
        await c.write(0,0xf3) # run+restart+flush both; queue only afterward
        await c.write(0x16,*uart);await c.write(0x26,*spi)
        await Timer(7*14*BIT_CLOCKS*PERIOD_PS,unit='ps')
        deadline=None
        try:
            got_uart=bytes(await with_timeout(sink.read(4),1,'ms'))
            got_spi=bytes(await with_timeout(c.recv(4,e=1),1,'ms'))
        except Exception as exc:
            got_uart=got_spi=b'';deadline=f'caller deadline/exception: {type(exc).__name__}: {exc}'
        overlap_task.cancel()
        okay=got_uart==uart and got_spi==replies and bytes(endpoint.received)==spi and overlap_clocks>0
        record(f'concurrent_uart_spi_restart_{round_index}',True,okay,
               uart_expected=uart.hex(),uart_actual=got_uart.hex(),spi_expected=spi.hex(),
               spi_received=bytes(endpoint.received).hex(),reply_expected=replies.hex(),
               reply_actual=got_spi.hex(),overlap_clocks=overlap_clocks,deadline=deadline)
        sink._run_cr.cancel();endpoint._run_coroutine_obj.cancel()
    # The runner decides strict versus characterization exit semantics from
    # these exact per-case observations. A completed coroutine is not a pass.
    d._log.info('Stress observations complete: %d cases; %d failures',len(rows),sum(r['status']=='FAIL' for r in rows))
