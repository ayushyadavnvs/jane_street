"""Reproducible digital timing sweeps; required-envelope failures are never called passes."""
import os,json,random
from pathlib import Path
import cocotb
from cocotb.triggers import Timer,with_timeout
from pin_driver import Host,PERIOD_PS
from wire_codecs import *
from test_wire_vectors import inject,until,chunks,observe
RESULTS=[]
def save(row):
 RESULTS.append(row);Path(os.environ['PBE_WIRE_RESULTS']).write_text(json.dumps(RESULTS,indent=2)+'\n')
@cocotb.test()
async def receive_jitter(d):
 h=Host(d);await h.start();await h.ethernet();reader=cocotb.start_soon(h.reader());required_fail=[]
 cases=[]
 for ppm in (-100,100):
  for pattern in ('uniform','alternating','isi'):
   for seed in (0x8023,0x13500):cases.append((ppm,13500,pattern,seed,256,True))
 for jitter in (14000,15000,18000,20000):
  for pattern in ('uniform','alternating','isi'):cases.append((100,jitter,pattern,0x8023,256,False))
 for ppm in (-10000,-1000,1000,10000):cases.append((ppm,0,'uniform',0x8023,1514,False))
 for i,(ppm,jitter,pattern,seed,size,required) in enumerate(cases):
  # Clear framing/FIFOs between cases; configuration and host speed stay identical.
  if i:
   await h.stop_reader(reader);await h.reset();await h.ethernet();reader=cocotb.start_soon(h.reader())
  frame=ethernet_frame(size,seed);wire=frame+ethernet_fcs(frame)
  edges,_,meta=manchester_edges(wire,ppm,jitter,seed,pattern)
  await inject(d,edges);await Timer(100000000,unit='ps')
  frames=h.records.frames
  delivered=frames==[(wire,2)]
  row=dict(test='receive_jitter',required=required,delivery='PASS' if delivered else 'FAIL',**meta,
   seed=seed,frame_bytes=size,local_bit_ps=6*PERIOD_PS,
   relative_ppm=(100000/meta['bit_ps']*6*PERIOD_PS/100000-1)*1e6,
   records=[dict(bytes=len(f),status=s,data_matches=f==wire) for f,s in frames])
  if not delivered:
   path=Path(os.environ['PBE_WIRE_OUTPUT'])/f'jitter-{i:02d}.json'
   path.write_text(json.dumps(dict(row,wire_hex=wire.hex(),edges=edges,received=[dict(data=f.hex(),status=s) for f,s in frames]),indent=2)+'\n')
   row['stimulus']=path.name
  save(row);d._log.info('JITTER %s',row)
  if required and not delivered:required_fail.append(row)
 await h.stop_reader(reader)
 assert not required_fail,f'{len(required_fail)} required +/-13.5ns receiver cases failed; retained observations.json'
@cocotb.test()
async def host_phases_and_full_duplex(d):
 h=Host(d);await h.start()
 for i in range(16):
  h.phase_ps=round(i*PERIOD_PS/16);h.jitter_ps=2000 if i%2 else 0
  await h.reset();await h.ethernet();d.loopback.value=1
  reader=cocotb.start_soon(h.reader());frame=ethernet_frame(256,100+i)
  await h.send_stream(chunks(frame,17+i));await until(h,lambda:len(h.records.frames)>=1 and len(h.rx[0])>=1,us=2000)
  assert h.records.frames==[(frame+ethernet_fcs(frame),2)] and h.rx[0][0]&0x1c==0,(i,h.records.frames,h.rx[0])
  await h.stop_reader(reader)
  save(dict(test='host_phases',phase_ps=h.phase_ps,jitter_ps=h.jitter_ps,
    half_min_ps=min(h.half_durations),half_max_ps=max(h.half_durations),status='PASS'))
 # Worst-case escaping saturates a host that must carry both directions plus commands.
 h.jitter_ps=0;h.phase_ps=7919;await h.reset();await h.ethernet();d.loopback.value=1
 reader=cocotb.start_soon(h.reader());frame=ethernet_frame(1514,99,escape=True)
 await h.send_stream(chunks(frame));await Timer(300000000,unit='ps');await h.stop_reader(reader)
 good=h.records.frames==[(frame+ethernet_fcs(frame),2)] and len(h.rx[0])==1 and h.rx[0][0]&0x1c==0
 save(dict(test='worst_escape_full_duplex',delivery='PASS' if good else 'FAIL',
  tx_status=h.rx[0],rx=[dict(bytes=len(f),status=s,matches=f==frame+ethernet_fcs(frame)) for f,s in h.records.frames],
  offered_raw_bytes_per_second=3750000,host_raw_limit=3750000,
  interpretation='Command, count-read and chunk overhead consume bandwidth beyond the raw offered limit.'))
