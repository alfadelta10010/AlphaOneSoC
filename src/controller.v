module controller (f3, f7, opcode, regWR, memWR, wbCtrl, aluOp, aluS1, aluS2, branchCtrl, memCtrl, doJump, doBranch);
  input wire [2:0] f3;
  input wire [6:0] f7;
  input wire [6:0] opcode;
  output reg regWR, memWR;
  output reg [1:0] wbCtrl;
  output reg [2:0] branchCtrl;
  output reg [2:0] memCtrl;
  output reg aluS1, aluS2, doBranch, doJump;
  output reg [3:0] aluOp;
  
  always@(*)
    begin
      regWR = 1'b0;
      aluS1 = 1'b0;
      aluS2 = 1'b0;
      memWR = 1'b0;
      branchCtrl = 3'b011;
      doJump = 1'b0;
      doBranch = 1'b0;
      memCtrl = 3'b101;
      aluOp = 4'b1001;
      wbCtrl = 2'b11;
      case(opcode)
        7'b0110011: begin // R-type
          regWR = 1'b1;
          wbCtrl = 2'b00;
          aluS1 = 1'b0;
          aluS2 = 1'b1;
          case(f3)
            3'b000: aluOp = (f7[5] == 1'b1) ? {1'b1, f3[2:0]} : {1'b0, f3[2:0]}; // SUB/ADD
            3'b101: aluOp = (f7[5] == 1'b1) ? {1'b1, f3[2:0]} : {1'b0, f3[2:0]}; // SRA/SRL
            3'b001, 3'b010, 3'b011, 3'b100, 3'b110, 3'b111: aluOp = (f7 == 7'b0) ? {1'b0, f3[2:0]} : 4'b1001; // ALU operations/Malformed instruction
          endcase
        end
        
        7'b0010011: begin // I-type (IR-type)
          regWR = 1'b1;
          wbCtrl = 2'b00;
          case(f3)
            3'b101: aluOp = (f7[5] == 1'b1) ? {1'b1, f3[2:0]} : {1'b0, f3[2:0]}; // SRAI/SRLI
            3'b000, 3'b001, 3'b010, 3'b011, 3'b100, 3'b110, 3'b111: aluOp = (f7 == 7'b0) ? {1'b0, f3[2:0]} : 4'b1001;
          endcase
        end
        
        7'b0000011: begin // Loads (IL-type)
          regWR = 1'b1;
          aluOp = 4'b0000;
          wbCtrl = 2'b01;
          case(f3)
            3'b000: memCtrl = 3'b000;   // LB
            3'b001: memCtrl = 3'b001;   // LH
            3'b010: memCtrl = 3'b010;   // LW
            3'b100: memCtrl = 3'b011;   // LBU
            3'b101: memCtrl = 3'b100;   // LHU
            default: memCtrl = 3'b101;  // Malformed instruction
          endcase
        end
        
        7'b0100011: begin // S-type
          memWR = 1'b1;
          aluOp = 4'b0000;
          case(f3)
            3'b000: memCtrl = 3'b101;   // SB
            3'b001: memCtrl = 3'b110;   // SH
            3'b010: memCtrl = 3'b111;   // SW
            default: memCtrl = 3'b101;  // Malformed instruction
          endcase          
        end
        
        7'b1100011: begin // B-type
          branchCtrl = f3;
          doBranch = 1'b1;
          aluS1 = 1'b1;
          aluOp = 4'b0000;
        end
        
        7'b0110111: begin // LUI
          regWR = 1'b1;
          wbCtrl = 2'b00;
          aluOp = 4'b0000;
        end
        
        7'b0010111: begin // AUIPC
          regWR = 1'b1;
          aluS1 = 1'b1;
          wbCtrl = 2'b00;
          aluOp = 4'b0000;
        end
        
        7'b1101111: begin // JAL
          regWR = 1'b1;
          aluS1 = 1'b1;
          wbCtrl = 2'b10;
          aluOp = 4'b0000;
          doJump = 1'b1;
        end
        7'b1100111: begin // JALR
          regWR = 1'b1;
          wbCtrl = 2'b10;
          aluOp = 4'b0000;
          doJump = 1'b1;
        end
        default: begin
          regWR = 1'b0;
          memWR = 1'b0;
          wbCtrl = 2'b11;
          aluS1 = 1'b0;
          aluS2 = 1'b0;
          doJump = 1'b0;
          doBranch = 1'b0;
          branchCtrl = 3'b011;
          aluOp = 4'b1001;
          memCtrl = 3'b101;
        end
    endcase
  end
endmodule
