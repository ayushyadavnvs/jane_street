#!/usr/bin/env python3
"""Unbounded legacy line equivalence, all LINE2 values and free external inputs."""
from pathlib import Path
import subprocess,hashlib,json,re,argparse
parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--repair-only',action='store_true');args=parser.parse_args()
ROOT=Path(__file__).resolve().parents[2];OUT=ROOT/'pbe_v1/build/formal'/('legacy_repair_equiv' if args.repair_only else 'legacy_equiv');OUT.mkdir(parents=True,exist_ok=True)
revision='3cca934' if args.repair_only else 'cabe10e'
ports='''input clk,rst_n,clear,input [7:0] raw_cfg,cfg2,sync,input [15:0] period_m1,input out_msb_first,in_msb_first,a_in,a_early,b_in,ctl,input [4:0] ctl_param,input tx_put,tx_end,input [7:0] tx_data,input rx_take,output drive,a_out,b_out,tx_ready,rx_valid,output [7:0] rx_data,output frame_end,err'''
connection='.clk,.rst_n,.clear,.cfg(cfg),.cfg2,.sync,.period_m1,.out_msb_first,.in_msb_first,.a_in,.b_in,.tx_put,.tx_end,.tx_data,.rx_take,.drive,.a_out,.b_out,.tx_ready,.rx_valid,.rx_data,.frame_end,.err'
old=subprocess.check_output(['git','show',revision+':src/pbe_line.sv'],cwd=ROOT,text=True).replace('module pbe_line ','module pbe_line_old ')
# The old coder has implicit always-enabled stuffing. Expose that constant
# specification state so induction must prove the new tags remain enabled.
if not args.repair_only:old=old.replace('endmodule',"(* keep *) wire ns_mode=1'b0, q_ns=1'b0, tns=1'b0, n_ns=1'b0; endmodule")
new=(ROOT/'src/pbe_line.sv').read_text().replace('module pbe_line ','module pbe_line_new ')
wrappers=''
for name in ('old','new'):
 cfg="{raw_cfg[7],"+("raw_cfg[6]" if args.repair_only else "1'b0")+",raw_cfg[5:2],raw_cfg[1]&~raw_cfg[0],raw_cfg[0]}"
 extra=''
 if name=='new' or args.repair_only:
  extra=',.a_early,.ctl,.ctl_param' if args.repair_only else ',.a_early,.ctl(1\'b0),.ctl_param(5\'d0)'
 wrappers+=f'module {name}({ports}); wire [7:0] cfg={cfg}; pbe_line_{name} u({connection}{extra}); endmodule\n'
(OUT/'miter.sv').write_text(old+'\n'+new+'\n'+wrappers)
script='''read_verilog -sv miter.sv
proc
flatten old new
memory
async2sync
opt_clean
equiv_make -inames old new equiv
hierarchy -top equiv
opt_clean
equiv_simple
equiv_induct -seq 8
equiv_status -assert
'''
(OUT/'run.ys').write_text(script)
r=subprocess.run(['yosys','-ql','logfile.txt','run.ys'],cwd=OUT)
(OUT/'result.json').write_text(json.dumps(dict(command=['yosys','-ql','logfile.txt','run.ys'],returncode=r.returncode,old_revision=revision,new_sha256=hashlib.sha256((ROOT/'src/pbe_line.sv').read_bytes()).hexdigest(),scope='all external inputs and LINE2 values; mode 0..2; '+('LINE[6] and ctl free' if args.repair_only else 'LINE[6]=0, ctl=0')+'; induction'),indent=2)+'\n')
raise SystemExit(r.returncode)