@cocotb.test()
async def underrun_overrun_recovery(d):
 h=Host(d);await h.start();await h.ethernet();reader=cocotb.start_soon(h.reader());frame=ethernet_frame(256,3)
 await h.send_stream(chunks(frame),pause_after=25,pause_us=30)
 await until(h,lambda:bool(h.rx[0]),us=5000)
 assert h.rx[0][0]&0x10 and not h.rx[0][0]&4,h.rx[0]
 save(dict(test='tx_underrun',status=h.rx[0][0],pause_us=30,status_contract='PASS',delivery='FAIL'))
 await h.stop_reader(reader);await h.reset();await h.ethernet();reader=cocotb.start_soon(h.reader())
 await h.send_stream(bytes([255])+frame[:24]);await Timer(1200000000,unit='ps')
 await until(h,lambda:bool(h.rx[0]),us=2000);assert h.rx[0][0]&0x14==0x14,h.rx[0]
 save(dict(test='tx_abort',status=h.rx[0][0],pause_us=1200,status_contract='PASS',delivery='FAIL'))
 await h.send_stream(b'\0\0');await Timer(100000000,unit='ps')
 n=len(h.rx[0]);await h.send_stream(chunks(frame));await until(h,lambda:len(h.rx[0])>n,us=3000)
 assert not h.rx[0][-1]&0x1c,h.rx[0]
 save(dict(test='tx_abort_recovery',status=h.rx[0][-1],status_contract='PASS'))
 await h.stop_reader(reader);await h.reset();await h.ethernet()
 # Host intentionally absent during receive. Resume reads before next traffic.
 wire=frame+ethernet_fcs(frame);edges,_,_=manchester_edges(wire)
 await inject(d,edges);reader=cocotb.start_soon(h.reader());await until(h,lambda:bool(h.records.frames),us=3000)
 got,status=h.records.frames[0]
 assert status&0x18==0x18 and not status&2,(len(got),status)
 assert got==wire[:len(got)] and len(got)<len(wire),(len(got),got.hex())
 save(dict(test='rx_host_overrun',retained_bytes=len(got),status=status,status_contract='PASS',delivery='FAIL'))
 n=len(h.records.frames);await inject(d,edges);await until(h,lambda:len(h.records.frames)>n,us=3000)
 assert h.records.frames[-1]==(wire,10),[(len(f),s,f[:20].hex()) for f,s in h.records.frames]
 await h.write(0x2f,4) # RX-overflow status is sticky until an explicit host clear.
 n=len(h.records.frames);await inject(d,edges);await until(h,lambda:len(h.records.frames)>n,us=3000)
 assert h.records.frames[-1]==(wire,2),h.records.frames[-1]
 save(dict(test='rx_overrun_recovery',status=2,delivery='PASS'));await h.stop_reader(reader)
@cocotb.test()
async def exact_ifg(d):
 h=Host(d);await h.start();await h.ethernet();reader=cocotb.start_soon(h.reader())
 frame=ethernet_frame(60,23);wire=frame+ethernet_fcs(frame);edges,end,_=manchester_edges(wire)
 # Tail lasts 0.3 us: 9.3 more makes the next preamble exactly 9.6 us after FCS.
 first=await inject(d,edges);second=await inject(d,edges,lead_ps=9300000)
 assert second-(first+end-300000)==9600000
 await until(h,lambda:len(h.records.frames)==2)
 assert h.records.frames==[(wire,2),(wire,2)],h.records.frames
 save(dict(test='exact_ifg',ifg_ps=9600000,frames=2,delivery='PASS'));await h.stop_reader(reader)
