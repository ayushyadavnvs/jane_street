// Line coder: an optional stage between an engine's shift registers and its line pin(s).
//
// It owns the bit timing (one bit every period_m1 + 1 clocks), because bits it inserts or
// removes (stuffing) must not cost the program anything (v2 lesson, docs/USB_NOTES.md).
//
//   cfg[1:0]  mode       0 off, 1 NRZ (the bit is the level), 2 NRZI (0 = change level, 1 = keep)
//   cfg[3:2]  stuffing   0 none, 1 after 6 ones (USB), 2 after 5 ones (HDLC), 3 after 5 equal (CAN)
//   cfg[4]    pair       pin a carries the line, pin b its complement; both low (SE0) ends a frame
//   cfg[5]    bytes      the engine transfers whole bytes (else single bits)
//
// Transmit: tx_put queues a byte (or a bit in tx_data[0]), tx_end queues "end of frame"; one
// entry is buffered (tx_ready). A frame starts with 2 idle bit times (an inter-packet gap) and
// then sends the sync byte (if not zero), the queued data, and on tx_end: in pair mode SE0, SE0,
// one bit of idle level, then it lets go of the line; otherwise it lets go at once.
// Receive: a frame starts when the line leaves the idle level (1). Sampling is mid-bit, and
// every edge re-centres the bit timer, so clock errors do not add up over a frame. Decoded bits
// are unstuffed (a stuff bit with the wrong value is an error) and, if sync is not zero,
// dropped until the last 8 bits equal sync. Then bytes (or bits) are delivered in rx_data.
// The frame ends on SE0 followed by the idle level (pair mode); otherwise after 8 bit times at
// the idle level, or when a run at the idle level breaks the stuffing rule. frame_end pulses, and
// a byte of that frame the engine has not taken is dropped.
module pbe_line (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        clear,
    input  logic [7:0]  cfg,
    input  logic [7:0]  sync,
    input  logic [15:0] period_m1,
    input  logic        out_msb_first,
    input  logic        in_msb_first,
    // line pins
    input  logic        a_in,        // synchronized levels
    input  logic        b_in,
    output logic        drive,       // the coder owns the line pin(s)
    output logic        a_out,
    output logic        b_out,
    // transmit
    input  logic        tx_put,
    input  logic        tx_end,
    input  logic [7:0]  tx_data,
    output logic        tx_ready,
    // receive
    output logic        rx_valid,
    output logic [7:0]  rx_data,
    input  logic        rx_take,
    output logic        frame_end,   // pulse
    output logic        err          // pulse: stuff error, receive overrun or transmit underrun
);
  wire       nrzi  = cfg[1:0] == 2'd2;
  wire [1:0] st    = cfg[3:2];
  wire       pair  = cfg[4];
  wire       bytes = cfg[5];
  wire       ones  = st != 2'd3;                    // stuff after ones, else after equal bits
  wire [2:0] run_n = (st == 2'd1) ? 3'd6 : 3'd5;
  wire [3:0] width = bytes ? 4'd8 : 4'd1;

  // ---------------- transmit ----------------
  localparam logic [2:0] T_IDLE = 3'd0, T_GAP = 3'd1, T_RUN = 3'd2, T_SE0A = 3'd3, T_SE0B = 3'd4,
                         T_J = 3'd5;
  logic [2:0]  ts;
  logic [15:0] tcnt;
  logic        gap2, kick;           // second gap bit; emit a bit now (frame start)
  logic        q_valid, q_end;
  logic [7:0]  q_data, tsh;
  logic [3:0]  tbits;                // bits left in tsh
  logic        level;                // line level, 1 = idle (USB J)
  logic [2:0]  trun;
  logic        tlast, tstuff;        // stuff bit due in the next slot

  assign tx_ready = !q_valid;
  wire boundary = tcnt == period_m1;

  // what the next bit slot sends
  wire        n_load = !tstuff && tbits == 4'd0 && q_valid && !q_end;
  wire [7:0]  q_bits = (!bytes && out_msb_first) ? {q_data[0], 7'b0} : q_data;
  wire [7:0]  n_src  = n_load ? q_bits : tsh;
  wire        n_bit  = tstuff ? (ones ? 1'b0 : !tlast) : (out_msb_first ? n_src[7] : n_src[0]);
  wire        n_have = tstuff || tbits != 4'd0 || n_load;
  wire        n_end  = !tstuff && tbits == 4'd0 && q_valid && q_end;
  wire [3:0]  n_left = n_load ? width - 4'd1 : tbits - 4'd1;
  wire [7:0]  n_rest = out_msb_first ? {n_src[6:0], 1'b0} : {1'b0, n_src[7:1]};
  // stuffing state after this bit
  logic [2:0] n_run;
  logic       n_last;
  always_comb begin
    if (tstuff) begin
      n_run  = ones ? 3'd0 : 3'd1;
      n_last = n_bit;
    end else if (ones) begin
      n_run  = n_bit ? trun + 3'd1 : 3'd0;
      n_last = n_bit;
    end else begin
      n_run  = (n_bit == tlast) ? trun + 3'd1 : 3'd1;
      n_last = n_bit;
    end
  end
  wire n_stuff = !tstuff && st != 2'd0 && n_run == run_n;
  wire n_level = nrzi ? (n_bit ? level : !level) : n_bit;

  // ---------------- receive ----------------
  localparam logic [1:0] R_IDLE = 2'd0, R_RUN = 2'd1, R_SE0 = 2'd2;
  logic [1:0]  rs;
  logic [15:0] rcnt;
  logic        a_d, rprev, rlast, rstuff, hunting;
  logic [2:0]  rrun, ridle;
  logic [7:0]  win, rsh;
  logic [3:0]  rbits;

  wire        se0    = pair && !a_in && !b_in;
  wire        sample = rcnt == {1'b0, period_m1[15:1]} + 16'd1;
  wire        r_bit  = nrzi ? (a_in == rprev) : a_in;
  wire        r_exp  = ones ? 1'b0 : !rlast;           // value a stuff bit must have
  logic [2:0] r_run;
  always_comb begin
    if (rstuff)    r_run = ones ? 3'd0 : 3'd1;
    else if (ones) r_run = r_bit ? rrun + 3'd1 : 3'd0;
    else           r_run = (r_bit == rlast) ? rrun + 3'd1 : 3'd1;
  end
  wire [7:0] win_n = in_msb_first ? {win[6:0], r_bit} : {r_bit, win[7:1]};
  wire [7:0] rsh_n = in_msb_first ? {rsh[6:0], r_bit} : {r_bit, rsh[7:1]};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ts <= T_IDLE; tcnt <= '0; gap2 <= 1'b0; kick <= 1'b0;
      q_valid <= 1'b0; q_end <= 1'b0; q_data <= '0; tsh <= '0; tbits <= '0;
      level <= 1'b1; trun <= '0; tlast <= 1'b1; tstuff <= 1'b0;
      drive <= 1'b0; a_out <= 1'b1; b_out <= 1'b0;
      rs <= R_IDLE; rcnt <= '0; a_d <= 1'b1; rprev <= 1'b1; rlast <= 1'b1; rstuff <= 1'b0;
      hunting <= 1'b0; rrun <= '0; ridle <= '0; win <= '0; rsh <= '0; rbits <= '0;
      rx_valid <= 1'b0; rx_data <= '0; frame_end <= 1'b0; err <= 1'b0;
    end else if (clear) begin
      ts <= T_IDLE; tcnt <= '0; gap2 <= 1'b0; kick <= 1'b0;
      q_valid <= 1'b0; q_end <= 1'b0; q_data <= '0; tsh <= '0; tbits <= '0;
      level <= 1'b1; trun <= '0; tlast <= 1'b1; tstuff <= 1'b0;
      drive <= 1'b0; a_out <= 1'b1; b_out <= 1'b0;
      rs <= R_IDLE; rcnt <= '0; a_d <= 1'b1; rprev <= 1'b1; rlast <= 1'b1; rstuff <= 1'b0;
      hunting <= 1'b0; rrun <= '0; ridle <= '0; win <= '0; rsh <= '0; rbits <= '0;
      rx_valid <= 1'b0; rx_data <= '0; frame_end <= 1'b0; err <= 1'b0;
    end else begin
      frame_end <= 1'b0;
      err       <= 1'b0;

      // ---- transmit ----
      if (tx_put || tx_end) begin
        q_valid <= 1'b1;
        q_end   <= tx_end;
        q_data  <= tx_data;
      end
      tcnt <= (ts == T_IDLE || boundary || kick) ? 16'd0 : tcnt + 16'd1;
      kick <= 1'b0;
      case (ts)
        T_IDLE:
          if (q_valid) begin
            if (q_end) q_valid <= 1'b0;  // end with no frame: nothing to do
            else begin
              ts   <= T_GAP;
              gap2 <= 1'b0;
            end
          end
        T_GAP:
          if (boundary) begin
            gap2 <= 1'b1;
            if (gap2) begin             // the gap is over: start the frame
              ts     <= T_RUN;
              kick   <= 1'b1;
              level  <= 1'b1;
              trun   <= '0;
              tlast  <= 1'b1;
              tstuff <= 1'b0;
              tsh    <= sync;
              tbits  <= (sync != 8'd0) ? 4'd8 : 4'd0;
            end
          end
        T_RUN:
          if (boundary || kick) begin
            if (n_have) begin
              level  <= n_level;
              a_out  <= n_level;
              b_out  <= !n_level;
              drive  <= 1'b1;
              trun   <= n_run;
              tlast  <= n_last;
              tstuff <= n_stuff;
              if (!tstuff) begin
                tsh   <= n_rest;
                tbits <= n_left;
              end
              if (n_load) q_valid <= 1'b0;
            end else if (n_end) begin
              q_valid <= 1'b0;
              if (pair) begin
                ts    <= T_SE0A;
                a_out <= 1'b0;
                b_out <= 1'b0;
              end else begin
                ts    <= T_IDLE;
                drive <= 1'b0;
              end
            end else err <= 1'b1;       // underrun: the line keeps its level
          end
        T_SE0A: if (boundary) ts <= T_SE0B;
        T_SE0B:
          if (boundary) begin
            ts    <= T_J;
            a_out <= 1'b1;
            b_out <= 1'b0;
          end
        default:                        // T_J: one bit of idle level, then let go
          if (boundary) begin
            ts    <= T_IDLE;
            drive <= 1'b0;
            level <= 1'b1;
          end
      endcase

      // ---- receive (off while transmitting: half duplex) ----
      a_d <= a_in;
      if (rx_take) rx_valid <= 1'b0;
      rcnt <= (a_in != a_d || rcnt == period_m1) ? 16'd0 : rcnt + 16'd1;
      if (ts != T_IDLE) rs <= R_IDLE;
      else case (rs)
        R_IDLE:
          if (se0) rs <= R_SE0;
          else if (!a_in) begin         // the line left the idle level: a frame starts
            rs      <= R_RUN;
            rprev   <= 1'b1;
            rlast   <= 1'b1;
            rrun    <= '0;
            rstuff  <= 1'b0;
            ridle   <= '0;
            hunting <= sync != 8'd0;
            win     <= '0;
            rbits   <= '0;
          end
        R_RUN:
          if (sample) begin
            if (se0) rs <= R_SE0;
            else begin
              rprev <= a_in;
              rlast <= rstuff ? r_exp : r_bit;
              rrun  <= r_run;
              // without SE0, a frame ends after 8 bit times at the idle level
              ridle <= a_in ? ridle + 3'd1 : 3'd0;
              if (!pair && a_in && ridle == 3'd7) begin
                rs        <= R_IDLE;
                frame_end <= 1'b1;
              end
              if (rstuff) begin
                rstuff <= 1'b0;
                if (r_bit != r_exp) begin
                  // Without SE0, a run too long for stuffing at the idle level is how a frame
                  // ends (HDLC flag or abort, CAN end of frame); anywhere else it is an error.
                  if (!pair && a_in) begin
                    rs        <= R_IDLE;
                    frame_end <= 1'b1;
                  end else err <= 1'b1;
                end
              end else begin
                rstuff <= st != 2'd0 && r_run == run_n;
                if (hunting) begin
                  win <= win_n;
                  if (win_n == sync) hunting <= 1'b0;
                end else if (rbits == width - 4'd1) begin
                  rx_data  <= bytes ? rsh_n : {7'b0, r_bit};
                  if (rx_valid && !rx_take) err <= 1'b1;  // the engine missed one
                  rx_valid <= 1'b1;
                  rbits    <= '0;
                  rsh      <= rsh_n;
                end else begin
                  rbits <= rbits + 4'd1;
                  rsh   <= rsh_n;
                end
              end
            end
          end
        default:                        // R_SE0: wait for the idle level
          if (sample && !se0) begin
            rs        <= R_IDLE;
            frame_end <= a_in;
          end
      endcase
      // A byte the engine has not taken when its frame ends belongs to that frame: drop it,
      // so it cannot be read as the start of the next frame (BUG-028).
      if (frame_end) rx_valid <= 1'b0;
    end
  end
endmodule
