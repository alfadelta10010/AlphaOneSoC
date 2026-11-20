// Unit testbench for src/plic.v (sifive,plic-1.0.0 subset: 9 level sources, one M-mode context, 1-bit
// priorities and threshold). Everything is predicted by a model written from the RISC-V PLIC spec
// (priority / pending / enable / threshold / claim-complete, gateway) and the Linux irq-sifive-plic.c
// access sequences, not from the RTL:
//   * every read (all 32 bits) is compared with the model, every cycle that has sel & !we;
//   * meip is compared with the model every clock (registered: "some source is pending, enabled, with
//     priority above the threshold" one clock earlier);
//   * a claim returns the lowest id among the eligible sources (priorities are all equal when eligible),
//     0 when none, and moves pending -> in service; a source in service is not re-pended; a complete of
//     an enabled id ends the service (a complete of a disabled or out-of-range id is ignored);
//   * only full-word writes act; reserved offsets read 0 and ignore writes (no aliasing in the 4 MB window).
// Accesses are single-cycle selects (soc_bus asserts select for one cycle per access); between accesses
// sel is low and the other inputs carry random values.
// Plusargs: +SEED=<n>, +NRAND=<n> random operations. Prints PASS or FAIL lines.

`timescale 1ns / 1ps

module tb_plic;
    localparam NS = 9;
    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    reg         sel = 0, we = 0;
    reg  [3:0]  be = 0;
    reg  [21:2] addr = 0;
    reg  [31:0] wdata = 0;
    reg  [NS:1] src = 0;
    wire [31:0] rdata;
    wire        meip;

    plic #(.NSRC(NS)) dut (.clk(clk), .rst(rst), .sel(sel), .we(we), .be(be), .addr(addr), .wdata(wdata),
                           .rdata(rdata), .src(src), .meip(meip));

    // word addresses
    localparam [19:0] A_PND = 20'h00400, A_EN = 20'h00800, A_THR = 20'h80000, A_CLM = 20'h80001;
    function [19:0] a_pri; input integer i; begin a_pri = i; end endfunction

    // ---------------- model ----------------
    reg [NS:1] m_pend, m_en, m_prio, m_insvc;
    reg        m_thr, m_meip;
    reg [NS:1] m_rep;                // re-pend wanted (set by a completion with the level still high)
    integer    seed, seed0, checks, fails, cyc;
    integer    n_claims, n_ign, n_rep, n_cplx;
    reg [NS:1] seen;
    reg [NS:1] mode_hold, mode_tog, mode_pls;   // per-source stimulus mode

    function [NS:1] m_elig; input dummy; begin
        m_elig = m_pend & m_en & m_prio & {NS{!m_thr}};
    end endfunction

    function [4:0] m_cid; input [NS:1] e; integer k; begin
        m_cid = 0;
        for (k = NS; k >= 1; k = k - 1) if (e[k]) m_cid = k;
    end endfunction

    function [31:0] m_read; input [19:0] a; integer k; begin
        m_read = 0;
        if (a >= 1 && a <= NS) m_read = {31'd0, m_prio[a]};
        else if (a == A_PND) m_read = {22'd0, m_pend, 1'b0};
        else if (a == A_EN)  m_read = {22'd0, m_en, 1'b0};
        else if (a == A_THR) m_read = {31'd0, m_thr};
        else if (a == A_CLM) m_read = {27'd0, m_cid(m_elig(0))};
    end endfunction

    task fail; input [255:0] what; begin
        fails = fails + 1;
        if (fails < 20) $display("FAIL %0s at cycle %0d (sel=%b we=%b be=%h addr=%h wdata=%h src=%b rdata=%h)",
                                 what, cyc, sel, we, be, addr, wdata, src, rdata);
    end endtask

    // one clock: inputs already applied; check, then update the model with the pre-edge state
    task step;
        reg [NS:1] e, np, ni, nrp, pe;
        reg [4:0]  cid;
        reg        rdn, wrn;
        integer    k;
        begin
            #3;
            cid = m_cid(m_elig(0));
            rdn = sel && !we;
            wrn = sel && we && (be == 4'b1111);
            if (rdn) begin
                checks = checks + 1;
                if (rdata !== m_read(addr)) begin fails = fails + 1;
                    if (fails < 20) $display("FAIL read addr %h: got %h want %h (cycle %0d)", addr, rdata, m_read(addr), cyc); end
            end
            checks = checks + 1;
            if (!rst && meip !== m_meip) begin fails = fails + 1;
                if (fails < 20) $display("FAIL meip got %b want %b (cycle %0d)", meip, m_meip, cyc); end
            @(posedge clk);
            // update from pre-edge state
            e = m_elig(0);
            np = m_pend; ni = m_insvc; nrp = m_rep;
            for (k = 1; k <= NS; k = k + 1) begin
                if (rdn && addr == A_CLM && cid == k) begin np[k] = 0; ni[k] = 1; end
                else begin
                    if (src[k] && !m_insvc[k]) begin
                        if (!m_pend[k] && m_rep[k]) begin n_rep = n_rep + 1; nrp[k] = 0; end
                        np[k] = 1;
                    end
                    if (wrn && addr == A_CLM && wdata == k) begin
                        if (m_en[k]) begin
                            ni[k] = 0; if (m_insvc[k] && src[k]) nrp[k] = 1;
                        end else if (m_insvc[k]) n_ign = n_ign + 1;
                    end
                end
            end
            if (rdn && addr == A_CLM && cid != 0) begin n_claims = n_claims + 1; seen[cid] = 1; end
            m_meip <= |e;
            m_pend <= np; m_insvc <= ni; m_rep <= nrp;
            if (wrn && addr >= 1 && addr <= NS) m_prio[addr] <= (wdata != 0);
            if (wrn && addr == A_EN)  m_en  <= wdata[NS:1];
            if (wrn && addr == A_THR) m_thr <= (wdata != 0);
            cyc = cyc + 1;
            #1;
        end
    endtask

    // random value
    function integer rn; input integer m; integer r; begin r = $random(seed); if (r < 0) r = -r; rn = r % m; end endfunction

    // next source levels
    task drive_src; integer k; begin
        for (k = 1; k <= NS; k = k + 1) begin
            if (mode_pls[k]) begin src[k] = (rn(8) == 0); end
            else if (mode_tog[k]) src[k] = rn(2);
            // hold: unchanged
        end
    end endtask

    // idle cycle: sel low, junk elsewhere
    task idle; begin
        sel = 0; we = rn(2); be = rn(16); addr = (rn(3) == 0) ? A_CLM : rn(1<<20); wdata = $random(seed);
        drive_src; step;
    end endtask

    task rd_op; input [19:0] a; begin
        sel = 1; we = 0; be = rn(16); addr = a; wdata = $random(seed); drive_src; step; idle;
    end endtask
    task wr_op; input [19:0] a; input [31:0] d; input [3:0] b; begin
        sel = 1; we = 1; be = b; addr = a; wdata = d; drive_src; step; idle;
    end endtask
    task wr; input [19:0] a; input [31:0] d; begin wr_op(a, d, 4'hF); end endtask

    // claim and return the id the model predicted (the bench has already checked the read)
    reg [4:0] last_claim;
    task claim; begin last_claim = m_cid(m_elig(0)); rd_op(A_CLM); end endtask

    // ---------------- stimulus ----------------
    integer i, j, n, nrand, r;
    reg [31:0] v;
    reg [4:0]  id;
    reg        pr;

    // Linux enable_irq: RMW the enable word, priority 1
    task enable_irq; input integer n; begin
        rd_op(A_EN); wr(A_EN, m_en_word(0) | (32'd1 << n)); wr(n, 1);
    end endtask
    function [31:0] m_en_word; input dummy; begin m_en_word = {22'd0, m_en, 1'b0}; end endfunction
    task disable_irq_hw; input integer n; begin
        rd_op(A_EN); wr(A_EN, m_en_word(0) & ~(32'd1 << n));
    end endtask
    // handler loop
    task handler; integer guard; begin
        guard = 0; claim;
        while (last_claim != 0 && guard < 40) begin
            idle; wr(A_CLM, last_claim); guard = guard + 1; claim;
        end
    end endtask

    initial begin
        if (!$value$plusargs("SEED=%d", seed)) seed = 1;
        if (!$value$plusargs("NRAND=%d", nrand)) nrand = 6000;
        seed0 = seed; checks = 0; fails = 0; cyc = 0; n_claims = 0; n_ign = 0; n_rep = 0; seen = 0; last_claim = 0;
        m_pend = 0; m_en = 0; m_prio = 0; m_insvc = 0; m_thr = 0; m_meip = 0; m_rep = 0;
        mode_hold = 0; mode_tog = 0; mode_pls = 0;
        rst = 1; src = 0;
        repeat (3) begin sel = 0; step; end
        #0 rst = 0;
        // reset applied: model values already zero. Make sure sources were low in reset.
        idle; idle;

        // phase 1: reset values and reserved offsets
        for (i = 0; i < 12; i = i + 1) rd_op(i);
        rd_op(A_PND); rd_op(A_EN); rd_op(A_EN + 1); rd_op(A_THR); rd_op(A_CLM);
        for (i = 0; i < 64; i = i + 1) begin
            v = rn(1<<20);
            if (v >= 1 && v <= NS || v == A_PND || v == A_EN || v == A_THR || v == A_CLM) v = v ^ 20'h40000;
            rd_op(v[19:0]);
        end
        for (i = 10; i < 40; i = i + 1) begin wr(i, 1); rd_op(i); end   // reserved priority ids ignore writes
        wr(0, 1); rd_op(0);

        // phase 2: the Linux sequence
        for (i = 1; i <= NS; i = i + 1) begin           // probe
            rd_op(A_EN); wr(A_EN, m_en_word(0) & ~(32'd1 << i)); wr(i, 1);
        end
        wr(A_THR, 0);
        for (i = 1; i <= NS; i = i + 1) enable_irq(i);
        for (i = 1; i <= NS; i = i + 1) begin
            // level asserted, handled, completed
            src[i] = 1; mode_hold[i] = 1; idle; idle; idle;
            handler; src[i] = 0; idle; idle; handler; idle;
        end
        // all at once: lowest id first
        src = {NS{1'b1}}; idle; idle; handler; src = 0; idle; idle; handler;
        // mask / unmask with a level held
        src[3] = 1; src[5] = 1; idle; idle;
        wr(3, 0); claim; idle; wr(3, 1); claim; idle; wr(A_CLM, last_claim); idle; handler;
        src = 0; idle; idle; handler;
        // disable_irq then EOI
        src[4] = 1; idle; idle; claim; idle;
        disable_irq_hw(4); wr(A_EN, m_en_word(0) | 32'h10); wr(A_CLM, 4); idle; // complete (enabled)
        wr(A_EN, m_en_word(0) & ~32'h10);
        src = 0; idle; handler; idle;
        // threshold 7 / 0
        src[2] = 1; idle; idle; wr(A_THR, 7); idle; idle; rd_op(A_CLM); wr(A_THR, 0); idle; idle; handler;
        src = 0; idle; handler;

        // phase 4a: level drops before the claim (pending stays)
        for (i = 1; i <= NS; i = i + 1) begin
            wr(A_THR, 1); src[i] = 1; idle; idle; src[i] = 0; idle; idle; rd_op(A_PND);
            wr(A_THR, 0); idle; idle; handler; idle;
        end
        // phase 4b: level held through complete (must re-pend); complete of a disabled id while in service
        for (i = 1; i <= NS; i = i + 1) begin
            src[i] = 1; idle; idle; claim; idle; wr(A_CLM, last_claim); idle; idle; rd_op(A_PND);
            rd_op(A_CLM); idle; src[i] = 0; idle; wr(A_CLM, i); idle; idle; handler;
        end
        for (i = 1; i <= NS; i = i + 1) begin           // complete while disabled is ignored
            src[i] = 1; idle; idle; claim; idle;
            wr(A_EN, m_en_word(0) & ~(32'd1 << i)); wr(A_CLM, i); wr(A_CLM, i); idle; idle; rd_op(A_PND);
            wr(A_EN, 32'h3FE); idle; src[i] = 0; idle; handler;
        end

        // phase 3: random
        for (n = 0; n < nrand; n = n + 1) begin
            r = rn(100);
            if (rn(40) == 0) begin
                mode_hold = $random(seed); mode_tog = $random(seed) & $random(seed) & $random(seed);
                mode_pls = $random(seed) & $random(seed) & $random(seed); mode_tog = mode_tog & ~mode_pls;
                src = $random(seed);
            end
            if (r < 22) rd_op(A_CLM);
            else if (r < 40) begin
                case (rn(6))
                    0, 1, 2: v = (last_claim != 0) ? last_claim : (1 + rn(NS));
                    3: v = rn(34);
                    4: v = (32'd1 << (1 + rn(31))) | ((rn(2)) ? 1 + rn(NS) : 0);
                    default: v = 1 + rn(NS);
                endcase
                wr(A_CLM, v);
            end
            else if (r < 48) begin
                case (rn(4)) 0: v = 32'h3FE; 1: v = $random(seed); 2: v = m_en_word(0) | (32'd2 << rn(NS)); default: v = m_en_word(0) & ~(32'd2 << rn(NS)); endcase
                wr(A_EN, v);
            end
            else if (r < 58) begin
                case (rn(4)) 0: v = 0; 1: v = 1; 2: v = $random(seed); default: v = 1; endcase
                wr(1 + rn(NS), v);
            end
            else if (r < 62) wr(A_THR, (rn(5) == 0) ? ((rn(2)) ? $random(seed) : 1) : 0);
            else if (r < 68) begin
                case (rn(5)) 0: rd_op(A_PND); 1: rd_op(A_EN); 2: rd_op(A_THR); 3: rd_op(1 + rn(NS)); default: rd_op(A_EN + 1 + rn(4)); endcase
            end
            else if (r < 74) begin                      // reserved offsets: write and read back
                v = rn(1<<20);
                if (v >= 1 && v <= NS || v == A_PND || v == A_EN || v == A_THR || v == A_CLM) v = v ^ 20'h40000;
                wr(v[19:0], $random(seed) | 1); rd_op(v[19:0]);
            end
            else if (r < 82) begin                      // partial writes to the real registers
                case (rn(5)) 0: id = 1 + rn(NS); 1: id = 0; default: id = 0; endcase
                case (rn(5)) 0: v = A_EN; 1: v = A_THR; 2: v = A_CLM; 3: v = 1 + rn(NS); default: v = A_EN; endcase
                wr_op(v[19:0], (v == A_CLM) ? (1 + rn(NS)) : ($random(seed) | 32'hFFFFFFFF), rn(15));
            end
            else if (r < 90) handler;
            else begin repeat (1 + rn(3)) idle; end
        end
        // the model must have seen the corner cases
        mode_hold = 0; mode_tog = 0; mode_pls = 0; src = 0;
        repeat (4) idle;

        if (n_claims < 200) begin fails = fails + 1; $display("FAIL floor: %0d claims < 200", n_claims); end
        if (seen != {NS{1'b1}}) begin fails = fails + 1; $display("FAIL floor: ids claimed %b", seen); end
        if (n_ign < 50) begin fails = fails + 1; $display("FAIL floor: %0d ignored completions < 50", n_ign); end
        if (n_rep < 20) begin fails = fails + 1; $display("FAIL floor: %0d re-pends < 20", n_rep); end
        $display("INFO claims=%0d ids=%b ignored=%0d repends=%0d", n_claims, seen, n_ign, n_rep);
        if (fails == 0) $display("PASS %0d checks seed %0d", checks, seed0);
        else $display("FAIL %0d failures seed %0d", fails, seed0);
        $finish;
    end

    initial begin #(100_000_000); $display("TIMEOUT tb_plic"); $finish; end
endmodule
