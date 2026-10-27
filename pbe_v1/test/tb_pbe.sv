`timescale 1ns / 1ps
// End-to-end test of tt_um_pbe through its real pins only.
//
//  Test 1  UART: engine 0 runs uart_tx on pin 0, engine 1 runs uart_rx on pin 1,
//          pin 0 is looped back to pin 1. An independent UART monitor also decodes pin 0.
//  Test 2  SPI:  engine 0 runs spi_ctrl on pins 0..3 against a behavioural mode-0 peripheral.
//
// Every pin has a pull-up and lines are wired-AND, like a real open-drain bus.
module tb_pbe;
  localparam int CLK_NS = 20;  // 50 MHz
  localparam int HOST_HALF = 8;  // host SCK half period in clocks (SCK = clk / 16)
  localparam int UART_BIT = 100;  // clocks per UART bit (500 kbaud at 50 MHz)

  logic clk = 0, rst_n = 0;
  always #(CLK_NS / 2) clk = ~clk;

  logic [7:0] ui_in = 8'b0000_0010;  // CS_n high
  wire  [7:0] uo_out, uio_out, uio_oe;
  logic [7:0] ext_drive = '0, ext_val = '0;
  logic       loop01 = 0;

  wire  [7:0] chip_lvl = ~uio_oe | uio_out;  // released pins float high
  wire  [7:0] ext_lvl  = ~ext_drive | ext_val;
  wire  [7:0] bus      = chip_lvl & ext_lvl & (loop01 ? {6'h3f, chip_lvl[0], 1'b1} : 8'hff);

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

    if (errors == 0) $display("PASS");
    else $display("FAILED with %0d error(s)", errors);
    $finish;
  end

  initial begin
    #20ms;
    $display("FAILED: timeout");
    $finish;
  end
endmodule
