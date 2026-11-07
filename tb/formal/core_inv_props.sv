// FC02 and FC49 are equivalent (WO-32): core invariants of fyracore, all inputs
// free, arbitrary register-file contents (rf_top_stub.v), internals read through
// `expose` (run.sh PRE), never by hierarchical reference.
//
// WHY THESE IMPLY EQUIVALENCE.
// FC02 (csr_wb_hazard tied to 0) only changes stall_nofetch (the term is read
// nowhere else that matters: grep shows csr_wb_hazard in stall_nofetch and in
// comments). stall_nofetch = wb_busy | wb_mem_stall | wfi_active | ex_ifetch_hi_phase
// | csr_wb_hazard | ex_wait. E-FC02b says csr_wb_hazard implies the OR of the
// OTHER terms in every reachable state, so dropping the term leaves
// stall_nofetch, and hence every register, unchanged. E-FC02a (hazard -> !ex_ph,
// so ex_wait = ifex_valid & !ex_ph holds) is the reason: a CSR write is in WB only
// if the instruction behind it entered EX at the last edge (ex_ph <= 0 there),
// and the hold cases that keep it in WB (wb_busy, wb_mem_stall) cannot occur
// with a CSR write in WB (S1).
// FC49 (`if (rst || flush) muldiv_ready <= 0` loses `flush`): the mutant differs
// only on a flush cycle. E-FC49c states the next muldiv_ready WITHOUT the flush
// term is 0 on any flush cycle (neither capture, nor done, nor ready), which is
// the original's value. It follows from E-FC49a (a flush never meets muldiv_want)
// and E-FC49b (ready, busy, done each imply muldiv_want: the M instruction stays
// in EX while the unit works, the unit having stalled it).
//   E-FC02a  csr_wb_hazard -> !ex_ph
//   E-FC02b  csr_wb_hazard -> wb_busy | wb_mem_stall | wfi_active | ex_ifetch_hi_phase | ex_wait
//   E-FC49a  !(flush & muldiv_want)
//   E-FC49b  (muldiv_ready | muldiv_busy | muldiv_done) -> muldiv_want
//   E-FC49c  flush -> next muldiv_ready without the flush term is 0
// Status: BOUNDED only (core_inv.conf); the length-1 induction does not close, see the conf.
// Strengthening: S2 busy/done/ready are pairwise exclusive, S3 wb_busy -> an AMO in WB,
// S4 ex_ph -> ex_rf_ok, M1 the unit's busy/st/done agree (st is muldiv_inst.st), S1 CSR write in WB -> no memory access, no AMO in WB, wb_busy = 0
// (see the induction notes in core_inv.conf).
module core_inv_props (
    input  wire        clk, rst_in,
    input  wire [31:0] boot_addr,
    input  wire [31:0] imem_rdata, dmem_rdata,
    input  wire        imem_ready, dmem_ready,
    input  wire        timer_irq, external_irq, sw_irq,
    input  wire [63:0] mtime_in
);
    wire rst = rst_in;
    wire [31:0] imem_addr, dmem_addr, dmem_wdata, dbg_pc, dbg_instr;
    wire [3:0]  dmem_be;
    wire        imem_req, dmem_req, dmem_we, fencei_flush, dbg_retired, dbg_compressed, dbg_trap;
    wire csr_wb_hazard, ex_ph, ex_wait, ifex_valid, flush, muldiv_want, muldiv_ready, muldiv_busy, muldiv_done;
    wire wb_busy, wb_mem_stall, wfi_active, ex_ifetch_hi_phase, ex_rf_ok, exwb_valid, exwb_csrWR, exwb_trap;
    wire exwb_memRD, exwb_memWR, exwb_isAmo, muldiv_capture, ex_is_iter;
    wire [2:0] x_mst;       // muldiv_inst.st, renamed by the PRE of core_inv.conf
    fyracore dut (.clk(clk), .rst(rst), .boot_addr(boot_addr),
        .imem_addr(imem_addr), .imem_req(imem_req), .imem_rdata(imem_rdata), .imem_ready(imem_ready),
        .dmem_req(dmem_req), .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata), .dmem_be(dmem_be),
        .dmem_we(dmem_we), .dmem_rdata(dmem_rdata), .dmem_ready(dmem_ready),
        .timer_irq(timer_irq), .external_irq(external_irq), .sw_irq(sw_irq), .mtime_in(mtime_in),
        .fencei_flush(fencei_flush), .dbg_pc(dbg_pc), .dbg_retired(dbg_retired),
        .dbg_instr(dbg_instr), .dbg_compressed(dbg_compressed), .dbg_trap(dbg_trap),
        .csr_wb_hazard(csr_wb_hazard), .ex_ph(ex_ph), .ex_wait(ex_wait), .ifex_valid(ifex_valid),
        .flush(flush), .muldiv_want(muldiv_want), .muldiv_ready(muldiv_ready),
        .muldiv_busy(muldiv_busy), .muldiv_done(muldiv_done), .wb_busy(wb_busy),
        .wb_mem_stall(wb_mem_stall), .wfi_active(wfi_active), .ex_ifetch_hi_phase(ex_ifetch_hi_phase),
        .ex_rf_ok(ex_rf_ok), .exwb_valid(exwb_valid), .exwb_csrWR(exwb_csrWR), .exwb_trap(exwb_trap),
        .exwb_memRD(exwb_memRD), .exwb_memWR(exwb_memWR), .exwb_isAmo(exwb_isAmo),
        .muldiv_capture(muldiv_capture), .ex_is_iter(ex_is_iter), .x_mst(x_mst));

    reg armed = 1'b0;
    always @(posedge clk) if (rst) armed <= 1'b1;
    wire chk = armed && !rst;
    wire csr_in_wb = exwb_valid && exwb_csrWR && !exwb_trap;
    wire nxt_ready_noflush = muldiv_capture ? 1'b0 : muldiv_done ? 1'b1 : muldiv_ready;

