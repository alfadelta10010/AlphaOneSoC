// WO-66 SF3: the handshake contract of src/cache.v proved UNBOUNDED, EN free (k-induction).
//
// Data never feeds control in cache.v, so the macro is dropped (rf_top answers free data) and there is no shadow byte.
// What is proved, from any state satisfying the invariants below, for every EN trace:
//   A  !active -> every fetch signal is its pass-through source
//   C  f_ready only with f_req; m_req is held with its address until m_ready (takeover and hand-back included)
//   D  the cycle after reset: not active
//   G  (WO-CF B2) m_burst -> m_req && aligned && PSRAM (M-A5)
//   H  (WO-CF B1) I6-I8: the sector-tag invariant, ghost tag per sector (see below)
//   E  every m_req address is in 0x20xx_xxxx or 0x80xx_xxxx (mem_ctrl's M-A2) when the fetch addresses are
// Invariants (asserted too, they are what makes the step inductive):
//   I1 fill_active -> act; I2 (hit_q | b_ph) -> act; I3 !act -> no valid bit set
//   I4 hit_q -> the fetch request was up last cycle and not ready; I5 the same for b_ph
//   I6 valid[s] -> gtags[s] == tags[s/2]   (ghost gtags[s] = tag of the fill that last started on sector s, kept in the generated
//      cache copy by cache_dbg_gen.sh): a valid sector holds data of the tag its line still has
//   I7 fill_active -> tags[line(fill_idx)] == fill_tag;  I8 fill_active -> gtags[fill_idx] == fill_tag  (so a fill that ends sets valid on I6)
// Environment: as tb/formal/cache_props.sv (core holds f_req/f_addr until f_ready, f_addr[0] = 0, PMA windows; mem_ctrl
// answers only a held request, never twice in a row, never in the cycle a store completes; the data port holds its
// request; one reset in the first cycle).

module rf_top (
    input  wire [31:0] w_data,
    input  wire [4:0]  w_addr,
    input  wire        w_ena,
    input  wire [4:0]  ra_addr,
    input  wire [4:0]  rb_addr,
    output wire [31:0] ra_data,
    output wire [31:0] rb_data,
    input  wire        clk
);
    wire [31:0] free_a, free_b;     // undriven: free inputs after setundef
    assign ra_data = free_a;
    assign rb_data = free_b;
endmodule

