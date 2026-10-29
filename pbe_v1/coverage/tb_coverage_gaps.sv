`timescale 1ns/1ps
// Directed closure: flag-edge WAIT completion and explicit RX-overflow clear.
module tb_coverage_gaps;
  logic clk=0,rst_n=0,restart=0,run=1,host_ovf_clr=0,rx_full=1;
  logic [3:0] flags=0;
  logic [15:0] program_mem[128];
  wire [6:0] pc;
  wire [7:0] pins_out,pins_oe;
  wire [4:0] status;
  always #5 clk=~clk;
  pbe_engine dut(.clk,.rst_n,.run,.restart,.clkdiv(16'd0),.pin_base(3'd0),.jmp_pin(3'd0),
    .out_msb_first(1'b0),.in_msb_first(1'b0),.start_pc(7'd0),.crc_poly(16'd0),.crc_cfg(8'd0),
    .timeout(16'd0),.line_cfg(8'h40),.coder_cfg(8'd0),.sync(8'd0),.crc_good(16'd0),
    .host_crc_init(1'b0),.host_tmo_clr(1'b0),.host_ovf_clr,.host_lerr_clr(1'b0),.status,
    .crc_now(),.pc,.pc_copy(),.instr(program_mem[pc]),.pm_wr(1'b0),.pins_in(8'd0),.pins_out,.pins_oe,
    .tx_data(8'd0),.tx_empty(1'b1),.tx_pop(),.rx_data(),.rx_full,.rx_push(),.flags,.flag_set(),.flag_clr(),.irq());
  task automatic tick; @(posedge clk); #1; endtask
  initial begin
    for(int i=0;i<128;i++) program_mem[i]=16'hd800;
    program_mem[0]=16'h4300; // WAIT FLAG0 RISE
    program_mem[1]=16'h0080; // PIN0 DRV1
    program_mem[2]=16'h4380; // WAIT FLAG0 FALL
    program_mem[3]=16'h0000; // PIN0 DRV0
    program_mem[4]=16'hb000; // PUSH, deliberately full
    program_mem[5]=16'h6050; // JMP 5
    repeat(3) tick(); @(negedge clk); rst_n=1; restart=1; tick();
    @(negedge clk); restart=0; repeat(5) tick();
    if(pins_oe[0]) $fatal(1,"RISE wait did not block");
    @(negedge clk); flags=1;
    repeat(4) tick();
    if(!pins_oe[0] || !pins_out[0]) $fatal(1,"RISE flag wait did not complete");
    @(negedge clk); flags=0;
    repeat(4) tick();
    if(pins_out[0]) $fatal(1,"FALL flag wait did not complete");
    if(!status[3]) $fatal(1,"full PUSH failed to set overflow");
    @(negedge clk); rx_full=0; host_ovf_clr=1; tick();
    @(negedge clk); host_ovf_clr=0; repeat(3) tick();
    if(status[3]) $fatal(1,"overflow host clear failed");
    $display("PASS: directed flag RISE/FALL WAIT and RX-overflow clear");
    $finish;
  end
  initial begin #10000; $fatal(1,"coverage closure watchdog"); end
endmodule
