module memController(pcP, aluOut, r2, clk, memReady, aluReady, inst, dataR, memCtrl, memData. memType, dataPos, dataSend, spiAddrOut, gpAddrOut, memClk, memGet);
  parameter IM_START = 32'h0000_0000;
  parameter IM_STOP = 32'h007F_FFFF;
  parameter DM_START = 32'h0080_0000;
  parameter DM_STOP = 32'h00FF_FFFF;
  
  parameter GPO_START = 32'h0100_0000;
  parameter GPO_STOP = 32'h0100_0007;
  parameter GPI_START = 32'h0100_0008;
  parameter GPI_STOP = 32'h0100_000F;
  
  input wire [31:0] pcP, aluOut, r2;
  input wire clk, memReady, aluReady;
  output wire [31:0] inst, dataR;
  input wire [3:0] memCtrl;
  inout wire [31:0] memData;
  output reg [1:0] memType;
  inout reg [2:0] dataPos;
  output wire dataSend;
  output wire [23:0] spiAddrOut;
  output wire [3:0] gpAddrOut;
  input wire memClk;
  inout reg memGet;
  
  wire delayClk, tmpClk, dataWait, instWait, dataSend;
  reg [31:0] dataInBuffer
  
  or2 #(1) clkbuf1 (.a(clk), .b(clk), .y(tmpClk));
  or2 #(1) clkbuf2 (.a(tmpClk), .b(tmpClk), .y(delayClk));
  
  
 // Pre-fetch Instruction Logic
  always @(delayClk)
    begin
      spiAddrOut <= ((pcP >= IM_START) && (pcP <= IM_STOP)) : pcP[23:0] : 24'h00_0000; 
      instWait <= 1'b1;
      memType <= 2'b11;
    end
  
  // Data In Accumalator && Data Sender
  always @(posedge memClk)
    begin
      if(dataSend == 1'b0)
        begin
          case(dataPos):
            3'b000: dataInBuffer[3:0] <= memData[3:0];
            3'b100: dataInBuffer[7:4] <= memData[3:0];
            3'b001: dataInBuffer[11:8] <= memData[3:0];
            3'b101: dataInBuffer[15:12] <= memData[3:0];
            3'b010: dataInBuffer[19:16] <= memData[3:0];
            3'b110: dataInBuffer[23:20] <= memData[3:0];
            3'b011: dataInBuffer[27:24] <= memData[3:0];
            3'b111: dataInBuffer[31:28] <= memData[3:0];
          endcase
        end
      if(dataSend == 1'b1 && memGet == 1'b1)
        begin
          case(dataPos):
            3'b000: begin memData[3:0] <= r2[3:0]; dataPos <= 3'b100; memGet <= 1'b0; end
            3'b100: begin memData[3:0] <= r2[7:4]; dataPos <= 3'b001; memGet <= 1'b0; end
            3'b001: begin memData[3:0] <= r2[11:8]; dataPos <= 3'b101; memGet <= 1'b0; end
            3'b101: begin memData[3:0] <= r2[15:12]; dataPos <= 3'b010; memGet <= 1'b0; end
            3'b010: begin memData[3:0] <= r2[19:16]; dataPos <= 3'b110; memGet <= 1'b0; end
            3'b110: begin memData[3:0] <= r2[23:20]; dataPos <= 3'b011; memGet <= 1'b0; end
            3'b011: begin memData[3:0] <= r2[27:24]; dataPos <= 3'b111; memGet <= 1'b0; end
            3'b111: begin memData[3:0] <= r2[31:28]; dataPos <= 3'b000; dataSend = 1'b0; memGet <= 1'b0; end
          endcase
        end
    end
  
  // Post-fetch Instruction Logic
  always @(instWait && memReady)
    begin
      inst[31:0] <= dataInBuffer[31:0];
      instWait <= 1'b0;
    end
  
  // Pre-fetch Load Logic
  always @(aluReady)
    begin
      if((memCtrl == 3'b000)||(memCtrl == 3'b011)) // Load Byte
        begin
          memType <= 2'b01;
          dataWait <= (((aluOut >= IM_START) && (aluOut <= DM_STOP))) ? 1'b1 : 1'b0;
        end
      if((memCtrl == 3'b000)||(memCtrl == 3'b011)) // Load Byte Unsigned
        begin
          memType <= 2'b01;
          dataWait <= (((aluOut >= IM_START) && (aluOut <= DM_STOP)) || ((aluOut >= GPI_START) && (aluOut <= GPI_STOP))) ? 1'b1 : 1'b0;
        end
      if((memCtrl == 3'b001)||(memCtrl == 3'b100)) // Load Halfword (S/U)
        begin
          memType <= 2'b10;
          dataWait <= ((aluOut >= IM_START) && (aluOut <= DM_STOP)) ? 1'b1 : 1'b0;
        end
      if(memCtrl == 3'b010) // Load Word
        begin
          memType <= 2'b11;
          dataWait <= ((aluOut >= IM_START) && (aluOut <= DM_STOP)) ? 1'b1 : 1'b0;
        end
      if(memCtrl == 3'b101)  // Store Byte
        begin
          memType <= 2'b01;
          dataSend <= ((aluOut >= IM_START) && (aluOut <= GPO_STOP)) ? 1'b1 : 1'b0;
        end
      if(memCtrl == 3'b110)  // Store Halfword
        begin
          memType <= 2'b10;
          dataSend <= ((aluOut >= IM_START) && (aluOut <= DM_STOP)) ? 1'b1 : 1'b0;
        end
      if(memCtrl == 3'b111)  // Store Word
        begin
          memType <= 2'b11;
          dataSend <= ((aluOut >= IM_START) && (aluOut <= DM_STOP)) ? 1'b1 : 1'b0;
        end
      gpAddrOut <= ((aluOut >= GPO_START) && (aluOut <= GPI_STOP)) : aluOut[3:0] : 4'b0000
      spiAddrOut <= ((aluOut >= IM_START) && (aluOut <= DM_STOP)) : aluOut[23:0] : 24'h80_0000;
    end
  
  // Post-fetch Load Logic  
  always @(dataWait && memReady)
    begin
      if(memCtrl == 011) // LBU
        dataInBuffer[31:8] <= 24'b0;
      if(memCtrl == 100) // LHU
        dataInBuffer[31:16] <= 16'b0;
      if(memCtrl == 001) // LH
        dataInBuffer[31:16] <= 16{dataInBuffer[15]};
      if(memCtrl == 000) // LB
        dataInBuffer[31:8] <= 24{dataInBuffer[7]};
      dataR[31:0] <= dataInBuffer[31:0];
      dataWait <= 1'b0;
    end
endmodule
