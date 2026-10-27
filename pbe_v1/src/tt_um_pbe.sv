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
//   0x04 FLAGS    RW shared flags [3:0]
//   0x05 PINS     R  synchronized pin levels
//   0x06 PM_ADDR  RW program memory byte pointer [6:0]: word = [6:1], [0] = 0 high byte, 1 low byte
//   0x07 PM_DATA  W  write the byte at PM_ADDR, then PM_ADDR += 1 (program memory is write only)
//   0x10+0x10*e   engine e (e = 0, 1):
//      +0 CLKDIV_L, +1 CLKDIV_H   tick every (CLKDIV + 1) clocks
//      +2 PIN_BASE[2:0]  +3 JMP_PIN[2:0]  +4 SHIFT [0] OUT msb first, [1] IN msb first
//      +5 START_PC[5:0]
//      +6 FIFO data: W pushes the TX FIFO, R pops the RX FIFO
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
  logic [3:0]  flags;
  logic [31:0] clkdiv;
  logic [5:0]  pin_base, jmp_pin;
  logic [3:0]  shiftcfg;
  logic [11:0] start_pc;
  logic [6:0]  pm_ptr;

  wire [1:0] restart = (wr_en && wr_addr == 7'h00) ? wr_data[5:4] : 2'b00;
  wire [1:0] flush   = (wr_en && wr_addr == 7'h00) ? wr_data[7:6] : 2'b00;

  // engine-facing signals
  logic [11:0] pc;
  logic [31:0] instr;
  logic [15:0] e_out, e_oe, tx_data, rx_din, rx_dout;
  logic [1:0]  tx_empty, tx_full, tx_pop, rx_empty, rx_full, rx_push, e_irq;
  logic [7:0]  f_set, f_clr;

  wire       wr_e0 = wr_en && wr_addr[6:4] == 3'd1;
  wire       wr_e1 = wr_en && wr_addr[6:4] == 3'd2;
  wire [3:0] wr_reg = wr_addr[3:0];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      run      <= '0;
      irq_pend <= '0;
      pin_own  <= '0;
      flags    <= '0;
      clkdiv   <= '0;
      pin_base <= '0;
      jmp_pin  <= '0;
      shiftcfg <= '0;
      start_pc <= '0;
      pm_ptr   <= '0;
    end else begin
      // engine events first, so a host write in the same cycle wins
      flags    <= (flags | f_set[3:0] | f_set[7:4]) & ~(f_clr[3:0] | f_clr[7:4]);
      irq_pend <= irq_pend | e_irq;

      if (wr_en) begin
        case (wr_addr)
          7'h00: run <= wr_data[1:0];
          7'h02: irq_pend <= (irq_pend | e_irq) & ~wr_data[1:0];
          7'h03: pin_own <= wr_data;
          7'h04: flags <= wr_data[3:0];
          7'h06: pm_ptr <= wr_data[6:0];
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
          4'h5: start_pc[5:0]  <= wr_data[5:0];
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
          4'h5: start_pc[11:6] <= wr_data[5:0];
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
      4'h5:    eng_rd = {2'b0, rd_e1 ? start_pc[11:6] : start_pc[5:0]};
      4'h6:    eng_rd = rd_e1 ? rx_dout[15:8] : rx_dout[7:0];
      default: eng_rd = 8'h00;
    endcase
  end

  always_comb begin
    case (addr)
      7'h00:   rd_data = {6'b0, run};
      7'h01:   rd_data = {tx_full[1], tx_empty[1], rx_full[1], rx_empty[1],
                          tx_full[0], tx_empty[0], rx_full[0], rx_empty[0]};
      7'h02:   rd_data = {6'b0, irq_pend};
      7'h03:   rd_data = pin_own;
      7'h04:   rd_data = {4'b0, flags};
      7'h05:   rd_data = pins_s2;
      7'h06:   rd_data = {1'b0, pm_ptr};
      default: rd_data = rd_eng ? eng_rd : 8'h00;
    endcase
  end

  // ---- program memory: 64 x 16, written by the host, read by both engines ----
  logic [15:0] pmem[64];
  always_ff @(posedge clk) begin
    if (wr_en && wr_addr == 7'h07) begin
      if (pm_ptr[0]) pmem[pm_ptr[6:1]][7:0] <= wr_data;
      else pmem[pm_ptr[6:1]][15:8] <= wr_data;
    end
  end
  assign instr[15:0]  = pmem[pc[5:0]];
  assign instr[31:16] = pmem[pc[11:6]];

  // ---- engines and their FIFOs ----
  for (genvar e = 0; e < 2; e++) begin : g_eng
    localparam logic [6:0] FIFO_ADDR = (e == 0) ? 7'h16 : 7'h26;

    pbe_fifo u_txf (
        .clk, .rst_n,
        .flush(flush[e]),
        .push (wr_en && wr_addr == FIFO_ADDR),
        .din  (wr_data),
        .pop  (tx_pop[e]),
        .dout (tx_data[e*8+:8]),
        .empty(tx_empty[e]),
        .full (tx_full[e])
    );

    pbe_fifo u_rxf (
        .clk, .rst_n,
        .flush(flush[e]),
        .push (rx_push[e]),
        .din  (rx_din[e*8+:8]),
        .pop  (rd_done && rd_addr == FIFO_ADDR),
        .dout (rx_dout[e*8+:8]),
        .empty(rx_empty[e]),
        .full (rx_full[e])
    );

    pbe_engine u_eng (
        .clk, .rst_n,
        .run          (run[e]),
        .restart      (restart[e]),
        .clkdiv       (clkdiv[e*16+:16]),
        .pin_base     (pin_base[e*3+:3]),
        .jmp_pin      (jmp_pin[e*3+:3]),
        .out_msb_first(shiftcfg[e*2]),
        .in_msb_first (shiftcfg[e*2+1]),
        .start_pc     (start_pc[e*6+:6]),
        .pc           (pc[e*6+:6]),
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
        .flags        (flags),
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
