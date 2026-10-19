`timescale 1ns / 1ps
// pmp (src/pmp.v) against Privileged spec 3.7.1 and
// docs/FyraCore_CPU_Reference.md 6.3 (REQ-PMP-001, REQ-PMP-002):
//
//   * matching on the 34-bit physical address, pmpaddr holding PA[33:2]:
//     OFF; TOR, pmpaddr[i-1] <= a < pmpaddr[i], with 0 below entry 0; NA4,
//     the one word; NAPOT, the naturally aligned 2^(t+3)-byte region of a
//     pmpaddr with t trailing ones (all ones: everything). The model counts
//     the trailing ones and compares the bits above them;
//   * the lowest-numbered matching entry decides; with no match M is allowed
//     and U refused; an unlocked entry binds U only, a locked one M as well;
//     an access needs every permission it asks for (R, W, R+W for an AMO, X).
// Configurations are drawn the way pmpcfg can hold them (csr.v's WARL: no
// R=0,W=1, bits 6:5 zero). Addresses are biased to region edges -- the
// word below, at, and above every bound -- and regions are drawn small,
// large, overlapping, above 4 GB and all-ones. Seeded (+SEED=, +N=). Prints
// PASS/FAIL with the number of checks and fails if a case was never hit.
module tb_pmp;
    reg  [31:0] cfg, pa0, pa1, pa2, pa3, addr;
    reg  [2:0]  at;
    reg         priv;
    wire        allow;
    pmp uut(.pmpcfg0(cfg), .pmpaddr0(pa0), .pmpaddr1(pa1), .pmpaddr2(pa2), .pmpaddr3(pa3),
            .addr(addr), .access_type(at), .priv_mode(priv), .pmp_allow(allow));

    integer checks = 0, fails = 0, seed = 1, n = 400000, i;
    integer seed0 = 1;
    integer cv_mode [0:3];      // matches decided by OFF/TOR/NA4/NAPOT
    integer cv_nomatch_u = 0, cv_nomatch_m = 0, cv_lock_m = 0, cv_prio = 0, cv_hi4g = 0, cv_all = 0;

    function [31:0] paddr(input integer k);
        case (k) 0: paddr = pa0; 1: paddr = pa1; 2: paddr = pa2; default: paddr = pa3; endcase
    endfunction

    // NAPOT: trailing ones t of p; region = the words whose bits above bit t
    // equal p's.
    function napot(input [31:0] p, input [33:0] wa);
        integer t; reg [33:0] pp;
        begin
            t = 0;
            while (t < 32 && p[t]) t = t + 1;
            pp = {2'b00, p};
            if (t >= 32) napot = 1'b1;                  // all ones: every address
            else napot = ((wa >> (t + 1)) == (pp >> (t + 1)));
        end
    endfunction

    reg e_allow; integer e_entry, e_matches;
    task model;
        integer k; reg [33:0] wa, lo, hi; reg [7:0] c; reg m;
        begin
            wa = {2'b00, addr} >> 2;        // PA[33:2]
            e_entry = -1; e_matches = 0;
            for (k = 3; k >= 0; k = k - 1) begin
                c  = cfg[8*k +: 8];
                hi = {2'b00, paddr(k)};
                lo = (k == 0) ? 34'd0 : {2'b00, paddr(k - 1)};
                case (c[4:3])
                    2'b00: m = 0;
                    2'b01: m = (wa >= lo) && (wa < hi);
                    2'b10: m = (wa == hi);
                    2'b11: m = napot(paddr(k), wa);
                endcase
                if (m) begin e_entry = k; e_matches = e_matches + 1; end
            end
            if (e_entry < 0) e_allow = priv;
            else begin
                c = cfg[8*e_entry +: 8];
                e_allow = (priv && !c[7]) || ((c[2:0] & at) == at);
            end
        end
    endtask

    function [7:0] legal_cfg(input [7:0] b);
        legal_cfg = {b[7], 2'b00, b[4:2], b[1] & b[0], b[0]};
    endfunction
    function [31:0] rnd_paddr(input integer dummy);
        case ($unsigned($random(seed)) % 8)
            0: rnd_paddr = 32'h2000_0000 + ($random(seed) & 32'h3FF);          // 0x8000_0000 >> 2 region
            1: rnd_paddr = 32'h0800_0000 + ($random(seed) & 32'hFFFF);         // flash >> 2
            2: rnd_paddr = 32'h4000_0000 | $random(seed);                      // above 4 GB
            3: rnd_paddr = (32'h2000_0000 | (($random(seed) & 32'hFFF) << 4)) | ((32'h1 << ($unsigned($random(seed)) % 12)) - 1); // NAPOT-shaped
            4: rnd_paddr = 32'hFFFF_FFFF;
            5: rnd_paddr = 32'h0;
            default: rnd_paddr = $random(seed);
        endcase
    endfunction
    // An address near one of the bounds the configuration has: the words
    // around each pmpaddr (a TOR bound or an NA4 word), or around either end
    // of the NAPOT region a pmpaddr encodes.
    function [31:0] rnd_addr(input integer dummy);
        reg [31:0] q, m, base; integer k, d;
        begin
            k = $unsigned($random(seed)) % 4;
            q = paddr(k);
            d = ($unsigned($random(seed)) % 5) - 2;          // -2..+2 words
            m = q & ~(q + 1);                                // trailing ones, in words
            base = {q[29:0], 2'b00} & ~{m[29:0], 2'b11};     // the region's first byte
            case ($unsigned($random(seed)) % 6)
                0: rnd_addr = $random(seed);
                1: rnd_addr = {q[29:0], 2'b00} + 4 * d + ($random(seed) & 3);
                2: rnd_addr = base + 4 * d;
                3: rnd_addr = (base | {m[28:0], 3'b111}) + 4 * d;   // the region's last byte
                default: rnd_addr = {q[29:0], 2'b00} + 4 * d;
            endcase
        end
    endfunction

    initial begin
        if ($value$plusargs("SEED=%d", seed)) ;
        seed0 = seed;   // $random(seed) moves seed on: report the one that reproduces the run
        if ($value$plusargs("N=%d", n)) ;
        $display("=== PMP Testbench (Priv 3.7.1 model, seed %0d) ===", seed);
        for (i = 0; i < 4; i = i + 1) cv_mode[i] = 0;
        for (i = 0; i < n; i = i + 1) begin
            if (i % 64 == 0) begin
                cfg = {legal_cfg($random(seed)), legal_cfg($random(seed)),
                       legal_cfg($random(seed)), legal_cfg($random(seed))};
                if ($unsigned($random(seed)) % 2) cfg = cfg & ~32'h8080_8080;   // mostly unlocked
                pa0 = rnd_paddr(0); pa1 = rnd_paddr(0); pa2 = rnd_paddr(0); pa3 = rnd_paddr(0);
                // ordered TOR bounds half of the time
                if ($unsigned($random(seed)) % 2) begin
                    pa1 = pa0 + ($random(seed) & 32'hFF); pa2 = pa1 + ($random(seed) & 32'hFF);
                    pa3 = pa2 + ($random(seed) & 32'hFFFF);
                end
            end
            addr = rnd_addr(0);
            case ($unsigned($random(seed)) % 4)
                0: at = 3'b001; 1: at = 3'b010; 2: at = 3'b011; default: at = 3'b100;
            endcase
            priv = $random(seed);
            #1;
            model;
            checks = checks + 1;
            if (allow !== e_allow) begin
                fails = fails + 1;
                if (fails <= 25)
                    $display("FAIL cfg=%08h pmpaddr=%08h %08h %08h %08h addr=%08h type=%03b priv=%b: allow %b want %b (entry %0d)",
                             cfg, pa0, pa1, pa2, pa3, addr, at, priv, allow, e_allow, e_entry);
            end
            if (e_entry >= 0) begin
                cv_mode[cfg[8*e_entry+3 +: 2]] = cv_mode[cfg[8*e_entry+3 +: 2]] + 1;
                if (e_matches > 1) cv_prio = cv_prio + 1;
                if (priv && cfg[8*e_entry+7]) cv_lock_m = cv_lock_m + 1;
                if (paddr(e_entry) >= 32'h4000_0000) cv_hi4g = cv_hi4g + 1;
                if (cfg[8*e_entry+3 +: 2] == 2'b11 && paddr(e_entry) == 32'hFFFF_FFFF) cv_all = cv_all + 1;
            end else if (priv) cv_nomatch_m = cv_nomatch_m + 1;
            else cv_nomatch_u = cv_nomatch_u + 1;
        end
        $display("decided by TOR %0d, NA4 %0d, NAPOT %0d (all-ones %0d), several matching %0d, locked in M %0d, bound above 4 GB %0d, no match M %0d / U %0d",
                 cv_mode[1], cv_mode[2], cv_mode[3], cv_all, cv_prio, cv_lock_m, cv_hi4g, cv_nomatch_m, cv_nomatch_u);
        if (cv_mode[1] == 0 || cv_mode[2] == 0 || cv_mode[3] == 0 || cv_all == 0 || cv_prio == 0 ||
            cv_lock_m == 0 || cv_hi4g == 0 || cv_nomatch_m == 0 || cv_nomatch_u == 0) begin
            fails = fails + 1;
            $display("FAIL coverage: a matching case was never reached");
        end
        if (fails == 0) $display("PASS tb_pmp (%0d checks, seed %0d)", checks, seed0);
        else            $display("FAIL tb_pmp: %0d failures, %0d checks, seed %0d", fails, checks, seed0);
        $finish;
    end
endmodule
