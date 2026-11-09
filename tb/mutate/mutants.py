# Mutant definitions for tb/mutate/run.py.
#
# Each entry is one fault injected into a throwaway copy of src/ (under
# build/mut/, never into src/ itself): (id, file, find, replace, intent).
# `find` must occur exactly once in the file; run.py refuses the mutant
# otherwise, so an RTL edit that moves the text shows up as a broken mutant
# instead of silently testing nothing. The intent says which bug class the
# mutant stands for: inverted condition, off-by-one, stuck bit, dropped
# reset, swapped priority, removed stall or hazard term, broken bypass,
# wrong field. Some are equivalent at the core level (fyracore never
# exercises the difference) and can only be killed by the unit bench; the
# intent says so where it is known.

M = []
def m(mid, f, find, rep, why):
    M.append((mid, f, find, rep, why))

# ── alu.v ────────────────────────────────────────────────────────────────
m("ALU01", "alu.v", "5'b00000: result = d1 + d2;", "5'b00000: result = d1 - d2;", "ADD computes SUB")
m("ALU02", "alu.v", "5'b00000: result = d1 + d2;",
  "5'b00000: result = {d1[31:16] + d2[31:16], d1[15:0] + d2[15:0]};", "ADD carry chain broken at bit 16")
m("ALU03", "alu.v", "5'b00100: result = d1 ^ d2;", "5'b00100: result = d1 | d2;", "XOR computes OR")
m("ALU04", "alu.v", "5'b00110: result = d1 | d2;", "5'b00110: result = (d1 | d2) & 32'hFFFF7FFF;", "OR bit 15 stuck at 0")
m("ALU05", "alu.v", "5'b00111: result = d1 & d2;", "5'b00111: result = (d1 & d2) | 32'h00000001;", "AND bit 0 stuck at 1")
m("ALU06", "alu.v", "5'b00010: result = {31'b0, lt_signed};", "5'b00010: result = {31'b0, lt_unsigned};", "SLT uses the unsigned compare")
m("ALU07", "alu.v", "default:  result = 32'b0;", "default:  result = d1;", "unissued codes give d1, not 0 (unit contract only)")

# ── branchCtrl.v ─────────────────────────────────────────────────────────
m("BR01", "branchCtrl.v", "assign lt_signed   = (r1[31] != r2[31]) ? r1[31] : sub33[32];",
  "assign lt_signed   = (r1[31] != r2[31]) ? r2[31] : sub33[32];", "signed compare inverted when signs differ")
m("BR02", "branchCtrl.v", "3'b101:  branchValid = !lt_signed;     // BGE",
  "3'b101:  branchValid =  lt_signed;     // BGE", "BGE inverted")
m("BR03", "branchCtrl.v", "wire eq          = (sub33[31:0] == 32'b0);",
  "wire eq          = (sub33[30:0] == 31'b0);", "equality ignores bit 31")
m("BR04", "branchCtrl.v", "assign lt_unsigned = sub33[32];", "assign lt_unsigned = sub33[31];", "unsigned compare from the wrong borrow bit")
m("BR05", "branchCtrl.v", "3'b110:  branchValid =  lt_unsigned;   // BLTU",
  "3'b110:  branchValid =  lt_signed;   // BLTU", "BLTU uses the signed compare")
m("BR06", "branchCtrl.v", "default: branchValid = 1'b0;", "default: branchValid = eq;", "reserved funct3 010/011 taken on equal")
m("BR07", "branchCtrl.v", "assign diff        = sub33[31:0];", "assign diff        = {sub33[31:1], 1'b0};", "SUB result bit 0 stuck at 0")

# ── signExt.v ────────────────────────────────────────────────────────────
m("SE01", "signExt.v", "immOut = {{12{instIn[31]}}, instIn[19:12], instIn[20], instIn[30:21], 1'b0};",
  "immOut = {{12{instIn[31]}}, instIn[19:12], instIn[31], instIn[30:21], 1'b0};", "JAL imm[11] from the sign bit")
m("SE02", "signExt.v", "immOut = {{20{instIn[31]}}, instIn[7], instIn[30:25], instIn[11:8], 1'b0};",
  "immOut = {{20{instIn[31]}}, instIn[31], instIn[30:25], instIn[11:8], 1'b0};", "branch imm[11] from the sign bit")
m("SE03", "signExt.v", "immOut = {{20{instIn[31]}}, instIn[31:25], instIn[11:7]};",
  "immOut = {{20{instIn[31]}}, instIn[31:25], instIn[11:8], 1'b0};", "store imm[0] stuck at 0")
m("SE04", "signExt.v", "if (instIn[14:12] == 3'b001 || instIn[14:12] == 3'b101)",
  "if (instIn[14:12] == 3'b001)", "SRLI/SRAI immediate sign-extended (core-equivalent: shamt is b[4:0])")
m("SE05", "signExt.v", "immOut = {27'b0, instIn[19:15]}; // zimm", "immOut = {27'b0, instIn[24:20]}; // zimm", "zimm from the wrong field (core-equivalent: fyracore takes zimm from rs1)")
m("SE06", "signExt.v", "immOut = {instIn[31:12], 12'b0};", "immOut = {instIn[31:13], 13'b0};", "U-type imm[12] lost")
m("SE07", "signExt.v", "7'b0000011: // Load (I-type)\n                immOut = {{20{instIn[31]}}, instIn[31:20]};",
  "7'b0000011: // Load (I-type)\n                immOut = {{20{instIn[30]}}, instIn[31:20]};", "load offset sign-extended from bit 30")
m("SE08", "signExt.v", "7'b1100111: // JALR (I-type)\n                immOut = {{20{instIn[31]}}, instIn[31:20]};",
  "7'b1100111: // JALR (I-type)\n                immOut = {{20{instIn[31]}}, instIn[31:21], 1'b0};", "JALR offset bit 0 dropped")

# ── decoder.v (decoder + rf_fields) ──────────────────────────────────────
m("DE01", "decoder.v", "7'b0110011: begin // R-type (ADD, SUB, SLL, SLT, ... and M-ext)\n                rd     = instIn[11:7];\n                rs1    = instIn[19:15];\n                rs2    = instIn[24:20];",
  "7'b0110011: begin // R-type (ADD, SUB, SLL, SLT, ... and M-ext)\n                rd     = instIn[11:7];\n                rs1    = instIn[19:15];\n                rs2    = {1'b0, instIn[23:20]};", "R-type rs2 bit 4 lost")
m("DE02", "decoder.v", "7'b0101111: begin // A-extension (AMO)\n                rd     = instIn[11:7];\n                rs1    = instIn[19:15];\n                rs2    = instIn[24:20];",
  "7'b0101111: begin // A-extension (AMO)\n                rd     = instIn[11:7];\n                rs1    = instIn[19:15];\n                rs2    = 5'b0;", "AMO/SC rs2 not decoded")
m("DE03", "decoder.v", "7'b0100011: begin // S-type (SB, SH, SW)\n                rs1    = instIn[19:15];\n                rs2    = instIn[24:20];",
  "7'b0100011: begin // S-type (SB, SH, SW)\n                rs1    = instIn[19:15];\n                rs2    = instIn[11:7];", "store rs2 from the imm field")
m("DE04", "decoder.v", "7'b1100111: begin // JALR\n                rd     = instIn[11:7];\n                rs1    = instIn[19:15];",
  "7'b1100111: begin // JALR\n                rd     = instIn[11:7];\n                rs1    = 5'b0;", "JALR rs1 not decoded")
m("DE05", "decoder.v", "funct7 = instIn[31:25]; // upper bits for ECALL/EBREAK/MRET",
  "funct7 = instIn[30:24]; // upper bits for ECALL/EBREAK/MRET", "SYSTEM funct7 off by one bit")
m("DE06", "decoder.v", "if (instIn[14:12] == 3'b001 || instIn[14:12] == 3'b101)\n                    funct7 = instIn[31:25];",
  "if (instIn[14:12] == 3'b001)\n                    funct7 = instIn[31:25];", "SRAI decoded as SRLI")
m("DE07", "decoder.v", "7'b1100011: begin // B-type (BEQ, BNE, BLT, BGE, BLTU, BGEU)\n                rs1    = instIn[19:15];\n                rs2    = instIn[24:20];",
  "7'b1100011: begin // B-type (BEQ, BNE, BLT, BGE, BLTU, BGEU)\n                rs1    = instIn[19:15];\n                rs2    = instIn[19:15];", "branch compares rs1 with itself")
m("RF01", "decoder.v", "wire sp    = (q == 2'b00) ? !f3[1] : (q == 2'b10) && f3[1];",
  "wire sp    = (q == 2'b00) ? !f3[1] : (q == 2'b10) && f3[2];", "rf_fields: wrong quadrant-2 sp detect")
m("RF02", "decoder.v", "prime        ? {2'b01, instr[9:7]} : instr[11:7];",
  "prime        ? {2'b00, instr[9:7]} : instr[11:7];", "rf_fields: rs1' maps to x0-x7")
m("RF03", "decoder.v", "(q == 2'b10) ? instr[6:2]   : {2'b01, instr[4:2]};",
  "(q == 2'b10) ? instr[6:2]   : {2'b01, instr[5:3]};", "rf_fields: rs2' from the wrong bits")
m("RF04", "decoder.v", "assign rs1 = (q == 2'b11) ? instr[19:15] :",
  "assign rs1 = (q == 2'b11) ? instr[20:16] :", "rf_fields: 32-bit rs1 off by one")
m('RFF01', 'decoder.v', "wire sp    = (q == 2'b00) ? !f3[1] : (q == 2'b10) && f3[1];", "wire sp    = (q == 2'b00) ? !f3[1] : (q == 2'b10) && f3[1] && !f3[2];", "C.SWSP's base register is not sp")
m('RFF02', 'decoder.v', "wire prime = (q == 2'b00) ?  f3[1] : (q == 2'b01) && f3[2];", "wire prime = (q == 2'b00) ?  f3[1] : (q == 2'b01) && f3[2] && !f3[1];", 'C.BEQZ/C.BNEZ read rs1 from the full rd field')
m('RFF03', 'decoder.v', "prime        ? {2'b01, instr[9:7]} : instr[11:7];", "prime        ? {2'b00, instr[9:7]} : instr[11:7];", "rs1' maps to x0-x7, not x8-x15")
m('RFF04', 'decoder.v', "(q == 2'b10) ? instr[6:2]   : {2'b01, instr[4:2]};", "(q == 2'b10) ? {instr[6:3], 1'b0} : {2'b01, instr[4:2]};", "quadrant 2's rs2 (C.MV, C.ADD, C.SWSP) loses bit 0")

# ── controller.v ─────────────────────────────────────────────────────────
m("CT01", "controller.v", "3'b100:  begin memSize = 2'b00; memUnsigned = 1'b1; end // LBU",
  "3'b100:  begin memSize = 2'b00; memUnsigned = 1'b0; end // LBU", "LBU sign-extends")
