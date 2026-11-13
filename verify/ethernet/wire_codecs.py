"""Independent byte/edge codecs: IEEE 802.3 and ISO/IEC 13239, no golden-model import."""
import bisect,binascii,random
from scapy.layers.l2 import Ether
from scapy.packet import Raw
from crccheck.crc import Crc16IbmSdlc

def ethernet_frame(size,seed=0,escape=False):
    assert size>=14
    r=random.Random(seed)
    body=bytes([0x7e]*(size-14)) if escape else r.randbytes(size-14)
    return bytes(Ether(dst='ff:ff:ff:ff:ff:ff',src='02:13:37:42:aa:01',type=0x88b5)/Raw(body))

def ethernet_fcs(data):return binascii.crc32(data).to_bytes(4,'little')

def lsb_bits(data):return [(b>>i)&1 for b in data for i in range(8)]

def manchester_edges(data,ppm=0,jitter_ps=0,seed=0,pattern='uniform',dribble=()):
    bit_ps=100000/(1+ppm*1e-6)
    bits=lsb_bits(b'\x55'*7+b'\xd5'+data)+list(dribble)
    level=0;edges=[];r=random.Random(seed);number=0;last_ideal=None
    for i,bit in enumerate(bits):
        for half,want in enumerate((1-bit,bit)):
            if want==level:continue
            ideal=(i+half/2)*bit_ps
            if pattern=='alternating':jitter=jitter_ps if number%2 else -jitter_ps
            elif pattern=='isi':jitter=jitter_ps if last_ideal is not None and ideal-last_ideal<.75*bit_ps else -jitter_ps
            else:jitter=r.uniform(-jitter_ps,jitter_ps)
            edges.append((round(ideal+jitter),want));level=want;number+=1;last_ideal=ideal
    # A common phase offset permits negative jitter on the very first edge.
    origin=jitter_ps+16668 if jitter_ps else 0
    edges=[(at+origin,value) for at,value in edges]
    end=round(len(bits)*bit_ps)+origin
    if level!=1:edges.append((end,1))
    edges.append((round(end+3*bit_ps),0))
    assert all(a[0]<b[0] for a,b in zip(edges,edges[1:])), 'nonmonotonic invalid edge stimulus'
    assert edges[0][0]>=0
    return edges,round(end+3*bit_ps),dict(ppm=ppm,bit_ps=bit_ps,jitter_ps=jitter_ps,pattern=pattern,edges=number)

def decode_manchester(events,bit_ps=100008):
    """Sample the two centers of each bit cell; no clock-recovery loop is reused."""
    packets=[];starts=[];start=None
    for t,p,m in events:
        if p!=m and start is None:start=t
        elif p==m and start is not None:
            starts.append((start,t));start=None
    times=[x[0] for x in events]
    def level(t):
        p,m=events[bisect.bisect_right(times,t)-1][1:]
        assert p!=m
        return p
    for start,end in starts:
        if end-start<64*bit_ps:continue # link pulses are not packet data
        bits=[];cell=0
        while start+(cell+1)*bit_ps<=end:
            a=level(start+(cell+.25)*bit_ps);b=level(start+(cell+.75)*bit_ps)
            if a==b:break
            assert a==1-b
            bits.append(b);cell+=1
        assert len(bits)%8==0,'TX dribble/misalignment'
        data=bytes(sum(bits[j+i]<<i for i in range(8)) for j in range(0,len(bits),8))
        assert data.startswith(b'\x55'*7+b'\xd5'),'preamble/SFD'
        wire=data[8:];assert len(wire)>=4
        assert ethernet_fcs(wire[:-4])==wire[-4:],'independent Ethernet FCS'
        assert (binascii.crc32(wire)^0xffffffff)==0xdebb20e3,'reflected raw residue'
        tail=end-(start+len(bits)*bit_ps)
        assert abs(tail-3*bit_ps)<=1,'TP_IDL duration'
        packets.append(dict(start=start,end=end,tail_ps=tail,frame=wire[:-4],fcs=wire[-4:]))
    for a,b in zip(packets,packets[1:]):
        # IEEE IFG is measured from the end of the last FCS bit, not tail release.
        last_bit_end=a['end']-a['tail_ps']
        assert b['start']-last_bit_end>=9_600_000,'interframe gap below 9.6 us'
    return packets

def hdlc_bits(data,corrupt=False):
    fcs=Crc16IbmSdlc.calc(data)^(1 if corrupt else 0)
    body=lsb_bits(data+fcs.to_bytes(2,'little'))
    result=[];run=0
    for bit in body:
        result.append(bit);run=run+1 if bit else 0
        if run==5:result.append(0);run=0
    return [0,1,1,1,1,1,1,0]+result+[0,1,1,1,1,1,1,0]

def nrzi_levels(bits,initial=1):
    level=initial;out=[]
    for bit in bits:
        if not bit:level^=1
        out.append(level)
    return out

def decode_hdlc(raw_bits):
    """Flag framing/zero deletion, independently of PBE's six-one event mechanism."""
    text=''.join(map(str,raw_bits));pieces=text.split('01111110');frames=[]
    for raw in pieces[1:-1]:
        if not raw:continue
        bits=[];run=0;i=0;abort=False
        while i<len(raw):
            b=int(raw[i]);i+=1;bits.append(b);run=run+1 if b else 0
            if run==5:
                if i>=len(raw) or raw[i]!='0':abort=True;break
                i+=1;run=0
        if abort or len(bits)%8:continue
        data=bytes(sum(bits[j+k]<<k for k in range(8)) for j in range(0,len(bits),8))
        if len(data)<2:continue
        assert Crc16IbmSdlc.calc(data[:-2])==int.from_bytes(data[-2:],'little'),'HDLC external CRC-16/X.25'
        frames.append(data)
    return frames
