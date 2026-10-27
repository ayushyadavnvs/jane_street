`timescale 1ns / 1ps
// End-to-end test of tt_um_pbe through its real pins only.
//
//  Test 1  UART: engine 0 runs uart_tx on pin 0, engine 1 runs uart_rx on pin 1,
//          pin 0 is looped back to pin 1. An independent UART monitor also decodes pin 0.
//  Test 2  SPI:  engine 0 runs spi_ctrl on pins 0..3 against a behavioural mode-0 peripheral.
//  Test 3  I2C on engine 1 while engine 0 sends UART.
//  Test 4  Low-speed USB: engine 0 sends packets on pins 0/1, checked by an independent decoder;
//          engine 1 receives packets on pins 2/3 from a host model running 1.5% fast and slow.
// The clock is 48 MHz so a USB bit is exactly 32 clocks.
//
// Every pin has a pull-up and lines are wired-AND, like a real open-drain bus.
module tb_pbe;
  localparam real CLK_NS = 20.8333;  // 48 MHz
  localparam int HOST_HALF = 8;  // host SCK half period in clocks (SCK = clk / 16)
  localparam int UART_BIT = 100;  // clocks per UART bit (500 kbaud at 50 MHz)

  logic clk = 0, rst_n = 0;
  always #(CLK_NS / 2) clk = ~clk;

  logic [7:0] ui_in = 8'b0000_0010;  // CS_n high
  wire  [7:0] uo_out, uio_out, uio_oe;
  logic [7:0] ext_drive = '0, ext_val = '0;
  logic       loop01 = 0;

  logic [7:0] pull_lo = '0;  // pins pulled low instead of high (USB D+)

  // Lines are wired-AND; an undriven line sits at its pull-up or pull-down.
  wire  [7:0] chip_lvl = ~uio_oe | uio_out;
  wire  [7:0] ext_lvl  = ~ext_drive | ext_val;
  wire  [7:0] loop_drv = loop01 ? {6'b0, uio_oe[0], 1'b0} : 8'h00;  // pin 0 also drives pin 1
  wire  [7:0] driven   = uio_oe | ext_drive | loop_drv;
  wire  [7:0] wired    = chip_lvl & ext_lvl & (loop01 ? {6'h3f, chip_lvl[0], 1'b1} : 8'hff);
  wire  [7:0] bus      = (driven & wired) | (~driven & ~pull_lo);

  tt_um_pbe dut (
      .ui_in, .uo_out, .uio_in(bus), .uio_out, .uio_oe, .ena(1'b1), .clk, .rst_n
  );

  int errors = 0;
  task automatic check(input bit ok, input string msg);
    if (!ok) begin
      errors++;
      $display("  FAIL: %s", msg);
    end
  endtask

  // ---------------- host SPI (mode 0) ----------------
  task automatic spi_byte(input logic [7:0] tx, output logic [7:0] rx);
    for (int i = 7; i >= 0; i--) begin
      ui_in[2] = tx[i];
      repeat (HOST_HALF) @(posedge clk);
      ui_in[0] = 1;  // rising: both sides sample
      rx[i] = uo_out[0];
      repeat (HOST_HALF) @(posedge clk);
      ui_in[0] = 0;
    end
  endtask

  task automatic cs(input bit level);
    repeat (HOST_HALF) @(posedge clk);
    ui_in[1] = level;
    repeat (HOST_HALF) @(posedge clk);
  endtask

  task automatic reg_write(input logic [6:0] addr, input logic [7:0] data);
    logic [7:0] d;
    cs(0);
    spi_byte({1'b1, addr}, d);
    spi_byte(data, d);
    cs(1);
  endtask

  task automatic reg_read(input logic [6:0] addr, output logic [7:0] data);
    logic [7:0] d;
    cs(0);
    spi_byte({1'b0, addr}, d);
    spi_byte(8'h00, data);
    cs(1);
  endtask

  task automatic load_program(input string file);
    logic [15:0] img[64];
    logic [7:0] d;
    $readmemh(file, img);
    reg_write(7'h06, 0);         // program memory pointer = word 0, high byte
    cs(0);
    spi_byte({1'b1, 7'h07}, d);  // burst into PM_DATA; the pointer advances per byte
    for (int w = 0; w < 64; w++) begin
      spi_byte(img[w][15:8], d);
      spi_byte(img[w][7:0], d);
    end
    cs(1);
  endtask

  task automatic fifo_send(input int e, input logic [7:0] data);
    logic [7:0] st;
    do reg_read(7'h01, st); while (st[e*4+3]);  // TX full
    reg_write(e ? 7'h26 : 7'h16, data);
  endtask

  task automatic fifo_recv(input int e, output logic [7:0] data);
    logic [7:0] st;
    int tries = 0;
    do begin
      reg_read(7'h01, st);
      tries++;
    end while (st[e*4+0] && tries < 400);  // RX empty
    check(!st[e*4+0], $sformatf("engine %0d RX FIFO stayed empty", e));
    reg_read(e ? 7'h26 : 7'h16, data);
  endtask

  // ---------------- independent UART monitor on pin 0 ----------------
  logic [7:0] uart_seen[$];
  bit uart_mon_en = 0;
  initial begin
    forever begin
      @(negedge bus[0]);
      if (uart_mon_en) begin
        logic [7:0] b;
        repeat (UART_BIT / 2) @(posedge clk);
        check(bus[0] == 0, "UART monitor: start bit not low at its middle");
        for (int i = 0; i < 8; i++) begin
          repeat (UART_BIT) @(posedge clk);
          b[i] = bus[0];
        end
        repeat (UART_BIT) @(posedge clk);
        check(bus[0] == 1, "UART monitor: stop bit not high");
        uart_seen.push_back(b);
      end
    end
  end

  // ---------------- behavioural SPI peripheral, mode 0, pins 0..3 ----------------
  logic [7:0] spi_reply[$], spi_got[$];
  bit spi_dev_en = 0;
  logic [7:0] dev_tx, dev_rx;
  int dev_bits;
  bit dev_loaded = 0;  // dev_tx holds the next reply byte
  function automatic logic [7:0] next_reply();
    return spi_reply.size() ? spi_reply.pop_front() : 8'hEE;
  endfunction
  always @(negedge bus[3]) if (spi_dev_en) begin
    if (!dev_loaded) dev_tx = next_reply();
    dev_loaded = 1;
    dev_bits = 0;
    ext_drive[2] = 1;
    ext_val[2] = dev_tx[7];
  end
  always @(posedge bus[3]) if (spi_dev_en) ext_drive[2] = 0;
  always @(posedge bus[0]) if (spi_dev_en && !bus[3]) begin
    dev_rx = {dev_rx[6:0], bus[1]};
    dev_bits++;
    if (dev_bits == 8) begin
      spi_got.push_back(dev_rx);
      dev_bits = 0;
      dev_loaded = 0;
    end
  end
  always @(negedge bus[0]) if (spi_dev_en && !bus[3]) begin
    if (dev_bits == 0) begin
      dev_tx = next_reply();
      dev_loaded = 1;
    end else dev_tx = {dev_tx[6:0], 1'b0};
    ext_val[2] = dev_tx[7];
  end


  // ---------------- behavioural I2C peripheral at 0x50, SDA = pin 4, SCL = pin 5 ----------------
  // Register device: write [reg] [data...] stores bytes; reads return bytes from the pointer.
  // It holds SCL low for I2C_STRETCH clocks after bit 4 and bit 8 of every byte (clock stretching).
  localparam int SDA = 4, SCL = 5, I2C_STRETCH = 120;
  localparam logic [6:0] I2C_ADDR = 7'h50;
  localparam int I_IDLE = 0, I_ADDR = 1, I_REG = 2, I_WDATA = 3, I_RDATA = 4;
  logic [7:0] i2c_mem[256];
  logic [7:0] i_ptr, i_sh;
  int i_st = I_IDLE, i_bit = 0, i_starts = 0, i_stops = 0, i_stretches = 0;
  bit i2c_en = 0, i_acking = 0;

  task automatic i_sda(input bit v);  // open drain: 0 pulls low, 1 releases
    ext_drive[SDA] = !v;
    ext_val[SDA] = 0;
  endtask

  always @(negedge bus[SDA]) if (i2c_en && bus[SCL]) begin  // START
    i_st = I_ADDR;
    i_bit = 0;
    i_starts++;
  end
  always @(posedge bus[SDA]) if (i2c_en && bus[SCL]) begin  // STOP
    i_st = I_IDLE;
    i_stops++;
  end
  always @(posedge bus[SCL]) if (i2c_en && i_st != I_IDLE) begin
    i_bit++;
    if (i_bit <= 8 && i_st != I_RDATA) i_sh = {i_sh[6:0], bus[SDA]};
    if (i_bit == 9 && i_st == I_RDATA && bus[SDA]) i_st = I_IDLE;  // controller NACKed: stop sending
  end
  always @(negedge bus[SCL]) if (i2c_en && i_st != I_IDLE) begin
    if (i_bit == 8) begin
      i_acking = 1;
      case (i_st)
        I_ADDR:  if (i_sh[7:1] == I2C_ADDR) i_st = i_sh[0] ? I_RDATA : I_REG;
                 else begin i_st = I_IDLE; i_acking = 0; end
        I_REG:   begin i_ptr = i_sh; i_st = I_WDATA; end
        I_WDATA: begin i2c_mem[i_ptr] = i_sh; i_ptr++; end
        default: i_acking = 0;  // sending: the controller drives the ACK slot
      endcase
      i_sda(!i_acking);
    end else if (i_bit == 9) begin
      i_bit = 0;
      if (i_st == I_RDATA) begin
        i_sh = i2c_mem[i_ptr];
        i_ptr++;
        i_sda(i_sh[7]);
      end else i_sda(1);
    end else if (i_st == I_RDATA && i_bit >= 1) begin
      i_sda(i_sh[7 - i_bit]);
    end
    // clock stretching mid-byte and before the ACK slot: keep SCL low a while
    if (i_bit == 4 || i_bit == 8) begin
      ext_drive[SCL] = 1;
      ext_val[SCL] = 0;
      i_stretches++;
      repeat (I2C_STRETCH) @(posedge clk);
      ext_drive[SCL] = 0;
    end
  end
  // a read starts right after the address ACK: first bit goes out when that ACK clock ends
  always @(negedge bus[SCL]) if (i2c_en && i_st == I_RDATA && i_bit == 0 && i_acking) begin
    i_acking = 0;
  end

  // host-side helpers for the i2c_ctrl program on engine 1
  task automatic wait_tx_empty(input int e);
    logic [7:0] st;
    do reg_read(7'h01, st); while (!st[e*4+2]);
  endtask
  // FLAG0 = START: happens when the next byte is queued.
  // FLAG1 = STOP: happens right away; wait until the engine clears the flag.
  task automatic i2c_cond(input logic [3:0] flag);
    logic [7:0] f;
    wait_tx_empty(1);
    reg_write(7'h04, flag);
    if (flag[1]) do reg_read(7'h04, f); while (f != 0);
  endtask
  task automatic i2c_xfer(input logic [7:0] data, input logic [7:0] ack_out,
                          output logic [7:0] seen, output logic [7:0] ack_in);
    fifo_send(1, data);
    fifo_send(1, ack_out);
    fifo_recv(1, seen);
    fifo_recv(1, ack_in);
  endtask


  // ---------------- low-speed USB models ----------------
  // USB CRC16 over u_pkt[1..] (the PID is not covered); u_crc gets the field, [7:0] sent first.
  logic [7:0]  u_pkt[$];
  logic [15:0] u_crc, u_c;
  logic [7:0]  u_byte;
  int          u_i, u_b;
  task usb_crc16;
    u_c = 16'hFFFF;
    for (u_i = 1; u_i < u_pkt.size(); u_i++) begin
      u_byte = u_pkt[u_i];
      for (u_b = 0; u_b < 8; u_b++) u_c = {u_c[14:0], 1'b0} ^ ((u_byte[u_b] ^ u_c[15]) ? 16'h8005 : 16'h0);
    end
    for (u_b = 0; u_b < 16; u_b++) u_crc[u_b] = ~u_c[15-u_b];
  endtask

  // Monitor: decodes every packet the chip sends on D+ = pin 0, D- = pin 1 while usb_mon_en
  // is set. Same clock as the chip, so a bit is 32 clocks; it re-centres on every D+ edge.
  logic [7:0] cap_q[$];
  int cap_stuffed, cap_se0, cap_count = 0;
  bit cap_j, usb_mon_en = 0;
  int m_phase, m_ones, m_nbits;
  bit m_last_dp, m_prev_k, m_in_sync, m_b;
  logic [7:0] m_sh;
  initial forever begin
    wait (usb_mon_en && bus[0] && !bus[1]);  // K: SYNC starts
    cap_q.delete();
    cap_stuffed = 0;
    m_phase = 0;
    m_ones = 0;
    m_nbits = 0;
    m_last_dp = 1;
    m_prev_k = 0;
    m_in_sync = 1;
    while (!(m_phase % 32 == 16 && !bus[0] && !bus[1])) begin  // until SE0 at mid-bit
      @(posedge clk);
      if (bus[0] != m_last_dp) begin
        m_last_dp = bus[0];
        m_phase = 0;
      end else m_phase++;
      if (m_phase % 32 == 16 && (bus[0] || bus[1])) begin
        m_b = (bus[0] == m_prev_k);
        m_prev_k = bus[0];
        if (m_in_sync) begin
          if (m_b) begin
            m_in_sync = 0;
            m_ones = 1;
          end
        end else if (m_ones == 6) begin
          check(!m_b, "USB TX: missing stuffed 0 after six 1s");
          cap_stuffed++;
          m_ones = 0;
        end else begin
          m_sh = {m_b, m_sh[7:1]};
          m_nbits++;
          m_ones = m_b ? m_ones + 1 : 0;
          if (m_nbits % 8 == 0) cap_q.push_back(m_sh);
        end
      end
    end
    cap_se0 = 16;  // SE0 seen at mid-bit; count to its end
    while (!bus[0] && !bus[1]) begin
      @(posedge clk);
      cap_se0++;
    end
    cap_j = !bus[0] && bus[1];
    cap_count++;
  end

  // Send u_pkt to the chip on D+ = pin 2, D- = pin 3, bit rate off by h_pct percent.
  real h_pct, h_bit;
  bit  h_k;
  int  h_ones, h_i, h_b;
  logic [7:0] h_cur;
  task usb_host_send;
    h_bit = (1.0e9 / 1.5e6) / (1.0 + h_pct / 100.0);  // ns
    h_k = 0;
    h_ones = 0;
    ext_drive[3:2] = 2'b11;
    for (h_i = -1; h_i < u_pkt.size(); h_i++) begin
      h_cur = (h_i < 0) ? 8'h80 : u_pkt[h_i];  // SYNC first
      for (h_b = 0; h_b < 8; h_b++) begin
        if (!h_cur[h_b]) h_k = !h_k;
        ext_val[2] = h_k;
        ext_val[3] = !h_k;
        #(h_bit);
        h_ones = h_cur[h_b] ? h_ones + 1 : 0;
        if (h_ones == 6) begin  // stuffed 0
          h_k = !h_k;
          ext_val[2] = h_k;
          ext_val[3] = !h_k;
          #(h_bit);
          h_ones = 0;
        end
      end
    end
    ext_val[3:2] = 2'b00;  // SE0, SE0
    #(2 * h_bit);
    ext_val[3:2] = 2'b10;  // J
    #(h_bit);
    ext_drive[3:2] = 2'b00;
    #(2 * h_bit);
  endtask

  // Engine 0 sends u_pkt (plus a CRC16 if t_crc); the monitor must decode exactly that.
  logic [7:0] t_exp[$], t_got, t_f;
  bit   t_crc;
  int   t_prev, t_i;
  string t_what;
  task usb_tx_check;
    t_exp = u_pkt;
    if (t_crc) begin
      usb_crc16;
      t_got = u_crc[7:0];
      t_exp.push_back(t_got);
      t_got = u_crc[15:8];
      t_exp.push_back(t_got);
    end
    for (t_i = 0; t_i < u_pkt.size(); t_i++) fifo_send(0, u_pkt[t_i]);
    t_prev = cap_count;
    reg_write(7'h04, t_crc ? 8'h03 : 8'h01);  // FLAG0 = send, FLAG1 = append CRC16
    while (cap_count == t_prev) @(posedge clk);
    check(cap_q.size() == t_exp.size(), $sformatf("USB TX %s: %0d bytes, expected %0d", t_what, cap_q.size(), t_exp.size()));
    for (t_i = 0; t_i < t_exp.size() && t_i < cap_q.size(); t_i++)
      check(cap_q[t_i] === t_exp[t_i], $sformatf("USB TX %s byte %0d: got %02x, expected %02x", t_what, t_i, cap_q[t_i], t_exp[t_i]));
    check(cap_se0 >= 60 && cap_se0 <= 68, $sformatf("USB TX %s: SE0 lasted %0d clocks, expected 64", t_what, cap_se0));
    check(cap_j, $sformatf("USB TX %s: no J after SE0", t_what));
    do reg_read(7'h04, t_f); while (t_f != 0);
    $display("  sent %s: %0d bytes, %0d stuffed bits, EOP ok", t_what, cap_q.size(), cap_stuffed);
  endtask

  // The host model sends u_pkt to engine 1; check the bytes and status it pushes.
  logic [7:0] r_mask, r_exp, r_got;
  task usb_rx_check;
    usb_host_send;
    for (t_i = 0; t_i < u_pkt.size(); t_i++) begin
      fifo_recv(1, r_got);
      check(r_got === u_pkt[t_i], $sformatf("USB RX %s byte %0d: got %02x, sent %02x", t_what, t_i, r_got, u_pkt[t_i]));
    end
    fifo_recv(1, r_got);
    check((r_got & r_mask) == r_exp, $sformatf("USB RX %s: status %02x", t_what, r_got));
    $display("  received %s at %+0.1f%% bit rate, status %02x", t_what, h_pct, r_got);
  endtask

  // ---------------- tests ----------------
  initial begin
    logic [7:0] sent[$], got;
    $dumpfile("tb_pbe.vcd");
    $dumpvars(0, tb_pbe);

    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (5) @(posedge clk);

    // register readback sanity check
    reg_write(7'h10, 8'hA5);
    reg_read(7'h10, got);
    check(got == 8'hA5, $sformatf("CLKDIV_L readback %02x", got));

    // ===== Test 1: UART loopback =====
    $display("Test 1: UART TX (engine 0) looped back into UART RX (engine 1)");
    load_program("uart_image.hex");
    reg_write(7'h10, UART_BIT / 2 - 1);  // E0 tick = 1/2 bit
    reg_write(7'h11, 0);
    reg_write(7'h12, 0);                 // E0 pins start at 0
    reg_write(7'h14, 2'b00);             // LSB first
    reg_write(7'h15, 0);                 // start at word 0
    reg_write(7'h20, UART_BIT / 4 - 1);  // E1 tick = 1/4 bit
    reg_write(7'h21, 0);
    reg_write(7'h22, 1);                 // E1 pins start at 1
    reg_write(7'h23, 0);                 // JMP pin = rx
    reg_write(7'h24, 2'b00);
    reg_write(7'h25, 8);                 // start at word 8
    reg_write(7'h03, 8'b0000_0010);      // pin 1 belongs to E1
    loop01 = 1;
    uart_mon_en = 1;
    reg_write(7'h00, 8'b0011_0011);      // restart + run both

    sent = '{8'h55, 8'hA3, 8'h00, 8'hFF, 8'h0F, 8'h80};
    // one host port, so sends and receives take turns; keep up to 4 bytes queued
    for (int i = 0; i < 4; i++) fifo_send(0, sent[i]);
    foreach (sent[i]) begin
      fifo_recv(1, got);
      check(got === sent[i], $sformatf("UART RX byte %0d: got %02x, sent %02x", i, got, sent[i]));
      if (i + 4 < sent.size()) fifo_send(0, sent[i+4]);
    end
    repeat (2 * UART_BIT) @(posedge clk);
    check(uart_seen.size() == sent.size(), $sformatf("UART monitor saw %0d bytes", uart_seen.size()));
    foreach (uart_seen[i])
      check(uart_seen[i] === sent[i], $sformatf("UART monitor byte %0d: %02x", i, uart_seen[i]));
    $display("  sent %0d bytes, engine 1 and the monitor received them", sent.size());

    // ===== Test 2: SPI controller =====
    $display("Test 2: SPI controller (engine 0) against a mode-0 peripheral");
    reg_write(7'h00, 8'b1100_0000);      // stop both, flush FIFOs
    uart_mon_en = 0;
    loop01 = 0;
    load_program("spi_image.hex");
    reg_write(7'h03, 8'h00);
    reg_write(7'h10, 3);                 // tick = 4 clocks
    reg_write(7'h11, 0);
    reg_write(7'h12, 0);
    reg_write(7'h14, 2'b11);             // MSB first both ways
    reg_write(7'h15, 0);
    spi_reply = '{8'h3C, 8'hC3, 8'h81};
    spi_dev_en = 1;
    reg_write(7'h00, 8'b0001_0001);      // restart + run E0
    repeat (50) @(posedge clk);
    check(bus[3] == 1 && bus[0] == 0, "SPI idle: CS_n high, SCLK low");

    sent = '{8'hA5, 8'h5A, 8'h7E};
    foreach (sent[i]) fifo_send(0, sent[i]);
    foreach (sent[i]) begin
      fifo_recv(0, got);
      check(got === (i == 0 ? 8'h3C : i == 1 ? 8'hC3 : 8'h81),
            $sformatf("SPI read byte %0d: got %02x", i, got));
    end
    repeat (100) @(posedge clk);
    check(bus[3] == 1, "SPI: CS_n released at the end");
    check(spi_got.size() == 3, $sformatf("SPI peripheral got %0d bytes", spi_got.size()));
    foreach (spi_got[i])
      check(spi_got[i] === sent[i], $sformatf("SPI peripheral byte %0d: %02x, expected %02x", i, spi_got[i], sent[i]));
    $display("  exchanged %0d bytes in both directions", spi_got.size());

    // ===== Test 3: I2C on engine 1 while engine 0 sends UART =====
    $display("Test 3: I2C controller (engine 1, pins 4-5) running alongside UART TX (engine 0)");
    reg_write(7'h00, 8'b1100_0000);      // stop both, flush FIFOs
    spi_dev_en = 0;
    ext_drive = '0;
    load_program("mixed_image.hex");
    reg_write(7'h03, 8'b0011_0000);      // pins 4, 5 belong to E1
    reg_write(7'h10, UART_BIT / 2 - 1);  // E0: UART TX as in test 1
    reg_write(7'h11, 0);
    reg_write(7'h12, 0);
    reg_write(7'h14, 2'b00);
    reg_write(7'h15, 0);
    reg_write(7'h20, 4);                 // E1 tick = 5 clocks, SCL = 35 clocks (1.4 MHz at 50 MHz)
    reg_write(7'h21, 0);
    reg_write(7'h22, 4);                 // E1 pins start at 4
    reg_write(7'h24, 2'b11);             // MSB first
    reg_write(7'h25, 8);                 // i2c_ctrl at word 8
    uart_seen.delete();
    uart_mon_en = 1;
    i2c_en = 1;
    reg_write(7'h00, 8'b0011_0011);      // restart + run both

    sent = '{8'hC3, 8'h3C, 8'h99, 8'h66};
    foreach (sent[i]) fifo_send(0, sent[i]);  // UART keeps running during the I2C traffic

    begin
      logic [7:0] seen, ack;
      // write 0xDE, 0xAD to registers 0x10, 0x11
      i2c_cond(1);
      i2c_xfer(8'hA0, 8'h80, seen, ack); check(ack == 0, "I2C: address+W not ACKed");
      i2c_xfer(8'h10, 8'h80, seen, ack); check(ack == 0, "I2C: register not ACKed");
      i2c_xfer(8'hDE, 8'h80, seen, ack); check(ack == 0, "I2C: data 0 not ACKed");
      i2c_xfer(8'hAD, 8'h80, seen, ack); check(ack == 0, "I2C: data 1 not ACKed");
      i2c_cond(2);
      check(i2c_mem[8'h10] === 8'hDE && i2c_mem[8'h11] === 8'hAD,
            $sformatf("I2C write: peripheral holds %02x %02x", i2c_mem[8'h10], i2c_mem[8'h11]));

      // read them back: write the register pointer, repeated START, read 2 bytes
      i2c_cond(1);
      i2c_xfer(8'hA0, 8'h80, seen, ack); check(ack == 0, "I2C: address+W not ACKed (read)");
      i2c_xfer(8'h10, 8'h80, seen, ack); check(ack == 0, "I2C: pointer not ACKed");
      i2c_cond(1);                                                  // repeated START
      i2c_xfer(8'hA1, 8'h80, seen, ack); check(ack == 0, "I2C: address+R not ACKed");
      i2c_xfer(8'hFF, 8'h00, seen, ack); check(seen === 8'hDE, $sformatf("I2C read 0: %02x", seen));
      i2c_xfer(8'hFF, 8'h80, seen, ack); check(seen === 8'hAD, $sformatf("I2C read 1: %02x", seen));
      check(ack == 1, "I2C: last read byte should carry our NACK");
      i2c_cond(2);

      // nobody at 0x58: expect a NACK
      i2c_cond(1);
      i2c_xfer(8'hB0, 8'h80, seen, ack); check(ack == 1, "I2C: missing device should NACK");
      i2c_cond(2);
    end
    repeat (50) @(posedge clk);
    check(bus[SDA] && bus[SCL], "I2C: bus not idle (both high) at the end");
    check(i_starts == 4 && i_stops == 3, $sformatf("I2C: saw %0d STARTs, %0d STOPs", i_starts, i_stops));
    check(i_stretches >= 20, $sformatf("I2C: only %0d clock stretches", i_stretches));

    wait (uart_seen.size() == sent.size() || $time > 15ms);
    foreach (sent[i])
      check(uart_seen[i] === sent[i], $sformatf("UART during I2C: byte %0d %02x", i, uart_seen[i]));
    $display("  I2C write, read with repeated START, and NACK passed with %0d clock stretches;", i_stretches);
    $display("  UART sent %0d bytes at the same time", uart_seen.size());

    // ===== Test 4: low-speed USB =====
    $display("Test 4: low-speed USB TX (engine 0, pins 0/1) and RX (engine 1, pins 2/3)");
    reg_write(7'h00, 8'b1100_0000);      // stop both, flush FIFOs
    uart_mon_en = 0;
    i2c_en = 0;
    ext_drive = '0;
    reg_write(7'h04, 8'h00);
    pull_lo = 8'b0000_0101;             // D+ pulled down (host side), D- pulled up (LS device)
    load_program("usb_image.hex");
    reg_write(7'h03, 8'b0000_1100);      // pins 2, 3 belong to E1
    for (int e = 0; e < 2; e++) begin
      reg_write(7'h10 + 7'(e * 16), 0);  // CLKDIV 0: the line unit does the bit timing
      reg_write(7'h11 + 7'(e * 16), 0);
      reg_write(7'h12 + 7'(e * 16), e ? 2 : 0);
      reg_write(7'h14 + 7'(e * 16), 2'b00);  // LSB first
      reg_write(7'h15 + 7'(e * 16), e ? 40 : 0);
      reg_write(7'h17 + 7'(e * 16), 31);     // 32 clocks per bit = 1.5 Mbit/s at 48 MHz
    end
    reg_write(7'h00, 8'b0011_0011);
    repeat (100) @(posedge clk);
    check(!bus[0] && bus[1] && !bus[2] && bus[3], "USB: both pairs should idle in J");
    usb_mon_en = 1;

    u_pkt = '{8'hC3, 8'h80, 8'h06, 8'h00, 8'h01, 8'h00, 8'h00, 8'h40, 8'h00};
    usb_crc16;
    check(u_crc == 16'h94DD, $sformatf("tb CRC16 model: %04x, expected 94dd (bytes DD 94)", u_crc));
    t_crc = 1; t_what = "DATA0 GET_DESCRIPTOR";       usb_tx_check;
    u_pkt = '{8'hD2};
    t_crc = 0; t_what = "ACK handshake";              usb_tx_check;
    u_pkt = '{8'h4B, 8'hFF, 8'hFF, 8'hFF};
    t_crc = 1; t_what = "DATA1 with long runs of 1s"; usb_tx_check;

    u_pkt = '{8'h2D, 8'h00, 8'h10};
    h_pct = 1.5;  r_mask = 8'h01; r_exp = 8'h01; t_what = "SETUP token";                 usb_rx_check;
    u_pkt = '{8'h2D, 8'h00, 8'h11};
    h_pct = -1.5; r_mask = 8'h01; r_exp = 8'h00; t_what = "SETUP token with a bad CRC5"; usb_rx_check;
    u_pkt = '{8'hC3, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'h80, 8'h06, 8'h00, 8'h01};
    usb_crc16;
    u_pkt.push_back(u_crc[7:0]);
    u_pkt.push_back(u_crc[15:8]);
    h_pct = -1.5; r_mask = 8'h02; r_exp = 8'h02; t_what = "DATA0 with stuffed bits";     usb_rx_check;
    u_pkt[3] = 8'hFE;
    h_pct = 1.5;  r_mask = 8'h02; r_exp = 8'h00; t_what = "DATA0 with a flipped bit";    usb_rx_check;
    if (errors == 0) $display("PASS");
    else $display("FAILED with %0d error(s)", errors);
    $finish;
  end

  initial begin
    #40ms;
    $display("FAILED: timeout");
    $finish;
  end
endmodule
