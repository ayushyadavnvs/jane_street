// Host-side helpers shared by the end-to-end testbenches. The including module provides
// clk, rst_n, HOST_HALF, ui_in (host SCK = [0], CS_n = [1], MOSI = [2]; quad D1..D3 = [5:3])
// and the DUT output uo_out.
//
// Quad host mode (D89): with +QUAD on the command line the first transaction after reset
// first writes HOSTCFG = 1 in single mode; every transaction after it is quad (4 bits per SCK
// on ui_in[5:2] and uo_out[3:0]). A bench may also call host_quad_on/off/recover itself.

  int errors = 0;
  task automatic check(input bit ok, input string msg);
    if (!ok) begin
      errors++;
      $display("  FAIL: %s", msg);
    end
  endtask

  // ---------------- host SPI (mode 0) ----------------
  // The host's pins change after a falling edge of the chip clock, never at a rising edge, where
  // the chip's synchronizers sample them and the simulator's process order would decide (BUG-102).
  bit host_quad = 0;        // the mode the chip's port is in (as far as the host knows)
  bit host_want_quad = 0;   // +QUAD: switch to quad mode at the first transaction
  int host_quad_entries = 0;
  initial host_want_quad = $test$plusargs("QUAD");
  always @(negedge rst_n) host_quad = 0;  // a chip reset returns the port to single mode

  task automatic spi_byte(input logic [7:0] tx, output logic [7:0] rx);
    if (host_quad) begin
      ui_in[5:2] = tx[7:4];  // high nibble first
      repeat (HOST_HALF) @(negedge clk);
      ui_in[0] = 1;
      rx[7:4] = uo_out[3:0];
      repeat (HOST_HALF) @(negedge clk);
      ui_in[0] = 0;
      ui_in[5:2] = tx[3:0];
      repeat (HOST_HALF) @(negedge clk);
      ui_in[0] = 1;
      rx[3:0] = uo_out[3:0];
      repeat (HOST_HALF) @(negedge clk);
      ui_in[0] = 0;
      ui_in[5:3] = 0;
    end else begin
      for (int i = 7; i >= 0; i--) begin
        ui_in[2] = tx[i];
        repeat (HOST_HALF) @(negedge clk);
        ui_in[0] = 1;  // rising: both sides sample
        rx[i] = uo_out[0];
        repeat (HOST_HALF) @(negedge clk);
        ui_in[0] = 0;
      end
    end
  endtask

  // One host port: a transaction holds it from CS_n low to CS_n high, so two host processes
  // can share it (BUG-001). A ticket lock serves them in arrival order; a plain busy flag let
  // the process that just released the port take it again at once and starve the other.
  int host_next = 0, host_serving = 0;
  task automatic cs(input bit level);
    int ticket;
    if (!level) begin
      ticket = host_next++;
      while (host_serving != ticket) @(negedge clk);
      if (host_want_quad && !host_quad && rst_n) host_quad_switch(1);
    end
    repeat (HOST_HALF) @(negedge clk);
    ui_in[1] = level;
    repeat (HOST_HALF) @(negedge clk);
    if (level) host_serving++;
  endtask

  // One transaction writing HOSTCFG (0x50), called while holding the port; the new mode
  // starts at CS_n high.
  task automatic host_quad_switch(input bit on);
    logic [7:0] d;
    repeat (HOST_HALF) @(negedge clk);
    ui_in[1] = 0;
    repeat (HOST_HALF) @(negedge clk);
    spi_byte({1'b1, 7'h50}, d);
    spi_byte({7'b0, on}, d);
    repeat (HOST_HALF) @(negedge clk);
    ui_in[1] = 1;
    repeat (HOST_HALF) @(negedge clk);
    host_quad = on;
    if (on) host_quad_entries++;
  endtask

  task automatic host_quad_on();
    logic [7:0] d;
    host_want_quad = 1;
    reg_read(7'h50, d);  // any transaction: cs() switches first
  endtask

  task automatic host_quad_off();
    host_want_quad = 0;
    reg_write(7'h50, 8'h00);  // in quad mode: back to single at CS_n high
    host_quad = 0;
  endtask

  // The recovery that works in either mode: 8 SCK pulses with CS_n high.
  task automatic host_recover();
    host_want_quad = 0;
    repeat (HOST_HALF) @(negedge clk);
    for (int i = 0; i < 8; i++) begin
      ui_in[0] = 1;
      repeat (HOST_HALF) @(negedge clk);
      ui_in[0] = 0;
      repeat (HOST_HALF) @(negedge clk);
    end
    host_quad = 0;
  endtask

  task automatic reg_write(input logic [6:0] addr, input logic [7:0] data);
    logic [7:0] d;
    cs(0);
    spi_byte({1'b1, addr}, d);
    spi_byte(data, d);
    cs(1);
  endtask

  task automatic reg_read(input logic [6:0] addr, output logic [7:0] data);
    logic [7:0] d;
    cs(0);
    spi_byte({1'b0, addr}, d);
    spi_byte(8'h00, data);
    cs(1);
  endtask

  // Program memory (D82): each engine has its own 256 words. The pointer is
  // {PM_ADDR_H[1:0], PM_ADDR} = {engine, word[7:0], byte}; PM_DATA writes a byte and advances it.
  task automatic pm_select(input int e, input int w);
    reg_write(7'h0F, 8'({e[0], w[7]}));  // PM_ADDR_H: [1] engine, [0] word bit 7
    reg_write(7'h06, 8'({w[6:0], 1'b0}));  // PM_ADDR: word bits 6..0, high byte first
  endtask

  // An image from pbe_asm.py: lines 0-255 are engine 0's memory, lines 256-511 engine 1's.
  // Each engine's memory is written whole, so no word is left unknown, with one burst each.
  task automatic load_program(input string file);
    logic [15:0] img[512];
    logic [7:0] d;
    $readmemh(file, img);
    for (int e = 0; e < 2; e++) begin
      pm_select(e, 0);
      cs(0);
      spi_byte({1'b1, 7'h07}, d);  // burst into PM_DATA; the pointer advances per byte
      for (int w = 0; w < 256; w++) begin
        spi_byte(img[e*256+w][15:8], d);
        spi_byte(img[e*256+w][7:0], d);
      end
      cs(1);
    end
    pm_select(0, 0);
  endtask

  // Write one program word of engine e while the engines may be running.
  task automatic pm_write(input int e, input int w, input logic [15:0] data);
    logic [7:0] d;
    pm_select(e, w);
    cs(0);
    spi_byte({1'b1, 7'h07}, d);
    spi_byte(data[15:8], d);
    spi_byte(data[7:0], d);
    cs(1);
  endtask

  task automatic fifo_send(input int e, input logic [7:0] data);
    logic [7:0] st;
    do reg_read(7'h01, st); while (st[e*4+3]);  // TX full
    reg_write(e ? 7'h26 : 7'h16, data);
  endtask

  task automatic fifo_recv(input int e, output logic [7:0] data);
    logic [7:0] st;
    int tries = 0;
    do begin
      reg_read(7'h01, st);
      tries++;
    end while (st[e*4+0] && tries < 400);  // RX empty
    check(!st[e*4+0], $sformatf("engine %0d RX FIFO stayed empty", e));
    reg_read(e ? 7'h26 : 7'h16, data);
  endtask


  // ---------------- engine-relative flags ----------------
  // Engine e's FLAG n is physical flag (FLAG_BASE[e] + n) mod 8; by default engine 0 has
  // flags 0-3 and engine 1 has flags 4-7. FLAG_SET (0x08) and FLAG_CLR (0x09) change single
  // bits, so the host never overwrites a flag the other engine just changed.
  function automatic int fphys(input int e, input int n);
    return (e * 4 + n) % 8;
  endfunction
  task automatic flag_set(input int e, input int n);
    reg_write(7'h08, 8'h01 << fphys(e, n));
  endtask
  task automatic flag_clear(input int e, input int n);
    reg_write(7'h09, 8'h01 << fphys(e, n));
  endtask
  task automatic flag_get(input int e, input int n, output bit v);
    logic [7:0] f;
    reg_read(7'h04, f);
    v = f[fphys(e, n)];
  endtask

  task automatic wait_tx_empty(input int e);
    logic [7:0] st;
    do reg_read(7'h01, st); while (!st[e*4+2]);
  endtask
