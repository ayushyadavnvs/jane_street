// Bit-synchronous line coder (LINE2[5], D66): one bit timer for both directions, for wired-AND
// buses on which every node reads back every bit (CAN, ISO 11898-1). The engine uses it in
// place of pbe_line when LINE2[5] is set; LINE must then select NRZ (and normally stuffing 3).
//
// Timing. One timer, period_m1 + 1 clocks per bit. The sample point is LINE2[2:0] (as in
// pbe_line). On the bus-idle level a falling edge hard-synchronizes (it is a start of frame);
// inside a frame a falling edge resynchronizes, except while this node drives a dominant
// bit (its own edge, delayed by the transceiver), and at most once between two sample points
// (ISO 11898-1). An edge after the sample point starts the
// next bit at once; an edge before it restarts the current bit.
//
// Transfers. OUT queues a unit of `width` bits (the top bits of OSR when MSB first); one unit
// is buffered. At each bit start the coder drives the next bit of the current unit, or the
// queued unit's first bit, or recessive when nothing is queued. IN takes a unit of `width`
// received bits, right-justified. Stuff bits are inserted and removed here: they never reach
// the program. Stuffing follows the bus, not the bits this node meant to send.
//   A frame starts in units of 8 bits if LINE[5] (bytes), else 1, with arbitration on and
//   stuffing on if LINE[3:2] != 0. LINECTL changes them (ctl, ctl_param, see pbe_engine).
// Arbitration. Sent recessive and read dominant on a data bit while the arbitration window is
//   on: the node stops driving at once (it is "silent"), keeps receiving, and pulses arb_lost
//   if it had started the frame. A silent node checks nothing and drives only error flags.
// Bit error. A non-silent node that reads back a level other than the one it drove (outside
//   the arbitration rule) has a bit error.
// Frame tail. When stuffing is switched off (LINECTL) the stuffed region ends after any stuff
//   bit already due, and the coder runs the rest of the frame itself: CRC delimiter, ACK slot,
//   ACK delimiter, 7 EOF bits. Every node is non-silent in the tail. A node that did not
//   transmit drives the ACK slot dominant if crc_ok; a transmitter that reads the ACK slot
//   recessive has an ACK error; a dominant delimiter or EOF bit is a form error (except EOF
//   bit 7 for a receiver: no overload frame, D69); a receiver whose CRC is not ok has a CRC
//   error after the ACK delimiter. After EOF bit 7 frame_end pulses, a transmitter pulses
//   `sent`, and the error counters count a success.
// Errors (stuff, bit, form, ACK, CRC, and LINECTL "error now"): err and frame_end pulse, the
//   queued unit is dropped, and the error flag starts at the next bit: 6 dominant bits when
//   error-active, 6 recessive (ended by 6 equal bits on the bus) when error-passive (the state
//   in which the error was detected, before its own count); then the
//   delimiter: wait for recessive, then 8 recessive bits.
// Error confinement (D68), ISO 11898-1 rules: a transmitter's error adds 8 to TEC (except an
//   error-passive transmitter's ACK error when its passive flag sees no dominant bit), a
//   receiver's adds 1 to REC; a receiver that reads dominant as the first bit after its error
//   flag adds 8; a bit error in its own active flag adds 8; 14 dominant bits after an active
//   flag (8 after a passive one), and each 8 more, add 8; success subtracts 1 (REC above 127
//   becomes 119). Error-passive at TEC or REC >= 128; bus-off when TEC > 255: the node is then
//   silent until it has seen 128 runs of 11 recessive bits (counters back to 0).
// Bus idle. After clear the node integrates: 11 recessive bits before a falling edge counts
//   as a start of frame. With LINE2[6] the node starts its own frame (a queued unit whose first
//   bit is dominant) only after 3 recessive bits following a frame end or error delimiter, or 11
//   otherwise, plus 8 (suspend transmission) after it transmitted while error-passive. A
//   foreign start of frame while a unit is queued (or queued before the SOF sample point) is
//   joined if this node may start, otherwise the unit is sent silently and arb_lost pulses.
// Every config bit of this mode defaults to 0 in LINE2, so the engine never selects it unless
// LINE2[5] is written.
module pbe_bsync (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        clear,
    input  logic [7:0]  cfg,         // LINE: [3:2] stuffing, [5] frames start in byte units
    input  logic [7:0]  cfg2,        // LINE2: [2:0] sample point, [6] wait for bus idle
    input  logic [15:0] period_m1,
    input  logic        out_msb_first,
    input  logic        in_msb_first,
    input  logic        a_in,        // synchronized receive level
    output logic        drive,       // drive the pin dominant (low)
    input  logic        tx_put,
    input  logic [7:0]  tx_data,
    output logic        tx_ready,
    output logic        rx_valid,
    output logic [7:0]  rx_data,
    input  logic        rx_take,
    output logic        frame_end,   // pulse: frame ended or an error was detected
    output logic        err,         // pulse: an error (or receive overrun)
    input  logic        ctl,         // LINECTL
    input  logic [4:0]  ctl_param,
    input  logic        drop,        // the engine abandoned the frame: drop the queued unit
    input  logic        crc_ok,
    output logic        crc_step,    // a received bit of the stuffed region, for the CRC
    output logic        crc_bit,
    output logic        arb_lost,    // pulses
    output logic        bit_err,
    output logic        sent,
    output logic [8:0]  tec,
    output logic [7:0]  rec,
    output logic        passive,
    output logic        busoff
);
  localparam logic [2:0] C_INTEG = 3'd0, C_IDLE = 3'd1, C_FRAME = 3'd2, C_TAIL = 3'd3,
                         C_EFLAG = 3'd4, C_EDWAIT = 3'd5, C_EDELIM = 3'd6, C_BUSOFF = 3'd7;
  wire [1:0] st    = cfg[3:2];
  wire       ones  = st != 2'd3;
  wire [2:0] run_n = (st == 2'd1) ? 3'd6 : 3'd5;
  wire       idle_wait = cfg2[6];
  wire       _unused = &{cfg[7:6], cfg[4], cfg[1:0], cfg2[7], cfg2[5:3], 1'b0};

  // ---- timing ----
  logic [15:0] cnt;
  logic        sampled, a_d;
  wire [15:0] n_per = period_m1 + 16'd1;
  wire        _unused_nper = &{n_per[1:0], 1'b0};
  logic [15:0] sp_add;
  always_comb begin
    case (cfg2[2:0])
      3'd1:    sp_add = {3'b0, n_per[15:3]};
      3'd2:    sp_add = {2'b0, n_per[15:2]};
      3'd3:    sp_add = {2'b0, n_per[15:2]} + {3'b0, n_per[15:3]};
      default: sp_add = 16'd0;
    endcase
  end
  // the sample count, registered: the adders stay off the counter's compare path; a change
  // of CLKDIV or LINE2 takes effect one clock later
  logic [15:0] spv;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) spv <= '0;
    else spv <= {1'b0, period_m1[15:1]} + 16'd1 + sp_add;

  logic [2:0]  cs;
  logic        drv;                  // driving dominant in this bit
  logic        cur;                  // the level this node means to send in this bit (1 = recessive)
  logic        slot_stuff, sof;
  logic        q_valid;
  logic [7:0]  q_data, tsh;
  logic [3:0]  tleft, width;
  logic        last, stuff_pend, st_en, arb_en;
  logic [2:0]  run;
  logic        silent, own, role_tx, joinw;
  logic [7:0]  rsh;
  logic [3:0]  rbits;
  logic [4:0]  icnt;
  logic        after, susp;
  logic [3:0]  tpos;
  logic        flag_on, flag_pas, fprev, ack_exc, first_after;
  logic [2:0]  fcnt;
  logic [3:0]  dom_cnt;
  logic [2:0]  dcnt;
  logic [6:0]  rseq;
  logic [3:0]  rrun;

  assign passive  = tec >= 9'd128 || rec >= 8'd128;
  assign busoff   = cs == C_BUSOFF;
  assign tx_ready = !q_valid;
  assign drive    = drv;

  wire fall   = a_d && !a_in;
  wire in_bus = cs != C_IDLE;
  // ISO 11898-1: at most one synchronization between two sample points
  logic synced;
  wire resync = fall && !drv && in_bus && !synced;
  wire hard   = fall && cs == C_IDLE;
  wire tend   = cnt == period_m1;
  wire sample = cnt == spv && !sampled;
  wire b      = a_in;

  // the unit bits
  wire [7:0] src   = (tleft != 4'd0) ? tsh : q_data;
  wire       nb    = out_msb_first ? src[7] : src[0];
  wire [7:0] rest  = out_msb_first ? {src[6:0], 1'b0} : {1'b0, src[7:1]};
  wire       have  = tleft != 4'd0 || q_valid;
  wire [3:0] start_w = cfg[5] ? 4'd8 : 4'd1;
  wire       q_first = out_msb_first ? q_data[7] : q_data[0];
  // a frame's first unit always comes from the queue, never from a unit cut short by an error
  wire [7:0] q_rest  = out_msb_first ? {q_data[6:0], 1'b0} : {1'b0, q_data[7:1]};

  // may this node start (or join) a frame now
  wire [4:0] need = (after ? 5'd3 : 5'd11) + (susp ? 5'd8 : 5'd0);
  wire       may_tx = !idle_wait || icnt >= need;

  // frame start: own (bus idle, at a bit boundary) or foreign (hard synchronization)
  wire own_start = cs == C_IDLE && tend && q_valid && !q_first && may_tx;
  wire fstart    = own_start || hard;
  // the late join: a unit queued during the start-of-frame bit, before its sample point
  wire late_join = cs == C_FRAME && sof && joinw && !sampled && q_valid;

  // receive: the bit after stuffing state and unit assembly
  logic [2:0] run_nx;
  always_comb begin
    if (ones) run_nx = b ? run + 3'd1 : 3'd0;
    else      run_nx = (b == last) ? run + 3'd1 : 3'd1;
  end
  wire [7:0] rsh_n = in_msb_first ? {rsh[6:0], b} : (rsh | ({7'd0, b} << rbits));

  // the role in this frame, for the counters
  wire        is_rx = !role_tx;
  logic       e_now, e_bit, e_ack;   // an error detected in this clock
  logic       e_rx8, e_tx8;          // +8 events without a new error flag
  always_comb begin
    e_now = 1'b0; e_bit = 1'b0; e_ack = 1'b0; e_rx8 = 1'b0; e_tx8 = 1'b0;
    if (sample) case (cs)
      C_FRAME:
        if (sof && b && !drv) ;                            // not a start of frame: see below
        else if (slot_stuff) e_now = b != cur;             // stuff error
        else if (!silent && !(arb_en && cur && !b) && b != cur) begin
          e_now = 1'b1;                                    // bit error
          e_bit = 1'b1;
        end
      C_TAIL:
        case (tpos)
          4'd1: if (role_tx && b) begin                    // ACK error
            e_now = 1'b1;
            e_ack = 1'b1;
          end
          4'd2: e_now = !b || (is_rx && !crc_ok);          // form error, or CRC error
          4'd9: e_now = !b && role_tx;                     // EOF 7: a receiver ignores it
          default: e_now = !b;                             // delimiter / EOF: form error
        endcase
      C_EFLAG:
        if (flag_on && !flag_pas && b) begin               // bit error in an active flag
          e_tx8 = role_tx;
          e_rx8 = is_rx;
        end else if (flag_on && flag_pas && ack_exc && !b) e_tx8 = 1'b1;
      C_EDWAIT:
        if (!b) begin
          if (first_after && is_rx) e_rx8 = 1'b1;
          if (dom_cnt == (flag_pas ? 4'd7 : 4'd13)) begin  // 8 / 14 dominant bits
            e_tx8 = role_tx;
            e_rx8 = is_rx;
          end
        end
      C_EDELIM: e_now = !b;                                // form error in the delimiter
      default: ;
    endcase
    if (ctl && ctl_param[4] && ctl_param[2] && (cs == C_FRAME || cs == C_TAIL)) e_now = 1'b1;
  end

  // counter arithmetic
  wire        add8_tx = (e_now && role_tx && !(e_ack && passive)) || e_tx8;
  wire        add1_rx = e_now && is_rx;
  wire [9:0]  tec_add = {1'b0, tec} + (add8_tx ? 10'd8 : 10'd0);
  wire [8:0]  rec_add = {1'b0, rec} + (e_rx8 ? 9'd8 : add1_rx ? 9'd1 : 9'd0);
  wire [7:0]  rec_sat = rec_add[8] ? 8'd255 : rec_add[7:0];
  wire        to_busoff = tec_add > 10'd255;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cnt <= '0; sampled <= 1'b0; a_d <= 1'b1; cs <= C_INTEG; drv <= 1'b0; cur <= 1'b1; synced <= 1'b0;
      slot_stuff <= 1'b0; sof <= 1'b0; q_valid <= 1'b0; q_data <= '0; tsh <= '0; tleft <= '0;
      width <= 4'd1; last <= 1'b1; stuff_pend <= 1'b0; st_en <= 1'b0; arb_en <= 1'b0; run <= '0;
      silent <= 1'b0; own <= 1'b0; role_tx <= 1'b0; joinw <= 1'b0; rsh <= '0; rbits <= '0;
      icnt <= '0; after <= 1'b0; susp <= 1'b0; tpos <= '0; flag_on <= 1'b0; flag_pas <= 1'b0;
      fprev <= 1'b0; ack_exc <= 1'b0; first_after <= 1'b0; fcnt <= '0;
      dom_cnt <= '0; dcnt <= '0; rseq <= '0; rrun <= '0; tec <= '0; rec <= '0;
      rx_valid <= 1'b0; rx_data <= '0; frame_end <= 1'b0; err <= 1'b0; crc_step <= 1'b0;
      crc_bit <= 1'b0; arb_lost <= 1'b0; bit_err <= 1'b0; sent <= 1'b0;
    end else if (clear) begin
      // the error counters survive a restart (ISO: only bus-off recovery or a reset clears them)
      cnt <= '0; sampled <= 1'b0; a_d <= 1'b1; cs <= (cs == C_BUSOFF) ? C_BUSOFF : C_INTEG; synced <= 1'b0;
      drv <= 1'b0; cur <= 1'b1;
      slot_stuff <= 1'b0; sof <= 1'b0; q_valid <= 1'b0; q_data <= '0; tsh <= '0; tleft <= '0;
      width <= 4'd1; last <= 1'b1; stuff_pend <= 1'b0; st_en <= 1'b0; arb_en <= 1'b0; run <= '0;
      silent <= 1'b0; own <= 1'b0; role_tx <= 1'b0; joinw <= 1'b0; rsh <= '0; rbits <= '0;
      icnt <= '0; after <= 1'b0; susp <= 1'b0; tpos <= '0; flag_on <= 1'b0; flag_pas <= 1'b0;
      fprev <= 1'b0; ack_exc <= 1'b0; first_after <= 1'b0; fcnt <= '0;
      dom_cnt <= '0; dcnt <= '0; rrun <= '0;
      rx_valid <= 1'b0; rx_data <= '0; frame_end <= 1'b0; err <= 1'b0; crc_step <= 1'b0;
      crc_bit <= 1'b0; arb_lost <= 1'b0; bit_err <= 1'b0; sent <= 1'b0;
    end else begin
      frame_end <= 1'b0; err <= 1'b0; crc_step <= 1'b0; arb_lost <= 1'b0; bit_err <= 1'b0;
      sent <= 1'b0;
      a_d <= a_in;
      if (rx_take) rx_valid <= 1'b0;
      if (tx_put) begin
        q_valid <= 1'b1;
        q_data  <= tx_data;
      end

      // ---- timer ----
      if (fstart || tend || (resync && sampled)) begin
        cnt     <= '0;
        sampled <= 1'b0;
      end else if (resync) cnt <= '0;            // a late edge: the current bit restarts
      else cnt <= cnt + 16'd1;
      if (sample) sampled <= 1'b1;
      if (sample) synced <= 1'b0;
      else if (resync || fstart) synced <= 1'b1;

      // ---- LINECTL ----
      if (ctl) begin
        if (!ctl_param[4]) begin
          width  <= {1'b0, ctl_param[2:0]} + 4'd1;
          arb_en <= ctl_param[3];
        end else begin
          if (ctl_param[0]) st_en <= 1'b0;
          if (ctl_param[1]) st_en <= 1'b1;
        end
      end

      // ---- bit start ----
      if (fstart) begin
        cs <= C_FRAME; sof <= 1'b1; last <= 1'b1; run <= '0; stuff_pend <= 1'b0;
        st_en <= st != 2'd0; arb_en <= 1'b1; width <= start_w; rbits <= '0; rsh <= '0;
        slot_stuff <= 1'b0; after <= 1'b0; susp <= 1'b0; tleft <= '0;
        if (q_valid) begin                       // this node's queued unit is the first one
          tsh     <= q_rest;
          tleft   <= start_w - 4'd1;
          q_valid <= 1'b0;
          cur     <= q_first;
          own     <= !q_first && may_tx;
          role_tx <= !q_first && may_tx;
          silent  <= !may_tx;
          drv     <= !q_first && may_tx;
          if (!q_first && !may_tx) arb_lost <= 1'b1;  // may not start yet: lost before it began
          joinw   <= 1'b0;
        end else begin
          cur <= 1'b1; own <= 1'b0; role_tx <= 1'b0; silent <= 1'b0; drv <= 1'b0;
          joinw <= 1'b1;
        end
      end else if (late_join) begin
        tsh     <= q_rest;
        tleft   <= width - 4'd1;
        q_valid <= 1'b0;
        cur     <= q_first;
        own     <= !q_first && may_tx;
        role_tx <= !q_first && may_tx;
        silent  <= !may_tx;
        drv     <= !q_first && may_tx;
        if (!q_first && !may_tx) arb_lost <= 1'b1;
        joinw   <= 1'b0;
      end else if ((tend || (resync && sampled)) && cs != C_IDLE) begin
        sof <= 1'b0; joinw <= 1'b0;
        case (cs)
          C_FRAME:
            if (stuff_pend) begin
              slot_stuff <= 1'b1;
              cur <= ones ? 1'b0 : !last;
              drv <= !silent && (ones ? 1'b1 : last);
            end else if (!st_en) begin           // the stuffed region is over: the tail
              cs <= C_TAIL; tpos <= '0; slot_stuff <= 1'b0; silent <= 1'b0;
              cur <= 1'b1; drv <= 1'b0;
            end else begin
              slot_stuff <= 1'b0;
              if (have) begin
                cur   <= nb;
                drv   <= !silent && !nb;
                tsh   <= rest;
                tleft <= (tleft != 4'd0) ? tleft - 4'd1 : width - 4'd1;
                if (tleft == 4'd0) q_valid <= 1'b0;
              end else begin
                cur <= 1'b1;
                drv <= 1'b0;
              end
            end
          C_TAIL: begin
            tpos <= tpos + 4'd1;
            // the ACK slot (tpos 1 next): a node that did not transmit acknowledges a good CRC
            cur  <= !(tpos == 4'd0 && is_rx && crc_ok);
            drv  <= tpos == 4'd0 && is_rx && crc_ok;
          end
          C_EFLAG: begin
            if (!flag_on) begin
              flag_on <= 1'b1;
              fcnt    <= '0;
            end
            cur <= flag_pas;
            drv <= !flag_pas;
          end
          default: begin
            cur <= 1'b1;
            drv <= 1'b0;
          end
        endcase
      end else if (tend && cs == C_IDLE) begin
        cur <= 1'b1;
        drv <= 1'b0;
      end

      // ---- sample point ----
      if (sample) begin
        case (cs)
          C_INTEG: begin
            icnt <= b ? icnt + 5'd1 : 5'd0;
            if (b && icnt == 5'd10) begin
              cs   <= C_IDLE;
              icnt <= 5'd11;
            end
          end
          C_IDLE:
            if (b) begin
              if (icnt != 5'd31) icnt <= icnt + 5'd1;
            end else icnt <= '0;
          C_FRAME:
            if (sof && b && !drv) begin          // a glitch, not a start of frame
              cs <= C_IDLE;
              drv <= 1'b0;
            end else if (slot_stuff) begin
              stuff_pend <= 1'b0;
              last <= b;
              run  <= ones ? 3'd0 : 3'd1;
            end else begin
              last <= b;
              run  <= run_nx;
              stuff_pend <= st_en && st != 2'd0 && run_nx == run_n;
              if (!silent && arb_en && cur && !b) begin   // lost arbitration
                silent  <= 1'b1;
                drv     <= 1'b0;
                role_tx <= 1'b0;
                if (own) arb_lost <= 1'b1;
              end
              if (st_en) begin
                crc_step <= 1'b1;
                crc_bit  <= b;
              end
              if (rbits == width - 4'd1) begin
                rx_data  <= rsh_n;
                if (rx_valid && !rx_take) err <= 1'b1;
                rx_valid <= 1'b1;
                rbits    <= '0;
                rsh      <= '0;
              end else begin
                rbits <= rbits + 4'd1;
                rsh   <= rsh_n;
              end
            end
          C_TAIL:
            if (tpos == 4'd9 && !e_now) begin    // the frame is over
              cs <= C_IDLE; icnt <= '0; after <= 1'b1; susp <= role_tx && passive;
              frame_end <= 1'b1;
              if (role_tx) begin
                sent <= 1'b1;
                if (tec != 9'd0) tec <= tec - 9'd1;
              end else if (rec > 8'd127) rec <= 8'd119;
              else if (rec != 8'd0) rec <= rec - 8'd1;
            end
          C_EFLAG:
            if (flag_on) begin
              fcnt  <= fcnt + 3'd1;
              fprev <= b;
              if (flag_pas) begin
                // a passive flag ends after 6 equal bits on the bus, counted from its start
                if (fcnt == 3'd0 || b != fprev) fcnt <= 3'd1;
                if (fcnt != 3'd0 && b == fprev && fcnt == 3'd5) begin
                  cs <= C_EDWAIT; dom_cnt <= '0; first_after <= 1'b1;
                end
                if (!b) ack_exc <= 1'b0;
              end else if (fcnt == 3'd5) begin
                cs <= C_EDWAIT; dom_cnt <= 4'd6; first_after <= 1'b1;
              end
            end
          C_EDWAIT: begin
            first_after <= 1'b0;
            if (b) begin
              cs <= C_EDELIM; dcnt <= 3'd1;
            end else if (dom_cnt == (flag_pas ? 4'd7 : 4'd13)) dom_cnt <= flag_pas ? 4'd0 : 4'd6;
            else dom_cnt <= dom_cnt + 4'd1;
          end
          C_EDELIM:
            if (b) begin
              dcnt <= dcnt + 3'd1;
              if (dcnt == 3'd7) begin
                cs <= C_IDLE; icnt <= '0; after <= 1'b1; susp <= role_tx && passive;
              end
            end
          default: begin                         // C_BUSOFF: wait for 128 x 11 recessive bits
            if (!b) rrun <= '0;
            else if (rrun == 4'd10) begin
              rrun <= '0;
              rseq <= rseq + 7'd1;
              if (rseq == 7'd127) begin
                cs <= C_IDLE; icnt <= 5'd11; after <= 1'b0; susp <= 1'b0;
                tec <= '0; rec <= '0;
              end
            end else rrun <= rrun + 4'd1;
          end
        endcase
      end

      // ---- an error: count it, then the error flag from the next bit (or bus-off) ----
      if (e_tx8 || e_rx8) begin
        tec <= tec_add[8:0];
        rec <= rec_sat;
        if (e_tx8 && ack_exc) ack_exc <= 1'b0;
        if (to_busoff) begin
          cs <= C_BUSOFF; rseq <= '0; rrun <= '0; drv <= 1'b0;
        end
      end
      if (e_now) begin
        err       <= 1'b1;
        frame_end <= 1'b1;
        bit_err   <= e_bit;
        q_valid   <= 1'b0;
        tleft     <= '0;                         // the unit being sent is abandoned too
        rx_valid  <= 1'b0;
        tec       <= tec_add[8:0];
        rec       <= rec_sat;
        ack_exc   <= e_ack && passive && role_tx;
        silent    <= 1'b0;
        if (to_busoff) begin
          cs <= C_BUSOFF; rseq <= '0; rrun <= '0; drv <= 1'b0;
        end else begin
          // the flag type is the state in which the error was detected (ISO 11898-1: the
          // counter changes when the flag is sent, so the error that reaches 128 still gets
          // an active flag; the next one gets a passive flag)
          cs <= C_EFLAG; flag_on <= 1'b0; flag_pas <= passive;
        end
      end
      if (drop) begin
        q_valid <= 1'b0;
        if (cs != C_FRAME) tleft <= '0;
      end
    end
  end
endmodule
