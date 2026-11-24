// Memory path (WO-31 part B): mem_ctrl wired to qspi_ctrl as in src/alphaone_soc.v
// (the q_* wires are this harness's own). One props file, four groups selected by
// a define so each sidecar proves one cluster by pdr:
//   P_FLASH  MF1 a write never selects CS0; MF2 IO0 in a CS0 window is a prefix of
//            0xEB or 0xFF (the device-level form: no 06h, no write); MF3 mode byte FFh
//   P_TCEM   MT1 a PSRAM CS run <= 64 clocks (tCEM 8 us at the 8 MHz floor); with BURST_FREE (the cache's
//            line-burst qualifier free, M-A5) MT1b a run <= LPB clocks (tCEM 8 us at a 13 MHz floor), MT1c only after a qualifier;
//            MT1t the measured PSRAM / flash runs; MT2 CS high >= 2 clocks (tCPH)
//   P_ARB    MD1 data first; MD2 split halves are consecutive; MD3 split iff
//            i_addr[31] && &i_addr[9:1], second half on the right chip
//   P_LD     ML1 held d_req answered within LD clocks (no M-A4)
//   P_LI     ML2 held i_req answered within LI clocks (needs M-A4); an EN = 0 statement (instruction cache off), see
//            src/mem_ctrl.v: with the cache on the i-port requester is the cache and M-A4 is not discharged for it
// Assumptions: M-A1 a request not yet answered is held unchanged; M-A2 PMA (stores to
// flash are NOT excluded: the engine's backstop is under test); M-A3 rd_late stable
// while !rst (syscon holds the strap); M-A4 (P_LI, ifndef NO_DF_ASSUME) at most DF_N
// data handshakes between two fetch handshakes (core_df_props.sv discharges it for the core's fetch port, i.e. EN = 0).
// M-A1/M-A2 hold for EN = 1 too: cache.v keeps its request held and its fills in the two windows (cache_props E, cache_ind).
// Every assert is gated on `armed` (set only by rst). No white-box access, except the TCEM_IND lemmas (mem_tcem_burst,
// WO-72), which read engine flops through ports that mem.conf's PRE adds with `expose`; without TCEM_IND the instances
// and the property list are unchanged.
`ifndef DF_N
`define DF_N 4
`endif
// measured bounds (rd_late = 0 / 1), see localFiles/verif-close-2026-11-07/WO-31/bounds.txt and
// `make bounds-qspi`, which FAILs if a define differs from the measured worst of streaming on and off.
// With streaming on (the default) LI (442/456 -> 449/482) and LF (56/57 -> 57/58) moved; LF is the CS0-low run with the engine not idle
`ifndef LP0
`define LP0 40
`define LP1 41
`define LF0 57
`define LF1 58
`endif
`ifndef LPB
`define LPB 104          // a 4-word PSRAM line burst: 20 + 3 * 8 SCK = 88 clocks plus the gaps; the proof's worst case
                         // (rd_late = 1, counterexample at LPB 100) is 101 clocks, so 104 = 101 + 3 margin: tCEM 8 us holds at clk >= 13 MHz
`endif
`ifndef S_MAX
`define S_MAX 125
`endif
`ifndef LD0
`define LD0 182
`define LD1 183
`define LI0 449
`define LI1 482
`endif
module mem_props (
    input  wire        clk, rst,
    input  wire        i_req, i_burst, d_req, d_we,
    input  wire [31:0] i_addr, d_addr, d_wdata,
    input  wire [3:0]  d_be, io_in,
    input  wire        rd_late,
    input  wire        stream_en    // free: streaming on, off and toggling are all covered (WO-54a)
);
    wire [31:0] i_rdata, d_rdata, q_wdata, q_rdata;
    wire        i_ready, d_ready, q_start, q_we, q_idle, q_done, q_burst;
    wire [1:0]  q_cs, q_nbytes_m1;
    wire [23:0] q_addr;
    wire        sck, ctl_oe, io_oe;
    wire [2:0]  cs_n;
    wire [3:0]  io_out;

`ifdef TCEM_IND
    // white-box state for the MT1b induction helpers (mem.conf exposes these flops as ports: PRE[mem_tcem_burst])
    wire [3:0] x_state; wire [2:0] x_cnt, x_t_sel; wire [23:1] x_p;
    wire x_strm, x_pstrm, x_t_bst, x_t_psram, x_t_we, x_t_top, x_t_ddr, x_late, x_init, x_again, x_gnt_d, x_second; wire [2:0] x_step;
