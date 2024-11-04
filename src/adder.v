module adder #(parameter N = 32)(a, b, s);
  input wire [N-1:0] a;
  input wire [N-1:0] b;
  output wire [N-1:0] s;
  assign s = a + b;
endmodule
