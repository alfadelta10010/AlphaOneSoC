module fyracore(dataOut, addrOut, dataIn, wbOut, clk, rst);
  wire [31:0] pcP, 
  <imports>
  
  // To memory controller: pcP, 
  // From memory controller: instOut/instIn
  
  adder #(32) pcAdder (
    .a(32'd4), 
    .b(pcP), 
    .s(pcN)
  ); 
  
  mux21 #(32) branchMux (
    .a(pcN), 
    .b(branchVal), 
    .s(branchSel), 
    .y(pcIn)
  );
  
  regs #(32) programCounter (
    .clk(clk), 
    .rst(rst), 
    .in(pcIn), 
    .out(pcP), 
    .en(pcEn)
  );
  
  decoder decoderUnit (
    .instIn(instIn), 
    .opcode(opcode), 
    .rd(rdOut), 
    .rs1(rs1Out), 
    .rs2(rs2Out), 
    .fn3(fn3), 
    .fn7(fn7)
  );
  
  controller controlUnit (
    .f3(f3), 
    .f7(f7), 
    .opcode(opcode), 
    .regWR(regWR), 
    .wbCtrl(wbCtrl), 
    .aluOp(aluOp), 
    .memWR(memW), 
    .aluS1(aluS1), 
    .aluS2(aluS2), 
    .branchCtrl(branchCtrl), 
    .memCtrl(memCtrl), 
    .doJump(doJump), 
    .doBranch(doBranch)
  );
  
  regFile #(32) registerFile (
    .clk(clk), 
    .wrEn(regWRIn), 
    .rs1(rs1Out), 
    .rs2(rs2Out), 
    .rd(rdIn), 
    .r1(r1), 
    .r2(r2), 
    .dIn(DIn), 
    rst(pcRst)
  );
  
  signExt signExtender (
    .opcode(opcode), 
    .instIn(instIn), 
    .immOut(imm)
  );
  
  alu ALU(
    .d1(aluY1), 
    .d2(aluY2), 
    .result(aluOut), 
    .control(aluOp)
  );
  
  branchCtrl branchController (
    .bCtrl(bCtrl), 
    .r1(r1), 
    .r2(r2), 
    .bSel(branchYes)
  );
  
  mux21 #(32) aluSrc1 (
    .a(r1), 
    .b(pcP), 
    .s(aluS1), 
    .y(aluY1)
  );
  
  mux21 #(32) aluSrc2 (
    .a(imm), 
    .b(r2), 
    .s(aluS2), 
    .y(aluY2)
  );
  
  or2 #(32) branchJumpGate (
    .a(doJump), 
    .b(branchYes), 
    .y(bSel)
  );
  
  and2 #(32) branchValidate (
    .a(branchOut), 
    .b(doBranch), 
    .y(branchYes)
  );
  
  memCtrlr #(12) memoryController (
    .memCtrl(memCtrl), 
    .addrIn(aluOut), 
    .dataRI(dataR), 
    .dataWI(dataIn), 
    .dataRO(dataOut), 
    .dataWO(dataW), 
    .addrOut(addrOut), 
    .wrType(wrType)
  );
  
  mux31 #(32) writebackMUX (
    .a(aluOut), 
    .b(dataOut), 
    .c(pcN), 
    .y(wbOut), 
    .s(wbCtrl)
  );
  
endmodule