`define MX , .gnt_d(x_gnt_d), .second(x_second)
`define QX , .state(x_state), .cnt(x_cnt), .t_sel(x_t_sel), .p(x_p), .strm(x_strm), .pstrm(x_pstrm), .t_bst(x_t_bst), \
             .t_psram(x_t_psram), .t_we(x_t_we), .t_top(x_t_top), .t_ddr(x_t_ddr), .late(x_late), .init(x_init), .again(x_again), .step(x_step)
`else
`define MX
`define QX
`endif
    mem_ctrl memc (.clk(clk), .rst(rst), .i_req(i_req), .i_addr(i_addr), .i_burst(i_burst), .i_rdata(i_rdata), .i_ready(i_ready),
        .d_req(d_req), .d_addr(d_addr), .d_wdata(d_wdata), .d_be(d_be), .d_we(d_we), .d_rdata(d_rdata), .d_ready(d_ready),
        .q_start(q_start), .q_cs(q_cs), .q_addr(q_addr), .q_we(q_we), .q_nbytes_m1(q_nbytes_m1), .q_wdata(q_wdata), .q_burst(q_burst),
        .q_idle(q_idle), .q_done(q_done), .q_rdata(q_rdata) `MX);
    qspi_ctrl qspi (.clk(clk), .rst(rst), .rd_late(rd_late), .start(q_start), .cs_sel(q_cs), .addr(q_addr), .we(q_we),
        .nbytes_m1(q_nbytes_m1), .wdata(q_wdata), .idle(q_idle), .done(q_done), .rdata(q_rdata),
        .sck(sck), .cs_n(cs_n), .ctl_oe(ctl_oe), .io_out(io_out), .io_oe(io_oe), .io_in(io_in), .stream_en(stream_en),
        .ddr(1'b0), .ddr_cap(3'd0), .burst(q_burst) `QX);      // WO-54b: SDR property list, see mem.conf

    reg armed = 1'b0;               // a reset has been applied; every assert is gated on it
    always @(posedge clk) if (rst) armed <= 1'b1;

    // ---- previous-cycle copies (assumptions and monitors)
    reg rst_q = 1'b1, i_req_q = 1'b0, i_rdy_q = 1'b0, d_req_q = 1'b0, d_rdy_q = 1'b0, d_we_q = 1'b0, rl_q = 1'b0, sck_q = 1'b0;
    reg [31:0] i_addr_q = 32'd0, d_addr_q = 32'd0, d_wdata_q = 32'd0;
    reg [3:0]  d_be_q = 4'd0;
    always @(posedge clk) begin
        rst_q <= rst; i_req_q <= i_req; i_rdy_q <= i_ready; d_req_q <= d_req; d_rdy_q <= d_ready; d_we_q <= d_we;
        rl_q <= rd_late; sck_q <= sck; i_addr_q <= i_addr; d_addr_q <= d_addr; d_wdata_q <= d_wdata; d_be_q <= d_be;
    end
    reg strap = 1'b0;               // rd_late as sampled during reset
    always @(posedge clk) if (rst) strap <= rd_late;

    wire i_ok = (i_addr[31:24] == 8'h20) || (i_addr[31:24] == 8'h80);
    wire d_ok = (d_addr[31:24] == 8'h20) || (d_addr[31:24] == 8'h80);
    wire be_ok = d_be == 4'b0001 || d_be == 4'b0010 || d_be == 4'b0100 || d_be == 4'b1000 ||
                 d_be == 4'b0011 || d_be == 4'b1100 || d_be == 4'b1111;
    wire hold_i = armed && !rst_q && i_req_q && !i_rdy_q;
    wire hold_d = armed && !rst_q && d_req_q && !d_rdy_q;
    always @(*) begin
        assume (!hold_i || (i_req && i_addr == i_addr_q));                                      // M-A1
        assume (!hold_d || (d_req && d_addr == d_addr_q && d_wdata == d_wdata_q && d_be == d_be_q && d_we == d_we_q));
        assume (!i_req || (i_ok && !i_addr[0]));                                                // M-A2
`ifdef BURST_FREE
        assume (!i_burst || (i_req && i_addr[1:0] == 2'b00 && i_addr[31]));                     // M-A5 a burst qualifier comes with an aligned PSRAM word request (cache.v m_burst)
`else
        assume (!i_burst);                                                                      // cache off: no qualifier
