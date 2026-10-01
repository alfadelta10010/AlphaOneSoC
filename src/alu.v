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
    // One shifter for all three shifts: a right shifter with a fill bit
    // (d1[31] for SRA, 0 otherwise), and SLL done as a right shift of the
    // bit-reversed operand, reversed back. The reversals are wiring.
    function [31:0] rev(input [31:0] x);
        integer k;
        begin
            for (k = 0; k < 32; k = k + 1) rev[k] = x[31-k];
        end
    endfunction
    wire        is_sll = (control == 5'b00001);
    wire        fill   = (control == 5'b01101) & d1[31];
    wire [31:0] sh_in  = is_sll ? rev(d1) : d1;
    wire [31:0] sh_out = $signed({fill, sh_in}) >>> d2[4:0];
    wire [31:0] shres  = is_sll ? rev(sh_out) : sh_out;

    always @(*) begin
        case (control)
            // RV32I ALU operations
            5'b00000: result = d1 + d2;                 // ADD
            5'b00001: result = shres;                   // SLL
            5'b00010: result = {31'b0, lt_signed};      // SLT
            5'b00011: result = {31'b0, lt_unsigned};    // SLTU
            5'b00100: result = d1 ^ d2;                 // XOR
            5'b00101: result = shres;                   // SRL
            5'b00110: result = d1 | d2;                 // OR
            5'b00111: result = d1 & d2;                 // AND
            5'b01000: result = sub_res;                 // SUB
            5'b01101: result = shres;                   // SRA
            // 5'b10xxx: M-extension — handled by muldiv.v (not here)
            default:  result = 32'b0;
        endcase
    end
endmodule
