`timescale 1ns / 1ps
// A quad SPI NOR flash, written from the common serial-flash command set (e.g. Winbond W25Q
// datasheets: instruction timing diagrams and AC characteristics), not from qspi_flash.pbe. D87.
// SPI mode 0: inputs are sampled on the rising SCK edge; outputs change T_V after the falling
// edge (and hold the old value until then). The quad enable bit is taken as set: IO2 and IO3
// are data lines in the quad phases and ignored otherwise.
// Commands:
//   0x9F  JEDEC ID: 3 bytes on IO1
//   0x03  Read (1-1-1): 24-bit address on IO0, data on IO1
//   0x0B  Fast Read (1-1-1): address, 8 dummy clocks, data on IO1
//   0x6B  Fast Read Quad Output (1-1-4): address on IO0, 8 dummy clocks, data on IO0-IO3
//   0xEB  Fast Read Quad I/O (1-4-4): address on IO0-IO3 (6 clocks), mode byte (2 clocks),
//         4 dummy clocks, data on IO0-IO3
//   0x06  Write Enable; 0x05 Read Status Register-1 (bit 1 = WEL, on IO1)
//   0x32  Quad Input Page Program (1-1-4): address on IO0, data on IO0-IO3 (needs WEL; the
//         page is written when CS# rises; the address wraps inside its 256-byte page; WEL clears)
// Checks (counted in n_errors): input setup >= T_SU before and hold >= T_H after the rising
// edge for every line sampled; SCK high and low >= T_CLK_MIN; CS# low >= T_CSS before the first
// rising edge; a quad command with the wrong number of bits before CS# rises is reported too.
module qspi_flash_model #(
    parameter real T_V = 7.0, T_SU = 2.0, T_H = 3.0, T_CLK_MIN = 4.5, T_CSS = 5.0,
    parameter int SIZE = 4096
) (
    input  wire       sck,
    input  wire       cs_n,
    input  wire [3:0] io_in,     // the bus levels
    output logic [3:0] io_out = 4'hF,
    output logic [3:0] io_oe = 4'h0
);
  logic [7:0] mem[SIZE];
  logic [7:0] page_buf[256];
  bit   page_dirty[256];
  int   n_errors = 0, n_cmds = 0;
  bit   wel = 0;
  logic [7:0] cmd;
  logic [23:0] addr;
  int   cyc;             // rising edges since CS# fell
  logic [7:0] mode_bits;
  logic [7:0] wbyte;
  int   wcount, pidx;

  task automatic err(input string s);
    n_errors++;
    if (n_errors < 10) $display("  QSPI flash: %s at %0t", s, $time);
  endtask

  // ---- timing checks ----
  realtime t_rise = -1e9, t_fall = -1e9, t_csf = -1e9;
  realtime t_io[4];
  initial for (int i = 0; i < 4; i++) t_io[i] = -1e9;
  bit [3:0] sampled;     // the lines sampled at the last rising edge (hold check)
  for (genvar i = 0; i < 4; i++) begin : g_hold
    always @(io_in[i]) begin
      if (!cs_n && sampled[i] && $realtime - t_rise < T_H)
        err($sformatf("IO%0d hold %0.1f ns", i, $realtime - t_rise));
      t_io[i] = $realtime;
    end
  end
  always @(negedge cs_n) t_csf = $realtime;
  always @(negedge sck) begin
    if (!cs_n && $realtime - t_rise < T_CLK_MIN) err("SCK high too short");
    t_fall = $realtime;
  end

  // which lines are inputs at rising edge number c (0-based) of the current command
  function automatic bit [3:0] in_lines(input int c);
    if (c < 8) return 4'b0001;
    case (cmd)
      8'h03, 8'h0B, 8'h6B: return (c < 32) ? 4'b0001 : 4'b0000;
      8'hEB: return (c < 16) ? 4'b1111 : 4'b0000;
      8'h32: return (c < 32) ? 4'b0001 : 4'b1111;
      default: return 4'b0000;
    endcase
  endfunction

  always @(posedge sck) if (!cs_n) begin
    bit [3:0] l;
    if (cyc == 0 && $realtime - t_csf < T_CSS) err("CS# set-up before SCK too short");
    if ($realtime - t_fall < T_CLK_MIN) err("SCK low too short");
    t_rise = $realtime;
    l = in_lines(cyc);
    sampled = l;
    for (int i = 0; i < 4; i++)
      if (l[i] && $realtime - t_io[i] < T_SU) err($sformatf("IO%0d set-up %0.1f ns (edge %0d)", i, $realtime - t_io[i], cyc));
    if (cyc < 8) cmd = {cmd[6:0], io_in[0]};
    else case (cmd)
      8'h03, 8'h0B, 8'h6B, 8'h32:
        if (cyc < 32) addr = {addr[22:0], io_in[0]};
        else if (cmd == 8'h32) begin
          wbyte = {wbyte[3:0], io_in};
          if ((cyc - 32) % 2 == 1) begin
            pidx = (int'(addr[7:0]) + wcount) % 256;
            page_buf[pidx] = wbyte;
            page_dirty[pidx] = 1;
            wcount++;
          end
        end
      8'hEB:
        if (cyc < 14) addr = {addr[19:0], io_in};
        else if (cyc < 16) mode_bits = {mode_bits[3:0], io_in};
      default: ;
    endcase
    cyc++;
    if (cyc == 8) begin
      n_cmds++;
      if (cmd == 8'h06) wel = 1;
    end
  end

  // ---- outputs: after the falling edge that follows rising edge number `cyc` ----
  function automatic logic [7:0] rd(input int a);
    return mem[a % SIZE];
  endfunction
  // the outputs change T_V after the falling edge (non-blocking with a delay: the old value
  // holds until then)
  logic [3:0] v_n;
  task automatic drive(input logic [3:0] oe);
    io_oe <= #(T_V) oe;
    io_out <= #(T_V) v_n;
  endtask
  always @(negedge sck) if (!cs_n) begin
    int k, st;
    logic [7:0] b;
    case (cmd)
      8'h9F: if (cyc >= 8) begin
               k = cyc - 8;
               b = (k / 8 == 0) ? 8'hEF : (k / 8 == 1) ? 8'h40 : 8'h16;
               begin v_n = 4'b1111; v_n[1] = b[7 - k % 8]; drive(4'b0010); end
             end
      8'h05: if (cyc >= 8) begin
               k = cyc - 8;
               b = {6'b0, wel, 1'b0};
               begin v_n = 4'b1111; v_n[1] = b[7 - k % 8]; drive(4'b0010); end
             end
      8'h03, 8'h0B: begin
               st = (cmd == 8'h03) ? 32 : 40;
               if (cyc >= st) begin
                 k = cyc - st;
                 b = rd(addr + k / 8);
                 begin v_n = 4'b1111; v_n[1] = b[7 - k % 8]; drive(4'b0010); end
               end
             end
      8'h6B, 8'hEB: begin
               st = (cmd == 8'h6B) ? 40 : 20;
               if (cyc >= st) begin
                 k = cyc - st;
                 b = rd(addr + k / 2);
                 begin v_n = (k % 2 == 0) ? b[7:4] : b[3:0]; drive(4'b1111); end
               end
             end
      default: ;
    endcase
  end

  // ---- CS# high: end of the command ----
  always @(posedge cs_n) begin
    io_oe <= #(T_V + 0.1) 4'h0;     // (after any output change still in flight)
    io_oe = 4'h0;
    if (cyc > 0 && cyc < 8) err($sformatf("CS# rose after %0d clocks", cyc));
    if (cmd == 8'h32 && cyc >= 32) begin
      if (!wel) err("page program without write enable");
      else begin
        if ((cyc - 32) % 2 != 0) err("page program: half a byte");
        for (int i = 0; i < 256; i++)
          if (page_dirty[i]) begin
            pidx = (int'(addr[23:8]) * 256 + i) % SIZE;
            mem[pidx] = page_buf[i];
          end
        wel = 0;
      end
    end
    if (cmd == 8'hEB && mode_bits[5:4] == 2'b10) err("continuous read mode requested (not modelled)");
  end
  always @(negedge cs_n) begin
    cyc = 0;
    cmd = 0;
    addr = 0;
    wcount = 0;
    for (int i = 0; i < 256; i++) page_dirty[i] = 0;
  end
endmodule
