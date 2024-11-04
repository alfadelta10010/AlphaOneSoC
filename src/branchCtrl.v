module branchCtrl(bCtrl, r1, r2, bSel);
  input wire [2:0] bCtrl;
  input wire [31:0] r1;
  input wire [31:0] r2;
  output reg [0:0] bSel;
  always@(*)
    begin
      bSel = 1'b0;
      case(bCtrl)
        3'b000: begin // BEQ
          if (r1 == r2)
            bSel = 1'b1;
          else
            bSel = 1'b0;
        end
        3'b001: begin // BNE
          if (r1 != r2)
            bSel = 1'b1;
          else
            bSel = 1'b0;
        end
        3'b100: begin // BLT
          if ($signed(r1) < $signed(r2))
            bSel = 1'b1;
          else
            bSel = 1'b0;
        end
        3'b110: begin // BLTU
          if (r1 < r2)
            bSel = 1'b1;
          else
            bSel = 1'b0;
        end
        3'b101: begin // BGE
          if ($signed(r1) >= $signed(r2))
            bSel = 1'b1;
          else
            bSel = 1'b0;
        end
        3'b111: begin // BGEU
          if (r1 >= r2)
            bSel = 1'b1;
          else
            bSel = 1'b0;
        end
        default: begin 
          bSel = 1'b0;
        end
      endcase
    end
endmodule
