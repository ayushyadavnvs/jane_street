// Included by tb_line.sv: test H, pbe_line's stuffing control and flag-delimited frames (D94).
// v sends HDLC (ISO/IEC 13239: flags 0x7E, a 0 after five 1s, an abort is seven 1s) as one
// coder frame, in bit transfers: each flag and the abort between LINECTL STUFFOFF and STUFFON.
// u receives with LINE[6] (flag-delimited): a stuffing violation (the sixth 1) ends a frame at
// either level and the next bit starts the next one. Expected, independently of the RTL: the
// segments between frame ends are [0] (the flag's last 0) + the data bits + [0 1 1 1 1 1]
// (the closing flag up to its sixth 1); between two flags [0] [0 1 1 1 1 1]; after the abort's
// sixth 1 the next bit is a 1. (The receiver never goes idle in this mode, so what it saw
// before the opening flag is not checked.)

int fe_pos[$];  // got.size() at each of u's frame ends
always @(posedge clk) if (fe_u) fe_pos.push_back(got.size());

task automatic ctl_v_pulse(input logic [4:0] p);
  @(negedge clk);
  ctlp_v = p;
  ctl_v = 1;
  @(negedge clk);
  ctl_v = 0;
endtask

bit hb[$];  // the data bits of the test frame
task automatic send_byte_bits(input logic [7:0] b);
  for (int k = 0; k < 8; k++) send_v(8'(b[k]), 0);
endtask
task automatic send_flag_v();
  ctl_v_pulse(5'b10001);  // STUFFOFF
  send_byte_bits(8'h7E);
  ctl_v_pulse(5'b10010);  // STUFFON
endtask

task automatic hdlc_case(input bit nrzi);
  logic [7:0] data[4];
  int s1, ok, base;
  data[0] = 8'hFF; data[1] = 8'h7E; data[2] = 8'h1F; data[3] = 8'h3E;  // runs of 5-8 ones
  cfg_v = nrzi ? 8'b0000_1010 : 8'b0000_1001;  // bits, stuff after 5 ones, NRZ/NRZI
  cfg_u = cfg_v | 8'h40;                       // flag-delimited
  sync_u = 0;
  sync_v = 0;
  use_loop = 1;
  repeat (20 * P) @(negedge clk);
  got.delete();
  fe_pos.delete();
  n_err_u = 0;
  hb.delete();
  foreach (data[i]) for (int k = 0; k < 8; k++) hb.push_back(data[i][k]);
  send_flag_v();                       // opening flag
  foreach (data[i]) send_byte_bits(data[i]);
  send_flag_v();                       // closing flag
  send_flag_v();                       // a second flag (idle fill)
  ctl_v_pulse(5'b10001);               // an abort: seven 1s
  for (int k = 0; k < 7; k++) send_v(8'd1, 0);
  ctl_v_pulse(5'b10010);
  send_flag_v();
  repeat (12 * P) @(negedge clk);      // let the last flag through before the coder lets go
  ok = fe_pos.size() >= 4;
  // segment 2 (after the opening flag's frame end): 0, the data bits, 0 1 1 1 1 1
  if (ok) begin
    base = fe_pos[0];
    ok = fe_pos[1] - base == 1 + hb.size() + 6;
    if (ok && got[base] !== 8'd0) ok = 0;
    for (int i = 0; ok && i < hb.size(); i++) if (got[base + 1 + i] !== 8'(hb[i])) ok = 0;
    for (int i = 0; ok && i < 6; i++) if (got[base + 1 + hb.size() + i] !== 8'(i != 0)) ok = 0;
    // the second flag, right after the first: the first one's last 0, then 0 1 1 1 1 1 (7 bits)
    if (ok) ok = fe_pos[2] - fe_pos[1] == 7 && got[fe_pos[1]] === 8'd0 && got[fe_pos[1] + 1] === 8'd0;
    // the abort: the flag's last 0 and 1 1 1 1 1, the sixth 1 ends a frame, its 7th 1 follows
    if (ok) ok = fe_pos[3] - fe_pos[2] == 6 && got.size() > fe_pos[3] && got[fe_pos[3]] === 8'd1;
  end
  if (!(ok && n_err_u == 0)) foreach (fe_pos[i]) $display("    frame end after bit %0d", fe_pos[i]);
  check(ok && n_err_u == 0, $sformatf("H %s: %0d frame ends, %0d bits, %0d errors", nrzi ? "NRZI" : "NRZ",
                                      fe_pos.size(), got.size(), n_err_u));
  $display("H: HDLC %s, flags and an abort unstuffed inside one coder frame (LINECTL), received flag-delimited (LINE[6]): %0d frame ends, the data bits exact",
           nrzi ? "NRZI" : "NRZ ", fe_pos.size());
  while (drive_v) begin
    send_v(0, 1);
    @(negedge clk);
  end
  use_loop = 0;
endtask

task run_hdlc_tests();
  hdlc_case(0);
  hdlc_case(1);
endtask
