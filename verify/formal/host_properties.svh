// Assertion-only synchronized mode-0 SPI reference parser.
// Environment: reset one initial clock, then deasserted; SCK phases >=4 clocks;
// CS falling starts with SCK low. CS may abort at any bit position.
  reg f_past_valid = 0;
  reg f_prev_sck = 0;
  reg f_prev_cs = 1;
  reg [2:0] f_stable = 7;
  reg [2:0] f_bit = 0;
  reg [7:0] f_received = 0;
  reg f_command = 0;
  reg f_write = 0;
  reg [6:0] f_address = 0;
  reg f_expected_wr = 0, f_expected_rd = 0;
  reg [6:0] f_expected_addr = 0;
  reg [7:0] f_expected_data = 0;
  reg [1:0] f_read_wait = 0;
  reg [7:0] f_read_word = 0;
  reg [3:0] f_read_shift = 0;
  reg [2:0] f_writes = 0, f_reads = 0;
  reg f_seen_stream = 0, f_seen_increment = 0, f_seen_abort = 0;
  wire f_rise = sck && !f_prev_sck;
  wire f_fall = !sck && f_prev_sck;
  wire [7:0] f_complete = {f_received[6:0], mosi};
  wire f_stream = f_address == 7'h07 || f_address == 7'h16 || f_address == 7'h26;
  wire [7:0] f_shifted_read_word = f_read_word << f_read_shift;
  always @(posedge clk) begin
    f_past_valid <= 1;
    f_prev_sck <= sck;
    f_prev_cs <= cs_n;
`ifdef FORMAL_COVER
    // Cover-only deterministic legal clk/8 stimulus; proof permits arbitrary pauses.
    if (f_past_valid) begin
      if (f_stable >= 3) assume(sck != f_prev_sck);
      else assume(sck == f_prev_sck);
    end
`endif
    if (!f_past_valid) begin assume(!rst_n); assume(!sck); assume(cs_n); end
    else begin
      assume(rst_n);
      if (sck != f_prev_sck) begin assume(f_stable >= 3); f_stable <= 0; end
      else if (f_stable < 7) f_stable <= f_stable + 1'b1;
      if (!cs_n && f_prev_cs) assume(!sck && !f_prev_sck);
      // Avoid CS changing on the sampling edge: setup/hold is required for valid SPI.
      if (cs_n != f_prev_cs) assume(sck == f_prev_sck);
    end

    if (f_past_valid) begin
      // Internal relationships are inductive strengthening, not assumptions.
      assert(sck_d == f_prev_sck);
      assert(bitcnt == f_bit);
      assert(have_cmd == f_command);
      if (f_command) assert(is_write == f_write);
      assert(rx_sh == f_received);
      assert(addr == f_address);
      assert(wr_en == f_expected_wr);
      assert(rd_done == f_expected_rd);
      assert(!(wr_en && rd_done));
      if (wr_en) begin assert(wr_addr == f_expected_addr); assert(wr_data == f_expected_data); end
      if (rd_done) assert(rd_addr == f_expected_addr);
      assert(tx_sh == f_shifted_read_word);
      assert(f_read_shift <= 8);
      assert(load_dly == (f_read_wait == 2 ? 2'b01 : f_read_wait == 1 ? 2'b10 : 2'b00));
      if (!cs_n && f_command && !f_write && f_rise)
        assert(miso == f_shifted_read_word[7]);
      if ($past(rst_n && cs_n)) begin
        assert(!have_cmd && bitcnt == 0 && tx_sh == 0 && load_dly == 0);
      end
      if ($past(wr_en)) assert(!wr_en);
      if ($past(rd_done)) assert(!rd_done);
    end
    f_expected_wr <= 0;
    f_expected_rd <= 0;
    if (!rst_n) begin
      f_prev_sck <= 0;
      f_bit <= 0;
      f_received <= 0;
      f_command <= 0;
      f_write <= 0;
      f_address <= 0;
      f_read_wait <= 0;
      f_read_word <= 0;
      f_read_shift <= 0;
    end else if (cs_n) begin
      if (f_bit != 0) f_seen_abort <= 1;
      f_bit <= 0;
      f_command <= 0;
      f_read_wait <= 0;
      f_read_word <= 0;
      f_read_shift <= 0;
    end else begin
      if (f_read_wait != 0) f_read_wait <= f_read_wait - 1'b1;
      if (f_read_wait == 1) begin f_read_word <= rd_data; f_read_shift <= 0; end
      if (f_fall && f_bit != 0 && f_read_shift < 8) f_read_shift <= f_read_shift + 1'b1;
      if (f_rise) begin
        f_received <= f_complete;
        f_bit <= f_bit + 1'b1;
        if (f_bit == 7) begin
          if (!f_command) begin
            f_command <= 1;
            f_write <= f_complete[7];
            f_address <= f_complete[6:0];
            if (!f_complete[7]) f_read_wait <= 2;
          end else begin
            f_expected_addr <= f_address;
            if (f_write) begin
              f_expected_wr <= 1;
              f_expected_data <= f_complete;
              if (f_writes < 7) f_writes <= f_writes + 1'b1;
            end else begin
              f_expected_rd <= 1;
              f_read_wait <= 2;
              if (f_reads < 7) f_reads <= f_reads + 1'b1;
            end
            if (f_stream) f_seen_stream <= 1;
            else begin f_address <= f_address + 1'b1; f_seen_increment <= 1; end
          end
        end
      end
    end
    cover(f_writes >= 2 && f_seen_stream);
    cover(f_reads >= 2 && f_seen_increment);
    cover(f_seen_abort && wr_en);
    cover(f_seen_abort && rd_done);
  end
