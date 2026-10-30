`timescale 1ns / 1ps
// End-to-end test of tt_um_pbe through its real pins only.
//
//  Test 1  UART: engine 0 runs uart_tx on pin 0, engine 1 runs uart_rx on pin 1,
//          pin 0 is looped back to pin 1. An independent UART monitor also decodes pin 0.
//  Test 2  SPI:  engine 0 runs spi_ctrl on pins 0..3 against a behavioural mode-0 peripheral.
//
// Every pin has a pull-up and lines are wired-AND, like a real open-drain bus.
module tb_pbe;
  localparam real CLK_NS = 20.8333;  // 48 MHz, the planned clock
  localparam int HOST_HALF = 8;  // host SCK half period in clocks (SCK = clk / 16)
  localparam int UART_BIT = 100;  // clocks per UART bit (500 kbaud at 50 MHz)

  logic clk = 0, rst_n = 0;
  always #(CLK_NS / 2) clk = ~clk;

  logic [7:0] ui_in = 8'b0000_0010;  // CS_n high
  wire  [7:0] uo_out, uio_out, uio_oe;
  logic [7:0] ext_drive = '0, ext_val = '0;
  logic       loop01 = 0;

  wire  [7:0] chip_lvl = ~uio_oe | uio_out;  // released pins float high
  wire  [7:0] ext_lvl  = ~ext_drive | ext_val;
  wire  [7:0] dev_pull;                       // 1-Wire device models pulling low
  wire  [7:0] bus      = chip_lvl & ext_lvl & ~dev_pull & (loop01 ? {6'h3f, chip_lvl[0], 1'b1} : 8'hff);

  tt_um_ayushyadavnvs_pbe dut (
      .ui_in, .uo_out, .uio_in(bus), .uio_out, .uio_oe, .ena(1'b1), .clk, .rst_n
  );

  // Verification-only scalar pins and phase markers; disabled for normal tests.
`ifdef PBE_SIGROK
  integer sigrok_phase = 0;
  wire p0 = bus[0], p1 = bus[1], p2 = bus[2], p3 = bus[3];
  wire p4 = bus[4], p5 = bus[5], p6 = bus[6], p7 = bus[7];
  initial begin
    $dumpfile("tb_pbe_pins.vcd");
    $dumpvars(0, p0, p1, p2, p3, p4, p5, p6, p7, sigrok_phase);
  end
