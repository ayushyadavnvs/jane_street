#!/usr/bin/env python3
"""Single-site feature/program mutants in frozen scratch copies, with strict failure classification."""
import argparse,hashlib,json,os,shutil,sys,tempfile,subprocess,tarfile
from pathlib import Path
from mutate import run_check,IGNORE,SNAPSHOT
ROOT=Path(__file__).resolve().parents[2];OUT=ROOT/'pbe_v1/build/ethernet_mutations'
# A component differential compares every observable clock; directed checks use public pins.
MUTANTS=[
 ('E01','quad nibble order','src/pbe_host_spi.sv','{rx_sh[3:0], mosi_hi, mosi}','{mosi_hi, mosi, rx_sh[3:0]}','directed'),
 ('E02','quad latch while selected','src/pbe_host_spi.sv','if (cs_n) begin\n        quad     <= quad_req;','quad <= quad_req;\n      if (cs_n) begin','directed'),
 ('E03','Manchester polarity','src/pbe_line.sv','minv  = cfg[7]','minv  = ~cfg[7]','line'),
 ('E04','Manchester lock threshold','src/pbe_line.sv',"{6'b0, period_m1, 2'b0} + {7'b0, period_m1, 1'b0}","{6'b0, period_m1, 2'b0} + {7'b0, period_m1, 1'b0} + {8'b0, period_m1}",'line'),
 ('E05','Manchester early offset','src/pbe_line.sv',"m_tau  = mcnt - (m_early ? 24'sd4 : 24'sd0)","m_tau  = mcnt - (m_early ? 24'sd0 : 24'sd0)",'line'),
 ('E06','wide CRC top decode','src/pbe_crc.sv',"32'h0000_0001 << width_m1","32'h0000_0001 << width_m1[3:0]",'crc'),
 ('E07','CRC reflection','src/pbe_crc.sv','out_rev ? rev : crc','out_rev ? crc : crc','crc'),
 ('E08','queued stuffing tag','src/pbe_line.sv','q_ns    <= ns_mode;','q_ns    <= !ns_mode;','line'),
 ('E09','STUFFON precedence','src/pbe_line.sv',"if (ctl_param[1]) ns_mode <= 1'b0;\n        else if (ctl_param[0]) ns_mode <= 1'b1;","if (ctl_param[0]) ns_mode <= 1'b1;\n        else if (ctl_param[1]) ns_mode <= 1'b0;",'line'),
 ('E10','flag run reset','src/pbe_line.sv',"if (!pair && flagd) begin\n                    frame_end", "if (!pair && flagd) begin\n                    rrun <= 3'd6;\n                    frame_end",'line_corners'),
 ('P01','Ethernet IFG count','pbe_v1/programs/eth_tx.pbe','SET  X, 35','SET  X, 15','program'),
 ('P02','Ethernet second END','pbe_v1/programs/eth_tx.pbe','fin:    PIN  tdp, END','fin:    NOP','program_corner'),
 ('P03','Ethernet frame STAT','pbe_v1/programs/eth_tx.pbe','        STAT                 ; clears','        NOP                  ; clears','program_corner'),
 ('P04','Ethernet RX escape','pbe_v1/programs/eth_rx.pbe','        PUSH                 ; a data 0x7E goes to the host twice','        NOP                  ; a data 0x7E goes to the host twice','program_corner'),
]
def main():
 p=argparse.ArgumentParser();p.add_argument('--only',nargs='*');p.add_argument('--timeout',type=int,default=240);a=p.parse_args();OUT.mkdir(parents=True,exist_ok=True)
 python=str(ROOT/'.venv/bin/python');env=os.environ.copy();env['PBE_LINE_ETHERNET']='1'
 env.pop('COCOTB_TEST_FILTER',None);env.pop('COCOTB_TESTCASE',None);results=[]
 with tempfile.TemporaryDirectory(prefix='ethernet-mutants-') as temp:
  snapshot=Path(temp)/'baseline'
  for part in SNAPSHOT:shutil.copytree(ROOT/part,snapshot/part,symlinks=True,ignore=IGNORE)
  manifest={str(x.relative_to(snapshot)):hashlib.sha256(x.read_bytes()).hexdigest() for x in snapshot.rglob('*') if x.is_file() and not x.is_symlink()}
  manifest_file=OUT/('snapshot-'+('-'.join(a.only) if a.only else 'all')+'.json')
  manifest_file.write_text(json.dumps(manifest,indent=2)+'\n')
  manifest_sha256=hashlib.sha256(manifest_file.read_bytes()).hexdigest()
  archive=OUT/('baseline-source-'+('-'.join(a.only) if a.only else 'all')+'.tar.gz')
  with tarfile.open(archive,'w:gz') as tar:tar.add(snapshot,arcname='baseline')
  for mid,category,file,before,after,check in MUTANTS:
   if a.only and mid not in a.only:continue
   scratch=Path(temp)/mid;shutil.copytree(snapshot,scratch,symlinks=True)
   path=scratch/file;text=path.read_text()
   if text.count(before)!=1:raise RuntimeError(f'{mid}: expected one site, got {text.count(before)} for {before!r}')
   path.write_text(text.replace(before,after))
   if check=='directed':cmd=[python,str(scratch/'verify/ethernet/run_directed.py')]
   elif check=='line_corners':cmd=[python,str(scratch/'verify/ethernet/run_line_corners.py')]
   elif check=='line':cmd=['make','diff-line',f'PYTHON={python}']
   elif check=='program_corner':cmd=[python,str(scratch/'verify/ethernet/run_wire.py'),'--sim','verilator','--test-module','test_program_corners']
   elif check=='crc':cmd=[python,str(scratch/'verify/vectors/crc/run.py'),'--wide','--random-cases','1']
   else:
    # Runtime readmemh images permit program-only injection into one compiled final-RTL bench.
    obj=ROOT/'pbe_v1/build/coverage/obj_tb_eth/sim'
    if not obj.exists():raise RuntimeError('Build final RTL tb_eth with coverage before program mutants')
    subprocess.run(['make','-s','test/eth_image.hex'],cwd=scratch/'pbe_v1',check=True,stdout=subprocess.DEVNULL)
    cmd=[str(obj)]
   cwd=scratch/'pbe_v1/test' if check=='program' else scratch/'pbe_v1'
   executable_path=Path(shutil.which(cmd[0],path=env.get('PATH')) or cmd[0])
   executable_sha256=hashlib.sha256(executable_path.read_bytes()).hexdigest()
   receipt=run_check(cmd,cwd,env,a.timeout,OUT/(mid+'.log.gz'))
   receipt['executable_sha256']=executable_sha256
   if hashlib.sha256(executable_path.read_bytes()).hexdigest()!=executable_sha256:raise RuntimeError('executable changed during mutant')
   receipt.update(baseline_archive=archive.name,input_manifest=manifest_file.name,input_manifest_sha256=manifest_sha256,id=mid,category=category,file=file,before=before,after=after,baseline_sha256=manifest[file],mutant_sha256=hashlib.sha256(path.read_bytes()).hexdigest())
   (OUT/(mid+'.json')).write_text(json.dumps(receipt,indent=2)+'\n');results.append(receipt)
   print(mid,receipt['status'],receipt['first_failure'],flush=True);shutil.rmtree(scratch)
 report=dict(total=len(results),caught=sum(r['status']=='caught' for r in results),results=results)
 (OUT/('summary-'+('-'.join(a.only) if a.only else 'all')+'.json')).write_text(json.dumps(report,indent=2)+'\n')
 return int(report['caught']!=report['total'])
if __name__=='__main__':raise SystemExit(main())
