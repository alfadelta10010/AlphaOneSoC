module mux21 #(parameter N = 32) (a, b, s, y);
  input wire [N-1:0] a; // 0
  input wire [N-1:0] b; // 1
  input wire s;
  output wire [N-1:0] y;
  assign y = s ? b : a;
endmodule