`endif
        assume (!d_req || (d_ok && d_addr[1:0] == 2'b00 && be_ok));
        assume (!(armed && !rst) || rd_late == rl_q);                                           // M-A3
    end

    wire start_ev = q_idle && q_start;
    wire [31:0] nxt = i_addr + 32'd2;

`ifdef P_LD
`define P_LAT
`endif
`ifdef P_LI
`define P_LAT
`endif
`ifdef P_LAT
    // M-A4: data handshakes since the last fetch handshake
    reg [3:0] nd = 4'd0;
    always @(posedge clk) if (rst || i_ready) nd <= 4'd0; else if (d_ready && nd != 4'd15) nd <= nd + 4'd1;
    wire new_d = d_req && !(d_req_q && !d_rdy_q && !rst_q);
`ifdef P_LI
`ifndef NO_DF_ASSUME
    always @(*) assume (!new_d || nd < `DF_N);
`endif
`endif
    reg [9:0] sc = 10'd0;  reg seen_idle = 1'b0;     // clocks from reset release to the first idle
    always @(posedge clk) if (rst) begin sc <= 10'd0; seen_idle <= 1'b0; end
                          else begin if (sc != 10'd1023) sc <= sc + 10'd1; if (q_idle) seen_idle <= 1'b1; end
    reg [9:0] dw = 10'd0, iw = 10'd0;       // clocks a request has waited
    always @(posedge clk) begin
        if (rst || !(d_req && !d_ready)) dw <= 10'd0; else if (dw != 10'd1023) dw <= dw + 10'd1;
        if (rst || !(i_req && !i_ready)) iw <= 10'd0; else if (iw != 10'd1023) iw <= iw + 10'd1;
    end
    always @(*) if (armed && !rst) begin
`ifdef P_LD
        assert (dw <= (strap ? `LD1 : `LD0));                                                   // ML1
        assert (seen_idle || sc <= `S_MAX);                                                     // S: reset release to the first idle
`endif
`ifdef P_LI
        assert (iw <= (strap ? `LI1 : `LI0));                                                   // ML2
`endif
    end
`endif

`ifdef P_FLASH
    reg wr_act = 1'b0;                      // a write transaction is in flight
    always @(posedge clk) if (rst) wr_act <= 1'b0; else begin
        if (q_done) wr_act <= 1'b0;
        if (start_ev && q_we) wr_act <= 1'b1;
    end
    reg [4:0] ec = 5'd0;                    // SCK rising edges seen in the current CS0 window
    reg okEB = 1'b1, okFF = 1'b1;           // IO0 so far a prefix of EBh / FFh
    wire edge0 = !cs_n[0] && sck && !sck_q;
    wire ebit = 8'hEB >> (~ec[2:0]);
    wire eb_now = okEB && (io_out[0] == ebit);
    wire ff_now = okFF && io_out[0];
    always @(posedge clk) begin
        if (rst || cs_n[0]) begin ec <= 5'd0; okEB <= 1'b1; okFF <= 1'b1; end
        else if (edge0) begin
            if (ec != 5'd31) ec <= ec + 5'd1;
            if (ec < 5'd8) begin okEB <= eb_now; okFF <= ff_now; end
        end
    end
    always @(*) if (armed && !rst) begin
        if (wr_act) assert (cs_n[0]);                                                           // MF1
        if (edge0 && ec < 5'd8) assert (io_oe && (eb_now || ff_now));                           // MF2
        if (edge0 && (ec == 5'd14 || ec == 5'd15) && okEB) assert (io_oe && io_out == 4'hF);    // MF3
    end
`endif

`ifdef P_TCEM
    reg [7:0] pl = 8'd0, fl = 8'd0;         // clocks in the current CS low run before this one
    wire pc = !cs_n[1] || !cs_n[2];
    wire fc = !cs_n[0] && !q_idle;          // an open stream held idle (CS0 low, engine idle) has no bound by design: not a run
    wire [7:0] pl_now = pc ? pl + 8'd1 : 8'd0, fl_now = fc ? fl + 8'd1 : 8'd0;
    always @(posedge clk) if (rst) begin pl <= 8'd0; fl <= 8'd0; end else begin
        pl <= (pl_now == 8'd255) ? 8'd255 : pl_now; fl <= (fl_now == 8'd255) ? 8'd255 : fl_now;
    end
    reg [2:0] cs_q = 3'b111, rise_q = 3'b000;
    reg i_burst_ever = 1'b0;
    always @(posedge clk) if (i_burst) i_burst_ever <= 1'b1;
    always @(posedge clk) begin cs_q <= cs_n; rise_q <= cs_n & ~cs_q; end
    always @(*) if (armed && !rst) begin
`ifdef BURST_FREE
        assert (pl_now <= `LPB);                                                                // MT1b a PSRAM line burst: one CS run <= LPB clocks
        assert (pl_now <= 8'd64 || i_burst_ever);                                               // MT1c longer than a single read only after a qualifier
`else
        assert (pl_now <= 8'd64);                                                               // MT1
        assert (pl_now <= (strap ? `LP1 : `LP0));                                               // MT1t
`endif
        assert (fl_now <= (strap ? `LF1 : `LF0));
        assert ((rise_q & ~cs_n) == 3'b000);                                                    // MT2
    end
`ifdef TCEM_IND
    // MT1b induction lemmas (WO-72), proved with the properties above. g = the most clocks the current PSRAM CS run can
    // have lasted, from the engine's position: a word costs CMD 4 + ADDR 12 + DUMMY 8 + DATA 16 (+1 S_TAIL with rd_late);
    // a continuation word END + IDLE + CHK + DATA 16 (+ TAIL) = 19 + L. E(n) = 40 + L + n (19 + L) is the run's length at
    // the end of its word n; a word at line index j is at most word j of its run, and p[3:2] - 1 is the line index of the
    // last word done while the stream is open (H6). So on a PSRAM run pl_now <= g <= E(3) = 97 + 4 L <= 101 <= LPB.
    // Every lemma is an assert, proved in the same k-induction (length 1) as MT1b; none is an assumption. The proof also
    // closes with -DLPB=101 and fails with 100, whose counterexample from reset WO-68 found (step 227): 101 is exact.
    localparam [3:0] S_IDLE = 4'd0, S_CMD = 4'd1, S_ADDR = 4'd2, S_DUMMY = 4'd3, S_DATA = 4'd4, S_TAIL = 4'd5, S_END = 4'd6,
                     S_CHK = 4'd7, S_CLOSE = 4'd8, S_GO = 4'd9;
    wire [7:0] Lx   = {7'd0, x_late};
    wire [1:0] jl   = x_p[3:2] - 2'd1;
    wire [7:0] E_j  = 8'd40 + Lx + {6'd0, jl} * (8'd19 + Lx);
    wire [7:0] E3   = 8'd97 + 8'd4 * Lx;
    wire [7:0] ph7  = {4'd0, 3'd7 - x_cnt, sck};                // (7 - cnt) * 2 + sck
    wire [2:0] isel = (x_step == 3'd3 || x_step == 3'd4 || x_step == 3'd5) ? 3'b001 : 3'b110;
    wire [2:0] dlast = x_t_top ? 3'd4 : {~q_nbytes_m1, 1'b0};
    reg  [7:0] g;
    always @(*) begin
        if (x_init) g = (x_state == S_CMD) ? 8'd1 + ph7 : 8'd0;
        else case (x_state)
            S_CMD:   g = 8'd1  + {6'd0, ~x_cnt[0], sck};
            S_ADDR:  g = 8'd5  + {4'd0, 3'd5 - x_cnt, sck};
            S_DUMMY: g = 8'd17 + {5'd0, 2'd3 - x_cnt[1:0], sck};
            S_DATA:  g = x_strm ? E_j + 8'd4 + ph7 : 8'd25 + ph7;
            S_TAIL:  g = x_strm ? E_j : (x_t_bst ? E3 : 8'd41);
            S_END:   g = x_strm ? E_j + 8'd1 : 8'd0;
            S_IDLE:  g = x_strm ? E_j + 8'd2 : 8'd0;
            S_CHK:   g = E_j + 8'd3;
            default: g = 8'd0;
        endcase
    end
    // gf: the same for the flash run fl (CS0 low, engine not idle): CMD 16 + ADDR 12 + DUMMY 12 + DATA 16 (+ TAIL) + END
    // with the stream left open; a stream word restarts the run at S_CHK (the idle clock before it is not a run)
    reg  [7:0] gf;
    always @(*) begin
        if (x_init) gf = (x_state == S_CMD) ? 8'd1 + (x_again ? 8'd16 : 8'd0) + ph7 : 8'd0;
        else case (x_state)
            S_CMD:   gf = 8'd1  + ph7;
            S_ADDR:  gf = 8'd17 + {4'd0, 3'd5 - x_cnt, sck};
            S_DUMMY: gf = 8'd29 + {4'd0, 3'd5 - x_cnt, sck};
            S_DATA:  gf = x_strm ? 8'd2 + ph7 : 8'd41 + ph7;
            S_TAIL:  gf = 8'd57;
            S_END:   gf = x_strm ? 8'd57 + Lx : 8'd0;
            S_CHK:   gf = 8'd1;
            default: gf = 8'd0;
        endcase
    end
    wire act = x_state == S_CMD || x_state == S_ADDR || x_state == S_DUMMY || x_state == S_DATA || x_state == S_TAIL ||
               x_state == S_END || x_state == S_CHK || x_state == S_GO || (x_state == S_CLOSE && x_cnt[0]);
    always @(*) if (armed && !rst) begin
        assert (pl_now <= g);                                                                   // H0 the ranking bound
        assert (fl_now <= gf);                                                                  // H0f the flash run's ranking bound
        assert (!x_t_ddr && x_late == strap);                                                   // H1 ddr tied 0; one strap
        assert (x_state <= S_GO);                                                               // H12 a legal state encoding
        if (x_state == S_TAIL) assert (x_late);
        if (rst_q) assert (x_init && x_state == S_IDLE && x_step == 3'd0 && x_cnt == 3'd0 && cs_n == 3'b111 && !x_strm &&
                           !x_pstrm && !x_t_bst && !x_again && !x_gnt_d && !x_second && pl == 8'd0 && fl == 8'd0);   // H14 the reset state
        if ((cs_q != cs_n) && !rst_q) assert (cs_q == 3'b111 || cs_n == 3'b111);                // H11 CS changes only from / to all high
        if (!rst_q && cs_q != 3'b111 && cs_n == 3'b111) assert (x_state == S_END || x_state == S_CLOSE);
        if (rise_q != 3'b000) assert (cs_n == 3'b111);                                          // (MT2)
        if (x_init) begin                                                                       // H2 start-up commands
            assert (!x_strm && (x_state == S_IDLE || x_state == S_CMD || x_state == S_END));
            assert (!x_pstrm && !x_gnt_d && !x_second);                                         // no request is taken before init ends
            assert (cs_n == ((x_state == S_CMD) ? ~isel : 3'b111));
            if (x_step != 3'd0 || x_state != S_IDLE) assert (!x_t_top);                         // cleared by the first command
        end else begin
            if (pc) assert (x_t_psram);                                                         // H3 a PSRAM CS belongs to a PSRAM transaction
            if (!cs_n[0]) assert (!x_t_psram);
            if (x_state == S_CLOSE || x_state == S_GO || ((x_state == S_IDLE || x_state == S_END) && !x_strm))
                assert (cs_n == 3'b111);                                                        // H4 CS high outside a transaction
            if (x_state == S_CHK || x_state == S_GO || (x_state == S_CLOSE && x_cnt[0]))
                assert ((x_t_sel[2:1] == 2'b00 || x_t_psram) && (!x_t_sel[0] || !x_t_psram));
            if (x_state == S_CHK) assert (x_strm);                                              // H5 stream states
            if (x_strm) assert (x_state == S_IDLE || x_state == S_CHK || x_state == S_DATA || x_state == S_TAIL || x_state == S_END);
            if (x_strm && !x_pstrm) assert (cs_n[2:1] == 2'b11);
            if (x_strm && x_pstrm) assert (x_t_psram && x_p[3:2] != 2'd0);                       // H6
            if (x_t_psram && x_state == S_CMD) assert (x_cnt <= 3'd1);                           // H7 phase counters
            if (x_state == S_ADDR) assert (x_cnt <= 3'd5);
            if (x_t_psram && !x_t_we && x_state == S_DUMMY) assert (x_cnt <= 3'd3);
            if (!x_t_psram && !x_t_we && x_state == S_DUMMY) assert (x_cnt <= 3'd5);
            if (x_state == S_DUMMY) assert (!x_t_we);                                            // a write has no dummies
            if (x_state == S_DATA) assert (x_cnt >= dlast && (!x_t_psram || !x_t_top));
            if (x_t_top) assert (!x_t_psram && !x_t_we);                                         // H13 a top-up is a flash stream read
            if (act) assert (x_gnt_d ? hold_d : hold_i);                                         // H8 the request is held (M-A1)
            if (x_second) assert (hold_i);
            if (x_state == S_CHK && x_pstrm) assert (x_t_bst && !x_gnt_d && !x_second);          // H9 a continuation word
            if (x_state == S_DATA && x_strm && x_pstrm)
                assert (x_t_bst && !x_gnt_d && !x_second && i_addr_q[3:2] == x_p[3:2] && q_nbytes_m1 == 2'd3);
        end
        if (x_t_bst || x_pstrm) assert (i_burst_ever);                                          // H10 (MT1c)
    end
`ifndef BURST_FREE
    // H15 (mem_tcem, MODE sind): the qualifier is tied low (assume above, unconditional), so no burst was ever asked for;
    // with H10 that rules out pstrm and t_bst, and H0 bounds a PSRAM run by one single read (MT1, MT1t). Not armed-gated:
    // i_burst_ever has no reset and holds 0 from the initial state on.
    always @(*) assert (!i_burst_ever);
`endif
`endif
`endif

`ifdef P_ARB
    reg kd = 1'b0;                          // the transaction in flight serves the data port
    reg pend = 1'b0;                        // a split's first half is done, the second is next
    wire pick = d_req && !pend;
    wire split_exp = i_addr[31] && (&i_addr[9:1]);
    always @(posedge clk) if (rst) begin kd <= 1'b0; pend <= 1'b0; end else begin
        if (start_ev) kd <= pick;
        if (q_done && !kd) pend <= !i_ready;
    end
    wire [1:0] cs_i = !i_addr[31] ? 2'd0 : (pend ? (nxt[23] ? 2'd2 : 2'd1) : (i_addr[23] ? 2'd2 : 2'd1));
    wire [1:0] cs_d = !d_addr[31] ? 2'd0 : (d_addr[23] ? 2'd2 : 2'd1);
    always @(*) if (armed && !rst) begin
        if (q_done) assert (d_ready == kd);                                                     // MD1
        if (pend) assert (!d_ready);                                                            // MD2
        if (pend && q_done) assert (i_ready);
        if (q_done && !kd) begin                                                                // MD3
            if (i_ready) assert (pend == split_exp); else assert (split_exp && !pend);
        end
        if (start_ev && !pick) assert (q_cs == cs_i);
        if (start_ev && pick)  assert (q_cs == cs_d);
        if (start_ev && pend)  assert (q_addr == {1'b0, nxt[22:10], 10'b0});
    end
`endif

`ifdef SBY_COVER
    genvar k;
`ifdef P_FLASH
    always @(*) begin
        cover (armed && !rst && start_ev && q_we && q_cs == 2'd0 && d_req);        // a flash-write start
        cover (armed && !rst && edge0 && ec == 5'd7 && okEB);                      // a full EBh command
        cover (armed && !rst && edge0 && ec == 5'd7 && okFF && !okEB);             // an FFh window
        cover (armed && !rst && edge0 && ec == 5'd15 && okEB);                     // the mode byte clocks
    end
`endif
`ifdef P_TCEM
    // the tight points only (the measured PSRAM / flash runs, both strap values)
    always @(*) begin
        cover (armed && !rst && pl_now == `LP0 && !strap);  cover (armed && !rst && pl_now == `LP1 && strap);
        cover (armed && !rst && fl_now == `LF0 && !strap);  cover (armed && !rst && fl_now == `LF1 && strap);
    end
    always @(*) cover (armed && !rst && rise_q != 3'b000 && cs_n == rise_q);
`endif
`ifdef P_ARB
    reg rst_cs = 1'b0;                              // a reset hit while a CS was low
    always @(posedge clk) if (rst && cs_n != 3'b111) rst_cs <= 1'b1;
    always @(*) begin
        cover (armed && !rst && i_ready && pend && i_addr == 32'h807F_FFFE);       // the A/B split fetch
        cover (armed && !rst && i_ready && i_addr == 32'h807F_FFFE);
        cover (armed && !rst && start_ev && d_req && i_req && !pend);              // data/fetch conflict at a start
        cover (armed && !rst && start_ev && d_req && i_req && pend);
        cover (armed && !rst && rst_cs && (i_ready || d_ready));                   // reset mid-CS, then a request completes
    end
`endif
`ifdef P_LAT
    // the tight points: the bound itself is reached (both strap values), and S
    always @(*) begin
        cover (armed && !rst && dw == `LD0 && !strap);  cover (armed && !rst && dw == `LD1 && strap);
        cover (armed && !rst && iw == `LI0 && !strap);  cover (armed && !rst && iw == `LI1 && strap);
        cover (armed && !rst && q_idle && !seen_idle && sc == `S_MAX);
    end
`endif
`endif
endmodule
