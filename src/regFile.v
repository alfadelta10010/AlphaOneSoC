// The register file: Sylvain Munaut's 32 x 32 hard macro (rf_top, src/rf_top.v;
// the views and their provenance are in macro/rf_top/). One write port, two
// read ports.
//
// Reads are synchronous. ra/rb are taken on a rising edge, and r1/r2 give
// those registers from just after that edge until the next one. A read of the
// register written on the same edge gets the new value (write-first), so r1/r2
// show the registers as they stand after that edge's write: what a
// combinational read of a flop register file gives in the cycle after the
// edge. fyracore keeps the EX instruction's own register numbers on ra/rb
// for as long as it is in EX, and uses r1/r2 from its second cycle there.
//
// Write-first is done here, not left to the macro. The macro's model and its
// author's slides both describe a read of the word being written as returning
// the new data, but its liberty gives that path no timing and no silicon
// measurement of it has been published. fyracore reads the word being written
// whenever an instruction reads what the one before it wrote (the write lands
// on the edge that takes the reader's addresses), so it must not rest on that.
// On an edge that writes the word a port is reading, the written data is kept
// in `byp` and the port gives that for the cycle instead of the macro's output
// (hit1/hit2). What the macro returns for such a read is never used; all that
// is asked of it is that the write itself lands, which KianV's sky25b silicon
// shows.
// +RF_COLLIDE_X makes the model return X there, so a run proves nothing
// depends on it (tests/directed/run.sh).
//
// x0: the macro's word 0 is an ordinary word, so it is never written here,
// and r1/r2 are raw -- the caller masks a read of x0 (fyracore masks with the
// decoded register field). There is no reset: x1-x31 are unspecified after
// reset (Priv spec, "Reset"), and boot code that relies on them clears them
// itself (plugins/helpers/boot_flash.S zeroes x1-x31 first thing). The
// simulation model starts them at 0 like Spike, or at X under +RF_X.
// hit1/hit2 need no reset either: nothing is written while the core is in
// reset, so they are 0 from its second clock on.
module regFile (
    input  wire        clk,
    input  wire        wrEn,
    input  wire [4:0]  rd,
    input  wire [31:0] dIn,
    input  wire [4:0]  ra,     // taken on the next rising edge
    input  wire [4:0]  rb,
    output wire [31:0] r1,     // the registers ra/rb named at the last edge
    output wire [31:0] r2
);
    wire        w_ena = wrEn && (rd != 5'b0);
    wire [31:0] m1, m2;

    rf_top rf_macro (
        .w_data (dIn),
        .w_addr (rd),
        .w_ena  (w_ena),
        .ra_addr(ra),
        .rb_addr(rb),
        .ra_data(m1),
        .rb_data(m2),
        .clk    (clk)
    );

    reg        hit1, hit2;
    reg [31:0] byp;
    always @(posedge clk) begin
        hit1 <= w_ena && (ra == rd);
        hit2 <= w_ena && (rb == rd);
        byp  <= dIn;
    end

    assign r1 = hit1 ? byp : m1;
    assign r2 = hit2 ? byp : m2;
endmodule
