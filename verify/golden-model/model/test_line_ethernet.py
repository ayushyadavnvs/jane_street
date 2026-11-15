"""D90/D94 clock differential; independent queued-bit and phase-age reference."""
import json
import os
import random
from pathlib import Path
import cocotb
from cocotb.triggers import Timer
from pbe_model import LineModel

@cocotb.test(skip=os.getenv('PBE_LINE_ETHERNET') != '1')
async def ethernet_line(dut):
    rng=random.Random(0x45544833);m=LineModel();cycle=0;history=[]
    names=('drive','a_out','b_out','tx_ready','rx_valid','rx_data','frame_end','err')
    async def edge(**kw):
        nonlocal cycle
        dut.clk.value=0
        for k,v in kw.items():getattr(dut,k).value=int(v)
        await Timer(8334,unit='ps')
        m.step(**kw);dut.clk.value=1
        await Timer(8334,unit='ps');cycle+=1
        got={k:int(getattr(dut,k).value) for k in names}
        want={k:int(getattr(m,k)) for k in names}
        history.append(dict(inputs=kw.copy(),model_age=m.mc_elapsed,rtl_age=int(dut.mcnt.value)))
        if got!=want:
            receipt=dict(cycle=cycle,inputs=kw,expected=want,actual=got,model=vars(m),history=history[-24:])
            Path(os.getenv('PBE_LINE_DIAGNOSTIC',str(Path(__file__).resolve().parents[3]/'pbe_v1/build/line_model/ethernet-failure.json'))).write_text(json.dumps(receipt,default=list,indent=2))
            assert got==want,dict(cycle=cycle,inputs=kw,actual=got,expected=want)
    base=dict(clear=True,cfg=0,cfg2=0,sync=0,period_m1=5,out_msb_first=0,
              in_msb_first=0,a_in=1,a_early=1,b_in=0,tx_put=0,tx_end=0,tx_data=0,
              rx_take=0,ctl=0,ctl_param=0)
    dut.rst_n.value=0;await edge(**base);dut.rst_n.value=1
    configs=[]
    for mode in (3,1,2):
        for byte in (0,1):
            for pair in (0,1):
                for order in (0,1):
                    for div in (3,4,5,6,19):
                        cfg=mode|byte*32|pair*16
                        if mode==3:
                            for polarity in (0,128):
                                for sync in (0,0xd5):
                                    configs.append((cfg|polarity|rng.choice((0,4,8,12))|64,
                                                    order,div,sync,rng.choice((0,1,2,3,8))))
                        else:
                            configs.append((cfg|8|64,order,div,0,0))
    for cfg,order,div,sync,cfg2 in configs:
        q=dict(base,cfg=cfg,cfg2=cfg2,sync=sync,period_m1=div,out_msb_first=order,in_msb_first=order)
        await edge(**q);q['clear']=False
        level=1
        for t in range(800):
            prior=level
            if rng.random()<.13:level^=1
            early=level if rng.getrandbits(1) else prior
            # Include pulses that cross the falling sample but not a rising sample.
            if rng.random()<.015 and prior==level:early=1-level
            put=m.tx_ready and rng.random()<.12
            end=m.tx_ready and not put and rng.random()<.03
            await edge(**dict(q,a_in=level,a_early=early,b_in=1-level,
                             tx_put=put,tx_end=end,tx_data=rng.randrange(256),
                             rx_take=rng.random()<.2,ctl=rng.random()<.08,
                             ctl_param=rng.choice((16,17,18,19))))
    dut._log.info('ETHERNET_LINE %s',json.dumps(dict(configurations=len(configs),clocks=cycle,seed=0x45544833)))
