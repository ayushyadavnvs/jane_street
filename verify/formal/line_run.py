#!/usr/bin/env python3
"""Run bounded line task matrix and record actual status, including counterexamples."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
from line_prepare import prepare

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
PBE = ROOT / 'pbe_v1'  # the design; runs go in its build/


def tasks():
    block = (HERE / "line.sby").read_text().split("[tasks]\n", 1)[1].split("\n[options]", 1)[0]
    return {parts[0]: parts[1:] for line in block.splitlines() if (parts := line.split())}


def run_one(name, tags):
    build = PBE / "build/formal" / ("line_" + name)
    logfile = PBE / "build/formal" / ("line_" + name + ".log")
    started = time.monotonic()
    with logfile.open("w") as output:
        proc = subprocess.run([os.environ.get("SBY", "sby"), "-f", "-d", str(build),
                               "line.sby", name], cwd=HERE, stdout=output, stderr=subprocess.STDOUT)
    status = (build / "status").read_text().split()[0] if (build / "status").exists() else "NO_STATUS"
    expected = "FAIL" if "original" in tags else "PASS"
    text = logfile.read_text()
    failed = re.findall(r"Assert failed in (.+)", text)
    cover = re.findall(r"Reached cover statement in step \d+ at (.+)", text)
    return dict(task=name, tags=tags, status=status, expected_status=expected,
                returncode=proc.returncode, matched_expectation=status == expected and proc.returncode == 0,
                seconds=round(time.monotonic()-started, 3), depth=48 if "stuff" in tags else 164,
                failed_assertions=failed, covers=cover, workdir=str(build.relative_to(PBE)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--tasks", nargs="*")
    args = parser.parse_args()
    matrix = tasks()
    if args.tasks:
        matrix = {name: matrix[name] for name in args.tasks}
    prepare()
    source_hashes = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                     for path in (HERE / "line.sby", HERE / "line_roundtrip.sv", HERE / "line_stuff.sv",
                                  HERE / "line_properties.svh", PBE / "src/pbe_line.sv")}
    (PBE / "build/formal").mkdir(parents=True, exist_ok=True)
    results = []
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = [pool.submit(run_one, name, tags) for name, tags in matrix.items()]
        for future in as_completed(futures):
            row = future.result()
            results.append(row)
            print(f'{row["task"]}: {row["status"]} expected={row["expected_status"]} {row["seconds"]}s', flush=True)
    results.sort(key=lambda row: row["task"])
    evidence = ROOT / "verify/golden-model/evidence/round2/formal"
    evidence.mkdir(parents=True, exist_ok=True)
    receipt = dict(scope="bounded line-coder conformance; not induction", source_sha256=source_hashes, tasks=results,
                   matched=sum(row["matched_expectation"] for row in results), total=len(results))
    (evidence / "line_results.json").write_text(json.dumps(receipt, indent=2) + "\n")
    for row in results:
        if row["status"] == "FAIL":
            trace = PBE / row["workdir"] / "engine_0/trace.vcd"
            if trace.exists():
                shutil.copyfile(trace, evidence / ("line_" + row["task"] + ".vcd"))
    if not all(row["matched_expectation"] for row in results):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
