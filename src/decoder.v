module decoder(
    input  wire [31:0] instIn,
    output wire [6:0]  opcode,
    output reg  [4:0]  rd,
    output reg  [4:0]  rs1,
    output reg  [4:0]  rs2,
    output reg  [2:0]  funct3,
    output reg  [6:0]  funct7
);
    assign opcode = instIn[6:0];

    always @(*) begin
        rd     = 5'b0;
        rs1    = 5'b0;
        rs2    = 5'b0;
        funct3 = 3'b0;
        funct7 = 7'b0;

        case (opcode)
            7'b0110011: begin // R-type (ADD, SUB, SLL, SLT, ... and M-ext)
                rd     = instIn[11:7];
                rs1    = instIn[19:15];
                rs2    = instIn[24:20];
                funct3 = instIn[14:12];
                funct7 = instIn[31:25];
            end

            7'b0010011: begin // I-type ALU (ADDI, SLTI, XORI, ORI, ANDI, SLLI, SRLI, SRAI)
                rd     = instIn[11:7];
                rs1    = instIn[19:15];
                funct3 = instIn[14:12];
                // funct7 needed for SLLI/SRLI/SRAI distinction
                if (instIn[14:12] == 3'b001 || instIn[14:12] == 3'b101)
                    funct7 = instIn[31:25];
            end

            7'b0000011: begin // Load (LB, LH, LW, LBU, LHU)
                rd     = instIn[11:7];
                rs1    = instIn[19:15];
                funct3 = instIn[14:12];
            end

            7'b0100011: begin // S-type (SB, SH, SW)
                rs1    = instIn[19:15];
                rs2    = instIn[24:20];
                funct3 = instIn[14:12];
            end

            7'b1100011: begin // B-type (BEQ, BNE, BLT, BGE, BLTU, BGEU)
                rs1    = instIn[19:15];
                rs2    = instIn[24:20];
                funct3 = instIn[14:12];
            end

            7'b0110111: begin // LUI
                rd = instIn[11:7];
            end

            7'b0010111: begin // AUIPC
                rd = instIn[11:7];
            end

            7'b1101111: begin // JAL
                rd = instIn[11:7];
            end

            7'b1100111: begin // JALR
                rd     = instIn[11:7];
                rs1    = instIn[19:15];
                funct3 = instIn[14:12];
            end

            7'b1110011: begin // SYSTEM (ECALL, EBREAK, MRET, CSR ops)
                rd     = instIn[11:7];
                rs1    = instIn[19:15]; // also zimm for CSRxI
                funct3 = instIn[14:12];
                funct7 = instIn[31:25]; // upper bits for ECALL/EBREAK/MRET
            end

            7'b0001111: begin // FENCE / FENCE.I
                funct3 = instIn[14:12];
            end

            7'b0101111: begin // A-extension (AMO)
                rd     = instIn[11:7];
                rs1    = instIn[19:15];
                rs2    = instIn[24:20];
                funct3 = instIn[14:12];
                funct7 = instIn[31:25]; // funct5 + aq + rl
            end

            default: begin
                rd     = 5'b0;
                rs1    = 5'b0;
                rs2    = 5'b0;
                funct3 = 3'b0;
                funct7 = 7'b0;
            end
        endcase
    end
endmodule

// The registers an instruction reads, from its raw fetched bits. fyracore puts
// them on the register file's read addresses on the cycle IF/EX takes the
// instruction: the register file reads synchronously, so its data is there on
// the instruction's first cycle in EX.
//
// For a 32-bit instruction these are the rs1/rs2 fields decoder reads. For a
// compressed one they are the registers its expansion (compressed_decoder)
// reads, taken from the 16-bit encoding without expanding it. Only a field the
// expansion has must be right: EX masks each read with decoder's rs1/rs2, which
// are x0 for a format without that field, so those formats get whatever the
// shared logic gives. Its testbench checks this against decoder and
// compressed_decoder for every legal compressed encoding.
module rf_fields(
    input  wire [31:0] instr,
    output wire [4:0]  rs1,
    output wire [4:0]  rs2
);
    wire [1:0] q  = instr[1:0];
    wire [2:0] f3 = instr[15:13];
    // Quadrant 0: C.ADDI4SPN reads sp, C.LW/C.SW rs1'. Quadrant 1: C.ADDI and
    // C.ADDI16SP read rd, the funct3 = 1xx ones (shifts, C.ANDI, C.SUB..C.AND,
    // C.BEQZ/C.BNEZ) rs1'. Quadrant 2: C.LWSP/C.SWSP read sp; C.SLLI, C.JR,
    // C.JALR and C.ADD read rd.
    wire sp    = (q == 2'b00) ? !f3[1] : (q == 2'b10) && f3[1];
    wire prime = (q == 2'b00) ?  f3[1] : (q == 2'b01) && f3[2];
    assign rs1 = (q == 2'b11) ? instr[19:15] :
                 sp           ? 5'd2 :
                 prime        ? {2'b01, instr[9:7]} : instr[11:7];
    // C.SW and quadrant 1's C.SUB..C.AND read rs2'; quadrant 2's C.MV, C.ADD
    // and C.SWSP the full rs2 field.
    assign rs2 = (q == 2'b11) ? instr[24:20] :
                 (q == 2'b10) ? instr[6:2]   : {2'b01, instr[4:2]};
endmodule