m("CT02", "controller.v", "3'b001:  begin memSize = 2'b01; memUnsigned = 1'b0; end // LH",
  "3'b001:  begin memSize = 2'b10; memUnsigned = 1'b0; end // LH", "LH loads a word")
m("CT03", "controller.v", "3'b001:  memSize = 2'b01; // SH", "3'b001:  memSize = 2'b00; // SH", "SH stores a byte")
m("CT04", "controller.v", "aluOp   = 5'b00000; // ADD (PC + imm)\n                aluSrc1 = 1'b1;     // PC",
  "aluOp   = 5'b00000; // ADD (PC + imm)\n                aluSrc1 = 1'b0;     // PC", "AUIPC adds to rs1")
m("CT05", "controller.v", "if (funct3 != 3'b000) begin", "if (1'b0) begin", "JALR with funct3 != 0 accepted")
m("CT06", "controller.v", "3'b011: begin // CSRRC\n                        regWR  = 1'b1;\n                        wbSel  = 2'b11;\n                        csrOp  = 2'b11;",
  "3'b011: begin // CSRRC\n                        regWR  = 1'b1;\n                        wbSel  = 2'b11;\n                        csrOp  = 2'b10;", "CSRRC sets instead of clearing")
m("CT07", "controller.v", "3'b110: begin // CSRRSI\n                        regWR  = 1'b1;\n                        wbSel  = 2'b11;\n                        csrOp  = 2'b10;\n                        csrSrc = 1'b1;",
  "3'b110: begin // CSRRSI\n                        regWR  = 1'b1;\n                        wbSel  = 2'b11;\n                        csrOp  = 2'b10;\n                        csrSrc = 1'b0;", "CSRRSI uses rs1's value, not zimm")
m("CT08", "controller.v", "5'b00100, // AMOXOR", "5'b11111, // AMOXOR", "AMOXOR illegal, a reserved AMO code accepted")
m("CT09", "controller.v", "wbSel = 2'b00; // rd gets 0 (success) or 1 (fail)", "wbSel = 2'b01; // rd gets 0 (success) or 1 (fail)", "SC writes memory data to rd")
m("CT10", "controller.v", "if (funct3 == 3'b000 || funct3 == 3'b101)", "if (funct3 == 3'b000 || funct3 == 3'b101 || funct3 == 3'b001)", "funct7=0100000 SLL accepted")
m("CT11", "controller.v", "if (funct3 == 3'b000)\n                    isFence = 1'b1;", "if (funct3 == 3'b000 || funct3 == 3'b010)\n                    isFence = 1'b1;", "MISC-MEM funct3 010 accepted as FENCE")
m("CT12", "controller.v", "3'b000, 3'b001, 3'b100, 3'b101, 3'b110, 3'b111: ; // valid",
  "3'b000, 3'b001, 3'b010, 3'b100, 3'b101, 3'b110, 3'b111: ; // valid", "branch funct3 010 accepted")
m("CT13", "controller.v", "memRD   = 1'b0;  // and no access, so no address exception",
  "memRD   = 1'b1;  // and no access, so no address exception", "illegal load still accesses memory (misaligned outranks illegal)")
m("CT14", "controller.v", "default: aluOp = {2'b00, funct3};", "default: aluOp = (funct3 == 3'b011) ? 5'b00010 : {2'b00, funct3};", "SLTIU computes SLTI")
m("CT15", "controller.v", "else if (funct7 == 7'b0001000)\n                            ;", "else if (funct7 == 7'b0001000)\n                            illegal = 1'b1;", "WFI illegal")
m("CT16", "controller.v", "isMulDiv = 1'b1;\n                    aluOp    = {2'b10, funct3};", "isMulDiv = !funct3[2];\n                    aluOp    = {2'b10, funct3};", "divides not routed to muldiv")
m("CT17", "controller.v", "memWR   = 1'b0;  // no access, so no address exception", "memWR   = 1'b1;  // no access, so no address exception", "illegal store still accesses memory")
m("CT18", "controller.v", "isLR  = 1'b1;\n                            regWR = 1'b1;", "isLR  = 1'b1;\n                            regWR = 1'b0;", "LR does not write rd")

# ── compressed_decoder.v ─────────────────────────────────────────────────
m("CD01", "compressed_decoder.v", "instr_in[5],     // nzuimm[3]\n                                instr_in[6],     // nzuimm[2]",
  "instr_in[6],     // nzuimm[3]\n                                instr_in[5],     // nzuimm[2]", "C.ADDI4SPN nzuimm[3:2] swapped")
m("CD02", "compressed_decoder.v", "instr_in[5],      // uimm[6]\n                            instr_in[12:10],  // uimm[5:3]",
  "instr_in[6],      // uimm[6]\n                            instr_in[12:10],  // uimm[5:3]", "C.LW uimm[6] from bit 6")
m("CD03", "compressed_decoder.v", "instr_in[11:10],  // uimm[4:3]", "instr_in[12:11],  // uimm[4:3]", "C.SW uimm[4:3] shifted")
m("CD04", "compressed_decoder.v", "instr_in[8],                     // imm[10]", "instr_in[7],                     // imm[10]", "C.JAL imm[10] from bit 7")
m("CD05", "compressed_decoder.v", "instr_in[5],         // imm[6]\n                                    instr_in[2],         // imm[5]",
  "instr_in[2],         // imm[6]\n                                    instr_in[5],         // imm[5]", "C.ADDI16SP imm[6:5] swapped")
m("CD06", "compressed_decoder.v", "// nzimm=0 is reserved for every rd.\n                            if ({instr_in[12], instr_in[6:2]} == 6'b0)",
  "// nzimm=0 is reserved for every rd.\n                            if (instr_in[6:2] == 5'b0)", "C.LUI with only nzimm[17] set called reserved")
m("CD07", "compressed_decoder.v", "7'b0100000,\n                                        instr_in[6:2],  // shamt",
  "7'b0000000,\n                                        instr_in[6:2],  // shamt", "C.SRAI expands to SRLI")
m("CD08", "compressed_decoder.v", "instr_out = {7'b0000000, rs2_p, rs1_p, 3'b100, rs1_p, 7'b0110011};",
  "instr_out = {7'b0000000, rs2_p, rs1_p, 3'b110, rs1_p, 7'b0110011};", "C.XOR expands to OR")
m("CD09", "compressed_decoder.v", "instr_in[12],         // imm[11] sign bit", "instr_in[11],         // imm[11] sign bit", "C.BEQZ imm[11] from bit 11")
m("CD10", "compressed_decoder.v", "3'b001,              // BNE", "3'b000,              // BNE", "C.BNEZ expands to BEQ")
m("CD11", "compressed_decoder.v", "if (rd_full == 5'd0)\n                            illegal = 1'b1;\n                        else begin\n                            // LW rd, uimm(x2)",
  "if (1'b0)\n                            illegal = 1'b1;\n                        else begin\n                            // LW rd, uimm(x2)", "C.LWSP rd=0 accepted")
m("CD12", "compressed_decoder.v", "if (rd_full == 5'd0)\n                                    illegal = 1'b1;\n                                else\n                                    // JALR x0, rs1, 0",
  "if (1'b0)\n                                    illegal = 1'b1;\n                                else\n                                    // JALR x0, rs1, 0", "C.JR rs1=0 accepted")
m("CD13", "compressed_decoder.v", "instr_in[8:7],     // uimm[7:6]", "instr_in[10:9],     // uimm[7:6]", "C.SWSP uimm[7:6] from the wrong bits")
m("CD14", "compressed_decoder.v", "3'b000: begin // C.SLLI\n                        if (instr_in[12]) // shamt[5] must be 0 on RV32",
  "3'b000: begin // C.SLLI\n                        if (1'b0) // shamt[5] must be 0 on RV32", "C.SLLI shamt[5]=1 accepted")
m("CD15", "compressed_decoder.v", "instr_out = {7'b0000000, rs2_full, 5'd0, 3'b000, rd_full, 7'b0110011};",
  "instr_out = {7'b0000000, rs2_full, rd_full, 3'b000, rd_full, 7'b0110011};", "C.MV expands to ADD")
m("CD16", "compressed_decoder.v", "instr_out = {12'b0, rd_full, 3'b000, 5'd1, 7'b1100111};",
  "instr_out = {12'b0, rd_full, 3'b000, 5'd0, 7'b1100111};", "C.JALR does not link")
m("CD17", "compressed_decoder.v", "3'b111,         // ANDI", "3'b110,         // ANDI", "C.ANDI expands to ORI")
m("CD18", "compressed_decoder.v", "5'd0,                // rs1 = x0", "rd_full,                // rs1 = x0", "C.LI adds to rd")

# ── muldiv.v ─────────────────────────────────────────────────────────────
m("MD01", "muldiv.v", "sa <= (op == 3'd1) | (op == 3'd2);", "sa <= (op == 3'd1);", "MULHSU multiplicand treated unsigned")
m("MD02", "muldiv.v", "sb <= (op == 3'd1);", "sb <= (op == 3'd1) | (op == 3'd2);", "MULHSU multiplier treated signed")
m("MD03", "muldiv.v", "wire        negres = isdiv & (hi ? na : ((na ^ nb) & ~mzero));",
  "wire        negres = isdiv & (hi ? na : ((na ^ nb)));", "negative / 0 gives +1, not -1")
m("MD04", "muldiv.v", "wire        negres = isdiv & (hi ? na : ((na ^ nb) & ~mzero));",
  "wire        negres = isdiv & (hi ? (na ^ nb) : ((na ^ nb) & ~mzero));", "remainder takes the quotient's sign")
m("MD05", "muldiv.v", "fill <= sra & a[31];", "fill <= a[31];", "SRL fills with the sign bit")
m("MD06", "muldiv.v", "cnt  <= ~b[4:0];", "cnt  <= ~{1'b0, b[3:0]};", "shift amount bit 4 lost")
m("MD07", "muldiv.v", "acc <= sum[33] ? {1'b0, trial[31:0]} : {1'b0, sum[31:0]};",
  "acc <= sum[32] ? {1'b0, trial[31:0]} : {1'b0, sum[31:0]};", "restoring step tests the wrong borrow bit")
m("MD08", "muldiv.v", "lo   <= sum[31:0];\n                busy <= 1'b0;\n                done <= 1'b1;",
  "lo   <= sum[31:0];\n                busy <= 1'b0;\n                done <= 1'b0;", "M ops never signal done (hang)")
