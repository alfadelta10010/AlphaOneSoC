// Multi-cycle multiply/divide unit -- RV32M extension, and the core's shifter
//
// All eight M-extension operations run through one FSM around a single
// 34-bit adder/subtractor and one 33+32-bit shift register pair. A separate
// multiply and divide datapath, each with its own adder and operand/result
// negators, cost about twice the area for operations that in the SoC finish
// behind the next instruction fetch anyway.
//
// The RV32I shifts (SLL/SRL/SRA and their immediate forms) use the same
// shift register, one bit per cycle, instead of a 32-bit barrel shifter in
// the ALU: 2 + shamt cycles, again behind the next fetch in the SoC.
//
// Multiply (MUL/MULH/MULHSU/MULHU): signed-aware shift-and-add. The
// multiplicand is sign-extended into the 33-bit accumulator when it is
// signed, and the last step subtracts instead of adds when the multiplier is
// signed (its bit 31 has weight -2^31), so no operand or result negation is
// needed. 1 + 32 + 1 cycles from start to done.
//
// Divide (DIV/DIVU/REM/REMU): restoring division on magnitudes. The operand
// negations (S_NEGA, S_NEGB) and the result negation (S_FIX) go through the
// same adder. 1 + 2 + 32 + 1 cycles. Division by zero and signed overflow
// fall out of the datapath with the results RV32M requires:
//   x / 0      -> quotient all ones (-1), remainder x
//   INT_MIN/-1 -> quotient INT_MIN, remainder 0
//
// op encoding matches controller aluOp[2:0] when aluOp[4:3] == 2'b10:
//   3'b000  MUL      3'b100  DIV
//   3'b001  MULH     3'b101  DIVU
//   3'b010  MULHSU   3'b110  REM
//   3'b011  MULHU    3'b111  REMU
// With shift = 1, op[2] picks the direction (0 SLL, 1 SRL/SRA, as in aluOp)
// and sra the arithmetic right shift; b[4:0] is the shift amount.
//
// Handshake:
//   Caller asserts start for one cycle.  busy is asserted the following cycle
//   and held until the result is ready.  done is a one-cycle pulse concurrent
//   with busy deasserting; result is valid from that cycle until the next start.

