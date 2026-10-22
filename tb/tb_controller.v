`timescale 1ns / 1ps
// controller (src/controller.v) over all 2^17 values of {opcode, funct3,
// funct7} -- everything it sees -- against a model written from the ISA:
//
//   * which encodings are legal: RV32I (Unpriv ch. 2), M, A (.W only), Zicsr,
//     Zifencei, with FyraCore's split of the SYSTEM funct3=000 family (the
//     controller accepts funct7 0000000 / 0011000 / 0001000 and the pipeline
//     checks the remaining fields, CPU reference 8.2). For OP-IMM other than
//     the shifts funct7 is immediate bits and must not matter;
//   * for every legal encoding, every output whose meaning the interfaces
//     define: regWR, memRD/memWR, memSize (00 b / 01 h / 10 w) and
//     memUnsigned, wbSel (00 ALU, 01 memory, 10 link, 11 CSR -- controller.v
//     ports), aluSrc1 (0 rs1, 1 pc) and aluSrc2 (0 imm, 1 rs2), aluOp (the
//     ALU codes alu.v documents: ADD 00000, SUB 01000, SLT 00010, SLTU 00011,
//     XOR 00100, OR 00110, AND 00111; the shifts muldiv.v and fyracore take,
//     SLL 00001, SRL 00101, SRA 01101; M ops {10, funct3}, muldiv.v's op
//     table), doBranch/doJump, csrOp (01 RW, 10 RS, 11 RC) and csrSrc (1 for
//     the immediate forms), amoOp = funct5, and the is* flags, which must be
//     0 wherever the class does not set them;
//   * for every illegal encoding, illegal = 1 and no memory access requested
//     (memRD, memWR, isAmo, isLR, isSC all 0): an illegal instruction must
//     not start an access an address exception could come from.
//
// It keeps the three properties fyracore's pipeline control rests on (see
// the sweep at the end). Prints PASS/FAIL with the number of checks.
module tb_controller;
    reg  [6:0] opcode, funct7;
    reg  [2:0] funct3;
    wire       regWR, memRD, memWR, aluSrc1, aluSrc2;
    wire [4:0] aluOp;
    wire [1:0] memSize, wbSel, csrOp;
    wire       memUnsigned, doBranch, doJump, csrSrc;
    wire       isAmo, isLR, isSC, isEcall, isEbreak, isMret, isFence, isFenceI, illegal;
    wire       isMulDiv;
    wire [4:0] amoOp;
    // As fyracore derives them: a shift runs in muldiv like an M instruction.
    wire       is_shift = !aluOp[4] && (aluOp[1:0] == 2'b01);
    wire       is_iter  = isMulDiv || is_shift;

    controller uut(
        .opcode(opcode), .funct3(funct3), .funct7(funct7),
        .regWR(regWR), .aluOp(aluOp), .aluSrc1(aluSrc1), .aluSrc2(aluSrc2),
        .memRD(memRD), .memWR(memWR), .memSize(memSize), .memUnsigned(memUnsigned),
        .wbSel(wbSel), .doBranch(doBranch), .doJump(doJump),
        .csrOp(csrOp), .csrSrc(csrSrc),
        .isAmo(isAmo), .isLR(isLR), .isSC(isSC), .amoOp(amoOp),
        .isEcall(isEcall), .isEbreak(isEbreak), .isMret(isMret),
        .isFence(isFence), .isFenceI(isFenceI), .isMulDiv(isMulDiv), .illegal(illegal)
    );

    integer checks = 0, fails = 0, sweep, n_legal = 0, n_illegal = 0;
    integer cls_seen [0:15];

    // The model's view of one encoding. x in an expected field = don't care.
    reg       e_legal, e_regWR, e_memRD, e_memWR, e_aluSrc1, e_aluSrc2, e_memUnsigned;
    reg       e_doBranch, e_doJump, e_csrSrc, e_isAmo, e_isLR, e_isSC, e_isEcall, e_isEbreak;
    reg       e_isMret, e_isFence, e_isFenceI, e_isMulDiv;
    reg [4:0] e_aluOp, e_amoOp;
    reg [1:0] e_memSize, e_wbSel, e_csrOp;
    integer   cls;

    localparam C_OP = 0, C_OPIMM = 1, C_LOAD = 2, C_STORE = 3, C_BRANCH = 4, C_LUI = 5,
               C_AUIPC = 6, C_JAL = 7, C_JALR = 8, C_CSR = 9, C_SYS = 10, C_FENCE = 11,
               C_AMO = 12, C_LR = 13, C_SC = 14, C_ILL = 15;

    task model;
        reg [4:0] f5;
        begin
            f5 = funct7[6:2];
            e_legal = 1; e_regWR = 0; e_memRD = 0; e_memWR = 0;
            e_aluSrc1 = 1'bx; e_aluSrc2 = 1'bx; e_aluOp = 5'bx;
            e_memSize = 2'bx; e_memUnsigned = 1'bx; e_wbSel = 2'bx;
            e_doBranch = 0; e_doJump = 0; e_csrOp = 2'b00; e_csrSrc = 1'bx;
            e_isAmo = 0; e_isLR = 0; e_isSC = 0; e_amoOp = 5'bx;
            e_isEcall = 0; e_isEbreak = 0; e_isMret = 0; e_isFence = 0; e_isFenceI = 0; e_isMulDiv = 0;
            cls = C_ILL;
            case (opcode)
                7'b0110011: begin                                   // OP
                    cls = C_OP;
                    e_regWR = 1; e_wbSel = 2'b00; e_aluSrc1 = 0; e_aluSrc2 = 1;
                    if (funct7 == 7'b0000000) e_aluOp = {2'b00, funct3};
                    else if (funct7 == 7'b0100000 && (funct3 == 3'b000 || funct3 == 3'b101))
                        e_aluOp = {2'b01, funct3};                  // SUB, SRA
                    else if (funct7 == 7'b0000001) begin e_aluOp = {2'b10, funct3}; e_isMulDiv = 1; end
                    else e_legal = 0;
                end
                7'b0010011: begin                                   // OP-IMM
                    cls = C_OPIMM;
                    e_regWR = 1; e_wbSel = 2'b00; e_aluSrc1 = 0; e_aluSrc2 = 0;
                    case (funct3)
                        3'b001: if (funct7 == 7'b0000000) e_aluOp = 5'b00001; else e_legal = 0;
                        3'b101: if (funct7 == 7'b0000000) e_aluOp = 5'b00101;
                                else if (funct7 == 7'b0100000) e_aluOp = 5'b01101;
                                else e_legal = 0;
                        default: e_aluOp = {2'b00, funct3};         // funct7 is immediate bits
                    endcase
                end
                7'b0000011: begin                                   // LOAD
                    cls = C_LOAD;
                    if (funct3 == 3'b011 || funct3 == 3'b110 || funct3 == 3'b111) e_legal = 0;
                    else begin
                        e_regWR = 1; e_memRD = 1; e_wbSel = 2'b01; e_aluOp = 5'b00000;
                        e_aluSrc1 = 0; e_aluSrc2 = 0; e_memSize = funct3[1:0]; e_memUnsigned = funct3[2];
                    end
                end
                7'b0100011: begin                                   // STORE
                    cls = C_STORE;
                    if (funct3[2] || funct3 == 3'b011) e_legal = 0;
                    else begin
                        e_memWR = 1; e_aluOp = 5'b00000; e_aluSrc1 = 0; e_aluSrc2 = 0;
                        e_memSize = funct3[1:0];
                    end
                end
                7'b1100011: begin                                   // BRANCH
                    cls = C_BRANCH;
                    if (funct3 == 3'b010 || funct3 == 3'b011) e_legal = 0;
                    else begin e_doBranch = 1; e_aluSrc1 = 1; e_aluSrc2 = 0; e_aluOp = 5'b00000; end
                end
                7'b0110111: begin cls = C_LUI;   e_regWR = 1; e_wbSel = 2'b00; e_aluOp = 5'b00000; e_aluSrc1 = 0; e_aluSrc2 = 0; end
                7'b0010111: begin cls = C_AUIPC; e_regWR = 1; e_wbSel = 2'b00; e_aluOp = 5'b00000; e_aluSrc1 = 1; e_aluSrc2 = 0; end
                7'b1101111: begin cls = C_JAL;   e_regWR = 1; e_wbSel = 2'b10; e_aluOp = 5'b00000; e_aluSrc1 = 1; e_aluSrc2 = 0; e_doJump = 1; end
                7'b1100111: begin                                   // JALR
                    cls = C_JALR;
                    if (funct3 != 3'b000) e_legal = 0;
                    else begin e_regWR = 1; e_wbSel = 2'b10; e_aluOp = 5'b00000; e_aluSrc1 = 0; e_aluSrc2 = 0; e_doJump = 1; end
                end
                7'b1110011: begin                                   // SYSTEM
                    if (funct3 == 3'b000) begin
                        cls = C_SYS;
                        if (funct7 == 7'b0000000) begin e_isEcall = 1; e_isEbreak = 1; end
                        else if (funct7 == 7'b0011000) e_isMret = 1;
                        else if (funct7 == 7'b0001000) ;            // WFI family: pipeline decides
                        else e_legal = 0;
                    end else if (funct3 == 3'b100) begin cls = C_SYS; e_legal = 0; end
                    else begin
                        cls = C_CSR;
                        e_regWR = 1; e_wbSel = 2'b11; e_csrOp = funct3[1:0]; e_csrSrc = funct3[2];
                    end
                end
                7'b0001111: begin                                   // MISC-MEM
                    cls = C_FENCE;
                    if (funct3 == 3'b000) e_isFence = 1;
                    else if (funct3 == 3'b001) e_isFenceI = 1;
                    else e_legal = 0;
                end
                7'b0101111: begin                                   // AMO
                    cls = C_AMO;
                    if (funct3 != 3'b010) e_legal = 0;
                    else begin
                        e_aluOp = 5'b00000; e_aluSrc1 = 0; e_aluSrc2 = 0; e_memSize = 2'b10; e_amoOp = f5;
                        case (f5)
                            5'b00010: begin cls = C_LR; e_isLR = 1; e_regWR = 1; e_memRD = 1; e_wbSel = 2'b01; end
                            5'b00011: begin cls = C_SC; e_isSC = 1; e_regWR = 1; e_memWR = 1; e_wbSel = 2'b00; end
                            5'b00001, 5'b00000, 5'b00100, 5'b01100, 5'b01000,
                            5'b10000, 5'b10100, 5'b11000, 5'b11100:
                                begin e_isAmo = 1; e_regWR = 1; e_memRD = 1; e_memWR = 1; e_wbSel = 2'b01; end
                            default: e_legal = 0;
                        endcase
                    end
                end
                default: e_legal = 0;
            endcase
        end
    endtask

    // got against want; a want with an x bit is not checked.
    task automatic chk(input [8*12-1:0] what, input [4:0] got, input [4:0] want);
        begin
            if (^want !== 1'bx) begin
                checks = checks + 1;
                if (got !== want) begin
                    fails = fails + 1;
                    if (fails <= 25)
                        $display("FAIL %0s: opcode=%07b funct3=%03b funct7=%07b got %b want %b",
                                 what, opcode, funct3, funct7, got, want);
                end
            end
        end
    endtask

    integer k;
    initial begin
        $display("=== Controller Testbench (all 2^17 inputs vs ISA model) ===");
        for (k = 0; k < 16; k = k + 1) cls_seen[k] = 0;
        for (sweep = 0; sweep < (1 << 17); sweep = sweep + 1) begin
            {opcode, funct3, funct7} = sweep[16:0];
            #1;
            model;
            chk("illegal", illegal, !e_legal);
            if (e_legal) begin
                n_legal = n_legal + 1;
                cls_seen[cls] = cls_seen[cls] + 1;
                chk("regWR", regWR, e_regWR);       chk("memRD", memRD, e_memRD);
                chk("memWR", memWR, e_memWR);       chk("aluSrc1", aluSrc1, e_aluSrc1);
                chk("aluSrc2", aluSrc2, e_aluSrc2); chk("aluOp", aluOp, e_aluOp);
                chk("memSize", memSize, e_memSize); chk("memUnsigned", memUnsigned, e_memUnsigned);
                chk("wbSel", wbSel, e_wbSel);       chk("doBranch", doBranch, e_doBranch);
                chk("doJump", doJump, e_doJump);    chk("csrOp", csrOp, e_csrOp);
                chk("csrSrc", csrSrc, e_csrSrc);    chk("isAmo", isAmo, e_isAmo);
                chk("isLR", isLR, e_isLR);          chk("isSC", isSC, e_isSC);
                chk("amoOp", amoOp, e_amoOp);       chk("isEcall", isEcall, e_isEcall);
                chk("isEbreak", isEbreak, e_isEbreak); chk("isMret", isMret, e_isMret);
                chk("isFence", isFence, e_isFence); chk("isFenceI", isFenceI, e_isFenceI);
                chk("isMulDiv", isMulDiv, e_isMulDiv);
            end else begin
                n_illegal = n_illegal + 1;
                chk("ill:memRD", memRD, 1'b0); chk("ill:memWR", memWR, 1'b0);
                chk("ill:isAmo", isAmo, 1'b0); chk("ill:isLR", isLR, 1'b0);
                chk("ill:isSC", isSC, 1'b0);
            end

            // The properties fyracore's pipeline control is built on:
            //  - An M instruction or a shift makes no memory access and no
            //    branch or jump, and is no SYSTEM, CSR, LR or FENCE
            //    instruction, so of the decode causes only the controller's
            //    own `illegal` is left for it (ex_trap_iter in fyracore.v).
            //  - Whatever writes memory data to rd (wbSel 01 with regWR) is a
            //    read access (memRD): a statement of what wbSel 01 means.
            checks = checks + 3;
            if (is_iter && (memRD || memWR || isAmo || isLR || isSC || doBranch || doJump)) begin
                fails = fails + 1;
                if (fails <= 25) $display("FAIL iterative op with a memory access or a jump: opcode=%07b funct3=%03b funct7=%07b", opcode, funct3, funct7);
            end
            if (is_iter && (isEcall || isEbreak || isMret || isLR || isFence || isFenceI ||
                            csrOp != 2'b00 || opcode == 7'b1110011)) begin
                fails = fails + 1;
                if (fails <= 25) $display("FAIL iterative op that is a SYSTEM, CSR, LR or FENCE instruction: opcode=%07b funct3=%03b funct7=%07b", opcode, funct3, funct7);
            end
            if (regWR && wbSel == 2'b01 && !memRD) begin
                fails = fails + 1;
                if (fails <= 25) $display("FAIL memory data written to rd without memRD: opcode=%07b funct3=%03b funct7=%07b", opcode, funct3, funct7);
            end
        end
        // Every class the model knows was met legal at least once.
        for (k = 0; k < 15; k = k + 1)
            if (cls_seen[k] == 0) begin
                fails = fails + 1;
                $display("FAIL coverage: instruction class %0d never seen legal", k);
            end
        if (n_legal + n_illegal != (1 << 17)) begin
            fails = fails + 1;
            $display("FAIL walked %0d inputs, not %0d", n_legal + n_illegal, 1 << 17);
        end
        $display("controller: %0d legal, %0d illegal inputs", n_legal, n_illegal);
        if (fails == 0) $display("PASS tb_controller (%0d checks)", checks);
        else            $display("FAIL tb_controller: %0d failures, %0d checks", fails, checks);
        $finish;
    end
endmodule
