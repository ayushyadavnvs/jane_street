#!/usr/bin/env python3
"""Fault-injection audit. Mutate isolated temporary copies; never the checkout's RTL.

Every mutant invokes BOTH `make test` and `make diff`, even if the first fails.
Nonzero caused solely by timeout/infrastructure/compile errors is not a killed mutant.
No synthesis, physical-design, or GitHub workflow is invoked.
"""
from __future__ import annotations
import argparse
import concurrent.futures
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import sys
import subprocess
import tempfile
import time

PBE = Path(__file__).resolve().parents[1]
# Exact, single-site replacements are auditable and reject source drift.
MUTATIONS = [
 ('M01','jump','pbe_engine.sv',"3'd0:    jmp_take = 1'b1;", "3'd0:    jmp_take = 1'b0;"),
 ('M02','jump','pbe_engine.sv',"jmp_take = (x != 8'd0);", "jmp_take = (x == 8'd0);"),
 ('M03','jump','pbe_engine.sv',"3'd2:    jmp_take = pins_in[jmp_idx];", "3'd2:    jmp_take = !pins_in[jmp_idx];"),
 ('M04','delay','pbe_engine.sv','dly_cnt <= dly;', "dly_cnt <= dly + 1'b1;"),
 ('M05','tick','pbe_engine.sv','(div_cnt >= clkdiv)', '(div_cnt > clkdiv)'),
 ('M06','FIFO-empty','pbe_fifo.sv','assign empty = (wptr == rptr);','assign empty = (wptr != rptr);'),
 ('M07','FIFO-full','pbe_fifo.sv','(wptr[ADDR_BITS] != rptr[ADDR_BITS]);','(wptr[ADDR_BITS] == rptr[ADDR_BITS]);'),
 ('M08','FIFO-count','pbe_fifo.sv','assign count = wptr - rptr;',"assign count = wptr - rptr + 1'b1;"),
 ('M09','flag-clear','tt_um_pbe.sv','p_clr[7:0] | p_clr[15:8] | host_clr','p_clr[7:0] | p_clr[15:8] | 8\'h00'),
 ('M10','flag-clear','tt_um_pbe.sv','p_clr[7:0] | p_clr[15:8] | host_clr',"8'h00 | 8'h00 | host_clr"),
 ('M11','MSB-LSB','pbe_engine.sv','out_msb_first ? osr[7] : osr[0]','out_msb_first ? osr[0] : osr[7]'),
 ('M12','MSB-LSB','pbe_engine.sv',"in_msb_first ? {isr[6:0], pin_now} : {pin_now, isr[7:1]}","in_msb_first ? {pin_now, isr[7:1]} : {isr[6:0], pin_now}"),
 ('M13','CRC-init','pbe_crc.sv',"init_ones ? mask : '0", "init_ones ? '0 : mask"),
 ('M14','CRC-feedback','pbe_crc.sv','bit_in ^ |(crc & top)','bit_in ^ ~|(crc & top)'),
 ('M15','D50-pm-write','pbe_engine.sv',"if (pm_wr) iv <= 1'b0;", "if (1'b0) iv <= 1'b0;"),
 ('M16','D50-pm-write','pbe_engine.sv',"(iv && !exec) ? pc - 1'b1 : pc",'(iv && !exec) ? pc : pc'),
 ('M17','stuff-5-vs-6','pbe_line.sv',"(st == 2'd1) ? 3'd6 : 3'd5", "(st == 2'd1) ? 3'd5 : 3'd6"),
 ('M18','stuff-TX','pbe_line.sv',"wire n_stuff = !tstuff && st != 2'd0 && n_run == run_n;", "wire n_stuff = 1'b0;"),
 ('M19','timeout','pbe_engine.sv','tmo_cnt >= timeout','tmo_cnt > timeout'),
 ('M20','pin-ownership','tt_um_pbe.sv','(e_out[15:8] & pin_own) | (e_out[7:0] & ~pin_own)','(e_out[15:8] & ~pin_own) | (e_out[7:0] & pin_own)'),
 ('M21','FIFO-accept','pbe_fifo.sv',"if (pop && !empty) rptr <= rptr + 1'b1;", "if (pop) rptr <= rptr + 1'b1;"),
 ('M22','restart-side-effect','pbe_engine.sv','wire exec = issue && ready && !restart;','wire exec = issue && ready;'),
 ('M23','parity','pbe_engine.sv','no_par || (par_out ^ odd)','no_par || !(par_out ^ odd)'),
 ('M24','FIFO-ready','pbe_engine.sv','OP_FIFO: ready = arg_hi ? !rx_full : !tx_empty;','OP_FIFO: ready = arg_hi ? rx_full : tx_empty;'),
]

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def hdl_digest(path):
    """Hash HDL text ignoring comments/whitespace, preserving quoted strings."""
    clean = re.sub(r'"(?:\\.|[^"\\])*"|/\*[\s\S]*?\*/|//[^\n]*|\s+',
                   lambda m: m.group(0) if m.group(0).startswith('"') else '',
                   path.read_text())
    return hashlib.sha256(clean.encode()).hexdigest()