module cache_ind_props (
    input  wire        clk, rst,
    input  wire        en, flush,
    input  wire        pburst,
    input  wire        f_req,
    input  wire [31:0] f_addr,
    input  wire        m_ready,
    input  wire [31:0] m_rdata,
    input  wire        d_req, d_we,
    input  wire [31:0] d_addr,
    input  wire        d_ready
);
    wire [31:0] f_rdata, m_addr;
    wire        f_ready, m_req, active;
    wire        dbg_act, dbg_hit_q, dbg_b_ph, dbg_fill, dbg_valid_any;
    wire        m_burst;
    wire [15:0]  dbg_valid;
    wire [135:0] dbg_tags;
    wire [271:0] dbg_gtags;
    wire [16:0]  dbg_fill_tag;
    wire [3:0]   dbg_fill_idx;
    cache dut (.clk(clk), .rst(rst), .en(en), .pburst(pburst), .fencei_flush(flush), .m_burst(m_burst),
               .f_req(f_req), .f_addr(f_addr), .f_rdata(f_rdata), .f_ready(f_ready),
               .m_req(m_req), .m_addr(m_addr), .m_rdata(m_rdata), .m_ready(m_ready),
               .d_req(d_req), .d_we(d_we), .d_addr(d_addr), .d_ready(d_ready), .active(active),
               .dbg_act(dbg_act), .dbg_hit_q(dbg_hit_q), .dbg_b_ph(dbg_b_ph), .dbg_fill(dbg_fill), .dbg_valid_any(dbg_valid_any),
               .dbg_valid(dbg_valid), .dbg_tags(dbg_tags), .dbg_gtags(dbg_gtags), .dbg_fill_tag(dbg_fill_tag), .dbg_fill_idx(dbg_fill_idx));

    reg dbg_act_q = 0;
    always @(posedge clk) dbg_act_q <= dbg_act;
    reg started = 1'b0, armed = 1'b0, armed_q = 1'b0;
    reg f_req_q = 0, f_ready_q = 0, m_req_q = 0, m_ready_q = 0, d_req_q = 0, d_ready_q = 0, d_we_q = 0;
    reg [31:0] f_addr_q = 0, m_addr_q = 0, d_addr_q = 0;
    always @(posedge clk) begin
        started <= 1'b1;
        if (rst) armed <= 1'b1;
        armed_q <= armed;
        f_req_q <= f_req; f_ready_q <= f_ready; f_addr_q <= f_addr;
        m_req_q <= m_req; m_ready_q <= m_ready; m_addr_q <= m_addr;
        d_req_q <= d_req; d_ready_q <= d_ready; d_addr_q <= d_addr; d_we_q <= d_we;
    end

    wire live = armed && armed_q;
    integer si;
    always @(*) begin
        assume (rst == !started);
        assume (!f_addr[0]);
        assume (f_addr[31] ? f_addr[30:24] == 7'd0 : f_addr[30:24] == 7'h20);
        if (live && f_req_q && !f_ready_q) assume (f_req && f_addr == f_addr_q);
        if (live && m_ready) assume (m_req_q && m_req && m_addr == m_addr_q);
        assume (!(live && m_ready && m_ready_q));
        if (live && d_req_q && !d_ready_q) assume (d_req && d_addr == d_addr_q && d_we == d_we_q);
        if (live && d_ready) assume (d_req && d_req_q);
        assume (!(live && d_ready && d_ready_q));
        assume (!(live && d_ready && m_ready));
    end

    always @(*) begin
        if (armed && !active)                                                         // A
            assert (m_req == f_req && m_addr == f_addr && f_ready == m_ready && f_rdata == m_rdata);
        if (live && f_ready) assert (f_req);                                          // C
        if (live && m_req_q && !m_ready_q) assert (m_req && m_addr == m_addr_q);     // C
        if (armed && !armed_q) assert (!active);                                      // D
        if (armed && m_req) assert (m_addr[31:24] == 8'h20 || m_addr[31:24] == 8'h80); // E
        if (armed && m_burst) assert (m_req && m_addr[1:0] == 2'b00 && m_addr[31]);   // M-A5 (WO-CF B2): the cache's half of mem_props.sv's burst assumption, PBURST free
        if (armed) begin
            assert (!dbg_fill || dbg_act);                                            // I1
            assert (!(dbg_hit_q || dbg_b_ph) || dbg_act);                             // I2
            assert (dbg_act || !dbg_valid_any);                                       // I3
            // WO-CF B1 (sector-tag invariant, unbounded): a valid sector s holds data of the fill that started on s (ghost
            // gtags[s]), and that tag is the tag its line still has; the running fill's line carries the fill's tag.
            for (si = 0; si < 16; si = si + 1)
                if (dbg_valid[si]) assert (dbg_gtags[17*si +: 17] == dbg_tags[17*(si/2) +: 17]);   // I6
            if (dbg_fill) begin
                assert (dbg_tags[17*dbg_fill_idx[3:1] +: 17] == dbg_fill_tag);                  // I7
                assert (dbg_gtags[17*dbg_fill_idx +: 17] == dbg_fill_tag);                      // I8
            end
        end
        if (live) begin
            assert (!dbg_hit_q || (f_req_q && dbg_act_q && !f_ready_q));            // I4
            assert (!dbg_b_ph  || (f_req_q && dbg_act_q && !f_ready_q));            // I5
        end
    end
endmodule
