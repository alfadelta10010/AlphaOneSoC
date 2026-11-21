// WO-66 SF3: the handshake contract of src/cache.v proved UNBOUNDED, EN free (k-induction).
//
// Data never feeds control in cache.v, so the macro is dropped (rf_top answers free data) and there is no shadow byte.
// What is proved, from any state satisfying the invariants below, for every EN trace:
//   A  !active -> every fetch signal is its pass-through source
//   C  f_ready only with f_req; m_req is held with its address until m_ready (takeover and hand-back included)
//   D  the cycle after reset: not active
//   E  every m_req address is in 0x20xx_xxxx or 0x80xx_xxxx (mem_ctrl's M-A2) when the fetch addresses are
// Invariants (asserted too, they are what makes the step inductive):
//   I1 fill_active -> act; I2 (hit_q | b_ph) -> act; I3 !act -> no valid bit set
//   I4 hit_q -> the fetch request was up last cycle and not ready; I5 the same for b_ph
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
    cache dut (.clk(clk), .rst(rst), .en(en), .fencei_flush(flush),
               .f_req(f_req), .f_addr(f_addr), .f_rdata(f_rdata), .f_ready(f_ready),
               .m_req(m_req), .m_addr(m_addr), .m_rdata(m_rdata), .m_ready(m_ready),
               .d_req(d_req), .d_we(d_we), .d_addr(d_addr), .d_ready(d_ready), .active(active),
               .dbg_act(dbg_act), .dbg_hit_q(dbg_hit_q), .dbg_b_ph(dbg_b_ph), .dbg_fill(dbg_fill), .dbg_valid_any(dbg_valid_any));

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
        if (armed) begin
            assert (!dbg_fill || dbg_act);                                            // I1
            assert (!(dbg_hit_q || dbg_b_ph) || dbg_act);                             // I2
            assert (dbg_act || !dbg_valid_any);                                       // I3
        end
        if (live) begin
            assert (!dbg_hit_q || (f_req_q && dbg_act_q && !f_ready_q));            // I4
            assert (!dbg_b_ph  || (f_req_q && dbg_act_q && !f_ready_q));            // I5
        end
    end
endmodule
