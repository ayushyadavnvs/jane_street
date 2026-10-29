#!/usr/bin/env python3
"""Scratch-only assertion/cover instrumentation; no tracked RTL edits."""
from pathlib import Path
import argparse,json,shutil
PBE=Path(__file__).resolve().parents[1]

def prepare(out=None):
 out=Path(out) if out else PBE/'build/coverage/src';out.mkdir(parents=True,exist_ok=True)
 manifests=[]
 def add(module,name,cond):
  manifests.append(dict(module=module,name=name,condition=cond))
  return f'    pbe_cov_{name}: cover ({cond});\n'
 eng='  reg [4:0] pbe_cov_previous_status;\n  always @(posedge clk) begin\n    if (!rst_n) pbe_cov_previous_status <= 0;\n    else pbe_cov_previous_status <= status;\n    if (rst_n) begin\n'
 for op in range(8):eng+=add('pbe_engine',f'opcode_{op}',f'exec && op == 3\'d{op}')
 for op,count,expr in [(0,8,'pin_act'),(5,2,'arg_hi'),(6,4,'flag_act'),(7,8,'ext_op')]:
  for sub in range(count):eng+=add('pbe_engine',f'sub_{op}_{sub}',f'exec && op == 3\'d{op} && {expr} == {sub}')
 for cond in range(8):eng+=add('pbe_engine',f'jump_{cond}',f'exec && op == OP_JMP && jmp_cnd == {cond}')
 for flag in range(2):
  for cond in range(4):eng+=add('pbe_engine',f'wait_{flag}_{cond}',f'exec && op == OP_WAIT && arg[5] == {flag} && wait_cnd == {cond}')
 eng+=add('pbe_engine','timeout_taken','tmo_hit')+add('pbe_engine','rx_overflow','ovf_now')+add('pbe_engine','d50_refetch','run && pm_wr && iv')
 for bit in range(5):
  eng+=add('pbe_engine',f'status_{bit}_set',f'status[{bit}] && !pbe_cov_previous_status[{bit}]')
  eng+=add('pbe_engine',f'status_{bit}_clear',f'!status[{bit}] && pbe_cov_previous_status[{bit}]')
 eng+='    end\n  end\n'
 line='  always @(posedge clk) if (rst_n && !clear && (drive || rx_valid || ts != T_IDLE || rs != R_IDLE)) begin\n'
 for mode in (1,2):
  for stuff in range(4):
   for pair in range(2):
    for byte in range(2):line+=add('pbe_line',f'line_{mode}_{stuff}_{pair}_{byte}',f'cfg[1:0] == {mode} && cfg[3:2] == {stuff} && cfg[4] == {pair} && cfg[5] == {byte}')
 line+='  end\n'
 top='  always @(posedge clk) if (rst_n) begin\n'+add('tt_um_pbe','both_engines','run == 2\'b11')+'  end\n'
 for source in sorted((PBE/'src').glob('*.sv')):
  s=source.read_text();extra={'pbe_engine.sv':eng,'pbe_line.sv':line,'tt_um_pbe.sv':top}.get(source.name,'')
  # Every used top can dump after final() in the simulator's normal shutdown path.
  extra+='\n  final begin $c("VerilatedCov::write();"); end\n'
  (out/source.name).write_text(s.replace('endmodule',extra+'\nendmodule'))
 (out.parent/'user_manifest.json').write_text(json.dumps(manifests,indent=2)+'\n')
 return out
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--out',type=Path);a=p.parse_args();print(prepare(a.out))
