"""Real public-pin frames from Scapy, binascii and crccheck, independent of the PBE model."""
import os,json
from pathlib import Path
import cocotb
from cocotb.triggers import RisingEdge,ReadOnly,Timer
from cocotb.utils import get_sim_time
from pin_driver import Host,PERIOD_PS
from wire_codecs import *
RESULTS=[]
def save(row):
 RESULTS.append(row);Path(os.environ['PBE_WIRE_RESULTS']).write_text(json.dumps(RESULTS,indent=2)+'\n')
async def observe(d,events):
 last=None
 while True:
  await RisingEdge(d.clk);await ReadOnly()
  pair=(int(d.tdp.value),int(d.tdm.value))
  if pair!=last:events.append((int(get_sim_time(unit='ps')),*pair));last=pair
async def inject(d,edges,lead_ps=1000000):
 await Timer(lead_ps,unit='ps');start=int(get_sim_time(unit='ps'))
 for at,level in edges:
  wait=start+at-int(get_sim_time(unit='ps'))
  if wait>0:await Timer(wait,unit='ps')
  d.incoming.value=level
 return start
async def until(h,predicate,us=200):
 for _ in range(us*5):
  if predicate():return
  await Timer(200000,unit='ps')
 raise AssertionError('host output deadline '+str(h.records.frames)+str(h.rx[0]))
def chunks(data,n=255):return b''.join(bytes([len(data[i:i+n])])+data[i:i+n] for i in range(0,len(data),n))+b'\0'
@cocotb.test()
async def ethernet_tx(d):
 h=Host(d);await h.start();await h.ethernet();events=[];obs=cocotb.start_soon(observe(d,events));reader=cocotb.start_soon(h.reader())
 frames=[ethernet_frame(n,n) for n in (60,61,255,256,512,1514,1600)]
 # All 255 nonzero chunk lengths occur in one independently CRC-checked jumbo.
 jumbo=ethernet_frame(sum(range(1,256)),32768);frames.append(jumbo)
 await h.send_stream(b'\0');await Timer(1000000,unit='ps')
 for k,frame in enumerate(frames):
  d._log.info('Independent TX frame %d size %d',k,len(frame))
  stream=chunks(frame)
  if k==len(frames)-1:
   stream=b'';at=0
   for n in range(1,256):stream+=bytes([n])+frame[at:at+n];at+=n
   stream+=b'\0'
  await h.send_stream(stream);await until(h,lambda:len(h.rx[0])>=k+1,us=40000)
  assert h.rx[0][k]&0x1c==0,('TX status',k,h.rx[0])
 await Timer(20000000,unit='ps');await h.stop_reader(reader);obs.cancel()
 packets=decode_manchester(events);assert [p['frame'] for p in packets]==frames
 from scapy.utils import wrpcap
 wrpcap(str(Path(os.environ['PBE_WIRE_OUTPUT'])/'decoded_frames.pcap'),[Ether(p['frame']) for p in packets])
 save(dict(test='ethernet_tx',frames=[len(f) for f in frames],chunks='1..255',statuses=h.rx[0],packets=[{k:v for k,v in p.items() if k not in ('frame','fcs')}|{'fcs':p['fcs'].hex()} for p in packets]))
@cocotb.test()
async def ethernet_rx(d):
 h=Host(d);await h.start();await h.ethernet();reader=cocotb.start_soon(h.reader());cases=[]
 frame=ethernet_frame(60,2,escape=True);wire=frame+ethernet_fcs(frame)
 vectors=[('good',wire,(),2),('bad_fcs',wire[:-1]+bytes([wire[-1]^1]),(),0)]
 vectors += [(f'runt_{n}',wire[:n],(),0) for n in range(4)]
 vectors += [(f'dribble_{n}',wire,tuple([1]*n),2 if n<8 else 0) for n in range(1,9)]
 for name,payload,dribble,status in vectors:
  n=len(h.records.frames);edges,_,_=manchester_edges(payload,dribble=dribble)
  await inject(d,edges);await until(h,lambda:len(h.records.frames)>n)
  got,stat=h.records.frames[n];expected=payload+(b'\xff' if len(dribble)==8 else b'')
  assert got==expected,(name,len(got),len(expected));assert stat==status,(name,stat,status)
  cases.append(dict(name=name,bytes=len(got),status=stat));await Timer(9600000,unit='ps')
 # A normal link pulse and a sub-half-clock glitch cannot produce a frame.
 n=len(h.records.frames)
 for duration in (100000,4000):
  d.incoming.value=1;await Timer(duration,unit='ps');d.incoming.value=0;await Timer(10000000,unit='ps')
 assert len(h.records.frames)==n
 await h.stop_reader(reader);save(dict(test='ethernet_rx',cases=cases,noise_ignored=True))
@cocotb.test()
async def hdlc_independent(d):
 h=Host(d);await h.start();await h.hdlc_config();reader=cocotb.start_soon(h.reader());bits=[]
 async def capture():
  # First flag's initial zero toggles NRZI to low; sample at cell centers.
  while int(d.hdlc_line.value):await RisingEdge(d.clk)
  await Timer(24*PERIOD_PS,unit='ps');previous=1
  for _ in range(18000):
   level=int(d.hdlc_line.value);bits.append(int(level==previous));previous=level
   await Timer(48*PERIOD_PS,unit='ps')
 cap=cocotb.start_soon(capture());frames=[bytes([0x7e,0xff,0,0xf8]),bytes(range(256))]
 for k,f in enumerate(frames):
  await h.send_stream(bytes([len(f)-1])+f)
  await Timer((len(f)+8)*8*48*PERIOD_PS,unit='ps')
 await Timer(100000000,unit='ps');cap.cancel()
 decoded=decode_hdlc(bits);assert decoded[:2]==[f+Crc16IbmSdlc.calc(f).to_bytes(2,'little') for f in frames],[(len(x),x[:8].hex()) for x in decoded]
 for f in frames:
  n=len(h.records.frames);levels=nrzi_levels(hdlc_bits(f));period=48*PERIOD_PS
  d.incoming.value=1;await Timer(8*period,unit='ps')
  for level in levels:d.incoming.value=level;await Timer(period,unit='ps')
  d.incoming.value=1;await until(h,lambda:len(h.records.frames)>n,us=10000)
  got,stat=h.records.frames[n];assert got==f+Crc16IbmSdlc.calc(f).to_bytes(2,'little') and stat==2,(len(got),stat)
 await h.stop_reader(reader);save(dict(test='hdlc_independent',sizes=[len(f) for f in frames],tx_status=h.rx[0],rx_records=len(h.records.frames)))
