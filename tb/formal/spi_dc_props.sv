// cc and bc are don't-care in IDLE (SPI-017, WO-29 D1): two copies of spi
// get the same inputs, and every output is equal in every cycle. The
// induction invariant is "all state equal, except cc and bc, which may
// differ while st = IDLE". cc and bc have no reset, so the copies are free to
// differ from the first reset on. No contract with gpio is needed: neither
// copy reads cc or bc in IDLE, and a LOAD sets both.
// White-box names (WO-28 2.1, exposed by run.sh): st cc bc bba sr bb cpol cpha baud.
module spi_dc_props (
    input  wire       clk, rst,
    input  wire       en, miso,
    input  wire [7:0] wdata,
    input  wire       wr_tx, wr_ctl, wr_baud, wr_en, wr_out
);
    wire [7:0] rx1, tx1, bd1, rx2, tx2, bd2;
    wire       txe1, txr1, mo1, sc1, txe2, txr2, mo2, sc2;
    wire [1:0] ct1, ct2, st1, st2;
    wire [7:0] sr1, bb1, cc1, ba1, sr2, bb2, cc2, ba2;
    wire [2:0] bc1, bc2;
    wire       bba1, cpol1, cpha1, bba2, cpol2, cpha2;

    spi c1 (.clk(clk), .rst(rst), .en(en), .miso(miso), .wdata(wdata),
            .wr_tx(wr_tx), .wr_ctl(wr_ctl), .wr_baud(wr_baud), .wr_en(wr_en), .wr_out(wr_out),
            .rxdata(rx1), .txdata(tx1), .txe(txe1), .txr(txr1), .control(ct1), .baud_o(bd1),
            .p_mosi(mo1), .p_sck(sc1), .st(st1), .sr(sr1), .bb(bb1), .bba(bba1), .cc(cc1), .bc(bc1),
            .cpol(cpol1), .cpha(cpha1), .baud(ba1));
    spi c2 (.clk(clk), .rst(rst), .en(en), .miso(miso), .wdata(wdata),
            .wr_tx(wr_tx), .wr_ctl(wr_ctl), .wr_baud(wr_baud), .wr_en(wr_en), .wr_out(wr_out),
            .rxdata(rx2), .txdata(tx2), .txe(txe2), .txr(txr2), .control(ct2), .baud_o(bd2),
            .p_mosi(mo2), .p_sck(sc2), .st(st2), .sr(sr2), .bb(bb2), .bba(bba2), .cc(cc2), .bc(bc2),
            .cpol(cpol2), .cpha(cpha2), .baud(ba2));

    reg armed = 1'b0;
    always @(posedge clk) if (rst) armed <= 1'b1;

    always @(*) begin
        if (armed) begin
            assert (st1 == st2 && sr1 == sr2 && bb1 == bb2 && bba1 == bba2 &&
                    cpol1 == cpol2 && cpha1 == cpha2 && ba1 == ba2);        // invariant
            if (st1 != 2'd0) assert (cc1 == cc2 && bc1 == bc2);             // invariant
            assert (mo1 == mo2 && sc1 == sc2 && txe1 == txe2 && txr1 == txr2 &&
                    rx1 == rx2 && tx1 == tx2 && ct1 == ct2 && bd1 == bd2);   // D1
        end
    end

`ifdef SBY_COVER
    // antecedents of the implication asserts above: an unreached one makes its assert vacuous
    always @(*) begin
        cover (armed && st1 != 2'd0); cover (armed && st1 == 2'd2 && cc1 == 8'd0);
    end
`endif
endmodule
