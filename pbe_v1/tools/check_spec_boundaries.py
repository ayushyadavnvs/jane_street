#!/usr/bin/env python3
"""Verify BUG-058/059 contracts and preserve failing stronger assertions."""
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    build = ROOT / "build" / "spec_boundaries"
    build.mkdir(parents=True, exist_ok=True)
    executable = build / "spec_boundaries.vvp"
    subprocess.run([
        os.environ.get("IVERILOG", "iverilog"), "-g2012", "-s", "tb_spec_boundaries",
        "-o", str(executable), str(ROOT / "test" / "tb_spec_boundaries.sv"),
        *(str(ROOT.parent / "src" / name) for name in ("pbe_engine.sv", "pbe_line.sv", "pbe_crc.sv")),
    ], check=True)
    cases = [
        ("documented_contract", None, 0, "PASS: BUG-058/059"),
        ("original_prefetch_pc_window", "EXPECT_WINDOW_FENCE", 1, "original requested pc<=start_pc+63 property fails"),
        ("original_instruction_window", "EXPECT_INSTRUCTION_WINDOW_FENCE", 1, "sequential executed-instruction window property fails"),
        ("original_write_cancellation", "EXPECT_WRITE_CANCELLATION", 1, "old ready instruction executes on same PM-write edge"),
    ]
    results = []
    for name, plusarg, expected, marker in cases:
        command = [os.environ.get("VVP", "vvp"), str(executable)]
        if plusarg:
            command.append("+" + plusarg)
        proc = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (build / (name + ".log")).write_text(proc.stdout)
        passed = proc.returncode == expected and marker in proc.stdout
        results.append(dict(case=name, returncode=proc.returncode, expected_returncode=expected,
                            marker_found=marker in proc.stdout, passed=passed, output=proc.stdout))
        if not passed:
            raise AssertionError(f"{name}: exit {proc.returncode}, expected {expected}:\n{proc.stdout}")
        print(f"PASS {name}: exit={proc.returncode}" + (" (expected counterexample)" if plusarg else ""))
    (build / "results.json").write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()
