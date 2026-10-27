// Low-speed USB line unit: serializer / deserializer for one engine.
//
// TX: the engine hands over one data bit at a time (1-bit holding register). The unit
//     NRZI-encodes it on the D+/D- pair, inserts a stuffed 0 after six 1s on its own,
//     and on request ends the packet with SE0, SE0, J and releases the pair.
// RX: when the pair leaves idle (J) the unit samples every bit in its middle, re-centring
//     on every D+ edge, drops the SYNC field and stuffed bits, and offers the decoded bits
//     one at a time. SE0 is offered as an end-of-packet marker.
// CRC5 and CRC16 run on every bit the engine sends (unless told not to) or takes.
//
// Low speed signalling: J (idle) = D+ low, D- high; K = D+ high, D- low; SE0 = both low.
module pbe_usb_line (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        clear,        // engine restart
    input  logic [7:0]  bitdiv,       // clocks per bit - 1
    // pair, already synchronized
    input  logic        dp_in,
    input  logic        dm_in,
    output logic        dp_out,
    output logic        dm_out,
    output logic        drive,
    // TX
    input  logic        tx_load,      // put tx_bit in the holding register
    input  logic        tx_bit,
    input  logic        tx_crc,       // include this bit in the CRCs
    input  logic        eop_req,      // end the packet after the queued bits
    output logic        tx_full,
    output logic        tx_busy,
    // RX
    input  logic        rx_take,
    output logic        rx_avail,
    output logic        rx_eop,       // the available item is end of packet, not a bit
    output logic        rx_bit,
    // CRC
    input  logic        crc_init,
    output logic [7:0]  crc16_lo,     // CRC16 field bytes, ready to send LSB first
    output logic [7:0]  crc16_hi,
    output logic        crc5_ok,
    output logic        crc16_ok
);
  localparam logic [2:0] T_IDLE = 3'd0, T_BITS = 3'd1, T_SE0A = 3'd2, T_SE0B = 3'd3, T_J = 3'd4;
  localparam logic [1:0] R_IDLE = 2'd0, R_SYNC = 2'd1, R_DATA = 2'd2, R_WAITJ = 2'd3;

  // ---- CRC ----
  logic [4:0]  crc5;
  logic [15:0] crc16;
  wire         crc_step = (tx_load && tx_crc) || (rx_take && rx_avail && !rx_eop);
  wire         crc_in = tx_load ? tx_bit : rx_bit;
  wire         fb5 = crc_in ^ crc5[4];
  wire         fb16 = crc_in ^ crc16[15];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      crc5  <= 5'h1F;
      crc16 <= 16'hFFFF;
    end else if (crc_init || clear) begin
      crc5  <= 5'h1F;
      crc16 <= 16'hFFFF;
    end else if (crc_step) begin
      crc5  <= {crc5[3:0], 1'b0} ^ (fb5 ? 5'h05 : 5'h00);
      crc16 <= {crc16[14:0], 1'b0} ^ (fb16 ? 16'h8005 : 16'h0000);
    end
  end

  // The CRC field is the inverted remainder, highest bit first on the wire.
  for (genvar i = 0; i < 8; i++) begin : g_crc_out
    assign crc16_lo[i] = ~crc16[15-i];
    assign crc16_hi[i] = ~crc16[7-i];
  end
  assign crc5_ok  = (crc5 == 5'b01100);       // residual after a correct CRC5
  assign crc16_ok = (crc16 == 16'h800D);      // residual after a correct CRC16

  // ---- TX ----
  logic [2:0] tst;
  logic [7:0] tcnt;
  logic       hv, hb, eop_pend, line_k;
  logic [2:0] tones;

  assign tx_full = hv;
  assign tx_busy = (tst != T_IDLE) || hv || eop_pend;
  assign drive   = (tst != T_IDLE);
  assign dp_out  = (tst == T_BITS) ? line_k : 1'b0;
  assign dm_out  = (tst == T_BITS) ? ~line_k : (tst == T_J);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tst      <= T_IDLE;
      tcnt     <= '0;
      hv       <= 1'b0;
      hb       <= 1'b0;
      eop_pend <= 1'b0;
      line_k   <= 1'b0;
      tones    <= '0;
    end else if (clear) begin
      tst      <= T_IDLE;
      hv       <= 1'b0;
      eop_pend <= 1'b0;
      line_k   <= 1'b0;
      tones    <= '0;
    end else begin
      if (tx_load) begin
        hv <= 1'b1;
        hb <= tx_bit;
      end
      if (eop_req) eop_pend <= 1'b1;

      if (tst == T_IDLE) begin
        if (hv) begin  // first bit of a packet: start from J
          tst    <= T_BITS;
          tcnt   <= bitdiv;
          hv     <= tx_load;
          line_k <= ~hb;  // a 0 toggles J to K
          tones  <= hb ? 3'd1 : 3'd0;
        end
      end else if (tcnt != 8'd0) begin
        tcnt <= tcnt - 1'b1;
      end else begin
        tcnt <= bitdiv;
        case (tst)
          T_BITS: begin
            if (tones == 3'd6) begin  // stuffed 0
              line_k <= ~line_k;
              tones  <= '0;
            end else if (hv) begin
              hv     <= tx_load;
              if (!hb) line_k <= ~line_k;
              tones  <= hb ? tones + 1'b1 : 3'd0;
            end else begin  // no more bits: end of packet (requested or underrun)
              tst      <= T_SE0A;
              eop_pend <= 1'b0;
            end
          end
          T_SE0A: tst <= T_SE0B;
          T_SE0B: tst <= T_J;
          default: begin  // T_J
            tst    <= T_IDLE;
            line_k <= 1'b0;
            tones  <= '0;
          end
        endcase
      end
    end
  end

  // ---- RX ----
  logic [1:0] rst_q;
  logic [7:0] rcnt;
  logic       dp_d, prev_k, rv, rb, re;
  logic [2:0] rones;

  wire rx_enable = (tst == T_IDLE) && !hv && !eop_pend;
  wire se0 = !dp_in && !dm_in;

  assign rx_avail = rv || re;
  assign rx_eop   = !rv && re;
  assign rx_bit   = rb;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rst_q  <= R_IDLE;
      rcnt   <= '0;
      dp_d   <= 1'b0;
      prev_k <= 1'b0;
      rv     <= 1'b0;
      rb     <= 1'b0;
      re     <= 1'b0;
      rones  <= '0;
    end else if (clear) begin
      rst_q <= R_IDLE;
      rv    <= 1'b0;
      re    <= 1'b0;
    end else begin
      dp_d <= dp_in;
      if (rx_take) begin
        if (rv) rv <= 1'b0;
        else re <= 1'b0;
      end

      if (!rx_enable) begin
        rst_q <= R_IDLE;
      end else begin
        case (rst_q)
          R_IDLE:
            if (dp_in && !dm_in) begin  // K: start of SYNC
              rst_q  <= R_SYNC;
              rcnt   <= {1'b0, bitdiv[7:1]};
              prev_k <= 1'b0;
            end
          R_WAITJ:
            if (!dp_in && dm_in) rst_q <= R_IDLE;
          default: begin
            if (dp_in != dp_d) rcnt <= {1'b0, bitdiv[7:1]};  // re-centre on every edge
            else if (rcnt != 8'd0) rcnt <= rcnt - 1'b1;
            else begin
              rcnt <= bitdiv;
              if (se0) begin
                if (rst_q == R_DATA) re <= 1'b1;
                rst_q <= R_WAITJ;
              end else begin
                prev_k <= dp_in;
                if (rst_q == R_SYNC) begin
                  if (dp_in == prev_k) begin  // the 1 that ends SYNC
                    rst_q <= R_DATA;
                    rones <= 3'd1;
                  end
                end else if (rones == 3'd6) begin
                  rones <= '0;  // stuffed bit, drop it
                end else begin
                  rv    <= 1'b1;
                  rb    <= (dp_in == prev_k);
                  rones <= (dp_in == prev_k) ? rones + 1'b1 : 3'd0;
                end
              end
            end
          end
        endcase
      end
    end
  end
endmodule
