#!/usr/bin/env python3
"""Merge Verilator data; count actual source points and named functional bins."""
import argparse,json,re,subprocess
from pathlib import Path
PBE=Path(__file__).resolve().parents[2]/'pbe_v1';B=PBE/'build/coverage'
def points(path):
 for line in path.read_text().splitlines():
  if not line.startswith("C '"):continue
  meta,count=line[3:].rsplit("' ",1)
  yield dict(part.split('\x02',1) for part in meta.split('\x01') if '\x02' in part),int(count)
def main():
 ap=argparse.ArgumentParser();ap.add_argument('--partial',action='store_true');a=ap.parse_args()
 files=sorted(B.glob('*.dat'));files=[p for p in files if p.name!='merged.dat']
 if not files:raise SystemExit('No simulator coverage data')
 subprocess.run(['verilator_coverage','--write',str(B/'merged.dat'),*map(str,files)],check=True)
 annotation=subprocess.run(['verilator_coverage','--annotate',str(B/'annotated'),'--annotate-all','--annotate-min','1',str(B/'merged.dat')],check=True,cwd=B/'test',stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
 (B/'verilator_coverage.txt').write_text(annotation.stdout)
 subprocess.run(['verilator_coverage','--write-info',str(B/'merged.info'),str(B/'merged.dat')],check=True)
 manifests=json.loads((B/'user_manifest.json').read_text());counts={r['name']:0 for r in manifests}
 types={};source_files={};line_union={};logical={}
 for m,count in points(B/'merged.dat'):
  file=Path(m.get('f',''));kind=m.get('t','unknown');name=m.get('o','')
  if kind=='user' and name.startswith('pbe_cov_'):
   key=name.removeprefix('pbe_cov_')
   if key in counts:counts[key]+=count
  original=PBE/'src'/file.name
  if not original.exists() or file.parent.name!='src':continue
  limit=original.read_text().splitlines().index('endmodule')+1
  if int(m.get('l','0'))>=limit or name.startswith('pbe_cov_'):continue
  key=(file.name,kind,tuple(sorted((k,v) for k,v in m.items() if k not in ('h','f'))))
  logical[key]=logical.get(key,0)+count
 for (filename,kind,metadata),count in logical.items():
  m=dict(metadata)
  target=types.setdefault(kind,dict(points=0,hit=0));target['points']+=1;target['hit']+=count>0
  ftarget=source_files.setdefault(filename,{}).setdefault(kind,dict(points=0,hit=0));ftarget['points']+=1;ftarget['hit']+=count>0
  if kind=='line':
   key=(filename,int(m['l']));line_union[key]=line_union.get(key,False) or count>0
 summary=dict(coverage_inputs=[str(p.relative_to(PBE)) for p in files],user_bins=len(counts),user_hit=sum(v>0 for v in counts.values()),user_counts=counts,user_missing=[k for k,v in counts.items() if not v],rtl_point_coverage=types,per_file=source_files,rtl_distinct_line_locations=len(line_union),rtl_distinct_lines_hit=sum(line_union.values()),threshold='at least one event',scope='RTL source metrics coalesce identical source points across hierarchy/test roots; RTL original source only; appended instrumentation and testbench locations excluded from RTL percentages; user bins aggregated across instances and tests')
 (B/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
 print(json.dumps({k:summary[k] for k in ['user_bins','user_hit','user_missing','rtl_point_coverage']},indent=2))
 if summary['user_missing'] and not a.partial:raise SystemExit('Functional coverage gaps remain; see summary.json')
if __name__=='__main__':main()
