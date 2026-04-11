`timescale 1ns / 1ps
module tb_decoder;
    reg  [31:0] instIn;
    wire [6:0]  opcode;
    wire [4:0]  rd, rs1, rs2;
    wire [2:0]  funct3;
    wire [6:0]  funct7;
    integer pass_count = 0, fail_count = 0;

    decoder uut(.instIn(instIn), .opcode(opcode), .rd(rd), .rs1(rs1),
                .rs2(rs2), .funct3(funct3), .funct7(funct7));

    task check_fields(
        input [6:0] exp_op, input [4:0] exp_rd, input [4:0] exp_rs1,
        input [4:0] exp_rs2, input [2:0] exp_f3, input [6:0] exp_f7,
        input [159:0] name
    );
        begin
            #1;
            if (opcode === exp_op && rd === exp_rd && rs1 === exp_rs1 &&
                rs2 === exp_rs2 && funct3 === exp_f3 && funct7 === exp_f7) begin
                pass_count = pass_count + 1;
            end else begin
                fail_count = fail_count + 1;
                $display("FAIL: %0s", name);
                $display("  inst=0x%08h", instIn);
                if (opcode !== exp_op)  $display("  opcode: got=%07b exp=%07b", opcode, exp_op);
                if (rd !== exp_rd)      $display("  rd:     got=%d exp=%d", rd, exp_rd);
                if (rs1 !== exp_rs1)    $display("  rs1:    got=%d exp=%d", rs1, exp_rs1);
                if (rs2 !== exp_rs2)    $display("  rs2:    got=%d exp=%d", rs2, exp_rs2);
                if (funct3 !== exp_f3)  $display("  funct3: got=%03b exp=%03b", funct3, exp_f3);
                if (funct7 !== exp_f7)  $display("  funct7: got=%07b exp=%07b", funct7, exp_f7);
            end
        end
    endtask

    initial begin
        $dumpfile("tb_decoder.vcd");
        $dumpvars(0, tb_decoder);
        $display("=== Decoder Testbench ===");

        // R-type: ADD x18, x9, x8 → 0x00848933
        instIn = 32'h00848933;
        check_fields(7'b0110011, 5'd18, 5'd9, 5'd8, 3'b000, 7'b0000000, "R: ADD x18,x9,x8");

        // R-type: SUB x1, x2, x3 → 0x40310093... let me encode correctly
        // SUB x5, x6, x7: funct7=0100000, rs2=7, rs1=6, f3=000, rd=5, op=0110011
        instIn = {7'b0100000, 5'd7, 5'd6, 3'b000, 5'd5, 7'b0110011};
        check_fields(7'b0110011, 5'd5, 5'd6, 5'd7, 3'b000, 7'b0100000, "R: SUB x5,x6,x7");

        // R-type M-ext: MUL x10, x11, x12
        instIn = {7'b0000001, 5'd12, 5'd11, 3'b000, 5'd10, 7'b0110011};
        check_fields(7'b0110011, 5'd10, 5'd11, 5'd12, 3'b000, 7'b0000001, "R: MUL x10,x11,x12");

        // I-type: ADDI x8, x9, 0x101 → 0x10148413
        instIn = 32'h10148413;
        check_fields(7'b0010011, 5'd8, 5'd9, 5'd0, 3'b000, 7'b0, "I: ADDI x8,x9,0x101");

        // I-type: SLLI x1, x2, 5 → funct7=0000000, shamt=5, rs1=2, f3=001, rd=1
        instIn = {7'b0000000, 5'd5, 5'd2, 3'b001, 5'd1, 7'b0010011};
        check_fields(7'b0010011, 5'd1, 5'd2, 5'd0, 3'b001, 7'b0000000, "I: SLLI x1,x2,5");

        // I-type: SRAI x3, x4, 10 → funct7=0100000
        instIn = {7'b0100000, 5'd10, 5'd4, 3'b101, 5'd3, 7'b0010011};
        check_fields(7'b0010011, 5'd3, 5'd4, 5'd0, 3'b101, 7'b0100000, "I: SRAI x3,x4,10");

        // Load: LW x6, 12(x3) → 0x00C1A303
        instIn = 32'h00C1A303;
        check_fields(7'b0000011, 5'd6, 5'd3, 5'd0, 3'b010, 7'b0, "IL: LW x6,12(x3)");

        // Load: LBU x7, 0(x8)
        instIn = {12'h000, 5'd8, 3'b100, 5'd7, 7'b0000011};
        check_fields(7'b0000011, 5'd7, 5'd8, 5'd0, 3'b100, 7'b0, "IL: LBU x7,0(x8)");

        // Store: SW x8, 8(x5) → S-type
        instIn = {7'b0000000, 5'd8, 5'd5, 3'b010, 5'b01000, 7'b0100011};
        check_fields(7'b0100011, 5'd0, 5'd5, 5'd8, 3'b010, 7'b0, "S: SW x8,8(x5)");

        // Branch: BEQ x1, x2, offset
        instIn = {7'b0000000, 5'd2, 5'd1, 3'b000, 5'b00000, 7'b1100011};
        check_fields(7'b1100011, 5'd0, 5'd1, 5'd2, 3'b000, 7'b0, "B: BEQ x1,x2");

        // Branch: BNE x10, x11
        instIn = {7'b0000000, 5'd11, 5'd10, 3'b001, 5'b00000, 7'b1100011};
        check_fields(7'b1100011, 5'd0, 5'd10, 5'd11, 3'b001, 7'b0, "B: BNE x10,x11");

        // LUI x1, 0xDEADB
        instIn = 32'hDEADB0B7;
        check_fields(7'b0110111, 5'd1, 5'd0, 5'd0, 3'b0, 7'b0, "U: LUI x1,0xDEADB");

        // AUIPC x2, 0x10000
        instIn = 32'h10000117;
        check_fields(7'b0010111, 5'd2, 5'd0, 5'd0, 3'b0, 7'b0, "U: AUIPC x2,0x10000");

        // JAL x1, offset → 0x004000EF
        instIn = 32'h004000EF;
        check_fields(7'b1101111, 5'd1, 5'd0, 5'd0, 3'b0, 7'b0, "J: JAL x1");

        // JALR x1, x2, 0x10
        instIn = {12'h010, 5'd2, 3'b000, 5'd1, 7'b1100111};
        check_fields(7'b1100111, 5'd1, 5'd2, 5'd0, 3'b000, 7'b0, "I: JALR x1,x2,0x10");

        // SYSTEM: ECALL (0x00000073)
        instIn = 32'h00000073;
        check_fields(7'b1110011, 5'd0, 5'd0, 5'd0, 3'b000, 7'b0000000, "SYS: ECALL");

        // SYSTEM: EBREAK (0x00100073) — rs1/rs2 extracted per SYSTEM decode
        instIn = 32'h00100073;
        check_fields(7'b1110011, 5'd0, 5'd0, 5'd0, 3'b000, 7'b0000000, "SYS: EBREAK");

        // SYSTEM: MRET (0x30200073) — funct7=inst[31:25]=0011000
        instIn = 32'h30200073;
        check_fields(7'b1110011, 5'd0, 5'd0, 5'd0, 3'b000, 7'b0011000, "SYS: MRET");

        // CSR: CSRRW x1, mstatus(0x300), x2 → funct7=inst[31:25]=0011000
        instIn = {12'h300, 5'd2, 3'b001, 5'd1, 7'b1110011};
        check_fields(7'b1110011, 5'd1, 5'd2, 5'd0, 3'b001, 7'b0011000, "CSR: CSRRW");

        // CSR: CSRRSI x3, mie(0x304), 0x1F → funct7=inst[31:25]=0011000
        instIn = {12'h304, 5'd31, 3'b110, 5'd3, 7'b1110011};
        check_fields(7'b1110011, 5'd3, 5'd31, 5'd0, 3'b110, 7'b0011000, "CSR: CSRRSI");

        // FENCE
        instIn = 32'h0FF0000F;
        check_fields(7'b0001111, 5'd0, 5'd0, 5'd0, 3'b000, 7'b0, "FENCE");

        // FENCE.I
        instIn = 32'h0000100F;
        check_fields(7'b0001111, 5'd0, 5'd0, 5'd0, 3'b001, 7'b0, "FENCE.I");

        // AMO: LR.W x1, (x2)
        instIn = {5'b00010, 2'b00, 5'd0, 5'd2, 3'b010, 5'd1, 7'b0101111};
        check_fields(7'b0101111, 5'd1, 5'd2, 5'd0, 3'b010, 7'b0001000, "AMO: LR.W");

        // AMO: SC.W x1, x3, (x2)
        instIn = {5'b00011, 2'b00, 5'd3, 5'd2, 3'b010, 5'd1, 7'b0101111};
        check_fields(7'b0101111, 5'd1, 5'd2, 5'd3, 3'b010, 7'b0001100, "AMO: SC.W");

        // AMO: AMOADD.W x4, x5, (x6)
        instIn = {5'b00000, 2'b00, 5'd5, 5'd6, 3'b010, 5'd4, 7'b0101111};
        check_fields(7'b0101111, 5'd4, 5'd6, 5'd5, 3'b010, 7'b0000000, "AMO: AMOADD.W");

        // Invalid opcode
        instIn = 32'hFFFFFFFF;
        check_fields(7'b1111111, 5'd0, 5'd0, 5'd0, 3'b0, 7'b0, "Invalid opcode");

        $display("\n=== Decoder Results: %0d passed, %0d failed ===", pass_count, fail_count);
        if (fail_count == 0) $display("ALL DECODER TESTS PASSED");
        $finish;
    end
endmodule
