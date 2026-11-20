// WO-49: 16550A UART (src/uart.v). Every transition property relates one non-reset step to the previous one
// (state and inputs copied in *_q); the FIFO invariants (counts, pointers, error count, timeout bound) are
// asserted and proved inductive. White-box signals are exposed by run.sh PRE (uart.conf).
//   P1 ready low exactly while a THR write meets a full TX FIFO     P2 counts <= size, err_n == errors queued,
//   P3 an RBR read pops iff the FIFO is not empty (empty: nothing moves)   pointers == rp + n
//   P4 irq == (IID != 1) and the IID priority RLS > RDA > CTI > THRE, trigger table 1/4/8/14 (1 without FEN)
//   P5 LOOP -> tx and rts_n high next clock   P6 rts_n low <-> RTS & !LOOP & rx_n <= 14 one clock earlier
//   P7 FCR clears (and a FEN change) empty the FIFOs   P8 LSR bits   P9 OE sticky, set by a frame at full
//   P10 the character-timeout counter: restarts, counts ticks, holds at 640   reset values
// -DFREE (broken copies, covers): armed from time 0, the invariants are assumed, not asserted.
module uart_props (
    input  wire        clk, rst,
    input  wire        sel, we, addr2,
    input  wire [3:0]  be,
    input  wire [31:0] wdata,
    input  wire        rx
);
    wire [31:0] rdata;
    wire        ready, tx, rts_n, irq;
    wire [4:0]  rx_n, err_n, mcr;
    wire [2:0]  tx_n;
    wire [3:0]  iid, rx_rp, rx_wp;
    wire [1:0]  rtrig, tx_rp, tx_wp;
    wire [9:0]  cti_cnt;
    wire [15:0] rx_err;
    wire        tx_idle, fen, erbfi, etbei, elsi, oe, dlab, rx_push, rx_end, rx_full, rd_rbr;
    wire        fcr_clr_rx, fcr_clr_tx, tick, h_err, err_ack;
    uart dut (.clk(clk), .rst(rst), .sel(sel), .we(we), .be(be), .addr2(addr2), .wdata(wdata), .rdata(rdata),
              .ready(ready), .rx(rx), .tx(tx), .rts_n(rts_n), .irq(irq),
              .rx_n(rx_n), .err_n(err_n), .tx_n(tx_n), .tx_idle(tx_idle), .iid(iid), .fen(fen), .rtrig(rtrig),
              .mcr(mcr), .erbfi(erbfi), .etbei(etbei), .elsi(elsi), .oe(oe), .cti_cnt(cti_cnt), .rx_err(rx_err),
              .rx_rp(rx_rp), .rx_wp(rx_wp), .tx_rp(tx_rp), .tx_wp(tx_wp), .dlab(dlab), .rx_push(rx_push),
              .rx_end(rx_end), .rx_full(rx_full), .rd_rbr(rd_rbr), .fcr_clr_rx(fcr_clr_rx),
              .fcr_clr_tx(fcr_clr_tx), .tick(tick), .h_err(h_err), .err_ack(err_ack));

`ifdef FREE
    reg armed = 1'b1;
    `define INV(x) assume (x)
`else
    reg armed = 1'b0;
    `define INV(x) assert (x)