m("MD09", "muldiv.v", "lo   <= sum[31:0];\n                busy <= 1'b0;", "lo   <= sum[31:0];\n                busy <= 1'b1;", "busy stuck after an M op")
m("MD10", "muldiv.v", "hi <= (op != 3'd0);", "hi <= op[0];", "MULHSU returns the low word")
m("MD11", "muldiv.v", "na <= ~op[0] & a[31];", "na <= a[31];", "DIVU/REMU treat the dividend as signed")
m("MD12", "muldiv.v", "if (rst) begin\n            st   <= S_IDLE;\n            busy <= 1'b0;", "if (rst) begin\n            busy <= 1'b0;", "reset does not return the FSM to idle")
m("MD13", "muldiv.v", "            end\n            S_NEGA: begin", "            end else lo <= 32'b0;\n            S_NEGA: begin", "result cleared the cycle after done (not held until the next start)")
m("MD14", "muldiv.v", "sub = (cnt == 5'd31) & sb;", "sub = (cnt == 5'd30) & sb;", "signed multiply subtracts on the wrong step")
m("MD15", "muldiv.v", "shr  <= op[2];", "shr  <= op[1];", "right shifts shift left")
m("MD16", "muldiv.v", "lo  <= {lo[30:0], ~sum[33]};", "lo  <= {lo[30:0], sum[33]};", "quotient bits inverted")

# ── regFile.v ────────────────────────────────────────────────────────────
m("RG01", "regFile.v", "wire        w_ena = wrEn && (rd != 5'b0);", "wire        w_ena = wrEn;", "x0 writable (core-equivalent: fyracore masks x0 reads)")
m("RG02", "regFile.v", "hit1 <= w_ena && (ra == rd);", "hit1 <= w_ena && (rb == rd);", "port 1 bypass compares port 2's address")
m("RG03", "regFile.v", "hit2 <= w_ena && (rb == rd);", "hit2 <= 1'b0;", "port 2 bypass removed (only +RF_COLLIDE_X shows it)")
m("RG04", "regFile.v", "hit1 <= w_ena && (ra == rd);", "hit1 <= wrEn && (ra == rd);", "port 1 bypass fires on a write to x0")
m("RG05", "regFile.v", "assign r1 = hit1 ? byp : m1;", "assign r1 = m1;", "port 1 bypass removed (only +RF_COLLIDE_X shows it)")

# ── csr.v ────────────────────────────────────────────────────────────────
m("CS01", "csr.v", "wire [31:0] mie_legal     = csr_new & 32'h0000_0888;", "wire [31:0] mie_legal     = csr_new & 32'h0000_088A;", "mie.SSIE writable")
m("CS02", "csr.v", "wire [31:0] mtvec_legal   = {csr_new[31:2], 2'b00};", "wire [31:0] mtvec_legal   = {csr_new[31:1], 1'b0};", "mtvec bit 1 stored")
m("CS03", "csr.v", "wire [31:0] mcountinhibit_legal = csr_new & 32'h0000_0005;", "wire [31:0] mcountinhibit_legal = csr_new & 32'h0000_0007;", "mcountinhibit.TM writable")
m("CS04", "csr.v", "pmpcfg_legal = {b[7], 2'b00, b[4:2], b[1] & b[0], b[0]};", "pmpcfg_legal = {b[7], 2'b00, b[4:2], b[1], b[0]};", "pmpcfg R=0,W=1 stored")
m("CS05", "csr.v", "pmpcfg0[15] ? pmpcfg0[15:8]  : pmpcfg_legal(csr_new[15:8]),", "1'b0 ? pmpcfg0[15:8]  : pmpcfg_legal(csr_new[15:8]),", "pmpcfg entry 1 lock ignored")
m("CS06", "csr.v", "wire tor_lock_addr0 = pmpcfg0[7]  || (pmpcfg0[12:11] == 2'b01 && pmpcfg0[15]);", "wire tor_lock_addr0 = pmpcfg0[7];", "TOR lock of entry 1 does not lock pmpaddr0")
m("CS07", "csr.v", "mstatus_after_we[12:11] = {2{csr_new[12] & csr_new[11]}};", "mstatus_after_we[12:11] = csr_new[12:11];", "MPP stores 01/10")
m("CS08", "csr.v", "mstatus_after_we[3], mstatus_after_we[6:4], 1'b0, mstatus_after_we[2:0]};", "1'b1, mstatus_after_we[6:4], 1'b0, mstatus_after_we[2:0]};", "trap sets MPIE=1 whatever MIE was")
m("CS09", "csr.v", "& ((mstatus_after_we[12:11] == 2'b11) ? 32'hFFFF_FFFF", "& ((mstatus_after_we[12:11] != 2'b11) ? 32'hFFFF_FFFF", "MRET clears MPRV on return to M, keeps it on return to U")
m("CS10", "csr.v", "1'b1, mstatus_after_we[6:4], mstatus_after_we[7], mstatus_after_we[2:0]}", "1'b1, mstatus_after_we[6:4], mstatus_after_we[3], mstatus_after_we[2:0]}", "MRET leaves MIE alone")
m("CS11", "csr.v", "wire [31:0] mepc_eff = {mepc[31:2], (misa_c ? mepc[1] : 1'b0), 1'b0};", "wire [31:0] mepc_eff = {mepc[31:1], 1'b0};", "mepc[1] not masked while misa.C=0")
m("CS12", "csr.v", "wire        misa_we_ok    = we && waddr == 12'h301 &&\n                                (csr_new[2] || !pc_next_misaligned);",
  "wire        misa_we_ok    = we && waddr == 12'h301 &&\n                                1'b1;", "misa.C clear accepted with a misaligned next pc")
m("CS13", "csr.v", "(we && waddr == 12'hB00) ? {mcycle[63:32], csr_new} :", "(we && waddr == 12'hB00) ? {mcycle_inc[63:32], csr_new} :", "mcycle low write keeps the replaced increment's carry")
m("CS14", "csr.v", "wire [63:0] minstret_next = (instret_inc && !mcountinhibit[2] && !minstret_we) ?", "wire [63:0] minstret_next = (instret_inc && !mcountinhibit[0] && !minstret_we) ?", "minstret inhibited by CY")
m("CS15", "csr.v", "wire [63:0] mcycle_next   = (!mcountinhibit[0] && !mcycle_we && !mcycle_wr_q) ?", "wire [63:0] mcycle_next   = (!mcountinhibit[0] && !mcycle_we) ?", "mcycle counts the clock after a write")
m("CS16", "csr.v", "12'hC02: begin rdata = minstret_next[31:0];  if (!priv_mode && !mcounteren[2]) addr_valid = 1'b0; end", "12'hC02: begin rdata = minstret_next[31:0];  if (!priv_mode && !mcounteren[0]) addr_valid = 1'b0; end", "instret gated by mcounteren.CY")
m("CS17", "csr.v", "(raddr[11:5] == 7'b1011_000 && raddr[4:0] >= 5'd3) ||   // mhpmcounter3-31", "(raddr[11:5] == 7'b1011_000 && raddr[4:0] >= 5'd4) ||   // mhpmcounter3-31", "mhpmcounter3 illegal")
m("CS18", "csr.v", "(timer_irq    ? 32'h0000_0080 : 32'b0) |  // MTIP bit 7", "(timer_irq    ? 32'h0000_0020 : 32'b0) |  // MTIP bit 7", "mip.MTIP read at bit 5")
m("CS19", "csr.v", "mtvec    <= 32'h0000_0000;", "mtvec    <= mtvec;", "mtvec reset dropped")
m("CS20", "csr.v", "always @(posedge clk) c32 <= &d[31:0];", "always @(posedge clk) c32 <= &d[30:0];", "inc64 carries into the high half one count early")
m("CS21", "csr.v", "wire [31:0] mcounteren_legal    = csr_new & 32'h0000_0007;", "wire [31:0] mcounteren_legal    = csr_new & 32'h0000_0005;", "mcounteren.TM not writable")
m("CS22", "csr.v", "12'hF15: rdata = 32'b0;  // mconfigptr: no config data structure", "12'hF16: rdata = 32'b0;  // mconfigptr: no config data structure", "mconfigptr missing, 0xF16 present")
m("CS23", "csr.v", "mstatus <= {mstatus_after_we[31:13], {priv_mode, priv_mode}, mstatus_after_we[10:8],", "mstatus <= {mstatus_after_we[31:13], 2'b11, mstatus_after_we[10:8],", "trap from U saves MPP=M")
m("CS24", "csr.v", "wire [31:0] pmpaddr3_legal = tor_lock_addr3 ? pmpaddr3 : csr_new;", "wire [31:0] pmpaddr3_legal = csr_new;", "locked pmpaddr3 writable")
m("CS25", "csr.v", "mtval    <= trap_val;", "mtval    <= mtval;", "mtval not written on a trap")
m("CS26", "csr.v", "(we && waddr == 12'hB02) ? {minstret[63:32], csr_new} :", "(we && waddr == 12'hB02) ? {minstret_inc[63:32], csr_new} :", "minstret low write keeps the replaced increment's carry")
m("CS27", "csr.v", "mstatus_after_we[21] = csr_new[21];  // TW", "mstatus_after_we[21] = 1'b0;  // TW", "mstatus.TW not writable")
m("CS28", "csr.v", "mstatus_after_we[17] = csr_new[17];  // MPRV", "mstatus_after_we[17] = 1'b0;  // MPRV", "mstatus.MPRV not writable")
m("CS29", "csr.v", "12'hC01: begin rdata = mtime_in[31:0];        if (!priv_mode && !mcounteren[1])", "12'hC01: begin rdata = mtime_in[31:0];        if (1'b0)", "U-mode time read ignores mcounteren.TM")

# ── pmp.v ────────────────────────────────────────────────────────────────
m("PM01", "pmp.v", "A_TOR:   match0 = (waddr < pmpaddr0);", "A_TOR:   match0 = (waddr <= pmpaddr0);", "TOR entry 0 top inclusive")
m("PM02", "pmp.v", "A_TOR:   match2 = (waddr >= pmpaddr1) && (waddr < pmpaddr2);", "A_TOR:   match2 = (waddr > pmpaddr1) && (waddr < pmpaddr2);", "TOR entry 2 bottom exclusive")
m("PM03", "pmp.v", "A_NA4:   match1 = (waddr == pmpaddr1);", "A_NA4:   match1 = (waddr[31:1] == pmpaddr1[31:1]);", "NA4 entry 1 matches 8 bytes")
m("PM04", "pmp.v", "mask = ~(pa ^ (pa + 1'b1));", "mask = ~(pa | (pa + 1'b1));", "NAPOT mask drops set address bits (an old bug)")
m("PM05", "pmp.v", "A_TOR:   match1 = (waddr >= pmpaddr0) && (waddr < pmpaddr1);", "A_TOR:   match1 = (waddr[29:0] >= pmpaddr0[29:0]) && (waddr[29:0] < pmpaddr1[29:0]);", "TOR entry 1 drops pmpaddr[31:30] (an old bug)")
m("PM06", "pmp.v", "if      (match0) pmp_allow = check_perm(cfg0, access_type, priv_mode);\n        else if (match1) pmp_allow = check_perm(cfg1, access_type, priv_mode);",
  "if      (match1) pmp_allow = check_perm(cfg1, access_type, priv_mode);\n        else if (match0) pmp_allow = check_perm(cfg0, access_type, priv_mode);", "entry 1 outranks entry 0")
