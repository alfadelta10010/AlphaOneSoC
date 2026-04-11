`timescale 1ns / 1ps
module tb_signExt;
    reg  [6:0]  opcode;
    reg  [31:0] instIn;
    wire [31:0] immOut;
    integer pass_count = 0, fail_count = 0;

    signExt uut(.opcode(opcode), .instIn(instIn), .immOut(immOut));

    task check(input [31:0] expected, input [159:0] name);
        begin
            #1;
            if (immOut === expected) begin
                pass_count = pass_count + 1;
            end else begin
                fail_count = fail_count + 1;
                $display("FAIL: %0s | op=%07b inst=0x%08h | got=0x%08h exp=0x%08h",
                         name, opcode, instIn, immOut, expected);
            end
        end
    endtask

    initial begin
        $dumpfile("tb_signExt.vcd");
        $dumpvars(0, tb_signExt);
        $display("=== Sign Extension Testbench ===");

        // ---- I-type ALU (0010011) ----
        opcode = 7'b0010011;
        // ADDI x8, x8, 11 → imm=11
        instIn = 32'h00B40413; check(32'd11, "I: pos imm 11");
        // ADDI with negative: imm = -10 (0xFF6)
        instIn = 32'hFF640413; check(32'hFFFFFFF6, "I: neg imm -10 (0xFF6)");
        // ADDI imm=0
        instIn = 32'h00040413; check(32'h0, "I: zero imm");
        // ADDI imm=2047 (0x7FF)
        instIn = 32'h7FF40413; check(32'd2047, "I: max pos 2047");
        // ADDI imm=-2048 (0x800)
        instIn = 32'h80040413; check(32'hFFFFF800, "I: min neg -2048");
        // SLLI: shamt=5 → imm should be 5 (zero-extended)
        instIn = {7'b0000000, 5'd5, 5'd2, 3'b001, 5'd1, 7'b0010011};
        check(32'd5, "I: SLLI shamt=5");
        // SRLI: shamt=31
        instIn = {7'b0000000, 5'd31, 5'd2, 3'b101, 5'd1, 7'b0010011};
        check(32'd31, "I: SRLI shamt=31");
        // SRAI: shamt=10 (funct7 has bit set but shamt is zero-extended)
        instIn = {7'b0100000, 5'd10, 5'd4, 3'b101, 5'd3, 7'b0010011};
        check(32'd10, "I: SRAI shamt=10");

        // ---- I-type Load (0000011) ----
        opcode = 7'b0000011;
        instIn = 32'h00C1A303; check(32'd12, "IL: offset 12");
        instIn = 32'hFFC1A303; check(32'hFFFFFFFC, "IL: offset -4");
        instIn = 32'h0001A303; check(32'h0, "IL: offset 0");

        // ---- S-type (0100011) ----
        opcode = 7'b0100011;
        // SW x8, 6(x3): imm = {0000000, 00110} = 6
        instIn = {7'b0000000, 5'd8, 5'd3, 3'b010, 5'b00110, 7'b0100011};
        check(32'd6, "S: offset 6");
        // Negative offset: imm = -4 (0xFFC)
        instIn = {7'b1111111, 5'd8, 5'd3, 3'b010, 5'b11100, 7'b0100011};
        check(32'hFFFFFFFC, "S: offset -4");
        // Zero offset
        instIn = {7'b0000000, 5'd8, 5'd3, 3'b010, 5'b00000, 7'b0100011};
        check(32'h0, "S: offset 0");

        // ---- B-type (1100011) ----
        opcode = 7'b1100011;
        // BEQ x0, x0, -12 (0xFFFFFFF4)
        instIn = 32'hFE000AE3; check(32'hFFFFFFF4, "B: offset -12");
        // Forward branch offset +8
        instIn = {1'b0, 6'b000000, 5'd0, 5'd0, 3'b000, 4'b0100, 1'b0, 7'b1100011};
        check(32'd8, "B: offset +8");
        // Zero branch
        instIn = {1'b0, 6'b000000, 5'd0, 5'd0, 3'b000, 4'b0000, 1'b0, 7'b1100011};
        check(32'd0, "B: offset 0");

        // ---- U-type LUI (0110111) ----
        opcode = 7'b0110111;
        instIn = 32'hFFFFF037; check(32'hFFFFF000, "U: LUI 0xFFFFF");
        instIn = 32'h00001037; check(32'h00001000, "U: LUI 0x1");
        instIn = 32'h00000037; check(32'h00000000, "U: LUI 0x0");
        instIn = 32'hDEADB037; check(32'hDEADB000, "U: LUI 0xDEADB");

        // ---- U-type AUIPC (0010111) ----
        opcode = 7'b0010111;
        instIn = 32'hF0101017; check(32'hF0101000, "U: AUIPC 0xF0101");
        instIn = 32'h00000017; check(32'h00000000, "U: AUIPC 0x0");

        // ---- J-type JAL (1101111) ----
        opcode = 7'b1101111;
        // JAL x1, +4 → 0x004000EF
        instIn = 32'h004000EF; check(32'd4, "J: JAL +4");
        // JAL x0, 0 (infinite loop)
        instIn = 32'h0000006F; check(32'd0, "J: JAL 0");
        // JAL negative offset
        instIn = 32'hFF9FF06F; check(32'hFFFFFFF8, "J: JAL neg");

        // ---- JALR (1100111) ----
        opcode = 7'b1100111;
        instIn = {12'h010, 5'd2, 3'b000, 5'd1, 7'b1100111};
        check(32'h10, "JALR: offset 16");
        instIn = {12'hFFF, 5'd2, 3'b000, 5'd1, 7'b1100111};
        check(32'hFFFFFFFF, "JALR: offset -1");

        // ---- SYSTEM (1110011) → zimm ----
        opcode = 7'b1110011;
        instIn = {12'h300, 5'd31, 3'b110, 5'd3, 7'b1110011};
        check(32'd31, "SYS: zimm=31");
        instIn = {12'h300, 5'd0, 3'b110, 5'd3, 7'b1110011};
        check(32'd0, "SYS: zimm=0");

        // ---- FENCE (0001111) ----
        opcode = 7'b0001111;
        instIn = 32'h0FF0000F; check(32'h0, "FENCE: zero");

        // ---- Default ----
        opcode = 7'b1111111;
        instIn = 32'hDEADBEEF; check(32'h0, "Default: zero");

        $display("\n=== SignExt Results: %0d passed, %0d failed ===", pass_count, fail_count);
        if (fail_count == 0) $display("ALL SIGNEXT TESTS PASSED");
        $finish;
    end
endmodule
