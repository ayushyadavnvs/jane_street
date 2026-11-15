`timescale 1ns / 1ps
// Blind generality benchmark 3: LIN 2.x commander (lin_commander.pbe) against a LIN responder
// node and bus checker written from the LIN 2.2A specification.
//   engine 0: lin_commander.pbe; TXD = pin 0, RXD = pin 1. The bus is the wired AND of the
//   commander's and the responder's drivers (dominant = low); RXD sees the bus (with the echo).
// The node checks every header: break >= 13 bit times, delimiter >= 1, sync 0x55, the protected
// ID's parity (P0 = ID0^ID1^ID2^ID4, P1 = !(ID1^ID3^ID4^ID5)). It answers the frames it
// publishes (ID 0x22: 8 bytes, enhanced checksum; ID 0x23: 2 bytes with a wrong checksum) and
// checks the checksum of the frames the commander publishes (ID 0x11 enhanced; 0x3C classic).
// The testbench's host computes the ID parity and the checksums (the program's stated limit).
module tb_lin;
  localparam real CLK_NS = 16.6672;  // 60 MHz
  localparam int HOST_HALF = 4;

  logic clk = 0, rst_n = 0;
  always #(CLK_NS / 2) clk = ~clk;
  logic [7:0] ui_in = 8'b0000_0010;
  wire  [7:0] uo_out, uio_out, uio_oe;
  logic node_tx = 1;
  wire  chip_tx = !uio_oe[0] | uio_out[0];
  wire  lin = chip_tx & node_tx;
  wire  [7:0] bus = {6'b0, lin, lin};
  tt_um_ayushyadavnvs_pbe dut (.ui_in, .uo_out, .uio_in(bus), .uio_out, .uio_oe, .ena(1'b1), .clk, .rst_n);
  `include "tb_host.svh"

  int pass = 0;
  task automatic result(input string name, input bit ok);
    check(ok, name);
    if (ok) pass++;
    $display("  LIN  %-62s %s", name, ok ? "PASS" : "FAIL");
  endtask

  // ---------------- LIN node (responder) and header checker ----------------
  real bit_ns = 52083.3;             // 19200 baud
  int n_headers = 0, n_hdr_err = 0, n_rx_ok = 0, n_rx_bad = 0, n_resp = 0;
  real brk_bits = 0, del_bits = 0;
  logic [7:0] node_rx[$];            // the data of the last frame received from the commander
  logic [5:0] last_id;
  bit silent = 0;                    // do not answer (a missing node)

  function automatic logic [7:0] pid_of(input logic [5:0] id);
    return {~(id[1] ^ id[3] ^ id[4] ^ id[5]), id[0] ^ id[1] ^ id[2] ^ id[4], id};
  endfunction
  // checksum: 8-bit sum with end-around carry, inverted; enhanced includes the protected ID
  logic [7:0] cs_q[$];
  function automatic logic [7:0] lin_sum(input logic [7:0] seed);
    logic [8:0] s;
    s = {1'b0, seed};
    foreach (cs_q[i]) begin
      s = s + cs_q[i];
      if (s[8]) s = {1'b0, s[7:0]} + 9'd1;
    end
    return ~s[7:0];
  endfunction

  task automatic node_byte(output logic [7:0] d, output bit ok);
    // called at the start bit's falling edge
    #(bit_ns * 1.5);
    for (int i = 0; i < 8; i++) begin
      d[i] = lin;
      #(bit_ns);
    end
    ok = lin;                        // stop bit
  endtask
  task automatic node_send(input logic [7:0] d);
    node_tx = 0;
    #(bit_ns);
    for (int i = 0; i < 8; i++) begin
      node_tx = d[i];
      #(bit_ns);
    end
    node_tx = 1;
    #(bit_ns);
  endtask

  initial forever begin
    realtime t0;
    logic [7:0] d, pid, sum;
    bit ok;
    int n;
    // wait for a break: the bus low for 11 bit times or more
    @(negedge lin);
    t0 = $realtime;
    @(posedge lin);
    if (($realtime - t0) / bit_ns >= 11.0) begin
      brk_bits = ($realtime - t0) / bit_ns;
      t0 = $realtime;
      @(negedge lin);
      del_bits = ($realtime - t0) / bit_ns;
      n_headers++;
      if (brk_bits < 13.0 || del_bits < 1.0) n_hdr_err++;
      node_byte(d, ok);
      if (d != 8'h55 || !ok) n_hdr_err++;
      @(negedge lin);
      node_byte(pid, ok);
      if (!ok || pid != pid_of(pid[5:0])) n_hdr_err++;
      else begin
        last_id = pid[5:0];
        case (pid[5:0])
          6'h22: if (!silent) begin   // published by this node: 8 bytes, enhanced checksum
            #(bit_ns * 2);            // response space
            cs_q = {};
            for (int i = 0; i < 8; i++) begin
              d = 8'hA0 + 8'(i * 17);
              cs_q.push_back(d);
              node_send(d);
            end
            node_send(lin_sum(pid));
            n_resp++;
          end
          6'h23: if (!silent) begin   // 2 bytes and a wrong checksum
            #(bit_ns * 2);
            node_send(8'h12);
            node_send(8'h34);
            node_send(8'h00);
            n_resp++;
          end
          6'h11, 6'h3C: begin         // published by the commander: 4 or 8 data bytes
            n = (pid[5:0] == 6'h11) ? 4 : 8;
            cs_q = {};
            for (int i = 0; i < n; i++) begin
              @(negedge lin);
              node_byte(d, ok);
              cs_q.push_back(d);
            end
            @(negedge lin);
            node_byte(sum, ok);
            // diagnostic frames (0x3C) use the classic checksum, the others the enhanced one
            if (sum == lin_sum(pid[5:0] == 6'h3C ? 8'h00 : pid)) begin
              n_rx_ok++;
              node_rx = cs_q;
            end else n_rx_bad++;
          end
          default: ;                  // nobody answers
        endcase
      end
    end
  end

  // ---------------- host ----------------
  logic [7:0] hq[$];                 // data bytes of a frame the commander publishes
  logic [7:0] rsp[$];                // what came back
  logic [7:0] trailer;
  task automatic frame(input logic [5:0] id, input bit classic, input int rx_n);
    logic [7:0] x, c, pid;
    bit f;
    int n;
    pid = pid_of(id);                // the host's job (see the program's LIMIT)
    cs_q = hq;
    flag_clear(0, 0);                // (the engine clears it too, but only 3 ticks into the record)
    cs(0);
    spi_byte({1'b1, 7'h16}, x);
    spi_byte(8'(1 + (hq.size() ? hq.size() + 1 : 0)), x);
    spi_byte(pid, x);
    foreach (hq[i]) spi_byte(hq[i], x);
    if (hq.size()) spi_byte(lin_sum(classic ? 8'h00 : pid), x);
    spi_byte(8'(rx_n), x);
    cs(1);
    // wait for FLAG0 (done)
    n = 0;
    do begin
      repeat (2000) @(posedge clk);
      flag_get(0, 0, f);
      n++;
    end while (!f && n < 4000);
    check(f, "the commander never finished the frame");
    rsp = {};
    reg_read(7'h0A, c);
    for (int i = 0; i < c; i++) begin
      reg_read(7'h16, x);
      rsp.push_back(x);
    end
    trailer = rsp.size() ? rsp[rsp.size() - 1] : 8'hXX;
  endtask

  task automatic setup(input int baud);
    int div;
    div = int'(60.0e6 / (4.0 * baud)) - 1;
    bit_ns = 1.0e9 / baud;
    reg_write(7'h00, 8'b0100_0000);
    reg_write(7'h10, 8'(div));
    reg_write(7'h11, 8'(div >> 8));
    reg_write(7'h12, 8'd0);
    reg_write(7'h13, 8'd1);           // JMP_PIN = RXD
    reg_write(7'h14, 8'h00);
    reg_write(7'h15, 8'd0);
    reg_write(7'h1B, 8'h00);
    reg_write(7'h1C, 8'd56);          // 14 bit times
    reg_write(7'h1D, 8'd0);
    reg_write(7'h1E, 8'h41);          // no parity, vector at word 1
    reg_write(7'h00, 8'b0001_0001);
    repeat (4000) @(posedge clk);
  endtask

  task automatic scenarios(input int baud);
    bit ok;
    int e0;
    logic [7:0] a, b;
    setup(baud);
    e0 = n_hdr_err;
    // 1: a frame the commander publishes, enhanced checksum
    hq = {};
    hq.push_back(8'h01); hq.push_back(8'hFF); hq.push_back(8'h80); hq.push_back(8'h7E);
    n_rx_ok = 0;
    frame(6'h11, 0, 0);
    ok = n_rx_ok == 1 && trailer == 8'h00 && rsp.size() == 1 && node_rx.size() == 4;
    result($sformatf("%0d baud: commander publishes ID 0x11, enhanced checksum (break %0.1f bits, delimiter %0.1f)",
                     baud, brk_bits, del_bits), ok);
    // 2: diagnostic frame 0x3C, 8 bytes, classic checksum
    hq = {};
    for (int i = 0; i < 8; i++) hq.push_back(8'($urandom));
    n_rx_ok = 0;
    frame(6'h3C, 1, 0);
    result($sformatf("%0d baud: master request 0x3C, 8 bytes, classic checksum", baud),
           n_rx_ok == 1 && trailer == 8'h00);
    // 3: a frame the node publishes: 8 bytes + enhanced checksum, checked by the host
    hq = {};
    frame(6'h22, 0, 9);
    ok = rsp.size() == 10 && trailer == 8'h00;
    cs_q = {};
    for (int i = 0; i < 8 && ok; i++) begin
      a = rsp[i];
      ok &= a == 8'hA0 + 8'(i * 17);
      cs_q.push_back(a);
    end
    if (ok) begin
      a = rsp[8];
      ok = a == lin_sum(pid_of(6'h22));
    end
    result($sformatf("%0d baud: node publishes ID 0x22: 8 bytes, checksum good at the host", baud), ok);
    // 4: a response with a wrong checksum: the host sees it
    frame(6'h23, 0, 3);
    cs_q = {};
    ok = rsp.size() == 4 && trailer == 8'h00;
    if (ok) begin
      a = rsp[0]; cs_q.push_back(a);
      a = rsp[1]; cs_q.push_back(a);
      a = rsp[2];
      ok = a != lin_sum(pid_of(6'h23));
    end
    result($sformatf("%0d baud: a response with a wrong checksum is delivered for the host to reject", baud), ok);
    // 5: nobody answers: timeout
    frame(6'h05, 0, 3);
    result($sformatf("%0d baud: no responder: timeout trailer 0xFF, no data", baud),
           rsp.size() == 1 && trailer == 8'hFF);
    // 6: the node stops after... the next frame still works
    hq = {};
    frame(6'h22, 0, 9);
    result($sformatf("%0d baud: the next frame after a timeout", baud), rsp.size() == 10 && trailer == 8'h00);
    check(n_hdr_err == e0, $sformatf("the node saw %0d bad headers", n_hdr_err - e0));
  endtask

  initial begin
    repeat (5) @(posedge clk);
    @(negedge clk) rst_n = 1;
    repeat (5) @(posedge clk);
    load_program("lin_image.hex");
    scenarios(19200);
    scenarios(9600);
    $display("  LIN  %0d headers checked by the node, %0d responses sent", n_headers, n_resp);
    if (errors == 0 && pass == 12) begin
      $display("PASS: LIN");
      $finish;
    end else $fatal(1, "FAILED with %0d error(s)", errors);
  end
  initial begin
    #2000ms;
    $fatal(1, "FAILED: timeout");
  end
endmodule
