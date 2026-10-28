// Programmable Bit Engine: top level for Tiny Tapeout.
//
// Pins
//   ui_in[0]  host SCK        uo_out[0]  host MISO
//   ui_in[1]  host CS_n       uo_out[1]  IRQ (engine 0 or 1 raised an interrupt)
//   ui_in[2]  host MOSI       uo_out[2]  engine 0 running    uo_out[3] engine 1 running
//                             uo_out[4]  E0 RX FIFO has data uo_out[5] E1 RX FIFO has data
//                             uo_out[6]  E0 TX FIFO full     uo_out[7] E1 TX FIFO full
//   uio[7:0]  protocol pins, driven by the engines
//
// Register map (7-bit address, see pbe_host_spi for the SPI framing)
//   0x00 CTRL     W  [0] run E0, [1] run E1, [4] restart E0, [5] restart E1,
//                    [6] flush E0 FIFOs, [7] flush E1 FIFOs   (bits 4..7 are self-clearing)
//                 R  [0] run E0, [1] run E1
//   0x01 STATUS   R  [0] E0 RX empty, [1] E0 RX full, [2] E0 TX empty, [3] E0 TX full, [7:4] same for E1
//   0x02 IRQ      R  [0] E0, [1] E1 pending;  W  write 1 to clear
//   0x03 PIN_OWN  RW bit i = 1 gives pin i to E1, 0 to E0
//   0x04 FLAGS    RW 8 flags. Engine e's FLAG n (n = 0..3 in instructions) is flag (FLAG_BASE[e] + n) mod 8,
//                    so by default engine 0 has flags 0-3 and engine 1 has flags 4-7; overlapping
//                    bases let the engines signal each other
//   0x08 FLAG_SET W  write 1s to set flags
//   0x09 FLAG_CLR W  write 1s to clear flags (use these two so the other engine's flags are untouched)
//   0x05 PINS     R  synchronized pin levels
//   0x0A, 0x0B RX_COUNT R  bytes in E0's, E1's RX FIFO; 0x0C, 0x0D TX_COUNT R  bytes in their TX FIFOs.
//                    A burst read of an RX FIFO must not read more than RX_COUNT bytes: a byte that
//                    arrives during the burst is not in it (the host would get a stale value)
//   0x0E TX_FLUSH W  [0] empties E0's TX FIFO, [1] E1's, leaving the RX FIFOs alone (to drop a
//                    queued reply while received data keeps arriving)
//   0x06 PM_ADDR  RW program memory byte pointer [7:0]: word = [7:1], [0] = 0 high byte, 1 low byte
//                    (128 words; each engine runs the program that starts at its START_PC)
//   0x07 PM_DATA  W  write the byte at PM_ADDR, then PM_ADDR += 1 (program memory is write only)
//   0x10+0x10*e   engine e (e = 0, 1):
//      +0 CLKDIV_L, +1 CLKDIV_H   tick every (CLKDIV + 1) clocks
//      +2 PIN_BASE[2:0]  +3 JMP_PIN[2:0]  +4 SHIFT [0] OUT msb first, [1] IN msb first
//      +5 START_PC[6:0]   the program's first word; its jumps are relative to it (64-word window)
//      +8 FLAG_BASE[2:0]  first physical flag this engine sees (reset: 0 for E0, 4 for E1)
//      +9 CRC_POLY_L, +A CRC_POLY_H   W: CRC polynomial (top term implied); R: the CRC's current value
//      +B CRC_CFG    [3:0] width - 1, [4] init all ones, [5] reversed output, [6] feed OUT bits,
//                    [7] feed IN bits (both 0: CRC off)
//      +C TIMEOUT_L, +D TIMEOUT_H     ticks a blocked WAIT/PULL/PUSH may wait (0 = forever)
//      +E LINE_CFG   [5:0] TIMEOUT_PC (where a timeout jumps), [6] no parity, [7] odd parity
//      +F STATUS     R: [0] receive parity error, [1] CRC ok (at CRC_GOOD), [2] timeout happened,
//                       [3] RX overflow (a PUSH found the RX FIFO full; also raises IRQ),
//                       [4] line error (line coder: stuff error, receive overrun, send underrun)
//                    W: [0] = 1 restarts the CRC, [1] = 1 clears "timeout happened",
//                       [2] = 1 clears "RX overflow", [3] = 1 clears "line error"
//      +6 FIFO data: W pushes the TX FIFO, R pops the RX FIFO (each FIFO holds 16 bytes)
//   0x30+0x10*e   engine e, second page:
//      +0 LINE       line coder, see pbe_line: [1:0] mode (0 off, 1 NRZ, 2 NRZI), [3:2] stuffing
//                    (0 none, 1 after 6 ones, 2 after 5 ones, 3 after 5 equal), [4] pair, [5] bytes
//      +1 SYNC       frame start pattern (0 = none)
//      +2 CRC_GOOD_L, +3 CRC_GOOD_H   the CRC value that means "ok" (0 unless the CRC is sent inverted)
module tt_um_pbe (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);
  // ---- input synchronizers ----
  logic [2:0] host_s1, host_s2;
  logic [7:0] pins_s1, pins_s2;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      host_s1 <= 3'b010;  // CS_n idles high
      host_s2 <= 3'b010;
      pins_s1 <= '0;
      pins_s2 <= '0;
    end else begin
      host_s1 <= ui_in[2:0];
      host_s2 <= host_s1;
      pins_s1 <= uio_in;
      pins_s2 <= pins_s1;
    end
  end

  // ---- host register port ----
  logic [6:0] addr, wr_addr, rd_addr;
  logic [7:0] rd_data, wr_data;
  logic       wr_en, rd_done, miso;

  pbe_host_spi u_host (
      .clk, .rst_n,
      .sck (host_s2[0]),
      .cs_n(host_s2[1]),
      .mosi(host_s2[2]),
      .miso,
      .addr, .rd_data, .wr_en, .wr_addr, .wr_data, .rd_done, .rd_addr
  );

  // ---- control and configuration registers ----
  // Per-engine values are packed into flat buses: engine e uses slice [e*W +: W].
  logic [1:0]  run, irq_pend;
  logic [7:0]  pin_own;
  logic [7:0]  flags;
  logic [5:0]  flag_base;  // 3 bits per engine
  logic [31:0] crc_poly, timeout;
  logic [15:0] crc_cfg, line_cfg;
  logic [9:0]  e_status;   // 5 bits per engine
  logic [15:0] coder_cfg, sync;
  logic [31:0] crc_good;
  logic [31:0] e_crc;      // each engine's current CRC value
  logic [31:0] clkdiv;
  logic [5:0]  pin_base, jmp_pin;
  logic [3:0]  shiftcfg;
  logic [13:0] start_pc;  // 7 bits per engine
  logic [7:0]  pm_ptr;

  wire [1:0] restart = (wr_en && wr_addr == 7'h00) ? wr_data[5:4] : 2'b00;
  wire [1:0] flush   = (wr_en && wr_addr == 7'h00) ? wr_data[7:6] : 2'b00;
  wire [1:0] tx_flush = flush | ((wr_en && wr_addr == 7'h0E) ? wr_data[1:0] : 2'b00);

  // engine-facing signals
  logic [13:0] pc;  // 7 bits per engine
  logic [31:0] instr;
  logic [15:0] e_out, e_oe, tx_data, rx_din, rx_dout;
  logic [1:0]  tx_empty, tx_full, tx_pop, rx_empty, rx_full, rx_push, e_irq;
  logic [9:0]  tx_count, rx_count;  // 5 bits per engine
  logic [7:0]  f_set, f_clr;  // engine-relative, 4 bits per engine
  logic [15:0] p_set, p_clr;  // the same, mapped to physical flags, 8 bits per engine
  logic [7:0]  e_flags;       // each engine's view of its 4 flags

  wire [7:0] host_set = (wr_en && wr_addr == 7'h08) ? wr_data : 8'h00;
  wire [7:0] host_clr = (wr_en && wr_addr == 7'h09) ? wr_data : 8'h00;

  wire       wr_e0 = wr_en && wr_addr[6:4] == 3'd1;
  wire       wr_e1 = wr_en && wr_addr[6:4] == 3'd2;
  wire       wr_p0 = wr_en && wr_addr[6:4] == 3'd3;  // second pages
  wire       wr_p1 = wr_en && wr_addr[6:4] == 3'd4;
  wire [3:0] wr_reg = wr_addr[3:0];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      run      <= '0;
      irq_pend <= '0;
      pin_own  <= '0;
      flags    <= '0;
      flag_base <= 6'b100_000;  // E1 starts at flag 4, E0 at flag 0
      crc_poly <= '0;
      crc_cfg  <= '0;
      timeout  <= '0;
      line_cfg <= '0;
      clkdiv   <= '0;
      pin_base <= '0;
      jmp_pin  <= '0;
      shiftcfg <= '0;
      start_pc <= '0;
      pm_ptr   <= '0;
      coder_cfg <= '0;
      sync     <= '0;
      crc_good <= '0;
    end else begin
      // engine events first, so a host write in the same cycle wins
      flags    <= (flags | p_set[7:0] | p_set[15:8] | host_set) & ~(p_clr[7:0] | p_clr[15:8] | host_clr);
      irq_pend <= irq_pend | e_irq;

      if (wr_en) begin
        case (wr_addr)
          7'h00: run <= wr_data[1:0];
          7'h02: irq_pend <= (irq_pend | e_irq) & ~wr_data[1:0];
          7'h03: pin_own <= wr_data;
          7'h04: flags <= wr_data;
          7'h06: pm_ptr <= wr_data;
          7'h07: pm_ptr <= pm_ptr + 1'b1;
          default: ;
        endcase
      end
      if (wr_e0) begin
        case (wr_reg)
          4'h0: clkdiv[7:0]   <= wr_data;
          4'h1: clkdiv[15:8]  <= wr_data;
          4'h2: pin_base[2:0] <= wr_data[2:0];
          4'h3: jmp_pin[2:0]  <= wr_data[2:0];
          4'h4: shiftcfg[1:0] <= wr_data[1:0];
          4'h5: start_pc[6:0]  <= wr_data[6:0];
          4'h8: flag_base[2:0] <= wr_data[2:0];
          4'h9: crc_poly[7:0]   <= wr_data;
          4'hA: crc_poly[15:8]  <= wr_data;
          4'hB: crc_cfg[7:0]    <= wr_data;
          4'hC: timeout[7:0]    <= wr_data;
          4'hD: timeout[15:8]   <= wr_data;
          4'hE: line_cfg[7:0]   <= wr_data;
          default: ;
        endcase
      end
      if (wr_e1) begin
        case (wr_reg)
          4'h0: clkdiv[23:16] <= wr_data;
          4'h1: clkdiv[31:24] <= wr_data;
          4'h2: pin_base[5:3] <= wr_data[2:0];
          4'h3: jmp_pin[5:3]  <= wr_data[2:0];
          4'h4: shiftcfg[3:2] <= wr_data[1:0];
          4'h5: start_pc[13:7] <= wr_data[6:0];
          4'h8: flag_base[5:3] <= wr_data[2:0];
          4'h9: crc_poly[23:16] <= wr_data;
          4'hA: crc_poly[31:24] <= wr_data;
          4'hB: crc_cfg[15:8]   <= wr_data;
          4'hC: timeout[23:16]  <= wr_data;
          4'hD: timeout[31:24]  <= wr_data;
          4'hE: line_cfg[15:8]  <= wr_data;
          default: ;
        endcase
      end
      if (wr_p0 || wr_p1) begin
        case (wr_reg)
          4'h0: if (wr_p1) coder_cfg[15:8] <= wr_data; else coder_cfg[7:0] <= wr_data;
          4'h1: if (wr_p1) sync[15:8] <= wr_data; else sync[7:0] <= wr_data;
          4'h2: if (wr_p1) crc_good[23:16] <= wr_data; else crc_good[7:0] <= wr_data;
          4'h3: if (wr_p1) crc_good[31:24] <= wr_data; else crc_good[15:8] <= wr_data;
          default: ;
        endcase
      end
    end
  end

  // ---- register read mux ----
  wire       rd_eng = addr[6:4] == 3'd1 || addr[6:4] == 3'd2;
  wire       rd_e1  = addr[5];  // 0x2x
  wire [3:0] rd_reg = addr[3:0];

  logic [7:0] eng_rd;
  always_comb begin
    case (rd_reg)
      4'h0:    eng_rd = rd_e1 ? clkdiv[23:16] : clkdiv[7:0];
      4'h1:    eng_rd = rd_e1 ? clkdiv[31:24] : clkdiv[15:8];
      4'h2:    eng_rd = {5'b0, rd_e1 ? pin_base[5:3] : pin_base[2:0]};
      4'h3:    eng_rd = {5'b0, rd_e1 ? jmp_pin[5:3] : jmp_pin[2:0]};
      4'h4:    eng_rd = {6'b0, rd_e1 ? shiftcfg[3:2] : shiftcfg[1:0]};
      4'h5:    eng_rd = {1'b0, rd_e1 ? start_pc[13:7] : start_pc[6:0]};
      4'h8:    eng_rd = {5'b0, rd_e1 ? flag_base[5:3] : flag_base[2:0]};
      4'h9:    eng_rd = rd_e1 ? e_crc[23:16] : e_crc[7:0];   // reads give the CRC value
      4'hA:    eng_rd = rd_e1 ? e_crc[31:24] : e_crc[15:8];
      4'hB:    eng_rd = rd_e1 ? crc_cfg[15:8] : crc_cfg[7:0];
      4'hC:    eng_rd = rd_e1 ? timeout[23:16] : timeout[7:0];
      4'hD:    eng_rd = rd_e1 ? timeout[31:24] : timeout[15:8];
      4'hE:    eng_rd = rd_e1 ? line_cfg[15:8] : line_cfg[7:0];
      4'hF:    eng_rd = {3'b0, rd_e1 ? e_status[9:5] : e_status[4:0]};
      4'h6:    eng_rd = rd_e1 ? rx_dout[15:8] : rx_dout[7:0];
      default: eng_rd = 8'h00;
    endcase
  end

  wire       rd_pg  = addr[6:4] == 3'd3 || addr[6:4] == 3'd4;
  wire       rd_p1  = addr[6:4] == 3'd4;
  logic [7:0] pg_rd;
  always_comb begin
    case (rd_reg)
      4'h0:    pg_rd = rd_p1 ? coder_cfg[15:8] : coder_cfg[7:0];
      4'h1:    pg_rd = rd_p1 ? sync[15:8] : sync[7:0];
      4'h2:    pg_rd = rd_p1 ? crc_good[23:16] : crc_good[7:0];
      4'h3:    pg_rd = rd_p1 ? crc_good[31:24] : crc_good[15:8];
      default: pg_rd = 8'h00;
    endcase
  end

  always_comb begin
    case (addr)
      7'h00:   rd_data = {6'b0, run};
      7'h01:   rd_data = {tx_full[1], tx_empty[1], rx_full[1], rx_empty[1],
                          tx_full[0], tx_empty[0], rx_full[0], rx_empty[0]};
      7'h02:   rd_data = {6'b0, irq_pend};
      7'h03:   rd_data = pin_own;
      7'h04:   rd_data = flags;
      7'h05:   rd_data = pins_s2;
      7'h06:   rd_data = pm_ptr;
      7'h0A:   rd_data = {3'b0, rx_count[4:0]};
      7'h0B:   rd_data = {3'b0, rx_count[9:5]};
      7'h0C:   rd_data = {3'b0, tx_count[4:0]};
      7'h0D:   rd_data = {3'b0, tx_count[9:5]};
      default: rd_data = rd_eng ? eng_rd : rd_pg ? pg_rd : 8'h00;
    endcase
  end

  // ---- program memory: 64 x 16, written by the host, read by both engines ----
  logic [15:0] pmem[128];
  always_ff @(posedge clk) begin
    if (wr_en && wr_addr == 7'h07) begin
      if (pm_ptr[0]) pmem[pm_ptr[7:1]][7:0] <= wr_data;
      else pmem[pm_ptr[7:1]][15:8] <= wr_data;
    end
  end
  assign instr[15:0]  = pmem[pc[6:0]];
  assign instr[31:16] = pmem[pc[13:7]];

  // ---- engines and their FIFOs ----
  for (genvar e = 0; e < 2; e++) begin : g_eng
    localparam logic [6:0] FIFO_ADDR = (e == 0) ? 7'h16 : 7'h26;

    pbe_fifo #(.ADDR_BITS(4)) u_txf (
        .clk, .rst_n,
        .flush(tx_flush[e]),
        .push (wr_en && wr_addr == FIFO_ADDR),
        .din  (wr_data),
        .pop  (tx_pop[e]),
        .dout (tx_data[e*8+:8]),
        .empty(tx_empty[e]),
        .full (tx_full[e]),
        .count(tx_count[e*5+:5])
    );

    pbe_fifo #(.ADDR_BITS(4)) u_rxf (
        .clk, .rst_n,
        .flush(flush[e]),
        .push (rx_push[e]),
        .din  (rx_din[e*8+:8]),
        .pop  (rd_done && rd_addr == FIFO_ADDR),
        .dout (rx_dout[e*8+:8]),
        .empty(rx_empty[e]),
        .full (rx_full[e]),
        .count(rx_count[e*5+:5])
    );

    // Engine-relative flags: FLAG n is physical flag (base + n) mod 8.
    wire [2:0]  fbase = flag_base[e*3+:3];
    wire [15:0] fl2   = {flags, flags};
    wire [15:0] set2  = {12'b0, f_set[e*4+:4]} << fbase;
    wire [15:0] clr2  = {12'b0, f_clr[e*4+:4]} << fbase;
    assign e_flags[e*4+:4] = fl2[fbase+:4];
    assign p_set[e*8+:8]   = set2[7:0] | set2[15:8];
    assign p_clr[e*8+:8]   = clr2[7:0] | clr2[15:8];

    pbe_engine u_eng (
        .clk, .rst_n,
        .run          (run[e]),
        .restart      (restart[e]),
        .clkdiv       (clkdiv[e*16+:16]),
        .pin_base     (pin_base[e*3+:3]),
        .jmp_pin      (jmp_pin[e*3+:3]),
        .out_msb_first(shiftcfg[e*2]),
        .in_msb_first (shiftcfg[e*2+1]),
        .start_pc     (start_pc[e*7+:7]),
        .crc_poly     (crc_poly[e*16+:16]),
        .crc_cfg      (crc_cfg[e*8+:8]),
        .timeout      (timeout[e*16+:16]),
        .line_cfg     (line_cfg[e*8+:8]),
        .coder_cfg    (coder_cfg[e*8+:8]),
        .sync         (sync[e*8+:8]),
        .crc_good     (crc_good[e*16+:16]),
        .host_crc_init(wr_en && wr_addr == FIFO_ADDR + 7'd9 && wr_data[0]),
        .host_tmo_clr (wr_en && wr_addr == FIFO_ADDR + 7'd9 && wr_data[1]),
        .host_ovf_clr (wr_en && wr_addr == FIFO_ADDR + 7'd9 && wr_data[2]),
        .host_lerr_clr(wr_en && wr_addr == FIFO_ADDR + 7'd9 && wr_data[3]),
        .status       (e_status[e*5+:5]),
        .crc_now      (e_crc[e*16+:16]),
        .pc           (pc[e*7+:7]),
        .instr        (instr[e*16+:16]),
        .pins_in      (pins_s2),
        .pins_out     (e_out[e*8+:8]),
        .pins_oe      (e_oe[e*8+:8]),
        .tx_data      (tx_data[e*8+:8]),
        .tx_empty     (tx_empty[e]),
        .tx_pop       (tx_pop[e]),
        .rx_data      (rx_din[e*8+:8]),
        .rx_full      (rx_full[e]),
        .rx_push      (rx_push[e]),
        .flags        (e_flags[e*4+:4]),
        .flag_set     (f_set[e*4+:4]),
        .flag_clr     (f_clr[e*4+:4]),
        .irq          (e_irq[e])
    );
  end

  // ---- pin mux: each pin is driven by exactly one engine ----
  assign uio_out = (e_out[15:8] & pin_own) | (e_out[7:0] & ~pin_own);
  assign uio_oe  = (e_oe[15:8] & pin_own)  | (e_oe[7:0] & ~pin_own);

  assign uo_out = {tx_full[1], tx_full[0], ~rx_empty[1], ~rx_empty[0], run[1], run[0], |irq_pend, miso};

  wire _unused = &{ena, ui_in[7:3], 1'b0};
endmodule
