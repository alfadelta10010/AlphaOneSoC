module controller(
    input  wire [6:0] opcode,
    input  wire [2:0] funct3,
    input  wire [6:0] funct7,
    // Register file
    output reg        regWR,
    // ALU
    output reg  [4:0] aluOp,
    output reg        aluSrc1,    // 0=rs1, 1=PC
    output reg        aluSrc2,    // 0=imm, 1=rs2
    // Memory
    output reg        memRD,
    output reg        memWR,
    output reg  [1:0] memSize,    // 00=byte, 01=half, 10=word
    output reg        memUnsigned,
    // Writeback
    output reg  [1:0] wbSel,      // 00=ALU, 01=MEM, 10=PC_NEXT, 11=CSR
    // Branch/Jump
    output reg        doBranch,
    output reg        doJump,
    // CSR
    output reg  [1:0] csrOp,      // 00=none, 01=RW, 10=RS, 11=RC
    output reg        csrSrc,     // 0=rs1, 1=zimm
    // A-extension
    output reg        isAmo,
    output reg        isLR,
    output reg        isSC,
    output reg  [4:0] amoOp,
    // System
    output reg        isEcall,
    output reg        isEbreak,
    output reg        isMret,
    output reg        isFence,
    output reg        isFenceI,
    output reg        isMulDiv,   // 1 for all RV32M operations (routes to muldiv unit)
    output reg        illegal
);
    always @(*) begin
        // Defaults: NOP-like
        regWR       = 1'b0;
        aluOp       = 5'b00000;
        aluSrc1     = 1'b0;
        aluSrc2     = 1'b0;
        memRD       = 1'b0;
        memWR       = 1'b0;
        memSize     = 2'b10;
        memUnsigned = 1'b0;
        wbSel       = 2'b00;
        doBranch    = 1'b0;
        doJump      = 1'b0;
        csrOp       = 2'b00;
        csrSrc      = 1'b0;
        isAmo       = 1'b0;
        isLR        = 1'b0;
        isSC        = 1'b0;
        amoOp       = 5'b0;
        isEcall     = 1'b0;
        isEbreak    = 1'b0;
        isMret      = 1'b0;
        isFence     = 1'b0;
        isFenceI    = 1'b0;
        isMulDiv    = 1'b0;
        illegal     = 1'b0;

        case (opcode)
            // ===== R-type =====
            7'b0110011: begin
                regWR   = 1'b1;
                wbSel   = 2'b00;
                aluSrc1 = 1'b0; // rs1
                aluSrc2 = 1'b1; // rs2
                if (funct7 == 7'b0000001) begin
                    // M-extension: route to muldiv unit
                    isMulDiv = 1'b1;
                    aluOp    = {2'b10, funct3};
                end else if (funct7 == 7'b0000000) begin
                    aluOp = {2'b00, funct3};
                end else if (funct7 == 7'b0100000) begin
                    // SUB (f3=000) or SRA (f3=101)
                    if (funct3 == 3'b000 || funct3 == 3'b101)
                        aluOp = {2'b01, funct3};
                    else
                        illegal = 1'b1;
                end else begin
                    illegal = 1'b1;
                end
            end

            // ===== I-type ALU =====
            7'b0010011: begin
                regWR   = 1'b1;
                wbSel   = 2'b00;
                aluSrc1 = 1'b0; // rs1
                aluSrc2 = 1'b0; // imm
                case (funct3)
                    3'b001: begin // SLLI
                        if (funct7 == 7'b0000000)
                            aluOp = 5'b00001;
                        else
                            illegal = 1'b1;
                    end
                    3'b101: begin // SRLI / SRAI
                        if (funct7 == 7'b0000000)
                            aluOp = 5'b00101; // SRLI
                        else if (funct7 == 7'b0100000)
                            aluOp = 5'b01101; // SRAI
                        else
                            illegal = 1'b1;
                    end
                    default: aluOp = {2'b00, funct3};
                endcase
            end

            // ===== Load =====
            7'b0000011: begin
                regWR   = 1'b1;
                memRD   = 1'b1;
                wbSel   = 2'b01; // MEM
                aluOp   = 5'b00000; // ADD for address
                aluSrc1 = 1'b0; // rs1
                aluSrc2 = 1'b0; // imm
                case (funct3)
                    3'b000:  begin memSize = 2'b00; memUnsigned = 1'b0; end // LB
                    3'b001:  begin memSize = 2'b01; memUnsigned = 1'b0; end // LH
                    3'b010:  begin memSize = 2'b10; memUnsigned = 1'b0; end // LW
                    3'b100:  begin memSize = 2'b00; memUnsigned = 1'b1; end // LBU
                    3'b101:  begin memSize = 2'b01; memUnsigned = 1'b1; end // LHU
                    default: begin
                        illegal = 1'b1;
                        regWR   = 1'b0;  // no destination write
                        memRD   = 1'b0;  // and no access, so no address exception
                    end
                endcase
            end

            // ===== Store =====
            7'b0100011: begin
                memWR   = 1'b1;
                aluOp   = 5'b00000; // ADD for address
                aluSrc1 = 1'b0; // rs1
                aluSrc2 = 1'b0; // imm
                case (funct3)
                    3'b000:  memSize = 2'b00; // SB
                    3'b001:  memSize = 2'b01; // SH
                    3'b010:  memSize = 2'b10; // SW
                    default: begin
                        illegal = 1'b1;
                        memWR   = 1'b0;  // no access, so no address exception
                    end
                endcase
            end

            // ===== Branch =====
            7'b1100011: begin
                doBranch = 1'b1;
                aluSrc1  = 1'b1; // PC
                aluSrc2  = 1'b0; // imm (branch offset)
                aluOp    = 5'b00000; // ADD (PC + offset)
                case (funct3)
                    3'b000, 3'b001, 3'b100, 3'b101, 3'b110, 3'b111: ; // valid
                    default: illegal = 1'b1;
                endcase
            end

            // ===== LUI =====
            7'b0110111: begin
                regWR   = 1'b1;
                wbSel   = 2'b00;
                aluOp   = 5'b00000; // ADD (0 + imm)
                aluSrc1 = 1'b0;     // rs1 (x0 via decoder)
                aluSrc2 = 1'b0;     // imm
            end

            // ===== AUIPC =====
            7'b0010111: begin
                regWR   = 1'b1;
                wbSel   = 2'b00;
                aluOp   = 5'b00000; // ADD (PC + imm)
                aluSrc1 = 1'b1;     // PC
                aluSrc2 = 1'b0;     // imm
            end

            // ===== JAL =====
            7'b1101111: begin
                regWR   = 1'b1;
                wbSel   = 2'b10;    // PC_NEXT (link address)
                aluOp   = 5'b00000; // ADD (PC + offset)
                aluSrc1 = 1'b1;     // PC
                aluSrc2 = 1'b0;     // imm
                doJump  = 1'b1;
            end

            // ===== JALR =====
            7'b1100111: begin
                regWR   = 1'b1;
                wbSel   = 2'b10;    // PC_NEXT (link address)
                aluOp   = 5'b00000; // ADD (rs1 + offset)
                aluSrc1 = 1'b0;     // rs1
                aluSrc2 = 1'b0;     // imm
                doJump  = 1'b1;
                if (funct3 != 3'b000) begin
                    illegal = 1'b1;
                    regWR   = 1'b0;  // no link write
                    doJump  = 1'b0;  // and no jump, so no target exception
                end
            end

            // ===== SYSTEM (CSR, ECALL, EBREAK, MRET) =====
            7'b1110011: begin
                case (funct3)
                    3'b000: begin
                        // SYSTEM/funct3=000 instructions are distinguished by funct7:
                        //   ECALL:  funct7=0000000, rs2=00000 (refined in pipeline)
                        //   EBREAK: funct7=0000000, rs2=00001 (refined in pipeline)
                        //   MRET:   funct7=0011000, rs2=00010 (rd=0, rs1=0 checked in pipeline)
                        //   WFI:    funct7=0001000, rs2=00101 (NOP in M-mode, legal per spec)
                        // All other funct7 values are reserved → illegal. Within
                        // the MRET and WFI families the pipeline also rejects
                        // the wrong rs2 (SRET and reserved encodings).
                        // Full rd/rs1/rs2 validation is done in the pipeline where those fields
                        // are available.
                        if (funct7 == 7'b0000000) begin
                            isEcall  = 1'b1;
                            isEbreak = 1'b1; // Both set; pipeline disambiguates via rs2 field
                        end
                        else if (funct7 == 7'b0011000)
                            isMret = 1'b1;
                        else if (funct7 == 7'b0001000)
                            ;              // WFI family; exact encoding checked in the pipeline
                        else
                            illegal = 1'b1;
                    end
                    3'b001: begin // CSRRW
                        regWR  = 1'b1;
                        wbSel  = 2'b11;
                        csrOp  = 2'b01;
                        csrSrc = 1'b0;
                    end
                    3'b010: begin // CSRRS
                        regWR  = 1'b1;
                        wbSel  = 2'b11;
                        csrOp  = 2'b10;
                        csrSrc = 1'b0;
                    end
                    3'b011: begin // CSRRC
                        regWR  = 1'b1;
                        wbSel  = 2'b11;
                        csrOp  = 2'b11;
                        csrSrc = 1'b0;
                    end
                    3'b101: begin // CSRRWI
                        regWR  = 1'b1;
                        wbSel  = 2'b11;
                        csrOp  = 2'b01;
                        csrSrc = 1'b1;
                    end
                    3'b110: begin // CSRRSI
                        regWR  = 1'b1;
                        wbSel  = 2'b11;
                        csrOp  = 2'b10;
                        csrSrc = 1'b1;
                    end
                    3'b111: begin // CSRRCI
                        regWR  = 1'b1;
                        wbSel  = 2'b11;
                        csrOp  = 2'b11;
                        csrSrc = 1'b1;
                    end
                    default: illegal = 1'b1;
                endcase
            end

            // ===== FENCE / FENCE.I =====
            7'b0001111: begin
                if (funct3 == 3'b000)
                    isFence = 1'b1;
                else if (funct3 == 3'b001)
                    isFenceI = 1'b1;
                else
                    illegal = 1'b1;
            end

            // ===== A-extension (AMO) =====
            7'b0101111: begin
                if (funct3 != 3'b010) begin
                    illegal = 1'b1; // Only .W (funct3=010) supported in RV32A
                end else begin
                    aluOp   = 5'b00000; // ADD for address (rs1 + 0)
                    aluSrc1 = 1'b0;     // rs1
                    aluSrc2 = 1'b0;     // imm (0)
                    memSize = 2'b10;    // Word
                    amoOp   = funct7[6:2]; // funct5

                    case (funct7[6:2])
                        5'b00010: begin // LR.W
                            isLR  = 1'b1;
                            regWR = 1'b1;
                            memRD = 1'b1;
                            wbSel = 2'b01;
                        end
                        5'b00011: begin // SC.W
                            isSC  = 1'b1;
                            regWR = 1'b1;
                            memWR = 1'b1; // Conditional, handled in pipeline
                            wbSel = 2'b00; // rd gets 0 (success) or 1 (fail)
                        end
                        5'b00001, // AMOSWAP
                        5'b00000, // AMOADD
                        5'b00100, // AMOXOR
                        5'b01100, // AMOAND
                        5'b01000, // AMOOR
                        5'b10000, // AMOMIN
                        5'b10100, // AMOMAX
                        5'b11000, // AMOMINU
                        5'b11100: begin // AMOMAXU
                            isAmo = 1'b1;
                            regWR = 1'b1;
                            memRD = 1'b1;
                            memWR = 1'b1;
                            wbSel = 2'b01;
                        end
                        default: illegal = 1'b1;
                    endcase
                end
            end

            default: begin
                illegal = 1'b1;
            end
        endcase
    end
endmodule
