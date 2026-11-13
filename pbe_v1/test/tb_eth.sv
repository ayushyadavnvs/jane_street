`timescale 1ns / 1ps
// 10BASE-T end to end (D93): eth_tx.pbe on engine 0 (TD+ pin 0, TD- pin 1), eth_rx.pbe on
// engine 1 (RD pin 2), against eth_model.sv, a link partner written from IEEE 802.3. The host
// runs the quad port (D89) at SCK = clk / 8 and streams the frames in real time: TX bursts
// paced by the TX-full pin (uo_out[6]), the RX FIFOs pumped by RX_COUNT and burst reads, all
// through the one shared port (tb_host.svh's ticket lock).
//   (1) transmit frames of 64, 512 and 1518 bytes (FCS included), queued back to back: the model
//       decodes each, checks preamble/SFD/FCS/bit timing/TP_IDL and the 9.6 us gap; one status
//       byte per frame says no underrun;
//   (2) receive the same sizes from the model, a frame with a bad FCS, and frames at +-100 ppm
//       (802.3's limit), +-1000 ppm and +-0.5 % with jitter; three frames 9.6 us apart;
//   (3) loopback: engine 0's pins into engine 1, both FIFOs streamed at once (full duplex host);
//   (4) normal link pulses while idle (16 ms +- 8 ms, 100 ns), and link pulses from the model
//       that engine 1 must ignore;
//   (5) a host underrun (the TX FIFO left dry for 30 us inside a frame) and an abort (1.2 ms):
//       reported in the frame's status byte; an RX overrun (the host stops reading): reported
//       in the frame's status record.
module tb_eth;
  localparam real CLK_NS = 16.6672;  // 60 MHz (simulated: 16.668 ns)
  localparam int HOST_HALF = 4;      // host SCK = clk / 8
  logic clk = 0, rst_n = 0;
  always #(CLK_NS / 2) clk = ~clk;

  logic [7:0] ui_in = 8'b0000_0010;
  wire  [7:0] uo_out, uio_out, uio_oe;
  wire tdp = uio_oe[0] & uio_out[0];  // the line driver's inputs (pull-downs when released)
  wire tdm = uio_oe[1] & uio_out[1];
  wire m_rd;
  bit  loop = 0;                      // (3): TD into RD through the comparator
  wire rd = loop ? (tdp && !tdm) : m_rd;
  wire [7:0] bus = {5'b0, rd, tdm, tdp};

  tt_um_ayushyadavnvs_pbe dut (
      .ui_in, .uo_out, .uio_in(bus), .uio_out, .uio_oe, .ena(1'b1), .clk, .rst_n
  );
  eth_model u_m (.tdp(loop ? 1'b0 : tdp), .tdm(loop ? 1'b0 : tdm), .rd(m_rd));

  `include "tb_host.svh"

  int pass = 0;
  task automatic result(input string name, input bit ok);
    check(ok, name);
    if (ok) pass++;
    $display("  ETH  %-70s %s", name, ok ? "PASS" : "FAIL");
  endtask

  // ---------------- host: transmit stream (engine 0's TX FIFO) ----------------
  // tx_s holds the FIFO bytes of the frames queued: per frame [n][n bytes]... [0]
  logic [7:0] tx_s[$];
  logic [7:0] frames[$];  // the frames' bytes as sent (no FCS), back to back
  int  frame_len[$];
  bit  tx_pause = 0;      // (5): stop feeding
  int  tx_sent = 0;
  // queue one frame of n bytes (without FCS) from frame_buf
  logic [7:0] frame_buf[2048];
  task automatic queue_frame(input int n);
    int k, c;
    k = 0;
    while (k < n) begin
      c = (n - k > 255) ? 255 : n - k;
      tx_s.push_back(8'(c));
      for (int i = 0; i < c; i++) tx_s.push_back(frame_buf[k + i]);
      k += c;
    end
    tx_s.push_back(8'h00);
    for (int i = 0; i < n; i++) frames.push_back(frame_buf[i]);
    frame_len.push_back(n);
  endtask
  // a random frame: broadcast destination, a source, an EtherType, random payload
  task automatic make_frame(input int n);
    for (int i = 0; i < n; i++) frame_buf[i] = 8'($urandom);
    for (int i = 0; i < 6; i++) frame_buf[i] = 8'hFF;
    frame_buf[6] = 8'h02;
    frame_buf[12] = 8'h88;
    frame_buf[13] = 8'hB5;  // local experimental EtherType
    frame_buf[20] = 8'h7E;  // escape-byte cases for the receive records
    frame_buf[21] = 8'h7E;
  endtask
  // one burst: as many bytes as the TX FIFO takes (TX full pin), at most 12, then let go of
  // the port so the RX pumps get their turn
  task automatic tx_burst();
    logic [7:0] d;
    int k;
    cs(0);
    spi_byte({1'b1, 7'h16}, d);
    k = 0;
    while (tx_s.size() > 0 && k < 12 && !tx_pause) begin
      repeat (2) @(negedge clk);  // the TX-full pin is valid 6 clocks after a byte's last SCK edge
      if (uo_out[6]) k = 12;      // full: end the burst (no `break` in Icarus 12)
      else begin
        spi_byte(tx_s.pop_front(), d);
        tx_sent++;
        k++;
      end
    end
    cs(1);
  endtask
  bit tx_pump_on = 0;
  initial forever begin
    @(negedge clk);
    if (tx_pump_on && tx_s.size() > 0 && !tx_pause && !uo_out[6]) tx_burst();
  end

  // ---------------- host: receive pumps ----------------
  logic [7:0] rx1[$];  // engine 1's RX FIFO, as read
  logic [7:0] st0[$];  // engine 0's RX FIFO: one status byte per transmitted frame
  bit rx_pump_on = 0;
  task automatic drain(input int e);
    logic [7:0] c, d;
    reg_read(e ? 7'h0B : 7'h0A, c);  // RX_COUNT
    if (c != 0) begin
      cs(0);
      spi_byte({1'b0, e ? 7'h26 : 7'h16}, d);
      for (int i = 0; i < c; i++) begin
        spi_byte(8'h00, d);
        if (e) rx1.push_back(d);
        else st0.push_back(d);
      end
      cs(1);
    end
  endtask
  initial forever begin
    @(negedge clk);
    if (rx_pump_on && uo_out[5]) drain(1);  // E1 RX has data
    if (rx_pump_on && uo_out[4]) drain(0);  // E0 RX has data (status bytes)
  end

  // parse engine 1's records: bytes, a data 0x7E twice, [0x7E][status] ends a frame
  logic [7:0] rf_bytes[$];
  int  rf_len[$];
  logic [7:0] rf_stat[$];
  task automatic parse_rx();
    int j, n;
    bit found;
    // only whole records: find the end of the first frame ([0x7E][status], not 0x7E 0x7E)
    found = 1;
    while (found) begin
      found = 0;
      j = 0;
      while (!found && j + 1 < rx1.size()) begin
        if (rx1[j] != 8'h7E) j++;
        else if (rx1[j+1] == 8'h7E) j += 2;
        else found = 1;
      end
      if (found) begin
        n = 0;
        while (rx1[0] != 8'h7E || rx1[1] == 8'h7E) begin
          if (rx1[0] == 8'h7E) void'(rx1.pop_front());
          rf_bytes.push_back(rx1.pop_front());
          n++;
        end
        void'(rx1.pop_front());
        rf_stat.push_back(rx1.pop_front());
        rf_len.push_back(n);
      end
    end
  endtask

  // ---------------- set-up ----------------
  task automatic setup();
    // engine 0: transmitter
    reg_write(7'h03, 8'h04);  // PIN_OWN: pin 2 (RD) to engine 1
    reg_write(7'h10, 8'd5);   // CLKDIV 5: 6 clocks a bit
    reg_write(7'h11, 8'd0);
    reg_write(7'h12, 8'd0);   // pin base 0: TD+ pin 0, TD- pin 1
    reg_write(7'h14, 8'h00);  // LSB first
    reg_write(7'h15, 8'd0);
    reg_write(7'h19, 8'hB7);  // CRC_POLY 0x04C11DB7
    reg_write(7'h1A, 8'h1D);
    reg_write(7'h38, 8'hC1);
    reg_write(7'h39, 8'h04);
    reg_write(7'h3C, 8'h01);  // CRC_CFG2: 32 bits
    reg_write(7'h1B, 8'h7F);  // init ones, reversed, fed by OUT
    reg_write(7'h1C, 8'h60);  // TIMEOUT 60000 = 1 ms
    reg_write(7'h1D, 8'hEA);
    reg_write(7'h1E, 8'h41);  // TIMEOUT_PC 1, no parity
    reg_write(7'h30, 8'h33);  // LINE: Manchester, pair, bytes
    reg_write(7'h31, 8'h00);  // SYNC 0
    // engine 1: receiver
    reg_write(7'h20, 8'd5);
    reg_write(7'h21, 8'd0);
    reg_write(7'h22, 8'd2);   // pin base 2: RD
    reg_write(7'h24, 8'h00);
    reg_write(7'h25, 8'd0);
    reg_write(7'h29, 8'hB7);
    reg_write(7'h2A, 8'h1D);
    reg_write(7'h48, 8'hC1);
    reg_write(7'h49, 8'h04);
    reg_write(7'h4C, 8'h01);
    reg_write(7'h2B, 8'hBF);  // init ones, reversed, fed by IN
    reg_write(7'h42, 8'h7B);  // CRC_GOOD 0xC704DD7B, the residue
    reg_write(7'h43, 8'hDD);
    reg_write(7'h4A, 8'h04);
    reg_write(7'h4B, 8'hC7);
    reg_write(7'h2C, 8'h00);  // no timeout
    reg_write(7'h2D, 8'h00);
    reg_write(7'h2E, 8'h40);  // no parity
    reg_write(7'h40, 8'h23);  // LINE: Manchester, bytes
    reg_write(7'h41, 8'hD5);  // SYNC: the SFD
  endtask

  task automatic regs_check(output bit ok);
    logic [7:0] d;
    ok = 1;
    reg_read(7'h3C, d); if (d != 8'h01) ok = 0;
    reg_read(7'h4A, d); if (d != 8'h04) ok = 0;
    reg_read(7'h4B, d); if (d != 8'hC7) ok = 0;
    reg_read(7'h42, d); if (d != 8'h7B) ok = 0;
  endtask

  // wait until the model has seen `want` frames in all (or a timeout)
  task wait_frames(input int want, input real max_us);
    realtime t0;
    t0 = $realtime;
    while (u_m.frames_seen < want && $realtime - t0 < max_us * 1000.0) #1000;
  endtask

  // compare the model's received frame k (n bytes + FCS) with frames from offset off
  function automatic bit tx_frame_ok(input int k, input int off, input int n);
    int base;
    base = 0;
    for (int i = 0; i < k; i++) base += u_m.rx_len[i];
    if (k >= u_m.rx_len.size() || u_m.rx_len[k] != n + 4 || !u_m.rx_fcs_ok[k]) return 0;
    for (int i = 0; i < n; i++) if (u_m.rx_bytes[base + i] !== frames[off + i]) return 0;
    return 1;
  endfunction

  // ---------------- tests ----------------
  int sizes[3];
  initial begin
    logic [7:0] d;
    bit ok;
    int off, nf, base;
    realtime t0;
    sizes[0] = 60; sizes[1] = 508; sizes[2] = 1514;  // 64, 512, 1518 with the FCS

    repeat (5) @(posedge clk);
    @(negedge clk) rst_n = 1;
    repeat (5) @(posedge clk);
    $display("10BASE-T (D93): eth_tx on engine 0, eth_rx on engine 1, quad host at SCK = clk / 8");
    host_quad_on();
    load_program("eth_image.hex");
    setup();
    regs_check(ok);
    result("CRC-32 registers (CRC_CFG2, CRC_GOOD_2/3) read back", ok);
    reg_write(7'h00, 8'h33);  // restart and run both
    rx_pump_on = 1;
    tx_pump_on = 1;

    // ===== (1) transmit 64, 512, 1518 back to back =====
    for (int s = 0; s < 3; s++) begin
      make_frame(sizes[s]);
      queue_frame(sizes[s]);
    end
    t0 = $realtime;
    wait_frames(3, 3000.0);
    repeat (2000) @(negedge clk);
    ok = u_m.frames_seen == 3;
    off = 0;
    for (int s = 0; s < 3; s++) begin
      ok = ok && tx_frame_ok(s, off, sizes[s]);
      off += sizes[s];
    end
    result($sformatf("(1) TX 64, 512, 1518 bytes back to back: decoded, FCS ok (%0d frames)", u_m.frames_seen), ok);
    result($sformatf("(1) TX inter-frame gap >= 9.6 us (min %0.2f us), TP_IDL %0.0f-%0.0f ns",
                     u_m.ifg_min / 1000.0, u_m.tpidl_min, u_m.tpidl_max),
           u_m.ifg_min >= 9600.0 && u_m.errors == 0);
    ok = st0.size() == 3;
    foreach (st0[i]) if ((st0[i] & 8'h1C) != 0) ok = 0;
    result($sformatf("(1) TX status bytes: %0d, no underrun/timeout/overflow", st0.size()), ok);
    $display("       on the wire: %0.1f, %0.1f, %0.1f us (1.25 MB/s streamed by the host; no underrun)",
             (u_m.rx_end[0] - u_m.rx_start[0]) / 1000.0, (u_m.rx_end[1] - u_m.rx_start[1]) / 1000.0,
             (u_m.rx_end[2] - u_m.rx_start[2]) / 1000.0);

    // ===== (2) receive =====
    begin
      int cases;
      real ppm[8], jit[8];
      int  len[8];
      bit  bad[8];
      len[0] = 60;   ppm[0] = 0;      jit[0] = 0;   bad[0] = 0;
      len[1] = 508;  ppm[1] = 0;      jit[1] = 0;   bad[1] = 0;
      len[2] = 1514; ppm[2] = 0;      jit[2] = 0;   bad[2] = 0;
      len[3] = 100;  ppm[3] = 0;      jit[3] = 0;   bad[3] = 1;
      len[4] = 508;  ppm[4] = 100;    jit[4] = 5.0; bad[4] = 0;
      len[5] = 508;  ppm[5] = -100;   jit[5] = 5.0; bad[5] = 0;
      len[6] = 508;  ppm[6] = 1000;   jit[6] = 5.0; bad[6] = 0;
      len[7] = 508;  ppm[7] = -5000;  jit[7] = 3.0; bad[7] = 0;
      cases = 8;
      rf_bytes.delete(); rf_len.delete(); rf_stat.delete();
      for (int c = 0; c < cases; c++) begin
        make_frame(len[c]);
        for (int i = 0; i < len[c]; i++) u_m.tx_buf[i] = frame_buf[i];
        u_m.send_frame(len[c], ppm[c], jit[c], bad[c]);
        #12000;  // the gap, and time for the host to drain
        repeat (3000) @(negedge clk);
        parse_rx();
        base = 0;
        for (int i = 0; i + 1 < rf_len.size(); i++) base += rf_len[i];
        ok = rf_len.size() == c + 1 && rf_len[c] == len[c] + 4 && rf_stat[c] == (bad[c] ? 8'h00 : 8'h02);
        for (int i = 0; ok && i < len[c]; i++) if (rf_bytes[base + i] !== frame_buf[i]) ok = 0;
        result($sformatf("(2) RX %4d bytes, %6.0f ppm, jitter +-%0.0f ns%s: bytes, status %02x",
                         len[c] + 4, ppm[c], jit[c], bad[c] ? ", bad FCS" : "",
                         rf_stat.size() > c ? rf_stat[c] : 8'hXX), ok);
      end
      // three frames 9.6 us apart (the model's gap after TP_IDL is part of the 9.6 us)
      nf = rf_len.size();
      for (int c = 0; c < 3; c++) begin
        make_frame(64);
        for (int i = 0; i < 64; i++) u_m.tx_buf[i] = frame_buf[i];
        u_m.send_frame(64, 0, 0, 0);
        #(9600 - 300);  // TP_IDL (300 ns) counts in the gap
      end
      #12000;
      repeat (3000) @(negedge clk);
      parse_rx();
      ok = rf_len.size() == nf + 3;
      for (int c = nf; ok && c < nf + 3; c++) if (rf_len[c] != 68 || rf_stat[c] != 8'h02) ok = 0;
      result("(2) RX three frames 9.6 us apart: all received, FCS ok", ok);
    end

    // ===== (3) loopback =====
    loop = 1;
    repeat (200) @(negedge clk);
    rf_bytes.delete(); rf_len.delete(); rf_stat.delete();
    rx1.delete();
    frames.delete(); frame_len.delete();
    st0.delete();
    for (int s = 0; s < 3; s++) begin
      make_frame(sizes[s]);
      queue_frame(sizes[s]);
    end
    t0 = $realtime;
    while (rf_len.size() < 3 && $realtime - t0 < 4.0e6) begin
      #2000;
      parse_rx();
    end
    ok = rf_len.size() == 3;
    off = 0;
    base = 0;
    for (int s = 0; ok && s < 3; s++) begin
      if (rf_len[s] != sizes[s] + 4 || rf_stat[s] != 8'h02) ok = 0;
      for (int i = 0; ok && i < sizes[s]; i++) if (rf_bytes[base + i] !== frames[off + i]) ok = 0;
      off += sizes[s];
      base += rf_len[s];
    end
    result($sformatf("(3) loopback engine 0 -> engine 1, 64/512/1518 bytes, full-duplex host: %0d frames", rf_len.size()), ok);
    if (!ok) begin
      foreach (rf_len[i]) $display("       frame %0d: %0d bytes, status %02x", i, rf_len[i], rf_stat[i]);
      foreach (st0[i]) $display("       engine 0 status %02x", st0[i]);
      $display("       tx_s left %0d, rx1 left %0d", tx_s.size(), rx1.size());
    end
    repeat (2000) @(negedge clk);
    loop = 0;

    // ===== (4) link pulses =====
    begin
      int n0;
      n0 = u_m.nlp_t.size();
      rf_len.delete();
      t0 = $realtime;
      fork
        #34ms;
        begin  // the model's own link pulses to engine 1, every 5 ms: never a frame
          repeat (6) begin
            #5ms;
            u_m.send_nlp();
          end
        end
      join
      parse_rx();
      result($sformatf("(4) NLPs while idle: %0d in 34 ms, %0.1f ns wide, %0.3f ms apart (8..24)",
                       u_m.nlp_t.size() - n0, u_m.nlp_w[$],
                       u_m.nlp_t.size() >= 2 ? (u_m.nlp_t[$] - u_m.nlp_t[u_m.nlp_t.size()-2]) / 1e6 : 0.0),
             u_m.nlp_t.size() - n0 >= 2 && u_m.errors == 0);
      result("(4) link pulses into engine 1: no frame, no record", rf_len.size() == 0 && rx1.size() == 0);
    end

    // ===== (5) underrun, abort, overrun =====
    begin
      int ns0;
      ns0 = st0.size();
      u_m.lenient = 1;
      make_frame(508);
      queue_frame(508);
      wait (tx_sent > 0);
      t0 = $realtime;
      while (tx_s.size() > 300) @(negedge clk);
      tx_pause = 1;
      #30000;          // the FIFO runs dry inside the frame for 30 us
      tx_pause = 0;
      while (st0.size() == ns0 && $realtime - t0 < 3.0e6) #1000;
      result($sformatf("(5) TX underrun (30 us): status %02x, bit 4 (line error) set",
                       st0.size() > ns0 ? st0[ns0] : 8'hXX),
             st0.size() > ns0 && (st0[ns0] & 8'h10) != 0);
      ns0 = st0.size();
      make_frame(508);
      queue_frame(508);
      t0 = $realtime;
      while (tx_s.size() > 300) @(negedge clk);
      tx_pause = 1;
      #1.2ms;          // more than TIMEOUT (1 ms): the engine ends the frame
      tx_s.delete();   // the host gives up on the rest of the frame
      tx_s.push_back(8'h00);
      tx_s.push_back(8'h00);  // a frame end, then an empty frame: back in step
      tx_pause = 0;
      while (st0.size() == ns0 && $realtime - t0 < 3.0e6) #1000;
      result($sformatf("(5) TX abort (FIFO empty 1.2 ms): status %02x, bit 2 (timeout) set",
                       st0.size() > ns0 ? st0[ns0] : 8'hXX),
             st0.size() > ns0 && (st0[ns0] & 8'h04) != 0);
      repeat (20000) @(negedge clk);
      u_m.lenient = 0;
      // RX overrun: the host stops reading during a 512-byte frame
      rx_pump_on = 0;
      rf_bytes.delete(); rf_len.delete(); rf_stat.delete();
      rx1.delete();
      make_frame(508);
      for (int i = 0; i < 508; i++) u_m.tx_buf[i] = frame_buf[i];
      u_m.send_frame(508, 0, 0, 0);
      #20000;
      rx_pump_on = 1;
      #200000;
      parse_rx();
      result($sformatf("(5) RX overrun (host not reading): %0d bytes of 512 kept, status %02x (bits 3, 4)",
                       rf_len.size() ? rf_len[0] : 0, rf_stat.size() ? rf_stat[0] : 8'hXX),
             rf_stat.size() == 1 && (rf_stat[0] & 8'h1A) == 8'h18);
    end

    check(u_m.errors == 0, $sformatf("the 10BASE-T model reported %0d error(s)", u_m.errors));
    if (errors == 0) $display("PASS: 10BASE-T (%0d checks)", pass);
    else $fatal(1, "FAILED with %0d error(s)", errors);
    $finish;
  end

  initial begin
    #120ms;
    $fatal(1, "timeout");
  end
endmodule
