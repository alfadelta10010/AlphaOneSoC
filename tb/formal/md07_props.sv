// MD07 is equivalent (WO-32). The catalogue mutant MD07 (tb/mutate/mutants.py)
// changes the divide step of src/muldiv.v from
//     acc <= sum[33] ? {1'b0, trial[31:0]} : {1'b0, sum[31:0]};
// to the same line testing sum[32]. Nothing else reads the mutated bit: grep
// of muldiv.v finds sum[33] in this line, in the `lo <= {lo[30:0], ~sum[33]}`
// quotient bit below it, and in the multiply step (acc <= sum[33:1]); MD07
// touches only the acc line, so only that mux is at issue.
//
// WHY THIS IMPLIES EQUIVALENCE. The two versions of the line give different
// values of acc only when sum[33] != sum[32] AND trial[31:0] != sum[31:0] (the
// arms are the trial remainder and the difference). E1 says that never happens
// in a divide loop step in any reachable state, so the registers of the original
// and of the mutant evolve identically from reset (induction over cycles on the
// state of the original; the mutant differs only in that line).
// Why E1 holds: trial = 2*acc + next dividend bit and sum = trial - m. If m != 0
// and acc < m, trial < 2m <= 2^33, and sum lies in [-m, m): both bits 33 and 32
// are the sign (m < 2^32), so they agree. If m = 0, sum = trial, whose bit 33 is
// 0 and bit 32 is whatever, but then the two arms are trial[31:0] and
// sum[31:0] = trial[31:0], equal. The invariant acc < m (m != 0), acc[32] = 0
// holds in the loop (I2) because the loop keeps either the trial remainder when
// it is < m or the difference, which is < m; it holds on entry because acc = 0
// through NEGA/NEGB (I1) and m != 0 survives NEGB (the negation is bijective).
//   E1  S_LOOP, divide: sum[33] == sum[32] or trial[31:0] == sum[31:0]
//   I1  S_NEGA, S_NEGB: a divide, acc = 0
//   I2  S_LOOP, divide: acc[32] = 0 and (m = 0 or acc < m)
// All asserts are gated on `armed` (set by a reset); white-box names come from
// `expose` (run.sh PRE), never from hierarchical references.
module md07_props (
    input  wire        clk, rst,
    input  wire        start,
    input  wire [2:0]  op,
    input  wire        shift, sra,
    input  wire [31:0] a, b
);
    wire [31:0] result, lo, m;
    wire        busy, done, isdiv;
    wire [2:0]  st;
    wire [32:0] acc, trial;
    wire [33:0] sum;
    muldiv dut (.clk(clk), .rst(rst), .start(start), .op(op), .shift(shift), .sra(sra),
                .a(a), .b(b), .result(result), .busy(busy), .done(done),
                .st(st), .acc(acc), .lo(lo), .m(m), .isdiv(isdiv), .sum(sum), .trial(trial));

    reg armed = 1'b0;
    always @(posedge clk) if (rst) armed <= 1'b1;

    wire in_loop = (st == 3'd3) && isdiv;
    wire in_neg  = (st == 3'd1) || (st == 3'd2);
    always @(*) begin
        if (armed && !rst) begin
            if (in_loop) assert ((sum[33] == sum[32]) || (trial[31:0] == sum[31:0]));   // E1
            if (in_neg)  assert (isdiv && acc == 33'd0);                                // I1
            if (in_loop) assert (!acc[32] && (m == 32'd0 || acc[31:0] < m));            // I2
        end
    end

`ifdef SBY_COVER
    always @(*) begin
        cover (armed && !rst && in_loop && sum[33]);                  // restore step taken
        cover (armed && !rst && in_loop && !sum[33] && m != 32'd0);   // not taken
        cover (armed && !rst && in_loop && m == 32'd0);               // divide by 0 in the loop
    end
`endif
endmodule
