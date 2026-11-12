`timescale 1ns / 1ps
// A PS/2 device (keyboard), written from the PS/2 protocol description (IBM PS/2 Technical
// Reference; the widely used summary by A. Chapweske), not from ps2_host.pbe. D84.
//
// Both lines are open-collector: the model only pulls them low (clk_low, dat_low); the testbench
// adds the pull-ups. The device generates the clock: HALF_US low and HALF_US high (40 us:
// 12.5 kHz, inside the 10-16.7 kHz range).
//   Device to host: start (0), 8 data LSB first, odd parity, stop (1). DATA changes in the middle
//     of the clock-high phase, so it is stable 20 us before and after each falling edge. A frame
//     starts only when CLK has been high for at least 50 us (the host is not inhibiting).
//   Host to device: the host holds CLK low for >= 100 us, pulls DATA low (request to send) and
//     releases CLK. The device then generates 11 clock pulses: it samples DATA at the rising edge
//     of pulses 1..10 (8 data, parity, stop), and for pulse 11 it pulls DATA low (ACK) before
//     the falling edge, and releases it after the rising edge.
// Behaviour (a keyboard, scan code set 2): every received byte with good parity and stop bit is
// answered with 0xFA, except 0xEE (echo: 0xEE). 0xED takes the next byte as the LED state.
// 0xFF (reset) adds 0xAA (self-test passed); 0xF2 (read ID) adds 0xAB 0x83.
// A byte with a bad parity bit is answered with 0xFE (resend).
// Checks: the host changes DATA only while CLK is low during host-to-device frames; the
// inhibit lasted >= 100 us; the host never pulls CLK low while the device is dev_clocking.
module ps2_dev #(
    parameter real HALF_US = 40.0
) (
    input  wire clk_line,
    input  wire dat_line,
    output logic clk_low = 0,
    output logic dat_low = 0
);
  localparam real HALF = HALF_US * 1000.0;  // ns

  // ---- statistics and test hooks ----
  int  n_rx = 0, n_tx = 0, n_errors = 0;
  int  n_rts = 0;
  logic [7:0] rx_log[$];     // bytes received from the host
  logic [7:0] leds = 0;
  bit  mute = 0;             // ignore a request to send (no clocks: the host must time out)
  bit  bad_parity_next = 0;  // the next byte sent has the wrong parity bit
  bit  bad_stop_next = 0;    // the next byte sent has a 0 stop bit
  bit  no_ack_next = 0;      // do not acknowledge the next host byte
  logic [7:0] tx_q[$];       // bytes to send to the host
  bit  dev_clocking = 0;         // the device is generating the clock

  task automatic err(input string s);
    n_errors++;
    $display("  PS/2 device: %s at %0t", s, $time);
  endtask

  // ---- request-to-send detection: CLK held low by the host ----
  // A falling edge the device did not make is the host's (inhibit); the rising edge that ends
  // it with DATA low is a request to send.
  realtime clk_fell = 0, inhibit = 0;
  bit rts = 0, host_low = 0;
  always @(negedge clk_line)
    if (!clk_low) begin
      host_low = 1;
      clk_fell = $realtime;
    end
  always @(posedge clk_line)
    if (host_low) begin
      host_low = 0;
      inhibit = $realtime - clk_fell;
      if (!dat_line) begin
        if (inhibit < 100_000.0) err($sformatf("request to send after only %0.1f us of inhibit", inhibit / 1000));
        rts = 1;
      end
    end
  // the host must not pull CLK low while the device clocks
  always @(negedge clk_line) if (dev_clocking && !clk_low) err("the host pulled CLK low while the device was dev_clocking");

  // ---- host-to-device DATA changes must happen while CLK is low ----
  bit rx_on = 0;
  always @(dat_line) if (rx_on && clk_line && !dat_low) err("the host changed DATA while CLK was high");

  // ---- one clock pulse: low HALF, high HALF ----
  task automatic pulse_low;
    clk_low = 1;
    #(HALF);
  endtask
  task automatic pulse_high;
    clk_low = 0;
    #(HALF);
  endtask

  // ---- device to host ----
  task automatic send(input logic [7:0] b);
    logic [10:0] f;
    f = {1'b1, ~^b, b, 1'b0};  // stop, odd parity, data, start
    if (bad_parity_next) f[9] = ~f[9];
    if (bad_stop_next) f[10] = 1'b0;
    bad_parity_next = 0;
    bad_stop_next = 0;
    dev_clocking = 1;
    for (int i = 0; i < 11; i++) begin
      dat_low = !f[i];          // mid-way through the high phase
      #(HALF / 2);
      pulse_low;
      clk_low = 0;
      if (i == 10) dev_clocking = 0;  // the last clock pulse is over
      #(HALF / 2);
    end
    dat_low = 0;
    n_tx++;
  endtask

  // ---- host to device ----
  task automatic receive;
    logic [9:0] f;
    bit ack;
    n_rts++;
    rts = 0;
    #(HALF);                    // the device notices the request
    dev_clocking = 1;
    rx_on = 1;
    for (int i = 0; i < 10; i++) begin
      pulse_low;
      clk_low = 0;
      #1;
      f[i] = dat_line;          // sampled as CLK rises
      #(HALF - 1);
    end
    rx_on = 0;
    ack = !no_ack_next && f[9];
    no_ack_next = 0;
    #(HALF / 2);
    dat_low = ack;              // ACK: DATA low for pulse 11
    #(HALF / 2);
    pulse_low;
    clk_low = 0;
    dev_clocking = 0;           // the last clock pulse is over
    #(HALF / 2);
    dat_low = 0;
    #(HALF / 2);
    if (!f[9]) err("stop bit 0 from the host");
    n_rx++;
    rx_log.push_back(f[7:0]);
    if (^f[8:0] != 1'b1) tx_q.push_back(8'hFE);   // bad parity: resend
    else respond(f[7:0]);
  endtask

  bit led_next = 0;
  task automatic respond(input logic [7:0] b);
    if (led_next) begin
      leds = b;
      led_next = 0;
      tx_q.push_back(8'hFA);
    end else case (b)
      8'hEE: tx_q.push_back(8'hEE);
      8'hED: begin tx_q.push_back(8'hFA); led_next = 1; end
      8'hFF: begin tx_q.push_back(8'hFA); tx_q.push_back(8'hAA); end
      8'hF2: begin tx_q.push_back(8'hFA); tx_q.push_back(8'hAB); tx_q.push_back(8'h83); end
      default: tx_q.push_back(8'hFA);
    endcase
  endtask

  // ---- main loop: a request to send wins; otherwise send when CLK has been idle 50 us ----
  realtime high_since = 0;
  always @(posedge clk_line) high_since = $realtime;
  initial begin
    forever begin
      #1000;
      if (rts) begin
        if (mute) rts = 0;
        else receive;
      end else if (tx_q.size() && clk_line && dat_line && $realtime - high_since >= 50_000.0) begin
        logic [7:0] b;
        b = tx_q.pop_front();
        send(b);
        #(2 * HALF);            // a gap between bytes
      end
    end
  end
endmodule
