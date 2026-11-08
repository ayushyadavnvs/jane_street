// "Default configuration = today's behaviour" (D65-D71): with LINE2 = 0 and the new
// instruction encodings unused, the line coder and the engine produce exactly the outputs of
// the pre-CAN design (main 797314f, renamed *_old by bsync_prepare.py), every clock, from any
// inputs. Bounded equivalence (two copies, shared free inputs).
module default_equiv(input wire clk);
  reg f_past = 0;
  always @(posedge clk) f_past <= 1;
  (* anyseq *) reg rst_n, clear, tx_put, tx_end, rx_take, a_in, b_in, omsb, imsb;
  (* anyseq *) reg [7:0] cfg, sync, tx_data;
`ifdef F_ENGINE
  (* anyseq *) reg run, restart, pm_wr, tx_empty, rx_full, hci, htc, hoc, hlc;
  (* anyseq *) reg [15:0] instr, clkdiv, crc_poly, timeout, crc_good;
  (* anyseq *) reg [7:0] crc_cfg, line_cfg, pins, txd;
  (* anyseq *) reg [7:0] start_pc;  // 8 bits since D82; the old engine takes [6:0]
  (* anyseq *) reg [3:0] flags;
  (* anyseq *) reg [2:0] pin_base, jmp_pin;
  wire [2:0] op = instr[15:13];
  wire [8:0] arg = instr[12:4];
  // the new encodings are excluded: PULL NOWAIT/MARK/REWIND and OSRCRC LEFT
  always @* begin
    assume(!(op == 3'd5 && !arg[8] && arg[7:6] != 2'd0));
    assume(!(op == 3'd7 && arg[8:6] == 3'd1 && arg[2]));
    assume(clkdiv < 16'd4 && timeout < 16'd4);   // keeps the bounded search interesting
  end
  wire [7:0] st_new; wire [4:0] st_old;
  wire [15:0] crc_new, crc_old;
  wire [7:0] pc_new, pcd_new;
  wire [6:0] pc_old, pcd_old;
  wire [7:0] po_new, po_old, poe_new, poe_old, rxd_new, rxd_old;
  wire [3:0] fs_new, fs_old, fc_new, fc_old;
  wire pop_new, pop_old, push_new, push_old, irq_new, irq_old;
  pbe_engine n(.clk, .rst_n, .run, .restart, .clkdiv, .pin_base, .jmp_pin, .out_msb_first(omsb),
    .in_msb_first(imsb), .start_pc, .crc_poly, .crc_cfg, .timeout, .line_cfg, .coder_cfg(cfg),
    .coder_cfg2(8'd0), .sync, .crc_good, .host_crc_init(hci), .host_tmo_clr(htc), .host_ovf_clr(hoc),
    .host_lerr_clr(hlc), .host_arb_clr(1'b0), .host_berr_clr(1'b0), .host_sent_clr(1'b0),
    .status(st_new), .crc_now(crc_new), .can_tec(), .can_rec(), .can_state(), .pc(pc_new), .pc_copy(),
    .pc_d(pcd_new), .instr, .pm_wr, .pins_in(pins), .pins_out(po_new), .pins_oe(poe_new),
    .tx_data(txd), .tx_empty, .tx_pop(pop_new), .tx_mark(), .tx_rewind(), .rx_data(rxd_new), .rx_full,
    .rx_push(push_new), .flags, .flag_set(fs_new), .flag_clr(fc_new), .irq(irq_new));
  pbe_engine_old o(.clk, .rst_n, .run, .restart, .clkdiv, .pin_base, .jmp_pin, .out_msb_first(omsb),
    .in_msb_first(imsb), .start_pc(start_pc[6:0]), .crc_poly, .crc_cfg, .timeout, .line_cfg, .coder_cfg(cfg),
    .sync, .crc_good, .host_crc_init(hci), .host_tmo_clr(htc), .host_ovf_clr(hoc),
    .host_lerr_clr(hlc), .status(st_old), .crc_now(crc_old), .pc(pc_old), .pc_copy(),
    .pc_d(pcd_old), .instr, .pm_wr, .pins_in(pins), .pins_out(po_old), .pins_oe(poe_old),
    .tx_data(txd), .tx_empty, .tx_pop(pop_old), .rx_data(rxd_old), .rx_full,
    .rx_push(push_old), .flags, .flag_set(fs_old), .flag_clr(fc_old), .irq(irq_old));
  always @(posedge clk) begin
    if (!f_past) assume(!rst_n);
    if (f_past) begin
      assert(st_new == {3'b000, st_old});
      // D82: pc is 8 bits (mod 256), the old one 7 (mod 128). pc only ever changes by +1, -1
      // or start_pc + offset, so the two agree modulo 128: compare the low 7 bits.
      assert(crc_new == crc_old && pc_new[6:0] == pc_old && pcd_new[6:0] == pcd_old);
      assert(po_new == po_old && poe_new == poe_old && rxd_new == rxd_old);
      assert(fs_new == fs_old && fc_new == fc_old && pop_new == pop_old && push_new == push_old);
      assert(irq_new == irq_old);
    end
  end
`else
  (* anyseq *) reg [15:0] period_m1;
  wire dn, an, bn, rn, rvn, fen, en; wire [7:0] rdn;
  wire d0, a0, b0, r0, rv0, fe0, e0; wire [7:0] rd0;
  pbe_line n(.clk, .rst_n, .clear, .cfg, .cfg2(8'd0), .sync, .period_m1, .out_msb_first(omsb),
    .in_msb_first(imsb), .a_in, .b_in, .drive(dn), .a_out(an), .b_out(bn), .tx_put, .tx_end,
    .tx_data, .tx_ready(rn), .rx_valid(rvn), .rx_data(rdn), .rx_take, .frame_end(fen), .err(en));
  pbe_line_old o(.clk, .rst_n, .clear, .cfg, .sync, .period_m1, .out_msb_first(omsb),
    .in_msb_first(imsb), .a_in, .b_in, .drive(d0), .a_out(a0), .b_out(b0), .tx_put, .tx_end,
    .tx_data, .tx_ready(r0), .rx_valid(rv0), .rx_data(rd0), .rx_take, .frame_end(fe0), .err(e0));
  always @(posedge clk) begin
    if (!f_past) assume(!rst_n);
    assume(period_m1 < 16'd4);
    if (f_past) assert({dn, an, bn, rn, rvn, rdn, fen, en} == {d0, a0, b0, r0, rv0, rd0, fe0, e0});
  end
`endif
endmodule
