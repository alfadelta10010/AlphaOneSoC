module branchCtrl(
    input  wire [2:0]  funct3,
    input  wire [31:0] r1,
    input  wire [31:0] r2,
    output reg         branchValid
);
    wire [32:0] sub33 = {1'b0, r1} - {1'b0, r2};
    wire eq          = (sub33[31:0] == 32'b0);
    wire lt_signed   = (r1[31] != r2[31]) ? r1[31] : sub33[32];
    wire lt_unsigned = sub33[32];

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
