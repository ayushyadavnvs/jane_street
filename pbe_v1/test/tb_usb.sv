`timescale 1ns / 1ps
// End-to-end test of the USB low-speed device (programs/usb_dev.pbe on engine 0), through the
// chip's pins only.
//
//  - A USB host model drives D- (pin 0) and D+ (pin 1), with its bit rate off by +-1.5 %, and
//    decodes what the device sends (NRZI, unstuffing, CRC16 checked here, independently).
//    Every device reply must start 2 to 7.5 bit times after the host's EOP, and host and
//    device must never drive the bus at the same time.
//  - A device firmware model on the host port answers the records the engine reports
//    (IRQ-driven): descriptors, SET_ADDRESS (it rewrites the address in the program), a
//    vendor write and read, and STALL for what it does not support. On a timer it queues an
//    IN packet again when its ACK does not come, and handles a bus reset (SE0 >= 2.5 us).
//  - The host enumerates the device: GET_DESCRIPTOR (device, configuration), SET_ADDRESS,
//    SET_CONFIGURATION, an unsupported request, vendor requests; and checks that the device
//    ignores a corrupted SETUP, a packet with a stuffing error, tokens for another address and a
//    token with a bad CRC5, and keep-alive EOPs. Then a lost ACK (the device must resend the
//    same DATA1 packet) and a 10 ms bus reset (the device must answer at address 0 again).
module tb_usb;
  localparam real CLK_NS = 20.8333;  // 48 MHz: a USB low-speed bit is 32 clocks
  localparam int HOST_HALF = 8;
  localparam real BIT_NS = 1.0e9 / 1.5e6;

  logic clk = 0, rst_n = 0;
  always #(CLK_NS / 2) clk = ~clk;

  logic [7:0] ui_in = 8'b0000_0010;
  wire  [7:0] uo_out, uio_out, uio_oe;
  logic [7:0] ext_drive = '0, ext_val = '0;
  // D- (pin 0) has the device's 1.5 kohm pull-up, D+ (pin 1) the host's pull-down: idle is J
  localparam logic [7:0] PULL = 8'b1111_1101;
  wire  [7:0] bus = (uio_oe & uio_out) | (~uio_oe & ext_drive & ext_val) | (~uio_oe & ~ext_drive & PULL);

  tt_um_ayushyadavnvs_pbe dut (
      .ui_in, .uo_out, .uio_in(bus), .uio_out, .uio_oe, .ena(1'b1), .clk, .rst_n
  );

  `include "tb_host.svh"

  int contention = 0;
  always @(posedge clk) if ((uio_oe[1:0] & ext_drive[1:0]) != 0) contention++;

  // ---------------- USB helpers ----------------
  // CRC16 over u_data (the PID is not covered): returns the field, low byte sent first
  logic [7:0] u_data[$];
  function automatic logic [15:0] usb_crc16();
    logic [15:0] c, f;
    logic [7:0] b;
    c = 16'hFFFF;
    foreach (u_data[i]) begin
      b = u_data[i];
      for (int k = 0; k < 8; k++) c = {c[14:0], 1'b0} ^ ((b[k] ^ c[15]) ? 16'h8005 : 16'h0);
    end
    for (int k = 0; k < 16; k++) f[k] = ~c[15-k];
    return f;
  endfunction
  // token bytes 2 and 3 for an address and endpoint (CRC5: poly 0x05, init all ones, inverted)
  function automatic logic [15:0] usb_tok(input logic [6:0] addr, input logic [3:0] ep);
    logic [10:0] v;
    logic [4:0]  c, f;
    v = {ep, addr};
    c = 5'h1F;
    for (int k = 0; k < 11; k++) c = {c[3:0], 1'b0} ^ ((v[k] ^ c[4]) ? 5'h05 : 5'h0);
    for (int k = 0; k < 5; k++) f[k] = ~c[4-k];
    return {f, v};
  endfunction

  // ---------------- USB host model: send ----------------
  logic [7:0] h_pkt[$];   // PID and the rest, without SYNC
  real h_pct = 0;         // bit rate error in percent
  int  h_bad_stuff = 0;   // the first stuffed bit: 1 leave it out, 2 send it as a 1 (wrong value)
  realtime t_host_j;      // when the host's last EOP turned to J
  task automatic hs_line(input int st);  // 0 SE0, 1 J, 2 K
    ext_drive[1:0] = 2'b11;
    ext_val[0] = st == 1;
    ext_val[1] = st == 2;
  endtask
  task automatic hs_send;
    real tb;
    int k, ones;
    logic [7:0] cur;
    tb = BIT_NS / (1.0 + h_pct / 100.0);
    k = 1;  // J
    ones = 0;
    for (int i = -1; i < h_pkt.size(); i++) begin
      cur = (i < 0) ? 8'h80 : h_pkt[i];
      for (int b = 0; b < 8; b++) begin
        if (!cur[b]) k = 3 - k;
        hs_line(k);
        #(tb);
        ones = cur[b] ? ones + 1 : 0;
        if (ones == 6) begin
          if (h_bad_stuff != 1) begin
            if (h_bad_stuff != 2) k = 3 - k;  // a stuffed 0 changes the level, a wrong 1 keeps it
            hs_line(k);
            #(tb);
          end
          h_bad_stuff = 0;
          ones = 0;
        end
      end
    end
    hs_line(0);
    #(2 * tb);
    hs_line(1);
    t_host_j = $realtime;
    #(tb);
    ext_drive[1:0] = 2'b00;
  endtask
  task automatic hs_keepalive;  // a bare EOP, as a low-speed host sends every millisecond
    hs_line(0);
    #(2 * BIT_NS);
    hs_line(1);
    #(BIT_NS);
    ext_drive[1:0] = 2'b00;
  endtask

  // ---------------- USB host model: receive ----------------
  // Waits up to 16 bit times for the device; decodes with the chip's clock (32 clocks a bit),
  // re-centring on every D- edge. r_pkt gets the bytes (PID first), r_ok says a packet came.
  logic [7:0] r_pkt[$];
  bit r_ok;
  real tt_min = 1e9, tt_max = 0;
  int r_bad = 0;
  task automatic hs_recv;
    int phase, ones, nbits, wait_clk;
    bit last, prev, in_sync, b, se0;
    logic [7:0] sh;
    real tt;
    r_pkt.delete();
    r_ok = 0;
    wait_clk = 0;
    while (!(bus[1] && !bus[0]) && wait_clk < 16 * 32) begin  // K starts the SYNC
      @(posedge clk);
      wait_clk++;
    end
    if (bus[1] && !bus[0]) begin : got_k
    tt = ($realtime - t_host_j) / BIT_NS;
    if (tt < tt_min) tt_min = tt;
    if (tt > tt_max) tt_max = tt;
    phase = 0;
    ones = 0;
    nbits = 0;
    last = 0;   // D- is low (K)
    prev = 1;   // the level before SYNC: J
    in_sync = 1;
    se0 = 0;
    while (!se0) begin
      @(posedge clk);
      if (bus[0] != last) begin
        last = bus[0];
        phase = 0;
      end else phase++;
      if (phase % 32 == 16) begin
        if (!bus[0] && !bus[1]) se0 = 1;
        else begin
          b = (bus[0] == prev);
          prev = bus[0];
          if (in_sync) begin
            if (b) begin
              in_sync = 0;
              ones = 1;
            end
          end else if (ones == 6) begin
            if (b) begin
              r_bad++;
              $display("  FAIL: USB host: device sent no stuffed 0 after six 1s");
            end
            ones = 0;
          end else begin
            sh = {b, sh[7:1]};
            nbits++;
            ones = b ? ones + 1 : 0;
            if (nbits % 8 == 0) r_pkt.push_back(sh);
          end
        end
      end
    end
    // EOP: SE0 for 2 bits (we saw it at mid-bit), then J
    wait_clk = 16;
    while (!bus[0] && !bus[1]) begin
      @(posedge clk);
      wait_clk++;
    end
    check(wait_clk >= 60 && wait_clk <= 68, $sformatf("USB host: device EOP SE0 lasted %0d clocks", wait_clk));
    check(bus[0] && !bus[1], "USB host: no J after the device's SE0");
    check(nbits % 8 == 0, $sformatf("USB host: device packet of %0d bits", nbits));
    repeat (40) @(posedge clk);
    check(uio_oe[1:0] == 2'b00, "USB host: device did not release the bus after its EOP");
    r_ok = 1;
    end
  endtask

  // ---------------- transactions ----------------
  logic [6:0] dev_addr = 0;
  int n_timeouts = 0;
  task automatic hs_token(input logic [7:0] pid, input logic [6:0] addr);
    logic [15:0] t;
    t = usb_tok(addr, 0);
    h_pkt = '{pid, t[7:0], t[15:8]};
    hs_send;
  endtask
  task automatic hs_data(input logic [7:0] pid, input bit flip);  // u_data with its CRC16
    logic [15:0] c;
    c = usb_crc16();
    h_pkt.delete();
    h_pkt.push_back(pid);
    foreach (u_data[i]) h_pkt.push_back(u_data[i]);
    h_pkt.push_back(c[7:0]);
    h_pkt.push_back(c[15:8]);
    if (flip) h_pkt[1] = h_pkt[1] ^ 8'h04;
    hs_send;
  endtask
  task automatic gap;  // between transactions: a little time, sometimes a keep-alive
    repeat (200) @(posedge clk);
  endtask

  // the request of the next control transfer (array ports are not supported by Icarus 12)
  logic [7:0] req[$];

  // SETUP stage: retried until the device ACKs (a host gives up after 3 errors)
  task automatic hs_setup;
    int tries;
    tries = 0;
    do begin
      hs_token(8'h2D, dev_addr);
      u_data.delete();
      foreach (req[i]) u_data.push_back(req[i]);
      hs_data(8'hC3, 0);
      hs_recv;
      tries++;
      gap;
    end while (!(r_ok && r_pkt.size() == 1 && r_pkt[0] == 8'hD2) && tries < 3);
    check(r_ok && r_pkt.size() == 1 && r_pkt[0] == 8'hD2, "USB: SETUP not ACKed");
  endtask

  // IN: retried while the device NAKs. in_pkt gets the data, in_res: 0 data, 1 STALL, 2 nothing
  logic [7:0] in_pkt[$];
  int in_res;
  logic [7:0] in_pid;
  bit h_lose_ack = 0;  // the next IN data packet gets no ACK (as if the ACK were lost)
  task automatic hs_in;
    int tries;
    logic [15:0] c, got;
    tries = 0;
    in_res = 2;
    do begin
      hs_token(8'h69, dev_addr);
      hs_recv;
      tries++;
      if (r_ok && r_pkt.size() == 1 && r_pkt[0] == 8'h5A) repeat (400) @(posedge clk);  // NAK
    end while (r_ok && r_pkt.size() == 1 && r_pkt[0] == 8'h5A && tries < 200);
    if (r_ok && r_pkt.size() == 1 && r_pkt[0] == 8'h1E) begin
      in_res = 1;
      gap;
    end else if (r_ok) begin : data
    check(r_pkt.size() >= 3 && (r_pkt[0] == 8'hC3 || r_pkt[0] == 8'h4B),
          $sformatf("USB: IN answered with %0d bytes, PID %02x", r_pkt.size(), r_pkt.size() ? r_pkt[0] : 8'h00));
    in_pid = r_pkt[0];
    u_data.delete();
    for (int i = 1; i + 2 < r_pkt.size(); i++) u_data.push_back(r_pkt[i]);
    c = usb_crc16();
    got = {r_pkt[r_pkt.size()-1], r_pkt[r_pkt.size()-2]};
    check(got == c, $sformatf("USB: device DATA CRC16 %04x, expected %04x", got, c));
    in_pkt.delete();
    foreach (u_data[i]) in_pkt.push_back(u_data[i]);
    in_res = 0;
    if (h_lose_ack) h_lose_ack = 0;
    else begin
      h_pkt = '{8'hD2};  // ACK
      hs_send;
    end
    gap;
    end
  endtask

  // OUT: a data packet with out_data, retried until ACKed
  logic [7:0] out_data[$];
  task automatic hs_out(input logic [7:0] pid);
    int tries;
    tries = 0;
    do begin
      hs_token(8'hE1, dev_addr);
      u_data = out_data;  // (hs_setup uses u_data for the request: BUG-029)
      hs_data(pid, 0);
      hs_recv;
      tries++;
      gap;
    end while (!(r_ok && r_pkt.size() == 1 && r_pkt[0] == 8'hD2) && tries < 3);
    check(r_ok && r_pkt.size() == 1 && r_pkt[0] == 8'hD2, "USB: OUT not ACKed");
  endtask

  // control read: SETUP, IN data stages until a short packet or wLength, OUT status
  logic [7:0] ctl_in[$];
  int ctl_stalled;
  task automatic ctl_read;
    int want;
    logic [7:0] expect_pid;
    want = {req[7], req[6]};
    ctl_in.delete();
    ctl_stalled = 0;
    hs_setup;
    expect_pid = 8'h4B;  // DATA1 first
    begin : stages  // (Icarus 12 has no return in tasks: disable the block instead)
      do begin
        hs_in;
        if (in_res == 1) begin
          ctl_stalled = 1;
          disable stages;
        end
        check(in_res == 0, "USB: no answer to IN in a control read");
        if (in_res != 0) disable stages;
        check(in_pid == expect_pid, $sformatf("USB: data stage PID %02x, expected %02x", in_pid, expect_pid));
        expect_pid = expect_pid ^ 8'h88;  // DATA1 <-> DATA0
        foreach (in_pkt[i]) ctl_in.push_back(in_pkt[i]);
      end while (in_pkt.size() == 8 && ctl_in.size() < want);
      out_data.delete();
      hs_out(8'h4B);  // status stage: OUT DATA1, zero length
    end
  endtask

  // control with no data stage, or a write: SETUP, OUT data, IN status (zero length)
  task automatic ctl_write(input bit with_data);
    hs_setup;
    if (with_data) hs_out(8'h4B);  // out_data holds the data
    hs_in;
    check(in_res == 0 && in_pkt.size() == 0 && in_pid == 8'h4B, "USB: status stage is not a DATA1 ZLP");
  endtask

  // ---------------- device firmware model (on the host port) ----------------
  logic [7:0] dev_desc[$], cfg_desc[$], vendor_mem[$];
  logic [7:0] fw_tx[$], rec[$];
  int  fw_want, fw_sent, fw_toggle, fw_setups = 0, fw_bad = 0, fw_acks = 0;
  bit  fw_reading = 0, fw_zlp = 0, fw_writing = 0, fw_run = 0, fw_hold = 0;
  logic [6:0] fw_addr_pending = 0;
  bit  fw_set_addr = 0;
  int  fw_vlen;
  int  fw_resends = 0, fw_resets = 0;  // IN packets queued again (BUG-041), bus resets seen (BUG-042)

  task automatic pm_write_word(input int a, input logic [15:0] w);
    logic [7:0] d;
    reg_write(7'h06, 8'(2 * a));
    cs(0);
    spi_byte({1'b1, 7'h07}, d);
    spi_byte(w[15:8], d);
    spi_byte(w[7:0], d);
    cs(1);
  endtask
  // The IN packet in the TX FIFO, kept until the host ACKs it: if the ACK does not come, the
  // firmware queues it again, same DATA PID (BUG-041)
  logic [7:0] fw_last[$];
  bit  fw_unacked = 0;
  realtime fw_drained_at = 0;  // when the TX FIFO was first seen empty with fw_unacked (0: not yet)
  task automatic fw_put;  // fw_last into the TX FIFO, then FLAG0
    logic [7:0] d;
    cs(0);
    spi_byte({1'b1, 7'h16}, d);
    foreach (fw_last[i]) spi_byte(fw_last[i], d);
    cs(1);
    fw_unacked = 1;
    fw_drained_at = 0;
    flag_set(0, 0);
  endtask
  task automatic fw_queue;  // the next IN packet of the reply
    int n;
    n = fw_tx.size() < 8 ? fw_tx.size() : 8;
    fw_last.delete();
    fw_last.push_back(fw_toggle ? 8'h4B : 8'hC3);
    for (int i = 0; i < n; i++) fw_last.push_back(fw_tx.pop_front());
    fw_sent += n;
    fw_zlp = 0;
    fw_toggle ^= 1;
    fw_put;
  endtask
  task automatic fw_status_zlp;  // the IN status stage of a no-data or write request
    fw_tx.delete();
    fw_toggle = 1;
    fw_reading = 0;
    fw_queue;
  endtask
  task automatic fw_setup;  // rec holds [2D] [C3] [8 bytes] [crc] [crc] [count] [status]
    logic [7:0] rt, rq, wvh, wvl;
    rt = rec[2];
    rq = rec[3];
    wvl = rec[4];
    wvh = rec[5];
    fw_want = {rec[9], rec[8]};
    fw_setups++;
    reg_write(7'h0E, 8'h01);  // drop a stale reply; not the RX FIFO: an OUT may already be arriving
    fw_unacked = 0;
    flag_clear(0, 0);
    flag_clear(0, 1);
    fw_writing = 0;
    fw_reading = 0;
    if (rt == 8'h80 && rq == 8'h06 && (wvh == 8'h01 || wvh == 8'h02)) begin  // GET_DESCRIPTOR
      fw_tx.delete();
      if (wvh == 8'h01) foreach (dev_desc[i]) fw_tx.push_back(dev_desc[i]);
      else foreach (cfg_desc[i]) fw_tx.push_back(cfg_desc[i]);
      while (fw_tx.size() > fw_want) d_drop();
      fw_reading = 1;
      fw_sent = 0;
      fw_toggle = 1;
      fw_queue;
    end else if (rt == 8'h00 && rq == 8'h05) begin  // SET_ADDRESS: takes effect after the status stage
      fw_addr_pending = wvl[6:0];
      fw_set_addr = 1;
      fw_status_zlp;
    end else if (rt == 8'h00 && rq == 8'h09) begin  // SET_CONFIGURATION
      fw_status_zlp;
    end else if (rt == 8'h40 && rq == 8'h01) begin  // vendor write: data follows
      fw_writing = 1;
      fw_vlen = fw_want;
      vendor_mem.delete();
    end else if (rt == 8'hC0 && rq == 8'h02) begin  // vendor read: what was written, reversed
      fw_tx.delete();
      for (int i = vendor_mem.size() - 1; i >= 0; i--) fw_tx.push_back(vendor_mem[i]);
      fw_tx.push_back(8'h55);
      while (fw_tx.size() > fw_want) d_drop();
      fw_reading = 1;
      fw_sent = 0;
      fw_toggle = 1;
      fw_queue;
    end else flag_set(0, 1);  // not supported: STALL
  endtask
  task automatic d_drop;
    logic [7:0] d;
    d = fw_tx.pop_back();
  endtask
  // One record from the RX FIFO, in rec: [D2], or [tag] [DATA PID] [n bytes] [255 - n] [status]
  task automatic fw_record;
    logic [7:0] st;
    if (rec.size() == 1 && rec[0] == 8'hD2) begin  // the host ACKed our IN packet
      fw_acks++;
      fw_unacked = 0;
      flag_clear(0, 0);
      if (fw_set_addr) begin                        // SET_ADDRESS status stage done: switch
        logic [15:0] t;
        t = usb_tok(fw_addr_pending, 0);
        pm_write_word(6, 16'h9000 | {4'h0, t[7:0], 4'h0});
        pm_write_word(9, 16'h9000 | {4'h0, t[15:8], 4'h0});
        fw_set_addr = 0;
      end else if (fw_reading && (fw_tx.size() > 0 || (fw_sent % 8 == 0 && fw_sent < fw_want && !fw_zlp)))
        fw_queue;
    end else begin
      st = rec[rec.size()-1];
      if (!st[1] || st[4]) fw_bad++;                // bad CRC or line error: not ACKed, sent again
      else if (rec[0] == 8'h2D && rec.size() == 14) fw_setup;
      else if (rec[0] == 8'hE1 && fw_writing) begin
        for (int k = 2; k < rec.size() - 4; k++) vendor_mem.push_back(rec[k]);
        if (vendor_mem.size() >= fw_vlen) begin
          fw_writing = 0;
          fw_status_zlp;
        end
      end
    end
  endtask

  // Bus reset (BUG-042): SE0 for 2.5 us or more. The firmware puts the device back at address
  // 0 (program words 6 and 9), drops the reply and the flags, and forgets its state.
  bit fw_in_reset = 0;
  task automatic fw_bus_reset;
    pm_write_word(6, 16'h9000);  // SET OSR, 0x00: address 0
    pm_write_word(9, 16'h9100);  // SET OSR, 0x10: endpoint 0 and the CRC5 for address 0
    reg_write(7'h0E, 8'h01);     // flush the TX FIFO
    reg_write(7'h09, 8'h07);     // clear FLAG0 (IN queued), FLAG1 (STALL) and FLAG2
    fw_tx.delete();
    fw_reading = 0;
    fw_writing = 0;
    fw_zlp = 0;
    fw_set_addr = 0;
    fw_unacked = 0;
    fw_resets++;
  endtask

  // The firmware's timer, every 50 us when no record waits: a bus reset, and an IN packet that
  // has left the TX FIFO (TX_COUNT = 0) without an ACK record for 100 us is queued again.
  // One register read takes about 6 us, so two reads that both see SE0 are 2.5 us apart; EOPs
  // (1.33 us of SE0) are at least ~12 us apart, so two of them cannot pass for a reset.
  task automatic fw_poll;
    logic [7:0] p, cnt;
    realtime t;
    reg_read(7'h05, p);  // PINS: D- is pin 0, D+ pin 1
    if (p[1:0] == 2'b00) begin
      t = $realtime;
      reg_read(7'h05, p);
      if (p[1:0] == 2'b00 && $realtime - t >= 2500) begin
        if (!fw_in_reset) fw_bus_reset;
        fw_in_reset = 1;
      end
    end else fw_in_reset = 0;
    if (fw_unacked) begin
      reg_read(7'h0C, cnt);  // TX_COUNT
      if (cnt != 0) fw_drained_at = 0;
      else if (fw_drained_at == 0) fw_drained_at = $realtime;
      else if ($realtime - fw_drained_at >= 100000 && !uo_out[1]) begin  // no record waiting
        fw_resends++;
        fw_put;
      end
    end
  endtask

  // IRQ-driven: read how many bytes wait (RX_COUNT), read exactly those in one burst, split
  // them into records from the end (a status byte is below 0x20, an ACK record is 0xD2), and
  // handle the records in order. Otherwise the timer (fw_poll). One process, like a firmware
  // main loop, so the two never race.
  logic [7:0] fw_buf[$];
  int fw_ends[$];
  int fw_records = 0, fw_max_pile = 0;
  realtime fw_next_poll = 0;
  initial forever begin
    @(posedge clk);
    if (fw_run && !fw_hold && !uo_out[1] && $realtime >= fw_next_poll) begin
      fw_next_poll = $realtime + 50000;
      fw_poll;
    end else if (fw_run && !fw_hold && uo_out[1]) begin
      logic [7:0] cnt, d, b;
      int j, c, from;
      reg_write(7'h02, 8'h01);  // clear the IRQ first: a record arriving meanwhile raises it again
      reg_read(7'h0A, cnt);
      fw_buf.delete();
      if (cnt != 0) begin
        cs(0);
        spi_byte({1'b0, 7'h16}, d);
        for (int i = 0; i < cnt; i++) begin
          spi_byte(8'h00, d);
          fw_buf.push_back(d);
        end
        cs(1);
      end
      flag_clear(0, 2);
      // record boundaries, found from the end
      fw_ends.delete();
      j = fw_buf.size() - 1;
      while (j >= 0) begin
        fw_ends.push_front(j);
        b = fw_buf[j];
        if (b == 8'hD2) j = j - 1;
        else begin
          c = 255 - fw_buf[j-1];
          j = j - 1 - c - 3;  // [tag] [pid] [c bytes] [count] [status]
        end
      end
      if (fw_ends.size() > fw_max_pile) fw_max_pile = fw_ends.size();
      check(j == -1, $sformatf("USB firmware: %0d bytes do not split into records", fw_buf.size()));
      from = 0;
      foreach (fw_ends[k]) begin
        rec.delete();
        for (int i = from; i <= fw_ends[k]; i++) rec.push_back(fw_buf[i]);
        from = fw_ends[k] + 1;
        fw_records++;
        fw_record;
      end
    end
  end

  // ---------------- the test ----------------
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("tb_usb.vcd");
      $dumpvars(0, tb_usb);
    end
    dev_desc = '{8'h12, 8'h01, 8'h10, 8'h01, 8'hFF, 8'h00, 8'h00, 8'h08, 8'h34, 8'h12,
                 8'h78, 8'h56, 8'h00, 8'h01, 8'h00, 8'h00, 8'h00, 8'h01};
    cfg_desc = '{8'h09, 8'h02, 8'h12, 8'h00, 8'h01, 8'h01, 8'h00, 8'h80, 8'h32,
                 8'h09, 8'h04, 8'h00, 8'h00, 8'h00, 8'hFF, 8'h00, 8'h00, 8'h00};
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (5) @(posedge clk);

    // CRC helpers against the known values (docs/USB_NOTES.md)
    begin
      logic [15:0] c, t;
      u_data = '{8'h80, 8'h06, 8'h00, 8'h01, 8'h00, 8'h00, 8'h40, 8'h00};
      c = usb_crc16();
      t = usb_tok(0, 0);
      check(c == 16'h94DD && t == 16'h1000, $sformatf("testbench CRCs: %04x %04x", c, t));
    end

    $display("Test 11: USB low-speed device (engine 0, D- pin 0, D+ pin 1) enumerated by a host model");
    load_program("usb_image.hex");
    reg_write(7'h03, 8'h00);
    reg_write(7'h10, 31);               // bit time 32 clocks
    reg_write(7'h11, 0);
    reg_write(7'h12, 0);
    reg_write(7'h14, 2'b00);            // LSB first
    reg_write(7'h15, 0);
    reg_write(7'h19, 8'h05);            // CRC16 0x8005, all ones, reversed, fed by OUT and IN
    reg_write(7'h1A, 8'h80);
    reg_write(7'h1B, 8'hFF);
    reg_write(7'h1E, 8'h40);            // no parity
    reg_write(7'h30, 8'h36);            // line coder: bytes, pair, stuff after 6 ones, NRZI
    reg_write(7'h31, 8'h80);            // SYNC
    reg_write(7'h32, 8'h0D);            // CRC good value 0x800d (CRC16 sent inverted)
    reg_write(7'h33, 8'h80);
    reg_write(7'h00, 8'b0001_0001);     // restart + run E0
    fw_run = 1;
    repeat (100) @(posedge clk);
    check(bus[0] && !bus[1] && uio_oe[1:0] == 0, "USB: bus not idle in J with the device released");

    // bus reset and a keep-alive: nothing must come back
    hs_line(0);
    #(20000);
    hs_line(1);
    t_host_j = $realtime;
    #(BIT_NS);
    ext_drive[1:0] = 0;
    hs_recv;
    check(!r_ok, "USB: device answered a bus reset");
    hs_keepalive;
    hs_recv;
    check(!r_ok, "USB: device answered a keep-alive");

    // GET_DESCRIPTOR(device, 64) at address 0, host at +1.5 %
    h_pct = 1.5;
    req = '{8'h80, 8'h06, 8'h00, 8'h01, 8'h00, 8'h00, 8'h40, 8'h00};
    ctl_read;
    check(ctl_in.size() == 18, $sformatf("USB: device descriptor %0d bytes", ctl_in.size()));
    foreach (ctl_in[i]) if (i < 18) check(ctl_in[i] === dev_desc[i], $sformatf("USB: device descriptor byte %0d", i));
    $display("  GET_DESCRIPTOR(device) at address 0: 18 bytes in 3 packets");

    // a corrupted SETUP is not ACKed (the host model retries it), a stuffing error neither
    h_pct = -1.5;
    begin
      int bad0;
      bad0 = fw_bad;
      hs_token(8'h2D, 0);
      u_data = '{8'h80, 8'h06, 8'h00, 8'h02, 8'h00, 8'h00, 8'h09, 8'h00};
      hs_data(8'hC3, 1);                  // a flipped bit
      hs_recv;
      check(!r_ok, "USB: device ACKed a SETUP with a bad CRC");
      gap;
      hs_token(8'h2D, 0);
      u_data = '{8'hFF, 8'hFF, 8'h00, 8'h02, 8'h00, 8'h00, 8'h09, 8'h00};
      h_bad_stuff = 1;                    // six 1s and no stuffed 0
      hs_data(8'hC3, 0);
      hs_recv;
      check(!r_ok, "USB: device ACKed a packet with a stuffing error");
      gap;
      // a stuff bit with the wrong value: the data and the CRC16 arrive intact (BUG-040)
      hs_token(8'h2D, 0);
      u_data = '{8'hFF, 8'hFF, 8'h00, 8'h02, 8'h00, 8'h00, 8'h09, 8'h00};
      h_bad_stuff = 2;                    // six 1s, then a 1 where the stuffed 0 belongs
      hs_data(8'hC3, 0);
      hs_recv;
      check(!r_ok, "USB: device ACKed a packet with a wrong stuff bit (data and CRC intact)");
      gap;
      repeat (15000) @(posedge clk);  // the firmware reads 14-byte records: ~2000 clocks each
      check(fw_bad == bad0 + 3, $sformatf("USB: firmware saw %0d bad records, expected 3", fw_bad - bad0));
      $display("  a SETUP with a flipped bit, one with a missing and one with a wrong stuff bit: not ACKed, reported as bad");
      // the firmware busy: two (corrupted) OUT records pile up in the RX FIFO and are split apart
      bad0 = fw_bad;
      fw_hold = 1;
      for (int k = 0; k < 2; k++) begin
        hs_token(8'hE1, 0);
        u_data.delete();
        hs_data(8'h4B, 1);
        hs_recv;
        check(!r_ok, "USB: device ACKed an OUT with a bad CRC");
        gap;
      end
      fw_hold = 0;
      repeat (6000) @(posedge clk);
      check(fw_max_pile >= 2, $sformatf("USB: records did not pile up (%0d at most)", fw_max_pile));
      check(fw_bad == bad0 + 2, $sformatf("USB: firmware split %0d bad records out of the pile, expected 2", fw_bad - bad0));
      $display("  two records piled up while the firmware was busy: split apart from the end");
    end

    // SET_ADDRESS(0x15), then everything at the new address
    req = '{8'h00, 8'h05, 8'h15, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00};
    ctl_write(0);
    repeat (6000) @(posedge clk);       // the firmware switches the address (USB allows 2 ms)
    dev_addr = 7'h15;
    $display("  SET_ADDRESS(0x15)");

    // tokens for the old address and with a bad CRC5 are ignored
    hs_token(8'h69, 0);
    hs_recv;
    check(!r_ok, "USB: device answered an IN for address 0 after SET_ADDRESS");
    gap;
    begin
      logic [15:0] t;
      t = usb_tok(dev_addr, 0) ^ 16'h0800;  // a CRC5 bit flipped
      h_pkt = '{8'h69, t[7:0], t[15:8]};
      hs_send;
      hs_recv;
      check(!r_ok, "USB: device answered a token with a bad CRC5");
      gap;
    end
    $display("  tokens for address 0 and with a bad CRC5: ignored");

    h_pct = 0;
    req = '{8'h80, 8'h06, 8'h00, 8'h01, 8'h00, 8'h00, 8'h12, 8'h00};
    ctl_read;
    check(ctl_in.size() == 18, $sformatf("USB: device descriptor at the new address: %0d bytes", ctl_in.size()));
    h_pct = 1.5;
    req = '{8'h80, 8'h06, 8'h00, 8'h02, 8'h00, 8'h00, 8'h09, 8'h00};
    ctl_read;
    check(ctl_in.size() == 9, $sformatf("USB: configuration descriptor (9): %0d bytes", ctl_in.size()));
    req = '{8'h80, 8'h06, 8'h00, 8'h02, 8'h00, 8'h00, 8'hFF, 8'h00};
    ctl_read;
    check(ctl_in.size() == 18, $sformatf("USB: configuration descriptor (all): %0d bytes", ctl_in.size()));
    foreach (ctl_in[i]) if (i < 18) check(ctl_in[i] === cfg_desc[i], $sformatf("USB: configuration byte %0d", i));
    $display("  GET_DESCRIPTOR(device, configuration 9 and 18 bytes) at the new address");

    hs_keepalive;
    hs_recv;
    check(!r_ok, "USB: device answered a keep-alive");

    req = '{8'h00, 8'h09, 8'h01, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00};
    ctl_write(0);
    $display("  SET_CONFIGURATION(1)");

    h_pct = -1.5;
    req = '{8'h80, 8'h06, 8'h02, 8'h03, 8'h09, 8'h04, 8'h40, 8'h00};  // a string: not supported
    ctl_read;
    check(ctl_stalled == 1, "USB: unsupported request not STALLed");
    $display("  an unsupported request: STALL");

    // vendor write of 3 bytes, then read them back (the firmware reverses them, adds 0x55)
    req = '{8'h40, 8'h01, 8'h00, 8'h00, 8'h00, 8'h00, 8'h03, 8'h00};
    out_data = '{8'hAA, 8'hBB, 8'hCC};
    ctl_write(1);
    check(vendor_mem.size() == 3 && vendor_mem[0] == 8'hAA && vendor_mem[2] == 8'hCC, "USB: vendor write data");
    h_pct = 1.5;
    req = '{8'hC0, 8'h02, 8'h00, 8'h00, 8'h00, 8'h00, 8'h04, 8'h00};
    ctl_read;
    check(ctl_in.size() == 4 && ctl_in[0] == 8'hCC && ctl_in[1] == 8'hBB && ctl_in[2] == 8'hAA && ctl_in[3] == 8'h55,
          "USB: vendor read did not return the written data");
    $display("  vendor write (OUT data) and read back");

    // the host's ACK for an IN data packet is lost (BUG-041): the firmware queues the same
    // packet again, and the device sends the same DATA1 packet when the host asks again
    begin
      logic [7:0] first[$];
      int resends0;
      resends0 = fw_resends;
      h_pct = 0;
      req = '{8'h80, 8'h06, 8'h00, 8'h01, 8'h00, 8'h00, 8'h12, 8'h00};
      ctl_in.delete();
      hs_setup;
      h_lose_ack = 1;
      hs_in;
      check(in_res == 0 && in_pid == 8'h4B && in_pkt.size() == 8, "USB: first DATA1 packet of the descriptor");
      first.delete();
      foreach (in_pkt[i]) first.push_back(in_pkt[i]);
      hs_in;                              // NAKed until the firmware has queued it again
      check(in_res == 0 && in_pid == 8'h4B, $sformatf("USB: after a lost ACK the device sent PID %02x (res %0d), expected DATA1 again", in_pid, in_res));
      check(in_pkt.size() == first.size(), $sformatf("USB: after a lost ACK the device sent %0d bytes, first %0d", in_pkt.size(), first.size()));
      foreach (first[i]) if (i < in_pkt.size()) check(in_pkt[i] === first[i], $sformatf("USB: resent byte %0d differs", i));
      check(fw_resends == resends0 + 1, $sformatf("USB: firmware resent %0d packets, expected 1", fw_resends - resends0));
      foreach (in_pkt[i]) ctl_in.push_back(in_pkt[i]);
      hs_in;
      check(in_res == 0 && in_pid == 8'hC3, "USB: second packet after the resend is not DATA0");
      foreach (in_pkt[i]) ctl_in.push_back(in_pkt[i]);
      hs_in;
      check(in_res == 0 && in_pid == 8'h4B, "USB: third packet after the resend is not DATA1");
      foreach (in_pkt[i]) ctl_in.push_back(in_pkt[i]);
      out_data.delete();
      hs_out(8'h4B);
      check(ctl_in.size() == 18, $sformatf("USB: descriptor after a lost ACK: %0d bytes", ctl_in.size()));
      foreach (ctl_in[i]) if (i < 18) check(ctl_in[i] === dev_desc[i], $sformatf("USB: descriptor byte %0d after a lost ACK", i));
      $display("  a lost ACK: the firmware queued the packet again, the device resent the same DATA1");
    end

    // bus reset (BUG-042): 10 ms of SE0 puts the device back at address 0
    begin
      int resets0;
      resets0 = fw_resets;
      hs_line(0);
      #(10ms);
      hs_line(1);
      #(BIT_NS);
      ext_drive[1:0] = 0;
      repeat (200) @(posedge clk);
      check(fw_resets == resets0 + 1, $sformatf("USB: firmware saw %0d bus resets, expected 1", fw_resets - resets0));
      dev_addr = 0;
      req = '{8'h80, 8'h06, 8'h00, 8'h01, 8'h00, 8'h00, 8'h40, 8'h00};
      ctl_read;
      check(ctl_in.size() == 18, $sformatf("USB: device descriptor at address 0 after a bus reset: %0d bytes", ctl_in.size()));
      foreach (ctl_in[i]) if (i < 18) check(ctl_in[i] === dev_desc[i], $sformatf("USB: descriptor byte %0d after a bus reset", i));
      $display("  a 10 ms bus reset: back at address 0, GET_DESCRIPTOR works again");
    end

    fw_run = 0;
    check(contention == 0, $sformatf("USB: host and device drove the bus at the same time for %0d clocks", contention));
    check(r_bad == 0, "USB: stuffing errors in the device's packets");
    check(tt_min >= 2.0 && tt_max <= 7.5, $sformatf("USB: device turnaround %0.2f to %0.2f bit times, allowed 2 to 7.5", tt_min, tt_max));
    $display("  %0d SETUPs, %0d IN packets ACKed, %0d records (up to %0d at once); turnaround %0.2f to %0.2f bit times",
             fw_setups, fw_acks, fw_records, fw_max_pile, tt_min, tt_max);

    if (errors == 0) begin
      $display("PASS");
      $finish;
    end else $fatal(1, "FAILED with %0d error(s)", errors);
  end

  initial begin
    #60ms;
    $fatal(1, "FAILED: timeout");
  end
endmodule
