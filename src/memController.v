/*
module memController(pcP, aluOut, r2, clk, memReady, aluReady, inst, dataR, memCtrl, memDataIn, memDataOut, memType, dataPosOut, dataPosIn, dataSend, spiAddrOut, gpAddrOut, memClk, rst);
  parameter IM_START = 32'h0000_0000;
  parameter IM_STOP = 32'h007F_FFFF;
  parameter DM_START = 32'h0080_0000;
  parameter DM_STOP = 32'h00FF_FFFF;
  
  parameter GPO_START = 32'h0100_0000;
  parameter GPO_STOP = 32'h0100_0007;
  parameter GPI_START = 32'h0100_0008;
  parameter GPI_STOP = 32'h0100_000F;
  
  input wire [31:0] pcP, aluOut, r2;
  input wire clk, memReady, aluReady, rst;
  output reg [31:0] inst, dataR;
  input wire [2:0] memCtrl;
  output reg [31:0] memDataOut;
  input wire [31:0] memDataIn;
  output reg [1:0] memType = 2'b00;
  input wire [2:0] dataPosIn;
  output reg [2:0] dataPosOut;
  output reg dataSend;
  output reg [23:0] spiAddrOut;
  output reg [3:0] gpAddrOut;
  input wire memClk;
  
  wire delayClk, tmpClk; 
  reg dataWait;
  reg instWait;
  reg [31:0] dataInBuffer;
  
  or2 #(1) clkbuf1 (.a(clk), .b(clk), .y(tmpClk));
  or2 #(1) clkbuf2 (.a(tmpClk), .b(tmpClk), .y(delayClk));
  
  
 // Pre-fetch Instruction Logic
  always @(delayClk)
    begin
      spiAddrOut <= ((pcP >= IM_START) && (pcP <= IM_STOP)) ? pcP[23:0] : 24'h00_0000; 
      instWait <= 1'b1;
      memType <= 2'b11;
    end
  
  // Data In Accumalator && Data Sender
  always @(posedge memClk)
    begin
      if(dataSend == 1'b0)
        begin
          case(dataPosIn)
            3'b000: dataInBuffer[3:0] <= memDataIn[3:0];
            3'b100: dataInBuffer[7:4] <= memDataIn[3:0];
            3'b001: dataInBuffer[11:8] <= memDataIn[3:0];
            3'b101: dataInBuffer[15:12] <= memDataIn[3:0];
            3'b010: dataInBuffer[19:16] <= memDataIn[3:0];
            3'b110: dataInBuffer[23:20] <= memDataIn[3:0];
            3'b011: dataInBuffer[27:24] <= memDataIn[3:0];
            3'b111: dataInBuffer[31:28] <= memDataIn[3:0];
          endcase
        end
      if(dataSend == 1'b1)
        begin
          case(dataPosOut)
            3'b000: begin memDataOut[3:0] <= r2[3:0]; dataPosOut <= 3'b100; end
            3'b100: begin memDataOut[3:0] <= r2[7:4]; dataPosOut <= 3'b001; end
            3'b001: begin memDataOut[3:0] <= r2[11:8]; dataPosOut <= 3'b101; end
            3'b101: begin memDataOut[3:0] <= r2[15:12]; dataPosOut <= 3'b010; end
            3'b010: begin memDataOut[3:0] <= r2[19:16]; dataPosOut <= 3'b110; end
            3'b110: begin memDataOut[3:0] <= r2[23:20]; dataPosOut <= 3'b011; end
            3'b011: begin memDataOut[3:0] <= r2[27:24]; dataPosOut <= 3'b111; end
            3'b111: begin memDataOut[3:0] <= r2[31:28]; dataPosOut <= 3'b000; dataSend <= 1'b0; end
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
      if((memCtrl == 3'b000)) // Load Byte
        begin
          memType <= 2'b01;
          dataWait <= (((aluOut >= IM_START) && (aluOut <= DM_STOP))) ? 1'b1 : 1'b0;
        end
      if((memCtrl == 3'b011)) // Load Byte Unsigned
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
      gpAddrOut <= ((aluOut >= GPO_START) && (aluOut <= GPI_STOP)) ? aluOut[3:0] : 4'b0000;
      spiAddrOut <= ((aluOut >= IM_START) && (aluOut <= DM_STOP)) ? aluOut[23:0] : 24'h80_0000;
    end
  
  // Post-fetch Load Logic  
  always @(dataWait && memReady)
    begin
      if(memCtrl == 3'b011) // LBU
        dataInBuffer[31:8] <= 24'b0;
      if(memCtrl == 3'b100) // LHU
        dataInBuffer[31:16] <= 16'b0;
      if(memCtrl == 3'b001) // LH
        dataInBuffer[31:16] <= {16{dataInBuffer[15]}};
      if(memCtrl == 3'b000) // LB
        dataInBuffer[31:8] <= {24{dataInBuffer[7]}};
      dataR[31:0] <= dataInBuffer[31:0];
      dataWait <= 1'b0;
    end
endmodule
*/
module memController(pcP, aluOut, r2, clk, memReady, aluReady, inst, dataR, memCtrl, memDataIn, memDataOut, memType, dataPosOut, dataPosIn, dataSend, spiAddrOut, gpAddrOut, memClk, rst);
  parameter IM_START = 32'h0000_0000;
  parameter IM_STOP = 32'h007F_FFFF;
  parameter DM_START = 32'h0080_0000;
  parameter DM_STOP = 32'h00FF_FFFF;
  
  parameter GPO_START = 32'h0100_0000;
  parameter GPO_STOP = 32'h0100_0007;
  parameter GPI_START = 32'h0100_0008;
  parameter GPI_STOP = 32'h0100_000F;
  
  input wire [31:0] pcP, aluOut, r2;
  input wire clk, memReady, aluReady, rst;
  output reg [31:0] inst, dataR;
  input wire [2:0] memCtrl;
  output reg [31:0] memDataOut;
  input wire [31:0] memDataIn;
  output reg [1:0] memType = 2'b00;
  input wire [2:0] dataPosIn;
  output reg [2:0] dataPosOut;
  output reg dataSend;
  output reg [23:0] spiAddrOut;
  output reg [3:0] gpAddrOut;
  input wire memClk;
  
  wire delayClk, tmpClk; 
  reg dataWait;
  reg instWait;
  reg [31:0] dataInBuffer;
  
  or2 #(1) clkbuf1 (.a(clk), .b(clk), .y(tmpClk));
  or2 #(1) clkbuf2 (.a(tmpClk), .b(tmpClk), .y(delayClk));
  
  // Pre-fetch Instruction Logic
  always @(posedge delayClk or posedge rst) begin
    if (rst) begin
      spiAddrOut <= 24'h00_0000;
      instWait <= 1'b0;
      memType <= 2'b00;
    end else begin
      spiAddrOut <= ((pcP >= IM_START) && (pcP <= IM_STOP)) ? pcP[23:0] : 24'h00_0000; 
      instWait <= 1'b1;
      memType <= 2'b11;
    end
  end
  
  // Data In Accumulator && Data Sender
  always @(posedge memClk or posedge rst) begin
    if (rst) begin
      dataInBuffer <= 32'b0;
      dataSend <= 1'b0;
      memDataOut <= 32'b0;
      dataPosOut <= 3'b0;
    end else begin
      if (dataSend == 1'b0) begin
        case (dataPosIn)
          3'b000: dataInBuffer[3:0] <= memDataIn[3:0];
          3'b100: dataInBuffer[7:4] <= memDataIn[3:0];
          3'b001: dataInBuffer[11:8] <= memDataIn[3:0];
          3'b101: dataInBuffer[15:12] <= memDataIn[3:0];
          3'b010: dataInBuffer[19:16] <= memDataIn[3:0];
          3'b110: dataInBuffer[23:20] <= memDataIn[3:0];
          3'b011: dataInBuffer[27:24] <= memDataIn[3:0];
          3'b111: dataInBuffer[31:28] <= memDataIn[3:0];
        endcase
      end
      if (dataSend == 1'b1) begin
        case (dataPosOut)
          3'b000: begin memDataOut[3:0] <= r2[3:0]; dataPosOut <= 3'b100; end
          3'b100: begin memDataOut[3:0] <= r2[7:4]; dataPosOut <= 3'b001; end
          3'b001: begin memDataOut[3:0] <= r2[11:8]; dataPosOut <= 3'b101; end
          3'b101: begin memDataOut[3:0] <= r2[15:12]; dataPosOut <= 3'b010; end
          3'b010: begin memDataOut[3:0] <= r2[19:16]; dataPosOut <= 3'b110; end
          3'b110: begin memDataOut[3:0] <= r2[23:20]; dataPosOut <= 3'b011; end
          3'b011: begin memDataOut[3:0] <= r2[27:24]; dataPosOut <= 3'b111; end
          3'b111: begin memDataOut[3:0] <= r2[31:28]; dataPosOut <= 3'b000; dataSend <= 1'b0; end
        endcase
      end
    end
  end
  
  // Post-fetch Instruction Logic
  always @(instWait && memReady or posedge rst) begin
    if (rst) begin
      inst <= 32'b0;
      instWait <= 1'b0;
    end else begin
      inst <= dataInBuffer;
      instWait <= 1'b0;
    end
  end
  
  // Pre-fetch Load Logic
  always @(posedge aluReady or posedge rst) begin
    if (rst) begin
      memType <= 2'b00;
      dataWait <= 1'b0;
      dataSend <= 1'b0;
      spiAddrOut <= 24'b0;
      gpAddrOut <= 4'b0;
    end else begin
      if (memCtrl == 3'b000) begin
        memType <= 2'b01;
        dataWait <= ((aluOut >= IM_START) && (aluOut <= DM_STOP)) ? 1'b1 : 1'b0;
      end
      if (memCtrl == 3'b011) begin
        memType <= 2'b01;
        dataWait <= ((aluOut >= IM_START) && (aluOut <= DM_STOP) || ((aluOut >= GPI_START) && (aluOut <= GPI_STOP))) ? 1'b1 : 1'b0;
      end
      if (memCtrl == 3'b001 || memCtrl == 3'b100) begin
        memType <= 2'b10;
        dataWait <= ((aluOut >= IM_START) && (aluOut <= DM_STOP)) ? 1'b1 : 1'b0;
      end
      if (memCtrl == 3'b010) begin
        memType <= 2'b11;
        dataWait <= ((aluOut >= IM_START) && (aluOut <= DM_STOP)) ? 1'b1 : 1'b0;
      end
      if (memCtrl == 3'b101) begin
        memType <= 2'b01;
        dataSend <= ((aluOut >= IM_START) && (aluOut <= GPO_STOP)) ? 1'b1 : 1'b0;
      end
      if (memCtrl == 3'b110) begin
        memType <= 2'b10;
        dataSend <= ((aluOut >= IM_START) && (aluOut <= DM_STOP)) ? 1'b1 : 1'b0;
      end
      if (memCtrl == 3'b111) begin
        memType <= 2'b11;
        dataSend <= ((aluOut >= IM_START) && (aluOut <= DM_STOP)) ? 1'b1 : 1'b0;
      end
      gpAddrOut <= ((aluOut >= GPO_START) && (aluOut <= GPI_STOP)) ? aluOut[3:0] : 4'b0;
      spiAddrOut <= ((aluOut >= IM_START) && (aluOut <= DM_STOP)) ? aluOut[23:0] : 24'h80_0000;
    end
  end
  
  // Post-fetch Load Logic
  always @(dataWait && memReady or posedge rst) begin
    if (rst) begin
      dataR <= 32'b0;
      dataInBuffer <= 32'b0;
      dataWait <= 1'b0;
    end else begin
      if (memCtrl == 3'b011)
        dataInBuffer[31:8] <= 24'b0;
      if (memCtrl == 3'b100)
        dataInBuffer[31:16] <= 16'b0;
      if (memCtrl == 3'b001)
        dataInBuffer[31:16] <= {16{dataInBuffer[15]}};
      if (memCtrl == 3'b000)
        dataInBuffer[31:8] <= {24{dataInBuffer[7]}};
      dataR <= dataInBuffer;
      dataWait <= 1'b0;
    end
  end
endmodule
