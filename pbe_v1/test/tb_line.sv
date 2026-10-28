`timescale 1ns / 1ps
// Unit test of the line coder (pbe_line) against reference encoders and decoders written
// here, independently of the RTL.
//
//  A  USB transmit: NRZI, a 0 stuffed after six 1s, pair drive. Checked: 2-bit gap, SYNC
//     KJKJKJKK, every bit exactly one period, the stuffed bits (also one right before EOP),
//     EOP = SE0 SE0 J, then the line is released.
//  B  USB receive from a reference encoder at +1.5 % and -1.5 % clock error (the USB limit for
//     a low-speed device), then a packet with seven 1s in a row: a stuff error.
//  C  Two coders back to back, CAN style (NRZ, stuff after 5 equal bits, single bits) and
//     HDLC style (NRZI, stuff after 5 ones, bytes): what goes in comes out, and the line never
//     holds more than the allowed run.
module tb_line;
  localparam int P = 32;  // clocks per bit (USB low speed at 48 MHz)
  logic clk = 0, rst_n = 0;
  always #10 clk = ~clk;  // 20 ns clock (the period only scales time here)
  int errors = 0;
  task automatic check(input bit ok, input string msg);
    if (!ok) begin
      errors++;
      $display("  FAIL: %s", msg);
    end
  endtask

  // ---- coder under test (u) and a second one for the loopback tests (v) ----
  logic [7:0] cfg_u = 0, cfg_v = 0, sync_u = 0, sync_v = 0;
  logic       a_in = 1, b_in = 0, use_loop = 0;
  logic       put_u = 0, end_u = 0, take_u = 0, put_v = 0, end_v = 0, take_v = 0;
  logic [7:0] data_u = 0, data_v = 0;
  wire        drive_u, ao_u, bo_u, ready_u, rv_u, fe_u, err_u;
  wire        drive_v, ao_v, bo_v, ready_v, rv_v, fe_v, err_v;
  wire [7:0]  rd_u, rd_v;
  wire        line_v = drive_v ? ao_v : 1'b1;  // v transmits into u in the loopback tests

  pbe_line u (
      .clk, .rst_n, .clear(1'b0), .cfg(cfg_u), .sync(sync_u), .period_m1(16'(P - 1)),
      .out_msb_first(1'b0), .in_msb_first(1'b0),
      .a_in(use_loop ? line_v : a_in), .b_in(use_loop ? 1'b0 : b_in),
      .drive(drive_u), .a_out(ao_u), .b_out(bo_u),
      .tx_put(put_u), .tx_end(end_u), .tx_data(data_u), .tx_ready(ready_u),
      .rx_valid(rv_u), .rx_data(rd_u), .rx_take(take_u), .frame_end(fe_u), .err(err_u)
  );
  pbe_line v (
      .clk, .rst_n, .clear(1'b0), .cfg(cfg_v), .sync(sync_v), .period_m1(16'(P - 1)),
      .out_msb_first(1'b0), .in_msb_first(1'b0),
      .a_in(1'b1), .b_in(1'b0),
      .drive(drive_v), .a_out(ao_v), .b_out(bo_v),
      .tx_put(put_v), .tx_end(end_v), .tx_data(data_v), .tx_ready(ready_v),
      .rx_valid(rv_v), .rx_data(rd_v), .rx_take(take_v), .frame_end(fe_v), .err(err_v)
  );

  int n_err_u = 0, n_fe_u = 0;
  always @(posedge clk) begin
    if (err_u) n_err_u++;
    if (fe_u) n_fe_u++;
  end

  // feed one coder: queue a byte (or bit) when it is ready, like the engine does
  task automatic send_u(input logic [7:0] d, input bit is_end);
    @(negedge clk);  // between edges, so tx_ready already shows the last put (BUG-027)
    while (!ready_u) @(negedge clk);
    data_u = d; put_u = !is_end; end_u = is_end;
    @(negedge clk);
    put_u = 0; end_u = 0;
  endtask
  task automatic send_v(input logic [7:0] d, input bit is_end);
    @(negedge clk);  // between edges, so tx_ready already shows the last put (BUG-027)
    while (!ready_v) @(negedge clk);
    data_v = d; put_v = !is_end; end_v = is_end;
    @(negedge clk);
    put_v = 0; end_v = 0;
  endtask

  // collect everything u receives
  logic [7:0] got[$];
  always @(posedge clk) begin
    take_u <= 0;
    if (rv_u && !take_u) begin
      got.push_back(rd_u);
      take_u <= 1;
    end
  end

  // ---- A: watch u's line while it transmits a USB packet ----
  // Line states sampled every clock while driven: 0 = SE0, 1 = J (a high), 2 = K (a low).
  int st_q[$];
  bit watch = 0;
  int t_first = -1, t_put = -1, clk_n = 0;
  always @(posedge clk) begin
    clk_n++;
    if (watch && drive_u) begin
      if (t_first < 0) t_first = clk_n;
      st_q.push_back(!ao_u && !bo_u ? 0 : ao_u && !bo_u ? 1 : !ao_u && bo_u ? 2 : 3);
    end
  end

  // reference USB encoder: bytes (LSB first) -> line states, one per bit, SYNC first, then EOP
  int ref_st[$];
  logic [7:0] enc_in[$];  // the bytes to encode (a queue argument crashes Icarus 12)
  task automatic usb_encode(input bit bad_stuff);
    int lvl, ones;
    bit b;
    logic [7:0] x, all[$];
    ref_st.delete();
    all.push_back(8'h80);
    foreach (enc_in[i]) all.push_back(enc_in[i]);
    lvl = 1;  // J
    ones = 0;
    foreach (all[i])
      for (int k = 0; k < 8; k++) begin
        x = all[i];  // Icarus 12 cannot bit-select a queue element
        b = x[k];
        if (!b) lvl = 3 - lvl;  // NRZI: 0 changes J <-> K (1 <-> 2)
        ref_st.push_back(lvl);
        ones = b ? ones + 1 : 0;
        if (ones == 6 && !bad_stuff) begin
          lvl = 3 - lvl;
          ref_st.push_back(lvl);
          ones = 0;
        end
      end
    ref_st.push_back(0);
    ref_st.push_back(0);
    ref_st.push_back(1);
  endtask

  // drive the line from ref_st with bits stretched by (1 + ppm / 1e6)
  task automatic usb_drive(input real ppm);
    real t_bit = 20.0 * P * (1.0 + ppm / 1.0e6);
    foreach (ref_st[i]) begin
      a_in = ref_st[i] == 1;
      b_in = ref_st[i] == 2;
      #(t_bit);
    end
    a_in = 1;
    b_in = 0;
  endtask

  initial begin
    logic [7:0] pkt[$], seq[$];
    repeat (3) @(posedge clk);
    rst_n = 1;
    repeat (3) @(posedge clk);

    // ===== A: USB transmit =====
    cfg_u = 8'b0011_0110;  // bytes, pair, stuff after 6 ones, NRZI
    sync_u = 8'h80;
    pkt = '{8'hC3, 8'hFF, 8'h3F, 8'h00, 8'h7E, 8'hFF, 8'hFC};  // runs of ones, ends in six 1s
    enc_in = pkt;
    usb_encode(0);
    watch = 1;
    t_put = clk_n + 1;
    foreach (pkt[i]) send_u(pkt[i], 0);
    send_u(8'h00, 1);
    while (drive_u) @(posedge clk);
    repeat (5) @(posedge clk);
    watch = 0;
    check(t_first - t_put >= 2 * P && t_first - t_put <= 2 * P + 4,
          $sformatf("USB TX: gap before the packet is %0d clocks, expected 2 bits (%0d)", t_first - t_put, 2 * P));
    check(st_q.size() == ref_st.size() * P,
          $sformatf("USB TX: driven for %0d clocks, expected %0d bits x %0d", st_q.size(), ref_st.size(), P));
    for (int i = 0; i < ref_st.size() && i * P < st_q.size(); i++)
      for (int c = 0; c < P; c++)
        if (i * P + c < st_q.size() && st_q[i*P+c] != ref_st[i]) begin
          check(0, $sformatf("USB TX: bit %0d clock %0d is state %0d, reference %0d", i, c, st_q[i*P+c], ref_st[i]));
          c = P;
          i = ref_st.size();
        end
    check(!drive_u && n_err_u == 0, "USB TX: line not released, or an error");
    $display("A: USB transmit of %0d bytes: %0d line bits match the reference encoder", pkt.size(), ref_st.size());

    // ===== B: USB receive at +-1.5 % =====
    for (int r = 0; r < 3; r++) begin
      real ppm;
      ppm = r == 0 ? 15000.0 : -15000.0;
      got.delete();
      n_err_u = 0;
      n_fe_u = 0;
      pkt = '{8'h2D, 8'h00, 8'h10, 8'hFF, 8'hFF, 8'h01, 8'h80, 8'h7F, 8'hFE};
      enc_in = pkt;
      usb_encode(r == 2);
      usb_drive(ppm);
      repeat (4 * P) @(posedge clk);
      if (r < 2) begin
        check(got.size() == pkt.size(), $sformatf("USB RX %+0.1f %%: %0d bytes, sent %0d", ppm / 1e4, got.size(), pkt.size()));
        foreach (pkt[i])
          if (i < got.size()) check(got[i] === pkt[i], $sformatf("USB RX %+0.1f %%: byte %0d %02x, sent %02x", ppm / 1e4, i, got[i], pkt[i]));
        check(n_fe_u == 1, $sformatf("USB RX: %0d frame ends", n_fe_u));
        check(n_err_u == 0, $sformatf("USB RX: %0d errors on a good packet", n_err_u));
        $display("B: USB receive at %+0.1f %% clock error: %0d bytes, one frame end", ppm / 1e4, got.size());
      end else begin
        check(n_err_u > 0, "USB RX: seven 1s in a row not reported");
        $display("B: seven 1s in a row (no stuff bit) reported as a stuff error");
      end
    end

    // ===== C1: CAN style, NRZ, stuff after 5 equal bits, single bits =====
    begin
      int run, lvl_prev, maxrun;
      cfg_u = 8'b0000_1101;  // bits, stuff 5 equal, NRZ
      cfg_v = 8'b0000_1101;
      sync_u = 0;
      sync_v = 0;
      use_loop = 1;
      got.delete();
      n_err_u = 0;
      seq.delete();
      seq.push_back(0);  // a start bit
      for (int i = 0; i < 40; i++) seq.push_back(i < 12 ? 0 : i < 20 ? 1 : (i * 7 % 3 == 0));
      fork
        begin
          foreach (seq[i]) send_v(seq[i], 0);
          send_v(0, 1);
        end
        begin  // the line never holds one level for more than 5 bits
          run = 0;
          maxrun = 0;
          lvl_prev = -1;
          @(posedge drive_v);
          repeat (P / 2) @(posedge clk);
          while (drive_v) begin
            run = (ao_v == lvl_prev) ? run + 1 : 1;
            lvl_prev = ao_v;
            if (run > maxrun) maxrun = run;
            repeat (P) @(posedge clk);
          end
        end
      join
      repeat (12 * P) @(posedge clk);
      check(maxrun == 5, $sformatf("CAN-style TX: longest run on the line %0d bits, expected 5", maxrun));
      check(got.size() >= seq.size(), $sformatf("CAN-style RX: %0d bits, sent %0d", got.size(), seq.size()));
      foreach (seq[i])
        if (i < got.size()) check(got[i] === seq[i], $sformatf("CAN-style bit %0d: %0d, sent %0d", i, got[i], seq[i]));
      check(n_err_u == 0, "CAN-style RX: stuff error on a good frame");
      $display("C: CAN style (NRZ, stuff after 5 equal, bits): %0d bits round trip, longest run %0d", seq.size(), maxrun);
    end

    // ===== C2: HDLC style, NRZI, stuff after 5 ones, bytes, sync 0x7E =====
    cfg_u = 8'b0010_1010;  // bytes, stuff 5 ones, NRZI
    cfg_v = 8'b0010_1010;
    sync_u = 8'h7E;
    sync_v = 8'h7E;
    repeat (20 * P) @(posedge clk);
    got.delete();
    n_err_u = 0;
    pkt = '{8'hFF, 8'h1F, 8'hF8, 8'h00, 8'hAA, 8'hFF};
    foreach (pkt[i]) send_v(pkt[i], 0);
    send_v(0, 1);
    while (drive_v) @(posedge clk);
    repeat (12 * P) @(posedge clk);
    check(got.size() == pkt.size(), $sformatf("HDLC-style RX: %0d bytes, sent %0d", got.size(), pkt.size()));
    foreach (pkt[i])
      if (i < got.size()) check(got[i] === pkt[i], $sformatf("HDLC-style byte %0d: %02x, sent %02x", i, got[i], pkt[i]));
    check(n_err_u == 0, "HDLC-style RX: stuff error on a good frame");
    $display("C: HDLC style (NRZI, stuff after 5 ones, bytes): %0d bytes round trip", got.size());

    if (errors == 0) begin
      $display("PASS: line coder");
      $finish;
    end else $fatal(1, "FAILED with %0d error(s)", errors);
  end

  initial begin
    #20ms;
    $fatal(1, "FAILED: timeout");
  end
endmodule
