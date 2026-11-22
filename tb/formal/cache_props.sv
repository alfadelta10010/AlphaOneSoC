// WO-62: instruction cache (src/cache.v). Formal harness.
//
// Shadow memory: one tracked byte address `tb` (a key {addr[31], addr[23:0]}, constant, free) with free initial contents
// `sb`; the data-port stores that complete (d_req && d_we && d_ready) update it. The mem_ctrl stand-in answers a fetch
// word that contains `tb` with `sb` (mem_ctrl serves one transaction at a time, so no store completes while a fetch
// is being read, and a store never completes in the cycle a fetch word arrives); every other byte is free. The
// macro is a real 32 x 32 storage (below), so what the cache wrote is what it reads; a read of the word written on
// the same edge gives free data, the formal image of +RF_COLLIDE_X.
//
//   A  !active -> every fetch signal equals its pass-through source (m_req = f_req, m_addr = f_addr,
//      f_ready = m_ready, f_rdata = m_rdata)
//   A2 (-DPT, EN tied 0) active is always 0, from the first cycle after reset
//   B  every completed fetch (f_req && f_ready) returns, for each of its 4 bytes that is `tb`, the value `sb` holds in
//      that cycle (a store completing in the same cycle is not yet in it)
//   C  while active f_ready only comes with f_req; m_req is held with its address until m_ready
//   D  the cycle after reset: not active
//   E  every m_req comes with an address in 0x20xx_xxxx or 0x80xx_xxxx (mem_ctrl's proved input assumption M-A2)
// Environment (assumed): fetch addresses are in the two PMA windows; the core holds f_req/f_addr until f_ready and f_addr[0] = 0; mem_ctrl answers only a request
// that has been held for a cycle, never in two consecutive cycles, never for the cycle a store completes; the data
// port holds its request until ready, and a store request has been up for a cycle when it completes; reset only in
// the first cycle (the SoC resets every block together, nothing else is reset mid-run).

// The data macro: real storage, free data when a read meets a write of the same word.
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
    wire [31:0] free_a, free_b;     // undriven: free inputs after setundef
    always @(posedge clk) begin
        if (w_ena) mem[w_addr] <= w_data;
        ra_data <= (w_ena && ra_addr == w_addr) ? free_a : mem[ra_addr];
        rb_data <= (w_ena && rb_addr == w_addr) ? free_b : mem[rb_addr];
    end
endmodule

module cache_props (
    input  wire        clk, rst,
    input  wire        en_i, flush,
    input  wire        f_req,
    input  wire [31:0] f_addr,
    input  wire        m_ready,
    input  wire [31:0] m_rdata,
    input  wire        d_req, d_we,
    input  wire [31:0] d_addr, d_wdata,
    input  wire [3:0]  d_be,
    input  wire        d_ready,
    input  wire [24:0] tb_i,
    input  wire [7:0]  sb_i
);
`ifdef PT
    wire en = 1'b0;
`elsif EN1
    wire en = 1'b1;
