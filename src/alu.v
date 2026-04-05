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

    // M-extension: Multiplication (64-bit results)
    wire signed [63:0] mul_ss = $signed(d1) * $signed(d2);
    wire signed [63:0] mul_su = $signed(d1) * $signed({1'b0, d2});
    wire        [63:0] mul_uu = d1 * d2;

    // M-extension: Division with edge-case guards
    wire div_by_zero = (d2 == 32'b0);
    wire div_overflow = (d1 == 32'h80000000) && (d2 == 32'hFFFFFFFF);

    reg signed [31:0] div_s;
    reg        [31:0] div_u;
    reg signed [31:0] rem_s;
    reg        [31:0] rem_u;

    always @(*) begin
        if (div_by_zero || div_overflow) begin
            div_s = 32'sd0;
            rem_s = 32'sd0;
        end else begin
            div_s = d1s / d2s;
            rem_s = d1s % d2s;
        end
        if (div_by_zero) begin
            div_u = 32'd0;
            rem_u = 32'd0;
        end else begin
            div_u = d1 / d2;
            rem_u = d1 % d2;
        end
    end

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
            // RV32M multiply
            5'b10000: result = mul_ss[31:0];            // MUL
            5'b10001: result = mul_ss[63:32];           // MULH
            5'b10010: result = mul_su[63:32];           // MULHSU
            5'b10011: result = mul_uu[63:32];           // MULHU
            // RV32M divide
            5'b10100: result = div_by_zero ? 32'hFFFFFFFF :
                               div_overflow ? 32'h80000000 : div_s;   // DIV
            5'b10101: result = div_by_zero ? 32'hFFFFFFFF : div_u;    // DIVU
            5'b10110: result = div_by_zero ? d1 :
                               div_overflow ? 32'b0 : rem_s;          // REM
            5'b10111: result = div_by_zero ? d1 : rem_u;              // REMU
            default:  result = 32'b0;
        endcase
    end
endmodule
