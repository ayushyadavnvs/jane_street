// Pre-D89 single-lane equivalence, with arbitrary extra MOSI lanes and input timing.
module ethernet_host_equiv(input wire clk);
  reg initialized=0;
  always @(posedge clk) initialized<=1;
  (* anyseq *) reg rst_n,sck,cs_n,mosi;
  (* anyseq *) reg [2:0] mosi_hi;
  (* anyseq *) reg [7:0] rd_data;
  wire mn,mo,quad;
  wire [54:0] sn,so;
  host_new_equiv n(.clk,.rst_n,.sck,.cs_n,.mosi,.rd_data,.quad_req(1'b0),.mosi_hi,
    .miso(mn),.quad,.miso_hi(),.quad_exit(),.addr(),.wr_en(),.wr_addr(),.wr_data(),
    .rd_done(),.rd_addr(),.f_state(sn));
  host_old_equiv o(.clk,.rst_n,.sck,.cs_n,.mosi,.rd_data,.miso(mo),.addr(),
    .wr_en(),.wr_addr(),.wr_data(),.rd_done(),.rd_addr(),.f_state(so));
  always @(posedge clk) begin
    if(!initialized) assume(!rst_n);
    if(initialized) begin
      assert(!quad);
      assert(sn==so);
      assert(mn==mo);
    end
  end
endmodule
