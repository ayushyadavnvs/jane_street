#!/usr/bin/env python3
"""Prepare observation-only D89/D91/D94 sources; never modify tracked RTL."""
from pathlib import Path
import subprocess
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
OUT=ROOT/'pbe_v1/build/formal/generated'

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    source=(ROOT/'src/pbe_host_spi.sv').read_text()
    props=(HERE/'host_properties.svh').read_text()
    props=props.replace('  reg f_past_valid = 0;', '''  reg f_mode = 0;
  reg [2:0] f_idle_edges = 0;
  reg f_expected_exit = 0;
  wire [3:0] f_stride = f_mode ? 4 : 1;
  reg f_past_valid = 0;''')
    props=props.replace("wire [7:0] f_complete = {f_received[6:0], mosi};", "wire [7:0] f_complete = f_mode ? {f_received[3:0],mosi_hi,mosi} : {f_received[6:0],mosi};")
    props=props.replace('      assert(!quad); // default wrapper ties quad_req low; include mode in induction', '      assert(quad == f_mode);\n      if(f_mode) begin assert(f_bit[1:0]==0); assert(f_read_shift[1:0]==0); end\n      assert(idle_sck == f_idle_edges);\n      assert(quad_exit == f_expected_exit);')
    props=props.replace('assert(miso == f_shifted_read_word[7]);', '''begin
          assert(miso == (f_mode ? f_shifted_read_word[4] : f_shifted_read_word[7]));
          if(f_mode) assert(miso_hi == f_shifted_read_word[7:5]);
        end''')
    props=props.replace("f_read_shift + 1'b1", 'f_read_shift + f_stride')
    props=props.replace("f_bit + 1'b1", 'f_bit + f_stride')
    props=props.replace('if (f_bit == 7)', 'if ((f_mode && f_bit == 4) || (!f_mode && f_bit == 7))')
    props=props.replace('    f_expected_wr <= 0;', '''    f_expected_exit <= 0;
    if (!rst_n) begin f_mode <= 0; f_idle_edges <= 0; end
    else if (cs_n) begin
      f_mode <= quad_req;
      if (f_rise) begin
        f_expected_exit <= f_idle_edges == 7;
        if (f_idle_edges != 7) f_idle_edges <= f_idle_edges + 1'b1;
      end
    end else f_idle_edges <= 0;
    f_expected_wr <= 0;''',1)
    (OUT/'ethernet_host.sv').write_text(source.replace('endmodule',props+'\nendmodule'))
    old=subprocess.check_output(['git','show','cabe10e^:src/pbe_host_spi.sv'],cwd=ROOT,text=True)
    # Export common state solely to strengthen induction of cycle equivalence.
    state='{sck_d,bitcnt,rx_sh,tx_sh,have_cmd,is_write,load_dly,addr,wr_en,wr_addr,wr_data,rd_done,rd_addr}'
    for name,text in [('host_new_equiv',source),('host_old_equiv',old)]:
        text=text.replace('module pbe_host_spi (',f'module {name} (')
        marker='    output logic [6:0] rd_addr\n);'
        assert marker in text
        text=text.replace(marker,'    output logic [6:0] rd_addr,\n    output wire [54:0] f_state\n);')
        text=text.replace('endmodule',f'assign f_state = {state};\nendmodule')
        (OUT/(name+'.sv')).write_text(text)
    crc_sources=[]
    for path,width in [(ROOT/'src/pbe_crc.sv',32),(ROOT/'pbe_v1/test/ref_pbe_crc16.sv',16)]:
        text=path.read_text()
        start=text.index('module ')
        end=text.index(');',start)
        text=text[:end]+f',\n    output wire [{width-1}:0] f_raw\n'+text[end:]
        text=text.replace('endmodule','assign f_raw = crc;\nendmodule')
        crc_sources.append(text)
    (OUT/'ethernet_crc_observers.sv').write_text('\n'.join(crc_sources))
    source=(ROOT/'src/pbe_line.sv').read_text()
    props=(HERE/'ethernet_line_properties.svh').read_text()
    (OUT/'ethernet_line.sv').write_text(source.replace('endmodule',props+'\nendmodule'))
if __name__=='__main__':main()
