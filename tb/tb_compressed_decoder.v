`timescale 1ns / 1ps
module tb_compressed_decoder;
    reg  [15:0] instr_in;
    wire [31:0] instr_out;
    wire        illegal;
    integer pass_count = 0, fail_count = 0;

    compressed_decoder uut(.instr_in(instr_in), .instr_out(instr_out), .illegal(illegal));

    task check(input [31:0] expected, input exp_illegal, input [159:0] name);
        begin
            #1;
            if (instr_out === expected && illegal === exp_illegal)
                pass_count = pass_count + 1;
            else begin
                fail_count = fail_count + 1;
                $display("FAIL: %0s | cin=0x%04h | got=0x%08h(ill=%b) exp=0x%08h(ill=%b)",
                         name, instr_in, instr_out, illegal, expected, exp_illegal);
            end
        end
    endtask

    task check_opcode(input [6:0] exp_opcode, input [2:0] exp_f3, input exp_illegal, input [159:0] name);
        begin
            #1;
            if (instr_out[6:0] === exp_opcode && instr_out[14:12] === exp_f3 && illegal === exp_illegal)
                pass_count = pass_count + 1;
            else begin
                fail_count = fail_count + 1;
                $display("FAIL: %0s | cin=0x%04h | op=%07b(exp=%07b) f3=%03b(exp=%03b) ill=%b",
                         name, instr_in, instr_out[6:0], exp_opcode, instr_out[14:12], exp_f3, illegal);
            end
        end
    endtask

    initial begin
        $dumpfile("tb_compressed_decoder.vcd");
        $dumpvars(0, tb_compressed_decoder);
        $display("=== Compressed Decoder Testbench ===");

        // ===== Quadrant 0 =====

        // C.ADDI4SPN: ADDI rd', x2, nzuimm (rd'=x8, nzuimm=32 → 0x20)
        // Encoding: 000 | nzuimm[5:4|9:6|2|3] | rd' | 00
        // nzuimm=32: [9:6]=0010, [5:4]=00, [3]=0, [2]=0 → bits[12:5] = 00_0010_0_0 = 0x08
        instr_in = 16'b000_00001000_000_00; // rd'=0→x8, nzuimm=32
        check_opcode(7'b0010011, 3'b000, 1'b0, "Q0: C.ADDI4SPN");
        // Check rs1=x2
        #1; if (instr_out[19:15] !== 5'd2) begin fail_count=fail_count+1; $display("FAIL: ADDI4SPN rs1!=x2"); end
        else pass_count=pass_count+1;

        // C.ADDI4SPN with nzuimm=0 should be illegal
        instr_in = 16'b000_00000000_000_00;
        #1; if (illegal !== 1'b1) begin fail_count=fail_count+1; $display("FAIL: ADDI4SPN nzuimm=0 not illegal"); end
        else pass_count=pass_count+1;

        // C.LW: LW rd', offset(rs1')
        // Format: 010 | uimm[5:3] | rs1' | uimm[2|6] | rd' | 00
        instr_in = 16'b010_000_000_00_000_00; // minimal encoding
        check_opcode(7'b0000011, 3'b010, 1'b0, "Q0: C.LW");

        // C.SW: SW rs2', offset(rs1')
        instr_in = 16'b110_000_000_00_000_00;
        check_opcode(7'b0100011, 3'b010, 1'b0, "Q0: C.SW");

        // ===== Quadrant 1 =====

        // C.NOP: ADDI x0, x0, 0
        instr_in = 16'b000_0_00000_00000_01;
        check(32'h00000013, 1'b0, "Q1: C.NOP");

        // C.ADDI: ADDI rd, rd, nzimm (rd=x1, imm=1)
        instr_in = 16'b000_0_00001_00001_01; // rd=1, imm=1
        check_opcode(7'b0010011, 3'b000, 1'b0, "Q1: C.ADDI x1,1");
        #1; if (instr_out[11:7] !== 5'd1 || instr_out[19:15] !== 5'd1)
            begin fail_count=fail_count+1; $display("FAIL: C.ADDI rd/rs1"); end
        else pass_count=pass_count+1;

        // C.ADDI with negative imm (imm=-1, bit12=1, bits[6:2]=11111)
        instr_in = 16'b000_1_00001_11111_01;
        check_opcode(7'b0010011, 3'b000, 1'b0, "Q1: C.ADDI x1,-1");
        #1; if (instr_out[31:20] !== 12'hFFF)
            begin fail_count=fail_count+1; $display("FAIL: C.ADDI neg imm=%0h", instr_out[31:20]); end
        else pass_count=pass_count+1;

        // C.JAL: JAL x1, offset
        instr_in = 16'b001_0_00000_00000_01; // minimal offset
        check_opcode(7'b1101111, 3'b0, 1'b0, "Q1: C.JAL");
        #1; if (instr_out[11:7] !== 5'd1)
            begin fail_count=fail_count+1; $display("FAIL: C.JAL rd!=x1"); end
        else pass_count=pass_count+1;

        // C.LI: ADDI rd, x0, imm (rd=x5, imm=10)
        instr_in = 16'b010_0_00101_01010_01; // rd=5, imm=10
        check_opcode(7'b0010011, 3'b000, 1'b0, "Q1: C.LI x5,10");
        #1; if (instr_out[11:7] !== 5'd5 || instr_out[19:15] !== 5'd0)
            begin fail_count=fail_count+1; $display("FAIL: C.LI fields"); end
        else pass_count=pass_count+1;

        // C.ADDI16SP: ADDI x2, x2, nzimm (rd=x2)
        // nzimm = sext({inst[12], inst[4:3], inst[5], inst[2], inst[6], 4'b0})
        instr_in = 16'b011_0_00010_00001_01; // rd=2, some nzimm
        check_opcode(7'b0010011, 3'b000, 1'b0, "Q1: C.ADDI16SP");
        #1; if (instr_out[11:7] !== 5'd2 || instr_out[19:15] !== 5'd2)
            begin fail_count=fail_count+1; $display("FAIL: ADDI16SP rd/rs1!=x2"); end
        else pass_count=pass_count+1;

        // C.ADDI16SP with nzimm=0: illegal
        instr_in = 16'b011_0_00010_00000_01;
        #1; if (illegal !== 1'b1)
            begin fail_count=fail_count+1; $display("FAIL: ADDI16SP nzimm=0 not illegal"); end
        else pass_count=pass_count+1;

        // C.LUI: LUI rd, nzimm (rd=x3)
        // Note: LUI is U-type, bits[14:12] are part of imm, not funct3
        instr_in = 16'b011_0_00011_00001_01; // rd=3, nzimm!=0
        #1;
        if (instr_out[6:0] === 7'b0110111 && instr_out[11:7] === 5'd3 && illegal === 1'b0)
            pass_count = pass_count + 1;
        else begin
            fail_count = fail_count + 1;
            $display("FAIL: Q1: C.LUI x3 | cin=0x%04h | op=%07b rd=%0d ill=%b",
                     instr_in, instr_out[6:0], instr_out[11:7], illegal);
        end

        // C.LUI with nzimm=0: illegal
        instr_in = 16'b011_0_00011_00000_01;
        #1; if (illegal !== 1'b1)
            begin fail_count=fail_count+1; $display("FAIL: C.LUI nzimm=0 not illegal"); end
        else pass_count=pass_count+1;

        // C.LUI with rd=0 and nzimm!=0: HINT, not illegal — expands to LUI x0
        instr_in = 16'b011_0_00000_00001_01;
        #1; if (illegal !== 1'b0 || instr_out !== 32'h00001037)
            begin fail_count=fail_count+1;
                  $display("FAIL: C.LUI rd=0 | op=%08h ill=%b", instr_out, illegal); end
        else pass_count=pass_count+1;

        // C.SRLI: SRLI rd', rd', shamt
        instr_in = 16'b100_0_00_000_00001_01; // rs1'=x8, shamt=1
        check_opcode(7'b0010011, 3'b101, 1'b0, "Q1: C.SRLI");
        #1; if (instr_out[31:25] !== 7'b0000000)
            begin fail_count=fail_count+1; $display("FAIL: C.SRLI funct7"); end
        else pass_count=pass_count+1;

        // C.SRAI: SRAI rd', rd', shamt
        instr_in = 16'b100_0_01_000_00001_01;
        check_opcode(7'b0010011, 3'b101, 1'b0, "Q1: C.SRAI");
        #1; if (instr_out[31:25] !== 7'b0100000)
            begin fail_count=fail_count+1; $display("FAIL: C.SRAI funct7"); end
        else pass_count=pass_count+1;

        // C.ANDI: ANDI rd', rd', imm
        instr_in = 16'b100_0_10_000_01111_01;
        check_opcode(7'b0010011, 3'b111, 1'b0, "Q1: C.ANDI");

        // C.SUB: SUB rd', rd', rs2'
        instr_in = 16'b100_0_11_000_00_000_01;
        check_opcode(7'b0110011, 3'b000, 1'b0, "Q1: C.SUB");
        #1; if (instr_out[31:25] !== 7'b0100000)
            begin fail_count=fail_count+1; $display("FAIL: C.SUB funct7"); end
        else pass_count=pass_count+1;

        // C.XOR
        instr_in = 16'b100_0_11_000_01_000_01;
        check_opcode(7'b0110011, 3'b100, 1'b0, "Q1: C.XOR");

        // C.OR
        instr_in = 16'b100_0_11_000_10_000_01;
        check_opcode(7'b0110011, 3'b110, 1'b0, "Q1: C.OR");

        // C.AND
        instr_in = 16'b100_0_11_000_11_000_01;
        check_opcode(7'b0110011, 3'b111, 1'b0, "Q1: C.AND");

        // C.J: JAL x0, offset
        instr_in = 16'b101_0_00000_00000_01;
        check_opcode(7'b1101111, 3'b0, 1'b0, "Q1: C.J");
        #1; if (instr_out[11:7] !== 5'd0)
            begin fail_count=fail_count+1; $display("FAIL: C.J rd!=x0"); end
        else pass_count=pass_count+1;

        // C.BEQZ: BEQ rs1', x0, offset
        instr_in = 16'b110_000_000_00000_01;
        check_opcode(7'b1100011, 3'b000, 1'b0, "Q1: C.BEQZ");

        // C.BNEZ: BNE rs1', x0, offset
        instr_in = 16'b111_000_000_00000_01;
        check_opcode(7'b1100011, 3'b001, 1'b0, "Q1: C.BNEZ");

        // ===== Quadrant 2 =====

        // C.SLLI: SLLI rd, rd, shamt (rd=x1, shamt=1)
        instr_in = 16'b000_0_00001_00001_10;
        check_opcode(7'b0010011, 3'b001, 1'b0, "Q2: C.SLLI x1,1");

        // C.LWSP: LW rd, offset(x2) (rd=x1)
        instr_in = 16'b010_0_00001_00000_10;
        check_opcode(7'b0000011, 3'b010, 1'b0, "Q2: C.LWSP x1");
        #1; if (instr_out[19:15] !== 5'd2)
            begin fail_count=fail_count+1; $display("FAIL: C.LWSP rs1!=x2"); end
        else pass_count=pass_count+1;

        // C.LWSP rd=0: illegal
        instr_in = 16'b010_0_00000_00000_10;
        #1; if (illegal !== 1'b1)
            begin fail_count=fail_count+1; $display("FAIL: C.LWSP rd=0 not illegal"); end
        else pass_count=pass_count+1;

        // C.JR: JALR x0, rs1, 0 (rs1=x1)
        instr_in = 16'b100_0_00001_00000_10;
        check_opcode(7'b1100111, 3'b000, 1'b0, "Q2: C.JR x1");
        #1; if (instr_out[11:7] !== 5'd0)
            begin fail_count=fail_count+1; $display("FAIL: C.JR rd!=x0"); end
        else pass_count=pass_count+1;

        // C.JR rs1=0: illegal
        instr_in = 16'b100_0_00000_00000_10;
        #1; if (illegal !== 1'b1)
            begin fail_count=fail_count+1; $display("FAIL: C.JR rs1=0 not illegal"); end
        else pass_count=pass_count+1;

        // C.MV: ADD rd, x0, rs2 (rd=x1, rs2=x2)
        instr_in = 16'b100_0_00001_00010_10;
        check_opcode(7'b0110011, 3'b000, 1'b0, "Q2: C.MV x1,x2");
        #1; if (instr_out[19:15] !== 5'd0 || instr_out[24:20] !== 5'd2)
            begin fail_count=fail_count+1; $display("FAIL: C.MV fields"); end
        else pass_count=pass_count+1;

        // C.EBREAK
        instr_in = 16'b100_1_00000_00000_10;
        check(32'h00100073, 1'b0, "Q2: C.EBREAK");

        // C.JALR: JALR x1, rs1, 0 (rs1=x5)
        instr_in = 16'b100_1_00101_00000_10;
        check_opcode(7'b1100111, 3'b000, 1'b0, "Q2: C.JALR x5");
        #1; if (instr_out[11:7] !== 5'd1 || instr_out[19:15] !== 5'd5)
            begin fail_count=fail_count+1; $display("FAIL: C.JALR fields"); end
        else pass_count=pass_count+1;

        // C.ADD: ADD rd, rd, rs2 (rd=x1, rs2=x2)
        instr_in = 16'b100_1_00001_00010_10;
        check_opcode(7'b0110011, 3'b000, 1'b0, "Q2: C.ADD x1,x2");
        #1; if (instr_out[11:7] !== 5'd1 && instr_out[19:15] !== 5'd1)
            begin fail_count=fail_count+1; $display("FAIL: C.ADD rd=rs1"); end
        else pass_count=pass_count+1;

        // C.SWSP: SW rs2, offset(x2)
        instr_in = 16'b110_000000_00001_10; // rs2=x1
        check_opcode(7'b0100011, 3'b010, 1'b0, "Q2: C.SWSP");
        #1; if (instr_out[19:15] !== 5'd2)
            begin fail_count=fail_count+1; $display("FAIL: C.SWSP rs1!=x2"); end
        else pass_count=pass_count+1;

        // Illegal quadrant 0 funct3
        instr_in = 16'b001_00000000_000_00; // funct3=001 in Q0
        #1; if (illegal !== 1'b1)
            begin fail_count=fail_count+1; $display("FAIL: Q0 illegal funct3"); end
        else pass_count=pass_count+1;

        $display("\n=== Compressed Decoder Results: %0d passed, %0d failed ===", pass_count, fail_count);
        if (fail_count == 0) $display("ALL COMPRESSED DECODER TESTS PASSED");
        $finish;
    end
endmodule
