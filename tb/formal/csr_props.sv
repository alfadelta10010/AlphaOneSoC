// Invariants of the CSR file (src/csr.v), proved with yosys's own SAT
// engine (tb/formal/run.sh) for every input sequence, not only the ones a
// simulation happens to drive. Each is a WARL rule of
// docs/FyraCore_CPU_Reference.md section 7 stated as "no reachable state
// breaks it":
//   P1 mstatus.MPP is 00 or 11 (M+U only)            CPU ref 7.3
//   P2 mstatus has no bits outside MIE/MPIE/MPP/MPRV/TW
//   P3 mie has only MSIE/MTIE/MEIE                   CPU ref 7.3
//   P4 mtvec[1:0] = 0 (direct mode)
//   P5 mcounteren has only CY/TM/IR, mcountinhibit only CY/IR
//   P6 no pmpcfg byte has bits 6:5 set or R=0,W=1    CPU ref 6.3
//   P7 misa is 0x40101101 with only C (bit 2) free   CPU ref 7.2
//   P8 mepc as read has bit 0 clear, and bit 1 clear while misa.C = 0
// They are checked from the first clock after a reset onward.
module csr_props (
    input  wire        clk, rst,
    input  wire [11:0] waddr,
    input  wire [31:0] wdata,
    input  wire        we, trap, mret,
    input  wire [31:0] trap_pc, trap_cause, trap_val,
    input  wire        priv_mode, instret_inc,
    input  wire        timer_irq, external_irq, sw_irq, pc_next_misaligned,
    input  wire [63:0] mtime_in
);
    wire [31:0] rdata, mtvec_out, mepc_out, pmpcfg0, pa0, pa1, pa2, pa3, mie_out, wval;
    wire        mie, valid, misa_c, tw, mprv;
    wire [1:0]  mpp;
    csr dut (.clk(clk), .rst(rst), .raddr(raddr), .waddr(waddr), .wdata(wdata), .we(we),
             .rdata(rdata), .trap(trap), .mret(mret), .trap_pc(trap_pc), .trap_cause(trap_cause),
             .trap_val(trap_val), .priv_mode(priv_mode), .mtvec_out(mtvec_out), .mepc_out(mepc_out),
             .instret_inc(instret_inc), .mstatus_mie(mie), .mstatus_mpp(mpp), .pmpcfg0_out(pmpcfg0),
             .pmpaddr0_out(pa0), .pmpaddr1_out(pa1), .pmpaddr2_out(pa2), .pmpaddr3_out(pa3),
             .csr_addr_valid(valid), .timer_irq(timer_irq), .external_irq(external_irq),
             .sw_irq(sw_irq), .mie_out(mie_out), .misa_c(misa_c), .mstatus_tw(tw),
             .mstatus_mprv(mprv), .mtime_in(mtime_in), .pc_next_misaligned(pc_next_misaligned),
             .wval_out(wval));

    // The read port cycles through the registers that have no export of
    // their own, one per clock, so every window of 8 steps the induction
    // looks at has seen each of them. (A free raddr let the induction
    // hypothesis read elsewhere on every earlier step and say nothing.)
    reg  [2:0]  obs = 3'd0;
    always @(posedge clk) obs <= obs + 3'd1;
    wire [11:0] raddr = (obs == 3'd0) ? 12'h300 : (obs == 3'd1) ? 12'h301 :
                        (obs == 3'd2) ? 12'h304 : (obs == 3'd3) ? 12'h305 :
                        (obs == 3'd4) ? 12'h306 : (obs == 3'd5) ? 12'h320 :
                        (obs == 3'd6) ? 12'h341 : 12'h3A0;

    reg armed = 1'b0;               // a reset has been applied
    always @(posedge clk) if (rst) armed <= 1'b1;

    // The registers are seen through the exports and the cycling read
    // port; nothing reaches into the design.
    integer k;
    always @(*) begin
        if (armed) begin
            assert (mpp == 2'b00 || mpp == 2'b11);                                          // P1
            if (raddr == 12'h300) assert ((rdata & ~32'h0022_1888) == 32'h0);               // P2
            if (raddr == 12'h300) assert (rdata[12:11] == mpp);
            if (raddr == 12'h304) assert ((rdata & ~32'h0000_0888) == 32'h0);               // P3
            assert ((mie_out & ~32'h0000_0888) == 32'h0);
            assert (mtvec_out[1:0] == 2'b00);                                               // P4
            if (raddr == 12'h305) assert (rdata[1:0] == 2'b00);
            if (raddr == 12'h306) assert ((rdata & ~32'h7) == 32'h0);                       // P5
            if (raddr == 12'h320) assert ((rdata & ~32'h5) == 32'h0);
            for (k = 0; k < 4; k = k + 1) begin                                             // P6
                assert (pmpcfg0[8*k+5] == 1'b0 && pmpcfg0[8*k+6] == 1'b0);
                assert (!(pmpcfg0[8*k+1] && !pmpcfg0[8*k]));
            end
            if (raddr == 12'h301) assert ((rdata & ~32'h4) == 32'h4010_1101);               // P7
            if (raddr == 12'h301) assert (rdata[2] == misa_c);
            assert (mepc_out[0] == 1'b0 && (misa_c || mepc_out[1] == 1'b0));                // P8
        end
    end

`ifdef SBY_COVER
    // antecedents of the implication asserts above: an unreached one makes its assert vacuous
    always @(*) begin
        cover (armed && raddr == 12'h300); cover (armed && raddr == 12'h301); cover (armed && raddr == 12'h304);
        cover (armed && raddr == 12'h305); cover (armed && raddr == 12'h306); cover (armed && raddr == 12'h320);
    end
`endif
endmodule
