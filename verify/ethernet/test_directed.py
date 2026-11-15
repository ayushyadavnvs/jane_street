"""Architectural D89/D91 corners through the real host pins and per-clock oracle."""
import cocotb
from cocotb.triggers import RisingEdge,FallingEdge,Timer
from test_diff import Harness,word

@cocotb.test()
async def crc_bytes(dut):
    retained=None
    for width in (9,16,17,21,24,32):
        h=Harness(dut,0x435243+width)
        if retained:
            for f,mem in zip(h.model.tx+h.model.rx,retained):f.mem=list(mem)
        await h.reset();await h.set_quad(True)
        program=[word(7,0)]
        expected=[];mask=(1<<width)-1
        for param in range(16):
            program.extend((word(7,64|param),word(6,384|3<<4|2<<2),word(5,256)))
            value=mask << (16-width) if width<=16 and param&4 else mask
            index=(param&1)|(2 if width>16 and param&8 else 0)
            expected.append(((value>>(8*index))&255)^(255 if param&2 else 0))
        program.append(word(3,len(program)))
        for e in range(2):
            await h.write(15,e<<1);await h.write(6,0)
            await h.write(7,[b for w in program for b in (w>>8,w&255)])
            a=0x10+16*e;p=0x30+16*e
            await h.write(a,[0,0,e*4,0,0,0])
            await h.write(a+11,0x30|((width-1)&15))
            await h.write(p+12,int(width>16))
        await h.write(0,0x33);await h.clocks_wait(220)
        for e in range(2):
            p=0x30+16*e;a=0x10+16*e
            assert (await h.host(0x0a+e))[0]==16
            assert await h.host(a+6,count=16)==expected,(width,e,expected)
            for addr,shift in ((a+9,0),(a+10,8),(p+8,16),(p+9,24)):
                assert (await h.host(addr))[0]==((mask>>shift)&255)
            await h.write(p+2,[mask&255,(mask>>8)&255])
            await h.write(p+10,[(mask>>16)&255,(mask>>24)&255])
            assert (await h.host(a+15))[0]&2
            assert await h.host(p+10,count=2)==[(mask>>16)&255,(mask>>24)&255]
            await h.write(p+11,((mask>>24)&255)^0x80)
            assert not (await h.host(a+15))[0]&2
        if width==32:
            await h.write(0,0)
            for e in range(2):
                a=0x10+16*e;p=0x30+16*e
                await h.write(p+12,0);await h.write(a+11,0x1f)
                assert await h.host(p+8,count=2)==[255,255] # live shrink keeps raw state
                await h.write(a+15,1)
                assert await h.host(p+8,count=2)==[0,0] # CRCRST masks the new width
        retained=[list(f.mem) for f in h.model.tx+h.model.rx]
    dut._log.info('DIRECTED_CRC_BYTES: 6 widths x 16 parameters x 2 engines PASS')

@cocotb.test()
async def quad_edges(dut):
    h=Harness(dut,0x51554144);await h.reset();await h.set_quad(True)
    await h.write(0,3) # status pins differ from zero read-data high nibble
    async def short_cs(captured):
        for _ in range(2):await RisingEdge(dut.clk)
        if captured:
            await FallingEdge(dut.clk);await Timer(7000,unit='ps')
        else:await Timer(1000,unit='ps')
        saved=h.ui;before=int(dut.uo_out.value)
        h.ui=saved|2;dut.ui_in.value=h.ui
        await Timer(1000 if not captured else 2000,unit='ps')
        if not captured:
            assert int(dut.uo_out.value)==before,'raw CS pulse glitched synchronized Q/status mux'
        h.ui=saved;dut.ui_in.value=saved
    for captured in (False,True):
        h.ui=0;await h.clocks_wait(4);await h.transfer(0x50)
        task=cocotb.start_soon(short_cs(captured))
        value=await h.transfer(0)
        await task
        h.ui=2;await h.clocks_wait(5)
        if not captured:assert value==1
        assert (await h.host(0x50))[0]==1
    async def idle_edges(n):
        for _ in range(n):
            h.ui=2;await h.clocks_wait(4)
            h.ui=3;await h.clocks_wait(4)
        h.ui=2;await h.clocks_wait(4)
    await idle_edges(7)
    assert (await h.host(0x50))[0]==1
    await idle_edges(1) # the selected transaction reset the counter
    assert (await h.host(0x50))[0]==1
    # Abort after one nibble of a write command; no partial register write.
    h.ui=0;await h.clocks_wait(4)
    h.ui=0xd<<2;await h.clocks_wait(4)
    h.ui|=1;await h.clocks_wait(4)
    h.ui=2;await h.clocks_wait(5)
    assert (await h.host(0x50))[0]==1
    # HOSTCFG changes mid-burst; unmapped following bytes stay in the old lane mode.
    await h.write(0x50,[0,0xa5,0x5a]);h.quad_mode=False
    assert (await h.host(0x50))[0]==0
    assert await h.host(0x51,count=2)==[0,0]
    await h.set_quad(True);await h.idle_exit()
    assert (await h.host(0x50))[0]==0
    dut._log.info('DIRECTED_QUAD: short CS pulses, partial abort, 7/8 idle edges, counter reset, burst mode latch PASS')

@cocotb.test()
async def linectl_both_and_manchester_wait(dut):
    h=Harness(dut,0x4c43544c);await h.reset();await h.set_quad(True)
    # STUFFOFF|STUFFON must leave stuffing enabled; MC must ignore LINE2 idle wait.
    program=[word(7,448|19),word(4,256|0x55),word(0,4<<3),word(3,2)]
    for e in range(2):
        await h.write(15,e<<1);await h.write(6,0)
        await h.write(7,[b for w in program for b in (w>>8,w&255)])
        a=0x10+16*e;p=0x30+16*e
        await h.write(a,[5,0,e*4,0,0,0])
        await h.write(p,0x23 if e==0 else 0x29)
        await h.write(p+4,0x40 if e==0 else 0)
    await h.write(0,0x33);await h.clocks_wait(400)
    assert h.model.engines[0].line.drive,'Manchester idle qualification blocked transfer'
    for e in range(2):assert not (await h.host(0x1f+16*e))[0]&0x10
    dut._log.info('DIRECTED_LINECTL: simultaneous off/on and Manchester LINE2 idle wait PASS')
