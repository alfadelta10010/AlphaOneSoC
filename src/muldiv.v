// Multi-cycle multiply/divide unit — RV32M extension
//
// Replaces the combinational * / % operators from alu.v to eliminate the
// ~10,000-gate area hit on Sky 180nm.  All eight M-extension operations are
// handled by a single FSM that shares one 32-bit adder/subtractor.
//
// Multiply (MUL/MULH/MULHSU/MULHU):
//   Shift-right accumulate, 32 iterations + optional 1-cycle negate fixup.
//   Total: 33 cycles (unsigned) or 34 cycles (signed with negation).
//
// Divide (DIV/DIVU/REM/REMU):
//   Restoring division, 32 iterations + 1-cycle fixup.
//   Total: 34 cycles (including setup and fixup).
//   Division-by-zero and signed overflow handled per RV32M spec.
//
// op encoding matches controller aluOp[2:0] when aluOp[4:3] == 2'b10:
//   3'b000  MUL      3'b100  DIV
//   3'b001  MULH     3'b101  DIVU
//   3'b010  MULHSU   3'b110  REM
//   3'b011  MULHU    3'b111  REMU
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
    input  wire [31:0] a,           // operand A (dividend / multiplicand)
    input  wire [31:0] b,           // operand B (divisor / multiplier)
    output reg  [31:0] result,      // computed result (valid while done=1)
    output reg         busy,        // 1 while computing
    output reg         done         // one-cycle result-valid pulse
);

    // ── Operation codes ──────────────────────────────────────────────────────
    localparam OP_MUL    = 3'd0;
    localparam OP_MULH   = 3'd1;
    localparam OP_MULHSU = 3'd2;
    localparam OP_MULHU  = 3'd3;
    localparam OP_DIV    = 3'd4;
    localparam OP_DIVU   = 3'd5;
    localparam OP_REM    = 3'd6;
    localparam OP_REMU   = 3'd7;

    // ── FSM states ────────────────────────────────────────────────────────────
    localparam ST_IDLE   = 3'd0;
    localparam ST_MUL    = 3'd1;    // 32 shift-and-add iterations
    localparam ST_MFIXUP = 3'd2;    // negate 64-bit product (signed only)
    localparam ST_MOUT   = 3'd3;    // output multiply result
    localparam ST_DIV    = 3'd4;    // 32 restoring-division iterations
    localparam ST_DFIXUP = 3'd5;    // sign adjust + special-case handling

    reg [2:0] state;
    reg [5:0] count;    // iteration counter (0 – 31)

    // ── Multiply datapath ─────────────────────────────────────────────────────
    // Shift-right accumulate: the 64-bit product lives in {mul_p, mul_n}.
    //   mul_p : upper 32 bits (partial-product accumulator)
    //   mul_n : lower 32 bits (also serves as the multiplier shift register)
    //   mul_m : fixed multiplicand magnitude
    //
    // Each iteration:
    //   sum = mul_p + (mul_n[0] ? mul_m : 0)   [33-bit to capture carry]
    //   {mul_p, mul_n} >>= 1  (logical, carry feeds into mul_p MSB)
    reg [31:0] mul_m;       // multiplicand magnitude
    reg [31:0] mul_p;       // upper partial product
    reg [31:0] mul_n;       // multiplier / lower product
    reg        mul_neg;     // 1 → negate the 64-bit result at end
    reg        mul_upper;   // 1 → return mul_p, 0 → return mul_n

    wire [32:0] mul_sum = {1'b0, mul_p} + (mul_n[0] ? {1'b0, mul_m} : 33'b0);

    // ── Divide datapath ───────────────────────────────────────────────────────
    // Restoring division on magnitudes; sign adjustment in fixup.
    //   div_dvd : dividend (shifts left one bit per cycle)
    //   div_dvs : divisor  (fixed)
    //   div_rem : partial remainder (32 bits; grows via shift-in from div_dvd)
    //   div_quot: quotient being assembled LSB-first from bit 0
    //
    // Each iteration (bit i, from MSB to LSB of dividend):
    //   trial = {div_rem[30:0], div_dvd[31]}   ← shift remainder left, bring in MSB of dvd
    //   if trial >= div_dvs : rem = trial − div_dvs, quot[i] = 1
    //   else                : rem = trial,            quot[i] = 0
    //   div_dvd <<= 1
    reg [31:0] div_dvd;     // dividend magnitude (shifts out MSB each cycle)
    reg [31:0] div_dvs;     // divisor magnitude  (constant)
    reg [31:0] div_rem;     // partial remainder
    reg [31:0] div_quot;    // quotient
    reg        div_neg_q;   // negate quotient in fixup
    reg        div_neg_r;   // negate remainder in fixup
    reg        div_bzero;   // division-by-zero flag
    reg        div_ovfl;    // signed overflow flag (INT_MIN / −1)
    reg        div_isrem;   // 1 → return remainder
    reg [31:0] div_a_orig;  // original (signed) dividend for div-by-zero REM

    // Restoring-division step (combinational)
    wire [32:0] div_trial = {1'b0, div_rem[30:0], div_dvd[31]};
    wire [32:0] div_diff  = div_trial - {1'b0, div_dvs};
    wire        div_qbit  = !div_diff[32]; // 1 if trial ≥ divisor (no borrow)

    // ─────────────────────────────────────────────────────────────────────────
    always @(posedge clk) begin
        done <= 1'b0;   // default: done is a one-cycle pulse

        if (rst) begin
            state  <= ST_IDLE;
            busy   <= 1'b0;
            result <= 32'b0;

        end else begin
            case (state)

                // ── IDLE ─────────────────────────────────────────────────────
                ST_IDLE: begin
                    if (start) begin
                        busy  <= 1'b1;
                        count <= 6'd0;

                        if (!op[2]) begin
                            // ── Multiply setup ─────────────────────────────
                            mul_upper <= (op != OP_MUL); // MUL wants lower 32

                            case (op)
                                OP_MULH: begin
                                    // signed × signed: work on magnitudes
                                    mul_m   <= a[31] ? (~a + 32'd1) : a;
                                    mul_n   <= b[31] ? (~b + 32'd1) : b;
                                    mul_neg <= a[31] ^ b[31];
                                end
                                OP_MULHSU: begin
                                    // signed × unsigned
                                    mul_m   <= a[31] ? (~a + 32'd1) : a;
                                    mul_n   <= b;
                                    mul_neg <= a[31];
                                end
                                default: begin  // MUL, MULHU (unsigned)
                                    mul_m   <= a;
                                    mul_n   <= b;
                                    mul_neg <= 1'b0;
                                end
                            endcase

                            mul_p <= 32'b0;
                            state <= ST_MUL;

                        end else begin
                            // ── Divide setup ───────────────────────────────
                            div_isrem  <= (op == OP_REM || op == OP_REMU);
                            div_bzero  <= (b == 32'b0);
                            div_ovfl   <= (op == OP_DIV) &&
                                          (a == 32'h8000_0000) &&
                                          (b == 32'hFFFF_FFFF);
                            div_a_orig <= a;

                            if (op == OP_DIVU || op == OP_REMU) begin
                                // Unsigned: use operands as-is
                                div_dvd   <= a;
                                div_dvs   <= b;
                                div_neg_q <= 1'b0;
                                div_neg_r <= 1'b0;
                            end else begin
                                // Signed (DIV / REM): work on magnitudes
                                div_dvd   <= a[31] ? (~a + 32'd1) : a;
                                div_dvs   <= b[31] ? (~b + 32'd1) : b;
                                div_neg_q <= a[31] ^ b[31];
                                div_neg_r <= a[31];
                            end

                            div_rem  <= 32'b0;
                            div_quot <= 32'b0;
                            state    <= ST_DIV;
                        end
                    end
                end

                // ── MULTIPLY (32 shift-and-add iterations) ────────────────────
                ST_MUL: begin
                    // Right-shift {sum, mul_n} by 1 and store back.
                    // Carry from the addition enters mul_p at the MSB position.
                    mul_p <= {mul_sum[32], mul_sum[31:1]};
                    mul_n <= {mul_sum[0],  mul_n[31:1]};
                    count <= count + 6'd1;

                    if (count == 6'd31)
                        state <= mul_neg ? ST_MFIXUP : ST_MOUT;
                end

                // ── MULTIPLY FIXUP (negate 64-bit product) ────────────────────
                ST_MFIXUP: begin
                    {mul_p, mul_n} <= ~{mul_p, mul_n} + 64'd1;
                    state <= ST_MOUT;
                end

                // ── MULTIPLY OUTPUT ───────────────────────────────────────────
                ST_MOUT: begin
                    result <= mul_upper ? mul_p : mul_n;
                    busy   <= 1'b0;
                    done   <= 1'b1;
                    state  <= ST_IDLE;
                end

                // ── DIVIDE (32 restoring-division iterations) ─────────────────
                ST_DIV: begin
                    div_dvd  <= {div_dvd[30:0], 1'b0};                       // shift left
                    div_rem  <= div_qbit ? div_diff[31:0] : div_trial[31:0]; // restore or subtract
                    div_quot <= {div_quot[30:0], div_qbit};                   // accumulate quotient
                    count    <= count + 6'd1;

                    if (count == 6'd31)
                        state <= ST_DFIXUP;
                end

                // ── DIVIDE FIXUP (sign adjust + special cases) ────────────────
                ST_DFIXUP: begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= ST_IDLE;

                    if (div_bzero) begin
                        // Division by zero — spec-mandated results
                        result <= div_isrem ? div_a_orig    // REM/REMU: return dividend
                                           : 32'hFFFF_FFFF; // DIV/DIVU: return −1
                    end else if (div_ovfl) begin
                        // Signed overflow: INT_MIN / −1
                        result <= div_isrem ? 32'b0              // REM  = 0
                                           : 32'h8000_0000;      // DIV  = INT_MIN
                    end else if (div_isrem) begin
                        result <= div_neg_r ? (~div_rem  + 32'd1) : div_rem;
                    end else begin
                        result <= div_neg_q ? (~div_quot + 32'd1) : div_quot;
                    end
                end

                default: state <= ST_IDLE;

            endcase
        end
    end

endmodule
