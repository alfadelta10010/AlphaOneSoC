module mux31 #(parameter N = 32) (a, b, c, s, y);
  input wire [N-1:0] a; //00
  input wire [N-1:0] b; //01
  input wire [N-1:0] c; //10
  input wire [1:0] s;
  output wire [N-1:0] y;
  
  wire [N-1:0] mux1;
  mux21 m1(a, b, s[0], mux1);
  mux21 m2(mux1, c, s[1], y);
endmodule

