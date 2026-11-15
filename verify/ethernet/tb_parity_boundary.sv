`timescale 1ns/1ps
// Two payload bits 1,0 have odd parity; verify OUTPAR for all parity settings.
module tb_parity_boundary;
  reg clk=0,rst_n=0,restart=0;
  wire [7:0] status,pc,pins;
  reg [7:0] line_cfg=0;
  reg [15:0] program_mem[0:255];
  always #8.334 clk=~clk;
  pbe_engine dut(.clk,.rst_n,.run(1'b1),.restart,.clkdiv(16'd0),
    .pin_base(3'd0),.jmp_pin(3'd0),.out_msb_first(1'b0),.in_msb_first(1'b0),
    .start_pc(8'd0),.crc_poly(32'd0),.crc_cfg(8'd0),.crc_wide(1'b0),
    .timeout(16'd0),.line_cfg,.coder_cfg(8'd0),.coder_cfg2(8'd0),
    .sync(8'd0),.crc_good(32'd0),.host_crc_init(1'b0),.host_tmo_clr(1'b0),
    .host_ovf_clr(1'b0),.host_lerr_clr(1'b0),.host_arb_clr(1'b0),
    .host_berr_clr(1'b0),.host_sent_clr(1'b0),.status,.crc_now(),.can_tec(),
    .can_rec(),.can_state(),.pc,.pc_copy(),.pc_d(),.instr(program_mem[pc]),.pm_wr(1'b0),
    .pins_in(8'd0),.pins_in_n(8'd0),.pins_out(pins),.pins_oe(),.tx_data(8'd0),
    .tx_empty(1'b1),.tx_pop(),.tx_mark(),.tx_rewind(),.rx_data(),.rx_full(1'b0),
    .rx_push(),.flags(4'd0),.flag_set(),.flag_clr(),.irq());
  initial begin
    for(integer n=0;n<256;n=n+1) program_mem[n]=16'hd800;
    program_mem[0]=16'h9010; // SET OSR,1
    program_mem[1]=16'h0200; // OUT 1, parity accumulator becomes odd
    program_mem[2]=16'h0200; // OUT 0
    program_mem[3]=16'h0300; // OUTPAR
    repeat(3) @(negedge clk);rst_n=1;
    for(integer kind=0;kind<4;kind=kind+1) begin
      line_cfg=(kind[0]?8'h80:0)|(kind[1]?8'h40:0);
      restart=1;@(negedge clk);restart=0;
      repeat(7) @(negedge clk);
      if(pins[0] !== (kind[1] || !kind[0]))
        $fatal(1,"OUTPAR even/odd/no-parity mismatch, LINE_CFG=%02x pins=%02x",line_cfg,pins);
    end
    $display("PASS: exact OUTPAR even, odd, and disabled parity values");$finish;
  end
endmodule