m("PM07", "pmp.v", "if (cfg_in[7]) // Locked", "if (1'b0) // Locked", "lock does not bind M-mode")
m("PM08", "pmp.v", "else             pmp_allow = priv_mode; // no match: M=allow, U=deny", "else             pmp_allow = 1'b1; // no match: M=allow, U=deny", "no match allows U-mode")
m("PM09", "pmp.v", "check_perm = priv || ((cfg_in[2:0] & atype) == atype);", "check_perm = priv || ((cfg_in[2:0] & atype) != 3'b0);", "U-mode AMO needs only R or W")
m("PM10", "pmp.v", "case (cfg3[4:3])", "case (cfg2[4:3])", "entry 3 uses entry 2's A field")
m("PM11", "pmp.v", "wire [31:0] waddr = {2'b00, addr[31:2]};", "wire [31:0] waddr = {2'b00, addr[31:3], 1'b0};", "PMP compares 8-byte granules")
m("PM12", "pmp.v", "A_NA4:   match0 = (waddr == pmpaddr0);", "A_NA4:   match0 = (waddr < pmpaddr0);", "NA4 entry 0 behaves as TOR")

# ── clint.v ──────────────────────────────────────────────────────────────
m("CL01", "clint.v", "else     mtip <= (mtime >= mtimecmp);", "else     mtip <= (mtime > mtimecmp);", "MTIP one count late")
m("CL02", "clint.v", "if (wmask[1]) mtimecmp[47:40] <= wdata[15:8];", "if (wmask[2]) mtimecmp[47:40] <= wdata[15:8];", "mtimecmp_hi byte 1 written by lane 2")
m("CL03", "clint.v", "16'h0000: if (wmask[0]) msip <= wdata[0];", "16'h0000: msip <= wdata[0];", "msip written by any lane")
m("CL04", "clint.v", "mtimecmp <= 64'hFFFF_FFFF_FFFF_FFFF;", "mtimecmp <= 64'h0;", "mtimecmp resets to 0 (timer pending out of reset)")
m("CL05", "clint.v", "16'h4004: rdata = mtimecmp[63:32];", "16'h4004: rdata = mtimecmp[31:0];", "mtimecmp_hi reads the low half")
m("CL06", "clint.v", "wmask[3] ? wdata[31:24] : mtime[63:56],", "wmask[0] ? wdata[31:24] : mtime[63:56],", "mtime_hi byte 3 written by lane 0")
m("CL07", "clint.v", "end else if (we && addr == 16'hBFF8) begin", "end else if (1'b0) begin", "mtime_lo not writable")
m("CL08", "clint.v", "16'h0000: rdata = {31'b0, msip};", "16'h0000: rdata = {30'b0, msip, 1'b0};", "msip reads at bit 1")

# ── fyracore.v ───────────────────────────────────────────────────────────
m("FC01", "fyracore.v", "(exwb_rd == ex_rs1 || exwb_rd == ex_rs2);", "(exwb_rd == ex_rs1);", "use hazard ignores rs2")
m("FC03", "fyracore.v", "wire ex_misaligned_half = (ctrl_memSize == 2'b01) && (alu_r[0] != 1'b0);", "wire ex_misaligned_half = (ctrl_memSize == 2'b01) && (alu_r[1] != 1'b0);", "halfword alignment checks bit 1")
m("FC04", "fyracore.v", "wire ex_misaligned_word = (ctrl_memSize == 2'b10) && (alu_r[1:0] != 2'b00);", "wire ex_misaligned_word = (ctrl_memSize == 2'b10) && (alu_r[0] != 1'b0);", "word alignment ignores bit 1")
m("FC05", "fyracore.v", "(ex_pma_in_rom && !ex_misalign_is_store && !ctrl_isLR) ||", "(ex_pma_in_rom && !ctrl_isLR) ||", "stores to flash allowed")
m("FC06", "fyracore.v", "(ex_pma_in_io && !ctrl_isLR && !ctrl_isSC);", "(ex_pma_in_io && !ctrl_isSC);", "LR to an IO window allowed")
m("FC07", "fyracore.v", "end else if (ex_illegal_insn) begin", "end else if (ex_illegal_insn && !ex_misaligned) begin", "misaligned outranks illegal")
m("FC08", "fyracore.v", "exwb_trap_cause <= priv_mode ? 32'd11 : 32'd8; // M-mode=11, U-mode=8", "exwb_trap_cause <= 32'd11; // M-mode=11, U-mode=8", "ECALL from U reports cause 11")
m("FC09", "fyracore.v", "exwb_trap_val   <= ifex_pc;\n                    end else if (ex_misaligned && !ex_misalign_is_store) begin", "exwb_trap_val   <= 32'b0;\n                    end else if (ex_misaligned && !ex_misalign_is_store) begin", "EBREAK mtval 0")
m("FC10", "fyracore.v", "exwb_trap_cause <= 32'd4;  // Load address misaligned\n                        exwb_trap_val   <= alu_r;", "exwb_trap_cause <= 32'd4;  // Load address misaligned\n                        exwb_trap_val   <= ifex_pc;", "load-misaligned mtval is the pc")
m("FC11", "fyracore.v", "irq_external_pend ? {1'b1, 31'd11} :  // Machine External Interrupt\n        irq_sw_pend       ? {1'b1, 31'd3}  :  // Machine Software Interrupt",
  "irq_sw_pend       ? {1'b1, 31'd3}  :  // Machine Software Interrupt\n        irq_external_pend ? {1'b1, 31'd11} :  // Machine External Interrupt", "MSI outranks MEI")
m("FC12", "fyracore.v", "wire irq_global_en     = !priv_mode || csr_mstatus_mie;", "wire irq_global_en     = csr_mstatus_mie;", "U-mode interrupts masked by MIE")
m("FC13", "fyracore.v", "&& !muldiv_want && !stall_other;", "&& !muldiv_want;", "interrupt injected during a stall")
m("FC14", "fyracore.v", "&& !muldiv_want && !stall_other;", "&& !stall_other;", "interrupt injected while an M op is in EX")
m("FC15", "fyracore.v", "exwb_trap_pc    <= ex_is_wfi ? pc : ifex_pc;", "exwb_trap_pc    <= ifex_pc;", "interrupt at WFI saves the WFI's pc")
m("FC16", "fyracore.v", "wire       sc_success = reservation_valid &&\n                            (reservation_addr == exwb_alu_result[31:2]);", "wire       sc_success = reservation_valid;", "SC ignores the reservation address")
m("FC17", "fyracore.v", "if (csr_trap_signal)\n                reservation_valid <= 1'b0;", "if (1'b0)\n                reservation_valid <= 1'b0;", "trap does not clear the reservation")
m("FC18", "fyracore.v", "end else if (exwb_isSC) begin\n                    reservation_valid <= 1'b0;", "end else if (exwb_isSC) begin\n                    reservation_valid <= reservation_valid;", "SC does not clear the reservation")
m("FC19", "fyracore.v", "5'b10000: amo_computed = ($signed(load_data) < $signed(exwb_rs2_data)) ? load_data : exwb_rs2_data; // AMOMIN",
  "5'b10000: amo_computed = (load_data < exwb_rs2_data) ? load_data : exwb_rs2_data; // AMOMIN", "AMOMIN unsigned")
m("FC20", "fyracore.v", "5'b11100: amo_computed = (load_data > exwb_rs2_data) ? load_data : exwb_rs2_data; // AMOMAXU",
  "5'b11100: amo_computed = ($signed(load_data) > $signed(exwb_rs2_data)) ? load_data : exwb_rs2_data; // AMOMAXU", "AMOMAXU signed")
m("FC21", "fyracore.v", "wire [31:0] wb_load_or_amo = (exwb_isAmo && amo_phase) ? amo_old_val : load_data;", "wire [31:0] wb_load_or_amo = (exwb_isAmo && amo_phase) ? exwb_rs2_data : load_data;", "AMO writes the new value to rd")
m("FC22", "fyracore.v", "access_be = 4'b0001 << mem_byte_offset;", "access_be = 4'b0001;", "byte access always lane 0")
m("FC23", "fyracore.v", "access_be = (mem_byte_offset[1]) ? 4'b1100 : 4'b0011;", "access_be = 4'b0011;", "halfword access always lanes 0-1")
m("FC24", "fyracore.v", "store_data_shifted = {4{exwb_rs2_data[7:0]}};", "store_data_shifted = {24'b0, exwb_rs2_data[7:0]};", "byte store data not replicated")
m("FC25", "fyracore.v", "2'b11: load_data = exwb_memUnsigned ? {24'b0, raw_load[31:24]} : {{24{raw_load[31]}}, raw_load[31:24]};",
  "2'b11: load_data = exwb_memUnsigned ? {24'b0, raw_load[31:24]} : {{24{raw_load[23]}}, raw_load[31:24]};", "LB of byte 3 sign-extends from bit 23")
m("FC26", "fyracore.v", "load_data = exwb_memUnsigned ? {16'b0, raw_load[31:16]} : {{16{raw_load[31]}}, raw_load[31:16]};",
  "load_data = exwb_memUnsigned ? {16'b0, raw_load[31:16]} : {{16{raw_load[15]}}, raw_load[31:16]};", "LH of the upper half sign-extends from bit 15")
