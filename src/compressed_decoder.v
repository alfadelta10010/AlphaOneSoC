// RV32C Compressed Instruction Decoder
// Expands 16-bit compressed instructions to 32-bit equivalents
module compressed_decoder(
    input  wire [15:0] instr_in,
    output reg  [31:0] instr_out,
    output reg         illegal
);
    // Compressed register mapping: cr' → x(8 + cr')
    wire [4:0] rd_p  = {2'b01, instr_in[4:2]};   // CIW/CL rd'
    wire [4:0] rs1_p = {2'b01, instr_in[9:7]};   // CL/CS/CA/CB rs1'
    wire [4:0] rs2_p = {2'b01, instr_in[4:2]};   // CS/CA rs2'

    // Full register fields (Quadrant 2)
    wire [4:0] rd_full  = instr_in[11:7];
    wire [4:0] rs2_full = instr_in[6:2];

    always @(*) begin
        instr_out = 32'h0000_0013; // Default: NOP (ADDI x0, x0, 0)
        illegal   = 1'b0;

        case (instr_in[1:0])
            // ============================================================
            // Quadrant 0
            // ============================================================
            2'b00: begin
                case (instr_in[15:13])
                    3'b000: begin // C.ADDI4SPN
                        // nzuimm = {inst[10:7], inst[12:11], inst[5], inst[6], 2'b00}
                        if (instr_in[12:5] == 8'b0)
                            illegal = 1'b1; // nzuimm must be non-zero
                        else begin
                            // ADDI rd', x2, nzuimm
                            instr_out = {
                                2'b0,
                                instr_in[10:7],  // nzuimm[9:6]
                                instr_in[12:11], // nzuimm[5:4]
                                instr_in[5],     // nzuimm[3]
                                instr_in[6],     // nzuimm[2]
                                2'b00,           // nzuimm[1:0]
                                5'd2,            // rs1 = x2 (sp)
                                3'b000,          // funct3 = ADDI
                                rd_p,            // rd = rd'
                                7'b0010011       // OP-IMM
                            };
                        end
                    end

                    3'b010: begin // C.LW
                        // uimm = {inst[5], inst[12:10], inst[6], 2'b00}
                        instr_out = {
                            5'b0,
                            instr_in[5],      // uimm[6]
                            instr_in[12:10],  // uimm[5:3]
                            instr_in[6],      // uimm[2]
                            2'b00,            // uimm[1:0]
                            rs1_p,            // rs1 = rs1'
                            3'b010,           // funct3 = LW
                            rd_p,             // rd = rd'
                            7'b0000011        // LOAD
                        };
                    end

                    3'b110: begin // C.SW
                        // uimm same encoding as C.LW
                        instr_out = {
                            5'b0,
                            instr_in[5],      // uimm[6]
                            instr_in[12],     // uimm[5]
                            rs2_p,            // rs2 = rs2'
                            rs1_p,            // rs1 = rs1'
                            3'b010,           // funct3 = SW
                            instr_in[11:10],  // uimm[4:3]
                            instr_in[6],      // uimm[2]
                            2'b00,            // uimm[1:0]
                            7'b0100011        // STORE
                        };
                    end

                    default: illegal = 1'b1;
                endcase
            end

            // ============================================================
            // Quadrant 1
            // ============================================================
            2'b01: begin
                case (instr_in[15:13])
                    3'b000: begin // C.NOP / C.ADDI
                        // ADDI rd, rd, nzimm
                        instr_out = {
                            {7{instr_in[12]}},  // imm[11:5] sign-ext
                            instr_in[6:2],       // imm[4:0]
                            rd_full,             // rs1 = rd
                            3'b000,              // funct3 = ADDI
                            rd_full,             // rd
                            7'b0010011           // OP-IMM
                        };
                    end

                    3'b001: begin // C.JAL (RV32 only)
                        // JAL x1, offset
                        instr_out = {
                            instr_in[12],                    // imm[20]
                            instr_in[8],                     // imm[10]
                            instr_in[10:9],                  // imm[9:8]
                            instr_in[6],                     // imm[7]
                            instr_in[7],                     // imm[6]
                            instr_in[2],                     // imm[5]
                            instr_in[11],                    // imm[4]
                            instr_in[5:3],                   // imm[3:1]
                            instr_in[12],                    // imm[11]
                            {8{instr_in[12]}},               // imm[19:12]
                            5'd1,                            // rd = x1 (ra)
                            7'b1101111                       // JAL
                        };
                    end

                    3'b010: begin // C.LI
                        // ADDI rd, x0, imm
                        instr_out = {
                            {7{instr_in[12]}},  // imm[11:5]
                            instr_in[6:2],       // imm[4:0]
                            5'd0,                // rs1 = x0
                            3'b000,              // funct3 = ADDI
                            rd_full,             // rd
                            7'b0010011           // OP-IMM
                        };
                    end

                    3'b011: begin
                        if (rd_full == 5'd2) begin // C.ADDI16SP
                            // ADDI x2, x2, nzimm
                            // nzimm = sext({inst[12], inst[4:3], inst[5], inst[2], inst[6], 4'b0})
                            if ({instr_in[12], instr_in[6:2]} == 6'b0)
                                illegal = 1'b1;
                            else
                                instr_out = {
                                    {3{instr_in[12]}},  // imm[11:9]
                                    instr_in[4:3],       // imm[8:7]
                                    instr_in[5],         // imm[6]
                                    instr_in[2],         // imm[5]
                                    instr_in[6],         // imm[4]
                                    4'b0000,             // imm[3:0]
                                    5'd2,                // rs1 = x2
                                    3'b000,              // ADDI
                                    5'd2,                // rd = x2
                                    7'b0010011           // OP-IMM
                                };
                        end else begin // C.LUI (rd != 2)
                            // LUI rd, nzimm.  rd=x0 with nzimm!=0 is a HINT
                            // (RVC HINT table) — expand it like any other C.LUI;
                            // LUI x0 retires with no architectural effect.
                            // nzimm=0 is reserved for every rd.
                            if ({instr_in[12], instr_in[6:2]} == 6'b0)
                                illegal = 1'b1;
                            else
                                instr_out = {
                                    {15{instr_in[12]}}, // imm[31:17]
                                    instr_in[6:2],       // imm[16:12]
                                    rd_full,             // rd
                                    7'b0110111           // LUI
                                };
                        end
                    end

                    3'b100: begin // ALU operations
                        case (instr_in[11:10])
                            2'b00: begin // C.SRLI
                                if (instr_in[12]) // shamt[5] must be 0 on RV32
                                    illegal = 1'b1;
                                else
                                    instr_out = {
                                        7'b0000000,
                                        instr_in[6:2],  // shamt
                                        rs1_p,
                                        3'b101,         // SRLI
                                        rs1_p,          // rd = rs1'
                                        7'b0010011
                                    };
                            end
                            2'b01: begin // C.SRAI
                                if (instr_in[12]) // shamt[5] must be 0 on RV32
                                    illegal = 1'b1;
                                else
                                    instr_out = {
                                        7'b0100000,
                                        instr_in[6:2],  // shamt
                                        rs1_p,
                                        3'b101,         // SRAI
                                        rs1_p,
                                        7'b0010011
                                    };
                            end
                            2'b10: begin // C.ANDI
                                instr_out = {
                                    {7{instr_in[12]}},
                                    instr_in[6:2],
                                    rs1_p,
                                    3'b111,         // ANDI
                                    rs1_p,
                                    7'b0010011
                                };
                            end
                            2'b11: begin // C.SUB, C.XOR, C.OR, C.AND
                                case ({instr_in[12], instr_in[6:5]})
                                    3'b000: // C.SUB
                                        instr_out = {7'b0100000, rs2_p, rs1_p, 3'b000, rs1_p, 7'b0110011};
                                    3'b001: // C.XOR
                                        instr_out = {7'b0000000, rs2_p, rs1_p, 3'b100, rs1_p, 7'b0110011};
                                    3'b010: // C.OR
                                        instr_out = {7'b0000000, rs2_p, rs1_p, 3'b110, rs1_p, 7'b0110011};
                                    3'b011: // C.AND
                                        instr_out = {7'b0000000, rs2_p, rs1_p, 3'b111, rs1_p, 7'b0110011};
                                    default: illegal = 1'b1;
                                endcase
                            end
                        endcase
                    end

                    3'b101: begin // C.J
                        // JAL x0, offset
                        instr_out = {
                            instr_in[12],
                            instr_in[8],
                            instr_in[10:9],
                            instr_in[6],
                            instr_in[7],
                            instr_in[2],
                            instr_in[11],
                            instr_in[5:3],
                            instr_in[12],
                            {8{instr_in[12]}},
                            5'd0,               // rd = x0
                            7'b1101111          // JAL
                        };
                    end

                    3'b110: begin // C.BEQZ
                        // BEQ rs1', x0, offset
                        instr_out = {
                            {4{instr_in[12]}},   // imm[12:9] sign-ext
                            instr_in[6:5],        // imm[8:7] → offset[7:6]
                            instr_in[2],          // imm[6] → offset[5]
                            5'd0,                 // rs2 = x0
                            rs1_p,                // rs1 = rs1'
                            3'b000,               // BEQ
                            instr_in[11:10],      // imm[4:3] → offset[4:3]
                            instr_in[4:3],        // imm[2:1] → offset[2:1]
                            instr_in[12],         // imm[11] sign bit
                            7'b1100011            // BRANCH
                        };
                    end

                    3'b111: begin // C.BNEZ
                        // BNE rs1', x0, offset
                        instr_out = {
                            {4{instr_in[12]}},
                            instr_in[6:5],
                            instr_in[2],
                            5'd0,
                            rs1_p,
                            3'b001,              // BNE
                            instr_in[11:10],
                            instr_in[4:3],
                            instr_in[12],
                            7'b1100011
                        };
                    end
                endcase
            end

            // ============================================================
            // Quadrant 2
            // ============================================================
            2'b10: begin
                case (instr_in[15:13])
                    3'b000: begin // C.SLLI
                        if (instr_in[12]) // shamt[5] must be 0 on RV32
                            illegal = 1'b1;
                        else
                            instr_out = {
                                7'b0000000,
                                instr_in[6:2],   // shamt
                                rd_full,          // rs1 = rd
                                3'b001,           // SLLI
                                rd_full,          // rd
                                7'b0010011
                            };
                    end

                    3'b010: begin // C.LWSP
                        if (rd_full == 5'd0)
                            illegal = 1'b1;
                        else begin
                            // LW rd, uimm(x2)
                            // uimm = {inst[3:2], inst[12], inst[6:4], 2'b00}
                            instr_out = {
                                4'b0,
                                instr_in[3:2],    // uimm[7:6]
                                instr_in[12],     // uimm[5]
                                instr_in[6:4],    // uimm[4:2]
                                2'b00,            // uimm[1:0]
                                5'd2,             // rs1 = x2 (sp)
                                3'b010,           // LW
                                rd_full,          // rd
                                7'b0000011        // LOAD
                            };
                        end
                    end

                    3'b100: begin
                        if (instr_in[12] == 1'b0) begin
                            if (rs2_full == 5'd0) begin // C.JR
                                if (rd_full == 5'd0)
                                    illegal = 1'b1;
                                else
                                    // JALR x0, rs1, 0
                                    instr_out = {12'b0, rd_full, 3'b000, 5'd0, 7'b1100111};
                            end else begin // C.MV
                                // ADD rd, x0, rs2
                                instr_out = {7'b0000000, rs2_full, 5'd0, 3'b000, rd_full, 7'b0110011};
                            end
                        end else begin
                            if (rs2_full == 5'd0 && rd_full == 5'd0) begin // C.EBREAK
                                instr_out = 32'h0010_0073;
                            end else if (rs2_full == 5'd0) begin // C.JALR
                                // JALR x1, rs1, 0
                                instr_out = {12'b0, rd_full, 3'b000, 5'd1, 7'b1100111};
                            end else begin // C.ADD
                                // ADD rd, rd, rs2
                                instr_out = {7'b0000000, rs2_full, rd_full, 3'b000, rd_full, 7'b0110011};
                            end
                        end
                    end

                    3'b110: begin // C.SWSP
                        // SW rs2, uimm(x2)
                        // uimm = {inst[8:7], inst[12:9], 2'b00}
                        instr_out = {
                            4'b0,
                            instr_in[8:7],     // uimm[7:6]
                            instr_in[12],      // uimm[5]
                            rs2_full,          // rs2
                            5'd2,              // rs1 = x2 (sp)
                            3'b010,            // SW
                            instr_in[11:9],    // uimm[4:2]
                            2'b00,             // uimm[1:0]
                            7'b0100011         // STORE
                        };
                    end

                    default: illegal = 1'b1;
                endcase
            end

            default: ; // bits [1:0] = 11 → not compressed (shouldn't reach here)
        endcase
    end
endmodule
