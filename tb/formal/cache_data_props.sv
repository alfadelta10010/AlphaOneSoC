// WO-CF step 3: DATA coherence of src/cache.v proved UNBOUNDED (k-induction), one symbolic tracked byte.
//
// The cache_ind environment and invariants I1-I9 (they are the helpers), plus a tracked byte `tb` (a key {addr[31], addr[23:0]},
// free, constant after the first cycle) with a ghost `sb` = the value memory holds for it (data-port stores that complete
// update it; the fetch-side stand-in answers every word that contains tb with sb, as in cache_props.sv). The data macros
// are modelled by the one word of each macro that tb maps to (rf_top below keeps only word cw = tb[6:2]; every other cell
// and every read is free data), so the storage side is checked end to end through the real write enables and addresses:
//   D1 valid[sector(tb)] && tags[line(tb)] == tag(tb) -> the macro cell of tb holds sb (macro tb[7], word tb[6:2], byte tb[1:0])
//   D2 a live (not dead) fill of sector(tb) under tag(tb): every word already written (tb[3:2] < fcnt) holds sb in the cell
// D2 is what lets the fill end set valid (and what early restart relies on); a dead fill never sets valid. NOT covered here:
// the READ side (port A/B addressing, the 2:1 macro select, the straddle merge): reads are free data in this model, so that
// stays with `cache` (BMC property B), tb_cache and the nonvac copies.
module rf_top (
    input  wire [31:0] w_data,
    input  wire [4:0]  w_addr,
    input  wire        w_ena,
    input  wire [4:0]  ra_addr,
    input  wire [4:0]  rb_addr,
    output wire [31:0] ra_data,
    output wire [31:0] rb_data,
    input  wire        clk,
    input  wire [4:0]  cw,          // the tracked word index of this macro (harness: tb[6:2])
    output wire [31:0] cmem         // what the macro holds at cw (written by w_ena && w_addr == cw)
);
    reg  [31:0] c;
    wire [31:0] free_a, free_b;     // undriven: free inputs after setundef
    assign ra_data = free_a;
    assign rb_data = free_b;
    assign cmem = c;
    always @(posedge clk) if (w_ena && w_addr == cw) c <= w_data;
endmodule

module cache_data_props (
    input  wire        clk, rst,
    input  wire        en, flush,
    input  wire        pburst,
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
    wire [31:0] f_rdata, m_addr;
    wire        f_ready, m_req, active;
    wire        dbg_act, dbg_hit_q, dbg_b_ph, dbg_fill, dbg_valid_any;
    wire        m_burst;
    wire [15:0]  dbg_valid;
    wire [135:0] dbg_tags;
    wire [271:0] dbg_gtags;
    wire [16:0]  dbg_fill_tag;
    wire [3:0]   dbg_fill_idx;
    wire [31:0]  dbg_cm_lo, dbg_cm_hi;
    wire         dbg_dead;
    wire [1:0]   dbg_fcnt;
    reg started = 1'b0;
    reg  [24:0]  tb_q = 0;
    wire [24:0]  tb = started ? tb_q : tb_i;
    reg  [7:0]   sb = 8'd0;
    cache dut (.clk(clk), .rst(rst), .en(en), .pburst(pburst), .fencei_flush(flush), .m_burst(m_burst),
               .f_req(f_req), .f_addr(f_addr), .f_rdata(f_rdata), .f_ready(f_ready),
               .m_req(m_req), .m_addr(m_addr), .m_rdata(m_rdata), .m_ready(m_ready),
               .d_req(d_req), .d_we(d_we), .d_addr(d_addr), .d_ready(d_ready), .active(active),
               .dbg_act(dbg_act), .dbg_hit_q(dbg_hit_q), .dbg_b_ph(dbg_b_ph), .dbg_fill(dbg_fill), .dbg_valid_any(dbg_valid_any),
               .dbg_valid(dbg_valid), .dbg_tags(dbg_tags), .dbg_gtags(dbg_gtags), .dbg_fill_tag(dbg_fill_tag), .dbg_fill_idx(dbg_fill_idx),
               .g_cw(tb[6:2]), .dbg_cm_lo(dbg_cm_lo), .dbg_cm_hi(dbg_cm_hi), .dbg_dead(dbg_dead), .dbg_fcnt(dbg_fcnt));

    reg dbg_act_q = 0;
    always @(posedge clk) dbg_act_q <= dbg_act;
    reg armed = 1'b0, armed_q = 1'b0;
    reg [3:0] d_be_q = 0;
    wire [31:0] cellw = tb[7] ? dbg_cm_hi : dbg_cm_lo;
    wire [7:0]  cellb = cellw >> (8*tb[1:0]);
    integer jj;
    function [24:0] kadd(input [31:0] a, input [1:0] j);
        kadd = {a[31], a[23:0] + {22'd0, j}};
    endfunction
    reg f_req_q = 0, f_ready_q = 0, m_req_q = 0, m_ready_q = 0, d_req_q = 0, d_ready_q = 0, d_we_q = 0;
    reg [31:0] f_addr_q = 0, m_addr_q = 0, d_addr_q = 0;
    always @(posedge clk) begin
        started <= 1'b1;
        tb_q <= tb;
        d_be_q <= d_be;
        if (!started) sb <= sb_i;
        else if (d_req && d_we && d_ready)
            for (jj = 0; jj < 4; jj = jj + 1)
                if (d_be[jj] && kadd({d_addr[31:2], 2'b00}, jj[1:0]) == tb) sb <= d_wdata[8*jj +: 8];
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
        if (live && d_req_q && !d_ready_q) assume (d_req && d_addr == d_addr_q && d_we == d_we_q && d_be == d_be_q);
        if (live && d_ready) assume (d_req && d_req_q);
        assume (!(live && d_ready && d_ready_q));
        assume (!(live && d_ready && m_ready));
        // the fetch-side stand-in answers a word that contains tb with the byte memory holds for it (as cache_props.sv)
        if (m_ready && m_addr[31] == tb[24] && m_addr[23:2] == tb[23:2]) assume (m_rdata[8*tb[1:0] +: 8] == (started ? sb : sb_i));
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
                assert (!dbg_valid[dbg_fill_idx]);                                              // I9 (fill start clears the filled sector's valid bit)
            end
        end
        if (armed) begin
            if (dbg_valid[tb[7:4]] && dbg_tags[17*tb[7:5] +: 17] == {tb[24], tb[23:8]})                 // D1
                assert (cellb == sb);
            if (dbg_fill && !dbg_dead && dbg_fill_idx == tb[7:4] && dbg_fill_tag == {tb[24], tb[23:8]} && tb[3:2] < dbg_fcnt)   // D2
                assert (cellb == sb);
        end
        if (live) begin
            assert (!dbg_hit_q || (f_req_q && dbg_act_q && !f_ready_q));            // I4
            assert (!dbg_b_ph  || (f_req_q && dbg_act_q && !f_ready_q));            // I5
        end
    end
endmodule
