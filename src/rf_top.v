// rf_top: Sylvain Munaut's 32 x 32 register-file hard macro (macro/rf_top/),
// as a simulation model. The same model serves TinyTapeout's gate-level test,
// which compiles it next to the netlist with GL_TEST (and so its power pins).
//
// Synthesis must never build this storage: the macro's GDS/LEF/liberty stand
// in for it. Under SYNTHESIS (yosys defines it) the module is an empty
// blackbox, so even a flow that elaborates the source keeps one rf_top cell
// and no flops. LibreLane also reads the liberty as a blackbox before the
// sources, so its synthesis keeps the cell either way.
`ifdef SYNTHESIS
(* blackbox *)
`endif
//
// Behaviour, as in the macro's own model (macro/rf_top/rf_top.upstream.v,
// which this follows statement for statement): on each rising edge the write
// (w_ena, w_addr, w_data) is done and both read addresses are captured; each
// read port then gives the captured word, write-first -- a read of the word
// written on the same edge gets the new data. Word 0 is an ordinary word.
//
// There is no reset. The storage starts at 0, as Spike's registers do, unless
// +RF_X is given; then it starts at X like the silicon's unknown state, so a
// read of a register nothing wrote shows up as an X (see tests/directed/run.sh).
//
// +RF_COLLIDE_X departs from the macro's model on purpose: a read of the word
// written on the same edge returns X instead of the new data. The write
// itself still lands. That read-through path has no timing in the macro's
// liberty, so regFile.v bypasses it; with this plusarg any use of the macro's
// own answer for such a read shows up as an X.
module rf_top (
`ifdef GL_TEST
    inout  wire        VDPWR,
    inout  wire        VGND,
`endif
    input  wire [31:0] w_data,
    input  wire [4:0]  w_addr,
    input  wire        w_ena,
    input  wire [4:0]  ra_addr,
    input  wire [4:0]  rb_addr,
    output reg  [31:0] ra_data,
    output reg  [31:0] rb_data,
    input  wire        clk
);
`ifndef SYNTHESIS
    reg [31:0] storage [0:31];
    reg        collide_x;
    integer i;

    initial begin
        if (!$test$plusargs("RF_X"))
            for (i = 0; i < 32; i = i + 1)
                storage[i] = 32'h0000_0000;
        collide_x = $test$plusargs("RF_COLLIDE_X") ? 1'b1 : 1'b0;
    end

    always @(posedge clk) begin
        if (w_ena)
            storage[w_addr] <= w_data;

        if (w_ena && (ra_addr == w_addr))
            ra_data <= collide_x ? 32'hxxxx_xxxx : w_data;
        else
            ra_data <= storage[ra_addr];

        if (w_ena && (rb_addr == w_addr))
            rb_data <= collide_x ? 32'hxxxx_xxxx : w_data;
        else
            rb_data <= storage[rb_addr];
    end
`endif
endmodule
