`timescale 1ns/1ps
// Four-state supplement: formal's two-state bit vectors cannot prove absence of X.
module tb_engine_known_reset;
  logic clk=0,rst_n=0,restart=0,run=0;
  logic [7:0] coder_cfg=0, coder_cfg2=0;
  logic [15:0] instr=16'hd800;
  wire [7:0] pins_out,pins_oe,rx_data;
  wire [7:0] status;
  wire [8:0] can_tec;
  wire [7:0] can_rec;
  wire [1:0] can_state;
  wire [31:0] crc_now;
  wire [7:0] pc;
  wire [23:0] pc_copy;
  wire [3:0] flag_set,flag_clr;
  wire tx_pop,rx_push,irq;
  always #5 clk=~clk;
  pbe_engine dut(.clk,.rst_n,.run,.restart,.clkdiv(16'd3),
    .pin_base(3'd0),.jmp_pin(3'd0),.out_msb_first(1'b0),.in_msb_first(1'b0),
    .start_pc(8'd0),.crc_poly(32'h8005), .crc_wide(1'b0),.crc_cfg(8'h3f),.timeout(16'd0),
    .line_cfg(8'h40),.coder_cfg,.coder_cfg2,.sync(8'h80),.crc_good(32'd0),
    .host_crc_init(1'b0),.host_tmo_clr(1'b0),.host_ovf_clr(1'b0),.host_lerr_clr(1'b0),
    .host_arb_clr(1'b0),.host_berr_clr(1'b0),.host_sent_clr(1'b0),
    .status,.can_tec,.can_rec,.can_state,.crc_now,.pc,.pc_copy,.instr,.pm_wr(1'b0),
    .pins_in(8'h01),.pins_out,.pins_oe,.tx_data(8'ha5),.tx_empty(1'b1),
    .tx_pop,.tx_mark(),.tx_rewind(),.rx_data,.rx_full(1'b0),.rx_push,.flags(4'd0),.flag_set,.flag_clr,.irq);
  task automatic known;
    // one $isunknown per signal: Icarus 12 misreports it on concatenations of these outputs
    // (at 106 bits; after D91 even on a 51-bit one whose every part is known, BUG-131)
    if ($isunknown(pins_out) || $isunknown(pins_oe) || $isunknown(flag_set) || $isunknown(flag_clr)
        || $isunknown(tx_pop) || $isunknown(rx_push) || $isunknown(irq) || $isunknown(rx_data)
        || $isunknown(status) || $isunknown(pc) || $isunknown(pc_copy) || $isunknown(crc_now)
        || $isunknown(can_tec) || $isunknown(can_rec) || $isunknown(can_state))
      $fatal(1,"engine reset/restart has an unknown output cfg=%h cfg2=%h",coder_cfg,coder_cfg2);
  endtask
  initial begin
    repeat(3) begin @(posedge clk); #1; known(); end
    @(negedge clk); rst_n=1; run=1; instr=16'h0080; // known drive-high word
    repeat(10) @(negedge clk);
    // every LINE bit field, with LINE2 off, in bit-synchronous (CAN) mode, and all LINE2 bits
    for (int c=0;c<192;c++) begin
      coder_cfg=8'(c%64); coder_cfg2=c<64 ? 8'h00 : c<128 ? 8'h20 : 8'h7f; restart=1;
      @(posedge clk); #1; known();
      if(pins_oe!==0) $fatal(1,"restart must release enables cfg=%h",coder_cfg);
      @(negedge clk); restart=0; instr=16'hd800;
      repeat(3) begin @(posedge clk); #1; known(); @(negedge clk); end
    end
    $display("PASS: four-state reset/restart outputs, all 64 coder bit-field combinations x LINE2 off, CAN mode, all LINE2 bits");
    $finish;
  end
  initial begin #60000; $fatal(1,"known-output regression timeout"); end
endmodule
