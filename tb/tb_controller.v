`timescale 1ns / 1ps
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
    integer pass_count = 0, fail_count = 0;
    integer sweep, sweep_bad;
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

    task check_rtype(input [4:0] exp_aluOp, input exp_illegal, input [159:0] name);
        begin
            #1;
            if (regWR === 1'b1 && aluSrc1 === 1'b0 && aluSrc2 === 1'b1 &&
                wbSel === 2'b00 && aluOp === exp_aluOp && illegal === exp_illegal &&
                memRD === 1'b0 && memWR === 1'b0) begin
                pass_count = pass_count + 1;
            end else begin
                fail_count = fail_count + 1;
                $display("FAIL: %0s | aluOp=%05b(exp=%05b) regWR=%b src1=%b src2=%b wb=%02b ill=%b",
                         name, aluOp, exp_aluOp, regWR, aluSrc1, aluSrc2, wbSel, illegal);
            end
        end
    endtask

    task check_signals(
        input exp_regWR, input exp_memRD, input exp_memWR,
        input exp_doBranch, input exp_doJump, input exp_illegal,
        input [1:0] exp_wbSel, input [159:0] name
    );
        begin
            #1;
            if (regWR === exp_regWR && memRD === exp_memRD && memWR === exp_memWR &&
                doBranch === exp_doBranch && doJump === exp_doJump &&
                illegal === exp_illegal && wbSel === exp_wbSel) begin
                pass_count = pass_count + 1;
            end else begin
                fail_count = fail_count + 1;
                $display("FAIL: %0s | rWR=%b mRD=%b mWR=%b br=%b jmp=%b ill=%b wb=%02b",
                         name, regWR, memRD, memWR, doBranch, doJump, illegal, wbSel);
            end
        end
    endtask

    initial begin
        $dumpfile("tb_controller.vcd");
        $dumpvars(0, tb_controller);
        $display("=== Controller Testbench ===");

        // ===== R-type (0110011) =====
        opcode = 7'b0110011;
        funct7 = 7'b0000000; funct3 = 3'b000; check_rtype(5'b00000, 1'b0, "R: ADD");
        funct7 = 7'b0100000; funct3 = 3'b000; check_rtype(5'b01000, 1'b0, "R: SUB");
        funct7 = 7'b0000000; funct3 = 3'b001; check_rtype(5'b00001, 1'b0, "R: SLL");
        funct7 = 7'b0000000; funct3 = 3'b010; check_rtype(5'b00010, 1'b0, "R: SLT");
        funct7 = 7'b0000000; funct3 = 3'b011; check_rtype(5'b00011, 1'b0, "R: SLTU");
        funct7 = 7'b0000000; funct3 = 3'b100; check_rtype(5'b00100, 1'b0, "R: XOR");
        funct7 = 7'b0000000; funct3 = 3'b101; check_rtype(5'b00101, 1'b0, "R: SRL");
        funct7 = 7'b0100000; funct3 = 3'b101; check_rtype(5'b01101, 1'b0, "R: SRA");
        funct7 = 7'b0000000; funct3 = 3'b110; check_rtype(5'b00110, 1'b0, "R: OR");
        funct7 = 7'b0000000; funct3 = 3'b111; check_rtype(5'b00111, 1'b0, "R: AND");
        // M-extension
        funct7 = 7'b0000001; funct3 = 3'b000; check_rtype(5'b10000, 1'b0, "R: MUL");
        funct7 = 7'b0000001; funct3 = 3'b001; check_rtype(5'b10001, 1'b0, "R: MULH");
        funct7 = 7'b0000001; funct3 = 3'b010; check_rtype(5'b10010, 1'b0, "R: MULHSU");
        funct7 = 7'b0000001; funct3 = 3'b011; check_rtype(5'b10011, 1'b0, "R: MULHU");
        funct7 = 7'b0000001; funct3 = 3'b100; check_rtype(5'b10100, 1'b0, "R: DIV");
        funct7 = 7'b0000001; funct3 = 3'b101; check_rtype(5'b10101, 1'b0, "R: DIVU");
        funct7 = 7'b0000001; funct3 = 3'b110; check_rtype(5'b10110, 1'b0, "R: REM");
        funct7 = 7'b0000001; funct3 = 3'b111; check_rtype(5'b10111, 1'b0, "R: REMU");
        // Invalid R-type
        funct7 = 7'b0100000; funct3 = 3'b001; check_rtype(5'b00000, 1'b1, "R: illegal f7+f3");
        funct7 = 7'b1111111; funct3 = 3'b000; check_rtype(5'b00000, 1'b1, "R: bad funct7");

        // ===== I-type ALU (0010011) =====
        opcode = 7'b0010011; funct7 = 7'b0;
        funct3 = 3'b000; check_signals(1,0,0,0,0,0,2'b00, "I: ADDI");
        funct3 = 3'b010; check_signals(1,0,0,0,0,0,2'b00, "I: SLTI");
        funct3 = 3'b011; check_signals(1,0,0,0,0,0,2'b00, "I: SLTIU");
        funct3 = 3'b100; check_signals(1,0,0,0,0,0,2'b00, "I: XORI");
        funct3 = 3'b110; check_signals(1,0,0,0,0,0,2'b00, "I: ORI");
        funct3 = 3'b111; check_signals(1,0,0,0,0,0,2'b00, "I: ANDI");
        funct7 = 7'b0000000; funct3 = 3'b001; check_signals(1,0,0,0,0,0,2'b00, "I: SLLI");
        funct7 = 7'b0000000; funct3 = 3'b101; check_signals(1,0,0,0,0,0,2'b00, "I: SRLI");
        funct7 = 7'b0100000; funct3 = 3'b101; check_signals(1,0,0,0,0,0,2'b00, "I: SRAI");
        funct7 = 7'b1111111; funct3 = 3'b001; check_signals(1,0,0,0,0,1,2'b00, "I: SLLI bad f7");

        // ===== Load (0000011) =====
        opcode = 7'b0000011; funct7 = 7'b0;
        funct3 = 3'b000; check_signals(1,1,0,0,0,0,2'b01, "L: LB");
        funct3 = 3'b001; check_signals(1,1,0,0,0,0,2'b01, "L: LH");
        funct3 = 3'b010; check_signals(1,1,0,0,0,0,2'b01, "L: LW");
        funct3 = 3'b100; check_signals(1,1,0,0,0,0,2'b01, "L: LBU");
        funct3 = 3'b101; check_signals(1,1,0,0,0,0,2'b01, "L: LHU");
        // An illegal encoding must request no side effects -- no rd write and
        // no memory access, so it cannot raise an address exception that
        // would outrank the illegal-instruction trap.
        funct3 = 3'b011; check_signals(0,0,0,0,0,1,2'b01, "L: illegal f3");
        funct3 = 3'b110; check_signals(0,0,0,0,0,1,2'b01, "L: illegal f3");

        // ===== Store (0100011) =====
        opcode = 7'b0100011; funct7 = 7'b0;
        funct3 = 3'b000; check_signals(0,0,1,0,0,0,2'b00, "S: SB");
        funct3 = 3'b001; check_signals(0,0,1,0,0,0,2'b00, "S: SH");
        funct3 = 3'b010; check_signals(0,0,1,0,0,0,2'b00, "S: SW");
        funct3 = 3'b011; check_signals(0,0,0,0,0,1,2'b00, "S: illegal f3");

        // ===== Branch (1100011) =====
        opcode = 7'b1100011; funct7 = 7'b0;
        funct3 = 3'b000; check_signals(0,0,0,1,0,0,2'b00, "B: BEQ");
        funct3 = 3'b001; check_signals(0,0,0,1,0,0,2'b00, "B: BNE");
        funct3 = 3'b100; check_signals(0,0,0,1,0,0,2'b00, "B: BLT");
        funct3 = 3'b101; check_signals(0,0,0,1,0,0,2'b00, "B: BGE");
        funct3 = 3'b110; check_signals(0,0,0,1,0,0,2'b00, "B: BLTU");
        funct3 = 3'b111; check_signals(0,0,0,1,0,0,2'b00, "B: BGEU");
        funct3 = 3'b010; check_signals(0,0,0,1,0,1,2'b00, "B: illegal f3");
        funct3 = 3'b011; check_signals(0,0,0,1,0,1,2'b00, "B: illegal f3");

        // ===== LUI (0110111) =====
        opcode = 7'b0110111; funct3 = 3'b0; funct7 = 7'b0;
        check_signals(1,0,0,0,0,0,2'b00, "U: LUI");

        // ===== AUIPC (0010111) =====
        opcode = 7'b0010111;
        check_signals(1,0,0,0,0,0,2'b00, "U: AUIPC");
        #1; if (aluSrc1 !== 1'b1) begin fail_count=fail_count+1; $display("FAIL: AUIPC src1!=PC"); end
        else pass_count = pass_count+1;

        // ===== JAL (1101111) =====
        opcode = 7'b1101111;
        check_signals(1,0,0,0,1,0,2'b10, "J: JAL");

        // ===== JALR (1100111) =====
        opcode = 7'b1100111; funct3 = 3'b000;
        check_signals(1,0,0,0,1,0,2'b10, "I: JALR");
        funct3 = 3'b001;
        check_signals(0,0,0,0,0,1,2'b10, "I: JALR bad f3");  // no link, no jump

        // ===== SYSTEM CSR (1110011) =====
        opcode = 7'b1110011;
        funct3 = 3'b001; funct7 = 7'b0; // CSRRW
        check_signals(1,0,0,0,0,0,2'b11, "CSR: CSRRW");
        #1; if (csrOp !== 2'b01 || csrSrc !== 1'b0) begin fail_count=fail_count+1; $display("FAIL: CSRRW signals"); end
        else pass_count=pass_count+1;

        funct3 = 3'b010; // CSRRS
        check_signals(1,0,0,0,0,0,2'b11, "CSR: CSRRS");
        funct3 = 3'b011; // CSRRC
        check_signals(1,0,0,0,0,0,2'b11, "CSR: CSRRC");
        funct3 = 3'b101; // CSRRWI
        #1; if (csrSrc !== 1'b1) begin fail_count=fail_count+1; $display("FAIL: CSRRWI src"); end
        else pass_count=pass_count+1;
        funct3 = 3'b110; check_signals(1,0,0,0,0,0,2'b11, "CSR: CSRRSI");
        funct3 = 3'b111; check_signals(1,0,0,0,0,0,2'b11, "CSR: CSRRCI");

        // ECALL/MRET
        funct3 = 3'b000; funct7 = 7'b0000000;
        #1; if (!isEcall) begin fail_count=fail_count+1; $display("FAIL: ECALL"); end
        else pass_count=pass_count+1;
        funct7 = 7'b0011000;
        #1; if (!isMret) begin fail_count=fail_count+1; $display("FAIL: MRET"); end
        else pass_count=pass_count+1;

        // ===== FENCE (0001111) =====
        opcode = 7'b0001111; funct3 = 3'b000; funct7 = 7'b0;
        #1; if (!isFence) begin fail_count=fail_count+1; $display("FAIL: FENCE"); end
        else pass_count=pass_count+1;
        funct3 = 3'b001;
        #1; if (!isFenceI) begin fail_count=fail_count+1; $display("FAIL: FENCE.I"); end
        else pass_count=pass_count+1;

        // ===== AMO (0101111) =====
        opcode = 7'b0101111; funct3 = 3'b010;
        funct7 = {5'b00010, 2'b00}; // LR.W
        #1; if (!isLR || !regWR || !memRD) begin fail_count=fail_count+1; $display("FAIL: LR.W"); end
        else pass_count=pass_count+1;
        funct7 = {5'b00011, 2'b00}; // SC.W
        #1; if (!isSC || !regWR) begin fail_count=fail_count+1; $display("FAIL: SC.W"); end
        else pass_count=pass_count+1;
        funct7 = {5'b00000, 2'b00}; // AMOADD.W
        #1; if (!isAmo || !regWR || !memRD || !memWR) begin fail_count=fail_count+1; $display("FAIL: AMOADD"); end
        else pass_count=pass_count+1;
        funct7 = {5'b00001, 2'b00}; // AMOSWAP.W
        #1; if (!isAmo) begin fail_count=fail_count+1; $display("FAIL: AMOSWAP"); end
        else pass_count=pass_count+1;

        // Invalid AMO funct3
        funct3 = 3'b000; funct7 = {5'b00010, 2'b00};
        #1; if (!illegal) begin fail_count=fail_count+1; $display("FAIL: AMO bad f3"); end
        else pass_count=pass_count+1;

        // ===== Invalid opcode =====
        opcode = 7'b1111111; funct3 = 3'b0; funct7 = 7'b0;
        #1; if (!illegal) begin fail_count=fail_count+1; $display("FAIL: bad opcode"); end
        else pass_count=pass_count+1;

        // Two properties fyracore's pipeline control is built on, for every
        // opcode, funct3 and funct7 (the controller sees nothing else):
        //
        //  - An M instruction or a shift makes no memory access and no
        //    branch or jump. So the only traps it can take are the ones
        //    known from decode and fetch, and muldiv_want may leave the
        //    address causes out. Nor is it an ECALL, EBREAK, MRET, LR, FENCE,
        //    CSR access or any other SYSTEM instruction, so of the decode
        //    causes only the controller's own `illegal` is left for it
        //    (ex_trap_iter in fyracore.v).
        //  - Whatever writes memory data to rd (wbSel 01 with regWR) is a
        //    read access (memRD). So load_use_hazard holds every instruction
        //    that reads such an rd, and WB need not forward memory data.
        sweep_bad = 0;
        for (sweep = 0; sweep < (1 << 17); sweep = sweep + 1) begin
            {opcode, funct3, funct7} = sweep[16:0];
            #1;
            if (is_iter && (memRD || memWR || isAmo || isLR || isSC || doBranch || doJump)) begin
                sweep_bad = sweep_bad + 1;
                if (sweep_bad <= 10)
                    $display("FAIL: iterative op with a memory access or a jump: opcode=%07b funct3=%03b funct7=%07b",
                             opcode, funct3, funct7);
            end
            if (is_iter && (isEcall || isEbreak || isMret || isLR || isFence || isFenceI ||
                            csrOp != 2'b00 || opcode == 7'b1110011)) begin
                sweep_bad = sweep_bad + 1;
                if (sweep_bad <= 10)
                    $display("FAIL: iterative op that is a SYSTEM, CSR, LR or FENCE instruction: opcode=%07b funct3=%03b funct7=%07b",
                             opcode, funct3, funct7);
            end
            if (regWR && wbSel == 2'b01 && !memRD) begin
                sweep_bad = sweep_bad + 1;
                if (sweep_bad <= 10)
                    $display("FAIL: memory data written to rd without memRD: opcode=%07b funct3=%03b funct7=%07b",
                             opcode, funct3, funct7);
            end
        end
        if (sweep_bad == 0) pass_count = pass_count + 3;
        else                fail_count = fail_count + sweep_bad;

        $display("\n=== Controller Results: %0d passed, %0d failed ===", pass_count, fail_count);
        if (fail_count == 0) $display("ALL CONTROLLER TESTS PASSED");
        $finish;
    end
endmodule
