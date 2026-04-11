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
