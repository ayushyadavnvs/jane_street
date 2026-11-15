"""Program control paths: frame after an idle timeout, exact TX records and RX escaping."""
import cocotb
from cocotb.triggers import Timer,RisingEdge,ReadOnly
from cocotb.utils import get_sim_time
from pin_driver import Host
from wire_codecs import ethernet_frame,ethernet_fcs,decode_manchester,manchester_edges
from test_wire_vectors import observe,inject,until,chunks
@cocotb.test()
async def idle_timeout_then_frame(d):
 h=Host(d);await h.start();await h.ethernet();events=[]
 observer=cocotb.start_soon(observe(d,events));reader=cocotb.start_soon(h.reader())
 await Timer(1200000000,unit='ps') # An idle PULL has timed out at least once.
 frame=ethernet_frame(60,0x53544154)
 completion=[]
 async def completion_available():
  while not completion:
   await RisingEdge(d.clk);await ReadOnly()
   if int(d.uo_out.value[4]):completion.append(int(get_sim_time(unit="ps")))
 monitor=cocotb.start_soon(completion_available())
 await h.send_stream(chunks(frame));await until(h,lambda:bool(h.rx[0]),us=2000)
 assert not h.rx[0][0]&0x1c,('idle TIMEOUT leaked into a complete frame',h.rx[0])
 await Timer(20000000,unit='ps');observer.cancel()
 packets=decode_manchester(events)
 assert [p['frame'] for p in packets]==[frame]
 assert completion and completion[0]>=packets[0]['end']-packets[0]['tail_ps'],('completion status preceded last FCS bit',completion,packets[0]['end']-packets[0]['tail_ps'])
 monitor.cancel()
 received=ethernet_frame(60,42,escape=True);wire=received+ethernet_fcs(received)
 edges,_,_=manchester_edges(wire);await inject(d,edges)
 await until(h,lambda:bool(h.records.frames));assert h.records.frames==[(wire,2)],('RX escaped payload/status',[(f.hex(),status) for f,status in h.records.frames])
 await h.stop_reader(reader)
