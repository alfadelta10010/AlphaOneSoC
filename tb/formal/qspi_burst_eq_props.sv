// WO-68: equivalence of the QSPI engine before and after the PSRAM line burst, with the qualifier tied low.
// The reference is src/qspi_ctrl.v as of 22f7bc8 (tb/formal/qspi_ctrl_pre_burst.v, module qspi_ctrl_pre_burst); the new engine is
// src/qspi_ctrl.v with burst = 0. Same free inputs to both (ddr, ddr_cap, stream_en, rd_late, the request, io_in), both reset
// together; every pin and handshake output must agree on every clock, with the PSRAM burst present in the design but
// never asked for. This is the silicon safety argument: software leaves the cache off (CACHE_CTL.EN = 0, the reset
// state), the qualifier never rises, and the pins cannot differ from the proven engine. Like qspi_pins it runs the real
// engine, negedge flops included, through clk2fflogic (sby `multiclock on`): the inputs change only at the step where clk
// rises. Uninitialised state (sr, p, nib_*, t_*) starts at 0 in both copies (PASSES setundef -zero -init) so the two
// engines start from the same state; rdata is compared when done is high (sr is not cleared between transactions, but
// done is the only cycle the requester reads it, and a transfer's unwritten bytes are the same in both), the data pins
// only when the bus is driven.
module qspi_burst_eq_props (
    input  wire        clk, rst, rd_late, stream_en, ddr,
    input  wire [2:0]  ddr_cap,
    input  wire        start, we,
    input  wire [1:0]  cs_sel, nbytes_m1,
    input  wire [23:0] addr,
    input  wire [31:0] wdata,
    input  wire [3:0]  io_in
);
    wire        idle_n, done_n, sck_n, ctl_oe_n, io_oe_n;
    wire        idle_r, done_r, sck_r, ctl_oe_r, io_oe_r;
    wire [31:0] rdata_n, rdata_r;
    wire [2:0]  cs_n_n, cs_n_r;
    wire [3:0]  io_out_n, io_out_r;
    wire [104:0] tap_n, tap_r;
    wire [1:0]   x_n, x_r;
    qspi_ctrl_tap_new dut (.eq_tap(tap_n), .eq_x(x_n), .clk(clk), .rst(rst), .rd_late(rd_late), .stream_en(stream_en), .ddr(ddr), .ddr_cap(ddr_cap), .burst(1'b0),
        .start(start), .cs_sel(cs_sel), .addr(addr), .we(we), .nbytes_m1(nbytes_m1), .wdata(wdata),
        .idle(idle_n), .done(done_n), .rdata(rdata_n), .sck(sck_n), .cs_n(cs_n_n), .ctl_oe(ctl_oe_n), .io_out(io_out_n),
        .io_oe(io_oe_n), .io_in(io_in));
    qspi_ctrl_tap_old ref (.eq_tap(tap_r), .eq_x(x_r), .clk(clk), .rst(rst), .rd_late(rd_late), .stream_en(stream_en), .ddr(ddr), .ddr_cap(ddr_cap),
        .start(start), .cs_sel(cs_sel), .addr(addr), .we(we), .nbytes_m1(nbytes_m1), .wdata(wdata),
        .idle(idle_r), .done(done_r), .rdata(rdata_r), .sck(sck_r), .cs_n(cs_n_r), .ctl_oe(ctl_oe_r), .io_out(io_out_r),
        .io_oe(io_oe_r), .io_in(io_in));

    reg armed = 1'b0;
    always @(posedge clk) if (rst) armed <= 1'b1;
    wire live = armed && !rst;

    // Induction helper (tb/formal/qspi_burst_eq_gen.sh exports the state): with burst tied low the burst-only
    // flops pstrm and t_bst stay 0 and every register both engines have stays equal. Both hold from the start state
    // (both copies start at 0) through reset and every input, so they are inductive; the pin equalities below follow.
    always @(*) begin
        assert (x_n == 2'b00);
        assert (tap_n == tap_r);
    end

    always @(*) if (live) begin
        assert (idle_n == idle_r);
        assert (done_n == done_r);
        assert (sck_n == sck_r);
        assert (cs_n_n == cs_n_r);
        assert (ctl_oe_n == ctl_oe_r);
        assert (io_oe_n == io_oe_r);
        if (io_oe_r) assert (io_out_n == io_out_r);
        if (done_r) assert (rdata_n == rdata_r);
    end

    // clock model, as in qspi_pins_props.sv
    (* gclk *) reg gclk;
    reg gseen = 1'b0, clk_p = 1'b0;
    wire [68:0] ins = {rst, rd_late, stream_en, ddr, ddr_cap, start, we, cs_sel, nbytes_m1, addr, wdata};
    reg  [68:0] ins_p;
    always @(posedge gclk) begin gseen <= 1'b1; clk_p <= clk; ins_p <= ins; end
    always @(*) begin
        assume (gseen || !clk);
        assume (!gseen || clk != clk_p);
        assume (!gseen || (clk && !clk_p) || ins == ins_p);
    end

`ifdef SBY_COVER
    always @(*) begin
        cover (live && done_r && cs_n_r != 3'b111);                                       // a stream left open after a read
        cover (live && done_r && ddr && !cs_n_r[0]);
        cover (live && done_r && (!cs_n_r[1] || !cs_n_r[2]));                             // a PSRAM transfer ended (CS still low in done)
    end
`endif
endmodule
