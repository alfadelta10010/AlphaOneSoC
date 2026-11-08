// MD07 cross-check (WO-32): muldiv and muldiv_md07 (src/muldiv.v with the
// catalogue mutant MD07 applied by gen_md07_miter in md07_miter.conf, module
// renamed) side by side, same inputs; every output must agree. A bounded
// check, not a proof: md07 is the proof, this one catches a proof about the
// wrong thing.
//
// WHY THIS IMPLIES (BOUNDEDLY) EQUIVALENCE. Within the bound, no input sequence
// from reset makes busy, done or (once an operation has been accepted) result
// differ between the original and the MD07 copy. `result` is lo, which a reset
// does not clear, so it is compared only after the first accepted start
// (`seen`); before it the two copies' free initial lo legitimately differ.
// Depth: reset at step 0, start at 1, NEGA 2, NEGB 3, 32 loop steps, FIX 36,
// done visible at 37; a second divide started at 37 is done at 73. The bound
// is 40 (sby bitwuzla: 80 steps, two divides, was not reachable in the time box;
// step 19 took 4 minutes), so one full divide from reset is inside it, the second
// operation is not (MM_DEPTH=80 would add it).
// `def -DMITER_MUT=<id>` in the nonvac file applies a different catalogue
// mutant instead of MD07 (EXTRA_DEFS is read by the generator).
module md07_miter_props (
    input  wire        clk, rst,
    input  wire        start,
    input  wire [2:0]  op,
    input  wire        shift, sra,
    input  wire [31:0] a, b
);
    wire [31:0] r0, r1;
    wire        b0, b1, d0, d1;
    muldiv       u0 (.clk(clk), .rst(rst), .start(start), .op(op), .shift(shift), .sra(sra),
                     .a(a), .b(b), .result(r0), .busy(b0), .done(d0));
    muldiv_md07  u1 (.clk(clk), .rst(rst), .start(start), .op(op), .shift(shift), .sra(sra),
                     .a(a), .b(b), .result(r1), .busy(b1), .done(d1));

    reg armed = 1'b0, seen = 1'b0;
    always @(posedge clk) begin
        if (rst) begin armed <= 1'b1; seen <= 1'b0; end
        else if (start && !b0) seen <= 1'b1;
    end
    always @(*) begin
        if (armed && !rst) begin
            assert (b0 == b1);
            assert (d0 == d1);
            if (seen) assert (r0 == r1);
        end
    end
`ifdef SBY_COVER
    always @(*) begin
        cover (armed && !rst && d0 && d1 && seen);
    end
`endif
endmodule
