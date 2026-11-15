// D88 engine versus D94, full 8-bit PC/PAGE and arbitrary live configuration.
module modern_equiv(input wire clk);
  reg f_past = 0;
  always @(posedge clk) f_past <= 1;
  (* anyseq *) reg rst_n, clear, tx_put, tx_end, rx_take, a_in, b_in, omsb, imsb;
  (* anyseq *) reg [7:0] cfg, sync, tx_data;
  // D90/D94: default equivalence excludes newly assigned reserved encodings.
  always @* begin assume(cfg[1:0] != 2'd3); assume(!cfg[6]); end
  (* anyseq *) reg run, restart, pm_wr, tx_empty, rx_full, hci, htc, hoc, hlc;
  (* anyseq *) reg [15:0] instr, clkdiv, crc_poly, timeout, crc_good;
  (* anyseq *) reg [7:0] crc_cfg, line_cfg, pins, txd;
  (* anyseq *) reg [7:0] start_pc;  // 8 bits since D82; the old engine takes [6:0]
  (* anyseq *) reg [3:0] flags;
  (* anyseq *) reg [2:0] pin_base, jmp_pin;
  wire [2:0] op = instr[15:13];
  wire [8:0] arg = instr[12:4];
  (* anyseq *) reg [7:0] cfg2;
  always @* begin
    // Only D94's new non-bsync LINECTL action is outside the legacy instruction domain.
    assume(!(op == 7 && arg[8:6] == 7 && arg[4] && !arg[5] && !cfg2[5]));
    assume(clkdiv < 4 && timeout < 4);
  end
  wire [7:0] st_new; wire [7:0] st_old;
  wire [31:0] crc_new; wire [15:0] crc_old;
  wire [7:0] pc_new, pcd_new;
  wire [7:0] pc_old, pcd_old;
  wire [7:0] po_new, po_old, poe_new, poe_old, rxd_new, rxd_old;
  wire [3:0] fs_new, fs_old, fc_new, fc_old;
  wire pop_new, pop_old, push_new, push_old, irq_new, irq_old;
  pbe_engine n(.clk, .rst_n, .run, .restart, .clkdiv, .pin_base, .jmp_pin, .out_msb_first(omsb),
    .in_msb_first(imsb), .start_pc, .crc_poly({16'd0, crc_poly}), .crc_wide(1'b0), .crc_cfg, .timeout, .line_cfg, .coder_cfg(cfg),
    .coder_cfg2(cfg2), .sync, .crc_good({16'd0, crc_good}), .host_crc_init(hci), .host_tmo_clr(htc), .host_ovf_clr(hoc),
    .host_lerr_clr(hlc), .host_arb_clr(1'b0), .host_berr_clr(1'b0), .host_sent_clr(1'b0),
    .status(st_new), .crc_now(crc_new), .can_tec(), .can_rec(), .can_state(), .pc(pc_new), .pc_copy(),
    .pc_d(pcd_new), .instr, .pm_wr, .pins_in(pins), .pins_in_n(pins), .pins_out(po_new), .pins_oe(poe_new),
    .tx_data(txd), .tx_empty, .tx_pop(pop_new), .tx_mark(), .tx_rewind(), .rx_data(rxd_new), .rx_full,
    .rx_push(push_new), .flags, .flag_set(fs_new), .flag_clr(fc_new), .irq(irq_new));
  pbe_engine_preeth o(.clk, .rst_n, .run, .restart, .clkdiv, .pin_base, .jmp_pin, .out_msb_first(omsb),
    .in_msb_first(imsb), .start_pc, .crc_poly, .crc_cfg, .timeout, .line_cfg, .coder_cfg(cfg), .coder_cfg2(cfg2),
    .sync, .crc_good, .host_crc_init(hci), .host_tmo_clr(htc), .host_ovf_clr(hoc),
    .host_lerr_clr(hlc), .host_arb_clr(1'b0), .host_berr_clr(1'b0), .host_sent_clr(1'b0), .can_tec(), .can_rec(), .can_state(), .status(st_old), .crc_now(crc_old), .pc(pc_old), .pc_copy(),
    .pc_d(pcd_old), .instr, .pm_wr, .pins_in(pins), .pins_out(po_old), .pins_oe(poe_old),
    .tx_data(txd), .tx_empty, .tx_pop(pop_old), .rx_data(rxd_old), .rx_full,
    .rx_push(push_old), .flags, .flag_set(fs_old), .flag_clr(fc_old), .irq(irq_old));
  always @(posedge clk) begin
    if (!f_past) assume(!rst_n);
    if (f_past) begin
      assert(st_new == st_old);
      assert(crc_new == crc_old && pc_new == pc_old && pcd_new == pcd_old);
      assert(po_new == po_old && poe_new == poe_old && rxd_new == rxd_old);
      assert(fs_new == fs_old && fc_new == fc_old && pop_new == pop_old && push_new == push_old);
      assert(irq_new == irq_old);
    end
  end
endmodule
