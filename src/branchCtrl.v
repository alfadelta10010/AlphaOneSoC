module branchCtrl(bCtrl, r1, r2, bSel);
  input wire [2:0] bCtrl;
  input wire [31:0] r1;
  input wire [31:0] r2;
  output reg [0:0] bSel;
  
  wire [31:0] condinv = ~r2;
  wire [32:0] sum = {1'b1, condinv} + {1'b0, r1} + {32'b0, 1'b1};
  wire LT = (r1[31] ^ r2[31]) ? r1[31] : sum[32];
  wire LTU = sum[32];
  wire is_sum_zero = sum[31:0] == 32'b0;

  always@(*)
    begin
      bSel = 1'b0;
      case(bCtrl)
        3'b000: bSel = is_sum_zero; // BEQ
          
        3'b001: bSel = !is_sum_zero; // BNE
          
        3'b010: bSel = LT; // BLT
          
        3'b011: bSel = LTU; // BLTU
          
        3'b100: bSel = !LT; // BGE
         
        3'b101: bSel = !LTU; // BGEU
          
        default: bSel = 1'b0;
      endcase
    end
endmodule