module muldiv (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,       // one-cycle pulse to begin
    input  wire [2:0]  op,          // operation select (see above)
    input  wire        shift,       // a shift, not an M operation
    input  wire        sra,         // ... arithmetic right
    input  wire [31:0] a,           // operand A (dividend / multiplicand)
    input  wire [31:0] b,           // operand B (divisor / multiplier)
    output wire [31:0] result,      // computed result (valid from done)
    output reg         busy,        // 1 while computing
    output reg         done         // one-cycle result-valid pulse
);

    localparam S_IDLE = 3'd0,
               S_NEGA = 3'd1,       // divide: |dividend|
               S_NEGB = 3'd2,       // divide: |divisor|
               S_LOOP = 3'd3,       // 32 iterations
               S_FIX  = 3'd4,       // select / negate the result
               S_SH   = 3'd5;       // shift one bit per cycle

    reg [2:0]  st;
    reg [4:0]  cnt;
    reg [32:0] acc;     // multiply: high product; divide: partial remainder
    reg [31:0] lo;      // multiplier -> low product; dividend -> quotient; result
    reg [31:0] m;       // multiplicand / divisor
    reg        isdiv;   // the operation is a divide
    reg        sa;      // multiplicand is signed
    reg        sb;      // multiplier is signed
    reg        hi;      // return the high word (MULH*) / the remainder (REM*)
    reg        na, nb;  // divide: dividend / divisor was negative
    reg        shr;     // shift: right (else left)
    reg        fill;    // shift: the bit shifted in at the top (SRA)

    assign result = lo;

    wire [32:0] mext   = {sa & m[31], m};
    wire [32:0] trial  = {acc[31:0], lo[31]};
    wire        mzero  = (m == 32'b0);
    // Quotient sign: negative when exactly one operand was, except for a
    // zero divisor (the all-ones quotient stands). Remainder sign: the
    // dividend's.
    wire        negres = isdiv & (hi ? na : ((na ^ nb) & ~mzero));

    // The one adder: sum = X + Y, or X - Y when sub.
    reg  [33:0] X, Y;
    reg         sub;
    always @(*) begin
        X = 34'b0; Y = 34'b0; sub = 1'b0;
        case (st)
            S_NEGA: begin Y = {2'b0, lo}; sub = 1'b1; end
            S_NEGB: begin Y = {2'b0, m};  sub = 1'b1; end
            S_LOOP: if (isdiv) begin
                        X = {1'b0, trial}; Y = {2'b0, m}; sub = 1'b1;
                    end else begin
                        X = {acc[32], acc};
                        Y = lo[0] ? {mext[32], mext} : 34'b0;
                        sub = (cnt == 5'd31) & sb;
                    end
            S_FIX:  begin Y = {2'b0, hi ? acc[31:0] : lo}; sub = negres; end
            default: ;
        endcase
    end
    wire [33:0] sum = X + (Y ^ {34{sub}}) + {33'b0, sub};

    always @(posedge clk) begin
        done <= 1'b0;   // default: done is a one-cycle pulse
        if (rst) begin
            st   <= S_IDLE;
            busy <= 1'b0;
        end else case (st)
            S_IDLE: if (start) begin
                busy  <= 1'b1;
                cnt   <= 5'd0;
                acc   <= 33'b0;
                isdiv <= op[2] & ~shift;
                if (shift) begin
                    // cnt counts up from 31 - shamt; the shift is done at 31
                    lo   <= a;
                    cnt  <= ~b[4:0];
                    shr  <= op[2];
                    fill <= sra & a[31];
                    st   <= S_SH;
                end else if (op[2]) begin
                    // DIV/REM are signed, DIVU/REMU (op[0] = 1) are not
                    lo <= a; m <= b;
                    na <= ~op[0] & a[31];
                    nb <= ~op[0] & b[31];
                    hi <= op[1];            // REM/REMU return the remainder
                    st <= S_NEGA;
                end else begin
                    // multiplicand a (signed for MULH, MULHSU),
                    // multiplier b (signed for MULH)
                    m  <= a; lo <= b;
                    sa <= (op == 3'd1) | (op == 3'd2);
                    sb <= (op == 3'd1);
                    hi <= (op != 3'd0);
                    na <= 1'b0; nb <= 1'b0;
                    st <= S_LOOP;
                end
            end
            S_NEGA: begin if (na) lo <= sum[31:0]; st <= S_NEGB; sa <= 1'b0; end
            S_NEGB: begin if (nb) m  <= sum[31:0]; st <= S_LOOP; end
            S_LOOP: begin
                if (isdiv) begin
                    // restoring step: keep the trial remainder on a borrow
                    acc <= sum[33] ? {1'b0, trial[31:0]} : {1'b0, sum[31:0]};
                    lo  <= {lo[30:0], ~sum[33]};
                end else begin
                    // shift the 66-bit {acc, lo} right with the new sum on top
                    acc <= sum[33:1];
                    lo  <= {sum[0], lo[31:1]};
                end
                cnt <= cnt + 5'd1;
                if (cnt == 5'd31) st <= S_FIX;
            end
            S_FIX: begin
                lo   <= sum[31:0];
                busy <= 1'b0;
                done <= 1'b1;
                st   <= S_IDLE;
            end
            S_SH: begin
                if (cnt == 5'd31) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    st   <= S_IDLE;
                end else begin
                    lo  <= shr ? {fill, lo[31:1]} : {lo[30:0], 1'b0};
                    cnt <= cnt + 5'd1;
                end
            end
            default: st <= S_IDLE;
        endcase
    end

endmodule
