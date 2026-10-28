// Host register port: an SPI peripheral, mode 0 (sample on SCK rising, shift on falling), MSB first.
//
// Transaction: CS_n low, command byte, then any number of data bytes.
//   command[7]   1 = write, 0 = read
//   command[6:0] register address
// The address auto-increments after every data byte, except for the streaming registers
// (program memory data and the engine FIFOs), so a burst can stream many bytes into one.
//
// SCK, CS_n and MOSI arrive already synchronized to clk, so SCK must be at most clk/8.
module pbe_host_spi (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       sck,
    input  logic       cs_n,
    input  logic       mosi,
    output logic       miso,
    // register bus
    output logic [6:0] addr,     // current address; rd_data must be the register at addr
    input  logic [7:0] rd_data,
    output logic       wr_en,    // 1-cycle pulse
    output logic [6:0] wr_addr,
    output logic [7:0] wr_data,
    output logic       rd_done,  // 1-cycle pulse: the byte read from rd_addr has been sent
    output logic [6:0] rd_addr
);
  logic       sck_d;
  logic [2:0] bitcnt;
  logic [7:0] rx_sh, tx_sh;
  logic       have_cmd, is_write;
  logic [1:0] load_dly;  // load tx_sh two cycles after a byte so a FIFO pop has landed

  wire        sck_rise = sck & ~sck_d;
  wire        sck_fall = ~sck & sck_d;
  wire  [7:0] rx_byte = {rx_sh[6:0], mosi};
  wire        no_incr = (addr == 7'h07) || (addr == 7'h16) || (addr == 7'h26);  // streaming registers

  assign miso = tx_sh[7];
  wire   _unused = rx_sh[7];  // the 8th bit of a byte comes straight from mosi

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sck_d    <= 1'b0;
      bitcnt   <= '0;
      rx_sh    <= '0;
      tx_sh    <= '0;
      have_cmd <= 1'b0;
      is_write <= 1'b0;
      load_dly <= '0;
      addr     <= '0;
      wr_en    <= 1'b0;
      wr_addr  <= '0;
      wr_data  <= '0;
      rd_done  <= 1'b0;
      rd_addr  <= '0;
    end else begin
      sck_d   <= sck;
      wr_en   <= 1'b0;
      rd_done <= 1'b0;

      if (cs_n) begin
        bitcnt   <= '0;
        have_cmd <= 1'b0;
        load_dly <= '0;
        tx_sh    <= '0;
      end else begin
        load_dly <= {load_dly[0], 1'b0};
        if (load_dly[1]) tx_sh <= rd_data;

        if (sck_rise) begin
          rx_sh  <= rx_byte;
          bitcnt <= bitcnt + 1'b1;
          if (bitcnt == 3'd7) begin
            if (!have_cmd) begin
              have_cmd <= 1'b1;
              is_write <= rx_byte[7];
              addr     <= rx_byte[6:0];
              if (!rx_byte[7]) load_dly <= 2'b01;
            end else if (is_write) begin
              wr_en   <= 1'b1;
              wr_addr <= addr;
              wr_data <= rx_byte;
              if (!no_incr) addr <= addr + 1'b1;
            end else begin
              rd_done  <= 1'b1;
              rd_addr  <= addr;
              load_dly <= 2'b01;
              if (!no_incr) addr <= addr + 1'b1;
            end
          end
        end

        // The first bit of a freshly loaded byte is already on MISO, so skip the
        // falling edge that follows the last bit of the previous byte.
        if (sck_fall && bitcnt != 3'd0) tx_sh <= {tx_sh[6:0], 1'b0};
      end
    end
  end
endmodule
