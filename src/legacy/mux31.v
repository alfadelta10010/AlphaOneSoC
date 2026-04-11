module mux31 #(parameter N = 32) (a, b, c, s, y);
    input  wire [N-1:0] a; // 00
    input  wire [N-1:0] b; // 01
    input  wire [N-1:0] c; // 10
    input  wire [1:0]   s;
    output wire [N-1:0] y;

    assign y = (s == 2'b00) ? a :
               (s == 2'b01) ? b :
               (s == 2'b10) ? c : {N{1'b0}};
endmodule
