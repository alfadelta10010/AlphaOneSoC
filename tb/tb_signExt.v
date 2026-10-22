`timescale 1ns / 1ps
// signExt (src/signExt.v) against the RV32I immediate formats (Unprivileged
// ISA 2.3, figure "Types of immediate produced by RISC-V instructions"):
// I (loads, OP-IMM, JALR), S, B, U (LUI, AUIPC), J. For the OP-IMM shifts
// only the shift amount, imm[4:0] = instr[24:20], has a meaning (muldiv
// takes b[4:0]); opcodes without an immediate, and SYSTEM (fyracore takes a
// CSR zimm from the rs1 field, not from here), are not checked. Every one of
// the 128 opcodes gets 4096 seeded random words (+SEED=); corners first.
// Prints PASS/FAIL with the number of checks.
module tb_signExt;
    reg  [6:0]  opcode;
    reg  [31:0] instIn;
    wire [31:0] immOut;
    signExt uut(.opcode(opcode), .instIn(instIn), .immOut(immOut));

    integer checks = 0, fails = 0, seed = 1, op, k;
    integer seed0 = 1;
    reg [31:0] want, mask;

    task check;
        reg [31:0] w;
        begin
            w = instIn;
            mask = 32'hFFFF_FFFF;
            case (opcode)
                7'b0110111, 7'b0010111: want = {w[31:12], 12'b0};
                7'b1101111: want = {{12{w[31]}}, w[19:12], w[20], w[30:21], 1'b0};
                7'b1100111, 7'b0000011: want = {{20{w[31]}}, w[31:20]};
                7'b1100011: want = {{20{w[31]}}, w[7], w[30:25], w[11:8], 1'b0};
                7'b0100011: want = {{20{w[31]}}, w[31:25], w[11:7]};
                7'b0010011: if (w[13:12] == 2'b01) begin want = {27'b0, w[24:20]}; mask = 32'h1F; end
                            else want = {{20{w[31]}}, w[31:20]};
                default: mask = 0;
            endcase
            #1;
            if (mask != 0) begin
                checks = checks + 1;
                if ((immOut & mask) !== (want & mask)) begin
                    fails = fails + 1;
                    if (fails <= 25)
                        $display("FAIL opcode=%07b instr=%08h: imm %08h want %08h (mask %08h)", opcode, w, immOut, want, mask);
                end
            end
        end
    endtask

    initial begin
        if ($value$plusargs("SEED=%d", seed)) ;
        seed0 = seed;   // $random(seed) moves seed on: report the one that reproduces the run
        $display("=== Sign Extension Testbench (RV32I formats, seed %0d) ===", seed);
        for (op = 0; op < 128; op = op + 1) begin
            opcode = op;
            // corners: all zeros, all ones, only the sign bit, all but it
            instIn = {25'h0, opcode};          check;
            instIn = {25'h1FF_FFFF, opcode};   check;
            instIn = {25'h100_0000, opcode};   check;
            instIn = {25'h0FF_FFFF, opcode};   check;
            for (k = 0; k < 4096; k = k + 1) begin
                instIn = $random(seed);
                instIn[6:0] = opcode;
                check;
            end
        end
        if (fails == 0) $display("PASS tb_signExt (%0d checks, seed %0d)", checks, seed0);
        else            $display("FAIL tb_signExt: %0d failures, %0d checks, seed %0d", fails, checks, seed0);
        $finish;
    end
endmodule
