// Instruction cache: 256 B, direct-mapped, 16 B lines, fetch path only (WO-62 K4, 256 B WO-77).
//
// Sits between the core's fetch port and mem_ctrl's fetch port. The data path
// is not touched; the cache only watches it: a store that completes on the
// data port invalidates the line it falls in (no update, loads are ignored).
//
//   core -- f_* --> [ cache ] -- m_* --> mem_ctrl i_*       d_* = snoop only
//
// The ports follow the core's request/ready contract (src/fyracore.v, docs/CLAUDE.md
// "Memory handshake"): a request is held, address unchanged, until the cycle
// ready is seen with it. f_* is the core side, m_* the mem_ctrl side.
//
// EN (CACHE_CTL.EN, from a flop in the SoC):
//   EN = 0 (reset)  every fetch signal passes straight through, combinationally
//                   (m_req = f_req, m_addr = f_addr, f_rdata = m_rdata,
//                   f_ready = m_ready) and every valid bit is held 0.
//   EN 0 -> 1       the cache takes over on a cycle that has no request in
//                   flight on mem_ctrl (f_req low, or f_ready seen), starts cold.
//   EN 1 -> 0       no new fill starts; the pass-through returns when no fill and no
//                   hit is pending (a request that does not hit then goes through).
// `active` shows which of the two the fetch path is in.
//
// Geometry. Key = {addr[31], addr[23:0]} (flash / PSRAM and the chip offset;
// the PMA windows decide the rest): offset 4 bits, index 4 bits (addr[7:4]), tag 17 bits
// ({addr[31], addr[23:8]}). Tags and valid bits are flops (16 x 17 + 16); the data is TWO rf_top macros
// (each 32 x 32 = 8 lines x 4 words): data_mem holds lines 0-7 (index[3] = addr[7] = 0), data_hi lines 8-15
// (index[3] = 1); the word address inside a macro is addr[6:2]. Both read ports of both macros are driven
// with the same addresses and a 2:1 per port picks the data (port A by index[3] of A, port B by index[3] of
// B = A + 1, so a straddle across line 7 -> 8 or 15 -> 0 reads each word from its own macro). On the fill edge port A may read the word being written, but
// that data is never used: a word is looked up only after it has been written
// (see fill_here), so the macro's write-through is never used (+RF_COLLIDE_X
// stays clean).
//
// A fetch wants the 4 bytes from the halfword-aligned pc. At f_addr[1] = 0
// that is one word; at f_addr[1] = 1 it is the upper half of word A and the
// lower half of word B = A + 1 (the next line when A is the last word of
// its line). Port A of the macro always reads A, port B always reads B (both
// addresses come straight from f_addr), the tag lookup is one per cycle:
//
//   hit, aligned    cycle 0 lookup of A, cycle 1 ready (f_ready is a flop, the
//                   data comes from the macro)                    2 clocks
//   hit, straddle   cycle 0 lookup of A, cycle 1 lookup of B,
//                   cycle 2 ready                                 3 clocks
//   miss            the line is filled as four aligned 4-byte reads in line
//                   order through m_*, each word written to the macro as it
//                   arrives. The lookup repeats every cycle; a word hits as
//                   soon as it has been written (early restart: ready two
//                   clocks after the word arrives, and the next word of the
//                   same line hits the same way). A request that finds its
//                   word or line unavailable waits; a miss on another line
//                   waits for the running fill to end (one fill at a time).
//
// Coherence. A store that completes on the data port (d_we && d_ready)
// clears the valid bit of its line if the tags match; if that line is being
// filled the fill is marked dead (it stops after the word in flight, its words are
// not used, valid is not set). The lookup in that cycle is skipped (the shared tag mux and
// comparator serve the store) and a straddling fetch starts again at A.
// fencei_flush clears every valid bit (and kills a running fill); with the
// snoop it adds nothing a single hart needs, it is belt and braces.
//
// PSRAM line burst (pburst = CACHE_CTL.PBURST): a fill of a line in PSRAM may keep CE# low for its four words
// (m_burst). tCEM (8 us) needs a core clock >= 12.6 MHz for that: set PBURST only at >= 15 MHz, and only with
// QSPI_CFG.STREAM set (the engine ignores m_burst otherwise).
//
// Fill addresses are the real addresses the core would have fetched: {addr[31], addr[30:24] rebuilt, tag, index,
// word}. The key keeps addr[31] and addr[23:0]; the window byte is 0x20 (flash) or 0x80 (PSRAM), so addr[29] =
// ~addr[31] and the rest is 0. That keeps mem_ctrl's proved input assumption M-A2 (i_addr[31:24] in {0x20, 0x80})
// true of every request the cache makes (tb/formal/cache_props.sv asserts it).
module cache (
    input  wire        clk,
    input  wire        rst,           // rst_soc
    input  wire        en,            // CACHE_CTL.EN
    input  wire        pburst,        // CACHE_CTL.PBURST: PSRAM fills may burst (0 = four separate reads)
    input  wire        fencei_flush,  // core: FENCE.I retires, invalidate everything
    // Core side (fetch port)
    input  wire        f_req,
    input  wire [31:0] f_addr,
    output wire [31:0] f_rdata,
    output wire        f_ready,
    // mem_ctrl side (its instruction port)
    output wire        m_req,
    output wire [31:0] m_addr,
    output wire        m_burst,       // the fill word on m_* is of a line in PSRAM and the fill is alive (a burst may continue)
    input  wire [31:0] m_rdata,
    input  wire        m_ready,
    // Data port, snooped: the memory half of the core's data port
    input  wire        d_req,
    input  wire        d_we,
    input  wire [31:0] d_addr,
    input  wire        d_ready,
    output wire        active         // the cache owns the fetch path (EN took effect)
`ifdef CACHE_DBG                      // formal only (tb/formal/cache_ind_props.sv): the state its invariants talk about
    , output wire        dbg_act, dbg_hit_q, dbg_b_ph, dbg_fill, dbg_valid_any
`endif
);
    reg         act;          // the cache owns the fetch path
    reg         hit_q;        // a hit was found last cycle: f_ready now
    reg         b_ph;         // a straddling fetch: A hit, B is looked up now
    reg  [15:0] valid;
    reg  [271:0] tags;        // 16 x 17, line i at [17*i +: 17]

    reg         fill_active;
    reg         dead;         // a store hit the line being filled
    reg  [3:0]  fill_idx;
    reg  [16:0] fill_tag;
    reg  [1:0]  fcnt;         // words of the running fill that have arrived (and been written)

    // ---- lookup -------------------------------------------------------
    wire        pc1  = f_addr[1];
    wire [21:0] nxt  = f_addr[23:2] + 22'd1;            // the word after A (24-bit offset wraps)
    // A store completes on the data port: the tag logic serves it for this cycle. d_ready only comes with the
    // request it completes (the core holds d_req until then; cache_props assumes it), so d_req is not needed.
    // The snoop also runs while !act, where it only clears valid bits that are already 0.
    wire        snoop = d_we && d_ready;

    wire [3:0]  kidx  = snoop ? d_addr[7:4] : b_ph ? nxt[5:2] : f_addr[7:4];
    wire [1:0]  kword = b_ph ? nxt[1:0] : f_addr[3:2];
    wire [16:0] ktag  = snoop ? {d_addr[31], d_addr[23:8]} :
                        b_ph  ? {f_addr[31], nxt[21:6]} : {f_addr[31], f_addr[23:8]};

    wire        tmatch    = (tags[17*kidx +: 17] == ktag);
    // The word of the line being filled is usable once it has been written.
    wire        fill_here = fill_active && !dead && (kidx == fill_idx) && (kword < fcnt);
    wire        hit       = tmatch && (valid[kidx] || fill_here);

    wire        look  = act && f_req && !hit_q && !snoop;
    wire        start = look && !hit && !fill_active && en;  // miss: begin a fill (not on the way out)
    wire        word_in = fill_active && m_ready;            // a fill word arrives

    wire        off   = act && !en && !fill_active && !hit_q;
    wire        on    = !act && en && (!f_req || m_ready);

    always @(posedge clk) begin
        if (rst) begin
            act         <= 1'b0;
            hit_q       <= 1'b0;
            b_ph        <= 1'b0;
            valid       <= 16'd0;
            fill_active <= 1'b0;
        end else begin
            if (on)  act <= 1'b1;
            if (off) act <= 1'b0;

            hit_q <= look && hit && (b_ph || !pc1);
            b_ph  <= look && hit && !b_ph && pc1;

            if (start) begin
                fill_active <= 1'b1;
                fill_idx    <= kidx;
                fill_tag    <= ktag;
                fcnt        <= 2'd0;
                dead        <= 1'b0;
                valid[kidx] <= 1'b0;
                tags[17*kidx +: 17] <= ktag;
            end
            if (word_in) begin
                fcnt <= fcnt + 2'd1;
                if (fcnt == 2'd3 || dead) begin          // a dead fill stops at the next word boundary
                    fill_active <= 1'b0;
                    valid[fill_idx] <= !dead;
                end
            end
            if (snoop && tmatch) begin
                valid[kidx] <= 1'b0;
                if (fill_active && fill_idx == kidx)
                    dead <= 1'b1;
            end
            if (fencei_flush) begin
                valid <= 16'd0;
                if (fill_active)
                    dead <= 1'b1;
            end
            if (off) begin                               // on the way out: cold, nothing pending
                valid <= 16'd0;
                hit_q <= 1'b0;
                b_ph  <= 1'b0;
            end
        end
    end

    // ---- data macro ---------------------------------------------------
    wire [31:0] ra_lo, rb_lo, ra_hi, rb_hi;
    rf_top data_mem (                       // lines 0-7  (index[3] = 0)
        .w_data  (m_rdata),
        .w_addr  ({fill_idx[2:0], fcnt}),
        .w_ena   (word_in && !fill_idx[3]),
        .ra_addr (f_addr[6:2]),
        .rb_addr (nxt[4:0]),
        .ra_data (ra_lo),
        .rb_data (rb_lo),
        .clk     (clk)
    );
    rf_top data_hi (                        // lines 8-15 (index[3] = 1)
        .w_data  (m_rdata),
        .w_addr  ({fill_idx[2:0], fcnt}),
        .w_ena   (word_in && fill_idx[3]),
        .ra_addr (f_addr[6:2]),
        .rb_addr (nxt[4:0]),
        .ra_data (ra_hi),
        .rb_data (rb_hi),
        .clk     (clk)
    );
    // The macros read synchronously: the data in a cycle is for the address of the previous edge. The
    // core holds f_addr from request to ready, so the select taken from the current f_addr is the one
    // the data was read with.
    wire [31:0] ra_data = f_addr[7] ? ra_hi : ra_lo;   // word A's line: index[3] of A
    wire [31:0] rb_data = nxt[5]    ? rb_hi : rb_lo;   // word B = A + 1: index[3] of B

    // ---- outputs ------------------------------------------------------
    wire        use_fill = act && fill_active;
    assign active  = act;
`ifdef CACHE_DBG
    assign dbg_act = act, dbg_hit_q = hit_q, dbg_b_ph = b_ph, dbg_fill = fill_active, dbg_valid_any = |valid;
`endif
    assign m_req   = act ? fill_active : f_req;
    // PSRAM line burst qualifier: only fill words of a live fill whose window is PSRAM (key bit 16 = addr[31]).
    // Low with EN = 0 (fill_active is 0 while !act) and with PBURST = 0.
    assign m_burst = act && fill_active && !dead && fill_tag[16] && pburst;
    assign m_addr  = use_fill ? {fill_tag[16], 1'b0, ~fill_tag[16], 5'd0, fill_tag[15:0], fill_idx, fcnt, 2'b00} : f_addr;
    assign f_ready = act ? hit_q : m_ready;
    assign f_rdata = !act ? m_rdata :
                     pc1  ? {rb_data[15:0], ra_data[31:16]} : ra_data;
endmodule
