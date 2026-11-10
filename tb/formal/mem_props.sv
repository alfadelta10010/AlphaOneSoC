// Memory path (WO-31 part B): mem_ctrl wired to qspi_ctrl as in src/alphaone_soc.v
// (the q_* wires are this harness's own). One props file, four groups selected by
// a define so each sidecar proves one cluster by pdr:
//   P_FLASH  MF1 a write never selects CS0; MF2 IO0 in a CS0 window is a prefix of
//            0xEB or 0xFF (the device-level form: no 06h, no write); MF3 mode byte FFh
//   P_TCEM   MT1 a PSRAM CS run <= 64 clocks (tCEM 8 us at the 8 MHz floor);
//            MT1t the measured PSRAM / flash runs; MT2 CS high >= 2 clocks (tCPH)
//   P_ARB    MD1 data first; MD2 split halves are consecutive; MD3 split iff
//            i_addr[31] && &i_addr[9:1], second half on the right chip
//   P_LD     ML1 held d_req answered within LD clocks (no M-A4)
//   P_LI     ML2 held i_req answered within LI clocks (needs M-A4)
// Assumptions: M-A1 a request not yet answered is held unchanged; M-A2 PMA (stores to
// flash are NOT excluded: the engine's backstop is under test); M-A3 rd_late stable
// while !rst (syscon holds the strap); M-A4 (P_LI, ifndef NO_DF_ASSUME) at most DF_N
// data handshakes between two fetch handshakes (core_df_props.sv discharges it).
// Every assert is gated on `armed` (set only by rst). No white-box access.
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
    input  wire        i_req, d_req, d_we,
    input  wire [31:0] i_addr, d_addr, d_wdata,
    input  wire [3:0]  d_be, io_in,
    input  wire        rd_late,
    input  wire        stream_en    // free: streaming on, off and toggling are all covered (WO-54a)
);
    wire [31:0] i_rdata, d_rdata, q_wdata, q_rdata;
    wire        i_ready, d_ready, q_start, q_we, q_idle, q_done;
    wire [1:0]  q_cs, q_nbytes_m1;
    wire [23:0] q_addr;
    wire        sck, ctl_oe, io_oe;
    wire [2:0]  cs_n;
    wire [3:0]  io_out;

    mem_ctrl memc (.clk(clk), .rst(rst), .i_req(i_req), .i_addr(i_addr), .i_rdata(i_rdata), .i_ready(i_ready),
        .d_req(d_req), .d_addr(d_addr), .d_wdata(d_wdata), .d_be(d_be), .d_we(d_we), .d_rdata(d_rdata), .d_ready(d_ready),
        .q_start(q_start), .q_cs(q_cs), .q_addr(q_addr), .q_we(q_we), .q_nbytes_m1(q_nbytes_m1), .q_wdata(q_wdata),
        .q_idle(q_idle), .q_done(q_done), .q_rdata(q_rdata));
    qspi_ctrl qspi (.clk(clk), .rst(rst), .rd_late(rd_late), .start(q_start), .cs_sel(q_cs), .addr(q_addr), .we(q_we),
        .nbytes_m1(q_nbytes_m1), .wdata(q_wdata), .idle(q_idle), .done(q_done), .rdata(q_rdata),
        .sck(sck), .cs_n(cs_n), .ctl_oe(ctl_oe), .io_out(io_out), .io_oe(io_oe), .io_in(io_in), .stream_en(stream_en),
        .ddr(1'b0), .ddr_cap(3'd0));      // WO-54b: SDR property list, see mem.conf

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
    always @(posedge clk) begin cs_q <= cs_n; rise_q <= cs_n & ~cs_q; end
    always @(*) if (armed && !rst) begin
        assert (pl_now <= 8'd64);                                                               // MT1
        assert (pl_now <= (strap ? `LP1 : `LP0));                                               // MT1t
        assert (fl_now <= (strap ? `LF1 : `LF0));
        assert ((rise_q & ~cs_n) == 3'b000);                                                    // MT2
    end
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