m("FC27", "fyracore.v", "!wb_mem_stall;\n    assign wb_rd    = exwb_rd;", "1'b1;\n    assign wb_rd    = exwb_rd;", "register write on every cycle of a memory stall")
m("FC28", "fyracore.v", "!(exwb_isSC && !sc_success);", "1'b1;", "failing SC issues a bus read")
m("FC30", "fyracore.v", "wire ex_mret_commit = ex_is_mret && !stall && !ex_trap && !irq_inject;", "wire ex_mret_commit = ex_is_mret && !ex_trap && !irq_inject;", "MRET commits on every stalled cycle")
m("FC31", "fyracore.v", "wire ex_mret_commit = ex_is_mret && !stall && !ex_trap && !irq_inject;", "wire ex_mret_commit = ex_is_mret && !stall && !ex_trap;", "MRET commits as well as the interrupt taken at it")
m("FC32", "fyracore.v", "(ex_csr_addr == 12'h3A0 || ex_csr_addr[11:2] == 10'b0011_1011_00);", "(ex_csr_addr == 12'h3A0);", "pmpaddr write does not refetch")
m("FC33", "fyracore.v", "wire ex_ifetch_fault_hi = ex_straddle && (!ex_pma_fetch_hi_ok || ifetch_hi_denied);", "wire ex_ifetch_fault_hi = 1'b0;", "straddling fetch's upper half never faults")
m("FC34", "fyracore.v", "wire ex_ifetch_fault_hi = ex_straddle && (!ex_pma_fetch_hi_ok || ifetch_hi_denied);", "wire ex_ifetch_fault_hi = ex_straddle && (!ex_pma_fetch_hi_ok);", "straddling fetch's upper half skips PMP")
m("FC35", "fyracore.v", "wire data_priv_mode = csr_mstatus_mprv ? (csr_mstatus_mpp == 2'b11) : priv_mode;", "wire data_priv_mode = priv_mode;", "MPRV ignored")
m("FC36", "fyracore.v", "wire [2:0] ex_pmp_access_type = ctrl_isAmo           ? 3'b011 : // AMO: R+W", "wire [2:0] ex_pmp_access_type = ctrl_isAmo           ? 3'b001 : // AMO: R+W", "AMO checked for R only")
m("FC37", "fyracore.v", "wire fetch_can_deny = !priv_mode || pmp_any_locked;", "wire fetch_can_deny = !priv_mode;", "locked entries never deny an M-mode fetch")
m("FC38", "fyracore.v", "wire ex_csr_priv_fail = !priv_mode && (ex_csr_addr[9:8] != 2'b00);", "wire ex_csr_priv_fail = 1'b0;", "U-mode may access M CSRs")
m("FC39", "fyracore.v", "(ex_csr_writes && ex_csr_readonly) ||  // Write to read-only CSR", "1'b0 ||  // Write to read-only CSR", "writes to read-only CSRs accepted")
m("FC40", "fyracore.v", "ex_rs1 != 5'b0            // CSRRS/CSRRC write only if rs1/uimm != 0", "1'b1            // CSRRS/CSRRC write only if rs1/uimm != 0", "CSRRS/CSRRC with rs1=x0 write")
m("FC41", "fyracore.v", "(ifex_compressed && !csr_misa_c) ||", "1'b0 ||", "compressed instructions execute with misa.C=0")
m("FC42", "fyracore.v", "!csr_misa_c && ex_branch_target[1];", "!csr_misa_c && ex_branch_target[0];", "IALIGN=32 target check looks at bit 0")
m("FC43", "fyracore.v", "{alu_r[31:1], 1'b0} : alu_r;", "alu_r : alu_r;", "JALR does not clear bit 0")
m("FC44", "fyracore.v", "!wfi_has_enabled_irq;  // NOP when no sources enabled", "1'b0;  // NOP when no sources enabled", "WFI with mie=0 waits forever")
m("FC45", "fyracore.v", "!priv_mode &&\n                        csr_mstatus_tw;", "!priv_mode &&\n                        1'b1;", "U-mode WFI illegal even with TW=0")
m("FC46", "fyracore.v", "wire ex_bad_lr = ifex_valid && ctrl_isLR && (ex_rs2 != 5'b0);", "wire ex_bad_lr = 1'b0;", "LR.W with rs2 != 0 accepted")
m("FC47", "fyracore.v", "wire ex_is_mret   = ifex_valid && ctrl_isMret && ex_system_fields_ok && priv_mode &&", "wire ex_is_mret   = ifex_valid && ctrl_isMret && ex_system_fields_ok &&", "MRET executes in U-mode")
m("FC48", "fyracore.v", "wire ex_system_fields_ok = (ex_rd == 5'b0) && (ex_rs1 == 5'b0);", "wire ex_system_fields_ok = 1'b1;", "ECALL/EBREAK/MRET with rd/rs1 != 0 accepted")
m("FC50", "fyracore.v", "wire muldiv_have = muldiv_ready || muldiv_done;", "wire muldiv_have = muldiv_ready;", "M unit restarted on its done cycle (the 2e6718b bug)")
m("FC51", "fyracore.v", "wire wb_mem_stall = dmem_req && !dmem_ready;", "wire wb_mem_stall = 1'b0;", "data-memory wait ignored")
m("FC52", "fyracore.v", "wire if_mem_stall = imem_req && !imem_ready;", "wire if_mem_stall = 1'b0;", "fetch wait ignored")
m("FC53", "fyracore.v", "if (ex_trap && !stall)\n            next_pc = trap_target;", "if (ex_trap)\n            next_pc = trap_target;", "trap redirect on a stalled cycle")
m("FC54", "fyracore.v", "if (csr_trap_signal)\n                priv_mode <= 1'b1;", "if (1'b0)\n                priv_mode <= 1'b1;", "trap does not enter M-mode")
m("FC55", "fyracore.v", "assign rf_r2 = (ex_rs2 == 5'b0) ? 32'b0 : rf_b;", "assign rf_r2 = rf_b;", "x0 read on port 2 unmasked (only +RF_X shows it)")
m("FC56", "fyracore.v", "ex_ph    <= ex_rf_ok && !use_hazard;", "ex_ph    <= ex_rf_ok;", "use hazard does not hold EX")
m("FC57", "fyracore.v", "exwb_trap_cause <= 32'd6;  // Store/AMO address misaligned", "exwb_trap_cause <= 32'd4;  // Store/AMO address misaligned", "store misaligned reports cause 4")
m("FC58", "fyracore.v", "exwb_trap_cause <= 32'd7;  // Store/AMO access fault", "exwb_trap_cause <= 32'd5;  // Store/AMO access fault", "store access fault reports cause 5")
m("FC59", "fyracore.v", "exwb_trap_val   <= ex_ifetch_fault_lo ? ifex_pc : ex_pc_hi;", "exwb_trap_val   <= ifex_pc;", "upper-half fetch fault reports the start address")
m("FC60", "fyracore.v", "exwb_trap_val   <= 32'b0;\n                    // mepc: if interrupted instruction is WFI", "exwb_trap_val   <= ifex_pc;\n                    // mepc: if interrupted instruction is WFI", "interrupt writes the pc to mtval")
m("FC61", "fyracore.v", "wire irq_timer_pend    = timer_irq    & csr_mie[7]  & irq_global_en;", "wire irq_timer_pend    = timer_irq    & csr_mie[5]  & irq_global_en;", "timer interrupt enabled by mie bit 5")
m("FC62", "fyracore.v", "in_exec = in_win(a, PMA_ROM_BASE, PMA_ROM_TOP) || in_win(a, PMA_RAM_BASE, PMA_RAM_TOP);", "in_exec = 1'b1;", "fetch allowed from any address")
m("FC63", "fyracore.v", "in_win = (a >= base) && (a <= top);", "in_win = (a >= base) && (a < top);", "the last byte of every window unmapped")
m("FC67", "fyracore.v", "end else if (wb_mem_stall) begin", "end else if (1'b0) begin", "EX/WB not held across a memory wait")
m("FC69", "fyracore.v", "wire ex_bad_wfi = ifex_valid && (ifex_instr[31:25] == 7'b0001000) &&", "wire ex_bad_wfi = 1'b0 && (ifex_instr[31:25] == 7'b0001000) &&", "SRET and malformed WFI execute as NOPs")
m("FC70", "fyracore.v", "wire [31:0] ex_csr_wdata_src = ctrl_csrSrc ? {27'b0, ex_rs1} : ex_rs1_val; // zimm or rs1", "wire [31:0] ex_csr_wdata_src = ctrl_csrSrc ? {28'b0, ex_rs1[3:0]} : ex_rs1_val; // zimm or rs1", "zimm bit 4 lost")
m("FC71", "fyracore.v", "(ctrl_csrOp == 2'b11) ? (csr_rdata_eff & ~ex_csr_wdata_src): // CSRRC", "(ctrl_csrOp == 2'b11) ? (csr_rdata_eff & ex_csr_wdata_src): // CSRRC", "CSRRC keeps the bits it should clear")
m("FC72", "fyracore.v", "(ctrl_wbSel == 2'b10)  ? pc            :", "(ctrl_wbSel == 2'b10)  ? ifex_pc + 32'd4 :", "link address is pc+4 for compressed jumps too")
m('FC80', 'fyracore.v', "priv_mode <= 1'b1; // Boot in M-mode", "priv_mode <= (priv_mode === 1'bx) ? 1'b1 : priv_mode; // Boot in M-mode", 'a reset in U-mode stays in U-mode (power-up-only reset)')
m('FC81', 'fyracore.v', "            wfi_active        <= 1'b0;\n            // Reservation", "            wfi_active        <= (wfi_active === 1'bx) ? 1'b0 : wfi_active;\n            // Reservation", 'a reset during a WFI wait keeps waiting')
m('FC82', 'fyracore.v', "            reservation_valid <= 1'b0;\n            reservation_addr  <= 30'b0;", "            reservation_valid <= (reservation_valid === 1'bx) ? 1'b0 : reservation_valid;\n            reservation_addr  <= (^reservation_addr === 1'bx) ? 30'b0 : reservation_addr;", 'the LR reservation survives a reset (both registers, or an SC after reset fails on the address alone)')
m('FC83', 'fyracore.v', "            amo_phase      <= 1'b0;\n            wb_busy        <= 1'b0;", "            amo_phase      <= (amo_phase === 1'bx) ? 1'b0 : amo_phase;\n            wb_busy        <= (wb_busy === 1'bx) ? 1'b0 : wb_busy;", 'an AMO cut by a reset resumes after it')
m('FC84', 'fyracore.v', "            exwb_memWR      <= 1'b0;\n            exwb_memSize    <= 2'b0;", "            exwb_memWR      <= (exwb_memWR === 1'bx) ? 1'b0 : exwb_memWR;\n            exwb_memSize    <= 2'b0;", 'a store in WB is issued again after a reset')
m('FC85', 'fyracore.v', "            ifex_valid     <= 1'b0;\n            ex_rf_ok       <= 1'b0;", "            ifex_valid     <= (ifex_valid === 1'bx) ? 1'b0 : ifex_valid;\n            ex_rf_ok       <= 1'b0;", 'the instruction in EX at a reset executes after it')
m("FC86", "fyracore.v", "(ex_rd == 5'b0) && (ex_rs1 == 5'b0) && priv_mode;", "(ex_rd == 5'b0) && (ex_rs1 == 5'b0) && (priv_mode || !csr_mstatus_tw);", "U-mode WFI with TW=0 waits like an M-mode WFI (CPU ref 8.5: it is a NOP)")

