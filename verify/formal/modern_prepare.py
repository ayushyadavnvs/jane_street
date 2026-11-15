#!/usr/bin/env python3
"""Freeze the pre-D89 D88 engine hierarchy, preserving PAGE and CAN semantics."""
import re,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];OUT=ROOT/'pbe_v1/build/formal/generated';OUT.mkdir(parents=True,exist_ok=True)
names=('pbe_engine','pbe_line','pbe_crc','pbe_bsync');parts=[]
for name in names:
 text=subprocess.check_output(['git','show',f'159650f:src/{name}.sv'],cwd=ROOT,text=True)
 for n in names:text=re.sub(r'\b'+n+r'\b',n+'_preeth',text)
 parts.append(text)
(OUT/'preeth_old.sv').write_text('\n'.join(parts))
