#!/usr/bin/env python3
"""Compare a receipt's Python version with an independently captured runtime."""
import argparse,json
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('receipt',type=Path);p.add_argument('probe',type=Path);a=p.parse_args()
receipt=json.loads(a.receipt.read_text());probe=json.loads(a.probe.read_text())
claimed=receipt['tools']['python'].split()[0];actual=probe['version'].split()[0]
if claimed!=actual:raise SystemExit(f'VERSION MISMATCH: receipt={claimed} runtime={actual}')
print(f'VERSION MATCH: receipt={claimed} independently probed runtime={actual}')
