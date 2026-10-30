// Cover points for the bounded SPI check (WO-29 7.2 spi_cover). They guard
// spi_bb's assumption against vacuity: if a situation the properties are
// about cannot happen under the same assumption, a green spi_bb proves
// nothing about it. run.sh compiles this file once per point with
// -D COVER_n; each point is assert(!cond), so a counterexample means COVERED
// and "no model found" means UNREACHABLE (a failure).
//   1 a back-to-back LOAD from B
//   2 a TXDATA write stalled for 2 clocks or more, then accepted
//   3 an OUT write stalled for 2 clocks or more
//   4 a byte completed in mode 1, and a byte completed in mode 2
//   5 an EN 0 -> 1 write that moves SCK to CPOL
//   6 rst in B with the holding register full
// Same assumption as spi_bb: a BAUD write carries wdata[7:0] = 0.
// White-box names (exposed by run.sh, as in spi_bus): x_st x_cc x_bc x_bba
// x_cpol x_cpha and spi_en.
module spi_cover_props (
    input  wire        clk, rst,
    input  wire        sel, we,
    input  wire [3:0]  be,
    input  wire [5:2]  addr,
    input  wire [31:0] wdata,
    input  wire [7:0]  in
);
    wire [31:0] rdata;
    wire        ready;
    wire [7:0]  out;
    wire        x_wr_tx, x_wr_ctl, x_wr_baud, x_wr_en, x_wr_out, x_miso, x_bba, x_cpol, x_cpha, spi_en;
    wire [1:0]  x_st;
    wire [7:0]  x_bb, x_sr, x_baud, x_cc, in_m, in_s, out_r;
    wire [2:0]  x_bc;
    gpio dut (.clk(clk), .rst(rst), .sel(sel), .we(we), .be(be), .addr(addr), .wdata(wdata),
              .rdata(rdata), .ready(ready), .in(in), .out(out),
              .x_wr_tx(x_wr_tx), .x_wr_ctl(x_wr_ctl), .x_wr_baud(x_wr_baud), .x_wr_en(x_wr_en),
              .x_wr_out(x_wr_out), .x_miso(x_miso), .x_st(x_st), .x_bba(x_bba), .x_bb(x_bb),
              .x_sr(x_sr), .x_baud(x_baud), .x_cpol(x_cpol), .x_cpha(x_cpha), .x_cc(x_cc), .x_bc(x_bc),
              .spi_en(spi_en), .in_m(in_m), .in_s(in_s), .out_r(out_r));

    wire req = sel && we && be[0];
    reg armed = 1'b0;
    reg [1:0] st_q = 0;  reg [7:0] cc_q = 0;  reg [2:0] bc_q = 0;  reg bba_q = 0, en_q = 0, sck_q = 0;
    reg cpol_q = 0, cpha_q = 0;
    reg [1:0] txs = 0, ons = 0;                 // consecutive stalled clocks (saturating at 2)
    reg [1:0] txa = 0, ona = 0;                 // saw an accepted write after >= 2 stalled clocks
    reg seen_m1 = 0, seen_m2 = 0;
    wire byte_done = armed && st_q == 2'd2 && cc_q == 8'd0 && bc_q == 3'd0;
    always @(posedge clk) begin
        if (rst) armed <= 1'b1;
        st_q <= x_st; cc_q <= x_cc; bc_q <= x_bc; bba_q <= x_bba; en_q <= spi_en; sck_q <= out[3];
        cpol_q <= x_cpol; cpha_q <= x_cpha;
        txs <= (req && addr == 4'd9 && !ready) ? (txs == 2'd2 ? 2'd2 : txs + 2'd1) : 2'd0;
        ons <= (req && addr == 4'd0 && !ready) ? (ons == 2'd2 ? 2'd2 : ons + 2'd1) : 2'd0;
        if (byte_done && !cpol_q &&  cpha_q) seen_m1 <= 1'b1;
        if (byte_done &&  cpol_q && !cpha_q) seen_m2 <= 1'b1;
    end
    wire c1 = armed && st_q == 2'd2 && cc_q == 8'd0 && bc_q == 3'd0 && bba_q && x_st == 2'd1;
    wire c2 = armed && req && addr == 4'd9 && ready && txs == 2'd2;
    wire c3 = armed && req && addr == 4'd0 && ready && ons == 2'd2;
    wire c4 = seen_m1 && seen_m2;
    wire c5 = armed && !en_q && spi_en && out[3] != sck_q;
    wire c6 = armed && rst && x_st == 2'd2 && x_bba;

    always @(*) begin
        assume (!(req && ready && addr == 4'd12 && wdata[7:0] != 8'd0));
`ifdef COVER_1
        assert (!c1);
`endif
`ifdef COVER_2
        assert (!c2);
`endif
`ifdef COVER_3
        assert (!c3);
`endif
`ifdef COVER_4
        assert (!c4);
`endif
`ifdef COVER_5
        assert (!c5);
`endif
`ifdef COVER_6
        assert (!c6);
`endif
    end
endmodule
