// pmp — Physical Memory Protection checker (RV32, 4 regions, TOR + NA4 + NAPOT)
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
    localparam A_NA4   = 2'b10;
    localparam A_NAPOT = 2'b11;

    // On RV32 a pmpaddr register holds bits 33:2 of a 34-bit physical
    // address, and every comparison is made in that space. The hart only
    // generates 32-bit addresses (PA[33:32] = 0), but a region's bounds can
    // still lie above 4 GB: pmpaddr = 0x4000_0000 as a TOR top is PA
    // 0x1_0000_0000, so the region covers everything below it. Dropping
    // pmpaddr[31:30], as this module used to, made that region empty and
    // turned NAPOT 0x9fff_ffff (a region above 4 GB) into one covering
    // 0x8000_0000 upward.
    //
    // All compares below are on word addresses: waddr = PA[33:2].
    wire [31:0] waddr = {2'b00, addr[31:2]};

    // ── NAPOT match ──────────────────────────────────────────────────────────
    // pmpaddr = y...y0 1...1 with t trailing ones encodes a naturally aligned
    // region of 2^(t+3) bytes; only the y bits above the trailing ones and
    // their terminating zero have to match. pa ^ (pa+1) is exactly those low
    // t+1 bits, so its complement is the compare mask. (All ones gives
    // pa+1 = 0 and a zero mask: the whole address space, as the spec says.)
    //
    // The mask used to be ~(pa | (pa+1)), which also drops every y bit that
    // is 1 -- so a region matched any address with arbitrary values in those
    // positions, e.g. NAPOT 0x81000000/4K also matched 0x80000044.
    function automatic napot_match;
        input [31:0] pa;
        input [31:0] wa;
        reg [31:0] mask;
        begin
            mask = ~(pa ^ (pa + 1'b1));
            napot_match = ((wa ^ pa) & mask) == 32'b0;
        end
    endfunction

    // ── Address match per entry ──────────────────────────────────────────────
    // TOR lower bound: entry 0 → 0, entry i → pmpaddr[i-1].
    reg match0, match1, match2, match3;
    always @(*) begin
        case (cfg0[4:3])
            A_OFF:   match0 = 1'b0;
            A_TOR:   match0 = (waddr < pmpaddr0);                          // lower = 0
            A_NA4:   match0 = (waddr == pmpaddr0);
            A_NAPOT: match0 = napot_match(pmpaddr0, waddr);
            default: match0 = 1'b0;
        endcase

        case (cfg1[4:3])
            A_OFF:   match1 = 1'b0;
            A_TOR:   match1 = (waddr >= pmpaddr0) && (waddr < pmpaddr1);
            A_NA4:   match1 = (waddr == pmpaddr1);
            A_NAPOT: match1 = napot_match(pmpaddr1, waddr);
            default: match1 = 1'b0;
        endcase

        case (cfg2[4:3])
            A_OFF:   match2 = 1'b0;
            A_TOR:   match2 = (waddr >= pmpaddr1) && (waddr < pmpaddr2);
            A_NA4:   match2 = (waddr == pmpaddr2);
            A_NAPOT: match2 = napot_match(pmpaddr2, waddr);
            default: match2 = 1'b0;
        endcase

        case (cfg3[4:3])
            A_OFF:   match3 = 1'b0;
            A_TOR:   match3 = (waddr >= pmpaddr2) && (waddr < pmpaddr3);
            A_NA4:   match3 = (waddr == pmpaddr3);
            A_NAPOT: match3 = napot_match(pmpaddr3, waddr);
            default: match3 = 1'b0;
        endcase
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
