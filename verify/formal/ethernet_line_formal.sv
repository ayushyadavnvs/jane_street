// D90/D94 bounded functional checks. Manchester wire checks use the IEEE bit definition.
module ethernet_line_formal #(parameter KIND=0, POLARITY=0)(input wire clk);
  reg rst_n=0;
  always @(posedge clk) rst_n<=1;
  generate if(KIND==0) begin:mc
    (* anyconst *) reg [7:0] payload;
    reg [2:0] sent=0;
    reg ended=0,got=0,saw_end=0;
    reg [8:0] age=0,wave_age=0;
    wire ready,drive,a,b,tx_err,rx_err,valid,frame_end;
    wire [7:0] data;
    wire put=sent<4 && ready;
    wire end_put=sent==4 && ready && !ended;
    wire [7:0] tx_data=sent<2?8'h55:sent==2?8'hd5:payload;
    localparam [7:0] CFG=8'h23 | (POLARITY?8'h80:8'h00);
    wire incoming=drive?a:(POLARITY?1'b1:1'b0);
    pbe_line tx(.clk,.rst_n,.clear(1'b0),.cfg(CFG),.cfg2(8'd0),.sync(8'd0),
      .period_m1(16'd5),.out_msb_first(1'b0),.in_msb_first(1'b0),
      .a_in(POLARITY?1'b1:1'b0),.a_early(POLARITY?1'b1:1'b0),.b_in(1'b1),
      .ctl(1'b0),.ctl_param(5'd0),.drive,.a_out(a),.b_out(b),.tx_put(put),
      .tx_end(end_put),.tx_data,.tx_ready(ready),.rx_valid(),.rx_data(),.rx_take(1'b1),
      .frame_end(),.err(tx_err));
    pbe_line rx(.clk,.rst_n,.clear(1'b0),.cfg(CFG),.cfg2(8'd0),.sync(8'hd5),
      .period_m1(16'd5),.out_msb_first(1'b0),.in_msb_first(1'b0),
      .a_in(incoming),.a_early(incoming),.b_in(!incoming),.ctl(1'b0),.ctl_param(5'd0),
      .drive(),.a_out(),.b_out(),.tx_put(1'b0),.tx_end(1'b0),.tx_data(8'd0),.tx_ready(),
      .rx_valid(valid),.rx_data(data),.rx_take(1'b1),.frame_end,.err(rx_err));
    reg [7:0] expected_byte;
    reg expected_bit;
    always @* begin
      case(wave_age/48)
        0,1: expected_byte=8'h55;
        2: expected_byte=8'hd5;
        default: expected_byte=payload;
      endcase
      expected_bit=(expected_byte >> ((wave_age/6)%8)) & 1;
      if(wave_age%6<3) expected_bit=!expected_bit;
      if(POLARITY) expected_bit=!expected_bit;
    end
    always @(posedge clk) if(rst_n) begin
      if(age<255) age<=age+1;
      if(put) sent<=sent+1;
      if(end_put) ended<=1;
      assert(!tx_err && !rx_err);
      if(drive) begin
        if(wave_age<192) assert(a==expected_bit && b!=a);
        else assert(a && !b); // 3 complete bit times of TP_IDL
        wave_age<=wave_age+1;
      end
      if(ended && !drive && wave_age!=0) assert(wave_age==210);
      if(valid) begin assert(!got);assert(data==payload);got<=1;end
      if(frame_end && got) saw_end<=1;
      if(age==249) assert(got && saw_end && wave_age==210);
      cover(got && saw_end && wave_age==210);
    end
  end else if(KIND==3) begin:timer
    (* anyconst *) reg [15:0] period;
    (* anyseq *) reg level,early;
    always @* assume(period>=3);
    pbe_line dut(.clk,.rst_n,.clear(1'b0),.cfg(8'h23),.cfg2(8'd0),.sync(8'd0),
      .period_m1(period),.out_msb_first(1'b0),.in_msb_first(1'b0),
      .a_in(level),.a_early(early),.b_in(!level),.ctl(1'b0),.ctl_param(5'd0),
      .drive(),.a_out(),.b_out(),.tx_put(1'b0),.tx_end(1'b0),.tx_data(8'd0),.tx_ready(),
      .rx_valid(),.rx_data(),.rx_take(1'b1),.frame_end(),.err());
  end else begin:controls
    (* anyseq *) reg clear,put,finish,take,ctl,a_in,b_in;
    (* anyseq *) reg [4:0] action;
    (* anyseq *) reg [7:0] payload;
    wire ready,frame_end;
    localparam [7:0] CFG=KIND==1?8'h29:8'h4a;
    pbe_line dut(.clk,.rst_n,.clear,.cfg(CFG),.cfg2(8'd0),.sync(8'd0),
      .period_m1(16'd3),.out_msb_first(1'b0),.in_msb_first(1'b0),
      .a_in,.a_early(a_in),.b_in,.ctl,.ctl_param(action),.drive(),.a_out(),.b_out(),
      .tx_put(put),.tx_end(finish),.tx_data(payload),.tx_ready(ready),
      .rx_valid(),.rx_data(),.rx_take(take),.frame_end,.err());
    always @* assume(!(put || finish) || ready);
    always @(posedge clk) if(rst_n) begin
      cover(ctl && action[4] && action[1:0]==3 && put);
      cover(frame_end && !clear);
    end
  end endgenerate
endmodule
