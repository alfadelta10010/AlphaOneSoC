// SPI bus rules at gpio, proved by k-induction at length 1 (WO-29 7.2):
// G1-G6 are the guarantees gpio gives spi (the assumptions AC1-AC6 of
// spi_core_props.sv, proved back here over gpio's real strobe wires), B1-B9
// are the bus rules of WO-28 1.2 written against the ports. Checks that name
// a register write use a strobe computed here from the ports (`spw`), not
// gpio's own, so a wrong decode in gpio is a failure.
// White-box names, exposed from the committed RTL by run.sh (PRE): gpio's
// spi_en, in_m, in_s, out_r, and spi_inst's wr_tx wr_ctl wr_baud wr_en wr_out wr_st
// miso st bba bb sr baud cpol cpha (renamed x_*). The port map is WO-28 1.2:
// slot (addr[5:2]) 0 OUT, 1 IN, 3 SPICTL, 8 RXDATA, 9 TXDATA, 10 STATUS,
// 11 CONTROL, 12 BAUD, 6 IN_IE, 7 IN_IP (WO-69, input-change interrupt, never stall),
// others reserved. in_p, in_ie, in_ip are exposed too.
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
    wire [7:0]  out, in_sync;
    wire        spi_irq, in_irq;
    wire        x_wr_tx, x_wr_ctl, x_wr_baud, x_wr_en, x_wr_out, x_wr_st, x_miso, x_bba, x_cpol, x_cpha, spi_en;
    wire [1:0]  x_st;
    wire [7:0]  x_bb, x_sr, x_baud, in_m, in_s, in_p, in_ie, in_ip, out_r;

    gpio dut (.clk(clk), .rst(rst), .sel(sel), .we(we), .be(be), .addr(addr), .wdata(wdata),
              .rdata(rdata), .ready(ready), .in(in), .out(out), .in_sync(in_sync), .spi_irq(spi_irq), .in_irq(in_irq),
              .x_wr_tx(x_wr_tx), .x_wr_ctl(x_wr_ctl), .x_wr_baud(x_wr_baud), .x_wr_en(x_wr_en),
              .x_wr_out(x_wr_out), .x_wr_st(x_wr_st), .x_miso(x_miso), .x_st(x_st), .x_bba(x_bba), .x_bb(x_bb),
              .x_sr(x_sr), .x_baud(x_baud), .x_cpol(x_cpol), .x_cpha(x_cpha),
              .spi_en(spi_en), .in_m(in_m), .in_s(in_s), .in_p(in_p), .in_ie(in_ie), .in_ip(in_ip), .out_r(out_r));

    wire txe = (x_st == 2'd0) && !x_bba;
    wire txr = !x_bba;

    // the strobe the spec calls for: an accepted write with lane 0
    wire spw = sel && we && be[0] && ready;

    reg armed = 1'b0;               // a reset has been applied; every assert is gated on it
    always @(posedge clk) if (rst) armed <= 1'b1;
    reg rst_q = 1'b0, spw_q = 1'b0, txe_q = 1'b0, bba_q = 1'b0, en_q = 1'b0, wr_en_q = 1'b0;
    reg wrst_q = 1'b0, txr_q = 1'b0, irq_q = 1'b0;
    reg [5:2] addr_q = 0;  reg [31:0] wdata_q = 0;  reg [7:0] in_q = 0, in_m_q = 0, out_r_q = 0;
    reg [7:0] in_s_q = 0, in_p_q = 0, ip_q = 0, ie_q = 0;
    reg [7:0] bb_q = 0, baud_q = 0, out_q = 0;  reg cpol_q = 0, cpha_q = 0, ctl_q = 0;
    always @(posedge clk) begin
        wrst_q <= wr_st; txr_q <= txr; irq_q <= spi_irq;
        rst_q <= rst; spw_q <= spw; txe_q <= txe; bba_q <= x_bba; en_q <= spi_en; wr_en_q <= x_wr_en;
        addr_q <= addr; wdata_q <= wdata; in_q <= in; in_m_q <= in_m; out_r_q <= out_r; out_q <= out;
        in_s_q <= in_s; in_p_q <= in_p; ip_q <= in_ip; ie_q <= in_ie;
        bb_q <= x_bb; baud_q <= x_baud; cpol_q <= x_cpol; cpha_q <= x_cpha;
    end

    wire [5:0] strobes = {x_wr_st, x_wr_tx, x_wr_ctl, x_wr_baud, x_wr_en, x_wr_out};
    wire       wr_st = spw && addr == 4'd10;   // the spec's STATUS write; x_wr_st is spi's real port (G1b)
    wire       req = sel && we && be[0];
    wire [7:0] clrw_q = (spw_q && addr_q == 4'd7) ? wdata_q[7:0] : 8'h00;   // the W1C the last clock applied

    always @(*) if (armed) begin
        // ---- the guarantees for spi_core's assumptions
        assert ((strobes & (strobes - 6'd1)) == 6'd0);                              // G1 (AC1, six strobes with wr_st)
        assert (x_wr_st == wr_st);                                                  // G1b: the real wr_st wire is the spec's decode
        assert (!(x_wr_tx && x_bba));                                               // G2 (AC2)
        assert (!((x_wr_ctl || x_wr_baud || x_wr_en || x_wr_out) && !txe));         // G3 (AC3)
        assert (!(spi_en != en_q && !txe_q && !rst_q));                             // G4 (AC4)
        assert (!(spi_en && !en_q && (rst_q || !wr_en_q)));                         // G5 (AC5)
        assert (!(wr_en_q && !rst_q && !spi_en));                                   // G6 (AC6)
        // ---- bus rules
        assert (ready || req);                                                      // B1
        if (sel && !we) assert (ready);                                             // B2
        if (req && addr == 4'd9)  assert (!ready == x_bba);                         // B3
        if (req && addr != 4'd9 && addr != 4'd10 && addr != 4'd6 && addr != 4'd7) assert (!ready == !txe);           // B4
        if (req && addr == 4'd10) assert (ready);                                   // B4b: STATUS writes never wait
        if (req && (addr == 4'd6 || addr == 4'd7)) assert (ready);                  // B4c: IN_IE / IN_IP never wait (read or write)
        if (!(sel && we && be[0])) assert (ready);                                  // B5 (no stall without lane 0)
        assert (in_sync == in_s);
        // spi_irq = (TXR & en1) | (TXE & en0), the enables set by a STATUS write (spi_core proves the same rules)
        if (spi_irq) assert (txr);                                                  // IRQ1
        if (rst_q) assert (!spi_irq);                                               // IRQ2
        if (wrst_q && !rst_q) assert (spi_irq == ((txr && wdata_q[1]) || (txe && wdata_q[0])));  // IRQ3
        if (!wrst_q && !rst_q && txr == txr_q && txe == txe_q) assert (spi_irq == irq_q);        // IRQ4
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
        if (addr == 4'd6)  assert (rdata == {24'b0, in_ie});
        if (addr == 4'd7)  assert (rdata == {24'b0, in_ip});
        if (addr == 4'd2 || addr == 4'd4 || addr == 4'd5 || addr >= 4'd13) assert (rdata == 32'h0);
        // ---- WO-69: the input-change interrupt
        assert (in_irq == |(in_ip & in_ie));                                        // I1: level, from the flops
        assert (in_p == in_s_q);                                                    // I2: in_p is in_s one clock later
        // ---- B7
        if (rst_q) begin
            assert (in_ip == 8'h00 && in_ie == 8'h00);                              // I3: no phantom IP, IE off
            assert (out == 8'hB9 && !spi_en);
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
                assert (out[0] == wdata_q[0] && out[2] == wdata_q[2] && out[7:4] == wdata_q[7:4]);
                if (en_q) assert (out[1] == out_q[1] && out[3] == out_q[3]);
                else      assert (out[1] == wdata_q[1] && out[3] == wdata_q[3]);
            end
            // I4: IP sets exactly on an edge of the synchronised input, W1C clears only the written bits,
            // and a same-clock edge wins over the clear
            assert (((in_s_q ^ in_p_q) & ~in_ip) == 8'h00);                         // I4a: every edge is set
            assert ((ip_q & ~clrw_q & ~in_ip) == 8'h00);                            // I4b: a bit clears only by a W1C of it
            assert ((in_ip & ~ip_q & ~(in_s_q ^ in_p_q)) == 8'h00);                 // I4c: a bit sets only on an edge
            assert (((ip_q & clrw_q & ~(in_s_q ^ in_p_q)) & in_ip) == 8'h00);       // I4d: a W1C clears (without an edge)
            if (in_ie != ie_q) assert (spw_q && addr_q == 4'd6 && in_ie == wdata_q[7:0]);   // I5: IE changes by its own write
            if (spw_q && addr_q == 4'd6) assert (in_ie == wdata_q[7:0]);
            assert (in_m == in_q);
            assert (in_s == in_m_q);
        end
    end

`ifdef SBY_COVER
    // antecedents of the implication asserts above: an unreached one makes its assert vacuous
    always @(*) begin
        cover (armed && sel && !we); cover (armed && req && addr == 4'd9); cover (armed && req && addr == 4'd9 && !ready);
        cover (armed && req && addr != 4'd9 && !ready); cover (armed && rst_q); cover (armed && !rst_q && spw_q && addr_q == 4'd0);
        cover (armed && !rst_q && spw_q && addr_q == 4'd3); cover (armed && !rst_q && spw_q && addr_q == 4'd12);
        cover (armed && !rst_q && spw_q && addr_q == 4'd11); cover (armed && !rst_q && spw_q && addr_q == 4'd9);
        cover (armed && addr == 4'd8); cover (armed && addr == 4'd10);
        cover (armed && !rst_q && (in_s_q ^ in_p_q) != 8'h00); cover (armed && !rst_q && clrw_q != 8'h00 && (ip_q & clrw_q) != 8'h00);
        cover (armed && in_irq); cover (armed && req && addr == 4'd7); cover (armed && !rst_q && clrw_q != 8'h00 && (clrw_q & (in_s_q ^ in_p_q)) != 8'h00);
    end
`endif
endmodule
