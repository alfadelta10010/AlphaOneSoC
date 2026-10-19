`timescale 1ns / 1ps
// csr (src/csr.v) against a cycle-by-cycle model of the CSR file written from
// docs/FyraCore_CPU_Reference.md sections 6.3, 7, 8.3, 9.5 and the Privileged
// spec (3.1.6 mstatus, 3.1.9 mip/mie, 3.1.11-12 counters, 3.3.2 MRET, 3.7.1
// PMP CSRs), not from the RTL:
//
//   * reset values (REQ-CSR-001), the read-only and read-zero CSRs (002), and
//     csr_addr_valid for all 4096 addresses in both privileges and under
//     every mcounteren (011, 012);
//   * every write through its WARL rule (003-005): mstatus MIE/MPIE/MPRV/TW
//     and MPP legalised to U unless 11; mie 3/7/11; mtvec[1:0] 0; mcounteren
//     2:0; mcountinhibit 0 and 2; mepc bit 0 dropped, bit 1 kept but read 0
//     while misa.C = 0; misa only C, a clear refused while the next pc is
//     misaligned; pmpcfg0 per byte: R=0,W=1 written as W=0, bits 6:5 zero, a
//     byte with L=1 frozen; pmpaddr[i] frozen by its own L or by entry i+1's
//     TOR+L; mip, the read-only and the read-zero CSRs ignore writes;
//   * the counters (006, 007): mcycle counts every clock but the clock of and
//     the clock after an mcycle write, unless mcountinhibit.CY; minstret counts
//     instret_inc unless mcountinhibit.IR; a write replaces its half and the
//     other half keeps its value; the 64-bit carry; read through the
//     counters, mcycle/minstret(h) and the U aliases;
//   * trap entry (008): mepc, mcause, mtval, MPIE <- MIE, MIE <- 0, MPP <-
//     the trapping privilege; MRET (009): MIE <- MPIE, MPIE <- 1, MPP <- U,
//     MPRV <- 0 when MPP was not M;
//   * mip as the three live wires (010); every exported field (mtvec_out,
//     mepc_out, mstatus_*, mie_out, misa_c, pmp*_out) on every clock, and
//     wval_out -- the post-write value the trace logs -- on every write.
//
// A seeded random run (+SEED=, +NCYC=) drives all inputs on every clock,
// biased to the interesting values (locks, counter rollover, illegal MPP),
// with resets dropped in. Coverage counters fail the run if a case the
// stimulus is meant to reach was never reached. Prints PASS/FAIL with the
// number of checks.
module tb_csr;
    reg         clk = 0, rst = 1;
    reg  [11:0] raddr = 0, waddr = 0;
    reg  [31:0] wdata = 0;
    reg         we = 0, trap = 0, mret_sig = 0, priv = 1, instret_inc = 0;
    reg  [31:0] trap_pc = 0, trap_cause = 0, trap_val = 0;
    reg         tirq = 0, eirq = 0, sirq = 0, pc_mis = 0;
    reg  [63:0] mtime_in = 0;
    wire [31:0] rdata, mtvec_out, mepc_out, pmpcfg0_out, pa0, pa1, pa2, pa3, mie_out, wval_out;
    wire        mstatus_mie, csr_addr_valid, misa_c, mstatus_tw, mstatus_mprv;
    wire [1:0]  mstatus_mpp;

    localparam [31:0] MARCHID = 32'h0000_0005;
    csr #(.MARCHID_VAL(MARCHID)) uut (
        .clk(clk), .rst(rst), .raddr(raddr), .waddr(waddr), .wdata(wdata), .we(we), .rdata(rdata),
        .trap(trap), .mret(mret_sig), .trap_pc(trap_pc), .trap_cause(trap_cause), .trap_val(trap_val),
        .priv_mode(priv), .mtvec_out(mtvec_out), .mepc_out(mepc_out), .instret_inc(instret_inc),
        .mstatus_mie(mstatus_mie), .mstatus_mpp(mstatus_mpp), .pmpcfg0_out(pmpcfg0_out),
        .pmpaddr0_out(pa0), .pmpaddr1_out(pa1), .pmpaddr2_out(pa2), .pmpaddr3_out(pa3),
        .csr_addr_valid(csr_addr_valid), .timer_irq(tirq), .external_irq(eirq), .sw_irq(sirq),
        .mie_out(mie_out), .misa_c(misa_c), .mstatus_tw(mstatus_tw), .mstatus_mprv(mstatus_mprv),
        .mtime_in(mtime_in), .pc_next_misaligned(pc_mis), .wval_out(wval_out));

    // The clock can be held low (clk_en = 0) for the address sweep, which
    // walks raddr with no edge, so the counters stay where the model has them.
    reg clk_en = 1;
    always #5 if (clk_en || clk) clk = ~clk;

    integer checks = 0, fails = 0, seed = 1, ncyc = 200000, cyc = 0;
    integer seed0 = 1;
    task automatic chk(input [8*24-1:0] what, input [31:0] got, input [31:0] want);
        begin
            checks = checks + 1;
            if (got !== want) begin
                fails = fails + 1;
                if (fails <= 30)
                    $display("FAIL %0s: got %08h want %08h (cycle %0d raddr %03h waddr %03h we %b priv %b)",
                             what, got, want, cyc, raddr, waddr, we, priv);
            end
        end
    endtask

    // ── the model's state ────────────────────────────────────────────────
    reg        s_mie, s_mpie, s_mprv, s_tw, s_c;
    reg [1:0]  s_mpp;
    reg [31:0] s_mie_r, s_mtvec, s_mcounteren, s_mcountinhibit, s_mscratch, s_mepc, s_mcause, s_mtval;
    reg [31:0] s_pmpcfg, s_pa [0:3];
    reg [63:0] s_mcycle, s_minstret;
    reg        s_wr_q;          // the previous clock wrote mcycle or mcycleh

    task model_reset;
        integer k;
        begin
            s_mie = 0; s_mpie = 0; s_mprv = 0; s_tw = 0; s_mpp = 2'b00; s_c = 1;
            s_mie_r = 0; s_mtvec = 0; s_mcounteren = 0; s_mcountinhibit = 0; s_mscratch = 0;
            s_mepc = 0; s_mcause = 0; s_mtval = 0; s_pmpcfg = 0;
            for (k = 0; k < 4; k = k + 1) s_pa[k] = 0;
            s_mcycle = 0; s_minstret = 0; s_wr_q = 0;
        end
    endtask

    function [31:0] f_mstatus(input dummy);
        f_mstatus = {10'b0, s_tw, 3'b0, s_mprv, 4'b0, s_mpp, 3'b0, s_mpie, 3'b0, s_mie, 3'b0};
    endfunction
    function [31:0] f_misa(input dummy);
        f_misa = 32'h4010_1101 | (s_c ? 32'h4 : 32'h0);
    endfunction
    function [31:0] f_mepc(input dummy);             // as read
        f_mepc = {s_mepc[31:2], s_c ? s_mepc[1] : 1'b0, 1'b0};
    endfunction
    function [31:0] f_mip(input dummy);
        f_mip = (sirq ? 32'h8 : 0) | (tirq ? 32'h80 : 0) | (eirq ? 32'h800 : 0);
    endfunction
    function [7:0] cfg_legal(input [7:0] b);
        cfg_legal = {b[7], 2'b00, b[4:2], b[1] & b[0], b[0]};
    endfunction
    function addr_locked(input integer i);  // pmpaddr[i] frozen
        addr_locked = s_pmpcfg[8*i+7] ||
                      (i < 3 && s_pmpcfg[8*(i+1)+4 -: 2] == 2'b01 && s_pmpcfg[8*(i+1)+7]);
    endfunction
    // Counters as they stand after this clock's update, but for this
    // clock's write (what the read port returns: csr.v's read-port note).
    function [63:0] cyc_next(input dummy);
        cyc_next = (!s_mcountinhibit[0] && !w_mcycle(1'b0) && !s_wr_q) ? s_mcycle + 64'd1 : s_mcycle;
    endfunction
    function [63:0] ins_next(input dummy);
        ins_next = (instret_inc && !s_mcountinhibit[2] && !w_minstret(1'b0)) ? s_minstret + 64'd1 : s_minstret;
    endfunction
    function w_mcycle(input dummy);   w_mcycle   = we && (waddr == 12'hB00 || waddr == 12'hB80); endfunction
    function w_minstret(input dummy); w_minstret = we && (waddr == 12'hB02 || waddr == 12'hB82); endfunction

    // Implemented-address set (CPU reference section 7).
    function in_set(input [11:0] a);
        in_set = (a >= 12'hF11 && a <= 12'hF15) ||
                 a == 12'h300 || a == 12'h301 || a == 12'h304 || a == 12'h305 || a == 12'h306 ||
                 a == 12'h30A || a == 12'h310 || a == 12'h31A || a == 12'h320 ||
                 (a >= 12'h323 && a <= 12'h33F) || (a >= 12'h340 && a <= 12'h344) ||
                 (a >= 12'h3A0 && a <= 12'h3A3) || (a >= 12'h3B0 && a <= 12'h3BF) ||
                 a == 12'hB00 || a == 12'hB02 || (a >= 12'hB03 && a <= 12'hB1F) ||
                 a == 12'hB80 || a == 12'hB82 || (a >= 12'hB83 && a <= 12'hB9F) ||
                 a == 12'hC00 || a == 12'hC01 || a == 12'hC02 ||
                 a == 12'hC80 || a == 12'hC81 || a == 12'hC82;
    endfunction
    function e_valid(input [11:0] a);
        reg ok;
        begin
            ok = in_set(a);
            if (!priv && (a == 12'hC00 || a == 12'hC80) && !s_mcounteren[0]) ok = 0;
            if (!priv && (a == 12'hC01 || a == 12'hC81) && !s_mcounteren[1]) ok = 0;
            if (!priv && (a == 12'hC02 || a == 12'hC82) && !s_mcounteren[2]) ok = 0;
            e_valid = ok;
        end
    endfunction
    // Read value; `cnt_ok` is 0 when this clock writes a counter (the read is
    // then not checked: the pipeline never reads a CSR while a write is in WB).
    reg cnt_ok;
    function [31:0] e_rdata(input [11:0] a);
        reg [63:0] cn, in;
        begin
            cn = cyc_next(1'b0); in = ins_next(1'b0);
            case (a)
                12'hF12: e_rdata = MARCHID;
                12'h300: e_rdata = f_mstatus(1'b0);
                12'h301: e_rdata = f_misa(1'b0);
                12'h304: e_rdata = s_mie_r;
                12'h305: e_rdata = s_mtvec;
                12'h306: e_rdata = s_mcounteren;
                12'h320: e_rdata = s_mcountinhibit;
                12'h340: e_rdata = s_mscratch;
                12'h341: e_rdata = f_mepc(1'b0);
                12'h342: e_rdata = s_mcause;
                12'h343: e_rdata = s_mtval;
                12'h344: e_rdata = f_mip(1'b0);
                12'h3A0: e_rdata = s_pmpcfg;
                12'h3B0: e_rdata = s_pa[0];
                12'h3B1: e_rdata = s_pa[1];
                12'h3B2: e_rdata = s_pa[2];
                12'h3B3: e_rdata = s_pa[3];
                12'hB00, 12'hC00: e_rdata = cn[31:0];
                12'hB80, 12'hC80: e_rdata = cn[63:32];
                12'hB02, 12'hC02: e_rdata = in[31:0];
                12'hB82, 12'hC82: e_rdata = in[63:32];
                12'hC01: e_rdata = mtime_in[31:0];
                12'hC81: e_rdata = mtime_in[63:32];
                default: e_rdata = 32'h0;     // F11/F13-F15, mstatush, menvcfg(h), hpm, pmp 1-3/4-15
            endcase
        end
    endfunction

    // The post-write value of waddr for this clock's write (wval_out).
    function [31:0] e_wval(input dummy);
        reg [7:0] b; integer i;
        begin
            case (waddr)
                12'h300: e_wval = {10'b0, wdata[21], 3'b0, wdata[17], 4'b0,
                                   {2{wdata[12] & wdata[11]}}, 3'b0, wdata[7], 3'b0, wdata[3], 3'b0};
                12'h301: e_wval = (wdata[2] || !pc_mis) ? (32'h4010_1101 | (wdata[2] ? 32'h4 : 0)) : f_misa(1'b0);
                12'h304: e_wval = wdata & 32'h888;
                12'h305: e_wval = wdata & ~32'h3;
                12'h306: e_wval = wdata & 32'h7;
                12'h320: e_wval = wdata & 32'h5;
                12'h340, 12'h342, 12'h343: e_wval = wdata;
                12'h341: e_wval = {wdata[31:2], s_c ? wdata[1] : 1'b0, 1'b0};
                12'h344: e_wval = f_mip(1'b0);
                12'h3A0: begin
                    for (i = 0; i < 4; i = i + 1) begin
                        b = s_pmpcfg[8*i+7] ? s_pmpcfg[8*i +: 8] : cfg_legal(wdata[8*i +: 8]);
                        e_wval[8*i +: 8] = b;
                    end
                end
                12'h3B0: e_wval = addr_locked(0) ? s_pa[0] : wdata;
                12'h3B1: e_wval = addr_locked(1) ? s_pa[1] : wdata;
                12'h3B2: e_wval = addr_locked(2) ? s_pa[2] : wdata;
                12'h3B3: e_wval = addr_locked(3) ? s_pa[3] : wdata;
                12'hB00, 12'hB80, 12'hB02, 12'hB82: e_wval = wdata;
                default: e_wval = 32'h0;
            endcase
        end
    endfunction

    // Coverage of the cases the stimulus is meant to reach.
    integer cv_lock = 0, cv_torlock = 0, cv_lockedwr = 0, cv_misa_ref = 0, cv_cyc_carry = 0,
            cv_ins_carry = 0, cv_mpp_legal = 0, cv_trap_u = 0, cv_trap_m = 0, cv_mret_mprv = 0,
            cv_wr_hi = 0, cv_inhibit = 0, cv_uvalid = 0, cv_uinvalid = 0, cv_resets = 0;

    // One clock of the model, from the inputs as the edge sees them.
    task model_step;
        integer i; reg [7:0] b; reg [63:0] cn, in; reg mpp_m;
        begin
            if (rst) begin model_reset; end
            else begin
                cn = cyc_next(1'b0); in = ins_next(1'b0);
                if (cn[31:0] == 0 && s_mcycle[31:0] == 32'hFFFF_FFFF) cv_cyc_carry = cv_cyc_carry + 1;
                if (in[31:0] == 0 && s_minstret[31:0] == 32'hFFFF_FFFF) cv_ins_carry = cv_ins_carry + 1;
                if (s_mcountinhibit[0] || s_mcountinhibit[2]) cv_inhibit = cv_inhibit + 1;
                // 1. the write
                if (we) case (waddr)
                    12'h300: begin
                        s_mie = wdata[3]; s_mpie = wdata[7]; s_mprv = wdata[17]; s_tw = wdata[21];
                        s_mpp = (wdata[12:11] == 2'b11) ? 2'b11 : 2'b00;
                        if (wdata[12:11] == 2'b01 || wdata[12:11] == 2'b10) cv_mpp_legal = cv_mpp_legal + 1;
                    end
                    12'h301: if (wdata[2] || !pc_mis) s_c = wdata[2]; else cv_misa_ref = cv_misa_ref + 1;
                    12'h304: s_mie_r = wdata & 32'h888;
                    12'h305: s_mtvec = wdata & ~32'h3;
                    12'h306: s_mcounteren = wdata & 32'h7;
                    12'h320: s_mcountinhibit = wdata & 32'h5;
                    12'h340: s_mscratch = wdata;
                    12'h341: s_mepc = {wdata[31:1], 1'b0};
                    12'h342: s_mcause = wdata;
                    12'h343: s_mtval = wdata;
                    12'h3A0: for (i = 0; i < 4; i = i + 1)
                                 if (s_pmpcfg[8*i+7]) cv_lockedwr = cv_lockedwr + 1;
                                 else s_pmpcfg[8*i +: 8] = cfg_legal(wdata[8*i +: 8]);
                    12'h3B0, 12'h3B1, 12'h3B2, 12'h3B3: begin
                        i = waddr[1:0];
                        if (addr_locked(i)) begin
                            cv_lockedwr = cv_lockedwr + 1;
                            if (!s_pmpcfg[8*i+7]) cv_torlock = cv_torlock + 1;
                        end else s_pa[i] = wdata;
                    end
                    default: ;
                endcase
                // 2. trap / MRET, on top of the write
                if (trap) begin
                    s_mepc = trap_pc; s_mcause = trap_cause; s_mtval = trap_val;
                    s_mpie = s_mie; s_mie = 0; s_mpp = priv ? 2'b11 : 2'b00;
                    if (priv) cv_trap_m = cv_trap_m + 1; else cv_trap_u = cv_trap_u + 1;
                end else if (mret_sig) begin
                    mpp_m = (s_mpp == 2'b11);
                    if (!mpp_m && s_mprv) cv_mret_mprv = cv_mret_mprv + 1;
                    s_mie = s_mpie; s_mpie = 1; s_mpp = 2'b00;
                    if (!mpp_m) s_mprv = 0;
                end
                // 3. counters
                if (we && waddr == 12'hB00) s_mcycle[31:0] = wdata;
                else if (we && waddr == 12'hB80) begin s_mcycle[63:32] = wdata; cv_wr_hi = cv_wr_hi + 1; end
                else s_mcycle = cn;
                if (we && waddr == 12'hB02) s_minstret[31:0] = wdata;
                else if (we && waddr == 12'hB82) s_minstret[63:32] = wdata;
                else s_minstret = in;
                s_wr_q = w_mcycle(1'b0);
                for (i = 0; i < 4; i = i + 1) if (s_pmpcfg[8*i+7]) cv_lock = cv_lock + 1;
            end
        end
    endtask

    // Compare everything combinational, before the edge.
    task check_now;
        begin
            cnt_ok = !w_mcycle(1'b0) && !w_minstret(1'b0);
            chk("csr_addr_valid", {31'b0, csr_addr_valid}, {31'b0, e_valid(raddr)});
            if (e_valid(raddr) && (cnt_ok || !(raddr[11:8] == 4'hB || raddr[11:8] == 4'hC)))
                chk("rdata", rdata, e_rdata(raddr));
            chk("mtvec_out", mtvec_out, s_mtvec);
            chk("mepc_out", mepc_out, f_mepc(1'b0));
            chk("mstatus_mie", {31'b0, mstatus_mie}, {31'b0, s_mie});
            chk("mstatus_mpp", {30'b0, mstatus_mpp}, {30'b0, s_mpp});
            chk("mstatus_mprv", {31'b0, mstatus_mprv}, {31'b0, s_mprv});
            chk("mstatus_tw", {31'b0, mstatus_tw}, {31'b0, s_tw});
            chk("mie_out", mie_out, s_mie_r);
            chk("misa_c", {31'b0, misa_c}, {31'b0, s_c});
            chk("pmpcfg0_out", pmpcfg0_out, s_pmpcfg);
            chk("pmpaddr0_out", pa0, s_pa[0]); chk("pmpaddr1_out", pa1, s_pa[1]);
            chk("pmpaddr2_out", pa2, s_pa[2]); chk("pmpaddr3_out", pa3, s_pa[3]);
            if (we && in_set(waddr)) chk("wval_out", wval_out, e_wval(1'b0));
        end
    endtask

    // ── stimulus ─────────────────────────────────────────────────────────
    function integer ur(input integer n);
        ur = $unsigned($random(seed)) % n;
    endfunction
    reg [11:0] wlist [0:39];
    integer nw = 0;
    initial begin
        wlist[0] = 12'h300; wlist[1] = 12'h301; wlist[2] = 12'h304; wlist[3] = 12'h305;
        wlist[4] = 12'h306; wlist[5] = 12'h320; wlist[6] = 12'h340; wlist[7] = 12'h341;
        wlist[8] = 12'h342; wlist[9] = 12'h343; wlist[10] = 12'h344; wlist[11] = 12'h3A0;
        wlist[12] = 12'h3B0; wlist[13] = 12'h3B1; wlist[14] = 12'h3B2; wlist[15] = 12'h3B3;
        wlist[16] = 12'hB00; wlist[17] = 12'hB80; wlist[18] = 12'hB02; wlist[19] = 12'hB82;
        wlist[20] = 12'h310; wlist[21] = 12'h30A; wlist[22] = 12'h31A; wlist[23] = 12'h3A1;
        wlist[24] = 12'h3B7; wlist[25] = 12'hB03; wlist[26] = 12'hB9F; wlist[27] = 12'h323;
        wlist[28] = 12'hF14; wlist[29] = 12'hC00; wlist[30] = 12'hC81; wlist[31] = 12'h3BF;
        wlist[32] = 12'h300; wlist[33] = 12'h3A0; wlist[34] = 12'h3B1; wlist[35] = 12'hB00;
        wlist[36] = 12'hB02; wlist[37] = 12'h301; wlist[38] = 12'h341; wlist[39] = 12'h320;
        nw = 40;
    end

    task pick_inputs;
        reg [31:0] r;
        begin
            // reads: every implemented address in turn, or anything
            raddr = (ur(4) == 0) ? $random(seed) : wlist[ur(nw)];
            if (ur(8) == 0) raddr = 12'hC00 + ur(3) + (ur(2) ? 12'h80 : 0);
            if (ur(6) == 0) raddr = 12'hF11 + ur(5);
            we = (ur(3) == 0);
            waddr = (ur(10) == 0) ? $random(seed) : wlist[ur(nw)];
            r = $random(seed);
            case (ur(10))
                0: wdata = 32'hFFFF_FFFF;
                1: wdata = 32'h0;
                2: wdata = 32'hFFFF_FFFE - ur(3);          // near a counter rollover
                default: wdata = r;
            endcase
            // pmpcfg0: lock rarely, so most of the time entries are writable;
            // TOR+L on the entry above makes pmpaddr[i] locked by i+1.
            if (waddr == 12'h3A0 && wdata != 32'hFFFF_FFFF) begin
                wdata = wdata & ~32'h8080_8080;
                if (ur(16) == 0) wdata[8 * ur(4) + 7] = 1'b1;
                if (ur(8) == 0) begin wdata[15:8] = {1'b1, 2'b00, 2'b01, 3'b011}; end
            end
            if (waddr == 12'h320 && ur(2)) wdata = wdata & ~32'h5;   // mostly counting
            if (waddr == 12'h301 && ur(2)) wdata[2] = 1'b0;          // try to clear C
            if (waddr == 12'h300 && ur(3) == 0) wdata[12:11] = 2'b01 + ur(2);
            trap = 0; mret_sig = 0;
            if (!we && ur(12) == 0) begin
                trap = 1; trap_pc = $random(seed) & ~32'h1; trap_cause = $random(seed); trap_val = $random(seed);
            end else if (!we && ur(12) == 0) mret_sig = 1;
            priv = (ur(4) != 0);
            instret_inc = ur(2);
            tirq = ur(2); eirq = ur(2); sirq = ur(2);
            mtime_in = {$random(seed), $random(seed)};
            pc_mis = ur(2);
        end
    endtask

    integer a, p, k, ce;
    initial begin
        if ($value$plusargs("SEED=%d", seed)) ;
        seed0 = seed;   // $random(seed) moves seed on: report the one that reproduces the run
        if ($value$plusargs("NCYC=%d", ncyc)) ;
        $display("=== CSR Testbench (model, seed %0d, %0d clocks) ===", seed, ncyc);
        model_reset;
        rst = 1; @(negedge clk); @(posedge clk); model_step; @(negedge clk);
        rst = 0;

        // Reset values and every address's validity, both privileges, each
        // mcounteren value (set through the bus, so it is the DUT's own).
        for (ce = 0; ce < 8; ce = ce + 1) begin
            we = 1; waddr = 12'h306; wdata = ce; #1;
            @(posedge clk); model_step; @(negedge clk); we = 0;
            clk_en = 0;
            for (p = 0; p < 2; p = p + 1) begin
                priv = p;
                for (a = 0; a < 4096; a = a + 1) begin
                    raddr = a; #1;
                    chk("csr_addr_valid sweep", {31'b0, csr_addr_valid}, {31'b0, e_valid(raddr)});
                    if (e_valid(raddr) && raddr[11:8] != 4'hB && raddr[11:8] != 4'hC)
                        chk("rdata sweep", rdata, e_rdata(raddr));
                    if (!p && (a == 12'hC00 || a == 12'hC01 || a == 12'hC02))
                        if (e_valid(raddr)) cv_uvalid = cv_uvalid + 1; else cv_uinvalid = cv_uinvalid + 1;
                end
            end
            priv = 1;
            clk_en = 1;
        end

        // The random run.
        for (cyc = 0; cyc < ncyc; cyc = cyc + 1) begin
            pick_inputs;
            if (ur(5000) == 0) begin rst = 1; cv_resets = cv_resets + 1; end
            #1;
            if (!rst) check_now;
            @(posedge clk);
            model_step;
            @(negedge clk);
            if (rst) begin
                rst = 0;
                // reset values, before anything is written (clock held, as
                // for the sweep: these reads take 40 ns with no edge)
                we = 0; trap = 0; mret_sig = 0;
                clk_en = 0;
                for (k = 0; k < nw; k = k + 1) begin
                    raddr = wlist[k]; #1;
                    if (raddr[11:8] != 4'hB && raddr[11:8] != 4'hC) chk("after reset", rdata, e_rdata(raddr));
                end
                clk_en = 1;
            end
        end

        $display("coverage: locks %0d, TOR locks %0d, locked writes %0d, misa clears refused %0d, mcycle carries %0d, minstret carries %0d,",
                 cv_lock, cv_torlock, cv_lockedwr, cv_misa_ref, cv_cyc_carry, cv_ins_carry);
        $display("          MPP legalised %0d, traps from U %0d / M %0d, MRET clearing MPRV %0d, high-half writes %0d, inhibited clocks %0d, resets %0d",
                 cv_mpp_legal, cv_trap_u, cv_trap_m, cv_mret_mprv, cv_wr_hi, cv_inhibit, cv_resets);
        if (cv_lock == 0 || cv_torlock == 0 || cv_lockedwr == 0 || cv_misa_ref == 0 || cv_cyc_carry == 0 ||
            cv_ins_carry == 0 || cv_mpp_legal == 0 || cv_trap_u == 0 || cv_trap_m == 0 ||
            cv_mret_mprv == 0 || cv_wr_hi == 0 || cv_inhibit == 0 || cv_uvalid == 0 ||
            cv_uinvalid == 0 || (ncyc >= 100000 && cv_resets == 0)) begin
            fails = fails + 1;
            $display("FAIL coverage: a case the random run must reach was not reached");
        end
        if (fails == 0) $display("PASS tb_csr (%0d checks, seed %0d)", checks, seed0);
        else            $display("FAIL tb_csr: %0d failures, %0d checks, seed %0d", fails, checks, seed0);
        $finish;
    end

    initial begin
        #(64'd10 * 64'd10_000_000);
        $display("TIMEOUT tb_csr");
        $finish;
    end
endmodule
