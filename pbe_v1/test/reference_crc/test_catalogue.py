"""CRC vectors are external data; never import the PBE golden model or RTL state.

The library processes bytes independently. RTL receives serial wire bits directly.
Raw residue, reflected catalogue residue, and final XOR are separate comparisons.
"""
import json
import os
from pathlib import Path
import random
import cocotb
from cocotb.triggers import Timer
import crccheck.crc as library
from importlib.metadata import version
HERE=Path(__file__).resolve().parent
PBE=HERE.parents[1]


def reflect(value,width):
    return int(f'{value:0{width}b}'[::-1],2)


def bits(value,width,lsb_first):
    return [(value>>i)&1 for i in (range(width) if lsb_first else range(width-1,-1,-1))]


class WireCRC:
    def __init__(self,dut):self.dut=dut;self.cycles=0
    async def edge(self,**values):
        d=self.dut;d.clk.value=0
        for name,value in values.items():getattr(d,name).value=value
        await Timer(10416,unit='ps');d.clk.value=1
        await Timer(10416,unit='ps');d.clk.value=0;self.cycles+=1
    def raw(self,row):
        value=int(self.dut.value.value)
        return reflect(value,row['width']) if row['refout'] else value
    async def configure(self,row,good):
        mask=(1<<row['width'])-1
        await self.edge(rst_n=0,init=0,step=0,bit_in=0,poly=int(row['poly'],0),
                        width_m1=row['width']-1,init_ones=int(int(row['init'],0)==mask),
                        out_rev=int(row['refout']),good=good)
        await self.edge(rst_n=1,init=1,step=1,bit_in=1)
        assert self.raw(row)==int(row['init'],0),row['name']+' init / init-over-step'
        await self.edge(init=0,step=0)
    async def feed(self,row,data,oracle):
        d=self.dut
        for byte in data:
            for bit in bits(byte,8,row['refin']):await self.edge(step=1,bit_in=bit)
            oracle.process(bytes([byte]))
            assert self.raw(row)==oracle.value(),f"{row['name']} byte raw mismatch"
            assert int(d.value.value)<1<<row['width'],row['name']+' unused bits nonzero'
            before=int(d.value.value);await self.edge(step=0)
            assert int(d.value.value)==before,row['name']+' idle changed CRC'


@cocotb.test()
async def catalogue_checks(dut):
    rows=json.loads((HERE/'catalogue.json').read_text())['vectors']
    seed=int(os.getenv('PBE_CRC_SEED',str(0x435243)))
    random_cases=int(os.getenv('PBE_CRC_RANDOM','8'));rng=random.Random(seed)
    h=WireCRC(dut);results=[];unsupported=[]
    for row in rows:
        cls=getattr(library,row['class_name']);width=row['width'];mask=(1<<width)-1
        for key,actual in [('poly',cls.poly()),('init',cls.initvalue()),('xorout',cls.xor_output()),
                           ('check',cls.check_result()),('residue',cls.residue())]:
            assert actual==int(row[key],0),f"catalogue/library metadata disagree: {row['name']} {key}"
        assert cls.width()==width and cls.reflect_input()==row['refin'] and cls.reflect_output()==row['refout']
        assert cls.calc(b'123456789')==int(row['check'],0),row['name']+' independent library check'
        if not row['native_init']:
            unsupported.append(dict(name=row['name'],reason=f"init {row['init']} is neither zero nor all ones; no arbitrary seed-load register"))
            continue
        residue=int(row['residue'],0)
        raw_good=reflect(residue,width) if row['refout'] else residue
        for index,data in enumerate([b'123456789',b'']+[rng.randbytes(rng.randrange(33)) for _ in range(random_cases)]):
            oracle=cls();await h.configure(row,raw_good)
            await h.feed(row,data,oracle)
            wire_check=oracle.final()
            actual_check=int(dut.value.value)^int(row['xorout'],0)
            assert actual_check==wire_check,f"{row['name']} final value/XOR mismatch"
            if index==0:assert actual_check==int(row['check'],0),row['name']+' catalogue check'
            # Append exactly width CRC bits, without byte padding for short widths.
            for bit in bits(wire_check,width,row['refout']):await h.edge(step=1,bit_in=bit)
            actual_residue=int(dut.value.value)
            assert actual_residue==residue,f"{row['name']} residue {actual_residue:x} != {residue:x}"
            assert h.raw(row)==raw_good,row['name']+' raw residue mapping'
            assert int(dut.ok.value)==1,row['name']+' CRC_GOOD comparator'
            # Independently exercise both sides of the raw CRC_GOOD comparator.
            await h.edge(step=0,good=raw_good^1)
            assert int(dut.ok.value)==0,row['name']+' unequal CRC_GOOD comparator'
            await h.edge(good=raw_good)
        # Corrupt one transmitted checksum bit for a real bad-codeword test.
        await h.configure(row,raw_good)
        await h.feed(row,b'123456789',cls())
        for bit in bits(int(row['check'],0)^1,width,row['refout']):
            await h.edge(step=1,bit_in=bit)
        assert h.raw(row)!=raw_good and int(dut.ok.value)==0,row['name']+' corrupted checksum accepted'
        results.append(dict(corrupted_checksum_rejected=True,name=row['name'],check=row['check'],residue=row['residue'],raw_crc_good=hex(raw_good),
                            payloads=2+random_cases,refin=row['refin'],refout=row['refout'],xorout=row['xorout'],status='PASS'))
    report=dict(seed=seed,random_cases=random_cases,rtl_configurations=len(results),catalogue_entries=len(rows),
                cycles=h.cycles,library='crccheck '+version('crccheck'),clock_period_ps=20832,
                results=results,unsupported=unsupported)
    out=PBE/'build/reference_crc/results.json';out.parent.mkdir(parents=True,exist_ok=True)
    out.write_text(json.dumps(report,indent=2)+'\n')
    dut._log.info('CRC CATALOGUE %s',json.dumps(report,sort_keys=True))