`endif

  `include "tb_host.svh"

  // ---------------- independent UART monitor on pin 0 ----------------
  logic [7:0] uart_seen[$];
  bit uart_mon_en = 0;
  initial begin
    forever begin
      @(negedge bus[0]);
      if (uart_mon_en) begin
        logic [7:0] b;
        repeat (UART_BIT / 2) @(posedge clk);
        check(bus[0] == 0, "UART monitor: start bit not low at its middle");
        for (int i = 0; i < 8; i++) begin
          repeat (UART_BIT) @(posedge clk);
          b[i] = bus[0];
        end
        repeat (UART_BIT) @(posedge clk);
        check(bus[0] == 1, "UART monitor: stop bit not high");
        uart_seen.push_back(b);
      end
    end
  end

  // ---------------- behavioural SPI peripheral, mode 0, pins 0..3 ----------------
  logic [7:0] spi_reply[$], spi_got[$];
  bit spi_dev_en = 0;
  logic [7:0] dev_tx, dev_rx;
  int dev_bits;
  bit dev_loaded = 0;  // dev_tx holds the next reply byte
  function automatic logic [7:0] next_reply();
    return spi_reply.size() ? spi_reply.pop_front() : 8'hEE;
  endfunction
  always @(negedge bus[3]) if (spi_dev_en) begin
    if (!dev_loaded) dev_tx = next_reply();
    dev_loaded = 1;
    dev_bits = 0;
    ext_drive[2] = 1;
    ext_val[2] = dev_tx[7];
  end
  always @(posedge bus[3]) if (spi_dev_en) ext_drive[2] = 0;
  always @(posedge bus[0]) if (spi_dev_en && !bus[3]) begin
    dev_rx = {dev_rx[6:0], bus[1]};
    dev_bits++;
    if (dev_bits == 8) begin
      spi_got.push_back(dev_rx);
      dev_bits = 0;
      dev_loaded = 0;
    end
  end
  always @(negedge bus[0]) if (spi_dev_en && !bus[3]) begin
    if (dev_bits == 0) begin
      dev_tx = next_reply();
      dev_loaded = 1;
    end else dev_tx = {dev_tx[6:0], 1'b0};
    ext_val[2] = dev_tx[7];
  end


  // ---------------- behavioural I2C peripheral at 0x50, SDA = pin 4, SCL = pin 5 ----------------
  // Register device: write [reg] [data...] stores bytes; reads return bytes from the pointer.
  // It holds SCL low for I2C_STRETCH clocks after bit 4 and bit 8 of every byte (clock stretching).
  // SMBus PEC (i_pec_mode): it keeps its own CRC-8 (poly 0x07) over every byte since the last
  // STOP, in both directions, and sends it as the third byte of a read (i_pec_corrupt flips a bit).
  localparam int SDA = 4, SCL = 5, I2C_STRETCH = 120;
  localparam logic [6:0] I2C_ADDR = 7'h50;
  localparam int I_IDLE = 0, I_ADDR = 1, I_REG = 2, I_WDATA = 3, I_RDATA = 4;
  logic [7:0] i2c_mem[256];
  logic [7:0] i_ptr, i_sh;
  int i_st = I_IDLE, i_bit = 0, i_starts = 0, i_stops = 0, i_stretches = 0;
  bit i2c_en = 0, i_acking = 0;
  bit i_pec_mode = 0, i_pec_corrupt = 0;
  logic [7:0] i_pec = 0, i_pec_at_stop = 0;
  int i_rd_count = 0;

  // CRC-8 as SMBus defines it: poly x^8 + x^2 + x + 1, init 0, MSB first, no final XOR
  function automatic logic [7:0] crc8(input logic [7:0] crc, input logic [7:0] b);
    crc ^= b;
    for (int i = 0; i < 8; i++) crc = crc[7] ? {crc[6:0], 1'b0} ^ 8'h07 : {crc[6:0], 1'b0};
    return crc;
  endfunction

  bit scl_stretched = 0, scl_after_stretch = 0;  // declared before the peripheral model uses it (BUG-037)

  task automatic i_sda(input bit v);  // open drain: 0 pulls low, 1 releases
    ext_drive[SDA] = !v;
    ext_val[SDA] = 0;
  endtask

  always @(negedge bus[SDA]) if (i2c_en && bus[SCL]) begin  // START
    i_st = I_ADDR;
    i_bit = 0;
    i_rd_count = 0;
    i_starts++;
  end
  always @(posedge bus[SDA]) if (i2c_en && bus[SCL]) begin  // STOP
    i_st = I_IDLE;
    i_pec_at_stop = i_pec;  // 0 when the message ended in its correct PEC
    i_pec = 0;
    i_stops++;
  end
  always @(posedge bus[SCL]) if (i2c_en && i_st != I_IDLE) begin
    i_bit++;
    if (i_bit <= 8 && i_st != I_RDATA) i_sh = {i_sh[6:0], bus[SDA]};
    if (i_bit == 9 && i_st == I_RDATA && bus[SDA]) i_st = I_IDLE;  // controller NACKed: stop sending
  end
  always @(negedge bus[SCL]) if (i2c_en && i_st != I_IDLE) begin
    if (i_bit == 8) begin
      i_pec = crc8(i_pec, i_sh);  // the byte just sent or received
      i_acking = 1;
      case (i_st)
        I_ADDR:  if (i_sh[7:1] == I2C_ADDR) i_st = i_sh[0] ? I_RDATA : I_REG;
                 else begin i_st = I_IDLE; i_acking = 0; end
        I_REG:   begin i_ptr = i_sh; i_st = I_WDATA; end
        I_WDATA: begin i2c_mem[i_ptr] = i_sh; i_ptr++; end
        default: i_acking = 0;  // sending: the controller drives the ACK slot
      endcase
      i_sda(!i_acking);
    end else if (i_bit == 9) begin
      i_bit = 0;
      if (i_st == I_RDATA) begin
        if (i_pec_mode && i_rd_count == 2) i_sh = i_pec ^ {7'b0, i_pec_corrupt};
        else begin
          i_sh = i2c_mem[i_ptr];
          i_ptr++;
        end
        i_rd_count++;
        i_sda(i_sh[7]);
      end else i_sda(1);
    end else if (i_st == I_RDATA && i_bit >= 1) begin
      i_sda(i_sh[7 - i_bit]);
    end
    // clock stretching mid-byte and before the ACK slot: keep SCL low a while
    if (i_bit == 4 || i_bit == 8) begin
      ext_drive[SCL] = 1;
      ext_val[SCL] = 0;
      i_stretches++;
      scl_stretched = 1;
      repeat (I2C_STRETCH) @(posedge clk);
      ext_drive[SCL] = 0;
    end
  end
  // a read starts right after the address ACK: first bit goes out when that ACK clock ends
  always @(negedge bus[SCL]) if (i2c_en && i_st == I_RDATA && i_bit == 0 && i_acking) begin
    i_acking = 0;
  end

  // SCL timing against I2C fast mode: low >= 1.3 us, high >= 0.6 us, period >= 2.5 us (BUG-010)
  // The period check skips the cycle right after a stretch: the controller times that high
  // phase from when it sees SCL rise, which the spec allows (only low/high minimums apply).
  realtime scl_fell = 0, scl_rose = 0, scl_min_low = 1e9, scl_min_high = 1e9, scl_min_period = 1e9;
  always @(posedge bus[SCL]) if (i2c_en) begin
    if (scl_fell > 0 && $realtime - scl_fell < scl_min_low) scl_min_low = $realtime - scl_fell;
    if (scl_rose > 0 && !scl_after_stretch && $realtime - scl_rose < scl_min_period)
      scl_min_period = $realtime - scl_rose;
    scl_after_stretch = scl_stretched;
    scl_stretched = 0;
    scl_rose = $realtime;
  end
  always @(negedge bus[SCL]) if (i2c_en) begin
    if (scl_rose > 0 && $realtime - scl_rose < scl_min_high) scl_min_high = $realtime - scl_rose;
    scl_fell = $realtime;
  end

  // FLAG1 must clear only once the STOP is on the bus (BUG-011). This monitor looks inside the
  // design (the flags register), so it runs on the RTL only, not on the gate-level netlist.
`ifndef GL_TEST
  wire i2c_stop_flag = dut.flags[fphys(1, 1)];  // engine 1's FLAG1
  always @(negedge i2c_stop_flag) if (i2c_en)
    check(bus[SDA] && bus[SCL], "I2C: FLAG1 (STOP) cleared before the STOP finished");
`endif

  // host-side helpers for the i2c_ctrl program on engine 1
  // FLAG0 = START: happens when the next byte is queued.
  // FLAG1 = STOP: happens right away; wait until the engine clears the flag.
  task automatic i2c_cond(input logic [3:0] flag);
    bit b;
    wait_tx_empty(1);
    if (flag[0]) flag_set(1, 0);
    if (flag[1]) begin
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


  // ---------------- 1-Wire: two DS18B20-style devices on pin 6 ----------------
  localparam int OW = 6;
  localparam logic [63:0] ROM_A = 64'h2C000800003C5A28;  // family 28, valid CRC8
  localparam logic [63:0] ROM_B = 64'h1B000800003C5B28;
  localparam logic [71:0] OW_SP = 72'h1C100CFF7F464B0550;  // DS18B20 power-up scratchpad, CRC 1C
  bit ow_en_a = 0, ow_en_b = 0, ow_mon = 0;
  wire ow_pull_a, ow_pull_b;
  localparam logic [71:0] OW_SP_25C = 72'h70100CFF7F464B0191;  // after CONVERT T: 25.0625 C, CRC 70
  localparam logic [79:0] OW_BLK = 80'hB41E8877665544332211;   // 8 bytes + inverted CRC-16 (1E B4)
  wire ow_strong = uio_oe[OW] && uio_out[OW];                   // chip drives DQ hard high
  ow_device #(.ROM(ROM_A), .SP(OW_SP), .SP_CONV(OW_SP_25C), .BLK(OW_BLK)) u_ow_a
      (.dq(bus[OW]), .enable(ow_en_a), .hard_hi(ow_strong), .pull(ow_pull_a));
  ow_device #(.ROM(ROM_B), .SP(OW_SP), .SP_CONV(OW_SP_25C), .BLK(OW_BLK)) u_ow_b
      (.dq(bus[OW]), .enable(ow_en_b), .hard_hi(ow_strong), .pull(ow_pull_b));
  wire ow_pull_any = ow_pull_a | ow_pull_b;
  realtime ow_last_rise = 0, ow_spu_on = 0;  // DQ's last rising edge; when the strong pull-up began
  always @(posedge bus[OW]) ow_last_rise = $realtime;
  always @(posedge ow_strong) ow_spu_on = $realtime;

  // Slot timing: every low pulse the controller makes on its own must be a write-1/read pulse
  // (1-15 us), a write-0 pulse (60-120 us) or a reset (>= 480 us); recovery >= 1 us.
  realtime ow_fell = 0, ow_rose = 0;
  bit ow_touched = 0;
  int ow_short = 0, ow_long = 0, ow_resets = 0, ow_bad = 0;
  always @(posedge ow_pull_any) ow_touched = 1;
  always @(negedge bus[OW]) if (ow_mon) begin
    if (ow_rose > 0 && $realtime - ow_rose < 1000) begin
      ow_bad++;
      check(0, $sformatf("1-Wire: recovery %0.0f ns, needs 1 us", $realtime - ow_rose));
    end
    ow_fell = $realtime;
  end
  always @(posedge bus[OW]) if (ow_mon) begin
    if (!ow_touched) begin
      if ($realtime - ow_fell >= 1000 && $realtime - ow_fell <= 15000) ow_short++;
      else if ($realtime - ow_fell >= 60000 && $realtime - ow_fell <= 120000) ow_long++;
      else if ($realtime - ow_fell >= 480000) ow_resets++;
      else begin
        ow_bad++;
        check(0, $sformatf("1-Wire: controller low pulse of %0.0f ns", $realtime - ow_fell));
      end
    end
    ow_touched = 0;
    ow_rose = $realtime;
  end

  // Host side of the onewire_ctrl program on engine 1 (static tasks: see BUG-006).
  logic [7:0] ow_tx, ow_r, ow_f, ow_crc, ow_byte;
  int ow_e = 1;  // engine running the 1-Wire program
  bit ow_fb;
  logic [7:0] ow_buf[$];
  bit ow_present, ow_b;
  int ow_i, ow_j;
  task ow_reset;
    wait_tx_empty(ow_e);
    flag_set(ow_e, 0);        // FLAG0: reset/presence
    do flag_get(ow_e, 0, ow_fb); while (ow_fb);
    fifo_recv(ow_e, ow_r);
    ow_present = (ow_r == 8'h00);
  endtask
  task ow_xbyte;  // send ow_tx as 8 slots; the byte seen comes back in ow_r
    fifo_send(ow_e, ow_tx);
    fifo_recv(ow_e, ow_r);
  endtask
  task ow_xbit;   // single-slot mode: send bit 0 of ow_tx, the bit seen comes back in ow_b
    fifo_send(ow_e, ow_tx);
    fifo_recv(ow_e, ow_r);
    ow_b = ow_r[7];
  endtask
  task ow_read_bytes;  // read ow_i bytes into ow_buf
    ow_buf.delete();
    for (ow_j = ow_i; ow_j > 0; ow_j--) begin
      ow_tx = 8'hFF;
      ow_xbyte;
      ow_buf.push_back(ow_r);
    end
  endtask
  task ow_crc8;   // Dallas CRC8 over ow_buf; 0 when the block ends in its correct CRC
    ow_crc = 0;
    for (ow_i = 0; ow_i < ow_buf.size(); ow_i++) begin
      ow_byte = ow_buf[ow_i];
      for (ow_j = 0; ow_j < 8; ow_j++) begin
        if ((ow_crc ^ ow_byte) & 8'h01) ow_crc = (ow_crc >> 1) ^ 8'h8C;
        else ow_crc = ow_crc >> 1;
        ow_byte = ow_byte >> 1;
      end
    end
  endtask

  // Search ROM, the algorithm from Maxim application note 187, run by the host bit by bit.
  logic [63:0] s_rom;
  int s_last_disc = 0, s_last_zero, s_i;
  bit s_done = 0, s_ok, s_id, s_cmp, s_dir;
  task ow_search_next;  // s_ok = a device was found, its ROM in s_rom
    s_ok = 0;
    if (!s_done) begin
      ow_reset;
      if (ow_present) begin
        ow_tx = 8'hF0;
        ow_xbyte;
        wait_tx_empty(ow_e);
        flag_set(ow_e, 1);        // FLAG1: single-slot mode
        s_last_zero = 0;
        s_ok = 1;
        for (s_i = 1; s_i <= 64; s_i++) begin
          if (s_ok) begin
            ow_tx = 8'h01; ow_xbit; s_id = ow_b;   // the bit
            ow_tx = 8'h01; ow_xbit; s_cmp = ow_b;  // its complement
            if (s_id && s_cmp) s_ok = 0;            // nobody answered
            else begin
              if (s_id != s_cmp) s_dir = s_id;
              else begin                            // discrepancy: devices differ here
                if (s_i < s_last_disc) s_dir = s_rom[s_i-1];
                else s_dir = (s_i == s_last_disc);
                if (!s_dir) s_last_zero = s_i;
              end
              s_rom[s_i-1] = s_dir;
              ow_tx = {7'b0, s_dir};
              ow_xbit;                              // devices that differ drop out
            end
          end
        end
        wait_tx_empty(ow_e);
        flag_clear(ow_e, 1);      // back to byte mode
        s_last_disc = s_last_zero;
        if (s_last_disc == 0) s_done = 1;
      end
    end
  endtask

  // ---------------- Modbus RTU device (RS-485) on pins 0 (master TX), 1 (master RX), 2 (DE) ----------------
  // Independent of the RTL: it samples at exactly 19200 baud, checks even parity, stop bits,
  // that DE is on during every character and off before it answers, and the gaps between
  // characters, then answers with mb_resp (parity flipped on byte mb_bad, if set).
  real MB_BIT = 1.0e9 / 19200.0;  // ns
  bit mb_en = 0;
  bit mb_npar = 0;  // 8N2: no parity bit, a second stop bit instead
  int mb_gap_at = -1;     // the response pauses before this byte...
  real mb_gap_chars = 0;  // ...for this many character times (11 bits)
  int mb_bad = -1, mb_frames = 0, mb_par_err = 0, mb_stop_err = 0, mb_de_err = 0, mb_k, mb_m;
  real mb_max_gap = 0;
  realtime mb_t_end;
  logic [7:0] mb_req_got[$], mb_resp[$];
  logic [7:0] mb_c, mb_o;
  bit mb_p, mb_s, mb_more, mb_first;
  initial forever begin
    wait (mb_en && !bus[0]);  // start bit of a request
    #(MB_BIT / 4);
    if (!bus[0]) begin        // still low: a real start bit, not a glitch (BUG-014)
    mb_req_got.delete();
    mb_more = 1;
    mb_first = 1;
    while (mb_more) begin
      #(mb_first ? MB_BIT * 1.25 : MB_BIT * 1.5);
      mb_first = 0;
      for (mb_k = 0; mb_k < 8; mb_k++) begin
        mb_c[mb_k] = bus[0];
        if (!bus[2]) mb_de_err++;
        #(MB_BIT);
      end
      mb_p = bus[0];
      #(MB_BIT);
      mb_s = bus[0];
      if (mb_npar ? !mb_p : ^{mb_c, mb_p}) mb_par_err++;
      if (!mb_s) mb_stop_err++;
      mb_req_got.push_back(mb_c);
      mb_t_end = $realtime + MB_BIT / 2;
      while (bus[0] && $realtime - mb_t_end < 3.5 * 11 * MB_BIT) #(MB_BIT / 16);
      if (!bus[0]) begin
        if ($realtime - mb_t_end > mb_max_gap) mb_max_gap = $realtime - mb_t_end;
      end else mb_more = 0;
    end
    mb_frames++;
    if (bus[2]) mb_de_err++;  // the master must have turned its driver off by now
    ext_drive[1] = 1;
    ext_val[1] = 1;
    #(MB_BIT);
    for (mb_m = 0; mb_m < mb_resp.size(); mb_m++) begin
      mb_o = mb_resp[mb_m];
      if (mb_m == mb_gap_at) #(mb_gap_chars * 11 * MB_BIT);  // a pause inside the frame
      ext_val[1] = 0;  // start
      #(MB_BIT);
      for (mb_k = 0; mb_k < 8; mb_k++) begin
        ext_val[1] = mb_o[mb_k];
        #(MB_BIT);
      end
      ext_val[1] = mb_npar ? 1'b1 : ^mb_o ^ (mb_m == mb_bad);  // even parity (optionally wrong) or stop
      #(MB_BIT);
      ext_val[1] = 1;  // stop
      #(MB_BIT);
    end
    ext_drive[1] = 0;
    end
  end

  // Any low pulse on the master's TX line shorter than half a bit is a glitch (BUG-013).
  realtime mb_fell = 0;
  int mb_glitches = 0;
  always @(negedge bus[0]) if (mb_en) mb_fell = $realtime;
  always @(posedge bus[0]) if (mb_en && $realtime - mb_fell < MB_BIT / 2) mb_glitches++;

  // Host side of the modbus_rtu program on engine 0.
  logic [7:0] mb_rx[$], mb_par[$], mb_buf[$];
  logic [7:0] mb_f, mb_st, mb_d, mb_x, mb_b;
  logic [15:0] mb_crc;
  bit mb_fdone, mb_fb;
  int mb_i, mb_j, mb_perr;  // mb_i/mb_j belong to the tasks; static tasks share variables
  task mb_crc16;  // Modbus CRC over mb_buf -> mb_crc ({high byte, low byte}; low byte is sent first)
    mb_crc = 16'hFFFF;
    for (mb_i = 0; mb_i < mb_buf.size(); mb_i++) begin
      mb_b = mb_buf[mb_i];
      mb_crc = mb_crc ^ {8'h00, mb_b};
      for (mb_j = 0; mb_j < 8; mb_j++)
        if (mb_crc[0]) mb_crc = (mb_crc >> 1) ^ 16'hA001;
        else mb_crc = mb_crc >> 1;
    end
  endtask
  task mb_send;  // send mb_buf without its last 2 bytes: the engine adds parity and the CRC
    for (mb_i = 0; mb_i < mb_buf.size() - 2; mb_i++) begin
      mb_b = mb_buf[mb_i];
      fifo_send(0, mb_b);
    end
    wait_tx_empty(0);
    flag_set(0, 1);                  // FLAG1: request complete
    do flag_get(0, 1, mb_fb); while (mb_fb);
  endtask
  int mb_div, mb_tmo;
  real mb_baud = 19200.0;
  task mb_config;  // engine 0 for Modbus at mb_baud: tick = 1/8 bit, CRC, parity, timeout
    mb_div = $rtoi(1.0e9 / mb_baud / 8.0 / CLK_NS + 0.5) - 1;
    // 1.5 characters of silence (the program then watches 2 more for the frame end, BUG-039);
    // +9 ticks because the program starts waiting 9 ticks before the stop bit ends
    mb_tmo = 1.5 * 11 * 8 + 9;
    reg_write(7'h00, 8'b0000_0000);    // stop E0
    reg_write(7'h10, mb_div[7:0]);
    reg_write(7'h11, mb_div[15:8]);
    reg_write(7'h1C, mb_tmo[7:0]);     // TIMEOUT
    reg_write(7'h1D, mb_tmo[15:8]);
    MB_BIT = 1.0e9 / mb_baud;          // the device model follows
    reg_write(7'h00, 8'b0001_0001);    // restart + run E0
  endtask
  task mb_receive;  // collect one response frame into mb_rx / mb_par
    mb_rx.delete();
    mb_par.delete();
    mb_fdone = 0;
    while (!mb_fdone) begin
      flag_get(0, 2, mb_fdone);  // read the flag first, so every byte before it gets drained
      reg_read(7'h01, mb_st);
      while (!mb_st[0]) begin
        fifo_recv(0, mb_d);
        fifo_recv(0, mb_x);
        mb_rx.push_back(mb_d);
        mb_par.push_back(mb_x);
        reg_read(7'h01, mb_st);
      end
    end
  endtask
  assign dev_pull = {1'b0, ow_pull_any, 6'b0};

  // state for the two-protocol test
  logic [63:0] conc_rom;
  logic [7:0] conc_v, conc_seen, conc_ack;
  bit conc_ow_done = 0, conc_i2c_busy = 0;
  int conc_rounds = 0, conc_overlap = 0;
  always @(negedge bus[OW]) if (conc_i2c_busy && !conc_ow_done) conc_overlap++;


`ifdef PBE_PROTOCOL_REFERENCE
  `include "modbus_reference.svh"
`endif

  // ---------------- tests ----------------
  initial begin
    logic [7:0] sent[$], got;
`ifndef PBE_SIGROK
    if ($test$plusargs("vcd")) begin  // waveforms on request: vvp sim.vvp +vcd
      $dumpfile("tb_pbe.vcd");
      $dumpvars(0, tb_pbe);
    end
`endif

    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (5) @(posedge clk);

`ifdef PBE_PROTOCOL_REFERENCE
    modbus_reference;
    $finish;
`endif

    // register readback sanity check
    reg_write(7'h10, 8'hA5);
    reg_read(7'h10, got);
    check(got == 8'hA5, $sformatf("CLKDIV_L readback %02x", got));

    // ===== Test 0: NOP has no side effects (BUG-008) =====
`ifdef PBE_SIGROK
    sigrok_phase = 0;
`endif
    $display("Test 0: NOP has no side effects");
    load_program("nop_image.hex");
    reg_write(7'h10, 0);
    reg_write(7'h11, 0);
    reg_write(7'h12, 2);                 // pins 2, 3: a USB pair in v2
    reg_write(7'h15, 0);
    reg_write(7'h00, 8'b0001_0001);      // restart + run E0
    repeat (300) @(posedge clk);
    check(uio_oe == 8'h00, $sformatf("NOP drove pins: uio_oe = %08b", uio_oe));
    reg_read(7'h04, got);                // the flags, through the host port
    check(got == '0 && !uo_out[1], "NOP changed flags or raised IRQ");
    reg_write(7'h00, 8'b0000_0000);

    // ===== Test 1: UART loopback =====
`ifdef PBE_SIGROK
    sigrok_phase = 1;
`endif
    $display("Test 1: UART TX (engine 0) looped back into UART RX (engine 1)");
    load_program("uart_image.hex");
    reg_write(7'h10, UART_BIT / 2 - 1);  // E0 tick = 1/2 bit
    reg_write(7'h11, 0);
    reg_write(7'h12, 0);                 // E0 pins start at 0
    reg_write(7'h14, 2'b00);             // LSB first
    reg_write(7'h15, 0);                 // start at word 0
    reg_write(7'h20, UART_BIT / 4 - 1);  // E1 tick = 1/4 bit
    reg_write(7'h21, 0);
    reg_write(7'h22, 1);                 // E1 pins start at 1
    reg_write(7'h23, 0);                 // JMP pin = rx
    reg_write(7'h24, 2'b00);
    reg_write(7'h25, 8);                 // start at word 8
    reg_write(7'h03, 8'b0000_0010);      // pin 1 belongs to E1
    loop01 = 1;
    uart_mon_en = 1;
    reg_write(7'h00, 8'b0011_0011);      // restart + run both

    sent = '{8'h55, 8'hA3, 8'h00, 8'hFF, 8'h0F, 8'h80};
    // one host port, so sends and receives take turns; keep up to 4 bytes queued
    for (int i = 0; i < 4; i++) fifo_send(0, sent[i]);
    foreach (sent[i]) begin
      fifo_recv(1, got);
      check(got === sent[i], $sformatf("UART RX byte %0d: got %02x, sent %02x", i, got, sent[i]));
      if (i + 4 < sent.size()) fifo_send(0, sent[i+4]);
    end
    repeat (2 * UART_BIT) @(posedge clk);
    check(uart_seen.size() == sent.size(), $sformatf("UART monitor saw %0d bytes", uart_seen.size()));
    foreach (uart_seen[i])
      check(uart_seen[i] === sent[i], $sformatf("UART monitor byte %0d: %02x", i, uart_seen[i]));
    $display("  sent %0d bytes, engine 1 and the monitor received them", sent.size());

    // ===== Test 2: SPI controller =====
`ifdef PBE_SIGROK
    sigrok_phase = 2;
`endif
    $display("Test 2: SPI controller (engine 0) against a mode-0 peripheral");
    reg_write(7'h00, 8'b1100_0000);      // stop both, flush FIFOs
    uart_mon_en = 0;
    loop01 = 0;
    load_program("spi_image.hex");
    reg_write(7'h03, 8'h00);
    reg_write(7'h10, 3);                 // tick = 4 clocks
    reg_write(7'h11, 0);
    reg_write(7'h12, 0);
    reg_write(7'h14, 2'b11);             // MSB first both ways
    reg_write(7'h15, 0);
    spi_reply = '{8'h3C, 8'hC3, 8'h81};
    spi_dev_en = 1;
    reg_write(7'h00, 8'b0001_0001);      // restart + run E0
    repeat (50) @(posedge clk);
    check(bus[3] == 1 && bus[0] == 0, "SPI idle: CS_n high, SCLK low");

    sent = '{8'hA5, 8'h5A, 8'h7E};
    foreach (sent[i]) fifo_send(0, sent[i]);
    foreach (sent[i]) begin
      fifo_recv(0, got);
      check(got === (i == 0 ? 8'h3C : i == 1 ? 8'hC3 : 8'h81),
            $sformatf("SPI read byte %0d: got %02x", i, got));
    end
    repeat (100) @(posedge clk);
    check(bus[3] == 1, "SPI: CS_n released at the end");
    check(spi_got.size() == 3, $sformatf("SPI peripheral got %0d bytes", spi_got.size()));
    foreach (spi_got[i])
      check(spi_got[i] === sent[i], $sformatf("SPI peripheral byte %0d: %02x, expected %02x", i, spi_got[i], sent[i]));
    $display("  exchanged %0d bytes in both directions", spi_got.size());

    // ===== Test 3: I2C on engine 1 while engine 0 sends UART =====
`ifdef PBE_SIGROK
    sigrok_phase = 3;
`endif
    $display("Test 3: I2C controller (engine 1, pins 4-5) running alongside UART TX (engine 0)");
    reg_write(7'h00, 8'b1100_0000);      // stop both, flush FIFOs
    spi_dev_en = 0;
    ext_drive = '0;
    load_program("mixed_image.hex");
    reg_write(7'h03, 8'b0011_0000);      // pins 4, 5 belong to E1
    reg_write(7'h10, UART_BIT / 2 - 1);  // E0: UART TX as in test 1
    reg_write(7'h11, 0);
    reg_write(7'h12, 0);
    reg_write(7'h14, 2'b00);
    reg_write(7'h15, 0);
    reg_write(7'h20, 17);                // E1 tick = 18 clocks, SCL = 7 ticks: I2C fast mode (<= 400 kHz)
    reg_write(7'h21, 0);
    reg_write(7'h22, 4);                 // E1 pins start at 4
    reg_write(7'h24, 2'b11);             // MSB first
    reg_write(7'h25, 8);                 // i2c_ctrl at word 8
    uart_seen.delete();
    uart_mon_en = 1;
    i2c_en = 1;
    reg_write(7'h00, 8'b0011_0011);      // restart + run both

    sent = '{8'hC3, 8'h3C, 8'h99, 8'h66};
    foreach (sent[i]) fifo_send(0, sent[i]);  // UART keeps running during the I2C traffic

    begin
      logic [7:0] seen, ack;
      // write 0xDE, 0xAD to registers 0x10, 0x11
      i2c_cond(1);
      i2c_xfer(8'hA0, 8'h80, seen, ack); check(ack == 0, "I2C: address+W not ACKed");
      i2c_xfer(8'h10, 8'h80, seen, ack); check(ack == 0, "I2C: register not ACKed");
      i2c_xfer(8'hDE, 8'h80, seen, ack); check(ack == 0, "I2C: data 0 not ACKed");
      i2c_xfer(8'hAD, 8'h80, seen, ack); check(ack == 0, "I2C: data 1 not ACKed");
      i2c_cond(2);
      check(i2c_mem[8'h10] === 8'hDE && i2c_mem[8'h11] === 8'hAD,
            $sformatf("I2C write: peripheral holds %02x %02x", i2c_mem[8'h10], i2c_mem[8'h11]));

      // read them back: write the register pointer, repeated START, read 2 bytes
      i2c_cond(1);
      i2c_xfer(8'hA0, 8'h80, seen, ack); check(ack == 0, "I2C: address+W not ACKed (read)");
      i2c_xfer(8'h10, 8'h80, seen, ack); check(ack == 0, "I2C: pointer not ACKed");
      i2c_cond(1);                                                  // repeated START
      i2c_xfer(8'hA1, 8'h80, seen, ack); check(ack == 0, "I2C: address+R not ACKed");
      i2c_xfer(8'hFF, 8'h00, seen, ack); check(seen === 8'hDE, $sformatf("I2C read 0: %02x", seen));
      i2c_xfer(8'hFF, 8'h80, seen, ack); check(seen === 8'hAD, $sformatf("I2C read 1: %02x", seen));
      check(ack == 1, "I2C: last read byte should carry our NACK");
      i2c_cond(2);

      // nobody at 0x58: expect a NACK
      i2c_cond(1);
      i2c_xfer(8'hB0, 8'h80, seen, ack); check(ack == 1, "I2C: missing device should NACK");
      i2c_cond(2);
    end
    repeat (50) @(posedge clk);
    check(bus[SDA] && bus[SCL], "I2C: bus not idle (both high) at the end");
    check(i_starts == 4 && i_stops == 3, $sformatf("I2C: saw %0d STARTs, %0d STOPs", i_starts, i_stops));
    check(i_stretches >= 20, $sformatf("I2C: only %0d clock stretches", i_stretches));
    check(scl_min_low >= 1300, $sformatf("I2C: SCL low %0.0f ns, fast mode needs 1300", scl_min_low));
    check(scl_min_high >= 600, $sformatf("I2C: SCL high %0.0f ns, fast mode needs 600", scl_min_high));
    check(scl_min_period >= 2500, $sformatf("I2C: SCL period %0.0f ns, over 400 kHz", scl_min_period));

    wait (uart_seen.size() == sent.size() || $time > 15ms);
    foreach (sent[i])
      check(uart_seen[i] === sent[i], $sformatf("UART during I2C: byte %0d %02x", i, uart_seen[i]));
    $display("  I2C write, read with repeated START, and NACK passed with %0d clock stretches;", i_stretches);
    $display("  UART sent %0d bytes at the same time", uart_seen.size());
    $display("  SCL min low %0.0f ns, min high %0.0f ns, min period %0.0f ns", scl_min_low, scl_min_high, scl_min_period);

    // $fatal gives a non-zero exit code, so make and CI see the failure (BUG-007)
    // ===== Test 4: 1-Wire =====
`ifdef PBE_SIGROK
    sigrok_phase = 4;
`endif
    $display("Test 4: 1-Wire controller (engine 1, pin 6) with two DS18B20-style devices");
    reg_write(7'h00, 8'b1100_0000);      // stop both, flush FIFOs
    uart_mon_en = 0;
    i2c_en = 0;
    loop01 = 0;
    ext_drive = '0;
    reg_write(7'h04, 8'h00);
    reg_write(7'h02, 8'h03);
    load_program("ow_image.hex");
    reg_write(7'h03, 8'b0100_0000);      // pin 6 belongs to E1
    reg_write(7'h20, 8'($rtoi(1000.0 / CLK_NS + 0.5) - 1));  // tick = 1 us
    reg_write(7'h21, 0);
    reg_write(7'h22, OW);
    reg_write(7'h24, 2'b00);             // LSB first
    reg_write(7'h25, 0);
    ow_mon = 1;
    reg_write(7'h00, 8'b0010_0010);      // restart + run E1 only

    ow_reset;
    check(!ow_present, "1-Wire: presence reported with no device on the bus");
    ow_en_a = 1;
    ow_reset;
    check(ow_present, "1-Wire: no presence pulse from device A");
    reg_write(7'h29, 8'h31);             // CRC unit: 1-Wire CRC-8, poly 0x31
    reg_write(7'h2A, 8'h00);
    reg_write(7'h2B, 8'hA7);             // 8 bits, init 0, reversed, fed by IN bits only
    ow_tx = 8'h33; ow_xbyte;             // READ ROM (one device only)
    reg_write(7'h2F, 8'h01);             // restart the CRC after the command byte
    ow_i = 8; ow_read_bytes;
    reg_read(7'h2F, ow_f);
    check(ow_f[1], "1-Wire: hardware CRC-8 of the ROM ID not ok");
    for (ow_i = 0; ow_i < 8; ow_i++)
      check(ow_buf[ow_i] === ROM_A[8*ow_i+:8], $sformatf("1-Wire READ ROM byte %0d: %02x", ow_i, ow_buf[ow_i]));
    ow_crc8;
    check(ow_crc == 0, "1-Wire: READ ROM CRC8 failed");
    $display("  presence, absence and READ ROM ok");

    ow_en_b = 1;                         // two devices: find both with Search ROM
    s_done = 0;
    s_last_disc = 0;
    ow_search_next;
    check(s_ok, "1-Wire: search found no device");
    ow_buf.delete();
    for (ow_i = 0; ow_i < 8; ow_i++) ow_buf.push_back(s_rom[8*ow_i+:8]);
    ow_crc8;
    check(ow_crc == 0 && (s_rom == ROM_A || s_rom == ROM_B), $sformatf("1-Wire: search 1 found %016x", s_rom));
    ow_tx = 8'hxx;
    begin
      logic [63:0] first;
      first = s_rom;
      ow_search_next;
      check(s_ok && s_done, "1-Wire: search did not find a second device");
      check(s_rom != first && (s_rom == ROM_A || s_rom == ROM_B), $sformatf("1-Wire: search 2 found %016x", s_rom));
      $display("  Search ROM found %016x and %016x", first, s_rom);
    end

    ow_reset;                            // MATCH ROM device B, then READ SCRATCHPAD
    ow_tx = 8'h55; ow_xbyte;
    for (ow_j = 0; ow_j < 8; ow_j++) begin
      ow_tx = ROM_B[8*ow_j+:8];
      fifo_send(ow_e, ow_tx);
      fifo_recv(ow_e, ow_r);
    end
    ow_tx = 8'hBE; ow_xbyte;
    reg_write(7'h2F, 8'h01);             // restart the CRC
    ow_i = 8; ow_read_bytes;
    reg_read(7'h2F, ow_f);
    check(!ow_f[1], "1-Wire: hardware CRC ok before the CRC byte was read");
    ow_tx = 8'hFF; ow_xbyte;             // the 9th byte is the CRC
    ow_buf.push_back(ow_r);
    reg_read(7'h2F, ow_f);
    check(ow_f[1], "1-Wire: hardware CRC-8 of the scratchpad not ok");
    for (ow_i = 0; ow_i < 9; ow_i++)
      check(ow_buf[ow_i] === OW_SP[8*ow_i+:8], $sformatf("1-Wire scratchpad byte %0d: %02x", ow_i, ow_buf[ow_i]));
    ow_crc8;
    check(ow_crc == 0, "1-Wire: scratchpad CRC8 failed");
    ow_mon = 0;
    check(ow_bad == 0 && ow_short > 0 && ow_long > 0 && ow_resets >= 5,
          $sformatf("1-Wire timing: %0d bad, %0d short, %0d long, %0d resets", ow_bad, ow_short, ow_long, ow_resets));
    $display("  hardware CRC-8 checked the ROM ID and the scratchpad");

    // CONVERT T on parasite-powered device A: strong pull-up right after the command byte
    ow_reset;
    ow_tx = 8'h55; ow_xbyte;
    for (ow_j = 0; ow_j < 8; ow_j++) begin
      ow_tx = ROM_A[8*ow_j+:8];
      ow_xbyte;
    end
    fifo_send(ow_e, 8'h44);              // CONVERT T, queued first...
    flag_set(ow_e, 0);                   // ...then FLAG0: strong pull-up after this byte
    fifo_recv(ow_e, ow_r);
    #(50us);
    check(ow_strong, "1-Wire: DQ not driven high after CONVERT T");
    #(1200us);
    flag_clear(ow_e, 0);                 // conversion time over: pull-up off
    #(20us);
    check(!uio_oe[OW], "1-Wire: DQ still driven after the strong pull-up ended");
    check(u_ow_a.conversions == 1 && u_ow_a.conv_fails == 0,
          $sformatf("1-Wire: %0d conversions, %0d failed", u_ow_a.conversions, u_ow_a.conv_fails));
    ow_reset;                            // read the new temperature
    ow_tx = 8'h55; ow_xbyte;
    for (ow_j = 0; ow_j < 8; ow_j++) begin
      ow_tx = ROM_A[8*ow_j+:8];
      ow_xbyte;
    end
    ow_tx = 8'hBE; ow_xbyte;
    ow_i = 9; ow_read_bytes;
    for (ow_i = 0; ow_i < 9; ow_i++)
      check(ow_buf[ow_i] === OW_SP_25C[8*ow_i+:8], $sformatf("1-Wire converted scratchpad byte %0d: %02x", ow_i, ow_buf[ow_i]));
    $display("  CONVERT T with strong pull-up: device read 25.0625 C");

    // CONVERT T while the RX FIFO is full (BUG-038): the strong pull-up must come within 10 us
    // of the last slot, not after the host has made room for the byte's PUSH
    for (ow_j = 0; ow_j < 6; ow_j++) fifo_send(ow_e, 8'hFF);  // 6 read slots, left unread
    do reg_read(7'h0B, ow_f); while (ow_f != 6);
    flag_set(ow_e, 0);                   // reset: its presence byte is left unread too
    do flag_get(ow_e, 0, ow_fb); while (ow_fb);
    ow_tx = 8'h55; fifo_send(ow_e, ow_tx);
    for (ow_j = 0; ow_j < 8; ow_j++) fifo_send(ow_e, ROM_A[8*ow_j+:8]);
    do reg_read(7'h0B, ow_f); while (ow_f != 16);
    reg_read(7'h01, ow_f);
    check(ow_f[5], "1-Wire: RX FIFO not full before CONVERT T");
    ow_spu_on = 0;
    begin
      int conv0;
      conv0 = u_ow_a.conversions;
      fifo_send(ow_e, 8'h44);            // CONVERT T, then FLAG0, with the RX FIFO full
      flag_set(ow_e, 0);
      #(700us);                          // 8 slots and more; the host still reads nothing
      check(ow_spu_on > 0, "1-Wire: no strong pull-up after CONVERT T with the RX FIFO full");
      if (ow_spu_on > 0)
        check(ow_spu_on - ow_last_rise <= 10000,
              $sformatf("1-Wire: strong pull-up %0.1f us after the last slot, needs <= 10 us",
                        (ow_spu_on - ow_last_rise) / 1000.0));
      for (ow_j = 0; ow_j < 17; ow_j++) fifo_recv(ow_e, ow_r);  // 16 waiting and CONVERT T's
      check(ow_r == 8'h44, $sformatf("1-Wire: CONVERT T came back as %02x", ow_r));
      #(1200us);
      flag_clear(ow_e, 0);
      #(20us);
      check(!uio_oe[OW], "1-Wire: DQ still driven after the strong pull-up ended (RX FIFO full)");
      check(u_ow_a.conversions == conv0 + 1 && u_ow_a.conv_fails == 0,
            $sformatf("1-Wire: RX FIFO full: %0d conversions, %0d failed", u_ow_a.conversions - conv0, u_ow_a.conv_fails));
      if (ow_spu_on > 0)
        $display("  CONVERT T with the RX FIFO full: strong pull-up %0.1f us after the last slot",
                 (ow_spu_on - ow_last_rise) / 1000.0);
    end

    // Inverted CRC-16 (DS2408/DS2431 style): the host reads the CRC unit's value and compares
    ow_reset;
    ow_tx = 8'h55; ow_xbyte;
    for (ow_j = 0; ow_j < 8; ow_j++) begin
      ow_tx = ROM_B[8*ow_j+:8];
      ow_xbyte;
    end
    ow_tx = 8'hAA; ow_xbyte;
    reg_write(7'h29, 8'h05);             // CRC-16, poly 0x8005, init 0, reversed, fed by IN
    reg_write(7'h2A, 8'h80);
    reg_write(7'h2B, 8'hAF);
    reg_write(7'h2F, 8'h01);             // restart it after the command byte
    ow_i = 8; ow_read_bytes;
    for (ow_i = 0; ow_i < 8; ow_i++)
      check(ow_buf[ow_i] === OW_BLK[8*ow_i+:8], $sformatf("1-Wire block byte %0d: %02x", ow_i, ow_buf[ow_i]));
    reg_read(7'h29, ow_crc);             // the live CRC value (low byte)...
    reg_read(7'h2A, ow_byte);            // ...and high byte
    ow_tx = 8'hFF; ow_xbyte; ow_f = ow_r;
    ow_tx = 8'hFF; ow_xbyte;
    check({ow_byte, ow_crc} == 16'h4BE1, $sformatf("1-Wire: CRC unit value %04x, expected 4be1", {ow_byte, ow_crc}));
    check(ow_f === ~ow_crc && ow_r === ~ow_byte,
          $sformatf("1-Wire: device sent CRC %02x %02x, inverted CRC unit value %02x %02x", ow_f, ow_r, ~ow_crc, ~ow_byte));
    reg_write(7'h2B, 8'h00);             // CRC off again
    $display("  inverted CRC-16 checked by the host against the CRC unit's value");
    $display("  MATCH ROM + READ SCRATCHPAD ok; timing checked on %0d short, %0d long pulses and %0d resets",
             ow_short, ow_long, ow_resets);
    ow_en_a = 0;
    ow_en_b = 0;

    // ===== Test 5: Modbus RTU =====
`ifdef PBE_SIGROK
    sigrok_phase = 5;
`endif
    $display("Test 5: Modbus RTU master (engine 0, pins 0-2) with an RS-485 device model, 8E1, hardware CRC/parity/timeout");
    reg_write(7'h00, 8'b1100_0000);
    reg_write(7'h04, 8'h00);
    reg_write(7'h02, 8'h03);
    load_program("modbus_image.hex");
    reg_write(7'h03, 8'h00);
    reg_write(7'h12, 0);
    reg_write(7'h13, 1);                 // JMP pin = rx
    reg_write(7'h14, 2'b00);             // LSB first
    reg_write(7'h15, 0);
    reg_write(7'h19, 8'h05);             // CRC_POLY = 0x8005
    reg_write(7'h1A, 8'h80);
    reg_write(7'h1B, 8'hFF);             // CRC_CFG: 16 bits, init ones, reversed, fed by OUT and IN
    reg_write(7'h1E, 8'h01);             // LINE_CFG: timeout jumps to word 1, even parity
    mb_en = 1;

    // round 0: normal; 1: response parity error; 2: response CRC corrupted; 3: normal at 115200;
    // 4: 8N2 at 19200; 5, 6: a 2-character pause inside the response at 19200 and 115200 (the
    // frame is invalid, BUG-039); 7, 8: a 1-character pause at 115200 and 19200 (allowed)
    for (int round = 0; round < 9; round++) begin
      bit invalid;
`ifdef PBE_SIGROK
      sigrok_phase = 50 + round;  // isolate each baud/parity/error scenario
`endif
      mb_baud = (round == 3 || round == 6 || round == 7) ? 115200.0 : 19200.0;
      mb_npar = (round == 4);
      reg_write(7'h1E, mb_npar ? 8'h41 : 8'h01);  // LINE_CFG: even parity, or a second stop bit
      mb_config;
      mb_bad = (round == 1) ? 3 : -1;
      mb_gap_at = (round >= 5) ? 4 : -1;
      mb_gap_chars = (round == 5 || round == 6) ? 2.0 : 1.0;
      mb_resp = '{8'h01, 8'h03, 8'h04, 8'h12, 8'h34, 8'h56, 8'h78, 8'h81, 8'h07};
      if (round == 2) mb_resp[8] = 8'h06;  // wrong CRC high byte
      mb_buf = '{8'h01, 8'h03, 8'h00, 8'h00, 8'h00, 8'h02, 8'hC4, 8'h0B};  // what must arrive
      mb_max_gap = 0;
      mb_send;
      mb_receive;
      check(uo_out[1], "Modbus: no IRQ at the end of the response");
      flag_get(0, 3, invalid);             // FLAG3: the frame had a pause of over 1.5 characters
      flag_clear(0, 3);
      flag_clear(0, 2);
      reg_write(7'h02, 8'h03);
      mb_gap_at = -1;
      check(invalid == (round == 5 || round == 6),
            $sformatf("Modbus round %0d: frame reported %0s", round, invalid ? "invalid" : "valid"));
      if (round == 5 || round == 6) begin
        check(mb_rx.size() == 4, $sformatf("Modbus round %0d: %0d bytes before the pause, expected 4", round, mb_rx.size()));
        $display("  round %0d at %0.0f baud: a 2-character pause inside the response: frame %0s",
                 round, mb_baud, invalid ? "reported invalid" : "NOT reported invalid");
      end else begin
        check(mb_req_got.size() == 8, $sformatf("Modbus round %0d: device got %0d request bytes", round, mb_req_got.size()));
        for (mb_i = 0; mb_i < 8 && mb_i < mb_req_got.size(); mb_i++)
          check(mb_req_got[mb_i] === mb_buf[mb_i],
                $sformatf("Modbus round %0d request byte %0d: %02x, expected %02x", round, mb_i, mb_req_got[mb_i], mb_buf[mb_i]));
        check(mb_rx.size() == mb_resp.size(), $sformatf("Modbus round %0d: host got %0d response bytes", round, mb_rx.size()));
        mb_perr = 0;
        for (mb_i = 0; mb_i < mb_rx.size(); mb_i++) begin
          check(mb_rx[mb_i] === mb_resp[mb_i], $sformatf("Modbus round %0d response byte %0d: %02x", round, mb_i, mb_rx[mb_i]));
          mb_x = mb_par[mb_i];
          if (mb_x[0]) mb_perr++;            // parity errors found by the engine
        end
        check(mb_perr == (round == 1 ? 1 : 0), $sformatf("Modbus round %0d: engine reported %0d parity errors", round, mb_perr));
        mb_x = mb_par[mb_par.size() - 1];  // status after the last character: CRC ok?
        check(mb_x[1] == (round != 2), $sformatf("Modbus round %0d: CRC ok = %b", round, mb_x[1]));
        check(mb_max_gap <= 1.5 * 11 * MB_BIT, $sformatf("Modbus round %0d: %0.0f ns gap inside a request", round, mb_max_gap));
        $display("  round %0d at %0.0f baud %s: request with hardware CRC ok; response %0d parity error(s), CRC ok = %b",
                 round, mb_baud, mb_npar ? "8N2" : "8E1", mb_perr, mb_x[1]);
      end
    end
    mb_npar = 0;

    // RX overflow: the host does not read during the response; the engine must report it
    reg_write(7'h1E, 8'h01);             // back to 8E1
    mb_baud = 115200.0;
    mb_config;
    mb_bad = -1;
    mb_resp = '{8'h01, 8'h03, 8'h04, 8'h12, 8'h34, 8'h56, 8'h78, 8'h81, 8'h07};
    mb_send;
    do flag_get(0, 2, mb_fdone); while (!mb_fdone);  // wait for the frame end, reading nothing
    reg_read(7'h1F, mb_st);
    check(mb_st[3], "Modbus: RX overflow not reported in STATUS");
    check(uo_out[1], "Modbus: no IRQ for the RX overflow");
    reg_read(7'h01, mb_st);
    while (!mb_st[0]) begin               // drain whatever arrived
      reg_read(7'h16, mb_d);
      reg_read(7'h01, mb_st);
    end
    reg_write(7'h1F, 8'h04);             // clear the overflow
    reg_read(7'h1F, mb_st);
    check(!mb_st[3], "Modbus: RX overflow did not clear");
    flag_clear(0, 2);
    reg_write(7'h02, 8'h03);
    $display("  RX overflow (host not reading) reported in STATUS and by IRQ");
    check(mb_par_err == 0 && mb_stop_err == 0 && mb_de_err == 0,
          $sformatf("Modbus: device saw %0d parity, %0d stop, %0d DE errors", mb_par_err, mb_stop_err, mb_de_err));
    check(mb_glitches == 0, $sformatf("Modbus: %0d glitches on the TX line", mb_glitches));
    mb_en = 0;
    reg_write(7'h1B, 8'h00);             // CRC off
    reg_write(7'h1C, 8'h00);             // timeout off
    reg_write(7'h1D, 8'h00);
    reg_write(7'h1E, 8'h00);

    // ===== Test 6: two flag-using protocols at once (BUG-017) =====
`ifdef PBE_SIGROK
    sigrok_phase = 6;
`endif
    $display("Test 6: 1-Wire Search ROM (engine 0, pin 6) and I2C (engine 1, pins 4-5) at the same time");
    reg_write(7'h00, 8'b1100_0000);
    mb_en = 0;
    reg_write(7'h04, 8'h00);
    reg_write(7'h02, 8'h03);
    load_program("conc_image.hex");      // i2c_ctrl at word 0, onewire_ctrl at word 64
    reg_write(7'h03, 8'b0011_0000);      // pins 4, 5 to E1; pin 6 to E0
    reg_write(7'h10, 8'($rtoi(1000.0 / CLK_NS + 0.5) - 1));  // E0: 1-Wire, tick = 1 us
    reg_write(7'h11, 0);
    reg_write(7'h12, OW);
    reg_write(7'h14, 2'b00);
    reg_write(7'h15, 64);
    reg_write(7'h20, 17);                // E1: I2C fast mode
    reg_write(7'h21, 0);
    reg_write(7'h22, 4);
    reg_write(7'h24, 2'b11);
    reg_write(7'h25, 0);
    ow_e = 0;
    ow_en_a = 1;
    ow_en_b = 1;
    ow_mon = 1;
    ow_bad = 0;
    i2c_en = 1;
    i_starts = 0;
    i_stops = 0;
    reg_write(7'h00, 8'b0011_0011);      // restart + run both
    fork
      begin  // host process A: 1-Wire on engine 0
        ow_reset;
        check(ow_present, "concurrent 1-Wire: no presence");
        s_done = 0;
        s_last_disc = 0;
        ow_search_next;
        conc_rom = s_rom;
        ow_search_next;
        check(s_done && ((conc_rom == ROM_A && s_rom == ROM_B) || (conc_rom == ROM_B && s_rom == ROM_A)),
              $sformatf("concurrent 1-Wire search found %016x, %016x", conc_rom, s_rom));
        conc_ow_done = 1;
      end
      begin  // host process B: I2C on engine 1, until 1-Wire is done (at least 3 rounds)
        conc_i2c_busy = 1;
        conc_rounds = 0;
        while (!conc_ow_done || conc_rounds < 3) begin
          conc_v = 8'h40 + conc_rounds;
          i2c_cond(1);
          i2c_xfer(8'hA0, 8'h80, conc_seen, conc_ack); check(conc_ack == 0, "concurrent I2C: address not ACKed");
          i2c_xfer(8'h20, 8'h80, conc_seen, conc_ack);
          i2c_xfer(conc_v, 8'h80, conc_seen, conc_ack);
          i2c_cond(2);
          i2c_cond(1);
          i2c_xfer(8'hA0, 8'h80, conc_seen, conc_ack);
          i2c_xfer(8'h20, 8'h80, conc_seen, conc_ack);
          i2c_cond(1);
          i2c_xfer(8'hA1, 8'h80, conc_seen, conc_ack);
          i2c_xfer(8'hFF, 8'h80, conc_seen, conc_ack);
          check(conc_seen === conc_v, $sformatf("concurrent I2C round %0d read %02x, wrote %02x", conc_rounds, conc_seen, conc_v));
          i2c_cond(2);
          conc_rounds++;
        end
        conc_i2c_busy = 0;
      end
    join
    ow_mon = 0;
    check(ow_bad == 0, "concurrent 1-Wire: timing violations");
    check(i_starts == 3 * conc_rounds && i_stops == 2 * conc_rounds,
          $sformatf("concurrent I2C: %0d STARTs, %0d STOPs for %0d rounds", i_starts, i_stops, conc_rounds));
    check(conc_overlap > 100, $sformatf("only %0d 1-Wire edges happened during I2C traffic", conc_overlap));
    $display("  Search ROM found both devices while I2C ran %0d write/read rounds; %0d 1-Wire edges overlapped I2C traffic",
             conc_rounds, conc_overlap);
    ow_en_a = 0;
    ow_en_b = 0;
    i2c_en = 0;

    // ===== Test 7: SMBus PEC =====
`ifdef PBE_SIGROK
    sigrok_phase = 7;
`endif
    $display("Test 7: SMBus PEC: I2C controller (engine 1) with its CRC unit as CRC-8 (poly 0x07)");
    begin
      logic [7:0] seen, ack, pec, lo, hi, st, c;
      string s;
      s = "123456789";
      c = 0;
      for (int i = 0; i < 9; i++) c = crc8(c, s[i]);
      check(c == 8'hF4, $sformatf("testbench CRC-8 of \"123456789\" is %02x, the standard says f4", c));

      reg_write(7'h00, 8'b1100_0000);
      reg_write(7'h04, 8'h00);
      load_program("conc_image.hex");    // i2c_ctrl at word 0
      reg_write(7'h03, 8'b0011_0000);
      reg_write(7'h20, 17);              // E1: I2C fast mode, as in test 3
      reg_write(7'h21, 0);
      reg_write(7'h22, 4);
      reg_write(7'h24, 2'b11);
      reg_write(7'h25, 0);
      reg_write(7'h29, 8'h07);           // CRC-8, poly 0x07
      reg_write(7'h2A, 8'h00);
      reg_write(7'h2B, 8'h87);           // 8 bits, init 0, plain output, fed by IN bits only
      i2c_en = 1;
      i_pec_mode = 1;
      i_pec_corrupt = 0;
      reg_write(7'h00, 8'b0010_0010);    // restart + run E1

      // Write Word with PEC: [addr+W] [command 0x30] [0x12] [0x34] [PEC]
      reg_write(7'h2F, 8'h01);           // restart the CRC for a new message
      i2c_cond(1);
      i2c_xfer(8'hA0, 8'h80, seen, ack); check(ack == 0, "SMBus: address+W not ACKed");
      i2c_xfer(8'h30, 8'h80, seen, ack);
      i2c_xfer(8'h12, 8'h80, seen, ack);
      i2c_xfer(8'h34, 8'h80, seen, ack);
      reg_read(7'h29, pec);              // the CRC unit's value is the PEC
      c = crc8(crc8(crc8(crc8(0, 8'hA0), 8'h30), 8'h12), 8'h34);
      check(pec == c, $sformatf("SMBus write: engine PEC %02x, expected %02x", pec, c));
      i2c_xfer(pec, 8'h80, seen, ack); check(ack == 0, "SMBus: PEC byte not ACKed");
      i2c_cond(2);
      check(i_pec_at_stop == 0, $sformatf("SMBus write: the device's CRC over the message and PEC is %02x", i_pec_at_stop));
      check(i2c_mem[8'h30] === 8'h12 && i2c_mem[8'h31] === 8'h34, "SMBus write: device did not store the word");

      // Read Word with PEC: [addr+W] [0x30] Sr [addr+R] [low] [high] [PEC], then once with a bad PEC
      for (int bad = 0; bad < 2; bad++) begin
        i_pec_corrupt = bad;
        reg_write(7'h2F, 8'h01);
        i2c_cond(1);
        i2c_xfer(8'hA0, 8'h80, seen, ack);
        i2c_xfer(8'h30, 8'h80, seen, ack);
        i2c_cond(1);
        i2c_xfer(8'hA1, 8'h80, seen, ack); check(ack == 0, "SMBus: address+R not ACKed");
        i2c_xfer(8'hFF, 8'h00, lo, ack);
        i2c_xfer(8'hFF, 8'h00, hi, ack);
        i2c_xfer(8'hFF, 8'h80, pec, ack);  // NACK the PEC: last byte
        i2c_cond(2);
        reg_read(7'h2F, st);
        check(lo == 8'h12 && hi == 8'h34, $sformatf("SMBus read word %02x%02x", hi, lo));
        check(st[1] == !bad, $sformatf("SMBus read with %s PEC %02x: CRC ok = %0d",
                                       bad ? "a bad" : "the right", pec, st[1]));
      end
      $display("  Write Word and Read Word with PEC; the engine computes the PEC and checks the device's");
      i2c_en = 0;
      i_pec_mode = 0;
      reg_write(7'h2B, 8'h00);
    end

    if (errors == 0) begin
      $display("PASS");
      $finish;
    end else $fatal(1, "FAILED with %0d error(s)", errors);
  end

  initial begin
    #400ms;
    $fatal(1, "FAILED: timeout");
  end
endmodule

// A DS18B20-style 1-Wire device: presence pulse, READ ROM (33), SEARCH ROM (F0), MATCH ROM (55),
// SKIP ROM (CC) and READ SCRATCHPAD (BE). It samples written bits 30 us into a slot and holds
// the line low for 30 us to send a 0. Written independently of the RTL.
module ow_device #(
    parameter logic [63:0] ROM = 64'h0,
    parameter logic [71:0] SP  = 72'h0,
    parameter logic [71:0] SP_CONV = 72'h0,  // scratchpad after a successful CONVERT T
    parameter logic [79:0] BLK = 80'h0       // sent by function AA: data + inverted CRC-16
) (
    input  wire  dq,
    input  wire  enable,
    input  wire  hard_hi, // DQ actively driven high (strong pull-up)
    output logic pull
);
  localparam int S_IDLE = 0, S_CMD = 1, S_ROMTX = 2, S_SRCH = 3, S_MATCH = 4, S_FUNC = 5, S_SPTX = 6,
                 S_BLKTX = 7;
  localparam realtime CONV_NS = 1000000;  // conversion time (1 ms here; 750 ms in a real DS18B20)
  int st = S_IDLE, n = 0, sub = 0, conversions = 0, conv_fails = 0;
  logic [71:0] sp = SP;
  event conv_go;
  // Parasite power: the conversion needs DQ driven hard high within 10 us and for CONV_NS.
  initial forever begin
    @(conv_go);
    #10000;
    begin : conv
      realtime t;
      bit ok;
      ok = 1;
      t = $realtime;
      while ($realtime - t < CONV_NS) begin
        if (!hard_hi) ok = 0;
        #1000;
      end
      if (ok) begin
        sp = SP_CONV;
        conversions++;
      end else conv_fails++;
    end
  end
  logic [63:0] sh;
  bit tx_mode, tx_bit, b;
  realtime t0;
  initial begin
    pull = 0;
    forever begin
      @(negedge dq);
      if (enable && !pull) begin
        tx_mode = 0;
        tx_bit = 1;
        if (st == S_ROMTX) begin tx_mode = 1; tx_bit = ROM[n]; end
        if (st == S_SRCH && sub < 2) begin tx_mode = 1; tx_bit = sub ? !ROM[n] : ROM[n]; end
        if (st == S_SPTX) begin tx_mode = 1; tx_bit = sp[n]; end
        if (st == S_BLKTX) begin tx_mode = 1; tx_bit = BLK[n]; end
        t0 = $realtime;
        if (tx_mode && !tx_bit) pull = 1;
        #30000;
        b = dq;
        pull = 0;
        while (!dq && $realtime - t0 < 400000) #1000;
        if (!dq) begin  // reset pulse: answer with a presence pulse
          @(posedge dq);
          #30000;
          pull = 1;
          #120000;
          pull = 0;
          st = S_CMD;
          n = 0;
          sh = 0;
        end else begin
          case (st)
            S_CMD: begin
              sh[n] = b;
              n++;
              if (n == 8) begin
                n = 0;
                case (sh[7:0])
                  8'h33: st = S_ROMTX;
                  8'hF0: begin st = S_SRCH; sub = 0; end
                  8'h55: st = S_MATCH;
                  8'hCC: st = S_FUNC;
                  default: st = S_IDLE;
                endcase
                sh = 0;
              end
            end
            S_ROMTX: begin n++; if (n == 64) st = S_IDLE; end
            S_SRCH: begin
              if (sub < 2) sub++;
              else begin
                sub = 0;
                if (b != ROM[n]) st = S_IDLE;  // controller chose the other branch
                else begin
                  n++;
                  if (n == 64) st = S_IDLE;
                end
              end
            end
            S_MATCH: begin
              sh[n] = b;
              n++;
              if (n == 64) begin
                st = (sh == ROM) ? S_FUNC : S_IDLE;
                n = 0;
                sh = 0;
              end
            end
            S_FUNC: begin
              sh[n] = b;
              n++;
              if (n == 8) begin
                case (sh[7:0])
                  8'hBE: st = S_SPTX;   // READ SCRATCHPAD
                  8'hAA: st = S_BLKTX;  // block with an inverted CRC-16
                  8'h44: begin          // CONVERT T, parasite powered
                    st = S_IDLE;
                    -> conv_go;
                  end
                  default: st = S_IDLE;
                endcase
                n = 0;
              end
            end
            S_SPTX: begin n++; if (n == 72) st = S_IDLE; end
            S_BLKTX: begin n++; if (n == 80) st = S_IDLE; end
            default: ;
          endcase
        end
      end
    end
  end
endmodule