def diagnose(output):
    """Ignore harmless pytest hints and zero-failure summary counters."""
    lines = output.splitlines()
    interesting = [line.strip() for line in lines if re.search(
        r'FATAL:|^FAIL:|^\s+FAIL:|"reason":|AssertionError:|random_differential\s+FAIL\b', line)]
    reason = next((line for line in interesting if '"reason":' in line),
                  interesting[0] if interesting else None)
    if re.search(r'random_differential\s+FAIL\b', output):
        check = 'test_diff.random_differential'
    else:
        benches = re.findall(r'(tb_\w+)\.sv', output)
        check = benches[-1] if benches else None
    return reason, check


def run_check(cmd, cwd, env, timeout, log):
    started = time.monotonic()
    p = subprocess.Popen(cmd, cwd=cwd, env=env, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, text=True, start_new_session=True)
    try:
        output, _ = p.communicate(timeout=timeout)
        code, timed_out = p.returncode, False
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        output, _ = p.communicate()
        code, timed_out = None, True
    with gzip.open(log, 'wt') as f: f.write(output)
    # Compile and dependency failures are invalid/inconclusive, never a caught RTL bug.
    invalid = bool(re.search(r'syntax error|Unable to find the root module|No module named|command not found|No such file or directory|Unable to bind', output, re.I))
    reason, check = diagnose(output)
    if timed_out: status = 'inconclusive-timeout'
    elif invalid: status = 'inconclusive-infrastructure-or-compile'
    elif code == 0: status = 'survived'
    elif reason: status = 'caught'
    else: status = 'inconclusive-nonzero'
    return dict(command=cmd, returncode=code, seconds=round(time.monotonic()-started, 3),
                status=status, first_failure=reason[:1500] if reason else None, first_failing_check=check if code else None,
                log=log.name)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--jobs', type=int, default=2)
    ap.add_argument('--timeout', type=int, default=360)
    ap.add_argument('--n', type=int, default=1)
    ap.add_argument('--cycles', type=int, default=600)
    ap.add_argument('--seed', default='0x504245')
    ap.add_argument('--only', nargs='*', help='IDs, for reproducible selected reruns')
    ap.add_argument('--out', type=Path, default=PBE/'verification/evidence/round2/mutations')
    ap.add_argument('--keep-scratch', action='store_true')
    ap.add_argument('--allow-comment-changes', action='store_true', help='Allow concurrent comment-only RTL edits; HDL token hash must stay identical')
    args = ap.parse_args()
    if min(args.jobs, args.timeout, args.n, args.cycles) < 1:
        ap.error('jobs, timeout, n and cycles must be positive')
    if args.only and set(args.only) - {m[0] for m in MUTATIONS}:
        ap.error('unknown mutation IDs: ' + ', '.join(sorted(set(args.only) - {m[0] for m in MUTATIONS})))
    args.out = args.out.resolve(); args.out.mkdir(parents=True, exist_ok=True)
    python = str(Path(os.environ.get('PYTHON', PBE.parent/'.venv/bin/python')).absolute())
    if not Path(python).exists(): python = shutil.which('python3')
    manifest = [dict(id=m[0], category=m[1], file='src/'+m[2], before=m[3], after=m[4]) for m in MUTATIONS]
    (args.out/'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
    hashes = {str(p.relative_to(PBE)): digest(p) for p in (PBE/'src').glob('*.sv')}
    semantic_hashes = {str(p.relative_to(PBE)): hdl_digest(p) for p in (PBE/'src').glob('*.sv')}
    snapshot_dir = tempfile.TemporaryDirectory(prefix='pbe-mutation-baseline-')
    snapshot = Path(snapshot_dir.name)/'pbe_v1'
    shutil.copytree(PBE, snapshot, ignore=shutil.ignore_patterns('build','*.vvp','*.vcd','__pycache__','evidence'))
    # All jobs use one immutable baseline, including Makefile/model/test changes.
    baseline_commit = subprocess.check_output(['git','rev-parse','HEAD'], cwd=PBE, text=True).strip()
    env = os.environ.copy()
    # Never inherit a parent checkout's model path.
    env.pop('PYTHONPATH', None)
    def one(m):
        mid, category, filename, before, after = m
        tmp = Path(tempfile.mkdtemp(prefix='pbe-mutation-'+mid+'-'))
        scratch = tmp/'pbe_v1'
        shutil.copytree(snapshot, scratch, ignore=shutil.ignore_patterns('build','*.vvp','*.vcd','__pycache__','evidence'))
        path = scratch/'src'/filename
        source = path.read_text()
        if source.count(before) != 1: raise RuntimeError(f'{mid}: expected exactly one mutation site, got {source.count(before)}')
        path.write_text(source.replace(before,after))
        receipt = dict(id=mid, category=category, file='src/'+filename, before=before, after=after,
                       baseline_sha256=hashes['src/'+filename], baseline_hdl_sha256=semantic_hashes['src/'+filename], scratch=str(scratch), checks={})
        for name, cmd in [('test',['make','test',f'PYTHON={python}']),
                           ('diff',['make','diff',f'PYTHON={python}',f'N={args.n}',f'CYCLES={args.cycles}',f'SEED={args.seed}'])]:
            receipt['checks'][name] = run_check(cmd, scratch, env, args.timeout, args.out/(mid+'-'+name+'.log.gz'))
            print(mid, name, receipt['checks'][name]['status'], receipt['checks'][name]['seconds'], flush=True)
        receipt['caught_by'] = [k for k,v in receipt['checks'].items() if v['status']=='caught']
        (args.out/(mid+'.json')).write_text(json.dumps(receipt,indent=2)+'\n')
        if not args.keep_scratch: shutil.rmtree(tmp)
        return receipt
    selected = [m for m in MUTATIONS if not args.only or m[0] in args.only]
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        results = list(pool.map(one, selected))
    changed_comments = []
    for relative, original in hashes.items():
        if digest(PBE/relative) != original:
            if not args.allow_comment_changes or hdl_digest(PBE/relative) != semantic_hashes[relative]:
                raise RuntimeError('Tracked source changed during campaign: '+relative)
            changed_comments.append(relative)
    snapshot_dir.cleanup()
    summary = dict(seed=args.seed,n=args.n,cycles=args.cycles,jobs=args.jobs,
                   source_sha256=hashes,source_hdl_sha256=semantic_hashes, baseline_commit=baseline_commit,
                   python=sys.version, comment_only_source_changes=changed_comments, results=results,
                   caught=sum(bool(r['caught_by']) for r in results), total=len(results))
    (args.out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    print(json.dumps({k:summary[k] for k in ('caught','total')},indent=2))
    return 0 if all(r['caught_by'] for r in results) else 1

if __name__ == '__main__': raise SystemExit(main())
