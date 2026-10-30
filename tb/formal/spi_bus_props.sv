// SPI bus rules at gpio, proved by k-induction at length 1 (WO-29 7.2):
// G1-G6 are the guarantees gpio gives spi (the assumptions AC1-AC6 of
// spi_core_props.sv, proved back here over gpio's real strobe wires), B1-B9
// are the bus rules of WO-28 1.2 written against the ports. Checks that name
// a register write use a strobe computed here from the ports (`spw`), not
// gpio's own, so a wrong decode in gpio is a failure.
// White-box names, exposed from the committed RTL by run.sh (PRE): gpio's
// spi_en, in_m, in_s, out_r, and spi_inst's wr_tx wr_ctl wr_baud wr_en wr_out
// miso st bba bb sr baud cpol cpha (renamed x_*). The port map is WO-28 1.2:
// slot (addr[5:2]) 0 OUT, 1 IN, 3 SPICTL, 8 RXDATA, 9 TXDATA, 10 STATUS,
// 11 CONTROL, 12 BAUD, others reserved.
module spi_bus_props (
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
    wire [7:0]  x_bb, x_sr, x_baud, in_m, in_s, out_r;

    gpio dut (.clk(clk), .rst(rst), .sel(sel), .we(we), .be(be), .addr(addr), .wdata(wdata),
              .rdata(rdata), .ready(ready), .in(in), .out(out),
              .x_wr_tx(x_wr_tx), .x_wr_ctl(x_wr_ctl), .x_wr_baud(x_wr_baud), .x_wr_en(x_wr_en),
              .x_wr_out(x_wr_out), .x_miso(x_miso), .x_st(x_st), .x_bba(x_bba), .x_bb(x_bb),
              .x_sr(x_sr), .x_baud(x_baud), .x_cpol(x_cpol), .x_cpha(x_cpha),
              .spi_en(spi_en), .in_m(in_m), .in_s(in_s), .out_r(out_r));

    wire txe = (x_st == 2'd0) && !x_bba;
    wire txr = !x_bba;

    // the strobe the spec calls for: an accepted write with lane 0
    wire spw = sel && we && be[0] && ready;

    reg rst_q = 1'b0, spw_q = 1'b0, txe_q = 1'b0, bba_q = 1'b0, en_q = 1'b0, wr_en_q = 1'b0;
    reg [5:2] addr_q = 0;  reg [31:0] wdata_q = 0;  reg [7:0] in_q = 0, in_m_q = 0, out_r_q = 0;
    reg [7:0] bb_q = 0, baud_q = 0, out_q = 0;  reg cpol_q = 0, cpha_q = 0, ctl_q = 0;
    always @(posedge clk) begin
        rst_q <= rst; spw_q <= spw; txe_q <= txe; bba_q <= x_bba; en_q <= spi_en; wr_en_q <= x_wr_en;
        addr_q <= addr; wdata_q <= wdata; in_q <= in; in_m_q <= in_m; out_r_q <= out_r; out_q <= out;
        bb_q <= x_bb; baud_q <= x_baud; cpol_q <= x_cpol; cpha_q <= x_cpha;
    end

    wire [4:0] strobes = {x_wr_tx, x_wr_ctl, x_wr_baud, x_wr_en, x_wr_out};
    wire       req = sel && we && be[0];

    always @(*) begin
        // ---- the guarantees for spi_core's assumptions
        assert ((strobes & (strobes - 5'd1)) == 5'd0);                              // G1 (AC1)
        assert (!(x_wr_tx && x_bba));                                               // G2 (AC2)
        assert (!((x_wr_ctl || x_wr_baud || x_wr_en || x_wr_out) && !txe));         // G3 (AC3)
        assert (!(spi_en != en_q && !txe_q && !rst_q));                             // G4 (AC4)
        assert (!(spi_en && !en_q && (rst_q || !wr_en_q)));                         // G5 (AC5)
        assert (!(wr_en_q && !rst_q && !spi_en));                                   // G6 (AC6)
        // ---- bus rules
        assert (ready || req);                                                      // B1
        if (sel && !we) assert (ready);                                             // B2
        if (req && addr == 4'd9)  assert (!ready == x_bba);                         // B3
        if (req && addr != 4'd9)  assert (!ready == !txe);                          // B4
        if (!(sel && we && be[0])) assert (ready);                                  // B5 (no stall without lane 0)
        assert (out[5:4] == 2'b00);
        assert (x_miso == in_m[1]);                                                 // B9
        // ---- B8: the read mux
        if (addr == 4'd0)  assert (rdata == {24'b0, out});
        if (addr == 4'd1)  assert (rdata == {24'b0, in_s});
        if (addr == 4'd3)  assert (rdata == {23'b0, !txe, 7'b0, spi_en});
        if (addr == 4'd8)  assert (rdata == {24'b0, x_sr});
        if (addr == 4'd9)  assert (rdata == {24'b0, x_bb});
        if (addr == 4'd10) assert (rdata == {30'b0, txr, txe});
        if (addr == 4'd11) assert (rdata == {30'b0, x_cpol, x_cpha});
        if (addr == 4'd12) assert (rdata == {24'b0, x_baud});
        if (addr == 4'd2 || (addr >= 4'd4 && addr <= 4'd7) || addr >= 4'd13) assert (rdata == 32'h0);
        // ---- B7
        if (rst_q) begin
            assert (out == 8'h89 && !spi_en);
            if (addr == 4'd3) assert (rdata == 32'h0);
        end
        // ---- B5, B6 as transitions: nothing but an accepted write (to its own slot) changes a register
        if (!rst_q) begin
            if (out_r != out_r_q)   assert (spw_q && addr_q == 4'd0);
            if (spi_en != en_q)     assert (spw_q && addr_q == 4'd3);
            if (x_baud != baud_q)   assert (spw_q && addr_q == 4'd12);
            if (x_cpol != cpol_q || x_cpha != cpha_q) assert (spw_q && addr_q == 4'd11);
            if (!bba_q && x_bba)    assert (spw_q && addr_q == 4'd9);
            if (x_bb != bb_q)       assert ((spw_q && addr_q == 4'd9) || bba_q);
            if (spw_q && addr_q == 4'd0) begin                                      // B6
                assert (out[0] == wdata_q[0] && out[2] == wdata_q[2] && out[6] == wdata_q[6] && out[7] == wdata_q[7]);
                if (en_q) assert (out[1] == out_q[1] && out[3] == out_q[3]);
                else      assert (out[1] == wdata_q[1] && out[3] == wdata_q[3]);
            end
            assert (in_m == in_q);
            assert (in_s == in_m_q);
        end
    end
endmodule
