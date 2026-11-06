// Formal model of the 32 x 32 register-file macro (rf_top) for the
// riscv-formal run (tb/rvfi). Written from the macro's documented behaviour
// (macro/rf_top/README.md, docs/CLAUDE.md "Register file"), not copied from
// src/rf_top.v, which yosys cannot read ($test$plusargs; empty blackbox under
// SYNTHESIS).
//
//  * The storage has no initial value: the macro has no reset, and the RISC-V
//    Privileged spec leaves registers unspecified at reset. Every first
//    instruction therefore sees arbitrary operands.
//  * Write on the rising edge when w_ena; each read port registers its word on
//    the same edge (synchronous read).
//  * A read of the word written on that edge returns a FREE value (anyseq)
//    instead of the macro's write-first data. "Any value" includes the real
//    write-first one, so a pass here covers the macro, and it proves that
//    regFile's own bypass makes the collision answer irrelevant.
module rf_top (
    input  wire [31:0] w_data,
    input  wire [4:0]  w_addr,
    input  wire        w_ena,
    input  wire [4:0]  ra_addr,
    input  wire [4:0]  rb_addr,
    output reg  [31:0] ra_data,
    output reg  [31:0] rb_data,
    input  wire        clk
);
    reg [31:0] mem [0:31];
    (* anyseq *) reg [31:0] coll_a;
    (* anyseq *) reg [31:0] coll_b;
    always @(posedge clk) begin
        if (w_ena) mem[w_addr] <= w_data;
        ra_data <= (w_ena && w_addr == ra_addr) ? coll_a : mem[ra_addr];
        rb_data <= (w_ena && w_addr == rb_addr) ? coll_b : mem[rb_addr];
    end
endmodule
