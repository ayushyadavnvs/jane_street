`timescale 1ps/1ps
// External-pin fixture only: no forcing, oracle state, or internal DUT access.
module pin_top;
  reg clk=0,rst_n=0;
  reg [7:0] ui_in=8'h02;
  reg incoming=0,loopback=0,hdlc=0;
  wire [7:0] uo_out,uio_out,uio_oe;
  wire tdp=uio_oe[0] && uio_out[0];
  wire tdm=uio_oe[1] && uio_out[1];
  wire hdlc_line=uio_oe[0]?uio_out[0]:1'b1;
  wire rd=loopback?(hdlc?hdlc_line:(tdp && !tdm)):incoming;
  wire [7:0] pins={5'd0,rd,tdm,tdp};
  tt_um_ayushyadavnvs_pbe dut(.clk,.rst_n,.ena(1'b1),.ui_in,.uo_out,
    .uio_in(pins),.uio_out,.uio_oe);
endmodule
