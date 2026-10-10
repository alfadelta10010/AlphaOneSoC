module alu(
    input  wire [31:0] d1,
    input  wire [31:0] d2,
    // d1 - d2 and its two comparisons, from the shared comparator
    // (branchCtrl.v); fyracore wires it to these same operands whenever the
    // ALU result is used for SUB or SLT(I)(U).
    input  wire [31:0] sub_res,
    input  wire        lt_signed,
    input  wire        lt_unsigned,
    output reg  [31:0] result,
    input  wire [4:0]  control
);
    always @(*) begin
        case (control)
            // RV32I ALU operations
            5'b00000: result = d1 + d2;                 // ADD
            // SLL (00001), SRL (00101), SRA (01101): muldiv.v, serially
            5'b00010: result = {31'b0, lt_signed};      // SLT
            5'b00011: result = {31'b0, lt_unsigned};    // SLTU
            5'b00100: result = d1 ^ d2;                 // XOR
            5'b00110: result = d1 | d2;                 // OR
            5'b00111: result = d1 & d2;                 // AND
            5'b01000: result = sub_res;                 // SUB
            // 5'b10xxx: M-extension — handled by muldiv.v (not here)
            default:  result = 32'b0;
        endcase
    end
endmodule
