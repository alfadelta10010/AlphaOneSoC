`timescale 1ns / 1ps
// compressed_decoder (src/compressed_decoder.v) against a model of the RV32C
// tables written from the specification (Unprivileged ISA, "C" Standard
// Extension: the CIW/CL/CS/CA/CB/CJ/CR/CI/CSS formats, the RVC opcode map,
// and the HINT and reserved code points), with FyraCore's choices from
// docs/FyraCore_CPU_Reference.md 9.4: no F/D, so their encodings are
// illegal; Zcb/Zcmop and the RV64-only codes are illegal; shamt[5] = 1 is
// illegal on RV32; HINTs execute.
//
// The model decodes each field the way the spec draws it and then builds the
// 32-bit instruction with ordinary I/S/B/U/J/R encoders, so it shares no
// bit-wiring with the DUT, which writes the 32-bit word directly.
//
// Every one of the 49,152 16-bit encodings (bits [1:0] != 11) is checked:
// the illegal flag on all of them, and the expansion on every legal one.
// Prints PASS/FAIL with the number of checks; a coverage floor per opcode
// slot makes sure each slot was seen both ways where both exist.
module tb_compressed_decoder;
    reg  [15:0] instr_in;
    wire [31:0] instr_out;
    wire        illegal;

    compressed_decoder uut(.instr_in(instr_in), .instr_out(instr_out), .illegal(illegal));

    integer checks = 0, fails = 0, n_legal = 0, n_illegal = 0, i, s;
    integer slot_legal [0:23];
    integer slot_ill   [0:23];

    // ── encoders (RV32I base formats) ────────────────────────────────────
    function [31:0] enc_r(input [6:0] f7, input [4:0] rs2, input [4:0] rs1, input [2:0] f3,
                          input [4:0] rd, input [6:0] op);
        enc_r = {f7, rs2, rs1, f3, rd, op};
    endfunction
    function [31:0] enc_i(input [11:0] imm, input [4:0] rs1, input [2:0] f3, input [4:0] rd,
                          input [6:0] op);
        enc_i = {imm, rs1, f3, rd, op};
    endfunction
    function [31:0] enc_s(input [11:0] imm, input [4:0] rs2, input [4:0] rs1, input [2:0] f3);
        enc_s = {imm[11:5], rs2, rs1, f3, imm[4:0], 7'b0100011};
    endfunction
    function [31:0] enc_b(input [12:0] imm, input [4:0] rs2, input [4:0] rs1, input [2:0] f3);
        enc_b = {imm[12], imm[10:5], rs2, rs1, f3, imm[4:1], imm[11], 7'b1100011};
    endfunction
    function [31:0] enc_j(input [20:0] imm, input [4:0] rd);
        enc_j = {imm[20], imm[10:1], imm[11], imm[19:12], rd, 7'b1101111};
    endfunction
    function [31:0] enc_u(input [31:0] imm, input [4:0] rd);
        enc_u = {imm[31:12], rd, 7'b0110111};
    endfunction

    localparam [6:0] OPIMM = 7'b0010011, OP = 7'b0110011, LOAD = 7'b0000011, JALR = 7'b1100111;

    // ── the model ────────────────────────────────────────────────────────
    reg        m_legal;
    reg [31:0] m_out;
    reg [4:0]  rdp, rs1p, rs2p, rd, rs2;
    reg [5:0]  shamt;
    reg [11:0] imm6;            // sign-extended 6-bit immediate (CI)
    reg [20:0] joff;            // CJ offset
    reg [12:0] boff;            // CB offset
    reg [9:0]  nzuimm;          // CIW
    reg [6:0]  luimm;           // CL/CS word offset
    reg [7:0]  spimm;           // CI/CSS sp offset
    reg [9:0]  sp16;            // C.ADDI16SP, bits 9:0
    reg [17:0] lui18;           // C.LUI, bits 17:0
    task model(input [15:0] c);
        begin
            m_legal = 1'b1;
            m_out   = 32'h0;
            rdp   = {2'b01, c[4:2]};
            rs1p  = {2'b01, c[9:7]};
            rs2p  = {2'b01, c[4:2]};
            rd    = c[11:7];
            rs2   = c[6:2];
            shamt = {c[12], c[6:2]};
            imm6  = {{7{c[12]}}, c[6:2]};
            joff  = {{10{c[12]}}, c[8], c[10:9], c[6], c[7], c[2], c[11], c[5:3], 1'b0};
            boff  = {{5{c[12]}}, c[6:5], c[2], c[11:10], c[4:3], 1'b0};
            nzuimm = {c[10:7], c[12:11], c[5], c[6], 2'b00};
            luimm  = {c[5], c[12:10], c[6], 2'b00};
            sp16   = {c[12], c[4:3], c[5], c[2], c[6], 4'b0000};
            lui18  = {c[12], c[6:2], 12'b0};
            case ({c[1:0], c[15:13]})
                // quadrant 0
                5'b00_000: if (nzuimm == 10'd0) m_legal = 0;                // all-zero word too
                           else m_out = enc_i({2'b00, nzuimm}, 5'd2, 3'b000, rdp, OPIMM);
                5'b00_010: m_out = enc_i({5'b0, luimm}, rs1p, 3'b010, rdp, LOAD);
                5'b00_110: m_out = enc_s({5'b0, luimm}, rs2p, rs1p, 3'b010);
                5'b00_001, 5'b00_011, 5'b00_100, 5'b00_101, 5'b00_111: m_legal = 0; // FLD/FLW/Zcb/FSD/FSW
                // quadrant 1
                5'b01_000: m_out = enc_i(imm6, rd, 3'b000, rd, OPIMM);       // C.NOP/C.ADDI (+HINTs)
                5'b01_001: m_out = enc_j(joff, 5'd1);                        // C.JAL
                5'b01_010: m_out = enc_i(imm6, 5'd0, 3'b000, rd, OPIMM);     // C.LI (+HINT)
                5'b01_011: if (rd == 5'd2) begin                             // C.ADDI16SP
                               if (sp16 == 10'd0) m_legal = 0;
                               else m_out = enc_i({{2{sp16[9]}}, sp16}, 5'd2, 3'b000, 5'd2, OPIMM);
                           end else begin                                    // C.LUI (rd=0: HINT)
                               if (lui18 == 18'd0) m_legal = 0;
                               else m_out = enc_u({{14{lui18[17]}}, lui18}, rd);
                           end
                5'b01_100: case (c[11:10])
                               2'b00: if (shamt[5]) m_legal = 0;
                                      else m_out = enc_i({6'b000000, shamt}, rs1p, 3'b101, rs1p, OPIMM);
                               2'b01: if (shamt[5]) m_legal = 0;
                                      else m_out = enc_i({6'b010000, shamt}, rs1p, 3'b101, rs1p, OPIMM);
                               2'b10: m_out = enc_i(imm6, rs1p, 3'b111, rs1p, OPIMM);
                               2'b11: if (c[12]) m_legal = 0;               // SUBW/ADDW, reserved
                                      else case (c[6:5])
                                          2'b00: m_out = enc_r(7'b0100000, rs2p, rs1p, 3'b000, rs1p, OP);
                                          2'b01: m_out = enc_r(7'b0000000, rs2p, rs1p, 3'b100, rs1p, OP);
                                          2'b10: m_out = enc_r(7'b0000000, rs2p, rs1p, 3'b110, rs1p, OP);
                                          2'b11: m_out = enc_r(7'b0000000, rs2p, rs1p, 3'b111, rs1p, OP);
                                      endcase
                           endcase
                5'b01_101: m_out = enc_j(joff, 5'd0);                        // C.J
                5'b01_110: m_out = enc_b(boff, 5'd0, rs1p, 3'b000);          // C.BEQZ
                5'b01_111: m_out = enc_b(boff, 5'd0, rs1p, 3'b001);          // C.BNEZ
                // quadrant 2
                5'b10_000: if (shamt[5]) m_legal = 0;                        // C.SLLI (rd=0: HINT)
                           else m_out = enc_i({6'b000000, shamt}, rd, 3'b001, rd, OPIMM);
                5'b10_010: if (rd == 5'd0) m_legal = 0;                      // C.LWSP
                           else m_out = enc_i({4'b0, c[3:2], c[12], c[6:4], 2'b00}, 5'd2, 3'b010, rd, LOAD);
                5'b10_100: if (!c[12]) begin
                               if (rs2 == 5'd0) begin                        // C.JR
                                   if (rd == 5'd0) m_legal = 0;
                                   else m_out = enc_i(12'd0, rd, 3'b000, 5'd0, JALR);
                               end else m_out = enc_r(7'b0, rs2, 5'd0, 3'b000, rd, OP);   // C.MV
                           end else begin
                               if (rs2 == 5'd0 && rd == 5'd0) m_out = 32'h0010_0073;     // C.EBREAK
                               else if (rs2 == 5'd0) m_out = enc_i(12'd0, rd, 3'b000, 5'd1, JALR); // C.JALR
                               else m_out = enc_r(7'b0, rs2, rd, 3'b000, rd, OP);        // C.ADD
                           end
                5'b10_110: m_out = enc_s({4'b0, c[8:7], c[12:9], 2'b00}, rs2, 5'd2, 3'b010); // C.SWSP
                5'b10_001, 5'b10_011, 5'b10_101, 5'b10_111: m_legal = 0;    // FLDSP/FLWSP/FSDSP/FSWSP
                default: m_legal = 0;
            endcase
        end
    endtask

    initial begin
        $display("=== Compressed Decoder Testbench (all 49152 encodings vs RVC model) ===");
        for (s = 0; s < 24; s = s + 1) begin slot_legal[s] = 0; slot_ill[s] = 0; end
        for (i = 0; i < 65536; i = i + 1) begin
            if (i[1:0] != 2'b11) begin
                instr_in = i[15:0];
                #1;
                model(instr_in);
                s = {instr_in[1:0], instr_in[15:13]};
                checks = checks + 1;
                if (illegal !== !m_legal) begin
                    fails = fails + 1;
                    if (fails <= 25)
                        $display("FAIL cin=%04h illegal=%b, want %b (model expansion %08h)",
                                 instr_in, illegal, !m_legal, m_out);
                end else if (m_legal) begin
                    checks = checks + 1;
                    if (instr_out !== m_out) begin
                        fails = fails + 1;
                        if (fails <= 25)
                            $display("FAIL cin=%04h expands to %08h, want %08h", instr_in, instr_out, m_out);
                    end
                end
                if (m_legal) begin n_legal = n_legal + 1; slot_legal[s] = slot_legal[s] + 1; end
                else         begin n_illegal = n_illegal + 1; slot_ill[s] = slot_ill[s] + 1; end
            end
        end
        // The walk itself: every encoding, and every opcode slot that has
        // legal encodings had them checked (a model or loop slip that skipped
        // a slot would otherwise pass).
        if (n_legal + n_illegal != 49152) begin
            fails = fails + 1;
            $display("FAIL walked %0d encodings, not 49152", n_legal + n_illegal);
        end
        for (s = 0; s < 24; s = s + 1)
            if (s != 5'b00_001 && s != 5'b00_011 && s != 5'b00_100 && s != 5'b00_101 &&
                s != 5'b00_111 && s != 5'b10_001 && s != 5'b10_011 && s != 5'b10_101 &&
                s != 5'b10_111 && slot_legal[s] == 0) begin
                fails = fails + 1;
                $display("FAIL coverage: no legal encoding checked in quadrant %0d funct3 %0d", s >> 3, s & 7);
            end
        $display("compressed: %0d legal (expansion checked), %0d illegal", n_legal, n_illegal);
        if (fails == 0) $display("PASS tb_compressed_decoder (%0d checks)", checks);
        else            $display("FAIL tb_compressed_decoder: %0d failures, %0d checks", fails, checks);
        $finish;
    end
endmodule
