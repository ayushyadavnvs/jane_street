`timescale 1ns/1ps
// Test-only pin fixture. No hierarchical access, forcing, or design modifications.
module bus_top;
  reg clk = 0, rst_n = 0;
  reg [7:0] ui_in = 8'h02;
  wire [7:0] uo_out, uio_out, uio_oe;
  reg ext0 = 1, ext1 = 1, ext2 = 1, ext3 = 1;
  reg stretch_release = 1;
  wire [7:0] external_release = {4'hf, ext3, ext2, ext1, ext0};
  // Low wins; 1 represents a pull-up/released external output.
  wire [7:0] pins = ((uio_out & uio_oe) | ~uio_oe) & external_release & {6'h3f, stretch_release, 1'b1};
  wire sda = pins[0], scl = pins[1];
  wire [0:0] sclk = pins[0], mosi = pins[1], miso = pins[2], cs = pins[3];
  tt_um_ayushyadavnvs_pbe dut (.clk, .rst_n, .ena(1'b1), .ui_in,
    .uo_out, .uio_in(pins), .uio_out, .uio_oe);
endmodule
