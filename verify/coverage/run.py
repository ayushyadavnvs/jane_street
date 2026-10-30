#!/usr/bin/env python3
"""Run every normal make-test SV bench under instrumented Verilator; merge with diff.

Long target: leaves tracked RTL unchanged. Actual make test remains the Icarus gate.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import gzip,json,os,hashlib
from pathlib import Path
import resource,shutil,subprocess,sys,time
from prepare import prepare
from data_file import clear_coverage, require_coverage
HERE=Path(__file__).resolve().parent   # verify/coverage
ROOT=HERE.parents[1]
PBE=ROOT/'pbe_v1'                      # the design (src, test benches, build)
GM=ROOT/'verify/golden-model'
SPEC=ROOT/'verify/spec_boundaries'
BUILD=PBE/'build/coverage'
BENCHES=['tb_coverage_gaps','tb_engine_known_reset','tb_fifo_robustness','tb_engine_restart','tb_engine_ops','tb_fetch','tb_line','tb_usb','tb_proto','tb_pbe','tb_spec_boundaries']
def call(cmd,cwd,log,expected=0,marker=None,coverage_file=None):
 started=time.monotonic()
 if coverage_file is not None: clear_coverage(coverage_file)
 def no_core():resource.setrlimit(resource.RLIMIT_CORE,(0,0))
 p=subprocess.run(list(map(str,cmd)),cwd=cwd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,preexec_fn=no_core)
 log.write_text(p.stdout)
 passed=(p.returncode==expected if expected==0 else p.returncode!=0) and (not marker or marker in p.stdout)
 coverage_error=None;coverage_bytes=None
 if coverage_file is not None:
  try: coverage_bytes=require_coverage(coverage_file)
  except RuntimeError as exc: passed=False;coverage_error=str(exc)
 return dict(command=list(map(str,cmd)),returncode=p.returncode,seconds=round(time.monotonic()-started,3),passed=passed,log=str(log),coverage_bytes=coverage_bytes,coverage_error=coverage_error)
IMAGE_TARGETS=['test/'+name+'_image.hex' for name in ('conc','ow','modbus','nop','uart','spi','mixed','ws2812','spi_periph','i2c_target','usb','ops','fetch')]
def refresh_images(root=PBE,targets=IMAGE_TARGETS):
 command=['make','-s',*targets]
 result=subprocess.run(command,cwd=root,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
 if result.returncode: raise RuntimeError('Program image prerequisites failed:\n'+result.stdout)
 return dict(command=command,returncode=result.returncode,output=result.stdout,passed=True)

def main():
 ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--jobs',type=int,default=2);ap.add_argument('--only',nargs='*',choices=BENCHES);ap.add_argument('--skip-diff',action='store_true');ap.add_argument('--skip-line-sweep',action='store_true');ap.add_argument('--reuse-builds',action='store_true');args=ap.parse_args()
 BUILD.mkdir(parents=True,exist_ok=True)
 if args.jobs < 1: ap.error('jobs must be positive')
 if not args.only:
  # Full campaigns never inherit stale data from older source/test revisions.
  for old in BUILD.glob('*.dat'): old.unlink()
 harness=call([sys.executable,'-m','unittest','discover','-s',HERE,'-p','test_harness.py','-v'],PBE,BUILD/'harness-tests.log')
 if not harness['passed']: raise SystemExit('Coverage harness negative regressions failed')
 images=refresh_images()
 (BUILD/'images.log').write_text(images['output'])
 src=prepare();test=BUILD/'test';test.mkdir(exist_ok=True)
 for pat in ['*.sv','*.svh','*.hex']:
  for p in (PBE/'test').glob(pat):shutil.copyfile(p,test/p.name)
 for p in [*HERE.glob('tb_*.sv'),*SPEC.glob('tb_*.sv')]:shutil.copyfile(p,test/p.name)
 # Verilator does not accept the optional '+' flag in floating-point display formatting.
 # This scratch-only diagnostic formatting adaptation changes no stimulus/check.
 line=test/'tb_line.sv'
 line.write_text(line.read_text().replace('%+0.1f','%0.1f'))
 receipts=[dict(test='coverage harness negative regressions',run=harness,passed=True)]
 def one(tb):
  obj=BUILD/('obj_'+tb);exe=obj/'sim'
  signature=hashlib.sha256(b''.join(p.read_bytes() for p in [test/(tb+'.sv'),*sorted(src.glob('*.sv')),*sorted(test.glob('*.svh'))])).hexdigest()
  signature_file=obj/'source_signature.txt'
  can_reuse=args.reuse_builds and exe.exists() and signature_file.exists() and signature_file.read_text()==signature
  if not can_reuse:
   cmd=['verilator','--binary','--timing','--coverage','--assert','-Wno-fatal','--compiler-include','verilated_cov.h','-j','2','--top-module',tb,'--Mdir',obj,'-o','sim',test/(tb+'.sv'),*sorted(src.glob('*.sv'))]
   build=call(cmd,test,BUILD/(tb+'-build.log'))
   if not build['passed']:return dict(test=tb,build=build,passed=False)
   signature_file.write_text(signature)
  else:build=dict(reused=True,passed=True)
  run=call([exe,f'+verilator+coverage+file+{BUILD/(tb+".dat")}'],test,BUILD/(tb+'-run.log'),marker='PASS',coverage_file=BUILD/(tb+'.dat'))
  result=dict(test=tb,build=build,run=run,passed=run['passed'],source_signature=signature)
  if tb=='tb_spec_boundaries' and result['passed']:
   result['expected_failures']=[]
   for arg,marker in [('EXPECT_WINDOW_FENCE','original requested pc<=start_pc+63 property fails'),('EXPECT_INSTRUCTION_WINDOW_FENCE','sequential executed-instruction window property fails'),('EXPECT_WRITE_CANCELLATION','old ready instruction executes on same PM-write edge')]:
    r=call([exe,'+'+arg],test,BUILD/(tb+'-'+arg+'.log'),expected=1,marker=marker);result['expected_failures'].append(r);result['passed'] &= r['passed']
  print(tb,'PASS' if result['passed'] else 'FAIL',flush=True);return result
 with ThreadPoolExecutor(max_workers=args.jobs) as pool:receipts.extend(pool.map(one,args.only or BENCHES))
 if not args.skip_diff:
  receipts.append(dict(test='make diff equivalent --sim verilator',run=call([sys.executable,GM/'differential/run.py','--sim','verilator','--coverage','--source-dir',src,'--build-dir',BUILD/'obj_diff','--coverage-output',BUILD/'diff.dat','--n','2','--cycles','600','--seed','0x504245'],PBE,BUILD/'diff.log')))
  receipts[-1]['passed']=receipts[-1]['run']['passed']
 if not args.skip_line_sweep:
  receipts.append(dict(test='line differential 160 configurations',run=call([sys.executable,HERE/'run_line.py'],PBE,BUILD/'line_sweep.log')));receipts[-1]['passed']=receipts[-1]['run']['passed']
 (BUILD/'image_prerequisites.json').write_text(json.dumps(images,indent=2)+'\n')
 (BUILD/'runs.json').write_text(json.dumps(receipts,indent=2)+'\n')
 if not all(r['passed'] for r in receipts):raise SystemExit('Coverage tests failed; preserve logs, do not count failures as pass')
 subprocess.run([sys.executable,HERE/'summarize.py'],cwd=PBE,check=True)
if __name__=='__main__':main()
