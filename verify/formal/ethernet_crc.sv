// D91: coefficient-wise polynomial reference; a separate pre-D91 equivalence pair.
module ethernet_crc #(parameter NARROW=0)(input wire clk);
  reg initialized=0;
  always @(posedge clk) initialized<=1;
  (* anyseq *) reg rst_n, init, step, bit_in, init_ones, out_rev;
  (* anyseq *) reg [31:0] poly,good;
  (* anyconst *) reg [4:0] wide_width;
  (* anyseq *) reg [3:0] narrow_width;
  wire [4:0] width=NARROW ? {1'b0,narrow_width} : wide_width;
  always @* if(!NARROW) assume(wide_width>=16);
  wire [31:0] p=NARROW?{16'd0,poly[15:0]}:poly;
  wire [31:0] g=NARROW?{16'd0,good[15:0]}:good;
  wire [31:0] value,raw;
  wire ok,raw_ok;
  pbe_crc dut(.clk,.rst_n,.init,.step,.bit_in,.poly(p),.width_m1(width),
    .init_ones,.out_rev,.good(g),.value,.ok,.f_raw(raw));
  generate if(NARROW) begin:n
    wire [15:0] old_value,old_raw;
    wire old_ok;
    ref_pbe_crc16 o(.clk,.rst_n,.init,.step,.bit_in,.poly(poly[15:0]),
      .width_m1(narrow_width),.init_ones,.out_rev,.good(good[15:0]),
      .value(old_value),.ok(old_ok),.f_raw(old_raw));
    always @(posedge clk) if(initialized) begin
      assert(value=={16'd0,old_value});assert(raw=={16'd0,old_raw});
      assert(ok==old_ok);
    end
  end else begin:w
    reg [31:0] coefficients;
    reg [31:0] reflected;
    integer i;
    always @* begin
      reflected=0;
      for(integer b=0;b<32;b=b+1)
        if(b<=width) reflected[b]=coefficients[width-b];
    end
    always @(posedge clk or negedge rst_n) begin
      if(!rst_n) coefficients<=0;
      else if(init) begin
        for(i=0;i<32;i=i+1) coefficients[i]<=init_ones && i<=width;
      end else if(step) begin
        for(i=0;i<32;i=i+1)
          if(i>width) coefficients[i]<=0;
          else coefficients[i] <= (i==0 ? 1'b0 : coefficients[i-1]) ^
                                  ((bit_in ^ coefficients[width]) && poly[i]);
      end
    end
    always @(posedge clk) begin
      if(initialized) begin
        assert(raw==coefficients);
        assert(value==(out_rev?reflected:coefficients));
        assert(ok==(coefficients==good));
      end
    end
  end endgenerate
  always @(posedge clk) begin
    if(!initialized) assume(!rst_n);
    cover(initialized && init && step);
    cover(initialized && step && width==31 && out_rev);
  end
endmodule