# ── mem_ctrl.v / soc_bus.v / qspi_ctrl.v ─────────────────────────────────
m("MC01", "mem_ctrl.v", "wire        split     = i_addr[31] && (&i_addr[9:1]);", "wire        split     = i_addr[31] && (&i_addr[9:2]);", "split also at the page's second-last halfword")
m("MC02", "mem_ctrl.v", "wire        split     = i_addr[31] && (&i_addr[9:1]);", "wire        split     = i_addr[31] && (&i_addr[22:1]);", "split only at the PSRAM A/B boundary")
m("MC03", "mem_ctrl.v", "wire pick_d = d_req && !second;", "wire pick_d = d_req && !second && !i_req;", "fetch first")
m("MC04", "mem_ctrl.v", "wire pick_d = d_req && !second;", "wire pick_d = d_req;", "data request breaks into a split fetch")
m("MC05", "mem_ctrl.v", "wire [1:0] st_n_m1  = {d_be[0] & d_be[3], (d_be[0] & d_be[1]) | (d_be[2] & d_be[3])};", "wire [1:0] st_n_m1  = {d_be[0] & d_be[3], (d_be[0] & d_be[1])};", "upper-half store sends one byte")
m("MC06", "mem_ctrl.v", "wire [1:0] st_lane  = d_be[0] ? 2'd0 : d_be[1] ? 2'd1 : d_be[2] ? 2'd2 : 2'd3;", "wire [1:0] st_lane  = d_be[0] ? 2'd0 : d_be[1] ? 2'd1 : d_be[2] ? 2'd3 : 2'd2;", "store lanes 2 and 3 swapped")
m("MC07", "mem_ctrl.v", "wire chip_b = second ? next_page[13] : a23;", "wire chip_b = a23;", "split fetch's second half stays on PSRAM A")
m("MC08", "mem_ctrl.v", "assign i_ready = q_done && !gnt_d && (second || !split);", "assign i_ready = q_done && !gnt_d;", "split fetch completes after its first half")
m("SB01", "soc_bus.v", "assign d_ready = is_mem ? mem_ready : (uart_ready && gpio_ready);", "assign d_ready = is_mem ? mem_ready : uart_ready;", "GPIO back-pressure ignored")
m("SB02", "soc_bus.v", "assign gpio_sel   = d_req && is_io && (io_idx == 2'd1);", "assign gpio_sel   = d_req && is_io && (io_idx == 2'd2);", "GPIO decoded at the syscon slot")
m("SB03", "soc_bus.v", "assign clint_sel  = d_req && !is_mem && !d_addr[28];", "assign clint_sel  = d_req && !is_mem;", "IO stores also hit the CLINT")
m("QS01", "qspi_ctrl.v", ": ((3'b001 << cs_sel) & {2'b11, !we});", ": (3'b001 << cs_sel);", "a write may select the flash")
m("QS02", "qspi_ctrl.v", "default: io_sdr = 4'b1111;       // mode byte 0xFF, and idle", "default: io_sdr = 4'b1010;       // mode byte 0xFF, and idle", "flash mode byte 0xAA (continuous read)")
m("QS03", "qspi_ctrl.v", ":  (state == S_DATA &&  sck));", ":  (state == S_DATA && !sck));", "rd_late=0 samples on the wrong clock")
m("QS04", "qspi_ctrl.v", "cnt   <= t_we ? 3'd7 : psram ? 3'd3 : t_ddr ? 3'd6 : 3'd5;", "cnt   <= t_we ? 3'd7 : psram ? 3'd2 : t_ddr ? 3'd6 : 3'd5;", "PSRAM read with 3 wait cycles")
m("QS05", "qspi_ctrl.v", "3'd2:    cmd = 8'h99;", "3'd2:    cmd = 8'h98;", "start-up never resets the PSRAMs")
m("QS06", "qspi_ctrl.v", "ctl_oe <= 1'b1;\n            dq <= {dq[2:0], launch};", "ctl_oe <= 1'b1;\n            late <= rd_late;\n            dq <= {dq[2:0], launch};", "rd_late strap followed after reset")
m("QS07", "qspi_ctrl.v", "wire [2:0] wnib      = {~cnt[2:1], cnt[0]};", "wire [2:0] wnib      = {~cnt[2:1], ~cnt[0]};", "write nibbles low half first")
m("QS08", "qspi_ctrl.v", "S_CMD: if (init && step == 3'd4 && !again) begin", "S_CMD: if (1'b0) begin", "start-up step 4 sends 8 clocks, not 16")
m('QS09', 'qspi_ctrl.v', 'end else if (!init && strm && (!stream_en || mode_chg)) begin', 'end else if (!init && strm && (mode_chg)) begin', 'an idle open stream is not closed when stream_en falls (REVIEW-6a QX1)')
m('QS10', 'qspi_ctrl.v', "wire hit_top  = (a_hw == p - 23'd1);", "wire hit_top  = 1'b0;", 'the 2-byte top-up never recognised: a read at p-2 closes and reopens (QX2)')
m('QS11', 'qspi_ctrl.v', 'wire       mode_chg  = (t_ddr != ddr) || (t_ddr && t_cap != ddr_cap);', 'wire       mode_chg  = (t_ddr != ddr);', 'a DDR_CAP change with ddr = 1 does not close an open stream (QX3)')
m('QS12', 'qspi_ctrl.v', 'wire       mode_chg  = (t_ddr != ddr) || (t_ddr && t_cap != ddr_cap);', "wire       mode_chg  = 1'b0;", 'no QSPI_CFG change ever closes an open stream (QX4)')
m('QS13', 'qspi_ctrl.v', 't_ddr <= ddr && !t_we && !t_psram;\n                    t_cap <= ddr_cap;', 't_ddr <= t_ddr && !t_we && !t_psram;\n                    t_cap <= t_cap;', 'the new mode is never latched at the request (QX6; only same-clock change differs from idle-close)')
m('QS14', 'qspi_ctrl.v', 'if (streamable && !mode_chg && (hit_cont || hit_top)) begin', 'if (streamable && (hit_cont || hit_top)) begin', 'a continuation ignores a mode change on its own clock (QX7)')

# ── uart.v / gpio.v / tt_um ──────────────────────────────────────────────
m("UA01", "uart.v", "assign ready = !(thr_sel && !tx_idle);", "assign ready = 1'b1;", "no THR back-pressure")
m("UA02", "uart.v", "if (rx_bit == 4'd0 && rx_s)\n                        rx_busy <= 1'b0;               // glitch, not a start bit", "if (1'b0)\n                        rx_busy <= 1'b0;               // glitch, not a start bit", "start bit not re-checked at mid-bit")
m("UA03", "uart.v", "else if (rd_lsr)\n                oe <= 1'b0;", "else if (1'b0)\n                oe <= 1'b0;", "OE never cleared")
m("UA04", "uart.v", "rts_n <= !(!rx_busy && !dr);", "rts_n <= dr;", "RTS# asserted while a frame is being received")
m("UA05", "uart.v", "if (rst || wr_dll || wr_dlm) brg <= 16'd0;", "if (rst) brg <= 16'd0;", "divisor write does not restart the baud counter")
m("UA06", "uart.v", "wire [7:0] lsr = {1'b0, tx_idle, tx_idle, bi, 2'b00, oe, dr};", "wire [7:0] lsr = {1'b0, 1'b1, tx_idle, bi, 2'b00, oe, dr};", "LSR.TEMT always 1")
m("UA07", "uart.v", "(rx_s ? !rx_chk : rx_zero);", "(rx_s ? 1'b1 : rx_zero);", "frame after a framing error accepted")
m("UA08", "uart.v", "else if (rd_lsr)\n                bi <= 1'b0;", "else if (rd_lsr || (rx_mid && rx_busy && rx_bit == 4'd0))\n                bi <= 1'b0;", "BI cleared at the next start bit instead of by an LSR read (not sticky)")
m("GP01", "gpio.v", "wire req   = sel && we && be[0];", "wire req   = sel && we;", "writes without lane 0 stall and act too")
# GP02 (MOSI one bit early) and GP04 (DIV 3 runs at DIV 2) are retired: the DIV shifter they
# mutated was replaced by src/spi.v (WO-28). SPI01-SPI32 below cover the new logic.
# GP03 is back as a pin-assign mutant. The old form (OUT bits 5:4 stored) and "2'b00 -> out_r[5:4]"
# are equivalent, since out_r[5:4] is never written; bits 5:4 mirroring bits 7:6 is not.
m("GP03", "gpio.v", "assign out = {out_r[7:6], 2'b00, p_sck,", "assign out = {out_r[7:6], out_r[7:6], p_sck,", "OUT pins 5:4 mirror pins 7:6 (the pin assign must tie them to 0)")
m("GP05", "gpio.v", "in_s <= in_m;", "in_s <= in;", "one-flop input synchroniser")
m("TT01", "tt_um_alfadelta10010_alphaone_soc.v", "else        run <= !rst_sync[0];", "else        run <= 1'b1;", "reset released on the first edge")
m("TT02", "tt_um_alfadelta10010_alphaone_soc.v", "assign uio_oe  = {ctl_oe, ctl_oe, io_oe, io_oe, ctl_oe, io_oe, io_oe, ctl_oe};", "assign uio_oe  = {ctl_oe, ctl_oe, io_oe, io_oe, io_oe, io_oe, io_oe, ctl_oe};", "SCK's output enable follows the data pins")
# ── syscon.v
m("SY01", "syscon.v", "    wire       reboot  = fin & (wdata[15:0] == 16'h7777);\n    wire       halt    = fin & ((wdata[15:0] == 16'h5555) | (wdata[15:0] == 16'h3333));",
  "    wire       reboot  = fin & (wdata[15:0] == 16'h5555);\n    wire       halt    = fin & ((wdata[15:0] == 16'h7777) | (wdata[15:0] == 16'h3333));", "0x7777 powers off and 0x5555 reboots")
