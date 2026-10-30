#!/usr/bin/env python3
"""Create assertion-only engine instrumentation outside tracked RTL."""
from pathlib import Path

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
OUT=ROOT/'pbe_v1/build/formal/generated'

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    source=(ROOT/'src/pbe_engine.sv').read_text()
    port='    output logic        irq\n);'
    assert source.count(port)==1
    source=source.replace(port,'    output logic        irq,\n    input logic [15:0] f_mem_current\n);')
    assertions=r'''
  // Verification-only observer. Instrumentation is generated, never applied to src/.
  reg f_past = 0;
  always @(posedge clk) begin
    f_past <= 1;
    if (f_past && rst_n) begin
      if (`F_KIND == 0) begin
        assert ((flag_set & flag_clr) == 0);
        assert (!tx_pop || !tx_empty);
        assert (!rx_push || !rx_full);
        if ($past(rst_n && restart)) begin
          assert (poe == 0);
          assert (x == 0 && osr == 0 && isr == 0);
          assert (!blocked && dly_cnt == 0 && !tmo_seen && !rx_ovf);
          assert (pc == start_pc);
          assert (pout == $past(pout));
        end
        if (!$past(rst_n)) begin
          assert (pout == 0 && poe == 0);
          assert (x == 0 && osr == 0 && isr == 0);
        end
      end
      if (`F_KIND == 1 && iv) assert (instr_q == f_mem_current);
      // Original requested assertions are kept, not assumed away.
      if (`F_KIND == 2) assert (((pc - start_pc) & 7'h7f) < 64);
      if (`F_KIND == 3 && iv) assert ((((pc - 1'b1) - start_pc) & 7'h7f) < 64);
    end
  end
  reg [7:0] f_wait_ticks = 0;
  reg f_waiting = 0;
  reg [5:0] f_clock_age = 0;
  always @(posedge clk) begin
    if (!rst_n || restart) begin
      f_clock_age <= 0;
      f_wait_ticks <= 0;
      f_waiting <= 0;
    end else if (`F_KIND == 4) begin
      if (f_clock_age < 41) f_clock_age <= f_clock_age + 1;
      if (f_clock_age >= 40) assert(tmo_seen); // forces nonvacuous completion
      if (issue && !ready && !blocked) begin
        f_waiting <= 1;
        f_wait_ticks <= 0;
      end
      if (f_waiting && tick) f_wait_ticks <= f_wait_ticks + 1;
      if (tmo_hit) begin
        assert (f_waiting);
        assert (f_wait_ticks <= timeout + 2);
        f_waiting <= 0;
      end
      if (f_waiting) begin
        assert (f_wait_ticks <= timeout + 2);
      end
      if (f_past && $past(tmo_hit)) begin
        assert (pc == start_pc + {1'b0,line_cfg[5:0]});
        assert (tmo_seen && !blocked);
      end
    end
  end
'''
    source=source.rsplit('endmodule',1)[0]+assertions+'\nendmodule\n'
    (OUT/'engine_instrumented.sv').write_text(source)

if __name__=='__main__': main()
