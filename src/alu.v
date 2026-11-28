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
    // Shifts (SLL 00001, SRL 00101, SRA 01101): one right barrel shifter, the
    // operand and the result bit-reversed for SLL, so a left shift costs two
    // rows of wiring and a 2:1 mux each side instead of its own shifter.
    // control[2] = 1 shifts right, control[3] = 1 fills with d1[31] (SRA);
    // the shift amount is d2[4:0].
    wire        sh_left = ~control[2];
    reg  [31:0] sh_rev_in, sh_rev_out;
    wire [31:0] sh_in   = sh_left ? sh_rev_in : d1;
    wire [32:0] sh_ext  = {control[3] & d1[31], sh_in};
    wire [32:0] sh_ars  = $signed(sh_ext) >>> d2[4:0];
    wire [31:0] shres   = sh_left ? sh_rev_out : sh_ars[31:0];
    integer     bi;
    always @(*) begin
        for (bi = 0; bi < 32; bi = bi + 1) begin
            sh_rev_in[bi]  = d1[31 - bi];
            sh_rev_out[bi] = sh_ars[31 - bi];
        end
    end

    always @(*) begin
        case (control)
            // RV32I ALU operations
            5'b00000: result = d1 + d2;                 // ADD
            5'b00001, 5'b00101, 5'b01101: result = shres;   // SLL, SRL, SRA
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
