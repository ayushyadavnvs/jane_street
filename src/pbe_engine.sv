// One Programmable Bit Engine.
//
// Instruction word (16 bits):  [15:13] OP | [12:4] ARG | [3:0] DLY
// Each instruction issues on a tick and then idles DLY more ticks before the next one.
// A tick is one clock every (clkdiv + 1) clocks.
//
// Instruction fetch (D50): the instruction runs from a register (instr_q), not straight from
// the program memory, which cuts the clock's worst path in two. The memory is read at `pc`,
// the word after the current instruction, so the next word is always ready when the current
// one executes. A taken jump (JMP, JCRCBAD, JEQ, JNE, JLINE, the timeout) must fetch its target
// first: one clock with no instruction (a bubble). A tick that falls on a bubble is held for
// that clock, so it is late, never lost. Instruction times:
//   CLKDIV >= 1: (DLY + 1) * (CLKDIV + 1) clocks, exactly as without the register (the next
//                tick is at least 2 clocks away, and the bubble fits in between).
//   CLKDIV = 0, and the line coder (instructions run every clock): DLY + 1 clocks, plus 1 for
//                a taken jump. The first instruction after a restart starts 1 clock later.
// A host write to the program memory refetches the current instruction (one bubble), so a
// program the host changes is never run from a stale copy; with CLKDIV = 0 the engine slips
// by that clock.
//
//  OP   name        ARG
//  000  PIN p, act  [8:6] pin, [5:3] act: 0 DRV0, 1 DRV1, 2 REL, 3 TOG, 4 OUT, 5 OUTOD, 6 OUTPAR,
//                   7 END (line coder: end the frame); [0] NOCRC (OUT/OUTOD): leave this bit out
//                   of the CRC
//  001  IN p        [8:6] pin, [5] NOCRC       shift pin into ISR
//  010  WAIT        [8:6] pin (or flag in [7:6]), [5] 1 = flag, [4:3] 0 LOW, 1 HIGH, 2 RISE, 3 FALL
//  011  JMP         [8:6] cond, [5:0] addr    cond: 0 ALWAYS, 1 X-- != 0, 2 PIN_HI, 3 PIN_LO,
//                                             4 TX_EMPTY, 5 TX_READY, 6 FLAG0, 7 FLAG1
//  100  SET         [8] 0 = X, 1 = OSR; [7:0] value
//  101  PULL/PUSH   [8] 0 = PULL (TX FIFO -> OSR), 1 = PUSH (ISR -> RX FIFO, then clear ISR)
//  110  FLAG        [8:7] 0 SET, 1 CLR, 2 IRQ, 3 MOV; [1:0] flag
//                   MOV: [5:4] destination, [3:2] source: 1 X, 2 OSR, 3 ISR (source 0: zero);
//                   destination 0 does nothing (0xD800 is the assembler's NOP)
//  111  EXT         [8:6] sub-op, [5:0] param
//                   0 CRCRST      load the CRC's initial value and clear the line error: a new
//                                 checked packet starts
//                   1 OSRCRC      OSR <= CRC byte (param[0]: 0 low, 1 high; param[1]: inverted)
//                   2 STAT        ISR <= {3'b0, line error, RX overflow, timeout happened, CRC ok,
//                                 parity error}; then clears parity and timeout (not the line
//                                 error: a JCRCBAD after STAT must still see it)
//                   3 JCRCBAD a   jump to a if the packet is bad: the CRC is not ok (not at its
//                                 good value) or the line coder saw an error since the last CRCRST
//                   4 JEQ a       jump to a if ISR == OSR
//                   5 JNE a       jump to a if ISR != OSR
//                   6 JLINE a     jump to a if the line coder saw the end of a frame; clears it
//                   7             reserved, executes as nothing
//
// Parity: OUT/OUTOD bits since the last OSR load make the send parity; OUTPAR drives it
// (inverted for odd parity). IN bits since the last STAT make the receive parity; with the
// parity bit included it must come out 0 (even) or 1 (odd), otherwise STAT reports an error.
// With line_cfg[6] (no parity) OUTPAR sends 1 (a second stop bit) and no parity error is reported.
// RX overflow: a PUSH that finds the RX FIFO full sets a sticky status bit and raises IRQ.
// CRC: OUT/OUTOD and IN bits feed the CRC unit when enabled in crc_cfg, unless marked NOCRC.
// "CRC ok" means the register equals crc_good (0 for CRCs sent plain; the residual, e.g. USB's
// 0x800d, for CRCs sent inverted).
//
// Line coder (coder_cfg[1:0] != 0, see pbe_line): it drives pin_base (and pin_base + 1 in pair
// mode) and sets the bit timing: clkdiv is then the bit time minus 1, and instructions run
// every clock. OUT/OUTOD hand the coder a byte (or one bit) and wait while it is busy; END ends
// the frame; IN takes a received byte (or bit) and waits for one, or for the end of the frame
// (then ISR is unchanged and JLINE jumps). In byte mode the 8 bits of each OUT/IN feed the CRC
// one per clock afterwards; the next instruction waits until they are in.
// Timeout: if WAIT, PULL or PUSH stays blocked for timeout ticks (0 = never), the engine
// abandons it, jumps to timeout_pc and sets the "timeout happened" status bit.
//
// WAIT, PULL and PUSH block until they can complete. While blocked the engine checks
// every clock (not every tick), and when it unblocks the tick divider restarts, so
// following instructions are timed from the moment the condition was met.
//
// Pin numbers are relative to pin_base (mod 8); the JMP pin is jmp_pin + pin_base.
// Program addresses are relative to start_pc: a program starts at its own word 0, and every
// jump (JMP, JCRCBAD, the timeout) goes to start_pc + target, so each engine works in its own
// 64-word window of the 128-word program memory.
module pbe_engine (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        run,
    input  logic        restart,  // 1-cycle pulse
    // configuration
    input  logic [15:0] clkdiv,
    input  logic [2:0]  pin_base,
    input  logic [2:0]  jmp_pin,
    input  logic        out_msb_first,
    input  logic        in_msb_first,
    input  logic [6:0]  start_pc,     // where this engine's program starts (its word 0)
    input  logic [15:0] crc_poly,
    input  logic [7:0]  crc_cfg,      // [3:0] width-1, [4] init ones, [5] reversed, [6] feed OUT, [7] feed IN
    input  logic [15:0] timeout,      // ticks a blocked instruction may wait (0 = forever)
    input  logic [7:0]  line_cfg,     // [5:0] timeout_pc, [6] no parity, [7] odd parity
    input  logic [7:0]  coder_cfg,    // line coder, see pbe_line (0 = off)
    input  logic [7:0]  sync,         // line coder frame start pattern
    input  logic [15:0] crc_good,     // the CRC value that means "ok"
    input  logic        host_crc_init,
    input  logic        host_tmo_clr,
    input  logic        host_ovf_clr,
    input  logic        host_lerr_clr,
    output logic [4:0]  status,       // {line error, RX overflow, timeout happened, CRC ok, parity error}
    output logic [15:0] crc_now,      // the CRC unit's current value, for the host
    // program memory
    output logic [6:0]  pc,           // program memory read address (absolute): the next word
    output logic [20:0] pc_copy,      // three more copies of pc, to share out its fan-out
    output logic [6:0]  pc_d,         // the value pc takes at the next clock (an SRAM's address, D55)
    input  logic [15:0] instr,        // the program memory word at pc
    input  logic        pm_wr,        // the host is writing the program memory (any word)
    // pins
    input  logic [7:0]  pins_in,  // synchronized
    output logic [7:0]  pins_out,
    output logic [7:0]  pins_oe,  // (the line coder's pins are merged in combinationally)
    // TX FIFO (host to engine)
    input  logic [7:0]  tx_data,
    input  logic        tx_empty,
    output logic        tx_pop,
    // RX FIFO (engine to host)
    output logic [7:0]  rx_data,
    input  logic        rx_full,
    output logic        rx_push,
    // shared flags
    input  logic [3:0]  flags,
    output logic [3:0]  flag_set,
    output logic [3:0]  flag_clr,
    output logic        irq
);
  localparam logic [2:0] OP_PIN = 3'd0, OP_IN = 3'd1, OP_WAIT = 3'd2, OP_JMP = 3'd3,
                         OP_SET = 3'd4, OP_FIFO = 3'd5, OP_FLAG = 3'd6, OP_EXT = 3'd7;
  localparam logic [2:0] E_CRCRST = 3'd0, E_OSRCRC = 3'd1, E_STAT = 3'd2, E_JCRCBAD = 3'd3,
                         E_JEQ = 3'd4, E_JNE = 3'd5, E_JLINE = 3'd6;

  logic [15:0] div_cnt;
  logic [3:0]  dly_cnt;
  logic        blocked;
  logic [7:0]  x, osr, isr;
  logic [7:0]  pins_prev;
  logic [3:0]  flags_prev;
  logic        par_out, par_in, tmo_seen, rx_ovf;
  logic [15:0] tmo_cnt;
  logic [7:0]  pout, poe;   // the pin unit's own drive; the line coder can take over its pins
  logic        line_ev, line_err;
  logic [3:0]  cf_cnt;      // byte mode: CRC bits still to feed
  logic [7:0]  cf_sh;
  logic [15:0] instr_q;     // the current instruction
  logic        iv;          // instr_q holds the word at pc - 1 (else it is being fetched from pc)

  // ---- decode ----
  wire [2:0] op  = instr_q[15:13];
  wire [8:0] arg = instr_q[12:4];
  wire [3:0] dly = instr_q[3:0];

  wire [2:0] arg_pin  = arg[8:6];
  wire [2:0] pin_act  = arg[5:3];
  wire [1:0] wait_cnd = arg[4:3];
  wire [2:0] jmp_cnd  = arg[8:6];
  wire [1:0] flag_act = arg[8:7];
  wire       arg_hi   = arg[8];

  wire [2:0] pin_idx = pin_base + arg_pin;
  wire [2:0] jmp_idx = pin_base + jmp_pin;
  wire       pin_now = pins_in[pin_idx];
  wire       pin_was = pins_prev[pin_idx];

  wire       out_bit = out_msb_first ? osr[7] : osr[0];
  wire [7:0] osr_shifted = out_msb_first ? {osr[6:0], 1'b0} : {1'b0, osr[7:1]};
  wire [7:0] isr_shifted = in_msb_first ? {isr[6:0], pin_now} : {pin_now, isr[7:1]};

  wire [2:0] ext_op   = arg[8:6];
  wire       odd      = line_cfg[7];
  wire       no_par   = line_cfg[6];
  wire [5:0] tmo_pc   = line_cfg[5:0];
  wire       par_err  = !no_par && (par_in ^ odd);
  wire       par_bit  = no_par || (par_out ^ odd);  // what OUTPAR sends

  // ---- line coder ----
  wire       coder_on = coder_cfg[1:0] != 2'd0;
  wire       coder_bytes = coder_cfg[5];
  wire       coder_pair = coder_cfg[4];
  wire [2:0] base1 = pin_base + 3'd1;
  wire       is_txop = coder_on && op == OP_PIN && (pin_act == 3'd4 || pin_act == 3'd5 || pin_act == 3'd7);
  logic       l_drive, l_a, l_b, l_ready, l_rxv, l_end, l_err;
  logic [7:0] l_rxd;

  // ---- issue and readiness ----
  wire tick_due = coder_on || (div_cnt >= clkdiv);
  wire tick     = tick_due && iv;  // a tick that falls on a fetch bubble waits for it
  wire issue    = run && iv && (blocked || (tick && dly_cnt == 4'd0));

  wire now = arg[5] ? flags[arg[7:6]] : pin_now;
  wire was = arg[5] ? flags_prev[arg[7:6]] : pin_was;

  logic wait_ok;
  always_comb begin
    case (wait_cnd)
      2'd0:    wait_ok = !now;
      2'd1:    wait_ok = now;
      2'd2:    wait_ok = !was && now;
      default: wait_ok = was && !now;
    endcase
  end

  logic ready;
  always_comb begin
    case (op)
      OP_WAIT: ready = wait_ok;
      OP_FIFO: ready = arg_hi ? !rx_full : !tx_empty;
      OP_PIN:  ready = !is_txop || l_ready;
      OP_IN:   ready = !coder_on || l_rxv || line_ev;
      default: ready = 1'b1;
    endcase
    if (cf_cnt != 4'd0) ready = 1'b0;  // byte-mode CRC feed still running
  end

  // A restart in the same cycle cancels the instruction, so it has no side effects.
  wire exec = issue && ready && !restart;

  // A blocked instruction that has waited `timeout` ticks is abandoned.
  wire tmo_hit = run && !restart && iv && blocked && !ready && timeout != 16'd0 && tmo_cnt >= timeout;

  // ---- CRC unit, fed by the bits the engine shifts ----
  wire is_out = exec && op == OP_PIN && (pin_act == 3'd4 || pin_act == 3'd5);
  wire is_in  = exec && op == OP_IN && (!coder_on || l_rxv);  // not an IN ended by end of frame
  wire in_bit = coder_on ? l_rxd[0] : pin_now;
  wire crc_out = is_out && !arg[0] && crc_cfg[6];
  wire crc_in  = is_in && !arg[5] && crc_cfg[7];
  logic [15:0] crc_value;
  logic        crc_ok;

  // byte mode: the CRC takes the byte's bits in wire order, one per clock
  wire [7:0] cf_byte = crc_out ? osr : l_rxd;
  wire       cf_msb  = crc_out ? out_msb_first : in_msb_first;
  wire [7:0] cf_load = cf_msb ? {cf_byte[0], cf_byte[1], cf_byte[2], cf_byte[3],
                                 cf_byte[4], cf_byte[5], cf_byte[6], cf_byte[7]} : cf_byte;
  wire       cf_start = coder_on && coder_bytes && (crc_out || crc_in);

  pbe_crc u_crc (
      .clk, .rst_n,
      .init     (host_crc_init || restart || (exec && op == OP_EXT && ext_op == E_CRCRST)),
      .step     (cf_cnt != 4'd0 || (!cf_start && (crc_out || crc_in))),
      .bit_in   (cf_cnt != 4'd0 ? cf_sh[0] : is_out ? out_bit : in_bit),
      .poly     (crc_poly),
      .width_m1 (crc_cfg[3:0]),
      .init_ones(crc_cfg[4]),
      .out_rev  (crc_cfg[5]),
      .good     (crc_good),
      .value    (crc_value),
      .ok       (crc_ok)
  );

  assign status  = {line_err, rx_ovf, tmo_seen, crc_ok, par_err};
  assign crc_now = crc_value;

  pbe_line u_line (
      .clk, .rst_n,
      .clear        (restart || !coder_on),
      .cfg          (coder_cfg),
      .sync,
      .period_m1    (clkdiv),
      .out_msb_first,
      .in_msb_first,
      .a_in         (pins_in[pin_base]),
      .b_in         (pins_in[base1]),
      .drive        (l_drive),
      .a_out        (l_a),
      .b_out        (l_b),
      .tx_put       (exec && is_txop && pin_act != 3'd7),
      .tx_end       (exec && is_txop && pin_act == 3'd7),
      .tx_data      (coder_bytes ? osr : {7'b0, out_bit}),
      .tx_ready     (l_ready),
      .rx_valid     (l_rxv),
      .rx_data      (l_rxd),
      .rx_take      (exec && coder_on && op == OP_IN && l_rxv),
      .frame_end    (l_end),
      .err          (l_err)
  );

  // the coder's pins override the pin unit while it drives them
  wire [7:0] l_mask = l_drive ? ((8'd1 << pin_base) | (coder_pair ? 8'd1 << base1 : 8'd0)) : 8'd0;
  wire [7:0] l_val  = ({7'd0, l_a} << pin_base) | ({7'd0, l_b} << base1);
  assign pins_out = (pout & ~l_mask) | (l_val & l_mask);
  assign pins_oe  = poe | l_mask;

  // A PUSH that finds the RX FIFO full: the host is not keeping up.
  wire ovf_now = run && !restart && issue && op == OP_FIFO && arg_hi && rx_full;

  logic jmp_take;
  always_comb begin
    case (jmp_cnd)
      3'd0:    jmp_take = 1'b1;
      3'd1:    jmp_take = (x != 8'd0);
      3'd2:    jmp_take = pins_in[jmp_idx];
      3'd3:    jmp_take = !pins_in[jmp_idx];
      3'd4:    jmp_take = tx_empty;
      3'd5:    jmp_take = !tx_empty;
      3'd6:    jmp_take = flags[0];
      default: jmp_take = flags[1];
    endcase
  end

  // MOV: FLAG action 3 with a destination
  wire       is_mov  = op == OP_FLAG && flag_act == 2'd3 && arg[5:4] != 2'd0;
  logic [7:0] mov_val;
  always_comb begin
    case (arg[3:2])
      2'd1:    mov_val = x;
      2'd2:    mov_val = osr;
      2'd3:    mov_val = isr;
      default: mov_val = 8'd0;
    endcase
  end
  wire jline_take = exec && op == OP_EXT && ext_op == E_JLINE && line_ev;

  // a jump the current instruction takes if it executes: the next word must be fetched again
  logic jump;
  always_comb begin
    case (op)
      OP_JMP: jump = jmp_take;
      OP_EXT:
        case (ext_op)
          E_JCRCBAD: jump = !crc_ok || line_err;
          E_JEQ:     jump = isr == osr;
          E_JNE:     jump = isr != osr;
          E_JLINE:   jump = line_ev;
          default:   jump = 1'b0;
        endcase
      default: jump = 1'b0;
    endcase
  end
  wire [6:0] jump_pc = start_pc + {1'b0, arg[5:0]};

  // ---- fetch address ----
  logic [6:0] pc_next;
  always_comb begin
    pc_next = pc;
    if (restart) pc_next = start_pc;
    else begin
      if (!iv) pc_next = pc + 1'b1;  // the fetch fills instr_q: read on
      if (exec) pc_next = jump ? jump_pc : pc + 1'b1;
      if (tmo_hit) pc_next = start_pc + {1'b0, tmo_pc};
      // A host write to the program memory may change the current or the next word: fetch the
      // instruction that runs next again (a jump fetches its target anyway). pm_wr appears only
      // in `if`s: the unit testbenches leave it unconnected, and z must read as no write.
      if (pm_wr && !(exec && jump) && !tmo_hit) pc_next = (iv && !exec) ? pc - 1'b1 : pc;
    end
  end

  // pc drives the read multiplexers of all 16 bits of the program memory: thousands of inputs,
  // which place and route had to reach through long buffer chains (D50). Four copies each read
  // 4 bits. `keep` stops synthesis from merging them back into one register.
  assign pc_d = pc_next;

  (* keep *)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pc      <= '0;
      pc_copy <= '0;
    end else begin
      pc      <= pc_next;
      pc_copy <= {3{pc_next}};
    end
  end

  // ---- side-effect pulses (combinational, valid in the exec cycle) ----
  assign tx_pop   = exec && op == OP_FIFO && !arg_hi;
  assign rx_push  = exec && op == OP_FIFO && arg_hi;
  assign rx_data  = isr;
  assign flag_set = (exec && op == OP_FLAG && flag_act == 2'd0) ? (4'b0001 << arg[1:0]) : 4'b0000;
  assign flag_clr = (exec && op == OP_FLAG && flag_act == 2'd1) ? (4'b0001 << arg[1:0]) : 4'b0000;
  assign irq      = (exec && op == OP_FLAG && flag_act == 2'd2) || (ovf_now && !rx_ovf);

  // ---- state ----
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      instr_q    <= '0;
      iv         <= 1'b0;
      div_cnt    <= '0;
      dly_cnt    <= '0;
      blocked    <= 1'b0;
      x          <= '0;
      osr        <= '0;
      isr        <= '0;
      pout       <= '0;
      poe        <= '0;
      line_ev    <= 1'b0;
      line_err   <= 1'b0;
      cf_cnt     <= '0;
      cf_sh      <= '0;
      pins_prev  <= '0;
      flags_prev <= '0;
      par_out    <= 1'b0;
      par_in     <= 1'b0;
      tmo_seen   <= 1'b0;
      tmo_cnt    <= '0;
      rx_ovf     <= 1'b0;
    end else if (restart) begin
      iv       <= 1'b0;
      div_cnt  <= '0;
      dly_cnt  <= '0;
      blocked  <= 1'b0;
      x        <= '0;
      osr      <= '0;
      isr      <= '0;
      poe      <= '0;  // release every pin; keep pout so a line held high cannot glitch low
      line_ev  <= 1'b0;
      line_err <= 1'b0;
      cf_cnt   <= '0;
      par_out  <= 1'b0;
      par_in   <= 1'b0;
      tmo_seen <= 1'b0;
      tmo_cnt  <= '0;
      rx_ovf   <= 1'b0;
    end else begin
      pins_prev  <= pins_in;
      flags_prev <= flags;
      if (host_tmo_clr) tmo_seen <= 1'b0;
      if (host_ovf_clr) rx_ovf <= 1'b0;
      else if (ovf_now) rx_ovf <= 1'b1;
      line_ev <= (line_ev && !jline_take) || l_end;
      if (host_lerr_clr) line_err <= 1'b0;
      else if (l_err) line_err <= 1'b1;
      if (cf_cnt != 4'd0) begin
        cf_cnt <= cf_cnt - 4'd1;
        cf_sh  <= {1'b0, cf_sh[7:1]};
      end else if (cf_start) begin
        cf_cnt <= 4'd8;
        cf_sh  <= cf_load;
      end

      // fetch: fill an empty instruction register (also while stopped)
      if (!iv) begin
        instr_q <= instr;
        iv      <= 1'b1;
      end

      if (run) begin
        // tick divider; restarts when a blocked instruction completes
        if ((exec && blocked) || tmo_hit) div_cnt <= '0;
        else if (tick) div_cnt <= '0;
        else if (!tick_due) div_cnt <= div_cnt + 1'b1;

        if (tick && dly_cnt != 4'd0 && !blocked) dly_cnt <= dly_cnt - 1'b1;

        if (issue && !ready) blocked <= 1'b1;

        // timeout counter: ticks spent blocked
        if (!blocked) tmo_cnt <= '0;
        else if (tick) tmo_cnt <= tmo_cnt + 1'b1;

        if (exec) begin
          blocked <= 1'b0;
          dly_cnt <= dly;
          if (jump) iv <= 1'b0;
          else instr_q <= instr;  // the next word, already read at pc

          case (op)
            OP_PIN: begin
              if (coder_on && is_txop) begin
                if (!coder_bytes && pin_act != 3'd7) osr <= osr_shifted;  // bit mode shifts
              end else case (pin_act)
                3'd0: begin pout[pin_idx] <= 1'b0;                 poe[pin_idx] <= 1'b1;     end
                3'd1: begin pout[pin_idx] <= 1'b1;                 poe[pin_idx] <= 1'b1;     end
                3'd2: begin                                            poe[pin_idx] <= 1'b0;     end
                3'd3: begin pout[pin_idx] <= ~pout[pin_idx];   poe[pin_idx] <= 1'b1;     end
                3'd4: begin pout[pin_idx] <= out_bit;              poe[pin_idx] <= 1'b1;
                            osr <= osr_shifted;                                                      end
                3'd5: begin pout[pin_idx] <= 1'b0;                 poe[pin_idx] <= !out_bit;
                            osr <= osr_shifted;                                                      end
                3'd6: begin pout[pin_idx] <= par_bit;              poe[pin_idx] <= 1'b1;     end
                default: ;
              endcase
            end
            OP_IN: begin
              if (!coder_on) isr <= isr_shifted;
              else if (l_rxv) isr <= coder_bytes ? l_rxd
                                                 : (in_msb_first ? {isr[6:0], l_rxd[0]} : {l_rxd[0], isr[7:1]});
              par_in <= par_in ^ in_bit;
            end
            OP_JMP: begin
              if (jmp_cnd == 3'd1 && x != 8'd0) x <= x - 1'b1;
            end
            OP_SET: begin
              if (arg_hi) begin
                osr     <= arg[7:0];
                par_out <= 1'b0;
              end else x <= arg[7:0];
            end
            OP_FLAG: if (is_mov)
              case (arg[5:4])
                2'd1: x <= mov_val;
                2'd2: begin
                  osr     <= mov_val;
                  par_out <= 1'b0;
                end
                default: isr <= mov_val;
              endcase
            OP_FIFO: begin
              if (arg_hi) isr <= '0;
              else begin
                osr     <= tx_data;
                par_out <= 1'b0;
              end
            end
            OP_EXT: begin
              case (ext_op)
                E_OSRCRC: begin
                  osr     <= (arg[0] ? crc_value[15:8] : crc_value[7:0]) ^ {8{arg[1]}};
                  par_out <= 1'b0;
                end
                E_CRCRST:  if (!l_err) line_err <= 1'b0;  // an error in this very clock stays
                E_STAT: begin
                  isr      <= {3'b0, line_err, rx_ovf, tmo_seen, crc_ok, par_err};
                  par_in   <= 1'b0;
                  tmo_seen <= 1'b0;
                end
                default: ;  // the jumps are above
              endcase
            end
            default: ;
          endcase
          if (is_out) par_out <= par_out ^ out_bit;
        end

        // timeout: abandon the blocked instruction and jump to the timeout routine
        if (tmo_hit) begin
          iv       <= 1'b0;
          blocked  <= 1'b0;
          dly_cnt  <= '0;
          tmo_seen <= 1'b1;
        end
      end

      if (pm_wr) iv <= 1'b0;  // see pc_next
    end
  end
endmodule
