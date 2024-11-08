module fyracore(clk, rst, dIn);
  wire [31:0] pcP, pcN, aluOut, pcIn, instIn, dIn, imm, aluD1, aluD2, dataOut;
  wire [6;0] opcode, f7;
  wire [4:0] rs1, rd, rs2;
  wire [3:0] aluOp;
  wire [2:0] f3, bCtrl, memCtrl;
  wire [1:0] wbCtrl;
  wire branchSel, pcEn, regWR, memW, aluS1, aluS2, doJump, doBranch, branchValid, branchTrue;
  input wire clk, rst;
  output reg din;
  
  adder #(32) pcAdder (
    .a(32'd4),                   // Fixed Increment
    .b(pcP),                     // PC-Present (To Memory Controller)
    .s(pcN)                      // PC-Next
  ); 
  
  mux21 #(32) branchMux (
    .a(pcN),                     // PC-Next
    .b(aluOut),                  // ALU Output (To Memory Controller)
    .s(branchSel),               // Branch Select 
    .y(pcIn)                     // PC-Input
  );
  
  regs #(32) programCounter (
    .clk(clk),                   // Clock Input (External)
    .rst(rst),                   // Reset Input (External)
    .in(pcIn),                   // PC-Input
    .out(pcP),                   // PC-Present (To Memory Controller)
    .en(pcEn)                    // PC-Enable
  );
  
  decoder decoderUnit (
    .instIn(instIn),             // Instruction In (From Memory Controller)
    .opcode(opcode),             // Opcode
    .rd(rd),                     // Register Destination
    .rs1(rs1),                   // Register Souce 1
    .rs2(rs2),                   // Register Souce 2
    .fn3(fn3),                   // Function 3
    .fn7(fn7)                    // Function 7
  );
  
  controller controlUnit (
    .f3(f3),                     // Function 3
    .f7(f7),                     // Function 7
    .opcode(opcode),             // Opcode
    .regWR(regWR),               // Register Write
    .wbCtrl(wbCtrl),             // Write-back Control
    .aluOp(aluOp),               // ALU Operation
    .memWR(memW),                // Memory Write (To Memory Controller)
    .aluS1(aluS1),               // ALU Source 1
    .aluS2(aluS2),               // ALU Source 2
    .branchCtrl(bCtrl),          // Branch Control Type
    .memCtrl(memCtrl),           // Memory Control Type (To Memory Controller)
    .doJump(doJump),             // Jump Flag
    .doBranch(doBranch)          // Branch Flag
  );
  
  regFile #(32) registerFile (
    .clk(clk),                   // Clock Input (External)
    .wrEn(regWR),                // Register Write
    .rs1(rs1),                   // Register Souce 1
    .rs2(rs2),                   // Register Souce 2
    .rd(rd),                     // Register Destination
    .r1(r1),                     // Register Value 1
    .r2(r2),                     // Register Value 2
    .dIn(dIn),                   // Register Data Input
    .rst(rst)                    // Reset Input (External)
  );
  
  signExt signExtender (
    .opcode(opcode),             // Opcode
    .instIn(instIn),             // Instruction In (From Memory Controller)
    .immOut(imm)                 // Immediate Value
  );
  
  alu ALU(
    .d1(aluD1),                  // ALU Data In 1
    .d2(aluD2),                  // ALU Data In 2
    .result(aluOut),             // ALU Output (To Memory Controller)
    .control(aluOp)
  );
  
  mux21 #(32) aluSrc1 (
    .a(r1),                      // Register Value 1
    .b(pcP),                     // PC-Present (To Memory Controller)
    .s(aluS1),                   // ALU Source 1
    .y(aluD1)                    // ALU Data In 1
  );
  
  mux21 #(32) aluSrc2 (
    .a(imm),                     // Immediate Value
    .b(r2),                      // Register Value 2
    .s(aluS2),                   // ALU Source 2
    .y(aluD2)                    // ALU Data In 2
  );
  
  branchCtrl branchController (
    .bCtrl(bCtrl),               // Branch Control Type
    .r1(r1),                     // Register Value 1
    .r2(r2),                     // Register Value 2
    .bSel(branchValid)           // Branch Condition Valid
  );
  
  or2 #(32) branchJumpGate (
    .a(doJump),                  // Jump Flag
    .b(branchTrue),              // Branch Conditions True
    .y(branchSel)                // Branch Select 
  );
  
  and2 #(32) branchValidate (
    .a(branchValid),             // Branch Condition Valid
    .b(doBranch),                // Branch Flag
    .y(branchTrue)               // Branch Conditions True
  );
  

  
  mux31 #(32) writebackMUX (
    .a(aluOut),                  // ALU Output (To Memory Controller)
    .b(dataOut),                 // Data Output (From Memory Controller)
    .c(pcN),                     // PC-Next
    .y(dIn),                     // Register Data Input
    .s(wbCtrl)                   // Writeback Control
  );
endmodule
