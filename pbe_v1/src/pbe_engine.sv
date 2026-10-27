// One Programmable Bit Engine.
//
// Instruction word (16 bits):  [15:13] OP | [12:4] ARG | [3:0] DLY
// Each instruction issues on a tick and then idles DLY more ticks before the next one.
// A tick is one clock every (clkdiv + 1) clocks.
//
//  OP   name        ARG
//  000  PIN p, act  [8:6] pin, [5:3] act: 0 DRV0, 1 DRV1, 2 REL, 3 TOG, 4 OUT, 5 OUTOD
//  001  IN p        [8:6] pin                 shift pin into ISR
//  010  WAIT        [8:6] pin (or flag in [7:6]), [5] 1 = flag, [4:3] 0 LOW, 1 HIGH, 2 RISE, 3 FALL
//  011  JMP         [8:6] cond, [5:0] addr    cond: 0 ALWAYS, 1 X-- != 0, 2 PIN_HI, 3 PIN_LO,
//                                             4 TX_EMPTY, 5 TX_READY, 6 FLAG0, 7 FLAG1
//  100  SET         [8] 0 = X, 1 = OSR; [7:0] value
//  101  PULL/PUSH   [8] 0 = PULL (TX FIFO -> OSR), 1 = PUSH (ISR -> RX FIFO, then clear ISR)
//  110  FLAG        [8:7] 0 SET, 1 CLR, 2 IRQ, 3 none (the assembler's NOP); [1:0] flag
//  111  reserved    executes as NOP
//
// WAIT, PULL and PUSH block until they can complete. While blocked the engine checks
// every clock (not every tick), and when it unblocks the tick divider restarts, so
// following instructions are timed from the moment the condition was met.
//
// Pin numbers are relative to pin_base (mod 8); the JMP pin is jmp_pin + pin_base.
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
    input  logic [5:0]  start_pc,
    // program memory
    output logic [5:0]  pc,
    input  logic [15:0] instr,
    // pins
    input  logic [7:0]  pins_in,  // synchronized
    output logic [7:0]  pins_out,
    output logic [7:0]  pins_oe,
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
                         OP_SET = 3'd4, OP_FIFO = 3'd5, OP_FLAG = 3'd6;

  logic [15:0] div_cnt;
  logic [3:0]  dly_cnt;
  logic        blocked;
  logic [7:0]  x, osr, isr;
  logic [7:0]  pins_prev;
  logic [3:0]  flags_prev;

  // ---- decode ----
  wire [2:0] op  = instr[15:13];
  wire [8:0] arg = instr[12:4];
  wire [3:0] dly = instr[3:0];

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

  // ---- issue and readiness ----
  wire tick  = (div_cnt >= clkdiv);
  wire issue = run && (blocked || (tick && dly_cnt == 4'd0));

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
      default: ready = 1'b1;
    endcase
  end

  // A restart in the same cycle cancels the instruction, so it has no side effects.
  wire exec = issue && ready && !restart;

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

  // ---- side-effect pulses (combinational, valid in the exec cycle) ----
  assign tx_pop   = exec && op == OP_FIFO && !arg_hi;
  assign rx_push  = exec && op == OP_FIFO && arg_hi;
  assign rx_data  = isr;
  assign flag_set = (exec && op == OP_FLAG && flag_act == 2'd0) ? (4'b0001 << arg[1:0]) : 4'b0000;
  assign flag_clr = (exec && op == OP_FLAG && flag_act == 2'd1) ? (4'b0001 << arg[1:0]) : 4'b0000;
  assign irq      = exec && op == OP_FLAG && flag_act == 2'd2;

  // ---- state ----
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pc         <= '0;
      div_cnt    <= '0;
      dly_cnt    <= '0;
      blocked    <= 1'b0;
      x          <= '0;
      osr        <= '0;
      isr        <= '0;
      pins_out   <= '0;
      pins_oe    <= '0;
      pins_prev  <= '0;
      flags_prev <= '0;
    end else if (restart) begin
      pc       <= start_pc;
      div_cnt  <= '0;
      dly_cnt  <= '0;
      blocked  <= 1'b0;
      x        <= '0;
      osr      <= '0;
      isr      <= '0;
      pins_out <= '0;
      pins_oe  <= '0;
    end else begin
      pins_prev  <= pins_in;
      flags_prev <= flags;

      if (run) begin
        // tick divider; restarts when a blocked instruction completes
        if (exec && blocked) div_cnt <= '0;
        else if (tick) div_cnt <= '0;
        else div_cnt <= div_cnt + 1'b1;

        if (tick && dly_cnt != 4'd0 && !blocked) dly_cnt <= dly_cnt - 1'b1;

        if (issue && !ready) blocked <= 1'b1;

        if (exec) begin
          blocked <= 1'b0;
          dly_cnt <= dly;
          pc      <= pc + 1'b1;

          case (op)
            OP_PIN: begin
              case (pin_act)
                3'd0: begin pins_out[pin_idx] <= 1'b0;                 pins_oe[pin_idx] <= 1'b1;     end
                3'd1: begin pins_out[pin_idx] <= 1'b1;                 pins_oe[pin_idx] <= 1'b1;     end
                3'd2: begin                                            pins_oe[pin_idx] <= 1'b0;     end
                3'd3: begin pins_out[pin_idx] <= ~pins_out[pin_idx];   pins_oe[pin_idx] <= 1'b1;     end
                3'd4: begin pins_out[pin_idx] <= out_bit;              pins_oe[pin_idx] <= 1'b1;
                            osr <= osr_shifted;                                                      end
                3'd5: begin pins_out[pin_idx] <= 1'b0;                 pins_oe[pin_idx] <= !out_bit;
                            osr <= osr_shifted;                                                      end
                default: ;
              endcase
            end
            OP_IN: isr <= isr_shifted;
            OP_JMP: begin
              if (jmp_take) pc <= arg[5:0];
              if (jmp_cnd == 3'd1 && x != 8'd0) x <= x - 1'b1;
            end
            OP_SET: begin
              if (arg_hi) osr <= arg[7:0];
              else x <= arg[7:0];
            end
            OP_FIFO: begin
              if (arg_hi) isr <= '0;
              else osr <= tx_data;
            end
            default: ;
          endcase
        end
      end
    end
  end
endmodule
