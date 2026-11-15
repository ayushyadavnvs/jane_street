"""Divider range and half-clock glitches, using only coder ports."""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer,RisingEdge,FallingEdge,ClockCycles,ReadOnly
@cocotb.test()
async def divider_maximum(d):
 cocotb.start_soon(Clock(d.clk,16668,unit='ps').start())
 for k,v in dict(rst_n=0,clear=0,cfg=3,cfg2=0,sync=0,period_m1=65535,
  out_msb_first=0,in_msb_first=0,a_in=1,a_early=1,b_in=0,ctl=0,ctl_param=0,tx_put=0,tx_end=0,tx_data=0,rx_take=1).items():getattr(d,k).value=v
 await ClockCycles(d.clk,4);await FallingEdge(d.clk);d.rst_n.value=1
 await ClockCycles(d.clk,4);await FallingEdge(d.clk);d.a_in.value=0;d.a_early.value=0
 await RisingEdge(d.clk);await ReadOnly();assert not int(d.frame_end.value)
 await ClockCycles(d.clk,131070);await ReadOnly();assert not int(d.frame_end.value)
 ends=[]
 for i in range(1,5):
  await RisingEdge(d.clk);await ReadOnly()
  if int(d.frame_end.value):ends.append(131070+i)
 assert ends==[131072],ends
@cocotb.test()
async def sub_half_glitch(d):
 for k,v in dict(rst_n=0,clear=0,cfg=3,cfg2=0,sync=0,period_m1=5,
  out_msb_first=0,in_msb_first=0,a_in=1,a_early=1,b_in=0,ctl=0,ctl_param=0,tx_put=0,tx_end=0,tx_data=0,rx_take=1).items():getattr(d,k).value=v
 # Manual clock makes the one-half observation exact.
 async def edge():
  d.clk.value=0;await Timer(8334,unit='ps');d.clk.value=1;await Timer(8334,unit='ps')
 for _ in range(4):await edge()
 d.rst_n.value=1
 for _ in range(4):await edge()
 d.a_early.value=0;await edge();d.a_early.value=1
 for _ in range(24):
  await edge();assert not int(d.rx_valid.value) and not int(d.frame_end.value)

@cocotb.test()
async def flag_run_reset(d):
 async def edge():
  d.clk.value=0;await Timer(8334,unit='ps');d.clk.value=1;await Timer(8334,unit='ps')
 for k,v in dict(rst_n=0,clear=0,cfg=0x49,cfg2=0,sync=0,period_m1=4,
  out_msb_first=0,in_msb_first=0,a_in=0,a_early=0,b_in=1,ctl=0,ctl_param=0,tx_put=0,tx_end=0,tx_data=0,rx_take=1).items():getattr(d,k).value=v
 for _ in range(4):await edge()
 d.rst_n.value=1
 for _ in range(10):await edge()
 d.a_in.value=1;d.a_early.value=1;events=[]
 for i in range(150):
  await edge()
  if int(d.frame_end.value):events.append(i)
 assert len(events)>=4 and all(b-a==30 for a,b in zip(events,events[1:])),events
