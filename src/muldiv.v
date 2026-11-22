// Multi-cycle multiply/divide unit -- RV32M extension
//
// All eight M-extension operations run through one FSM around a single
// 35-bit adder/subtractor and one 33+32-bit shift register pair. A separate
// multiply and divide datapath, each with its own adder and operand/result
// negators, cost about twice the area for operations that in the SoC finish
// behind the next instruction fetch anyway.
//
// Multiply (MUL/MULH/MULHSU/MULHU): radix-4 Booth, two multiplier bits per
// step, 16 steps. The multiplier is always recoded as a 32-bit signed number
// (digits -2..2 from the bit triples {b[2i+1], b[2i], b[2i-1]}); the
// multiplicand is sign-extended into the 33-bit accumulator when it is signed
// (MULH, MULHSU). A multiplier that is unsigned with bit 31 set (MULHU,
// MULHSU) was recoded 2^32 low, so one more step adds the multiplicand into
// the high word (S_FIX); MUL and a multiplier without that case finish from
// the last step. No operand or result negation is needed. 17 cycles from
// start to done (18 with the extra step).
//
// Divide (DIV/DIVU/REM/REMU): restoring division on magnitudes. The operand
// negations (S_NEGA, S_NEGB; each only when its operand is negative) and
// the result negation (S_FIX) go through the same adder. While the
// remainder is still 0 and the divisor is not, the leading zero bits of the
// dividend are skipped 16, 8 or 4 at a time (they would only shift zero
// quotient bits in). 3 + 32 cycles at most (36 with both negations), fewer
// for a small dividend: a dividend below 2^4 takes 1 + 4 + 1 steps. Division
// by zero and signed overflow fall out of the datapath with the results
// RV32M requires:
//   x / 0      -> quotient all ones (-1), remainder x
//   INT_MIN/-1 -> quotient INT_MIN, remainder 0
//
// op encoding matches controller aluOp[2:0] when aluOp[4:3] == 2'b10:
//   3'b000  MUL      3'b100  DIV
//   3'b001  MULH     3'b101  DIVU
//   3'b010  MULHSU   3'b110  REM
//   3'b011  MULHU    3'b111  REMU
// The RV32I shifts are not here: they are single-cycle in alu.v.
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
    output wire [31:0] result,      // computed result (valid from done)
    output reg         busy,        // 1 while computing
    output reg         done         // one-cycle result-valid pulse
);

    localparam S_IDLE = 3'd0,
               S_NEGA = 3'd1,       // divide: |dividend|
               S_NEGB = 3'd2,       // divide: |divisor|
               S_LOOP = 3'd3,       // 32 iterations
               S_FIX  = 3'd4;       // select / negate the result

    reg [2:0]  st;
    reg [4:0]  cnt;
    reg [32:0] acc;     // multiply: high product; divide: partial remainder
    reg [31:0] lo;      // multiplier -> low product; dividend -> quotient; result
    reg [31:0] m;       // multiplicand / divisor
    reg        isdiv;   // the operation is a divide
    reg        sa;      // multiplicand is signed
    reg        bq;      // multiply: the multiplier bit below the next digit
    reg        ub31;    // multiply: multiplier unsigned with bit 31 set (S_FIX adds m)
    reg        hi;      // return the high word (MULH*) / the remainder (REM*)
    reg        na, nb;  // divide: dividend / divisor was negative

    assign result = lo;

    wire [32:0] mext   = {sa & m[31], m};
    wire [32:0] trial  = {acc[31:0], lo[31]};
    wire        mzero  = (m == 32'b0);
    // Quotient sign: negative when exactly one operand was, except for a
    // zero divisor (the all-ones quotient stands). Remainder sign: the
    // dividend's.
    wire        negres = isdiv & (hi ? na : ((na ^ nb) & ~mzero));

    // Booth radix-4 digit from {lo[1:0], bq}: 0, +-1 (bone), +-2 (btwo).
    wire [2:0]  bd    = {lo[1:0], bq};
    wire        bneg  = bd[2] & ~(bd[1] & bd[0]);
    wire        bone  = bd[1] ^ bd[0];
    wire        btwo  = (bd == 3'b011) | (bd == 3'b100);
    wire [34:0] mx35  = {{2{mext[32]}}, mext};
    wire [34:0] bY    = bone ? mx35 : btwo ? {mx35[33:0], 1'b0} : 35'b0;

    // Divide: skip leading zero quotient bits while the remainder is 0.
    wire        zrem  = isdiv & (acc == 33'b0) & ~mzero;
    wire        skip16 = zrem & (cnt <= 5'd15) & (lo[31:16] == 16'b0);
    wire        skip8  = zrem & (cnt <= 5'd23) & (lo[31:24] == 8'b0);
    wire        skip4  = zrem & (cnt <= 5'd27) & (lo[31:28] == 4'b0);

    // The one adder: sum = X + Y, or X - Y when sub.
    reg  [34:0] X, Y;
    reg         sub;
    always @(*) begin
        X = 35'b0; Y = 35'b0; sub = 1'b0;
        case (st)
            S_NEGA: begin Y = {3'b0, lo}; sub = 1'b1; end
            S_NEGB: begin Y = {3'b0, m};  sub = 1'b1; end
            S_LOOP: if (isdiv) begin
                        X = {2'b0, trial}; Y = {3'b0, m}; sub = 1'b1;
                    end else begin
                        X = {{2{acc[32]}}, acc};
                        Y = bY;
                        sub = bneg;
                    end
            S_FIX:  if (isdiv) begin
                        Y = {3'b0, hi ? acc[31:0] : lo}; sub = negres;
                    end else begin
                        X = {{2{acc[32]}}, acc};
                        Y = mx35;                  // multiplier was unsigned with bit 31
                    end
            default: ;
        endcase
    end
    wire [34:0] sum = X + (Y ^ {35{sub}}) + {34'b0, sub};

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
                isdiv <= op[2];
                if (op[2]) begin
                    // DIV/REM are signed, DIVU/REMU (op[0] = 1) are not
                    lo <= a; m <= b;
                    na <= ~op[0] & a[31];
                    nb <= ~op[0] & b[31];
                    hi <= op[1];            // REM/REMU return the remainder
                    sa <= 1'b0;
                    st <= (~op[0] & a[31]) ? S_NEGA : (~op[0] & b[31]) ? S_NEGB : S_LOOP;
                end else begin
                    // multiplicand a (signed for MULH, MULHSU),
                    // multiplier b (recoded as signed; MULHU, MULHSU add the
                    // multiplicand back when b[31] is set)
                    m  <= a; lo <= b;
                    sa <= (op == 3'd1) | (op == 3'd2);
                    bq <= 1'b0;
                    ub31 <= b[31] & (op != 3'd1);
                    hi <= (op != 3'd0);
                    na <= 1'b0; nb <= 1'b0;
                    st <= S_LOOP;
                end
            end
            S_NEGA: begin if (na) lo <= sum[31:0]; st <= nb ? S_NEGB : S_LOOP; end
            S_NEGB: begin if (nb) m  <= sum[31:0]; st <= S_LOOP; end
            S_LOOP: begin
                if (skip16) begin
                    lo  <= {lo[15:0], 16'b0};        // 16 zero quotient bits
                    cnt <= cnt + 5'd16;
                end else if (skip8) begin
                    lo  <= {lo[23:0], 8'b0};
                    cnt <= cnt + 5'd8;
                end else if (skip4) begin
                    lo  <= {lo[27:0], 4'b0};
                    cnt <= cnt + 5'd4;
                end else if (isdiv) begin
                    // restoring step: keep the trial remainder on a borrow
                    acc <= sum[33] ? {1'b0, trial[31:0]} : {1'b0, sum[31:0]};
                    lo  <= {lo[30:0], ~sum[33]};
                    cnt <= cnt + 5'd1;
                    if (cnt == 5'd31) st <= S_FIX;
                end else begin
                    // shift the 67-bit {acc, lo, bq} right by two with the new sum on top
                    acc <= sum[34:2];
                    lo  <= (cnt == 5'd15 && hi && !ub31) ? sum[33:2] : {sum[1:0], lo[31:2]};
                    bq  <= lo[1];
                    cnt <= cnt + 5'd1;
                    if (cnt == 5'd15) begin
                        // done after the last step, unless the high word
                        // still needs the unsigned-multiplier correction
                        if (hi && ub31) st <= S_FIX;
                        else begin busy <= 1'b0; done <= 1'b1; st <= S_IDLE; end
                    end
                end
            end
            S_FIX: begin
                lo   <= sum[31:0];
                busy <= 1'b0;
                done <= 1'b1;
                st   <= S_IDLE;
            end
            default: st <= S_IDLE;
        endcase
    end

endmodule
