`timescale 1ns/1ps
// Stress-only external pin fixture; pull-up/released high, low wins.
module stress_top;
  reg clk=0, rst_n=0;
  reg [7:0] ui_in=8'h02;
  reg ext0=1,ext1=1,ext2=1,ext3=1,ext4=1,ext5=1,ext6=1,ext7=1;
  reg stretch_release=1;
  wire [7:0] uo_out,uio_out,uio_oe;
  wire [7:0] pins=((uio_out & uio_oe)|~uio_oe) &
                  {ext7,ext6,ext5,ext4,ext3,ext2,ext1,ext0};
  wire sda=pins[0],scl=pins[1];
  wire [0:0] spi_sclk=pins[4],spi_mosi=pins[5],spi_miso=pins[6],spi_cs=pins[7];
  tt_um_ayushyadavnvs_pbe dut(.clk,.rst_n,.ui_in,.uo_out,
    .uio_in(pins),.uio_out,.uio_oe,.ena(1'b1));
endmodule
