// Bounded, handshake-valid two-byte frame (or 16 bit transfers), fixed period4.
module line_roundtrip #(parameter MODE=1, STYLE=0, PAIR=0, BYTES=0, MSB=0,
                        ORIGINAL=0, PERIOD=3, NO_SYNC=0, FORCE_ONES=0)(input wire clk);
  localparam [7:0] CFG = MODE | (STYLE << 2) | (PAIR << 4) | (BYTES << 5);
  // Both directions see wire sync bits 0,0,0,0,0,0,0,1, so start is detectable.
  localparam [7:0] SYNC = NO_SYNC ? 0 : (MSB ? 8'h01 : 8'h80);
  localparam integer UNITS = BYTES ? 2 : 16;
  localparam integer DEADLINE = 160;
  reg rst_n = 0;
  reg [7:0] cycle = 0;
  always @(posedge clk) begin
    rst_n <= 1;
    cycle <= cycle + 1;
  end
  (* anyconst *) reg [15:0] payload;
  reg [5:0] sent = 0, received = 0;
  reg ended = 0, saw_drive = 0, saw_end = 0;
  wire tx_ready, drive, a_out, b_out, tx_err;
  wire rx_valid, rx_err, frame_end;
  wire [7:0] rx_data;
  wire tx_put = rst_n && tx_ready && sent < UNITS;
  wire tx_end = rst_n && tx_ready && sent == UNITS && !ended;
  wire [7:0] next_byte = payload >> (8 * sent);
  wire next_bit = payload[MSB ? 15-sent : sent];
  wire [7:0] tx_data = BYTES ? next_byte : {7'd0, next_bit};
  wire [7:0] expected_byte = payload >> (8 * received);
  wire expected_bit = payload[MSB ? 15-received : received];
  wire [7:0] expected_data = BYTES ? expected_byte : {7'd0, expected_bit};
  wire a_wire = drive ? a_out : 1'b1;
  wire b_wire = drive ? b_out : 1'b0;
  // Full arbitrary payload for pair modes and stuffed single-line modes. Only the
  // unstuffed single-line subset needs data restrictions to avoid its idle EOF.
  always @* begin
    if (FORCE_ONES) assume(payload == 16'hffff);
    if (!ORIGINAL && !PAIR && STYLE == 0) begin
      assume(!payload[3] && !payload[7] && !payload[11] && !payload[15]);
    end
  end
  pbe_line tx (
    .clk, .rst_n, .clear(1'b0), .cfg(CFG), .sync(SYNC), .period_m1(16'(PERIOD)),
    .out_msb_first(1'(MSB)), .in_msb_first(1'(MSB)), .a_in(1'b1), .b_in(1'b0),
    .drive, .a_out, .b_out, .tx_put, .tx_end, .tx_data, .tx_ready,
    .rx_valid(), .rx_data(), .rx_take(1'b1), .frame_end(), .err(tx_err)
  );
  pbe_line rx (
    .clk, .rst_n, .clear(1'b0), .cfg(CFG), .sync(SYNC), .period_m1(16'(PERIOD)),
    .out_msb_first(1'(MSB)), .in_msb_first(1'(MSB)), .a_in(a_wire), .b_in(b_wire),
    .drive(), .a_out(), .b_out(), .tx_put(1'b0), .tx_end(1'b0), .tx_data(8'd0), .tx_ready(),
    .rx_valid, .rx_data, .rx_take(1'b1), .frame_end, .err(rx_err)
  );
  always @(posedge clk) if (rst_n) begin
    if (tx_put) sent <= sent + 1;
    if (tx_end) ended <= 1;
    if (drive) saw_drive <= 1;
    if (frame_end) saw_end <= 1;
    assert(!tx_err);
    assert(!rx_err);
    if (rx_valid) begin
      if (received < UNITS) begin
        assert(rx_data == expected_data);
        received <= received + 1;
      end else if (PAIR || ORIGINAL) begin
        // Single-line conditional contract allows an EOF idle suffix; original
        // unconditional exact-length property intentionally does not.
        assert(1'b0);
      end
    end
    if (cycle == DEADLINE) begin
      assert(sent == UNITS && received == UNITS && ended && saw_drive && !drive);
      if (PAIR) assert(saw_end);
    end
    cover(received == UNITS && ended && saw_drive && !drive);
  end
endmodule
