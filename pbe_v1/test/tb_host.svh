// Host-side helpers shared by the end-to-end testbenches. The including module provides
// clk, HOST_HALF, ui_in (host SCK = [0], CS_n = [1], MOSI = [2]) and the DUT output uo_out.

  int errors = 0;
  task automatic check(input bit ok, input string msg);
    if (!ok) begin
      errors++;
      $display("  FAIL: %s", msg);
    end
  endtask

  // ---------------- host SPI (mode 0) ----------------
  task automatic spi_byte(input logic [7:0] tx, output logic [7:0] rx);
    for (int i = 7; i >= 0; i--) begin
      ui_in[2] = tx[i];
      repeat (HOST_HALF) @(posedge clk);
      ui_in[0] = 1;  // rising: both sides sample
      rx[i] = uo_out[0];
      repeat (HOST_HALF) @(posedge clk);
      ui_in[0] = 0;
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
      while (host_serving != ticket) @(posedge clk);
    end
    repeat (HOST_HALF) @(posedge clk);
    ui_in[1] = level;
    repeat (HOST_HALF) @(posedge clk);
    if (level) host_serving++;
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

  task automatic load_program(input string file);
    logic [15:0] img[128];
    logic [7:0] d;
    $readmemh(file, img);
    reg_write(7'h06, 0);         // program memory pointer = word 0, high byte
    cs(0);
    spi_byte({1'b1, 7'h07}, d);  // burst into PM_DATA; the pointer advances per byte
    for (int w = 0; w < 128; w++) begin
      spi_byte(img[w][15:8], d);
      spi_byte(img[w][7:0], d);
    end
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