`else
    wire en = en_i;
`endif
    wire [31:0] f_rdata, m_addr;
    wire        f_ready, m_req, active;
    cache dut (.clk(clk), .rst(rst), .en(en), .fencei_flush(flush),
               .f_req(f_req), .f_addr(f_addr), .f_rdata(f_rdata), .f_ready(f_ready),
               .m_req(m_req), .m_addr(m_addr), .m_rdata(m_rdata), .m_ready(m_ready),
               .d_req(d_req), .d_we(d_we), .d_addr(d_addr), .d_ready(d_ready), .active(active));

    // ---- history and the shadow byte ----------------------------------------------------
    reg started = 1'b0, armed = 1'b0, armed_q = 1'b0;
    reg f_req_q = 0, f_ready_q = 0, m_req_q = 0, m_ready_q = 0, d_req_q = 0, d_ready_q = 0, d_we_q = 0;
    reg [31:0] f_addr_q = 0, m_addr_q = 0, d_addr_q = 0;
    reg [3:0]  d_be_q = 0;
    reg [24:0] tb_q = 0;
    reg [7:0]  sb = 8'd0;

    function [24:0] kadd(input [31:0] a, input [1:0] j);
        kadd = {a[31], a[23:0] + {22'd0, j}};
    endfunction
    wire [24:0] tb = started ? tb_q : tb_i;       // the tracked key, constant after the first cycle

    integer j;
    always @(posedge clk) begin
        started <= 1'b1;
        if (rst) armed <= 1'b1;
        armed_q <= armed;
        f_req_q <= f_req; f_ready_q <= f_ready; f_addr_q <= f_addr;
        m_req_q <= m_req; m_ready_q <= m_ready; m_addr_q <= m_addr;
        d_req_q <= d_req; d_ready_q <= d_ready; d_addr_q <= d_addr; d_we_q <= d_we; d_be_q <= d_be;
        tb_q <= tb;
        if (!started) sb <= sb_i;                 // free initial contents
        else if (d_req && d_we && d_ready)
            for (j = 0; j < 4; j = j + 1)
                if (d_be[j] && kadd({d_addr[31:2], 2'b00}, j[1:0]) == tb) sb <= d_wdata[8*j +: 8];
    end

    // ---- environment ------------------------------------------------------------------------
    reg [7:0] sbv;
    wire live = armed && armed_q;      // outputs of cycle 0 (before the reset edge) are free: contracts judged from cycle 2
    integer je, jp;
    always @(*) begin
        assume (rst == !started);
        assume (!f_addr[0]);
        assume (f_addr[31] ? f_addr[30:24] == 7'd0 : f_addr[30:24] == 7'h20);       // the core's PMA windows: 0x80.. and 0x20..
        if (live && f_req_q && !f_ready_q) assume (f_req && f_addr == f_addr_q);
        if (live && m_ready) assume (m_req_q && m_req && m_addr == m_addr_q);
        assume (!(live && m_ready && m_ready_q));
        if (live && d_req_q && !d_ready_q) assume (d_req && d_addr == d_addr_q && d_we == d_we_q && d_be == d_be_q);
        if (live && d_ready) assume (d_req && d_req_q);
        assume (!(live && d_ready && d_ready_q));
        assume (!(live && d_ready && m_ready));
        // Address abstraction: the tracked byte is in tag T of its chip; every fetch and store goes to tag T or T+1 of that
        // chip (same indexes, so conflicts and the carry from index 15 to 0 are reachable). Another tag only ever
        // plays the part of a line that is not the tracked one, which T+1 does for every T.
        assume ({f_addr[31], f_addr[23:8]} == {tb[24], tb[23:8]} || {f_addr[31], f_addr[23:8]} == {tb[24], tb[23:8] + 16'd1});
        assume ({d_addr[31], d_addr[23:8]} == {tb[24], tb[23:8]} || {d_addr[31], d_addr[23:8]} == {tb[24], tb[23:8] + 16'd1});
        sbv = started ? sb : sb_i;
        for (je = 0; je < 4; je = je + 1)
            if (m_ready && kadd(m_addr, je[1:0]) == tb) assume (m_rdata[8*je +: 8] == sbv);
    end

    // ---- properties -----------------------------------------------------------------------------
    always @(*) begin
        if (armed && !active)                                                         // A
            assert (m_req == f_req && m_addr == f_addr && f_ready == m_ready && f_rdata == m_rdata);
`ifdef PT
        if (armed) assert (!active);                                                  // A2
`endif
        if (armed && f_req && f_ready)                                                // B
            for (jp = 0; jp < 4; jp = jp + 1)
                if (kadd(f_addr, jp[1:0]) == tb) assert (f_rdata[8*jp +: 8] == sb);
        if (armed && active && f_ready) assert (f_req);                               // C
        if (armed && m_req) assert (m_addr[31:24] == 8'h20 || m_addr[31:24] == 8'h80); // E: mem_ctrl's M-A2, fills included
        if (live && m_req_q && !m_ready_q) assert (m_req && m_addr == m_addr_q);     // C
        if (armed && !armed_q) assert (!active);                                      // D
    end

`ifdef SBY_COVER
    // fill bookkeeping: a fill starts when the cache requests word 0 of a line
    reg        fl_start_q = 0;
    wire       fl_word0 = active && m_req && m_addr[3:2] == 2'd0 && (!m_req_q || m_ready_q);
    reg        have_l = 0, done_l = 0, killed_l = 0;
    reg [3:0]  l_idx = 0;  reg [16:0] l_tag = 0;
    wire [3:0]  m_idx = m_addr[7:4];
    wire [16:0] m_tag = {m_addr[31], m_addr[23:8]};
    wire        word3 = active && m_req && m_ready && m_addr[3:2] == 2'd3;
    wire        st_done = d_req && d_we && d_ready;
    wire [3:0]  s_idx = d_addr[7:4];
    wire [16:0] s_tag = {d_addr[31], d_addr[23:8]};
    always @(posedge clk) begin
        if (fl_word0) begin have_l <= 1'b1; done_l <= 1'b0; killed_l <= 1'b0; l_idx <= m_idx; l_tag <= m_tag; end
        if (word3 && have_l && m_idx == l_idx && m_tag == l_tag) done_l <= 1'b1;
        if (st_done && have_l && done_l && s_idx == l_idx && s_tag == l_tag) killed_l <= 1'b1;
    end
    always @(*) begin
        cover (armed && active && f_req && f_ready);                                                  // 1 hit
        cover (armed && active && fl_word0);                                                          // 2 fill
        cover (armed && fl_word0 && have_l && m_idx == l_idx && m_tag != l_tag);                      // 3 eviction (same index, other tag)
        cover (armed && fl_word0 && have_l && killed_l && m_idx == l_idx && m_tag == l_tag);         // 4 store-invalidate: the line fills again
        cover (armed && active && f_req && f_ready && f_addr[1] && f_addr[3:2] != 2'd3);            // 5 straddle in a line
        cover (armed && active && f_req && f_ready && f_addr[1] && f_addr[3:2] == 2'd3);            // 6 straddle across lines
        cover (armed && active && f_req && f_ready && f_addr[7]);                                    // 7 hit served by data_hi
        cover (armed && active && f_req && f_ready && f_addr[7:0] == 8'h7E);                          // 8 straddle data_mem -> data_hi
        cover (armed && active && f_req && f_ready && f_addr[7:0] == 8'hFE);                          // 9 straddle data_hi -> data_mem (index 15 -> 0)
        cover (armed && st_done && have_l && done_l && s_idx == l_idx && s_tag == l_tag && l_idx[3]); // 10 a data_hi line store-invalidated
    end
`endif
endmodule