`endif
    reg rst_q = 1'b0, armed_q = 1'b0;
    reg sel_q = 0, we_q = 0, addr2_q = 0, ready_q = 0, dlab_q = 0, oe_q = 0, rx_push_q = 0, rx_end_q = 0, rx_full_q = 0, herr_q = 0, errack_q = 0; reg [3:0] iid_q = 0;
    reg rd_rbr_q = 0, clr_rx_q = 0, clr_tx_q = 0, tick_q = 0;
    reg [3:0] be_q = 0, rx_rp_q = 0, rx_wp_q = 0; reg [4:0] rx_n_q = 0, err_n_q = 0, mcr_q = 0; reg [2:0] tx_n_q = 0;
    reg [9:0] cti_q = 0; reg [1:0] tx_rp_q = 0;
    always @(posedge clk) begin
        if (rst) armed <= 1'b1;
        rst_q <= rst; armed_q <= armed; sel_q <= sel; we_q <= we; addr2_q <= addr2; be_q <= be; ready_q <= ready;
        herr_q <= h_err; errack_q <= err_ack; iid_q <= iid;
        dlab_q <= dlab; oe_q <= oe; rx_push_q <= rx_push; rx_end_q <= rx_end; rx_full_q <= rx_full;
        rd_rbr_q <= rd_rbr; clr_rx_q <= fcr_clr_rx; clr_tx_q <= fcr_clr_tx; tick_q <= tick;
        rx_n_q <= rx_n; err_n_q <= err_n; mcr_q <= mcr; tx_n_q <= tx_n; cti_q <= cti_cnt; rx_rp_q <= rx_rp;
        rx_wp_q <= rx_wp; tx_rp_q <= tx_rp;
    end
    wire step = armed_q && !rst_q;

    // errors queued: entries of the window [rx_rp, rx_rp + rx_n) with the error flag
    integer i; reg [4:0] cnt; reg [3:0] dd;
    always @(*) begin
        cnt = 5'd0;
        for (i = 0; i < 16; i = i + 1) begin
            dd = i[3:0] - rx_rp;
            if ({1'b0, dd} < rx_n && rx_err[i]) cnt = cnt + 5'd1;
        end
    end

    // reference IID
    wire [4:0] trig = !fen ? 5'd1 : rtrig == 2'd0 ? 5'd1 : rtrig == 2'd1 ? 5'd4 : rtrig == 2'd2 ? 5'd8 : 5'd14;
    wire [3:0] iid_ref = (elsi && (oe || (h_err && !err_ack))) ? 4'h6 : (erbfi && rx_n >= trig) ? 4'h4 :
                         (erbfi && cti_cnt == 10'd640) ? 4'hC : (etbei && tx_n == 3'd0) ? 4'h2 : 4'h1;
    wire wr_fcr = sel && we && ready && be[2] && !addr2;
    wire lsr_rd_q = sel_q && !we_q && be_q[1] && addr2_q;
    wire restart_q = rx_push_q || rd_rbr_q || clr_rx_q || rx_n_q == 5'd0;
    wire pop_q = rd_rbr_q && rx_n_q != 5'd0;

    always @(*) begin
        if (armed) begin
            `INV(rx_n <= 5'd16);                                                                     // P2
            `INV(tx_n <= 3'd4);
            `INV(err_n == cnt);
            `INV(!err_ack || h_err);                                                                  // ack only over an error head
            `INV(rx_wp == rx_rp + rx_n[3:0]);
            `INV(tx_wp == tx_rp + tx_n[1:0]);
            `INV(cti_cnt <= 10'd640);
            assert (ready == !(sel && we && be[0] && !addr2 && !dlab && tx_n == 3'd4));             // P1
            assert (iid == iid_ref);                                                                  // P4
            assert (irq == (iid != 4'h1));
            if (!addr2) assert (rdata[23:16] == {fen, fen, 2'b00, iid});
            if (!addr2 && rx_n == 5'd0 && !dlab) assert (rdata[7:0] == 8'h00);                        // empty RBR reads 0
            if (addr2) begin                                                                          // P8: LSR = rdata[15:8]
                assert (rdata[8]  == (rx_n != 5'd0));
                assert (rdata[9]  == oe);
                assert (rdata[10] == 1'b0);
                assert (!(rdata[11] && rdata[12]));
                assert ((rdata[11] || rdata[12]) == (h_err && !err_ack));
                assert (rdata[13] == (tx_n == 3'd0));
                assert (rdata[14] == (tx_n == 3'd0 && tx_idle));
                assert (rdata[15] == (fen && err_n != 5'd0));
                assert (rdata[7:0] == {3'b0, mcr});
                assert (rdata[23:16] == (mcr[4] ? {mcr[3], mcr[2], mcr[0], mcr[1], 4'b0} : 8'hB0));
            end
            assert (fcr_clr_rx == (wr_fcr && (wdata[17] || wdata[16] != fen)));                      // P7
            assert (fcr_clr_tx == (wr_fcr && (wdata[18] || wdata[16] != fen)));
        end
        if (armed_q && rst_q) begin                                                                   // reset values
            assert (rx_n == 0 && err_n == 0 && tx_n == 0 && !oe && cti_cnt == 0 && !fen && mcr == 5'b00010);
            assert (tx && rts_n && !irq);
        end
        if (step) begin
            if (rx_push_q) assert (!rx_full_q);                                                       // P9, FIFO kept at full
            if (rx_end_q && rx_full_q) assert (oe);
            if (oe && !oe_q) assert (rx_end_q && rx_full_q);
            if (oe_q && !lsr_rd_q) assert (oe);
            if (lsr_rd_q && ready_q && herr_q && !pop_q && !clr_rx_q) assert (err_ack);               // P8b, an LSR read acks the head
            if (err_ack && !errack_q) assert (lsr_rd_q && ready_q && herr_q);                         // ... and only that sets it
            if (pop_q || clr_rx_q) assert (!err_ack);
            if (!oe && oe_q) assert (lsr_rd_q);
            if (clr_rx_q) assert (rx_n == 0 && err_n == 0 && rx_rp == 0 && rx_wp == 0);               // P7
            else begin
                assert (rx_n == rx_n_q + {4'b0, rx_push_q} - {4'b0, pop_q});                         // P3
                if (rd_rbr_q && rx_n_q == 5'd0) assert (rx_rp == rx_rp_q);
                if (!pop_q) assert (rx_rp == rx_rp_q);
            end
            if (clr_tx_q) assert (tx_n == 0);
            if (mcr_q[4]) assert (tx && rts_n);                                                       // P5
            if (!rts_n) assert (rx_n_q <= 5'd14 && !mcr_q[4] && mcr_q[1]);                            // P6
            if (mcr_q[1] && !mcr_q[4] && rx_n_q <= 5'd14) assert (!rts_n);
            if (restart_q) assert (cti_cnt == 10'd0);                                                 // P10
            else if (cti_q == 10'd640) assert (cti_cnt == 10'd640);
            else assert (cti_cnt == cti_q + {9'b0, tick_q});
            if (cti_q == 10'd639 && tick_q && !restart_q) assert (cti_cnt == 10'd640);
        end
    end

`ifdef SBY_COVER
    always @(*) begin
        cover (armed && rx_n == 5'd16);
        cover (armed && rx_n == 5'd0 && rx_full_q);
        cover (armed && tx_n == 3'd4);
        cover (armed && tx_n == 3'd0 && tx_n_q == 3'd4);
        cover (step && oe && !oe_q);
        cover (armed && cti_cnt == 10'd640 && rx_n != 5'd0);
        cover (armed && iid == 4'h6); cover (armed && iid == 4'h4); cover (armed && iid == 4'hC); cover (armed && iid == 4'h2);
        cover (step && rx_push_q && h_err);
        cover (step && iid_q == 4'h6 && iid != 4'h6 && lsr_rd_q && !rd_rbr_q && !clr_rx_q && !oe && err_ack);  // IID 6 cleared by an LSR read
        cover (step && rx_push_q && pop_q);
    end
`endif
endmodule
