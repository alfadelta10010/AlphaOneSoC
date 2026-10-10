// The core's one comparator: r1 - r2 decides a branch, and the same
// subtractor gives the ALU its SUB, SLT(I) and SLTU(I) results (fyracore
// feeds r2 = rs2 for a branch, the ALU's second operand otherwise). A branch
// never needs the ALU's SUB/SLT in the same cycle -- the ALU computes the
// branch target then -- so one subtractor serves both.
module branchCtrl(
    input  wire [2:0]  funct3,
    input  wire [31:0] r1,
    input  wire [31:0] r2,
    output reg         branchValid,
    // For the ALU
    output wire [31:0] diff,         // r1 - r2
    output wire        lt_signed,
    output wire        lt_unsigned
);
    wire [32:0] sub33 = {1'b0, r1} - {1'b0, r2};
    wire eq          = (sub33[31:0] == 32'b0);
    assign lt_signed   = (r1[31] != r2[31]) ? r1[31] : sub33[32];
    assign lt_unsigned = sub33[32];
    assign diff        = sub33[31:0];

    // funct3 encoding matches RISC-V spec
    always @(*) begin
        case (funct3)
            3'b000:  branchValid =  eq;           // BEQ
            3'b001:  branchValid = !eq;            // BNE
            3'b100:  branchValid =  lt_signed;     // BLT
            3'b101:  branchValid = !lt_signed;     // BGE
            3'b110:  branchValid =  lt_unsigned;   // BLTU
            3'b111:  branchValid = !lt_unsigned;   // BGEU
            default: branchValid = 1'b0;
        endcase
    end
endmodule
