`timescale 1ns/1ps
// TIMEOUT=1, CLKDIV=0: count blocked ticks exactly, then observe STATUS[2].
module tb_timeout_boundary;
  reg clk=0,rst_n=0,restart=0;
  wire [7:0] status;
  always #8.334 clk=~clk;
  pbe_engine dut(.clk,.rst_n,.run(1'b1),.restart,.clkdiv(16'd0),
    .pin_base(3'd0),.jmp_pin(3'd0),.out_msb_first(1'b0),.in_msb_first(1'b0),
    .start_pc(8'd0),.crc_poly(32'd0),.crc_cfg(8'd0),.crc_wide(1'b0),
    .timeout(16'd1),.line_cfg(8'h42),.coder_cfg(8'd0),.coder_cfg2(8'd0),
    .sync(8'd0),.crc_good(32'd0),.host_crc_init(1'b0),.host_tmo_clr(1'b0),
    .host_ovf_clr(1'b0),.host_lerr_clr(1'b0),.host_arb_clr(1'b0),
    .host_berr_clr(1'b0),.host_sent_clr(1'b0),.status,.crc_now(),.can_tec(),
    .can_rec(),.can_state(),.pc(),.pc_copy(),.pc_d(),.instr(16'h4080),.pm_wr(1'b0),
    .pins_in(8'd0),.pins_in_n(8'd0),.pins_out(),.pins_oe(),.tx_data(8'd0),
    .tx_empty(1'b1),.tx_pop(),.tx_mark(),.tx_rewind(),.rx_data(),.rx_full(1'b0),
    .rx_push(),.flags(4'd0),.flag_set(),.flag_clr(),.irq());
  initial begin
    repeat(3) @(negedge clk); rst_n=1;restart=1;
    @(negedge clk);restart=0;
    for(integer n=1;n<=4;n=n+1) begin
      @(posedge clk);#1;
      if(status[2] !== (n==4))
        $fatal(1,"TIMEOUT=1 must fire on fourth post-restart clock; n=%0d STATUS=%02x",n,status);
    end
    $display("PASS: exact blocked timeout deadline (>=, not >)");$finish;
  end
endmodule
