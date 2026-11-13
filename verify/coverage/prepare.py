#!/usr/bin/env python3
"""Scratch-only assertion/cover instrumentation; no tracked RTL edits."""
from pathlib import Path
import argparse,json,shutil
PBE=Path(__file__).resolve().parents[2]/'pbe_v1'  # the design

def prepare(out=None, ethernet=False):
 out=Path(out) if out else PBE/'build/coverage/src';out.mkdir(parents=True,exist_ok=True)
 manifests=[]
 def add(module,name,cond):
  manifests.append(dict(module=module,name=name,condition=cond))
  return f'    pbe_cov_{name}: cover ({cond});\n'
 eng='  reg [7:0] pbe_cov_previous_status;\n  always @(posedge clk) begin\n    if (!rst_n) pbe_cov_previous_status <= 0;\n    else pbe_cov_previous_status <= status;\n    if (rst_n) begin\n'
 for op in range(8):eng+=add('pbe_engine',f'opcode_{op}',f'exec && op == 3\'d{op}')
 for op,count,expr in [(0,8,'pin_act'),(5,2,'arg_hi'),(6,4,'flag_act'),(7,8,'ext_op')]:
  for sub in range(count):eng+=add('pbe_engine',f'sub_{op}_{sub}',f'exec && op == 3\'d{op} && {expr} == {sub}')
 for cond in range(8):eng+=add('pbe_engine',f'jump_{cond}',f'exec && op == OP_JMP && jmp_cnd == {cond}')
 for flag in range(2):
  for cond in range(4):eng+=add('pbe_engine',f'wait_{flag}_{cond}',f'exec && op == OP_WAIT && arg[5] == {flag} && wait_cnd == {cond}')
 eng+=add('pbe_engine','timeout_taken','tmo_hit')+add('pbe_engine','rx_overflow','ovf_now')+add('pbe_engine','d50_refetch','run && pm_wr && iv')
 for kind in range(4):eng+=add('pbe_engine',f'pull_kind_{kind}',f'exec && op == OP_FIFO && !arg_hi && arg[7:6] == {kind}')
 eng+=add('pbe_engine','linectl_width','lctl && bsm && !arg[4]')+add('pbe_engine','linectl_action','lctl && bsm && arg[4]')
 eng+=add('pbe_engine','line_event_vector','lv_hit')
 # D82: 8-bit pc and START_PC in each engine's own 256-word memory
 eng+=add('pbe_engine','start_pc_upper_half','exec && start_pc[7]')+add('pbe_engine','exec_word_255','exec && iv && pc == 8\'d0')
 # D83: PAGE, a jump into another page, a PAGE cleared by restart or a timeout
 eng+=add('pbe_engine','page_executed','exec && page_op')+add('pbe_engine','jump_other_page','exec && jump && pg_set && pg_num != cur_off[7:6]')
 eng+=add('pbe_engine','page_cleared','pg_set && (restart || tmo_hit || lv_hit)')
 eng+=add('pbe_engine','jump_wraps_256','exec && jump && ({1\'b0, start_pc} + {3\'b0, arg[5:0]}) > 9\'d255')
 for bit in range(8):
  eng+=add('pbe_engine',f'status_{bit}_set',f'status[{bit}] && !pbe_cov_previous_status[{bit}]')
  eng+=add('pbe_engine',f'status_{bit}_clear',f'!status[{bit}] && pbe_cov_previous_status[{bit}]')
 eng+='    end\n  end\n'
 line='  always @(posedge clk) if (rst_n && !clear && (drive || rx_valid || ts != T_IDLE || rs != R_IDLE)) begin\n'
 for mode in (1,2):
  for stuff in range(4):
   for pair in range(2):
    for byte in range(2):line+=add('pbe_line',f'line_{mode}_{stuff}_{pair}_{byte}',f'cfg[1:0] == {mode} && cfg[3:2] == {stuff} && cfg[4] == {pair} && cfg[5] == {byte}')
 line+='  end\n'
 bs='  always @(posedge clk) if (rst_n && !clear) begin\n'
 for st,name in enumerate(['integ','idle','frame','tail','eflag','edwait','edelim','busoff']):
  bs+=add('pbe_bsync',f'bsync_state_{name}',f'cs == 3\'d{st}')
 for name,cond in [('own_start','own_start'),('foreign_start','hard'),('late_join','late_join'),
                   ('arbitration_lost','arb_lost'),('bit_error','bit_err'),('frame_sent','sent'),
                   ('error_detected','e_now'),('passive_flag','cs == C_EFLAG && flag_on && flag_pas'),
                   ('active_flag','cs == C_EFLAG && flag_on && !flag_pas'),('stuff_slot','sample && slot_stuff'),
                   ('ack_given','cs == C_TAIL && drv'),('unit_1','sample && cs == C_FRAME && width == 1 && rx_valid == 0 && rbits == 0'),
                   ('unit_3','sample && cs == C_FRAME && width == 3 && rbits == 2'),('unit_4','sample && cs == C_FRAME && width == 4 && rbits == 3'),
                   ('unit_7','sample && cs == C_FRAME && width == 7 && rbits == 6'),('unit_8','sample && cs == C_FRAME && width == 8 && rbits == 7'),
                   ('busoff_recovered','cs == C_BUSOFF && sample && rseq == 7\'d127 && rrun == 4\'d10 && b')]:
  bs+=add('pbe_bsync',f'bsync_{name}',cond)
 bs+='  end\n'
 top='  always @(posedge clk) if (rst_n) begin\n'+add('tt_um_pbe','both_engines','run == 2\'b11')
 # D82: each engine's memory written, a write while the other engine runs, the SRAM's second refetch
 top+=add('tt_um_pbe','pm_write_engine0','pm_wr_e[0]')+add('tt_um_pbe','pm_write_engine1','pm_wr_e[1]')
 top+=add('tt_um_pbe','pm_write_other_running','(pm_wr_e[0] && run[1]) || (pm_wr_e[1] && run[0])')
 top+=add('tt_um_pbe','pm_second_refetch','pm_wr_q != 2\'b00 && pm_wr_e == 2\'b00')+'  end\n'
 host=crc=''
 if ethernet:
  def block(module,rows):
   return '  always @(posedge clk) if (rst_n) begin\n'+''.join(add(module,n,c) for n,c in rows)+'  end\n'
  host=block('pbe_host_spi',[
   ('quad_command','quad && !cs_n && sck_rise && last_bit && !have_cmd'),
   ('quad_write','quad && wr_en'),('quad_read','quad && rd_done'),
   ('quad_load','quad && load_dly[1] && !cs_n'),
   ('quad_skip_fall','quad && sck_fall && bitcnt == 0 && !cs_n'),
   ('quad_mode_request_inside','!cs_n && quad_req != quad'),
   ('quad_latch_high','cs_n && quad_req != quad'),
   ('quad_partial_abort','cs_n && bitcnt == 4'),
   ('quad_exit_seven','cs_n && sck_rise && idle_sck == 6'),
   ('quad_exit_eight','quad_exit'),('quad_idle_counter_reset','!cs_n && idle_sck != 0'),
   *[(f'quad_stream_{a:02x}',f'quad && !cs_n && no_incr && addr == 7\'h{a:02x} && (wr_en || rd_done)') for a in (7,22,38)]])
  crc=block('pbe_crc',[(f'crc_width_{w}',f'width_m1 == 5\'d{w-1} && step && !init') for w in range(17,33)]+[
   ('crc_wide_reflected','width_m1[4] && out_rev && step'),('crc_wide_plain','width_m1[4] && !out_rev && step'),
   ('crc_wide_init_zero','width_m1[4] && init && !init_ones'),('crc_wide_init_ones','width_m1[4] && init && init_ones'),
   ('crc_init_wins_step','width_m1[4] && init && step'),('crc_wide_good','width_m1[4] && ok'),('crc_wide_bad','width_m1[4] && !ok')])
  eng+=block('pbe_engine',[
   ('wide_osrcrc_b2','exec && op == OP_EXT && ext_op == 1 && crc_wide && arg[3:0] == 8'),
   ('wide_osrcrc_b3','exec && op == OP_EXT && ext_op == 1 && crc_wide && arg[3:0] == 9'),
   ('wide_osrcrc_left_ignored','exec && op == OP_EXT && ext_op == 1 && crc_wide && arg[2]'),
   ('narrow_osrcrc_param3','exec && op == OP_EXT && ext_op == 1 && !crc_wide && arg[3]'),
   ('linectl_non_bsync_off','lctl && !bsm && arg[0]'),('linectl_non_bsync_on','lctl && !bsm && arg[1]'),
   ('linectl_non_bsync_both','lctl && !bsm && arg[1:0] == 3')])
  line+=block('pbe_line',[
   *[(f'manchester_polarity_{p}',f'manch && minv == {p} && drive') for p in range(2)],
   *[(f'manchester_period_{p}',f'manch && period_m1 == 16\'d{p} && drive') for p in (3,4,5,6,19)],
   ('manchester_max_period','manch && period_m1 == 16\'hffff && rs == R_RUN'),
   ('manchester_bit','manch && !bytes && drive'),('manchester_byte','manch && bytes && drive'),
   ('manchester_msb','manch && out_msb_first && drive'),('manchester_lsb','manch && !out_msb_first && drive'),
   ('manchester_sync_tx','manch && sync != 0 && drive'),('manchester_idle_wait_ignored','manch && cfg2[6] && drive'),
   ('manchester_flag_ignored','manch && cfg[6] && drive'),('manchester_stuff_ignored','manch && cfg[3:2] != 0 && drive'),
   ('manchester_early_edge','manch && m_edge && m_early && rs == R_RUN'),
   ('manchester_late_edge','manch && m_edge && !m_early && rs == R_RUN'),
   ('manchester_boundary_skip','manch && m_edge && !m_mid && rs == R_RUN'),
   ('manchester_short_glitch','manch && a_d == a_in && a_early != a_in'),
   ('manchester_carrier_sync','manch && m_lost && !hunting && sync != 0 && rs == R_RUN'),
   ('manchester_carrier_no_sync','manch && m_lost && sync == 0 && rs == R_RUN'),
   ('manchester_hunt_loss','manch && m_lost && hunting && rs == R_RUN'),
   ('manchester_rx_overrun','manch && rx_valid && !rx_take && m_mid && rbits == 7'),
   ('manchester_tail','manch && ts == T_SE0A && drive'),
   ('stuff_ctl_off','ctl && ctl_param[0] && !ctl_param[1]'),('stuff_ctl_on_wins','ctl && ctl_param[1:0] == 3'),
   ('stuff_queued_tag','q_valid && q_ns != ns_mode'),('stuff_shifter_tag','tbits != 0 && tns != ns_mode'),
   ('stuff_due_before_no_stuff','tstuff && q_valid && q_ns'),
   ('flag_low_frame_end','flagd && frame_end && !a_in'),
   ('flag_run_reset','flagd && frame_end && rrun == 0'),
   ('flag_continuous_receive','flagd && frame_end && rs == R_RUN')])
  top+=block('tt_um_pbe',[('hostcfg_enabled','host_quad'),('quad_mux_active','quad && !host_s2[1]')])
 for source in sorted((PBE/'src').glob('*.sv')):
  s=source.read_text();extra={'pbe_engine.sv':eng,'pbe_line.sv':line,'tt_um_pbe.sv':top,'pbe_bsync.sv':bs,'pbe_host_spi.sv':host,'pbe_crc.sv':crc}.get(source.name,'')
  # Every used top can dump after final() in the simulator's normal shutdown path.
  extra+='\n  final begin $c("VerilatedCov::write();"); end\n'
  (out/source.name).write_text(s.replace('endmodule',extra+'\nendmodule'))
 (out.parent/'user_manifest.json').write_text(json.dumps(manifests,indent=2)+'\n')
 return out
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--out',type=Path);a=p.parse_args();print(prepare(a.out))
