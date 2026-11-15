`timescale 1ns / 1ps
// UART <-> I2C bridge (D103): bridge_uart.pbe on engine 0, bridge_i2c.pbe on engine 1, joined by
// the engine-to-engine link in both directions (D102). The host sets the chip up over SPI and
// then makes no transaction at all (checked): every command and reply goes UART -> engine 0 ->
// link -> engine 1 -> I2C and back.
//
// Models, written from the protocols, not from the programs:
//   - a UART terminal at 115200 baud 8N1 on pins 0 (chip TXD) and 1 (chip RXD); its receiver
//     checks every start and stop bit;
//   - an I2C target at 0x50 (pins 2 = SDA, 3 = SCL, open drain, pull-ups): a register device
//     ([reg] then data writes; reads from the pointer), registers 0xF0-0xFF write-protected (a
//     data byte for them is NACKed and not stored); it stretches SCL after bits 4 and 8.
//     No device answers at other addresses (NACK).
// Commands: writes, reads, address NACK (write and read, with the dropped bytes), data NACK in
// the middle of a write, probes, a read of 0 bytes, an unknown command, an 8-byte read and a
// 12-byte write, a command typed slowly, and a command sent the moment the previous reply
// ended. The terminal waits for each reply before its next command (engine 0 is half-duplex). Every reply is checked, the target's
// memory and its START/STOP counts too, and SCL against fast mode's minimum low and high times.
module tb_bridge;
  localparam real CLK_NS = 16.6672;   // 60 MHz
  localparam int HOST_HALF = 3;
  localparam real BIT_NS = 1.0e9 / 115200.0;

  logic clk = 0, rst_n = 0;
  always #(CLK_NS / 2) clk = ~clk;

  logic [7:0] ui_in = 8'b0000_0010;
  wire  [7:0] uo_out, uio_out, uio_oe;

  // pins: 0 chip TXD, 1 chip RXD, 2 SDA, 3 SCL (open drain with pull-ups)
  logic uart_rx_line = 1;                  // the terminal's TXD
  logic t_sda = 1, t_scl = 1;              // the target's open-drain outputs (1 = released)
  wire  sda = !(uio_oe[2] && !uio_out[2]) && t_sda;
  wire  scl = !(uio_oe[3] && !uio_out[3]) && t_scl;
  wire  chip_txd = uio_oe[0] ? uio_out[0] : 1'b1;
  wire [7:0] uio_in = {4'b1111, scl, sda, uart_rx_line, chip_txd};

  tt_um_ayushyadavnvs_pbe dut (
      .ui_in, .uo_out, .uio_in, .uio_out, .uio_oe, .ena(1'b1), .clk, .rst_n
  );

  `include "tb_host.svh"

  // the host stays out of the data path: no CS_n low after setup
  bit setup_done = 0;
  int host_after = 0;
  always @(negedge ui_in[1]) if (setup_done) host_after++;

  // ---------------- UART terminal ----------------
  task automatic uart_send(input logic [7:0] b);
    uart_rx_line = 0;
    #(BIT_NS);
    for (int i = 0; i < 8; i++) begin
      uart_rx_line = b[i];
      #(BIT_NS);
    end
    uart_rx_line = 1;
    #(BIT_NS);
  endtask
  logic [7:0] uart_got[$];
  int frame_errors = 0;
  initial begin : uart_receiver
    logic [7:0] b;
    forever begin
      @(negedge chip_txd);
      if (rst_n && setup_done) begin
        #(BIT_NS / 2);
        if (chip_txd) frame_errors++;                    // start bit gone at its middle
        else begin
          for (int i = 0; i < 8; i++) begin
            #(BIT_NS);
            b[i] = chip_txd;
          end
          #(BIT_NS);
          if (!chip_txd) frame_errors++;                 // stop bit
          uart_got.push_back(b);
        end
      end
    end
  end

  // ---------------- I2C target at 0x50 ----------------
  localparam logic [6:0] T_ADDR = 7'h50;
  localparam int STRETCH = 150;
  typedef enum {T_IDLE, T_ADR, T_REG, T_WDATA, T_RDATA, T_IGNORE} t_st_t;
  t_st_t t_st = T_IDLE;
  logic [7:0] mem[256];
  logic [7:0] t_ptr, t_sh;
  int t_bit = 0, n_start = 0, n_stop = 0, n_stretch = 0;
  bit t_ack = 0;
  initial for (int i = 0; i < 256; i++) mem[i] = 8'(i ^ 8'h5A);

  always @(negedge sda) if (scl && setup_done) begin   // START (or repeated START)
    t_st = T_ADR; t_bit = 0; t_sda = 1; n_start++;
  end
  always @(posedge sda) if (scl && setup_done) begin   // STOP
    t_st = T_IDLE; t_sda = 1; n_stop++;
  end
  always @(posedge scl) if (t_st != T_IDLE && t_st != T_IGNORE) begin
    t_bit++;
    if (t_bit <= 8 && t_st != T_RDATA) t_sh = {t_sh[6:0], sda};
    if (t_bit == 9 && t_st == T_RDATA && sda) t_st = T_IGNORE;  // NACK: the controller is done
  end
  always @(negedge scl) if (t_st != T_IDLE && t_st != T_IGNORE) begin
    if (t_bit == 8) begin
      t_ack = 1;
      case (t_st)
        T_ADR:   if (t_sh[7:1] == T_ADDR) begin if (t_sh[0]) t_st = T_RDATA; else t_st = T_REG; end
                 else begin t_st = T_IGNORE; t_ack = 0; end
        T_REG:   begin t_ptr = t_sh; t_st = T_WDATA; end
        T_WDATA: if (t_ptr >= 8'hF0) t_ack = 0;           // write-protected: NACK, not stored
                 else begin mem[t_ptr] = t_sh; t_ptr++; end
        default: t_ack = 0;                               // reading: the controller ACKs
      endcase
      t_sda = !t_ack;
    end else if (t_bit == 9) begin
      t_bit = 0;
      if (t_st == T_RDATA) begin
        t_sh = mem[t_ptr];
        t_ptr++;
        t_sda = t_sh[7];
      end else t_sda = 1;
    end else if (t_st == T_RDATA && t_bit >= 1) t_sda = t_sh[7 - t_bit];
    if (t_bit == 4 || t_bit == 8) begin                   // clock stretching
      t_scl = 0;
      n_stretch++;
      repeat (STRETCH) @(posedge clk);
      t_scl = 1;
    end
  end
  // a read: the first data bit goes out when the address's ACK clock ends
  always @(negedge scl) if (t_st == T_RDATA && t_bit == 0 && t_ack) begin
    t_ack = 0;
  end

  // SCL against fast mode: low >= 1.3 us, high >= 0.6 us (a stretched low is the target's)
  realtime scl_fell = 0, scl_rose = 0, min_low = 1e9, min_high = 1e9;
  always @(posedge scl) if (setup_done) begin
    if (scl_fell > 0 && $realtime - scl_fell < min_low) min_low = $realtime - scl_fell;
    scl_rose = $realtime;
  end
  always @(negedge scl) if (setup_done) begin
    if (scl_rose > 0 && $realtime - scl_rose < min_high) min_high = $realtime - scl_rose;
    scl_fell = $realtime;
  end

  // ---------------- commands ----------------
  logic [7:0] exp_q[$];
  task automatic expect_reply(input string what, input int timeout_bits = 400);
    int t = 0;
    while (uart_got.size() < exp_q.size() && t < timeout_bits) begin #(BIT_NS); t++; end
    #(BIT_NS * 12);   // nothing more may follow
    begin
      string g = "", e = "";
      bit ok = uart_got.size() == exp_q.size();
      foreach (uart_got[i]) g = {g, $sformatf("%02x ", uart_got[i])};
      foreach (exp_q[i]) e = {e, $sformatf("%02x ", exp_q[i])};
      if (ok) foreach (exp_q[i]) if (uart_got[i] !== exp_q[i]) ok = 0;
      check(ok, $sformatf("%s: reply %s, expected %s", what, g, e));
    end
    uart_got.delete();
    exp_q.delete();
  endtask

  task automatic mem_is(input logic [7:0] a, input logic [7:0] v, input string what);
    check(mem[a] === v, $sformatf("%s: target register %02x = %02x, expected %02x", what, a, mem[a], v));
  endtask

  initial begin
    int s0, p0;
    repeat (5) @(posedge clk);
    @(negedge clk) rst_n = 1;
    repeat (5) @(posedge clk);
    load_program("bridge_image.hex");
    reg_write(7'h00, 8'hF0);
    reg_write(7'h10, 8'd32);    // E0: tick = 33 clocks = 1/16 bit at 115200 (-1.4 %)
    reg_write(7'h11, 8'd0);
    reg_write(7'h12, 8'd0);     // PIN_BASE 0: TXD 0, RXD 1
    reg_write(7'h13, 8'd1);     // JMP_PIN = RXD
    reg_write(7'h14, 8'h00);    // LSB first
    reg_write(7'h15, 8'd0);
    reg_write(7'h20, 8'd21);    // E1: tick = 22 clocks, SCL = 7 ticks (390 kHz)
    reg_write(7'h21, 8'd0);
    reg_write(7'h22, 8'd2);     // PIN_BASE 2: SDA 2, SCL 3
    reg_write(7'h23, 8'd0);     // JMP_PIN = SDA
    reg_write(7'h24, 8'h03);    // MSB first
    reg_write(7'h25, 8'd0);
    reg_write(7'h03, 8'h0C);    // pins 2, 3 to engine 1
    reg_write(7'h17, 8'h01);    // LINK0: UART bytes to engine 1
    reg_write(7'h27, 8'h01);    // LINK1: replies to engine 0
    reg_write(7'h00, 8'h30);
    reg_write(7'h00, 8'h03);
    repeat (HOST_HALF * 4) @(negedge clk);
    setup_done = 1;
    #(BIT_NS * 4);

    // 1. a write: register 0x10 <- 11 22 33
    s0 = n_start; p0 = n_stop;
    uart_send(8'h57); uart_send(8'hA0); uart_send(8'h04);
    uart_send(8'h10); uart_send(8'h11); uart_send(8'h22); uart_send(8'h33);
    exp_q.push_back(8'h00);
    expect_reply("1 write");
    mem_is(8'h10, 8'h11, "1 write"); mem_is(8'h11, 8'h22, "1 write"); mem_is(8'h12, 8'h33, "1 write");
    check(n_start - s0 == 1 && n_stop - p0 == 1, $sformatf("1 write: %0d STARTs, %0d STOPs", n_start - s0, n_stop - p0));
    $display("1: W A0 [10 11 22 33]: reply 00, registers 10-12 written, one START and one STOP");

    // 2. a read: pointer to 0x10, then 3 bytes
    uart_send(8'h57); uart_send(8'hA0); uart_send(8'h01); uart_send(8'h10);
    exp_q.push_back(8'h00);
    expect_reply("2 set pointer");
    uart_send(8'h52); uart_send(8'hA1); uart_send(8'h03);
    exp_q.push_back(8'h00); exp_q.push_back(8'h11); exp_q.push_back(8'h22); exp_q.push_back(8'h33);
    expect_reply("2 read");
    $display("2: W A0 [10], R A1 3: reply 00 11 22 33");

    // 3. address NACK, write with data (dropped) and read
    s0 = n_start;
    uart_send(8'h57); uart_send(8'hA4); uart_send(8'h02); uart_send(8'hDE); uart_send(8'hAD);
    exp_q.push_back(8'h01);
    expect_reply("3 write to 0x52 (absent)");
    uart_send(8'h52); uart_send(8'hA5); uart_send(8'h04);
    exp_q.push_back(8'h01);
    expect_reply("3 read from 0x52 (absent)");
    check(n_start - s0 == 2, $sformatf("3: %0d STARTs, expected 2", n_start - s0));
    $display("3: an absent address: reply 01 for a write (its 2 bytes dropped) and a read");

    // 4. data NACK in the middle: 0xEF stored, 0xF0 NACKed, the last byte dropped
    uart_send(8'h57); uart_send(8'hA0); uart_send(8'h04);
    uart_send(8'hEF); uart_send(8'h55); uart_send(8'h66); uart_send(8'h77);
    exp_q.push_back(8'h02);
    expect_reply("4 data NACK");
    mem_is(8'hEF, 8'h55, "4 data NACK");
    mem_is(8'hF0, 8'hF0 ^ 8'h5A, "4 data NACK (protected)");
    mem_is(8'hF1, 8'hF1 ^ 8'h5A, "4 data NACK (dropped)");
    $display("4: W A0 [EF 55 66 77]: 55 stored, 66 NACKed (protected), 77 dropped: reply 02");

    // 5. probes, a read of 0 bytes, an unknown command
    uart_send(8'h57); uart_send(8'hA0); uart_send(8'h00);
    exp_q.push_back(8'h00);
    expect_reply("5 probe 0x50");
    uart_send(8'h57); uart_send(8'hA2); uart_send(8'h00);
    exp_q.push_back(8'h01);
    expect_reply("5 probe 0x51");
    uart_send(8'h52); uart_send(8'hA1); uart_send(8'h00);
    exp_q.push_back(8'h00);
    expect_reply("5 read 0 bytes");
    uart_send(8'h99);
    exp_q.push_back(8'hFF);
    expect_reply("5 unknown command");
    $display("5: probes (00, 01), a read of 0 bytes (00), an unknown command (FF)");

    // 6. a 12-byte write and an 8-byte read of it
    uart_send(8'h57); uart_send(8'hA0); uart_send(8'h0C); uart_send(8'h40);
    for (int i = 0; i < 11; i++) uart_send(8'(8'hC0 + i * 3));
    exp_q.push_back(8'h00);
    expect_reply("6 write 12");
    uart_send(8'h57); uart_send(8'hA0); uart_send(8'h01); uart_send(8'h42);
    exp_q.push_back(8'h00);
    expect_reply("6 set pointer");
    uart_send(8'h52); uart_send(8'hA1); uart_send(8'h08);
    exp_q.push_back(8'h00);
    for (int i = 2; i < 10; i++) exp_q.push_back(8'(8'hC0 + i * 3));
    expect_reply("6 read 8");
    $display("6: a 12-byte write, then an 8-byte read of it from register 42");

    // 7. a command typed slowly (gaps of 30 bit times between its bytes): the controller holds
    // SCL low between them; then the next command right after the reply, with no gap
    uart_send(8'h57); #(BIT_NS * 30); uart_send(8'hA0); #(BIT_NS * 30); uart_send(8'h02);
    #(BIT_NS * 30); uart_send(8'h20); #(BIT_NS * 30); uart_send(8'h9C);
    while (uart_got.size() == 0) #(BIT_NS / 4);
    check(uart_got[0] == 8'h00, $sformatf("7 slow write: reply %02x", uart_got[0]));
    uart_got.delete();
    uart_send(8'h57); uart_send(8'hA0); uart_send(8'h01); uart_send(8'h20);
    exp_q.push_back(8'h00);
    expect_reply("7 pointer, sent as the reply ended");
    uart_send(8'h52); uart_send(8'hA1); uart_send(8'h01);
    exp_q.push_back(8'h00); exp_q.push_back(8'h9C);
    expect_reply("7 read back");
    mem_is(8'h20, 8'h9C, "7 slow write");
    $display("7: a command typed slowly (SCL held low between its bytes), the next sent as its reply ended");

    check(frame_errors == 0, $sformatf("UART: %0d framing errors", frame_errors));
    check(host_after == 0, $sformatf("the host made %0d transactions after setup", host_after));
    check(n_stretch > 0, "I2C: the target never stretched SCL");
    check(min_low >= 1300.0, $sformatf("I2C: SCL low %0.0f ns < 1.3 us", min_low));
    check(min_high >= 600.0, $sformatf("I2C: SCL high %0.0f ns < 0.6 us", min_high));
    $display("I2C: %0d STARTs, %0d STOPs, %0d stretches, SCL low >= %0.0f ns, high >= %0.0f ns; no host transaction after setup",
             n_start, n_stop, n_stretch, min_low, min_high);
    if (errors == 0) begin
      $display("PASS: UART <-> I2C bridge");
      $finish;
    end else $fatal(1, "FAILED with %0d error(s)", errors);
  end
  initial begin
    #500ms;
    $fatal(1, "FAILED: timeout");
  end
endmodule
