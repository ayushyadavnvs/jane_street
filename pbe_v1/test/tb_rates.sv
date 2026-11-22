`timescale 1ns / 1ps
// Blind generality benchmark, step 3: the existing UART and I2C controller programs at other
// rates, with no change to the programs (only CLKDIV), against models written from the
// standards.
//   UART: uart_tx.pbe (engine 0, TX = pin 0) and uart_rx.pbe (engine 1, RX = pin 6) at 9600 and
//         115200 baud. A receiver model samples TX mid-bit at exactly the baud rate and checks
//         the stop bit and every edge against the bit grid; a transmitter model sends at the
//         nominal rate and 2 % fast and slow.
//   I2C:  i2c_ctrl.pbe (engine 1, SDA = pin 4, SCL = pin 5, pull-ups) at 100 kHz (CLKDIV 85)
//         and 400 kHz (CLKDIV 21) against an I2C target (address 0x50, a 16-byte memory with a
//         pointer) that measures SCL low, high and period against the standard-mode and
//         fast-mode limits (UM10204 table 10) and counts the START and STOP conditions (any
//         other SDA change while SCL is high would be counted as one).
module tb_rates;
  localparam real CLK_NS = 16.6672;  // 60 MHz
  localparam int HOST_HALF = 4;

  logic clk = 0, rst_n = 0;
  always #(CLK_NS / 2) clk = ~clk;
  logic [7:0] ui_in = 8'b0000_0010;
  wire  [7:0] uo_out, uio_out, uio_oe;
  logic u_rx = 1;                    // the UART model's transmitter -> pin 6
  logic t_sda = 1;                   // the I2C target's SDA driver (0 = pull low)
  wire  [7:0] chip = (uio_oe & uio_out) | ~uio_oe;   // released pins are pulled up
  wire  sda = chip[4] & t_sda;
  wire  scl = chip[5];
  wire  [7:0] bus = {chip[7], u_rx, scl, sda, chip[3:0]};
  tt_um_ayushyadavnvs_pbe dut (.ui_in, .uo_out, .uio_in(bus), .uio_out, .uio_oe, .ena(1'b1), .clk, .rst_n);
  `include "tb_host.svh"

  int pass = 0;
  task automatic result(input string name, input bit ok);
    check(ok, name);
    if (ok) pass++;
    $display("  RATE %-64s %s", name, ok ? "PASS" : "FAIL");
  endtask

  // ================= UART =================
  real bit_ns = 104166.7;
  logic [7:0] urx[$];
  int u_frame_err = 0;
  real u_edge_err = 0;
  realtime u_t0 = 0;
  bit u_in_frame = 0;
  always @(bus[0]) if (u_in_frame) begin
    real k, e;
    k = ($realtime - u_t0) / bit_ns;
    e = (k - $floor(k + 0.5));
    if (e < 0) e = -e;
    if (e > u_edge_err) u_edge_err = e;
  end
  initial forever begin
    logic [7:0] d;
    @(negedge bus[0]);
    if (rst_n) begin
      u_t0 = $realtime;
      u_in_frame = 1;
      #(bit_ns * 1.5);
      for (int i = 0; i < 8; i++) begin
        d[i] = bus[0];
        #(bit_ns);
      end
      u_in_frame = 0;
      if (!bus[0]) u_frame_err++;
      urx.push_back(d);
    end
  end
  task automatic u_send(input logic [7:0] b, input real k);
    u_rx = 0;
    #(bit_ns * k);
    for (int i = 0; i < 8; i++) begin
      u_rx = b[i];
      #(bit_ns * k);
    end
    u_rx = 1;
    #(bit_ns * k);
  endtask

  task automatic uart_test(input int baud);
    int dtx, drx;
    logic [7:0] v[10], x;
    bit ok;
    real k;
    bit_ns = 1.0e9 / baud;
    dtx = $rtoi(60.0e6 / (2.0 * baud) + 0.5) - 1;
    drx = $rtoi(60.0e6 / (4.0 * baud) + 0.5) - 1;
    reg_write(7'h00, 8'b1100_0000);
    reg_write(7'h03, 8'hF0);
    reg_write(7'h10, 8'(dtx));
    reg_write(7'h11, 8'(dtx >> 8));
    reg_write(7'h12, 8'd0);
    reg_write(7'h14, 8'h00);
    reg_write(7'h15, 8'd0);
    reg_write(7'h1E, 8'h40);
    reg_write(7'h20, 8'(drx));
    reg_write(7'h21, 8'(drx >> 8));
    reg_write(7'h22, 8'd6);           // RX = pin 6
    reg_write(7'h23, 8'd0);
    reg_write(7'h24, 8'h00);
    reg_write(7'h25, 8'd8);           // uart_rx is at word 8 of engine 1's memory
    reg_write(7'h2C, 8'd0);
    reg_write(7'h2D, 8'd0);
    reg_write(7'h2E, 8'h40);
    reg_write(7'h00, 8'b0011_0011);
    repeat (300) @(posedge clk);
    v[0] = 8'h00; v[1] = 8'hFF; v[2] = 8'h55; v[3] = 8'hAA; v[4] = 8'h80; v[5] = 8'h01;
    for (int i = 6; i < 10; i++) v[i] = 8'($urandom);
    // transmit
    urx = {};
    u_frame_err = 0;
    u_edge_err = 0;
    for (int i = 0; i < 10; i++) fifo_send(0, v[i]);
    wait_tx_empty(0);
    #(bit_ns * 12);
    ok = urx.size() == 10 && u_frame_err == 0;
    for (int i = 0; i < 10 && i < urx.size(); i++) begin
      x = urx[i];
      ok &= x === v[i];
    end
    result($sformatf("UART TX %0d baud (CLKDIV %0d): 10 bytes, worst edge %0.1f %% of a bit off the grid",
                     baud, dtx, u_edge_err * 100), ok && u_edge_err < 0.03);
    // receive: nominal, 2 % fast, 2 % slow
    ok = 1;
    for (int r = 0; r < 3; r++) begin
      k = (r == 0) ? 1.0 : (r == 1) ? 0.98 : 1.02;
      for (int i = 0; i < 10; i++) begin
        u_send(v[i], k);
        fifo_recv(1, x);
        if (x !== v[i]) begin
          ok = 0;
          $display("    rate x%0.2f byte %0d: %02x, sent %02x", k, i, x, v[i]);
        end
      end
    end
    result($sformatf("UART RX %0d baud (CLKDIV %0d): 30 bytes at the nominal rate and 2 %% off", baud, drx), ok);
  endtask

  // ================= I2C target =================
  logic [7:0] mem[16];
  logic [3:0] ptr = 0;
  int tb_bits = 0, tstate = 0;      // tstate: 0 idle, 1 address, 2 pointer, 3 write data, 4 read data
  logic [7:0] tsh, t_out;           // bits shifted in; the byte being read out
  bit t_ack_next = 0, t_rd = 0, t_first = 0, t_mine = 0;
  int n_start = 0, n_stop = 0;
  real scl_per = 1e9, scl_lo = 1e9, scl_hi = 1e9;
  realtime ts_r = 0, ts_f = 0;
  bit i2c_on = 0;
  always @(negedge sda) if (i2c_on && scl) begin          // START
    n_start++;
    tstate = 1;
    tb_bits = 0;
    t_sda = 1;
  end
  always @(posedge sda) if (i2c_on && scl) begin          // STOP
    n_stop++;
    tstate = 0;
    t_sda = 1;
  end
  always @(posedge scl) if (i2c_on) begin
    if (ts_r > 0 && $realtime - ts_r < scl_per) scl_per = $realtime - ts_r;
    if (ts_f > 0 && $realtime - ts_f < scl_lo) scl_lo = $realtime - ts_f;
    ts_r = $realtime;
    if (tstate != 0) begin
      if (tb_bits < 8) begin
        tsh = {tsh[6:0], sda};
        tb_bits++;
      end else begin                                       // the 9th clock: the ACK bit
        if (tstate == 4 && sda) tstate = 0;                // the controller NACKed: no more data
        tb_bits = 0;
      end
    end
  end
  always @(negedge scl) if (i2c_on) begin
    if ($realtime - ts_r < scl_hi) scl_hi = $realtime - ts_r;
    ts_f = $realtime;
    #300;                                                  // the target's data hold / valid time
    t_sda = 1;
    if (tstate != 0) begin
      if (tb_bits == 8) begin                              // a byte is in: ACK it (or not)
        case (tstate)
          1: begin
            t_mine = tsh[7:1] == 7'h50;
            t_rd = tsh[0];
            if (t_mine) begin
              t_sda = 0;
              tstate = t_rd ? 4 : 2;
            end else tstate = 0;
          end
          2: begin ptr = tsh[3:0]; t_sda = 0; tstate = 3; end
          3: begin mem[ptr] = tsh; ptr++; t_sda = 0; end
          default: ;                                       // read: the controller drives the ACK
        endcase
      end else if (tstate == 4) begin                      // read: the next data bit
        if (tb_bits == 0) t_out = mem[ptr];
        t_sda = t_out[7 - tb_bits];
        if (tb_bits == 7) ptr++;
      end
    end
  end
  // The controller's SDA may change while SCL is high only to make a START or a STOP: both are
  // counted, and the transfers below contain exactly 8 STARTs and 6 STOPs.

  task automatic i2c_cond(input bit start, input bit stop);
    bit b;
    wait_tx_empty(1);
    if (start) flag_set(1, 0);
    if (stop) begin
      flag_set(1, 1);
      do flag_get(1, 1, b); while (b);
    end
  endtask
  task automatic i2c_xfer(input logic [7:0] data, input logic [7:0] ack_out,
                          output logic [7:0] seen, output logic [7:0] ack_in);
    fifo_send(1, data);
    fifo_send(1, ack_out);
    fifo_recv(1, seen);
    fifo_recv(1, ack_in);
  endtask

  task automatic i2c_test(input int div, input real per_min, input real lo_min, input real hi_min, input string what);
    logic [7:0] s, a, d[3];
    bit ok;
    reg_write(7'h00, 8'b1100_0000);
    reg_write(7'h03, 8'hF0);
    reg_write(7'h04, 8'h00);
    reg_write(7'h20, 8'(div));
    reg_write(7'h21, 8'd0);
    reg_write(7'h22, 8'd4);
    reg_write(7'h23, 8'd0);
    reg_write(7'h24, 8'h03);          // MSB first
    reg_write(7'h25, 8'd8);           // i2c_ctrl is at word 8 of engine 1's memory
    reg_write(7'h2B, 8'h00);
    reg_write(7'h2C, 8'd0);
    reg_write(7'h2D, 8'd0);
    reg_write(7'h2E, 8'h40);
    reg_write(7'h00, 8'b0010_0010);   // engine 1 only
    repeat (500) @(posedge clk);
    i2c_on = 1;
    scl_per = 1e9; scl_lo = 1e9; scl_hi = 1e9; ts_r = 0; ts_f = 0;
    for (int i = 0; i < 3; i++) d[i] = 8'($urandom);
    // write 3 bytes at pointer 5
    ok = 1;
    i2c_cond(1, 0);
    i2c_xfer(8'hA0, 8'h80, s, a);  ok &= a == 8'h00;
    i2c_xfer(8'h05, 8'h80, s, a);  ok &= a == 8'h00;
    for (int i = 0; i < 3; i++) begin
      i2c_xfer(d[i], 8'h80, s, a);
      ok &= a == 8'h00 && s == d[i];
    end
    i2c_cond(0, 1);
    ok &= mem[5] == d[0] && mem[6] == d[1] && mem[7] == d[2];
    // set the pointer, repeated START, read them back (ACK, ACK, NACK)
    i2c_cond(1, 0);
    i2c_xfer(8'hA0, 8'h80, s, a);  ok &= a == 8'h00;
    i2c_xfer(8'h05, 8'h80, s, a);  ok &= a == 8'h00;
    i2c_cond(1, 0);
    i2c_xfer(8'hA1, 8'h80, s, a);  ok &= a == 8'h00;
    for (int i = 0; i < 3; i++) begin
      i2c_xfer(8'hFF, i == 2 ? 8'h80 : 8'h00, s, a);
      if (s !== d[i]) begin
        ok = 0;
        $display("    read %02x, expected %02x", s, d[i]);
      end
    end
    i2c_cond(0, 1);
    // an address nobody has: NACK
    i2c_cond(1, 0);
    i2c_xfer(8'h66, 8'h80, s, a);  ok &= a != 8'h00;
    i2c_cond(0, 1);
    repeat (200) @(posedge clk);
    i2c_on = 0;
    result($sformatf("I2C %s (CLKDIV %0d): write 3, read back 3, NACK; SCL %0.1f kHz, low %0.2f us, high %0.2f us",
                     what, div, 1.0e6 / scl_per, scl_lo / 1000, scl_hi / 1000),
           ok && scl_per >= per_min && scl_lo >= lo_min && scl_hi >= hi_min && scl_per < per_min * 1.1);
  endtask

  initial begin
    repeat (5) @(posedge clk);
    @(negedge clk) rst_n = 1;
    repeat (5) @(posedge clk);
    load_program("uart_image.hex");
    uart_test(9600);
    uart_test(115200);
    load_program("mixed_image.hex");
    i2c_test(85, 10000.0, 4700.0, 4000.0, "standard mode, 100 kHz");
    i2c_test(21, 2500.0, 1300.0, 600.0, "fast mode, 400 kHz");
    check(n_start == 8 && n_stop == 6, $sformatf("the target saw %0d STARTs and %0d STOPs", n_start, n_stop));
    if (errors == 0 && pass == 6) begin
      $display("PASS: UART and I2C rates");
      $finish;
    end else $fatal(1, "FAILED with %0d error(s)", errors);
  end
  initial begin
    #2000ms;
    $fatal(1, "FAILED: timeout");
  end
endmodule
