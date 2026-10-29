`timescale 1ns/1ps
// Four-state supplement: formal's two-state bit vectors cannot prove absence of X.
module tb_engine_known_reset;
  logic clk=0,rst_n=0,restart=0,run=0;
  logic [7:0] coder_cfg=0;
  logic [15:0] instr=16'hd800;
  wire [7:0] pins_out,pins_oe,rx_data;
  wire [4:0] status;
  wire [15:0] crc_now;
  wire [6:0] pc;
  wire [20:0] pc_copy;
  wire [3:0] flag_set,flag_clr;
  wire tx_pop,rx_push,irq;
  always #5 clk=~clk;
  pbe_engine dut(.clk,.rst_n,.run,.restart,.clkdiv(16'd3),
    .pin_base(3'd0),.jmp_pin(3'd0),.out_msb_first(1'b0),.in_msb_first(1'b0),
    .start_pc(7'd0),.crc_poly(16'h8005),.crc_cfg(8'h3f),.timeout(16'd0),
    .line_cfg(8'h40),.coder_cfg,.sync(8'h80),.crc_good(16'd0),
    .host_crc_init(1'b0),.host_tmo_clr(1'b0),.host_ovf_clr(1'b0),.host_lerr_clr(1'b0),
    .status,.crc_now,.pc,.pc_copy,.instr,.pm_wr(1'b0),
    .pins_in(8'h01),.pins_out,.pins_oe,.tx_data(8'ha5),.tx_empty(1'b1),
    .tx_pop,.rx_data,.rx_full(1'b0),.rx_push,.flags(4'd0),.flag_set,.flag_clr,.irq);
  task automatic known;
    if ($isunknown({pins_out,pins_oe,flag_set,flag_clr,tx_pop,rx_push,irq,rx_data,status,crc_now,pc,pc_copy}))
      $fatal(1,"engine reset/restart has an unknown output cfg=%h",coder_cfg);
  endtask
  initial begin
    repeat(3) begin @(posedge clk); #1; known(); end
    @(negedge clk); rst_n=1; run=1; instr=16'h0080; // known drive-high word
    repeat(10) @(negedge clk);
    for (int c=0;c<64;c++) begin
      coder_cfg=8'(c); restart=1;
      @(posedge clk); #1; known();
      if(pins_oe!==0) $fatal(1,"restart must release enables cfg=%h",coder_cfg);
      @(negedge clk); restart=0; instr=16'hd800;
      repeat(3) begin @(posedge clk); #1; known(); @(negedge clk); end
    end
    $display("PASS: four-state reset/restart outputs, all 64 coder bit-field combinations");
    $finish;
  end
  initial begin #20000; $fatal(1,"known-output regression timeout"); end
endmodule
