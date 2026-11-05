`timescale 1ns / 1ps
// An ARM ADIv5 SW-DP target (with the SWJ-DP JTAG-to-SWD switch and one MEM-AP-like access
// port), written from the ADIv5.2 specification (IHI 0031), not from swd.pbe, for tb_debug.
//
// Wire protocol (ADIv5.2 B4.2), sampled at the rising edge of SWCLK; the target drives SWDIO
// after a rising edge (TCO ns later):
//   Request: Start (1), APnDP, RnW, A[2], A[3], Parity (even, over the 4 bits), Stop (0), Park (1)
//   Trn (1 cycle), ACK[0..2] (OK = 1,0,0  WAIT = 0,1,0  FAULT = 0,0,1), then
//   read OK:  RDATA[0..31], Parity, Trn            write OK: Trn, WDATA[0..31], Parity
//   WAIT or FAULT: Trn, and no data phase (overrun detection, CTRL/STAT.ORUNDETECT, is not
//   modelled: it stays 0).
// Line reset: 50 or more cycles with SWDIO high; the next request needs 2 idle (low) cycles
// first, and after a line reset the first request must read DPIDR (B4.3.3: otherwise a protocol
// error). A protocol error (bad parity, stop or park in a request, or the above) makes the
// target not respond (the host sees ACK = 1,1,1) until the next line reset (B4.2.5).
// SWJ-DP (B5.2): the port starts in JTAG mode, where it ignores SWD; 50 or more ones followed by
// the 16-bit sequence 0xE79E (LSB first) select SWD, which then needs a line reset. The port
// watches for the sequence in SWD mode too (sending it again keeps SWD): a request read from
// those 16 bits is ignored without counting a protocol error.
//
// Registers (DPv1): DP 0x0 R DPIDR, W ABORT; 0x4 CTRL/STAT; 0x8 W SELECT, R RESEND; 0xC R RDBUFF.
//   CTRL/STAT: [5] STICKYERR, [7] WDATAERR, [28] CDBGPWRUPREQ -> [29] ACK,
//   [30] CSYSPWRUPREQ -> [31] ACK. ABORT: [2] STKERRCLR, [3] WDERRCLR (others clear what they
//   name or do nothing here). SELECT: [31:24] APSEL, [7:4] APBANKSEL.
//   While STICKYERR or WDATAERR is set every access gets FAULT except a DPIDR read, a CTRL/STAT
//   read and an ABORT write (B4.2.2). A write whose data parity is wrong is not done and sets
//   WDATAERR (B4.2.4).
//   AP 0 (APSEL = 0): 0x00 CSW, 0x04 TAR, 0x0C DRW (reads and writes mem[TAR[5:2]]), 0xFC IDR.
//   AP reads are posted (B2.2.2): an AP read returns the result of the previous AP read, and its
//   own result is in RDBUFF.
// Test controls (set by the testbench): wait_n gives WAIT to the next wait_n AP accesses (and
// RDBUFF reads); fault_next makes the next AP access fail (FAULT, STICKYERR set); bad_par_next
// sends the next read's data with the wrong parity.
module swd_dp #(
    parameter logic [31:0] DPIDR = 32'h2BA01477,
    parameter logic [31:0] AP_IDR = 32'h24770011,
    parameter real         TCO   = 8.0
) (
    input  logic swclk,
    input  logic swdio,     // the line level
    output logic drive,     // the target drives SWDIO
    output logic dout
);
  typedef enum logic [2:0] {JTAG, LOCKOUT, RESET, IDLE, REQ, XFER} st_t;
  st_t st = JTAG;

  // test controls and statistics
  int wait_n = 0;
  bit fault_next = 0, bad_par_next = 0;
  int n_line_reset = 0, n_switch = 0, n_proto_err = 0, n_ok = 0, n_wait = 0, n_fault = 0;
  int n_wdataerr = 0, n_writes = 0;

  // registers
  logic [31:0] ctrl = '0, select = '0, rdbuff = '0, last_read = '0;
  logic [31:0] csw = 32'h0300_0002, tar = '0;
  logic [31:0] mem[16];
  bit need_dpidr = 1;

  // line state
  int ones = 0;                    // consecutive sampled ones (while the host drives)
  bit sw_armed = 0;                // collecting the 16 bits after >= 50 ones
  int sw_k = 0;
  logic [15:0] sw_seq;
  int idle_zeros = 0;
  logic [7:0] req;
  int k = 0;                       // bit counter in REQ, cycle counter in XFER
  bit apndp, rnw;
  logic [1:0] a;                   // A[3:2]
  logic [2:0] ack;                 // ACK bits, bit 0 first on the wire
  logic [31:0] data;
  logic dpar;

  task automatic put(input logic en, input logic v);
    drive <= #(TCO) en;
    dout  <= #(TCO) v;
  endtask

  function automatic bit sticky();
    return ctrl[5] || ctrl[7];
  endfunction

  // the value a read returns, and its side effects (done when the request is accepted)
  function automatic logic [31:0] do_read();
    logic [31:0] v;
    if (!apndp) begin
      case (a)
        2'd0: v = DPIDR;
        2'd1: v = {ctrl[30], ctrl[30], ctrl[28], ctrl[28], 20'd0, ctrl[7:0]};
        2'd2: v = last_read;   // RESEND
        default: v = rdbuff;   // RDBUFF
      endcase
      last_read = v;
      return v;
    end
    v = rdbuff;                // posted: the previous AP read's result
    if (select[31:24] != 0) rdbuff = 32'd0;
    else case ({select[7:4], a})
      6'h00: rdbuff = csw;
      6'h01: rdbuff = tar;
      6'h03: rdbuff = mem[tar[5:2]];
      6'h3F: rdbuff = AP_IDR;
      default: rdbuff = 32'd0;
    endcase
    last_read = v;
    return v;
  endfunction

  task automatic do_write(input logic [31:0] v);
    n_writes++;
    if (!apndp) begin
      case (a)
        2'd0: begin  // ABORT
          if (v[2]) ctrl[5] = 1'b0;
          if (v[3]) ctrl[7] = 1'b0;
        end
        2'd1: ctrl = {v[31:8] & 24'h500000, ctrl[7:0]};  // the power-up requests
        2'd2: select = v;
        default: ;
      endcase
    end else if (select[31:24] == 0) begin
      case ({select[7:4], a})
        6'h00: csw = v;
        6'h01: tar = v;
        6'h03: mem[tar[5:2]] = v;
        default: ;
      endcase
    end
  endtask

  function automatic logic [2:0] respond();
    bit ap_like;
    ap_like = apndp || (!apndp && rnw && a == 2'd3);  // AP accesses and RDBUFF reads can stall
    if (sticky() && !(!apndp && rnw && a <= 2'd1) && !(!apndp && !rnw && a == 2'd0)) return 3'b100;
    if (ap_like && wait_n > 0) begin
      wait_n--;
      return 3'b010;
    end
    if (apndp && fault_next) begin
      fault_next = 0;
      ctrl[5] = 1'b1;  // STICKYERR
      return 3'b100;
    end
    return 3'b001;
  endfunction

  always @(posedge swclk) begin
    logic b;
    b = swdio;
    // ones counted only while the host drives the line
    if (!(st == XFER && drive)) begin
      if (b) ones++;
      else begin
        if (ones >= 50) begin
          sw_armed = 1;
          sw_k = 0;
        end
        ones = 0;
      end
    end
    if (sw_armed) begin
      sw_seq[sw_k] = b;
      sw_k++;
    end
    if (st == JTAG) begin
      if (sw_armed && sw_k == 16 && sw_seq == 16'hE79E) begin
        st = LOCKOUT;  // SWD selected; a line reset follows
        n_switch++;
      end
    end else if (ones >= 50 && st != RESET) begin
      if (st == XFER) put(1'b0, 1'b1);
      st = RESET;
      idle_zeros = 0;
      need_dpidr = 1;
      n_line_reset++;
    end else case (st)
      RESET: begin
        if (b) idle_zeros = 0;
        else if (++idle_zeros >= 2) st = IDLE;
      end
      IDLE: if (b) begin
        req = 8'h01;
        k = 1;
        st = REQ;
      end
      REQ: begin
        req[k] = b;
        k++;
        if (k == 8) begin
          apndp = req[1];
          rnw   = req[2];
          a     = req[4:3];
          if (req[5] != ^req[4:1] || req[6] != 1'b0 || req[7] != 1'b1 ||
              (need_dpidr && !(!apndp && rnw && a == 2'd0))) begin
            // eight ones are the start of a line reset, and a request read from the bits of a
            // selection sequence after one is part of that sequence: ignored the same way, but
            // not host errors
            if (req != 8'hFF && !(sw_armed && ((sw_seq ^ 16'hE79E) & ((16'd1 << sw_k) - 16'd1)) == 0))
              n_proto_err++;
            st = LOCKOUT;
          end else begin
            ack = respond();
            if (ack == 3'b001) n_ok++;
            else if (ack == 3'b010) n_wait++;
            else n_fault++;
            if (ack == 3'b001 && rnw) begin
              data = do_read();
              if (!apndp && a == 2'd0) need_dpidr = 0;
              dpar = ^data ^ bad_par_next;
              bad_par_next = 0;
            end
            k = 0;
            st = XFER;
          end
        end
      end
      XFER: begin
        k++;  // k = 1 at the turnaround's rising edge, the first after Park
        if (k <= 3) put(1'b1, ack[k-1]);                         // ACK after edges 1..3
        else if (ack == 3'b001 && rnw) begin
          if (k <= 35) put(1'b1, data[k-4]);                     // RDATA after edges 4..35
          else if (k == 36) put(1'b1, dpar);
          else if (k == 37) put(1'b0, 1'b1);                     // release: Trn
          else st = IDLE;                                        // edge 38 is the Trn edge
        end else if (ack == 3'b001) begin
          if (k == 4) put(1'b0, 1'b1);                           // release after ACK: Trn
          else if (k >= 6 && k <= 37) data[k-6] = b;             // WDATA at edges 6..37
          else if (k == 38) begin
            if (b != ^data) begin
              ctrl[7] = 1'b1;  // WDATAERR: the write is not done
              n_wdataerr++;
            end else do_write(data);
            st = IDLE;
          end
        end else begin
          if (k == 4) put(1'b0, 1'b1);                           // WAIT/FAULT: release, Trn
          else st = IDLE;                                        // edge 5 is the Trn edge
        end
      end
      default: ;  // LOCKOUT: only a line reset
    endcase
    if (sw_armed && sw_k == 16) begin
      sw_armed = 0;
      if (st != JTAG && sw_seq == 16'hE79E && st != LOCKOUT) st = LOCKOUT;  // SWD stays selected
    end
  end

  initial begin
    drive = 1'b0;
    dout = 1'b1;
    foreach (mem[i]) mem[i] = 32'h1000_0000 + i;
  end
endmodule
