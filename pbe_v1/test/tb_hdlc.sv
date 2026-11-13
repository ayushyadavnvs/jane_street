`timescale 1ns / 1ps
// End-to-end test of HDLC/SDLC (NRZ and NRZI): hdlc_tx.pbe on engine 0 (TXD = pin 0) and hdlc_rx.pbe on
// engine 1 (RXD = pin 4), D88, against an HDLC line model written from ISO/IEC 13239
// (hdlc_model.sv): the model receives what the chip sends and sends what the chip receives.
// Frames: data containing 0x7E, 0x7D and runs of five and more 1s (0xFF, 0x3E, 0x7C, 0xF8,
// 0x1F), back-to-back frames (shared flags), several flags between frames, a 1-byte and a
// 64-byte frame (more than the FIFOs); the model's transmitter runs 0.5 % off the chip's rate.
// Received side: a CRC error and aborts (followed by idle, and directly by a flag) must be
// reported; good frames must come through exactly. Rates at 60 MHz: 1.25 Mbit/s (CLKDIV 47)
// and 2.5 Mbit/s (CLKDIV 23) both ways, 5 Mbit/s (CLKDIV 11) transmit only; NRZ, then the
// first two in NRZI (D94: flags sent unstuffed with LINECTL, the receiver flag-delimited).
module tb_hdlc;
  localparam real CLK_NS = 16.6672;  // 60 MHz
  localparam real CLK_SIM = 16.668;  // the simulated period (the half period rounds to 1 ps)
  localparam int HOST_HALF = 4;      // host SCK = clk / 8

  logic clk = 0, rst_n = 0;
  always #(CLK_NS / 2) clk = ~clk;

  logic [7:0] ui_in = 8'b0000_0010;
  wire  [7:0] uo_out, uio_out, uio_oe;
  wire  m_line;
  // TXD (pin 0) is driven by the chip (pulled up while released); RXD (pin 4) by the model
  wire  [7:0] bus = {3'b000, m_line, 3'b000, !uio_oe[0] | uio_out[0]};

  tt_um_ayushyadavnvs_pbe dut (
      .ui_in, .uo_out, .uio_in(bus), .uio_out, .uio_oe, .ena(1'b1), .clk, .rst_n
  );

  // the model; its bit times are set per phase (see `rate`)
  hdlc_model u_m (.line(m_line), .rx_line(bus[0]));

  `include "tb_host.svh"

  int pass = 0;
  task automatic result(input string name, input bit ok);
    check(ok, name);
    if (ok) pass++;
    $display("  HDLC %s %-62s %s", nrzi ? "NRZI" : "NRZ ", name, ok ? "PASS" : "FAIL");
  endtask

  // ---------------- set-up ----------------
  bit nrzi = 0;  // the coding of the phases that follow (D94)
  task automatic setup(input int div);
    int p, d;
    p = div + 1;
    reg_write(7'h00, 8'b1100_0000);          // stop both, flush
    reg_write(7'h03, 8'hF0);                 // pins 4..7 to engine 1
    for (int e = 0; e < 2; e++) begin
      logic [6:0] b, b2;
      b = e ? 7'h20 : 7'h10;
      b2 = e ? 7'h40 : 7'h30;
      reg_write(b + 0, 8'(div));
      reg_write(b + 1, 8'(div >> 8));
      reg_write(b + 2, e ? 8'd4 : 8'd0);     // pin base
      reg_write(b + 3, 8'd0);                // JMP_PIN = pin base (RXD for engine 1)
      reg_write(b + 4, 8'h00);               // LSB first
      reg_write(b + 5, 8'd0);
      reg_write(b + 9, 8'h21);               // CRC_POLY 0x1021
      reg_write(b + 'hA, 8'h10);
      reg_write(b + 'hB, e ? 8'h9F : 8'h7F); // RX: fed by IN; TX: fed by OUT, reflected output
      reg_write(b + 'hC, 8'h00);
      reg_write(b + 'hD, 8'h00);
      reg_write(b + 'hE, 8'h40);             // no parity
      reg_write(b + 'hF, 8'h0F);             // clear status
      // LINE: NRZ (1) or NRZI (2), stuff after 5 ones, bits; the receiver flag-delimited (D94)
      reg_write(b2 + 0, (nrzi ? 8'h0A : 8'h09) | (e ? 8'h40 : 8'h00));
      reg_write(b2 + 1, 8'h00);              // no SYNC
      reg_write(b2 + 2, e ? 8'hF9 : 8'h00);  // CRC_GOOD 0xD0F9 (RX)
      reg_write(b2 + 3, e ? 8'hD0 : 8'h00);
      reg_write(b2 + 4, 8'h00);              // LINE2
    end
    reg_write(7'h00, 8'b0011_0011);          // restart and run both
  endtask

  // ---------------- transmit: chip -> model ----------------
  logic [7:0] fr[$];                         // the frame being built
  task automatic chip_send;                  // queue fr as one frame on engine 0
    logic [7:0] x;
    cs(0);
    spi_byte({1'b1, 7'h16}, x);
    while (uo_out[6]) @(negedge clk);
    spi_byte(8'(fr.size() - 1), x);
    foreach (fr[i]) begin
      while (uo_out[6]) @(negedge clk);
      spi_byte(fr[i], x);
    end
    cs(1);
  endtask

  // ---------------- receive: model -> chip ----------------
  // Read engine 1's RX FIFO, splitting frames at [7E][status] (7E 7E is a data 0x7E), until n
  // frames have arrived: c_data (bytes back to back), c_len, c_status.
  logic [7:0] c_data[$];
  int c_len[$], c_status[$];
  int c_cur = 0;
  bit esc = 0;
  task automatic chip_frames(input int n, input longint max_clocks);
    logic [7:0] c, d;
    longint t = 0;
    while (c_len.size() < n && t < max_clocks) begin
      reg_read(7'h0B, c);                    // engine 1's RX_COUNT
      if (c != 0) begin
        cs(0);
        spi_byte({1'b0, 7'h26}, d);
        for (int i = 0; i < c; i++) begin
          spi_byte(8'h00, d);
          if (esc) begin
            esc = 0;
            if (d == 8'h7E) begin
              c_data.push_back(8'h7E);
              c_cur++;
            end else begin
              c_len.push_back(c_cur);
              c_status.push_back(d);
              c_cur = 0;
            end
          end else if (d == 8'h7E) esc = 1;
          else begin
            c_data.push_back(d);
            c_cur++;
          end
        end
        cs(1);
      end
      repeat (20) @(posedge clk);
      t += 300;
    end
  endtask

  // frames to send from the model: their bytes are remembered for the check
  logic [7:0] sent[$];
  int sent_len[$];
  task automatic model_frame(input bit bad, input int abort_after, input int flags, input bit share);
    foreach (fr[i]) begin
      u_m.tx_bytes.push_back(fr[i]);
      sent.push_back(fr[i]);
    end
    sent_len.push_back(fr.size());
    u_m.add_frame(fr.size(), bad, abort_after, flags, share);
  endtask

  // the test frames
  task automatic frame_pattern;      // flag and escape look-alikes, runs of 1s
    fr = {};
    fr.push_back(8'h7E); fr.push_back(8'h7D); fr.push_back(8'hFF); fr.push_back(8'h3E);
    fr.push_back(8'h7C); fr.push_back(8'hF8); fr.push_back(8'h1F); fr.push_back(8'h7E);
    fr.push_back(8'h00); fr.push_back(8'hFE);
  endtask
  task automatic frame_one;
    fr = {};
    fr.push_back(8'h03);
  endtask
  task automatic frame_rand(input int n);
    fr = {};
    for (int i = 0; i < n; i++) fr.push_back(8'($urandom));
    fr[3] = 8'h7E;
  endtask

  // ---------------- chip -> model ----------------
  logic [7:0] exp[$];      // tx_test: the bytes and lengths of the frames sent
  int lens[$];
  int exp_st[$];           // rx_test: the status expected per frame
  string what;
  task automatic tx_test(input int div, input int big);
    int n0, k, bad;
    logic [7:0] st, x;
    n0 = u_m.rx_len.size();
    exp = {};
    lens = {};
    frame_pattern;  foreach (fr[i]) exp.push_back(fr[i]); lens.push_back(fr.size()); chip_send;
    frame_one;      foreach (fr[i]) exp.push_back(fr[i]); lens.push_back(fr.size()); chip_send;
    if (big) begin
      frame_rand(big); foreach (fr[i]) exp.push_back(fr[i]); lens.push_back(fr.size()); chip_send;
    end
    frame_pattern;  foreach (fr[i]) exp.push_back(fr[i]); lens.push_back(fr.size()); chip_send;
    wait_tx_empty(0);
    #(40 * (div + 1) * CLK_SIM * 20);
    bad = 0;
    k = 0;
    // the model's frames: each has its bytes + 2 FCS bytes, verdict good
    for (int f = 0; f < lens.size(); f++) begin
      int base, idx;
      if (n0 + f >= u_m.rx_len.size()) begin
        bad++;
        $display("    frame %0d: not received", f);
      end else begin
        idx = n0 + f;
        base = 0;
        for (int j = 0; j < idx; j++) base += u_m.rx_len[j];
        if (u_m.rx_verdict[idx] != 0 || u_m.rx_len[idx] != lens[f] + 2) begin
          bad++;
          $display("    frame %0d: verdict %0d, %0d bytes (sent %0d + FCS)", f, u_m.rx_verdict[idx], u_m.rx_len[idx], lens[f]);
        end else
          for (int j = 0; j < lens[f]; j++) begin
            x = u_m.rx_data[base + j];
            if (x !== exp[k + j]) bad++;
          end
      end
      k += lens[f];
    end
    reg_read(7'h1F, st);
    if (st[4]) $display("    the transmitter reported a line error (underrun)");
    if (big) what = $sformatf(", one of %0d bytes", big);
    else what = "";
    result($sformatf("TX, CLKDIV %0d: %0d frames back to back%s: good at the model", div, lens.size(), what),
           bad == 0 && u_m.rx_len.size() == n0 + lens.size() && !st[4]);
  endtask

  // ---------------- model -> chip ----------------
  // expected status per frame: 0x02 good, 0x00 CRC error, 0x40 abort
  task automatic rx_test(input int div, input bit full);
    int n0, k, bad, base;
    logic [7:0] x;
    n0 = c_len.size();
    exp_st = {};
    sent = {};
    sent_len = {};
    frame_pattern;  model_frame(0, -1, 0, 0); exp_st.push_back(8'h02);
    frame_one;      model_frame(0, -1, 0, 1); exp_st.push_back(8'h02);   // shared flag
    frame_pattern;  model_frame(1, -1, 0, 1); exp_st.push_back(8'h00);   // CRC error
    frame_rand(6);  model_frame(0, 3, 0, 0);  exp_st.push_back(8'h40);   // abort, then idle
    if (full) begin
      frame_one;     model_frame(0, -1, 2, 0); exp_st.push_back(8'h02);  // 3 flags before
      frame_rand(5); model_frame(0, 2, 0, 0);  exp_st.push_back(8'h40);  // abort ...
      frame_rand(64); model_frame(0, -1, 0, 1); exp_st.push_back(8'h02); // ... then a flag at once
    end
    frame_pattern;  model_frame(0, -1, 0, 0); exp_st.push_back(8'h02);
    chip_frames(n0 + exp_st.size(), 64'd4_000_000);
    bad = 0;
    k = 0;
    base = 0;
    for (int j = 0; j < n0; j++) base += c_len[j];
    for (int f = 0; f < exp_st.size(); f++) begin
      if (n0 + f >= c_len.size()) begin
        bad++;
        $display("    frame %0d: not received", f);
      end else begin
        if (c_status[n0 + f] != exp_st[f]) begin
          bad++;
          $display("    frame %0d: status %02x, expected %02x (%0d bytes)", f, c_status[n0 + f], exp_st[f], c_len[n0 + f]);
        end else if (exp_st[f] == 8'h02) begin
          if (c_len[n0 + f] != sent_len[f] + 2) begin
            bad++;
            $display("    frame %0d: %0d bytes, sent %0d + FCS", f, c_len[n0 + f], sent_len[f]);
          end else
            for (int j = 0; j < sent_len[f]; j++) begin
              x = c_data[base + j];
              if (x !== sent[k + j]) bad++;
            end
        end
        base += c_len[n0 + f];
      end
      k += sent_len[f];
    end
    if (full) what = ", 3 flags, 64 bytes";
    else what = "";
    result($sformatf("RX, CLKDIV %0d: %0d frames: good, shared flags, CRC error, aborts%s", div, exp_st.size(), what),
           bad == 0 && c_len.size() == n0 + exp_st.size());
  endtask

  task automatic rate(input int div);
    u_m.NRZI = nrzi;
    u_m.BIT_NS = (div + 1) * CLK_SIM * 1.005;   // the model's transmitter: 0.5 % slow
    u_m.RX_BIT_NS = (div + 1) * CLK_SIM;
    setup(div);
    repeat (200) @(posedge clk);
  endtask

  initial begin
    repeat (5) @(posedge clk);
    @(negedge clk) rst_n = 1;
    repeat (5) @(posedge clk);
    load_program("hdlc_image.hex");

    rate(47);                 // 1 Mbit/s
    tx_test(47, 64);
    rx_test(47, 1);
    rate(23);                 // 2 Mbit/s
    tx_test(23, 0);
    rx_test(23, 0);
    rate(11);                 // 5 Mbit/s: transmit
    tx_test(11, 40);
    nrzi = 1;                 // the same in NRZI (D94)
    rate(47);
    tx_test(47, 64);
    rx_test(47, 1);
    rate(23);
    tx_test(23, 0);
    rx_test(23, 0);

    $display("  model: %0d flags, %0d aborts seen on the chip's TXD", u_m.n_flags, u_m.n_aborts);
    check(u_m.n_aborts == 0, "the chip's transmitter sent an abort");
    if (errors == 0 && pass == 9) begin
      $display("PASS: HDLC");
      $finish;
    end else $fatal(1, "FAILED with %0d error(s)", errors);
  end

  initial begin
    #200ms;
    $fatal(1, "FAILED: timeout");
  end
endmodule