m("SY02", "syscon.v", "wire       fin     = wr & (idx == 3'd0) & (be[1:0] == 2'b11);", "wire       fin     = wr & (idx == 3'd0);", "FINISH ignores the lanes (sb 0x77 = 0x77777777 reboots)")
m("SY03", "syscon.v", "reboot  = fin & (wdata[15:0] == 16'h7777);", "reboot  = fin & (wdata[7:0] == 8'h77);", "reboot decided from status bits [7:0] only")
m("SY04", "syscon.v", "rq        <= reboot | fire | (rq & ~rq2);", "rq        <= reboot | fire;", "reboot holds the SoC one edge, not two")
m("SY05", "syscon.v", "rq2       <= rq & ~rq2;", "rq2       <= 1'b0;", "a reboot never ends (held like power-off)")
m("SY06", "syscon.v", "off       <= off | halt;", "off       <= halt;", "power-off not held (released like a one-edge reboot)")
m("SY07", "syscon.v", "halt    = fin & ((wdata[15:0] == 16'h5555) | (wdata[15:0] == 16'h3333));", "halt    = fin & (wdata[15:0] == 16'h5555);", "fail status 0x3333 ignored")
m("SY08", "syscon.v", "            if (w_mode) boot_mode <= wdata[7:0];", "            if (w_mode) boot_mode <= wdata[7:0];\n            else if (rq) boot_mode <= 8'h00;", "BOOT_MODE cleared by a reboot (as if on rst_soc)")
m("SY09", "syscon.v", "cause[1]  <= (cause[1] & ~(w_cause & wdata[1])) | reboot;", "cause[1]  <= (cause[1] & ~(w_cause & wdata[1]));", "RESET_CAUSE.SOFT not set by a reboot")
m("SY10", "syscon.v", "cause[0]  <= cause[0] & ~(w_cause & wdata[0]);", "cause[0]  <= w_cause ? wdata[0] : cause[0];", "RESET_CAUSE.PIN written, not write-1-to-clear")
m("SY11", "syscon.v", "cause     <= 3'b001;", "cause     <= 3'b000;", "RESET_CAUSE.PIN not set by the pin reset")
m("SY12", "syscon.v", "            strap_ns_q <= strap_no_stream;\n        end else begin", "            strap_ns_q <= strap_no_stream;\n        end else begin\n            if (rq | off) strap_q <= strap_rd_late;", "strap re-latched while a reboot / power-off holds the SoC")
m("SY13", "syscon.v", "assign rd_late = rst ? strap_rd_late : strap_q;", "assign rd_late = strap_rd_late;", "rd_late follows the strap pin always")
m("SY14", "syscon.v", "wire       wr      = sel & we & hit & ~rst_soc;", "wire       wr      = sel & we & hit;", "register writes accepted while the SoC is held")
m("SY15", "syscon.v", "wire       hit     = (addr[15:5] == 11'd0);", "wire       hit     = (addr[7:5] == 3'd0);", "register decode ignores offset bits [15:8] (aliases)")
m("SY16", "syscon.v", ": ~hit         ? 32'h0000_0000", ": ~hit         ? CHIP_ID", "unimplemented words read CHIP_ID")
m("SY17", "syscon.v", ": idx == 3'd3  ? CHIP_ID", ": idx == 3'd3  ? (CHIP_ID ^ 32'h1)", "CHIP_ID bit 0 flipped")
m("SY18", "syscon.v", ": idx == 3'd4  ? {30'b0, strap_ns_q, strap_q}", ": idx == 3'd4  ? {30'b0, strap_ns_q, strap_rd_late}", "STRAPS reads the live pin")
m("SY19", "syscon.v", "wire       w_mode  = wr & (idx == 3'd2) & be[0];", "wire       w_mode  = wr & (idx == 3'd2) & (|be);", "BOOT_MODE written by any lane")
m("SY20", "syscon.v", "assign rst_soc = rst | rq | off;", "assign rst_soc = rst | rq | off | (sel & we & (addr == 14'd0) & (wdata[15:0] == 16'h7777));", "rst_soc has a combinational term from the bus")
m("SY21", "syscon.v", "            rq        <= 1'b0;\n            rq2       <= 1'b0;\n            off       <= 1'b0;", "            rq        <= (rq === 1'b1);\n            rq2       <= (rq2 === 1'b1);\n            off       <= 1'b0;", "a pin reset does not end a reboot in progress: rq / rq2 hold their value through rst (=== turns the power-up X into 0, so only a hold already running survives)")
m('SY22', 'syscon.v', "wire       w_cfg   = wr & (idx == 3'd7) & be[0];", "wire       w_cfg   = wr & (idx == 3'd7);", 'QSPI_CFG written by any byte lane (SX1)')
m('SY23', 'syscon.v', 'cfg_stream <= ~ns_now;', "cfg_stream <= 1'b1;", 'QSPI_CFG.STREAM resets to 1 whatever the no-stream strap (SX2)')
m('SY24', 'syscon.v', 'wire       ns_now  = rst ? strap_no_stream : strap_ns_q;', 'wire       ns_now  = strap_no_stream;', 'the QSPI_CFG.STREAM reset follows the live no-stream pin, not the latched strap (SX3)')
# ── syscon.v (watchdog)
m("WD01", "syscon.v", "if (w_cr & wdata[0]) en <= 1'b1;", "if (w_cr) en <= wdata[0];", "watchdog EN clearable")
m("WD02", "syscon.v", "wire       kick    = wwr & (widx == 6'd3) & (wdata[7:0] == 8'h76);", "wire       kick    = wwr & (widx == 6'd3);", "any CRR value kicks")
m("WD03", "syscon.v", "tick & (cnt == 2'd2)", "tick & (cnt == 2'd1)", "fires one tick early")
m("WD04", "syscon.v", "wire       tap     = wdt_tap[top];", "wire       tap     = wdt_tap[top + 4'd1];", "tap bit off by one inside syscon")
m("WD05", "syscon.v", "        if (rst_soc) begin\n            en    <= 1'b0;", "        if (rst) begin\n            en    <= 1'b0;", "watchdog flops on rst, not rst_soc")
m("WD06", "syscon.v", "cause[2]  <= (cause[2] & ~(w_cause & wdata[2])) | fire;", "cause[2]  <= (cause[2] & ~(w_cause & wdata[2]));", "RESET_CAUSE.WDT never set")
m("WD07", "syscon.v", "wire       whit    = (addr[15:8] == 8'h01);", "wire       whit    = (addr[9:8] == 2'b01);", "watchdog window decoded on addr[9:8] (aliases)")
m("WD08", "syscon.v", "wire       wwr     = sel & we & whit & ~rst_soc & be[0];", "wire       wwr     = sel & we & whit & ~rst_soc;", "watchdog writes without lane 0 count")
m("WD09", "syscon.v", "if (~en | kick | w_torr) cnt <= 2'd0;", "if (kick | w_torr) cnt <= 2'd0;", "watchdog count runs while disabled")
m("WD10", "syscon.v", "tprev <= w_torr | tap;", "tprev <= tap;", "no tick suppression on a TORR write")
m("WD11", "syscon.v", "if (~en | kick | w_torr) cnt <= 2'd0;", "if (~en | kick) cnt <= 2'd0;", "a TORR write does not kick")
m("WD12", "syscon.v", "            top   <= 4'hF;", "            top   <= 4'h0;", "TORR resets to TOP 0")
m("WD13", "syscon.v", ": widx == 6'd61 ? 32'h0000_0040", ": widx == 6'd61 ? 32'h0000_0000", "COMP_PARAMS_1 reads 0")
m("WD14", "syscon.v", "cause[2]  <= (cause[2] & ~(w_cause & wdata[2])) | fire;", "cause[2]  <= rq ? 1'b0 : ((cause[2] & ~(w_cause & wdata[2])) | fire);", "RESET_CAUSE.WDT cleared by the reboot it causes (as if on rst_soc)")
m("WD15", "syscon.v", "rq        <= reboot | fire | (rq & ~rq2);", "rq        <= reboot | (rq & ~rq2);", "a watchdog expiry does not reboot (fire not ORed into the reboot request)")
m("WD16", "syscon.v", "(cnt == 2'd2) & ~rst_soc", "(cnt == 2'd2)", "SA-009 gate removed: the watchdog fires on the first edge of a FINISH / power-off hold (RESET_CAUSE 0x7 after a reboot, WDT set inside power-off)")
# SA-008: a kick or TORR write in the fire cycle must not stop the fire (the cnt reset is not part of fire)
m("SY-K1", "syscon.v", "wire       fire    = en & tick & (cnt == 2'd2) & ~rst_soc;", "wire       fire    = en & tick & (cnt == 2'd2) & ~rst_soc & ~kick;", "a kick in the fire cycle wins over the fire")
m("SY-K2", "syscon.v", "wire       fire    = en & tick & (cnt == 2'd2) & ~rst_soc;", "wire       fire    = en & tick & (cnt == 2'd2) & ~rst_soc & ~w_torr;", "a TORR write in the fire cycle wins over the fire")
# ── alphaone_soc.v (reset wiring)
m("AS01", "alphaone_soc.v", "    clint clint_inst (\n        .clk      (clk),\n        .rst      (rst_soc),", "    clint clint_inst (\n        .clk      (clk),\n        .rst      (rst),", "CLINT reset by the pin reset only")
m("AS02", "alphaone_soc.v", "    ) uart_inst (\n        .clk  (clk),\n        .rst  (rst_soc),", "    ) uart_inst (\n        .clk  (clk),\n        .rst  (rst),", "UART reset by the pin reset only")
m("AS03", "alphaone_soc.v", "    gpio gpio_inst (\n        .clk  (clk),\n        .rst  (rst_soc),", "    gpio gpio_inst (\n        .clk  (clk),\n        .rst  (rst),", "GPIO reset by the pin reset only")
m("AS04", "alphaone_soc.v", "    qspi_ctrl qspi (\n        .clk      (clk),\n        .rst      (rst_soc),", "    qspi_ctrl qspi (\n        .clk      (clk),\n        .rst      (rst),", "QSPI engine reset by the pin reset only")
m("AS05", "alphaone_soc.v", "        .rd_late  (qspi_late),", "        .rd_late  (qspi_rd_late),", "QSPI engine samples the live strap pin")
m("AS06", "alphaone_soc.v", "    mem_ctrl memc (\n        .clk        (clk),\n        .rst        (rst_soc),", "    mem_ctrl memc (\n        .clk        (clk),\n        .rst        (rst),", "memory controller reset by the pin reset only")
m("AS07", "alphaone_soc.v", "        .wdt_tap      (mtime[29:14])", "        .wdt_tap      (mtime[28:13])", "watchdog tap from mtime[28:13] (twice as fast)")
m("AS08", "alphaone_soc.v", "    ) cpu (\n        .clk         (clk),\n        .rst         (rst_soc),", "    ) cpu (\n        .clk         (clk),\n        .rst         (rst),", "the core on the pin reset only (a reboot does not restart it)")

# ── fetch word reuse (WO-27): if_kbuf / if_kv in fyracore.v ──────────────
# FR07, FR08 and FR13 change nothing a Spike-compared trace can show (the
# bench's if_kv checks kill them); FR09 is killed by fr_window_end under
# NOTREADY_DATA=2, FR12 by fr_reset (and the core_fetch proof). FR14 is
# equivalent. Campaign 2026-10-30 (sandbox, unit+dir+soc, plus formal here):
# 13/14 killed, none by fr_misa under +RF_X.
KV_LOAD = "                if_kv          <= !if_hit && if_exec && if_compressed &&\n                                  (if_fetched[17:16] != 2'b11);"
m("FR01", "fyracore.v", "if_kv          <= if_kv && !flush;", "if_kv          <= if_kv;",
  "if_kv survives a flush: a taken branch / trap / MRET issues the stale kept halfword")
m("FR02", "fyracore.v", "if_kv          <= if_kv && !flush;", "if_kv          <= if_kv && !(flush && !irq_inject);",
  "if_kv survives an interrupt injection: the handler's first instruction is the kept halfword")
m("FR03", "fyracore.v", KV_LOAD,
  "                if_kv          <= !if_hit && if_exec && if_compressed;",
  "kept even when the halfword starts a 32-bit instruction: its upper half is never fetched")
m("FR04", "fyracore.v", KV_LOAD,
  "                if_kv          <= !if_hit && if_exec &&\n                                  (if_fetched[17:16] != 2'b11);",
  "if_kv set after a 32-bit fetch too: the upper half of the instruction is issued as the next one")
