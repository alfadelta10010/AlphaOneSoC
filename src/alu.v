module alu(d1, d2, result, control);
  input wire [31:0] d1;
  input wire [31:0] d2;
  output wire [31:0] result;
  input wire [3:0] control;
  assign result = (control == 4'b0000) ? (d1 + d2) :       // ADD
                  (control == 4'b0001) ? (d1 << d2[4:0]) : // SLL
                  (control == 4'b0010) ? (($signed(d1) < $signed(d2)) ? 32'h00000001 : 32'h00000000) : // SLT
                  (control == 4'b0011) ? ((d1 < d2) ? 32'h00000001 : 32'h00000000) : // SLTU
                  (control == 4'b0100) ? (d1 ^ d2) :       // XOR
                  (control == 4'b0101) ? (d1 >> d2[4:0]) : // SRL
                  (control == 4'b0110) ? (d1 | d2) :       // OR
                  (control == 4'b0111) ? (d1 & d2) :       // AND
                  (control == 4'b1000) ? (d1 - d2) :       // SUB
                  (control == 4'b1101) ? (d1 >>> d2[4:0]) :// SRA
                  32'b0;
endmodule
