"""Small legal Ethernet frame exposing BUG-151; expected payload is independent of PBE."""
import json,os
from pathlib import Path
import cocotb
from cocotb.triggers import Timer
from pin_driver import Host
from wire_codecs import ethernet_frame,ethernet_fcs,manchester_edges
from test_wire_vectors import inject
@cocotb.test()
async def minimum_frame_edge_jitter(d):
 h=Host(d);await h.start();await h.ethernet();reader=cocotb.start_soon(h.reader())
 frame=ethernet_frame(60,0x8023);wire=frame+ethernet_fcs(frame)
 edges,_,meta=manchester_edges(wire,ppm=-100,jitter_ps=13500,seed=0x8023,pattern='isi')
 await inject(d,edges);await Timer(100000000,unit='ps');await h.stop_reader(reader)
 row=dict(test='minimum_frame_edge_jitter',wire=wire.hex(),edge_stimulus=edges,**meta,
  received=[dict(data=f.hex(),status=s) for f,s in h.records.frames],passed=h.records.frames==[(wire,2)])
 Path(os.environ['PBE_WIRE_RESULTS']).write_text(json.dumps(row,indent=2)+'\n')
 assert row['passed'],('BUG-151',[(len(f),s) for f,s in h.records.frames])
