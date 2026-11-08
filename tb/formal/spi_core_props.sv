// SPI engine invariants (src/spi.v), proved by k-induction at length 1
// (WO-29 section 7). SPI-006..SPI-012, SPI-015, SPI-017 at the engine.
//
// White-box names, exposed from the committed RTL by run.sh (PRE) and mapped
// from WO-28 2.1 (no other reading of the RTL's behaviour was used):
//   WO-28 name   spi.v name      meaning
//   st           st              IDLE=0 A=1 B=2
//   cc           cc              clocks left in the half period
//   bc           bc              bits left in the byte (7 at a LOAD)
//   bba          bba             holding register full
//   sr, bb       sr, bb          shift register / holding register
//   p_sck,p_mosi p_sck,p_mosi    the pin flops (ports of spi)
//   cpol,cpha,baud               CONTROL / BAUD
//
// All inputs are free except the contract A-G with gpio (assumed here, each
// one asserted back as G1..G6 in spi_bus_props.sv):
//   AC1 at most one register strobe per cycle
//   AC2 wr_tx only when bba = 0
//   AC3 wr_ctl, wr_baud, wr_en, wr_out only when TXE (idle and bba = 0)
//   AC4 en changes only when TXE in the cycle before, or on a reset
//   AC5 en rises only on the edge of a wr_en strobe (and not on a reset)
//   AC6 a wr_en strobe (not on a reset) leaves en = 1
// `armed` is set by the first rst; every state invariant is gated on it, and
// the shadow registers (all reset by rst) make the post-reset state checked
// at the first step.
//   C1  st is IDLE, A or B
//   C2  busy -> cc <= baud
//   C3  en: SCK is A in A, ~A in B, cpol in IDLE (A = cpol ^ cpha)
//   C4  ph + cc = baud while busy; every exit from A or B is at ph = baud
//   C5  nab (A->B edges since the LOAD) = 7 - bc in A, 8 - bc in B; 8 at the end
//   C6  IDLE is entered only from B with cc = 0, bc = 0
//   C7  en: MOSI changes only on a launch (entry into A)
//   C8  sr[7-bc+i] = txs[i] (i <= bc); en: MOSI = sr[7] = txs[bc] while busy
//   C9  accounting: d = writes - LOADs = bba; a LOAD takes the last written byte
//   C10 IDLE with bba loads on the next edge
//   C11 B, cc = 0, bc = 0, bba loads on that edge (no gap)
//   C12 rxs: low 7-bc bits of sr; bb / sr get the completed RX byte
//   C13 an IDLE LOAD writes the old sr into bb
//   C14 since = clocks since the LOAD, closed form; the byte ends at 16(B+1)
//   C15 reset values
//   C16 en = 0, or en = 1 with an OUT strobe: the strobe moves no pin
//   C17 SCK moves only at the listed events
//   C18 not TXE -> baud, cpol, cpha stable
module spi_core_props (
    input  wire       clk, rst,
    input  wire       en, miso,
    input  wire [7:0] wdata,
    input  wire       wr_tx, wr_ctl, wr_baud, wr_en, wr_out
);
    wire [7:0] rxdata, txdata, baud_o;
    wire       txe, txr, p_mosi, p_sck;
    wire [1:0] control;
    wire [1:0] st;
    wire [7:0] sr, bb, cc, baud;
    wire [2:0] bc;
    wire       bba, cpol, cpha;

    spi dut (.clk(clk), .rst(rst), .en(en), .miso(miso), .wdata(wdata),
             .wr_tx(wr_tx), .wr_ctl(wr_ctl), .wr_baud(wr_baud), .wr_en(wr_en), .wr_out(wr_out),
             .rxdata(rxdata), .txdata(txdata), .txe(txe), .txr(txr), .control(control),
             .baud_o(baud_o), .p_mosi(p_mosi), .p_sck(p_sck),
             .st(st), .sr(sr), .bb(bb), .bba(bba), .cc(cc), .bc(bc),
             .cpol(cpol), .cpha(cpha), .baud(baud));

    localparam [1:0] IDLE = 2'd0, A = 2'd1, B = 2'd2;
    wire a_lvl = cpol ^ cpha;

    // ---- previous-cycle copies and shadows (all reset by rst)
    reg armed = 1'b0;
    reg armed_q = 1'b0, rst_q = 1'b0, en_q = 1'b0, miso_q = 1'b0;
    reg wr_tx_q = 1'b0, wr_ctl_q = 1'b0, wr_baud_q = 1'b0, wr_en_q = 1'b0, wr_out_q = 1'b0;
    reg [1:0] st_q = 0;  reg [7:0] sr_q = 0, bb_q = 0, cc_q = 0, baud_q = 0;
    reg [2:0] bc_q = 0;  reg bba_q = 0, cpol_q = 0, cpha_q = 0, p_mosi_q = 0, p_sck_q = 0, txe_q = 0;
    reg [7:0] txs = 0, rxs = 0, hb = 0, ph = 0;
    reg [7:0] txs_q = 0, hb_q = 0, ph_q = 0, rxs_q = 0;  reg [3:0] nab_q = 0;
    reg [3:0] nab = 0;
    reg [15:0] since = 0;
    reg [1:0] d = 0;

    wire load_now = (st == IDLE && bba) || (st == B && cc == 8'd0 && bc == 3'd0 && bba);
    wire busy     = (st == A) || (st == B);

    always @(posedge clk) begin
        armed_q <= armed; rst_q <= rst; en_q <= en; miso_q <= miso;
        wr_tx_q <= wr_tx; wr_ctl_q <= wr_ctl; wr_baud_q <= wr_baud; wr_en_q <= wr_en; wr_out_q <= wr_out;
        txs_q <= txs; hb_q <= hb; ph_q <= ph; rxs_q <= rxs; nab_q <= nab;
        st_q <= st; sr_q <= sr; bb_q <= bb; cc_q <= cc; baud_q <= baud; bc_q <= bc; bba_q <= bba;
        cpol_q <= cpol; cpha_q <= cpha; p_mosi_q <= p_mosi; p_sck_q <= p_sck; txe_q <= txe;
        if (rst) begin
            armed <= 1'b1;
            txs <= 0; rxs <= 0; hb <= 0; ph <= 0; nab <= 0; since <= 0; d <= 0;
        end else begin
            if (wr_tx) hb <= wdata;
            d <= d + {1'b0, wr_tx} - {1'b0, load_now};
            if (load_now) begin
                txs <= bb; rxs <= 0; ph <= 0; nab <= 0; since <= 0;
            end else begin
                if (st == B && cc == 8'd0) rxs <= {rxs[6:0], miso};
                ph    <= (cc == 8'd0) ? 8'd0 : ph + 8'd1;
                since <= since + 16'd1;
                if (st == A && cc == 8'd0) nab <= nab + 4'd1;
            end
        end
    end

    // ---- the contract with gpio (assumed here, proved in spi_bus)
    wire [4:0] strobes = {wr_tx, wr_ctl, wr_baud, wr_en, wr_out};
    always @(*) begin
        assume ((strobes & (strobes - 5'd1)) == 5'd0);                       // AC1
        assume (!(wr_tx && bba));                                           // AC2
        assume (!((wr_ctl || wr_baud || wr_en || wr_out) && !txe));         // AC3
        assume (!(en != en_q && !txe_q && !rst_q));                         // AC4
        assume (!(en && !en_q && (rst_q || !wr_en_q)));                     // AC5
        assume (!(wr_en_q && !rst_q && !en));                               // AC6
    end

    // ---- closed forms
    wire [15:0] b1    = {8'b0, baud} + 16'd1;
    wire [2:0]  k     = 3'd7 - bc;
    wire [15:0] kmul  = (k[0] ? (b1 << 1) : 16'd0) + (k[1] ? (b1 << 2) : 16'd0) + (k[2] ? (b1 << 3) : 16'd0);
    wire [15:0] exp_since = kmul + {8'b0, baud} - {8'b0, cc} + ((st == B) ? b1 : 16'd0);
    wire [7:0]  kmask = (8'd1 << k) - 8'd1;                                  // low 7-bc bits
    wire [8:0]  tmask = (9'd1 << ({1'b0, bc} + 4'd1)) - 9'd1;                 // low bc+1 bits
    wire [3:0]  nab_exp = (st == A) ? {1'b0, k} : ({1'b0, k} + 4'd1);

    wire load_q   = (st_q == IDLE && bba_q) || (st_q == B && cc_q == 8'd0 && bc_q == 3'd0 && bba_q);
    wire [7:0] rxfull_q = {rxs_q[6:0], miso_q};
    wire a_lvl_q = cpol_q ^ cpha_q;
    wire t_ok = armed_q && !rst_q;                     // a transition from a state that held the invariants

    always @(*) begin
        // ---- state invariants
        if (armed) begin
            assert (st != 2'd3);                                                                // C1
            if (busy) assert (cc <= baud);                                                      // C2
            if (en && st == A)    assert (p_sck == a_lvl);                                      // C3
            if (en && st == B)    assert (p_sck == !a_lvl);                                     // C3
            if (en && st == IDLE) assert (p_sck == cpol);                                       // C3
            if (busy) assert ({1'b0, ph} + {1'b0, cc} == {1'b0, baud});                         // C4
            if (busy) assert (nab == nab_exp);                                                  // C5
            if (busy) assert (((sr >> k) & tmask) == (txs & tmask));                            // C8
            if (busy && en) assert (p_mosi == sr[7]);                                           // C8
            if (busy) assert (((sr ^ rxs) & kmask) == 8'd0);                                    // C12
            if (busy) assert (since == exp_since);                                              // C14
            assert (d == {1'b0, bba});                                                          // C9
            assert (txe == (st == IDLE && !bba) && txr == !bba);                                  // C9 (status flags)
            if (bba) assert (bb == hb);                                                         // C9
        end
        // ---- C15
        if (rst_q) begin
            assert (st == IDLE && !bba && p_sck && !p_mosi && baud == 8'hFF && cpol && cpha);
            assert (sr == 8'd0 && bb == 8'd0);
        end
        // ---- transitions
        if (t_ok) begin
            if (load_q) begin                                                                    // C10 C11 C9
                assert (st == A && bc == 3'd7 && cc == baud_q && !bba && sr == bb_q);
                assert (bb_q == hb_q);
            end
            if (st_q == IDLE && bba_q) assert (bb == sr_q);                                      // C13
            if (st_q == B && cc_q == 8'd0 && bc_q == 3'd0 && bba_q) assert (bb == rxfull_q);     // C12
            if (st_q == B && cc_q == 8'd0 && bc_q == 3'd0 && !bba_q) begin                       // C6 C12
                assert (st == IDLE && sr == rxfull_q);
            end
            if (st_q != IDLE && st == IDLE) assert (st_q == B && cc_q == 8'd0 && bc_q == 3'd0);  // C6
            if ((st_q == A || st_q == B) && st != st_q) assert ({1'b0, ph_q} == baud_q);         // C4
            if ((st_q == A || st_q == B) && st == st_q) assert (cc_q != 8'd0 && cc == cc_q - 8'd1);
            if (st_q == B && cc_q == 8'd0 && bc_q != 3'd0) assert (st == A && bc == bc_q - 3'd1 && cc == baud_q); // bit step
            if (st_q == A && cc_q == 8'd0) assert (st == B && bc == bc_q && cc == baud_q);
            if (st_q == B && cc_q == 8'd0 && bc_q == 3'd0) assert (nab_q == 4'd8);       // C5
            // C7
            if (en_q && p_mosi != p_mosi_q) assert (st == A && st_q != A);
            // C8 at the A->B edge
            if (en_q && st_q == A && cc_q == 8'd0) assert (p_mosi_q == txs_q[bc_q]);
            // C16
            if (!en_q && !wr_out_q && !wr_en_q) assert (p_mosi == p_mosi_q && p_sck == p_sck_q);
            if (en_q && wr_out_q) assert (p_mosi == p_mosi_q && p_sck == p_sck_q);
            // C17
            if (p_sck != p_sck_q)
                assert ((en_q && st != st_q) || (wr_ctl_q && en_q) || wr_en_q || (wr_out_q && !en_q));
            // C18
            if (!txe_q) assert (baud == baud_q && cpol == cpol_q && cpha == cpha_q);
        end
    end

`ifdef SBY_COVER
    // antecedents of the implication asserts above: an unreached one makes its assert vacuous
    always @(*) begin
        cover (t_ok); cover (armed && load_now); cover (armed && st == A); cover (armed && st == B);
        cover (armed && st == B && cc == 8'd0 && bc == 3'd0 && bba);
        cover (armed && wr_tx); cover (armed && wr_ctl); cover (armed && wr_baud); cover (armed && wr_en); cover (armed && wr_out);
    end
`endif
endmodule
