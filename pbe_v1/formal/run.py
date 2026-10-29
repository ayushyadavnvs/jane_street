#!/usr/bin/env python3
"""Run/collect formal jobs with exact source/configuration provenance.

Known counterexamples are FAIL results with an explicit expected_status, never
proofs. --collect accepts only already-finished jobs whose expanded config and
all copied input files match this checkout exactly. No RTL is changed.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time

HERE=Path(__file__).resolve().parent
PBE=HERE.parent
BUILD=PBE/'build/formal'

def section(config, name):
    match=re.search(r'^\['+re.escape(name)+r'\]\s*\n(.*?)(?=^\[|\Z)',config,re.M|re.S)
    return match.group(1) if match else ''

def option(config, name):
    values=re.findall(r'^'+re.escape(name)+r'\s+(\S+)',section(config,'options'),re.M)
    return values[-1] if values else None

def matrix(block):
    text=(HERE/(block+'.sby')).read_text()
    result=[]
    for line in section(text,'tasks').splitlines():
        parts=line.split()
        if not parts or parts[0].startswith('#'): continue
        name,tags=parts[0],parts[1:]
        expected='FAIL' if ('original' in tags or block=='engine' and name in ('pc_window','instruction_window')) else 'PASS'
        folder=block if block in ('fifo','host') and name=='prove' else block+'_'+name
        result.append(dict(block=block,task=name,tags=tags,expected_status=expected,folder=folder))
    return result

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def cover_locations(logtext):
    return re.findall(r'Reached cover statement in step \d+ at (.+)',logtext)

def verify_inputs(job):
    output=BUILD/job['folder']
    expanded=subprocess.check_output([os.environ.get('SBY','sby'),'--dumpcfg',job['block']+'.sby',job['task']],cwd=HERE,text=True)
    copied=(output/'config.sby').read_text()
    if expanded.strip()!=copied.strip(): raise RuntimeError('resolved formal configuration changed: '+job['folder'])
    hashes={}
    for line in section(expanded,'files').splitlines():
        if not line.strip() or line.lstrip().startswith('#'): continue
        fields=shlex.split(line)
        source=(HERE/fields[-1]).resolve()
        target=fields[0] if len(fields)>1 else source.name
        dest=output/'src'/target
        if sha(source)!=sha(dest): raise RuntimeError('formal input changed: '+str(source))
        hashes[str(source.relative_to(PBE.parent))]=sha(source)
    return expanded,hashes

def one(job,collect,timeout):
    started=time.monotonic(); output=BUILD/job['folder']
    rc=None; timed_out=False
    if not collect:
        log=BUILD/(job['folder']+'.runner.log')
        with log.open('w') as f:
            process=subprocess.Popen([os.environ.get('SBY','sby'),'-f','-d',str(output),job['block']+'.sby',job['task']],cwd=HERE,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
            try: rc=process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid,signal.SIGKILL);process.wait();timed_out=True
    status=(output/'status').read_text().split()[0] if (output/'status').is_file() else 'NO_STATUS'
    logtext=(output/'logfile.txt').read_text() if (output/'logfile.txt').is_file() else ''
    error=None;inputs={};mode=None;depth=None
    try:
        expanded,inputs=verify_inputs(job)
        options=section(expanded,'options')
        mode=option(expanded,'mode')
        value=option(expanded,'depth');depth=int(value) if value else None
    except Exception as exc: error=str(exc)
    induction='Temporal induction successful' in logtext
    matched=(status==job['expected_status'] and not timed_out and error is None and
             (collect or rc==0) and (mode!='prove' or status!='PASS' or induction))
    if job['expected_status']=='FAIL' and not re.search(r'Assert failed|failed assertion',logtext): matched=False
    result=dict(job,status=status,matched_expectation=matched,mode=mode,depth=depth,
                unbounded_k_induction=bool(mode=='prove' and status=='PASS' and induction),
                collected=collect,returncode=rc,timeout=timed_out,error=error,
                input_sha256=inputs,seconds=round(time.monotonic()-started,3),
                failed_assertions=re.findall(r'Assert failed in (.+)',logtext),
                covers=cover_locations(logtext),
                workdir=str(output.relative_to(PBE)))
    # Retain raw evidence separately from compact report; this is generated output.
    evidence=BUILD/'receipts';evidence.mkdir(exist_ok=True)
    with gzip.open(evidence/(job['folder']+'.log.gz'),'wt') as f: f.write(logtext)
    return result

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--block',choices=['all','fifo','host','line','engine'],default='all')
    p.add_argument('--jobs',type=int,default=3)
    p.add_argument('--timeout',type=int,default=300)
    p.add_argument('--collect',action='store_true',help='validate complete existing artifacts, without rerunning solvers')
    a=p.parse_args()
    if a.jobs<1 or a.timeout<1: p.error('jobs and timeout must be positive')
    BUILD.mkdir(parents=True,exist_ok=True)
    blocks=['fifo','host','line','engine'] if a.block=='all' else [a.block]
    for block in blocks: subprocess.run([sys.executable,str(HERE/(block+'_prepare.py'))],check=True,cwd=HERE)
    jobs=[j for block in blocks for j in matrix(block)]
    results=[]
    with ThreadPoolExecutor(max_workers=a.jobs) as pool:
        for f in as_completed([pool.submit(one,j,a.collect,a.timeout) for j in jobs]):
            r=f.result();results.append(r)
            print(f'{r["folder"]}: {r["status"]}, expected {r["expected_status"]}, verified={r["matched_expectation"]}',flush=True)
    results.sort(key=lambda r:r['folder'])
    report=dict(results=results,total=len(results),matched=sum(r['matched_expectation'] for r in results),
                proven=sum(r['unbounded_k_induction'] for r in results),
                bounded_pass=sum(r['status']=='PASS' and r['mode']=='bmc' for r in results),
                expected_counterexamples=sum(r['status']=='FAIL' and r['matched_expectation'] for r in results),
                note='Expected counterexamples remain failed properties; matched does not mean all properties proven.')
    path=BUILD/('results_'+a.block+'.json');path.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k!='results'},indent=2))
    return 0 if report['matched']==report['total'] else 1

if __name__=='__main__': raise SystemExit(main())
