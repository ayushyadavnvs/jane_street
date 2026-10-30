module engine_formal(input wire clk);
  reg initialized = 0;
  always @(posedge clk) initialized <= 1;
  wire rst_n = initialized;
  (* anyseq *) reg run_any, restart_any, write_any;
  (* anyseq *) reg [6:0] write_addr;
  (* anyseq *) reg [15:0] write_data;
  (* anyseq *) reg [7:0] pins, tx_data;
  (* anyseq *) reg [3:0] flags;
  (* anyseq *) reg tx_empty, rx_full;
  (* anyconst *) reg [6:0] start_any;
  (* anyconst *) reg [15:0] div_any, timeout_any;
  reg [15:0] mem[0:127];
  // Unreset RAM begins as symbolic, persistent storage; writes are coupled to pm_wr.
  wire fixed_program = (`F_KIND >= 2);
  wire run = fixed_program ? 1'b1 : run_any;
  wire restart = fixed_program ? 1'b0 : restart_any;
  wire pm_wr = fixed_program ? 1'b0 : write_any;
  wire [6:0] start_pc = fixed_program ? 7'd0 : start_any;
  wire [15:0] clkdiv = (`F_KIND == 4) ? div_any : 16'd0;
  wire [15:0] timeout = (`F_KIND == 4) ? timeout_any : 16'd0;
  always @* begin
    if (`F_KIND == 4) begin
      assume(div_any <= 3);
      assume(timeout_any >= 1 && timeout_any <= 5);
    end
  end
  always @(posedge clk) if (rst_n && pm_wr) mem[write_addr] <= write_data;
  wire [6:0] pc;
  wire [15:0] instruction = fixed_program ?
      ((`F_KIND == 4 && pc == 0) ? 16'h4080 : 16'hd800) : mem[pc];
  wire [6:0] current_addr = pc - 1'b1;
  wire [15:0] current_word = mem[current_addr];
  wire [7:0] pins_out, pins_oe;
  wire [4:0] status;
  wire [3:0] flag_set, flag_clr;
  wire tx_pop,rx_push;
  pbe_engine dut(
    .clk(clk),.rst_n(rst_n),.run(run),.restart(restart),.clkdiv(clkdiv),
    .pin_base(3'd0),.jmp_pin(3'd0),.out_msb_first(1'b0),.in_msb_first(1'b0),
    .start_pc(start_pc),.crc_poly(16'd0),.crc_cfg(8'd0),.timeout(timeout),
    .line_cfg(8'h45),.coder_cfg(8'd0),.sync(8'd0),.crc_good(16'd0),
    .host_crc_init(1'b0),.host_tmo_clr(1'b0),.host_ovf_clr(1'b0),.host_lerr_clr(1'b0),
    .status(status),.crc_now(),.pc(pc),.pc_copy(),.instr(instruction),.pm_wr(pm_wr),
    .pins_in((`F_KIND==4)?8'd0:pins),.pins_out(pins_out),.pins_oe(pins_oe),
    .tx_data(tx_data),.tx_empty(tx_empty),.tx_pop(tx_pop),.rx_data(),.rx_full(rx_full),
    .rx_push(rx_push),.flags(flags),.flag_set(flag_set),.flag_clr(flag_clr),.irq(),
    .f_mem_current(current_word)
  );
  always @(posedge clk) if (rst_n) begin
    cover (tx_pop);
    cover (rx_push);
    if (`F_KIND == 4) cover (status[2] && pc == 5);
  end
endmodule
