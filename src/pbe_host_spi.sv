// Host register port: an SPI peripheral, mode 0 (sample on SCK rising, shift on falling), MSB first.
//
// Transaction: CS_n low, command byte, then any number of data bytes.
//   command[7]   1 = write, 0 = read
//   command[6:0] register address
// The address auto-increments after every data byte, except for the streaming registers
// (program memory data and the engine FIFOs), so a burst can stream many bytes into one.
//
// SCK, CS_n and MOSI arrive already synchronized to clk, so SCK must be at most clk/8.
//
// Quad mode (D89): with `quad` set (latched from quad_req only while CS_n is high, so a
// transaction never changes mode half-way) every SCK rising edge carries 4 bits, high nibble
// first: the host drives {mosi_hi, mosi} = D3..D0 and samples {miso_hi, miso} = Q3..Q0. A byte
// is 2 SCK cycles; the framing (command byte, auto-increment, streaming registers, the read
// pipeline) is the same as in single mode, so the same SCK limit applies (clk/8), and both
// directions move 4 bits per SCK. The MISO lines are separate outputs, so there is no
// turnaround. quad_exit pulses on every 8th SCK rising edge seen while CS_n is high: the
// top level then clears the quad request, a recovery that works whatever mode the host
// thinks the port is in (single mode ignores it).
// Cycle contract (round-2 clarification): byte completion registers wr_en/rd_done;
// the top-level bus consumes the pulse on the following clk edge. Read data stages into
// MISO two clk edges after command/read-byte completion, after a FIFO pop has landed.
// The first following SCK falling edge (bit count 0) does not shift this fresh byte.
// Stream addresses are exactly 0x07, 0x16, 0x26; other addresses wrap modulo 128.
// CS_n high abandons any partial byte, clears command framing, read-load pipeline and
// transmit shifter/MISO, but preserves address/receive shifter and commits any previously
// issued bus pulse. Reset zeros all host state. Write transactions have no promised MISO
// payload; read prefetch may expose unspecified head data if an empty FIFO is selected.
module pbe_host_spi (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       sck,
    input  logic       cs_n,
    input  logic       mosi,
    output logic       miso,
    // quad mode (D89)
    input  logic       quad_req,  // HOSTCFG[0]: use quad mode from the next CS_n high
    input  logic [2:0] mosi_hi,   // D3..D1 (mosi is D0)
    output logic [2:0] miso_hi,   // Q3..Q1 (miso is Q0)
    output logic       quad,      // the mode in use
    output logic       quad_exit, // pulse: 8 SCK rising edges with CS_n high
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
  logic [2:0] idle_sck;  // SCK rising edges seen while CS_n is high (saturates at 7)

  wire        sck_rise = sck & ~sck_d;
  wire        sck_fall = ~sck & sck_d;
  wire  [7:0] rx_byte = quad ? {rx_sh[3:0], mosi_hi, mosi} : {rx_sh[6:0], mosi};
  wire        last_bit = quad ? bitcnt[2] : bitcnt == 3'd7;  // quad: bitcnt goes 0, 4, 0
  wire        no_incr = (addr == 7'h07) || (addr == 7'h16) || (addr == 7'h26);  // streaming registers

  assign miso    = quad ? tx_sh[4] : tx_sh[7];
  assign miso_hi = tx_sh[7:5];
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
      idle_sck <= '0;
      quad     <= 1'b0;
      quad_exit <= 1'b0;
    end else begin
      sck_d   <= sck;
      wr_en   <= 1'b0;
      rd_done <= 1'b0;
      quad_exit <= 1'b0;

      if (cs_n) begin
        quad     <= quad_req;
        if (sck_rise) begin
          if (idle_sck == 3'd7) quad_exit <= 1'b1;
          else idle_sck <= idle_sck + 3'd1;
        end
        bitcnt   <= '0;
        have_cmd <= 1'b0;
        load_dly <= '0;
        tx_sh    <= '0;
      end else begin
        idle_sck <= '0;
        load_dly <= {load_dly[0], 1'b0};
        if (load_dly[1]) tx_sh <= rd_data;

        if (sck_rise) begin
          rx_sh  <= rx_byte;
          bitcnt <= bitcnt + (quad ? 3'd4 : 3'd1);
          if (last_bit) begin
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
        if (sck_fall && bitcnt != 3'd0) tx_sh <= quad ? {tx_sh[3:0], 4'b0} : {tx_sh[6:0], 1'b0};
      end
    end
  end
endmodule
