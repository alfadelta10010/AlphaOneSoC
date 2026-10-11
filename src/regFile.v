// The register file: Sylvain Munaut's 32 x 32 hard macro (rf_top, src/rf_top.v;
// the views and their provenance are in macro/rf_top/). One write port, two
// read ports.
//
// Reads are synchronous. ra/rb are taken on a rising edge, and r1/r2 give
// those registers from just after that edge until the next one. A read of the
// register written on the same edge gets the new value (write-first), so r1/r2
// show the registers as they stand after that edge's write: what a
// combinational read of a flop register file gives in the cycle after the
// edge. fyracore keeps that equivalence by putting on ra/rb, in each cycle,
// the registers the instruction in EX will need in the next one.
//
// x0: the macro's word 0 is an ordinary word, so it is never written here,
// and r1/r2 are raw -- the caller masks a read of x0 (fyracore masks with the
// decoded register field). There is no reset: x1-x31 are unspecified after
// reset (Priv spec, "Reset"), and boot code that relies on them clears them
// itself (plugins/helpers/boot_flash.S zeroes x1-x31 first thing). The
// simulation model starts them at 0 like Spike, or at X under +RF_X.
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
    rf_top rf_macro (
        .w_data (dIn),
        .w_addr (rd),
        .w_ena  (wrEn && (rd != 5'b0)),
        .ra_addr(ra),
        .rb_addr(rb),
        .ra_data(r1),
        .rb_data(r2),
        .clk    (clk)
    );
endmodule