`ifdef ONLY
    localparam [15:0] SEL = `ONLY;      // debugging aid: run.sh EXTRA_DEFS=-DONLY=<mask> checks only those asserts
`else
    localparam [15:0] SEL = 16'hffff;
`endif
    always @(*) begin
        if (chk) begin
            if (SEL[0]) assert (!csr_wb_hazard || !ex_ph);                                       // E-FC02a
            if (SEL[1]) assert (!csr_wb_hazard || wb_busy || wb_mem_stall || wfi_active
                                   || ex_ifetch_hi_phase || ex_wait);                            // E-FC02b
            if (SEL[2]) assert (!(flush && muldiv_want));                                        // E-FC49a
            if (SEL[3]) assert (!(muldiv_ready || muldiv_busy || muldiv_done) || muldiv_want);  // E-FC49b
            if (SEL[4]) assert (!flush || !nxt_ready_noflush);                                   // E-FC49c
            if (SEL[5]) assert (!csr_in_wb || (!exwb_memRD && !exwb_memWR && !exwb_isAmo && !wb_busy));        end
            if (SEL[6]) assert (!(muldiv_busy && muldiv_done) && !(muldiv_ready && muldiv_busy) && !(muldiv_ready && muldiv_done));  // S2 handshake exclusion
            if (SEL[7]) assert (!wb_busy || (exwb_valid && exwb_isAmo));                         // S3
            if (SEL[9]) assert (x_mst <= 3'd5 && muldiv_busy == (x_mst != 3'd0) && (!muldiv_done || x_mst == 3'd0));  // M1: unit busy iff not IDLE; done only in IDLE
            if (SEL[8]) assert (!ex_ph || ex_rf_ok);                                             // S4
    end

`ifdef SBY_COVER
    always @(*) begin
        cover (chk && csr_wb_hazard);
        cover (chk && flush && ifex_valid && ex_is_iter);   // a flush with an M/shift instruction in EX (a trapping one: muldiv_want is 0)
        cover (chk && muldiv_ready);
        cover (chk && muldiv_done);
    end
`endif
endmodule