m("FR05", "fyracore.v", KV_LOAD,
  "                if_kv          <= if_exec && if_compressed &&\n                                  (if_fetched[17:16] != 2'b11);",
  "a hit does not consume if_kv: the same halfword is issued again, pc running on")
m("FR06", "fyracore.v", "if_kbuf <= imem_rdata[31:16];", "if_kbuf <= imem_rdata[15:0];",
  "the lower halfword is kept: C2 is replaced by C1")
m("FR07", "fyracore.v", "assign imem_req  = if_exec && !ex_nofetch && !if_hit;", "assign imem_req  = if_exec && !ex_nofetch;",
  "a fetch is requested with the instruction in hand (functionally equivalent, the hit wins; the bench's no-fetch check kills it)")
m("FR08", "fyracore.v", "if_kv          <= if_kv && !flush;", "if_kv          <= 1'b0;",
  "if_kv cleared behind a not-taken branch too (perf only; the bench's if_kv shadow kills it)")
m("FR09", "fyracore.v", "wire [31:0] if_fetched    = if_word & {32{if_exec}};",
  "wire [31:0] if_fetched    = {imem_rdata[31:16] & {16{if_exec}}, if_hit ? if_kbuf : (imem_rdata[15:0] & {16{if_exec}})};",
  "mux behind the window mask (a kept halfword outside the window is no longer forced to 0; fr_window_end kills it with garbage on the idle port)")
m("FR10", "fyracore.v", "        if (imem_req && imem_ready)\n            if_kbuf <= imem_rdata[31:16];",
  "        if (imem_ready)\n            if_kbuf <= imem_rdata[31:16];",
  "if_kbuf captured on ready alone: overwritten with the port's idle data while in use (needs NOTREADY_DATA)")
m("FR11", "fyracore.v", "ifex_raw16     <= if_fetched[15:0];", "ifex_raw16     <= imem_rdata[15:0];",
  "the trace / mtval 16 bits come from the port, not from the kept halfword, on a hit")
m("FR12", "fyracore.v", "            if_kv             <= 1'b0;\n        end else begin",
  "            if_kv             <= (if_kv === 1'bx) ? 1'b0 : if_kv;\n        end else begin",
  "if_kv survives a reset (a mid-run reset issues a halfword of the old stream)")
m("FR13", "fyracore.v", "            if (stall) begin\n                // Hold IF/EX on stall.",
  "            if (stall) begin\n                if_kv <= if_kv && !flush;\n                // Hold IF/EX on stall.",
  "if_kv cleared by a flush on a stalled cycle too (perf only: pc holds, the hit is lost; the if_kv shadow kills it)")
m("FR14", "fyracore.v", "if_kv          <= if_kv && !flush;", "if_kv          <= if_kv && !(flush && !ex_is_fencei && !ex_pmp_csr_wr);",
  "FENCE.I and a PMP write do not clear if_kv (equivalent: if_kv is set only behind a compressed instruction, and the compressed decoder turns every illegal encoding into a NOP, so no compressed form decodes as FENCE.I or a CSR write, with misa.C set or clear)")

# ── spi.v / gpio.v (WO-29 SPI01-SPI32)
m('SPI01', 'spi.v', 'wire [7:0] rx_in = {sr[6:0], miso};', 'reg miso_a;\n    always @(posedge clk) if (st == B && cc == baud) miso_a <= miso;\n    wire [7:0] rx_in = {sr[6:0], miso_a};', 'MISO taken at the A->B edge (the pin one clock after it), the classic point; equivalent at BAUD 0')
m('SPI02', 'gpio.v', '.miso    (in_m[1]),', '.miso    (in[1]),', "MISO from the raw pin (no synchroniser flop): option B's point without guards; survives every delay-based test")
m('SPI03', 'spi.v', 'if (en) sck_r <= ~a_lvl;', 'if (en) begin sck_r <= ~a_lvl; mosi_r <= sr[6]; end', 'MOSI changes at the A->B edge as well as at the launch')
m('SPI04a', 'spi.v', 'bb <= sr;                         // TXDATA then reads the last RX byte\n                sr <= bb;\n', 'sr <= bb;\n', 'an IDLE LOAD does not write sr into bb; invisible to the driver loop')
m('SPI04b', 'spi.v', 'bb <= rx_in;', '', 'a back-to-back LOAD does not write the RX byte into bb')
m('SPI05', 'gpio.v', 'wire stall = (addr == S_TX) ? !s_txr : !s_txe;', "wire stall = (addr == S_TX) ? 1'b0 : !s_txe;", 'TXDATA accepted while the holding register is full (overwrite); driver-equivalent')
m('SPI06', 'gpio.v', 'wire stall = (addr == S_TX) ? !s_txr : !s_txe;', "wire stall = (addr == S_TX) ? !s_txr : (addr == S_OUT) ? 1'b0 : !s_txe;", 'OUT write not stalled while busy')
m('SPI07', 'gpio.v', 'wire stall = (addr == S_TX) ? !s_txr : !s_txe;', "wire stall = (addr == S_TX) ? !s_txr : (addr == S_CON || addr == S_BAUD) ? 1'b0 : !s_txe;", 'CONTROL and BAUD writes accepted mid-byte')
m('SPI08', 'spi.v', 'if (en) sck_r <= ~a_lvl;\n                cc <= baud;', "if (en) sck_r <= ~a_lvl;\n                cc <= (baud == 8'd0) ? 8'd0 : baud - 8'd1;", 'the B phase lasts BAUD clocks (off by one; BAUD 0 unchanged)')
m('SPI09', 'spi.v', '                if (en) sck_r <= wdata[1];\n', '', 'a CONTROL write with EN = 1 does not set SCK to the new CPOL')
m('SPI10', 'spi.v', "bc  <= 3'd7;\n                cc  <= baud;\n                st  <= A;\n            end\n            A:", "bc  <= 3'd6;\n                cc  <= baud;\n                st  <= A;\n            end\n            A:", 'bc loaded with 6 at an idle LOAD (7-bit first byte)')
m('SPI11', 'spi.v', 'st <= B;', "st <= (bc == 3'd0) ? IDLE : B;", 'the last B phase is dropped (IDLE entered at the last A->B edge)')
m('SPI12', 'gpio.v', "assign out = {out_r[7:6], 2'b00, p_sck, out_r[2], p_mosi, out_r[0]};", "assign out = {out_r[7:6], 2'b00, (p_sck & spi_en) | (p_sck & ~spi_en), out_r[2], p_mosi, out_r[0]};", 'out[3] through an AND/OR of the flop (same settled value; test-wrapper sees two changes in one time step, and the structural F12 check sees the gate)')
m('SPI13', 'spi.v', 'if (wr_out && !en) begin', 'if (wr_out) begin', 'OUT writes to bits 1 and 3 reach the pins while EN = 1')
m('SPI14', 'gpio.v', "out_r  <= 8'h81;", "out_r  <= 8'h01;", 'OUT resets to 0x09 (SD CS# low)')
m('SPI15', 'gpio.v', 'assign ready = !(req && stall);', 'assign ready = !(we && be[0] && stall);', 'sel dropped from the stall')
m('SPI16', 'gpio.v', "(addr == S_RX)   ? {24'b0, s_rx} :", "(addr == S_RX)   ? {24'b0, s_tx} :", 'RXDATA returns bb')
m('SPI17', 'spi.v', 'wire a_lvl   = cpol ^ cpha;', 'wire a_lvl   = cpol;', 'CPHA ignored (A level = CPOL)')
m('SPI18', 'spi.v', 'assign txe     = (st == IDLE) && !bba;', 'assign txe     = (st == IDLE);', "TXE without !bba (tiny_spi's one-clock race)")
m('SPI19', 'gpio.v', "(addr == S_ST)   ? {30'b0, s_txr, s_txe} :", "(addr == S_ST)   ? {30'b0, s_txe, s_txr} :", 'STATUS bits swapped')
m('SPI20', 'spi.v', "            sr     <= 8'h00;\n            bb     <= 8'h00;\n", '', 'sr and bb not reset')
m('SPI21', 'gpio.v', '.miso    (in_m[1]),', '.miso    (in_s[1]),', 'MISO through the second synchroniser flop (one clock later than the right point)')
m('SPI22', 'spi.v', 'end else if (bba) begin            // next byte, no gap', "end else if (bba && 1'b0) begin            // next byte, no gap", 'a gap clock (IDLE) before a back-to-back load')
m('SPI23', 'spi.v', "bba <= 1'b0;\n                bc  <= 3'd7;\n                cc  <= baud;\n                st  <= A;\n            end\n            A:", "bc  <= 3'd7;\n                cc  <= baud;\n                st  <= A;\n            end\n            A:", 'bba not cleared at an idle LOAD (the byte repeats)')
m('SPI24', 'spi.v', "bc  <= 3'd7;\n                cc  <= baud;\n                st  <= A;\n            end\n            A:", "bc  <= 3'd7;\n                cc  <= baud + 8'd1;\n                st  <= A;\n            end\n            A:", "the first A phase of an idle LOAD one clock long (the byte one clock late; closest single replace to 'first launch at w+2')")
m('SPI25', 'gpio.v', '.en      (spi_en),', ".en      (1'b1),", 'EN gating dropped (the engine always drives the pins)')
m('SPI26', 'spi.v', '            if (wr_en) sck_r <= cpol;\n', '', 'an EN 0->1 write does not set SCK to CPOL')
m('SPI27', 'spi.v', "cpol   <= 1'b1;       // mode 3: SCK idles high, the level it resets to\n            cpha   <= 1'b1;", "cpol   <= 1'b0;\n            cpha   <= 1'b0;", 'CONTROL resets to 0')
m('SPI28', 'spi.v', "baud   <= 8'hFF;", "baud   <= 8'h00;", 'BAUD resets to 0')
m('SPI29', 'gpio.v', '.wr_tx   (wr && addr == S_TX),', '.wr_tx   (sel && we && addr == S_TX),', 'a TXDATA write without be[0] acts')
m('SPI30', 'gpio.v', "(addr == S_BAUD) ? {24'b0, s_baud} :", "(addr == S_BAUD || addr == 4'd13) ? {24'b0, s_baud} :", 'slot 0x34 decodes as BAUD')
m('SPI31', 'spi.v', 'wire [7:0] rx_in = {sr[6:0], miso};', 'wire [7:0] rx_in = {miso, sr[7:1]};', 'RX shifted in at the top (LSB-first data)')
m('SPI32', 'spi.v', 'bb <= sr;                         // TXDATA then reads the last RX byte\n                sr <= bb;\n                if (en) begin mosi_r <= bb[7];', 'bb <= sr;                         // TXDATA then reads the last RX byte\n                sr <= bb;\n                if (en) begin mosi_r <= bb[6];', 'MOSI at an idle LOAD from bb[6]')
