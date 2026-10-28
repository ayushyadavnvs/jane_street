`timescale 1ns / 1ps
// End-to-end tests of the LED and device-side protocols, through the chip's pins only.
//
//  Test 8   WS2812 LED driver (engine 0, pin 0) against a decoder that checks every pulse width
//  Test 9   SPI peripheral (engine 0, pins 0..3) driven by a mode-0 controller model at 2 MHz
//  Test 10  I2C target: i2c_target (engine 0) and i2c_watch (engine 1) share pins 0-1 and their
//           flags; an I2C controller model drives the bus and the host answers through flags
//
// Every pin has a pull-up and lines are wired-AND, like a real open-drain bus.
module tb_proto;
  localparam real CLK_NS = 20.8333;  // 48 MHz
  localparam int HOST_HALF = 8;      // host SCK = clk / 16

  logic clk = 0, rst_n = 0;
  always #(CLK_NS / 2) clk = ~clk;

  logic [7:0] ui_in = 8'b0000_0010;  // CS_n high
  wire  [7:0] uo_out, uio_out, uio_oe;
  logic [7:0] ext_drive = '0, ext_val = '0;

  wire  [7:0] chip_lvl = ~uio_oe | uio_out;  // released pins float high
  wire  [7:0] ext_lvl  = ~ext_drive | ext_val;
  wire  [7:0] bus      = chip_lvl & ext_lvl;

  tt_um_ayushyadavnvs_pbe dut (
      .ui_in, .uo_out, .uio_in(bus), .uio_out, .uio_oe, .ena(1'b1), .clk, .rst_n
  );

  `include "tb_host.svh"

  // Burst bytes into engine e's TX FIFO in one SPI transaction, pausing while the TX-full pin
  // (uo_out[6 + e]) is high: the flow control a real host would use.
  logic [7:0] stream_q[$];
  task automatic fifo_stream(input int e);
    logic [7:0] d;
    cs(0);
    spi_byte({1'b1, e ? 7'h26 : 7'h16}, d);
    while (stream_q.size()) begin
      while (uo_out[6+e]) @(posedge clk);
      d = stream_q.pop_front();  // Icarus 12 crashes on a queue pop passed as an argument
      spi_byte(d, d);
    end
    cs(1);
  endtask

  // ---------------- WS2812 decoder on pin 0 ----------------
  // WS2812B datasheet: T0H 0.4 us, T1H 0.8 us, T0L 0.85 us, T1L 0.45 us, each +/-150 ns.
  // A low of 50 us or more latches the frame; ws_take_frame collects it.
  bit ws_en = 0;
  int ws_bad = 0;
  logic [7:0] ws_bits[$];  // one bit per entry (Icarus 12 mishandles queues of 1-bit elements)
  bit ws_last;
  realtime ws_rise = 0, ws_fall = 0, low, high;  // not declared in the always blocks: a
                                                 // declaration's initializer runs only once
  always @(posedge bus[0]) if (ws_en) begin
    if (ws_fall > 0) begin
      low = $realtime - ws_fall;
      if (ws_last ? (low < 300 || low > 600) : (low < 700 || low > 1000)) begin
        ws_bad++;
        $display("  WS2812: low after a %0d bit lasted %0.0f ns", ws_last, low);
      end
    end
    ws_rise = $realtime;
  end
  always @(negedge bus[0]) if (ws_en && ws_rise > 0) begin
    high = $realtime - ws_rise;
    ws_last = high > 600;
    if (ws_last ? (high < 650 || high > 950) : (high < 250 || high > 550)) begin
      ws_bad++;
      $display("  WS2812: high lasted %0.0f ns", high);
    end
    ws_bits.push_back(8'(ws_last));
    ws_fall = $realtime;
  end
  logic [7:0] ws_bytes[$];
  task automatic ws_take_frame;  // decoded bytes into ws_bytes
    ws_bytes.delete();
    check(bus[0] == 0, "WS2812: line not low at the end of a frame");
    check(ws_bits.size() % 8 == 0, $sformatf("WS2812: frame of %0d bits", ws_bits.size()));
    while (ws_bits.size() >= 8) begin
      logic [7:0] b;
      logic [7:0] x;
      for (int i = 7; i >= 0; i--) begin  // MSB first
        x = ws_bits.pop_front();
        b[i] = x[0];
      end
      ws_bytes.push_back(b);
    end
    ws_bits.delete();
    ws_fall = 0;  // the next low is a reset, not a bit
  endtask

  // ---------------- SPI controller model, mode 0: sclk 0, mosi 1, miso 2, cs 3 ----------------
  localparam int SPI_HALF = 12;  // SCLK half period in clocks: 2 MHz at 48 MHz
  bit spic_en = 0;
  task automatic spic_select(input bit sel);
    ext_drive[0] = 1; ext_drive[1] = 1; ext_drive[3] = 1;
    ext_val[3] = !sel;
  endtask
  task automatic spic_byte(input logic [7:0] tx, output logic [7:0] rx);
    for (int i = 7; i >= 0; i--) begin
      ext_val[1] = tx[i];
      repeat (SPI_HALF) @(posedge clk);
      rx[i] = bus[2];  // sampled just before the rising edge: tests the setup time
      ext_val[0] = 1;
      repeat (SPI_HALF) @(posedge clk);
      ext_val[0] = 0;
    end
  endtask
  // the peripheral may change MISO only while SCLK is low
  always @(bus[2]) if (spic_en && !bus[3])
    check(!bus[0], "SPI peripheral: MISO changed while SCLK was high");

  // ---------------- I2C controller model: sda = pin 0, scl = pin 1, fast mode ----------------
  localparam int IC_LOW = 64, IC_HIGH = 32;  // 1.33 us low, 0.67 us high: 400 kHz
  localparam logic [6:0] TGT_ADDR = 7'h42;
  bit ic_en = 0;
  int ic_stretch = 0;  // clocks the target held SCL low
  task automatic ic_sda(input bit v);
    ext_drive[0] = !v;
    ext_val[0] = 0;
  endtask
  task automatic ic_scl(input bit v);
    ext_drive[1] = !v;
    ext_val[1] = 0;
  endtask
  task automatic ic_release_scl;  // release SCL and wait while the target stretches it
    ic_scl(1);
    @(posedge clk);
    while (!bus[1]) begin
      ic_stretch++;
      @(posedge clk);
    end
  endtask
  task automatic ic_bit(input bit b, output bit r);  // SCL is low on entry and exit
    repeat (IC_LOW / 4) @(posedge clk);
    ic_sda(b);
    repeat (IC_LOW - IC_LOW / 4) @(posedge clk);
    ic_release_scl;
    repeat (IC_HIGH) @(posedge clk);
    r = bus[0];
    ic_scl(0);
  endtask
  task automatic ic_start;  // START, or repeated START when SCL is low
    // Test our own drive, not bus[1]: right after ic_scl(0) the net has not updated yet.
    if (ext_drive[1]) begin
      repeat (IC_LOW / 4) @(posedge clk);
      ic_sda(1);
      repeat (IC_LOW - IC_LOW / 4) @(posedge clk);
      ic_release_scl;
      repeat (IC_HIGH) @(posedge clk);  // tSU;STA
    end
    ic_sda(0);
    repeat (IC_HIGH) @(posedge clk);    // tHD;STA
    ic_scl(0);
  endtask
  task automatic ic_stop;
    repeat (IC_LOW / 4) @(posedge clk);
    ic_sda(0);
    repeat (IC_LOW - IC_LOW / 4) @(posedge clk);
    ic_release_scl;
    repeat (IC_HIGH) @(posedge clk);    // tSU;STO
    ic_sda(1);
    repeat (IC_LOW) @(posedge clk);     // tBUF
  endtask
  bit ic_other = 0;  // another target on the bus ACKs (pulls SDA low in the ACK slot)
  task automatic ic_write(input logic [7:0] b, output bit ack);
    bit r;
    for (int i = 7; i >= 0; i--) ic_bit(b[i], r);
    ic_bit(!ic_other, r);
    ack = !r;
  endtask
  task automatic ic_read(input bit ack, output logic [7:0] b);
    bit r;
    for (int i = 7; i >= 0; i--) begin
      ic_bit(1, r);  // not ic_bit(1, b[i]): Icarus 12 crashes on a bit-select as an output argument
      b[i] = r;
    end
    ic_bit(!ack, r);
  endtask

  // The target must change SDA only while SCL is low, at least 300 ns after SCL fell (data hold),
  // and at least 250 ns before it lets go of a stretched SCL (data setup, standard mode).
  realtime ic_fell = 0, ic_sda_chg = 0;
  int ic_hold_min = 1000000, ic_setup_min = 1000000;
  always @(negedge bus[1]) ic_fell = $realtime;
  always @(chip_lvl[0]) if (ic_en) begin
    check(!bus[1], "I2C target: SDA changed while SCL was high");
    if ($realtime - ic_fell < ic_hold_min) ic_hold_min = $realtime - ic_fell;
    ic_sda_chg = $realtime;
  end
  always @(posedge chip_lvl[1]) if (ic_en)
    if ($realtime - ic_sda_chg < ic_setup_min) ic_setup_min = $realtime - ic_sda_chg;

  // Host service loop for the target: a register device like the one in tb_pbe. A write's first
  // byte sets the pointer, later bytes are stored; reads return bytes from the pointer.
  logic [7:0] tgt_mem[256], tgt_ptr;
  logic [7:0] tgt_pending[$];
  bit tgt_run = 0, tgt_first = 0;
  int tgt_acks = 0, tgt_nacks = 0, tgt_stops = 0, tgt_reads = 0, tgt_bytes = 0;
  task automatic tgt_drain;
    logic [7:0] st, d;
    reg_read(7'h01, st);
    while (!st[0]) begin
      reg_read(7'h16, d);
      tgt_pending.push_back(d);
      reg_read(7'h01, st);
    end
  endtask
  task automatic tgt_data(input logic [7:0] d);
    tgt_bytes++;
    if (tgt_first) tgt_ptr = d;
    else begin
      tgt_mem[tgt_ptr] = d;
      tgt_ptr++;
    end
    tgt_first = 0;
  endtask
  initial forever begin
    @(posedge clk);
    if (tgt_run) begin
      logic [7:0] f, a, a2;
      tgt_drain;
      reg_read(7'h04, f);  // after the drain: if FLAG2 is still clear, no address was drained
      if (f[2]) begin
        tgt_drain;
        if (tgt_pending.size()) begin  // an address, after any data bytes written before it
          a = tgt_pending.pop_back();
          while (tgt_pending.size()) begin
            a2 = tgt_pending.pop_front();
            tgt_data(a2);
          end
          if (a[7:1] == TGT_ADDR) begin
            tgt_acks++;
            tgt_first = !a[0];
          end else begin
            tgt_nacks++;
            reg_write(7'h00, 8'b0001_0011);  // NACK: restart engine 0, keep both running
          end
        end else begin                 // a read needs its next byte
          a = tgt_mem[tgt_ptr];
          fifo_send(0, a);
          tgt_ptr++;
          tgt_reads++;
        end
        reg_write(7'h09, 8'h04);       // clear FLAG2: the engine goes on
      end else while (tgt_pending.size()) begin
        a2 = tgt_pending.pop_front();
        tgt_data(a2);
      end
      if (f[3]) begin
        tgt_stops++;
        reg_write(7'h09, 8'h08);
      end
    end
  end
  task automatic tgt_wait_stops(input int n);
    int t = 0;
    while (tgt_stops < n && t < 20000) begin
      @(posedge clk);
      t++;
    end
    check(tgt_stops >= n, $sformatf("I2C target: host saw %0d STOPs, expected %0d", tgt_stops, n));
  endtask

  // ---------------- tests ----------------
  initial begin
    logic [7:0] got[$], exp[$];
    if ($test$plusargs("vcd")) begin
      $dumpfile("tb_proto.vcd");
      $dumpvars(0, tb_proto);
    end
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (5) @(posedge clk);

    // ===== Test 8: WS2812 =====
    $display("Test 8: WS2812 LED driver (engine 0, pin 0) at 800 kbit/s");
    load_program("ws2812_image.hex");
    reg_write(7'h10, 1);                 // tick = 2 clocks (41.7 ns)
    reg_write(7'h11, 0);
    reg_write(7'h12, 0);
    reg_write(7'h14, 2'b01);             // OUT MSB first
    reg_write(7'h15, 0);
    ws_en = 1;
    reg_write(7'h00, 8'b0001_0001);      // restart + run E0
    for (int frame = 0; frame < 2; frame++) begin
      exp.delete();
      for (int led = 0; led < 5; led++) begin  // G, R, B per LED
        // 8'() casts: Icarus 12 aborts when push_back gets a wider value than the queue holds
        exp.push_back(8'(8'h10 * led + frame));
        exp.push_back(8'(frame ? 8'hFF - 8'h33 * led : 8'h01 << led));
        exp.push_back(8'(8'hA5 ^ (8'h11 * led)));
      end
      foreach (exp[i]) stream_q.push_back(exp[i]);
      fifo_stream(0);
      wait_tx_empty(0);
      repeat ($rtoi(60000 / CLK_NS)) @(posedge clk);  // the last byte, then a 50 us reset
      ws_take_frame;
      got.delete();
      foreach (ws_bytes[i]) got.push_back(ws_bytes[i]);
      check(got.size() == exp.size(), $sformatf("WS2812 frame %0d: %0d bytes", frame, got.size()));
      foreach (got[i])
        if (i < exp.size())
          check(got[i] === exp[i], $sformatf("WS2812 frame %0d byte %0d: %02x, sent %02x", frame, i, got[i], exp[i]));
    end
    check(ws_bad == 0, $sformatf("WS2812: %0d pulses out of spec", ws_bad));
    $display("  2 frames of 5 LEDs, every pulse within +/-150 ns of the datasheet");
    ws_en = 0;

    // ===== Test 9: SPI peripheral =====
    $display("Test 9: SPI peripheral (engine 0, pins 0..3), mode 0, SCLK 2 MHz");
    reg_write(7'h00, 8'b1100_0000);      // stop, flush FIFOs
    load_program("spi_periph_image.hex");
    reg_write(7'h10, 0);                 // tick = 1 clock
    reg_write(7'h11, 0);
    reg_write(7'h12, 0);
    reg_write(7'h13, 3);                 // JMP pin = cs
    reg_write(7'h14, 2'b11);             // MSB first both ways
    reg_write(7'h15, 0);
    reg_write(7'h1C, 64);                // timeout: 64 clocks without SCLK
    reg_write(7'h1D, 0);
    reg_write(7'h1E, 8'h01);             // timeout routine at word 1
    spic_select(0);
    reg_write(7'h00, 8'b0001_0001);
    repeat (100) @(posedge clk);
    check(!uio_oe[2], "SPI peripheral drives MISO while not selected");
    spic_en = 1;
    begin
      logic [7:0] rx, sent[$], back[$];
      // 1: two replies queued, the controller clocks three bytes: the third reply is 0xFF
      fifo_send(0, 8'h3C);
      fifo_send(0, 8'hA5);
      sent = '{8'h11, 8'h22, 8'h33};
      spic_select(1);
      foreach (sent[i]) begin
        spic_byte(sent[i], rx);
        back.push_back(rx);
      end
      repeat (SPI_HALF) @(posedge clk);
      spic_select(0);
      check(back[0] == 8'h3C && back[1] == 8'hA5 && back[2] == 8'hFF,
            $sformatf("SPI peripheral replies %02x %02x %02x, expected 3c a5 ff", back[0], back[1], back[2]));
      repeat (100) @(posedge clk);       // > timeout: the transaction is over
      check(!uio_oe[2], "SPI peripheral: MISO not released after CS went high");
      foreach (sent[i]) begin
        fifo_recv(0, rx);
        check(rx === sent[i], $sformatf("SPI peripheral received %02x, controller sent %02x", rx, sent[i]));
      end

      // 2: a pause longer than the timeout in the middle of a transaction
      back.delete();
      fifo_send(0, 8'h5A);
      fifo_send(0, 8'hC3);
      spic_select(1);
      spic_byte(8'h44, rx);
      back.push_back(rx);
      repeat (300) @(posedge clk);       // CS stays low, SCLK stops
      spic_byte(8'h55, rx);
      back.push_back(rx);
      repeat (SPI_HALF) @(posedge clk);
      spic_select(0);
      check(back[0] == 8'h5A && back[1] == 8'hC3,
            $sformatf("SPI peripheral after a pause: replies %02x %02x, expected 5a c3", back[0], back[1]));
      fifo_recv(0, rx);
      check(rx === 8'h44, $sformatf("SPI peripheral received %02x before the pause", rx));
      fifo_recv(0, rx);
      check(rx === 8'h55, $sformatf("SPI peripheral received %02x after the pause", rx));
      repeat (100) @(posedge clk);

      // 3: nothing queued at all: the controller reads 0xFF from the first bit on
      back.delete();
      spic_select(1);
      for (int i = 0; i < 2; i++) begin
        spic_byte(8'h60 + i, rx);
        back.push_back(rx);
      end
      repeat (SPI_HALF) @(posedge clk);
      spic_select(0);
      check(back[0] == 8'hFF && back[1] == 8'hFF,
            $sformatf("SPI peripheral with nothing queued replied %02x %02x, expected ff ff", back[0], back[1]));
      for (int i = 0; i < 2; i++) begin
        fifo_recv(0, rx);
        check(rx === 8'h60 + i, $sformatf("SPI peripheral received %02x, controller sent %02x", rx, 8'h60 + i));
      end
      repeat (100) @(posedge clk);
    end
    spic_en = 0;
    ext_drive = '0;
    $display("  3 transactions: replies queued, default 0xFF, a pause inside a transaction");

    // ===== Test 10: I2C target =====
    $display("Test 10: I2C target at 0x%02x (engines 0 + 1, pins 0-1), fast mode controller", TGT_ADDR);
    reg_write(7'h00, 8'b1100_0000);
    reg_write(7'h1C, 0);                 // timeout off
    reg_write(7'h1E, 0);
    reg_write(7'h04, 8'h00);
    reg_write(7'h02, 8'h03);
    load_program("i2c_target_image.hex");  // bit engine at word 0, watcher at word 64
    reg_write(7'h03, 8'h00);             // both pins belong to E0
    reg_write(7'h10, 0);                 // E0: bit engine
    reg_write(7'h11, 0);
    reg_write(7'h12, 0);
    reg_write(7'h13, 0);                 // JMP pin = sda
    reg_write(7'h14, 2'b11);
    reg_write(7'h15, 0);
    reg_write(7'h20, 0);                 // E1: watcher, same pins, same flags
    reg_write(7'h21, 0);
    reg_write(7'h22, 0);
    reg_write(7'h23, 1);                 // JMP pin = scl
    reg_write(7'h25, 64);
    reg_write(7'h28, 0);                 // FLAG_BASE 0, like engine 0
    ic_en = 1;
    reg_write(7'h00, 8'b0011_0011);      // restart + run both
    tgt_run = 1;
    begin
      bit ack;
      logic [7:0] b;
      // 1: write the pointer 0x10 and 20 bytes (more than the 16-byte RX FIFO holds)
      ic_start;
      ic_write({TGT_ADDR, 1'b0}, ack); check(ack, "I2C target: address+W not ACKed");
      ic_write(8'h10, ack); check(ack, "I2C target: pointer not ACKed");
      exp = '{8'hDE, 8'hAD, 8'hBE, 8'hEF, 8'h01};
      for (int i = 5; i < 20; i++) exp.push_back(8'(8'h30 + i));
      foreach (exp[i]) begin
        ic_write(exp[i], ack);
        check(ack, $sformatf("I2C target: data byte %0d not ACKed", i));
      end
      ic_stop;
      tgt_wait_stops(1);
      foreach (exp[i])
        check(tgt_mem[8'h10 + i] === exp[i], $sformatf("I2C target write: mem[%02x] = %02x", 8'h10 + i, tgt_mem[8'h10 + i]));

      // 2: set the pointer, repeated START, read three bytes
      ic_start;
      ic_write({TGT_ADDR, 1'b0}, ack);
      ic_write(8'h11, ack);
      ic_start;
      ic_write({TGT_ADDR, 1'b1}, ack); check(ack, "I2C target: address+R not ACKed");
      got.delete();
      for (int i = 0; i < 3; i++) begin
        ic_read(i < 2, b);
        got.push_back(b);
      end
      ic_stop;
      tgt_wait_stops(2);
      check(got[0] == 8'hAD && got[1] == 8'hBE && got[2] == 8'hEF,
            $sformatf("I2C target read %02x %02x %02x, expected ad be ef", got[0], got[1], got[2]));

      // 3: another device's address: the host NACKs it. That device ACKs and takes two bytes;
      // our target must stay off SDA and pass nothing to the host.
      begin
        int bytes_before;
        bit sda_touched;
        bytes_before = tgt_bytes;  // not an initializer: that would run once, at time 0
        sda_touched = 0;
        ic_other = 1;
        fork
          begin : watch_sda
            @(negedge chip_lvl[0]) sda_touched = 1;
          end
          begin
            ic_start;
            ic_write({TGT_ADDR + 7'd1, 1'b0}, ack);
            ic_write(8'h77, ack);
            ic_write(8'h88, ack);
            ic_stop;
            disable watch_sda;
          end
        join
        ic_other = 0;
        tgt_wait_stops(3);
        check(!sda_touched, "I2C target drove SDA during another device's transaction");
        check(tgt_bytes == bytes_before, $sformatf("I2C target passed %0d bytes of another device's transaction to the host",
                                                 tgt_bytes - bytes_before));
      end

      // 4: and the target still answers: a read continues from the pointer (now 0x14)
      ic_start;
      ic_write({TGT_ADDR, 1'b1}, ack); check(ack, "I2C target: address+R not ACKed after a NACK");
      ic_read(0, b);
      ic_stop;
      tgt_wait_stops(4);
      check(b == 8'h01, $sformatf("I2C target read %02x after the NACK, expected 01", b));
    end
    tgt_run = 0;
    check(tgt_acks == 4 && tgt_nacks == 1 && tgt_reads == 4,
          $sformatf("I2C target host: %0d ACKs, %0d NACKs, %0d reads", tgt_acks, tgt_nacks, tgt_reads));
    check(ic_stretch > 0, "I2C target never stretched SCL");
    check(ic_hold_min >= 300, $sformatf("I2C target: SDA hold %0d ns after SCL fell", ic_hold_min));
    check(ic_setup_min >= 250, $sformatf("I2C target: SDA setup %0d ns before SCL release", ic_setup_min));
    $display("  write 20 bytes, read 3 after a repeated START, ignore another device's transfer; hold >= %0d ns, setup >= %0d ns",
             ic_hold_min, ic_setup_min);
    ic_en = 0;

    if (errors == 0) begin
      $display("PASS");
      $finish;
    end else $fatal(1, "FAILED with %0d error(s)", errors);
  end

  initial begin
    #100ms;
    $fatal(1, "FAILED: timeout");
  end
endmodule
