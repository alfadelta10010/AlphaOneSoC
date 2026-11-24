// pmp — Physical Memory Protection checker (RV32, 4 regions, TOR + NAPOT, 4 KiB grain)
//
// Two instances are used in fyracore: one for instruction-fetch (X), one for data (R/W).
// All pmpaddr/pmpcfg registers are shared between instances.
//
// access_type encoding (matches pmpcfg R/W/X bit positions):
//   3'b001 = Read  (load)
//   3'b010 = Write (store/AMO)
//   3'b100 = Execute (instruction fetch)
//
// Priority: entry 0 > 1 > 2 > 3 (first matching entry wins).
// No matching entry → M-mode allowed, U-mode denied.
// Locked entry (L=1) enforces permissions on M-mode as well.

module pmp(
    input  wire [31:0] pmpcfg0,
    input  wire [31:0] pmpaddr0,
    input  wire [31:0] pmpaddr1,
    input  wire [31:0] pmpaddr2,
    input  wire [31:0] pmpaddr3,
    input  wire [31:0] addr,        // byte address to check
    input  wire [2:0]  access_type, // 3'b001=R, 3'b010=W, 3'b100=X
    input  wire        priv_mode,   // 1=M, 0=U
    output reg         pmp_allow
);

    // Config byte per entry
    wire [7:0] cfg0 = pmpcfg0[7:0];
    wire [7:0] cfg1 = pmpcfg0[15:8];
    wire [7:0] cfg2 = pmpcfg0[23:16];
    wire [7:0] cfg3 = pmpcfg0[31:24];

    // cfg[i] bit layout:
    //   [0]   R  (read permission)
    //   [1]   W  (write permission)
    //   [2]   X  (execute permission)
    //   [4:3] A  (00=OFF, 01=TOR, 10=NA4, 11=NAPOT)
    //   [7]   L  (locked; entry applies to M-mode too and cannot be modified)

    localparam A_OFF   = 2'b00;
    localparam A_TOR   = 2'b01;
    localparam A_NAPOT = 2'b11;
    // A = 2'b10 (NA4) is not selectable at this core's PMP grain (G = 10,
    // 4 KiB: Priv spec 3.7.1) and csr.v stores a write of it as NAPOT, so
    // the A[1] bit alone tells NAPOT from OFF/TOR below.

    // The grain is 4 KiB and PA[33:32] are not implemented (pmpaddr[31:30]
    // read zero), so only the page address PA[31:12] = addr[31:12] is
    // compared. pmpaddr[i] = PA[33:2] of its bound; with the grain, bits
    // [9:0] never matter for TOR (they read zero), and for NAPOT bits [8:0]
    // read all ones and bit 9 is the terminating bit.
    //
    // A region at or above 4 GB is not expressible; the all-ones NAPOT
    // pmpaddr (0x3FFF_FFFF) is the whole 32-bit space.
    wire [19:0] pg  = addr[31:12];      // page address
    wire [20:0] pg2 = addr[31:11];      // half-page address: the NAPOT compare

    // ── NAPOT match ──────────────────────────────────────────────────────────
    // p = pmpaddr[29:9], read value (the nine low ones are implied). With t
    // trailing ones in p the region is 2^(t+12) bytes; only the bits above
    // the trailing ones and their terminating zero have to match. p ^ (p+1)
    // is exactly those low t+1 bits, so its complement is the compare mask.
    // (All ones gives p+1 = 0 and a zero mask: the whole address space.)
    function automatic napot_match;
        input [20:0] p;
        input [20:0] w;
        reg [20:0] mask;
        begin
            mask = ~(p ^ (p + 1'b1));
            napot_match = ((w ^ p) & mask) == 21'b0;
        end
    endfunction

    // ── Address match per entry ──────────────────────────────────────────────
    // TOR lower bound: entry 0 -> 0, entry i -> pmpaddr[i-1] (page bits).
    wire [19:0] top0 = pmpaddr0[29:10], top1 = pmpaddr1[29:10],
                top2 = pmpaddr2[29:10], top3 = pmpaddr3[29:10];
    reg match0, match1, match2, match3;
    always @(*) begin
        match0 = cfg0[4] ? napot_match(pmpaddr0[29:9], pg2) :
                 cfg0[3] ? (pg < top0) : 1'b0;
        match1 = cfg1[4] ? napot_match(pmpaddr1[29:9], pg2) :
                 cfg1[3] ? (pg >= top0) && (pg < top1) : 1'b0;
        match2 = cfg2[4] ? napot_match(pmpaddr2[29:9], pg2) :
                 cfg2[3] ? (pg >= top1) && (pg < top2) : 1'b0;
        match3 = cfg3[4] ? napot_match(pmpaddr3[29:9], pg2) :
                 cfg3[3] ? (pg >= top2) && (pg < top3) : 1'b0;
    end

    // ── Permission check helper ──────────────────────────────────────────────
    // L=0 (unlocked): M-mode always passes; U-mode checks R/W/X bits.
    // L=1 (locked):   both M and U must satisfy R/W/X bits.
    function automatic check_perm;
        input [7:0]  cfg_in;
        input [2:0]  atype;
        input        priv;
        begin
            if (cfg_in[7]) // Locked
                check_perm = ((cfg_in[2:0] & atype) == atype);
            else            // Unlocked: M-mode bypasses
                check_perm = priv || ((cfg_in[2:0] & atype) == atype);
        end
    endfunction

    // ── Priority mux: first matching entry wins ──────────────────────────────
    always @(*) begin
        if      (match0) pmp_allow = check_perm(cfg0, access_type, priv_mode);
        else if (match1) pmp_allow = check_perm(cfg1, access_type, priv_mode);
        else if (match2) pmp_allow = check_perm(cfg2, access_type, priv_mode);
        else if (match3) pmp_allow = check_perm(cfg3, access_type, priv_mode);
        else             pmp_allow = priv_mode; // no match: M=allow, U=deny
    end

endmodule
