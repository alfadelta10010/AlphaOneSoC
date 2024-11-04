module and2 #(parameter N = 32)(a, b, y);
  input wire [N-1 : 0] a;
  input wire [N-1 : 0] b;
  output wire [N-1 : 0] y;
  assign y = a & b;
endmodule
