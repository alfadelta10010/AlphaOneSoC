// Bench for src/cache.v (WO-62, K4: 128 B direct-mapped, 16 B lines, instruction only).
//
// A random fetch stream (halfword-aligned addresses with locality, so aligned and
// straddling fetches, hits, misses and conflicts) and random data-port traffic
// (stores for the invalidate rule, loads that must change nothing) run against a
// stand-in for mem_ctrl: one transaction at a time, data first when idle, random
// latency, the shadow memory read or written when the transaction completes. EN
// toggles and fencei_flush pulses come at random.
//
// Checks, every cycle:
//   * a completed fetch (f_req && f_ready) returns the 4 bytes at f_addr as the
//     shadow memory holds them (a store completing in that very cycle is not seen,
//     as in tb/formal/cache_props.sv);
//   * the core's contract on f_*: held until ready (the bench drives it, the DUT's
//     f_ready is only taken with f_req);
//   * mem_ctrl's contract on m_*: a request is held, address unchanged, until ready;
//   * while !active every fetch signal equals its pass-through source;
//   * EN low for a while -> active falls; EN high -> active rises; the takeover is cold (valid = 0).
// Floors (end of run): hits, misses, store-invalidates, evictions per line, straddling
// hits, EN toggles, flushes. +SEED=n, +CYCLES=n, +MAXLAT=n (default 12), +NOEN
// (EN stays 1 after the first rise), +ENFAST (EN toggles every ~100 cycles), +TFROM=n (trace).
`timescale 1ns/1ps
module tb_cache;
    reg clk = 0;
    always #5 clk = ~clk;

    reg rst = 1;
    reg en = 0;
    reg fencei = 0;

    // core side
    reg         f_req = 0;
    reg  [31:0] f_addr = 0;
    wire [31:0] f_rdata;
    wire        f_ready;
    // mem side
    wire        m_req;
    wire [31:0] m_addr;
    reg  [31:0] m_rdata = 0;
    reg         m_ready = 0;
    // data port
    reg         d_req = 0, d_we = 0;
    reg  [31:0] d_addr = 0, d_wdata = 0;
    reg  [3:0]  d_be = 0;
    reg         d_ready = 0;
    wire        active;

    cache dut (.clk(clk), .rst(rst), .en(en), .fencei_flush(fencei),
               .f_req(f_req), .f_addr(f_addr), .f_rdata(f_rdata), .f_ready(f_ready),
               .m_req(m_req), .m_addr(m_addr), .m_rdata(m_rdata), .m_ready(m_ready),
               .d_req(d_req), .d_we(d_we), .d_addr(d_addr), .d_ready(d_ready),
               .active(active));

    integer enfast, seed, seed0, ncyc, maxlat, noen;
    integer errors = 0;

    // ---- address pool and shadow memory ------------------------------------
    // Two chips (addr[31]), six consecutive tags each; the tag sits at addr[23:7].
    reg [16:0] tbase0, tbase1;
    function [31:0] mkaddr(input a31, input [2:0] p, input [6:0] low);
        reg [16:0] t;
        begin
            t = (a31 ? tbase1 : tbase0) + {14'd0, p};
            mkaddr = {a31, 7'd0, t, low};
        end
    endfunction
    // shadow index: {chip, tag number, addr[6:0]}; ~0 when outside the pool
    function [10:0] sidx(input [31:0] a);
        reg [16:0] d;
        begin
            d = a[23:7] - (a[31] ? tbase1 : tbase0);
            sidx = (d < 17'd6) ? {a[31], d[2:0], a[6:0]} : 11'h7ff;
        end
    endfunction
    reg [7:0] sh [0:2047];
    integer i;

    // ---- random --------------------------------------------------------------
    function integer rnd(input integer n);   // 0 .. n-1
        integer r;
        begin
            r = $random(seed);
            if (r < 0) r = -r;
            if (r < 0) r = 0;
            rnd = r % n;
        end
    endfunction

    // ---- mem_ctrl stand-in -----------------------------------------------------
    // One transaction at a time; chosen only while idle, data first; ready for one cycle.
    reg        busy = 0, bus_d = 0;
    integer    lat = 0;
    reg [31:0] t_addr;
    reg        t_we;
    reg [31:0] t_wd;
    reg [3:0]  t_be;
    integer    j;
    reg        fetch_in_wait = 0;  // a request (m_req) is outstanding

    // ---- checkers' state ---------------------------------------------------------
    reg        m_req_q = 0, m_ready_q = 0;
    reg [31:0] m_addr_q = 0;
    reg        f_req_q = 0, f_ready_q = 0;
    reg [31:0] f_addr_q = 0;
    reg        d_req_q = 0, d_ready_q = 0;
    reg [31:0] d_addr_q = 0, d_wdata_q = 0;
    reg [3:0]  d_be_q = 0;
    reg        d_we_q = 0;

    // ---- counters ---------------------------------------------------------------------
    integer n_hit = 0, n_miss = 0, n_inv = 0, n_strad = 0, n_strad_x = 0, n_flush = 0, n_entog = 0;
    integer n_fetch = 0, n_ptfetch = 0, n_store = 0, n_load = 0, n_dead = 0;
    integer n_evict [0:7];
    integer cyc = 0;
    integer en_fall_at = -1, en_rise_at = -1;

    // ---- generators -----------------------------------------------------------------------
    integer gap_f = 0, gap_d = 0;
    reg [31:0] pc;
    reg [31:0] exp_w;
    integer k, which;
    reg [31:0] ca;

    // a fresh halfword-aligned fetch address with locality
    task next_pc;
        integer r;
        reg [31:0] c;
        begin
            r = rnd(100);
            if (r < 48)      c = pc + (rnd(2) ? 32'd2 : 32'd4);
            else if (r < 70) c = pc + 32'd4 * rnd(8) - 32'd16;
            else if (r < 85) c = mkaddr(pc[31], rnd(5), {rnd(8), 4'd0} + {3'd0, rnd(16)}) & ~32'd1;
            else             c = mkaddr(rnd(2), rnd(5), rnd(128)) & ~32'd1;
            c[0] = 1'b0;
            // keep inside the pool, away from its last 6 bytes (a straddle must stay in it)
            if (sidx(c) == 11'h7ff || sidx(c + 32'd7) == 11'h7ff || sidx(c + 32'd4) == 11'h7ff)
                c = mkaddr(rnd(2), rnd(5), rnd(128)) & ~32'd1;
            pc = c;
        end
    endtask

    integer sp;
    always @(posedge clk) begin
        cyc <= cyc + 1;
        rst <= (cyc < 3);

        // ---------------- core side generator (holds until ready) ----------------
        if (f_req && f_ready) begin
            n_fetch = n_fetch + 1;
            f_req <= 1'b0;
            gap_f = (rnd(4) == 0) ? rnd(6) : 0;
        end else if (!f_req) begin
            if (gap_f > 0) gap_f = gap_f - 1;
            else if (cyc > 4) begin
                next_pc;
                f_addr <= pc;
                f_req  <= 1'b1;
            end
        end

        // ---------------- data-port generator (holds until ready) ---------------
        if (d_req && d_ready) begin
            d_req <= 1'b0;
            gap_d = rnd(40);
        end else if (!d_req) begin
            if (gap_d > 0) gap_d = gap_d - 1;
            else if (cyc > 4) begin
                // half of the stores aim at a line near the fetch stream
                if (rnd(2)) ca = (f_addr & ~32'h0000000F) + 32'd16 * rnd(3) - 32'd16 + rnd(16);
                else        ca = mkaddr(rnd(2), rnd(5), rnd(128));
                if (sidx(ca) == 11'h7ff) ca = mkaddr(rnd(2), rnd(5), rnd(128));
                d_addr  <= ca;
                d_wdata <= $random(seed);
                d_we    <= (rnd(4) != 0);
                sp = rnd(3);
                d_be    <= (sp == 0) ? (4'b0001 << rnd(4)) : (sp == 1) ? (4'b0011 << (2 * rnd(2))) : 4'b1111;
                d_req   <= 1'b1;
            end
        end

        // ---------------- mem_ctrl stand-in -----------------------------------------------
        // a store lands in the shadow at the end of its ready cycle (as in tb/formal/cache_props.sv)
        if (d_ready && t_we)
            for (j = 0; j < 4; j = j + 1)
                if (t_be[j] && sidx({t_addr[31:2], 2'b00}) != 11'h7ff)
                    sh[sidx({t_addr[31:2], 2'b00}) + j] <= t_wd[8*j +: 8];
        m_ready <= 1'b0;
        d_ready <= 1'b0;
        if (!busy) begin
            if (d_req && !d_ready && !m_ready) begin
                busy <= 1; bus_d <= 1; lat = 1 + rnd(maxlat);
                t_addr = d_addr; t_we = d_we; t_wd = d_wdata; t_be = d_be;
            end else if (m_req && !m_ready && !d_ready) begin
                busy <= 1; bus_d <= 0; lat = 1 + rnd(maxlat);
                t_addr = m_addr;
            end
        end else begin
            lat = lat - 1;
            if (lat <= 0) begin
                busy <= 0;
                if (bus_d) begin
                    d_ready <= 1'b1;
                    if (t_we) n_store = n_store + 1; else n_load = n_load + 1;
                end else begin
                    m_ready <= 1'b1;
                    for (j = 0; j < 4; j = j + 1)
                        m_rdata[8*j +: 8] <= (sidx(t_addr + j) == 11'h7ff) ? 8'hxx : sh[sidx(t_addr + j)];
                end
            end
        end

        // ---------------- EN and FENCE.I -----------------------------------------------------
        if (cyc > 6) begin
            if (noen) begin
                if (cyc == 20) en <= 1'b1;
            end else if (rnd(enfast ? (en ? 150 : 60) : (en ? 8000 : 400)) == 0) begin
                en <= ~en;
                n_entog = n_entog + 1;
                if (en) en_fall_at = cyc; else en_rise_at = cyc;
            end
            // FENCE.I at random, also with a fetch outstanding (a superset of the core's behaviour)
            if (rnd(1500) == 0) begin
                fencei <= 1'b1; n_flush = n_flush + 1;
            end else fencei <= 1'b0;
        end
    end

    // ---------------- checks (sample before the edge's updates) -----------------------
    always @(posedge clk) if (!rst && cyc > 5) begin
        // contract of the core's side (our generator) and the DUT's m_*
        if (m_req_q && !m_ready_q && !(m_req && m_addr === m_addr_q)) begin
            $display("FAIL %0d: m_req not held (req %b addr %h -> %h)", cyc, m_req, m_addr_q, m_addr);
            errors = errors + 1;
        end
        if (f_ready && !f_req && active) begin
            $display("FAIL %0d: f_ready without f_req while active", cyc); errors = errors + 1;
        end
        if (m_req === 1'bx || f_ready === 1'bx) begin
            $display("FAIL %0d: X on a handshake signal", cyc); errors = errors + 1;
        end
        // pass-through
        if (!active && !(m_req === f_req && m_addr === f_addr && f_ready === m_ready && f_rdata === m_rdata)) begin
            $display("FAIL %0d: pass-through broken", cyc); errors = errors + 1;
        end
        // data of a completed fetch
        if (f_req && f_ready) begin
            if (!active) n_ptfetch = n_ptfetch + 1;
            for (j = 0; j < 4; j = j + 1) begin
                if (sidx(f_addr + j) == 11'h7ff) begin end
                else if (f_rdata[8*j +: 8] !== sh[sidx(f_addr + j)]) begin
                    $display("FAIL %0d: fetch %h byte %0d = %h, shadow %h (active %b)", cyc, f_addr, j,
                             f_rdata[8*j +: 8], sh[sidx(f_addr + j)], active);
                    errors = errors + 1;
                end
            end
        end
        // EN 0 -> 1 starts cold (the stores are snooped in the pass-through too, so stale lines would not show in the data)
        if (dut.on && dut.valid !== 8'd0) begin
            $display("FAIL %0d: takeover with valid = %b", cyc, dut.valid); errors = errors + 1;
        end
        // liveness of EN
        if (!en && en_fall_at >= 0 && cyc - en_fall_at > 1500 && active) begin
            $display("FAIL %0d: EN low for 1500 cycles, cache still active", cyc);
            errors = errors + 1; en_fall_at = -1;
        end
        if (en && en_rise_at >= 0 && cyc - en_rise_at > 1500 && !active) begin
            $display("FAIL %0d: EN high for 1500 cycles, cache still off", cyc);
            errors = errors + 1; en_rise_at = -1;
        end
        // coverage, from the DUT's own state
        if (f_req && f_ready && active) begin
            n_hit = n_hit + 1;     // delivered by the cache (a hit, possibly after waiting for a fill)
            if (f_addr[1]) begin
                n_strad = n_strad + 1;
                if (f_addr[3:2] == 2'd3) n_strad_x = n_strad_x + 1;
            end
        end
        if (dut.start) begin
            n_miss = n_miss + 1;
            if (dut.valid[dut.kidx]) n_evict[dut.kidx] = n_evict[dut.kidx] + 1;
        end
        if (dut.snoop && dut.tmatch && (dut.valid[dut.kidx] || (dut.fill_active && dut.fill_idx == dut.kidx))) begin
            n_inv = n_inv + 1;
            if (dut.fill_active && dut.fill_idx == dut.kidx) n_dead = n_dead + 1;
        end
    end

    // +TFROM=n: a per-cycle trace of 150 cycles from n
    integer tfrom = -1;
    always @(posedge clk) if (tfrom >= 0 && cyc >= tfrom && cyc < tfrom + 150)
        $display("%0d: en %b act %b | f %b %h rdy %b | m %b %h rdy %b | d %b%b %h rdy %b | hit_q %b b %b fa %b fi %0d fc %0d dead %b valid %b",
                 cyc, en, active, f_req, f_addr, f_ready, m_req, m_addr, m_ready, d_req, d_we, d_addr, d_ready,
                 dut.hit_q, dut.b_ph, dut.fill_active, dut.fill_idx, dut.fcnt, dut.dead, dut.valid);

    // previous-cycle copies for the contract checks
    always @(posedge clk) begin
        m_req_q <= m_req; m_ready_q <= m_ready; m_addr_q <= m_addr;
        f_req_q <= f_req; f_ready_q <= f_ready; f_addr_q <= f_addr;
    end

    // ---------------- run ----------------------------------------------------------------------
    reg [31:0] dummy;
    initial begin
        if (!$value$plusargs("SEED=%d", seed)) seed = 1;
        seed0 = seed;
        if (!$value$plusargs("CYCLES=%d", ncyc)) ncyc = 400000;
        if (!$value$plusargs("MAXLAT=%d", maxlat)) maxlat = 12;
        noen = $test$plusargs("NOEN");
        enfast = $test$plusargs("ENFAST");
        if (!$value$plusargs("TFROM=%d", tfrom)) tfrom = -1;
        tbase0 = $random(seed); tbase1 = $random(seed);
        for (i = 0; i < 8; i = i + 1) n_evict[i] = 0;
        for (i = 0; i < 2048; i = i + 1) sh[i] = $random(seed);
        m_rdata = 0;
        pc = 32'd0;
        pc = mkaddr(0, 0, 0);
        repeat (ncyc) @(posedge clk);
        #1;
        $display("cycles %0d seed %0d maxlat %0d: fetches %0d (cache %0d, pass-through %0d), misses %0d, straddles %0d (cross-line %0d)",
                 ncyc, seed0, maxlat, n_fetch, n_hit, n_ptfetch, n_miss, n_strad, n_strad_x);
        $display("stores %0d loads %0d, store-invalidates %0d (on a filling line %0d), EN toggles %0d, flushes %0d",
                 n_store, n_load, n_inv, n_dead, n_entog, n_flush);
        $write("evictions per line:");
        for (i = 0; i < 8; i = i + 1) $write(" %0d", n_evict[i]);
        $write("\n");
        if (n_hit < 1000)  begin $display("FAIL floor: hits %0d < 1000", n_hit); errors = errors + 1; end
        if (n_miss < 1000) begin $display("FAIL floor: misses %0d < 1000", n_miss); errors = errors + 1; end
        if (n_inv < 100)   begin $display("FAIL floor: store-invalidates %0d < 100", n_inv); errors = errors + 1; end
        for (i = 0; i < 8; i = i + 1)
            if (n_evict[i] < (enfast ? 5 : 50)) begin $display("FAIL floor: evictions of line %0d = %0d < %0d", i, n_evict[i], enfast ? 5 : 50); errors = errors + 1; end
        if (n_strad < 100)   begin $display("FAIL floor: straddling hits %0d < 100", n_strad); errors = errors + 1; end
        if (n_strad_x < 20)  begin $display("FAIL floor: cross-line straddles %0d < 20", n_strad_x); errors = errors + 1; end
        if (!noen && n_entog < 10) begin $display("FAIL floor: EN toggles %0d < 10", n_entog); errors = errors + 1; end
        if (n_flush < 10)  begin $display("FAIL floor: flushes %0d < 10", n_flush); errors = errors + 1; end
        if (errors == 0) $display("PASS tb_cache");
        else $display("FAIL tb_cache: %0d errors", errors);
        $finish;
    end
endmodule
