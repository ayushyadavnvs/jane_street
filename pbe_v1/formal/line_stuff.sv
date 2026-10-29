// Arbitrary synchronized receive levels; internal observer checks every actual
// decoded violation, including arbitrary glitches/edges at any clock.
module line_stuff #(parameter MODE=1, STYLE=1, PAIR=0, ORIGINAL=0)(input wire clk);
  reg rst_n = 0;
  always @(posedge clk) rst_n <= 1;
  (* anyseq *) reg a_in, b_in;
  localparam [7:0] CFG = MODE | (STYLE << 2) | (PAIR << 4);
  pbe_line #(.FORMAL_CHECKS(1), .FORMAL_ORIGINAL_STUFF(ORIGINAL)) rx (
    .clk, .rst_n, .clear(1'b0), .cfg(CFG), .sync(8'd0), .period_m1(16'd3),
    .out_msb_first(1'b0), .in_msb_first(1'b0), .a_in, .b_in,
    .drive(), .a_out(), .b_out(), .tx_put(1'b0), .tx_end(1'b0), .tx_data(8'd0), .tx_ready(),
    .rx_valid(), .rx_data(), .rx_take(1'b1), .frame_end(), .err()
  );
endmodule
