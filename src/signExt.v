module signExt(
    input  wire [6:0]  opcode,
    input  wire [31:0] instIn,
    output reg  [31:0] immOut
);
    always @(*) begin
        case (opcode)
            7'b0110111, // LUI
            7'b0010111: // AUIPC
                immOut = {instIn[31:12], 12'b0};

            7'b1101111: // JAL (J-type)
                immOut = {{12{instIn[31]}}, instIn[19:12], instIn[20], instIn[30:21], 1'b0};

            7'b1100111: // JALR (I-type)
                immOut = {{20{instIn[31]}}, instIn[31:20]};

            7'b1100011: // B-type (branches)
                immOut = {{20{instIn[31]}}, instIn[7], instIn[30:25], instIn[11:8], 1'b0};

            7'b0000011: // Load (I-type)
                immOut = {{20{instIn[31]}}, instIn[31:20]};

            7'b0010011: // I-type ALU
                begin
                    if (instIn[14:12] == 3'b001 || instIn[14:12] == 3'b101)
                        immOut = {27'b0, instIn[24:20]}; // Shift amount (zero-extended)
                    else
                        immOut = {{20{instIn[31]}}, instIn[31:20]};
                end

            7'b0100011: // S-type (stores)
                immOut = {{20{instIn[31]}}, instIn[31:25], instIn[11:7]};

            7'b1110011: // SYSTEM (CSR address is handled separately)
                immOut = {27'b0, instIn[19:15]}; // zimm for CSR immediate instructions

            7'b0001111: // FENCE / FENCE.I
                immOut = 32'b0;

            default:
                immOut = 32'b0;
        endcase
    end
endmodule
