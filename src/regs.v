module regs #(parameter N = 32) (clk, rst, in, out, en);
  input wire clk;
  input wire rst;
  input wire en;
  input wire [N-1:0] in;
  output reg [N-1:0] out;
  always @(posedge clk or posedge rst) 
    begin
      if (rst)
        out <= 0;
      else if (en) 
        out <= in;
    end
endmodule
