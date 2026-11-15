// The historical single-lane properties run with new host inputs tied off.
module host_default(input wire clk, rst_n, sck, cs_n, mosi,
                    input wire [7:0] rd_data);
  pbe_host_spi dut(.clk, .rst_n, .sck, .cs_n, .mosi, .rd_data,
    .quad_req(1'b0), .mosi_hi(3'd0), .miso(), .miso_hi(), .quad(), .quad_exit(),
    .addr(), .wr_en(), .wr_addr(), .wr_data(), .rd_done(), .rd_addr());
endmodule
