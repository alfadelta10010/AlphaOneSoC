module alu(
    input  wire [31:0] d1,
    input  wire [31:0] d2,
    output reg  [31:0] result,
    input  wire [4:0]  control
);
    // Signed interpretations
    wire signed [31:0] d1s = $signed(d1);
    wire signed [31:0] d2s = $signed(d2);

    // Arithmetic shift right
    wire [31:0] sra_result = $signed(d1s) >>> d2[4:0];

    // Comparison (for SLT/SLTU)
    wire [32:0] sub33 = {1'b0, d1} - {1'b0, d2};
    wire lt_unsigned = sub33[32];
    wire lt_signed   = (d1[31] != d2[31]) ? d1[31] : sub33[32];

    always @(*) begin
        case (control)
            // RV32I ALU operations
            5'b00000: result = d1 + d2;                 // ADD
            5'b00001: result = d1 << d2[4:0];           // SLL
            5'b00010: result = {31'b0, lt_signed};      // SLT
            5'b00011: result = {31'b0, lt_unsigned};    // SLTU
            5'b00100: result = d1 ^ d2;                 // XOR
            5'b00101: result = d1 >> d2[4:0];           // SRL
            5'b00110: result = d1 | d2;                 // OR
            5'b00111: result = d1 & d2;                 // AND
            5'b01000: result = d1 - d2;                 // SUB
            5'b01101: result = sra_result;              // SRA
            // 5'b10xxx: M-extension — handled by muldiv.v (not here)
            default:  result = 32'b0;
        endcase
    end
endmodule
