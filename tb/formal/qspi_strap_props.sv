// Strap held (WO-31 part C, REQ-SYS-007; kills survivor QS06): two copies of the QSPI
// engine see the same inputs except rd_late. Copy A gets a free rd_late; copy B gets the
// value A saw on the last cycle rst was high (a harness latch). rd_late is a strap,
// sampled during reset and held (soc-architecture: "a pin that changes later cannot
// move the sampling point mid-read"), so every output of the two must be equal.
// The engine's read data register `sr` and its t_we/t_psram flops are not reset (they
// are written before they are read); the generated qspi_x.v (qspi_ctrl.v renamed, with
// those flops and the control flops as extra outputs, see qspi_strap.conf) lets the harness start both copies in
// the same arbitrary state (a first-cycle assume only: the reset-reached states are a subset).
module qspi_strap_props (
    input  wire        clk, rst, rd_late,
    input  wire        start, we,
    input  wire [1:0]  cs_sel, nbytes_m1,
    input  wire [23:0] addr,
    input  wire [31:0] wdata,
    input  wire [3:0]  io_in
);
    reg armed = 1'b0;               // a reset has been applied; every assert is gated on it
    always @(posedge clk) if (rst) armed <= 1'b1;
    reg lat = 1'b0;
    always @(posedge clk) if (rst) lat <= rd_late;
    wire rd_b = rst ? rd_late : lat;

    wire a_idle, a_done, b_idle, b_done, a_sck, b_sck, a_ctl, b_ctl, a_oe, b_oe;
    wire [31:0] a_rdata, b_rdata, a_sr, b_sr;
    wire [2:0] a_cs, b_cs;  wire [3:0] a_io, b_io;  wire [1:0] a_tt, b_tt;  wire [11:0] a_all, b_all;
    qspi_x a (.clk(clk), .rst(rst), .rd_late(rd_late), .start(start), .cs_sel(cs_sel), .addr(addr), .we(we),
        .nbytes_m1(nbytes_m1), .wdata(wdata), .idle(a_idle), .done(a_done), .rdata(a_rdata), .sck(a_sck),
        .cs_n(a_cs), .ctl_oe(a_ctl), .io_out(a_io), .io_oe(a_oe), .io_in(io_in), .x_sr(a_sr), .x_tt(a_tt), .x_all(a_all));
    qspi_x b (.clk(clk), .rst(rst), .rd_late(rd_b), .start(start), .cs_sel(cs_sel), .addr(addr), .we(we),
        .nbytes_m1(nbytes_m1), .wdata(wdata), .idle(b_idle), .done(b_done), .rdata(b_rdata), .sck(b_sck),
        .cs_n(b_cs), .ctl_oe(b_ctl), .io_out(b_io), .io_oe(b_oe), .io_in(io_in), .x_sr(b_sr), .x_tt(b_tt), .x_all(b_all));

    reg seen = 1'b0;
    always @(posedge clk) seen <= 1'b1;
    always @(*) begin
        // both copies start in the same (arbitrary) state, registered pins included
        assume (seen || (a_sr == b_sr && a_tt == b_tt && a_all == b_all && a_sck == b_sck && a_cs == b_cs && a_ctl == b_ctl && a_oe == b_oe));
        if (armed) begin
            assert (a_idle == b_idle); assert (a_done == b_done); assert (a_rdata == b_rdata);
            assert (a_sck == b_sck);   assert (a_cs == b_cs);     assert (a_ctl == b_ctl);
            assert (a_io == b_io);     assert (a_oe == b_oe);
            assert (a_all == b_all);    // the control flops, the read register and the write-direction flops agree:
            assert (a_sr == b_sr);      // helper lemmas that make the miter 1-inductive
            assert (a_tt == b_tt);
        end
    end

`ifdef SBY_COVER
    reg rdtx = 1'b0;                // a read transaction is in flight
    always @(posedge clk) if (rst) rdtx <= 1'b0; else begin
        if (a_done) rdtx <= 1'b0;
        if (a_idle && start && !we) rdtx <= 1'b1;
    end
    always @(*) cover (armed && !rst && rdtx && rd_late != lat && a_cs != 3'b111);
`endif
endmodule
