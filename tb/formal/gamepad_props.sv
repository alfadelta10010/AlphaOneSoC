// WO-53: gamepad receiver (src/gamepad.v), k-induction at length 1. Every property relates one non-reset
// step to the previous one (state and inputs copied in *_q), so no state invariant is needed. White-box
// ports (sh nb d chg ie latch_p pclk_p) are exposed by run.sh PRE (gamepad.conf).
//   P1 d changes only on a latch rising edge with nb 12 or 24, and takes sh (the last 12 bits shifted);
//      any other count leaves d alone
//   P2 present bit = (field != FFF); an absent pad reads 0 buttons; bits 31:16 (pad 1) and 14:12 read 0
//   P3 chg rises only with a load of a different d (and always then); falls only on a W1C without a load, and a W1C clears it
//   P4 irq == chg & ie
//   P5 nb: a latch edge clears it, a clock edge counts up saturating at 31
//   P6 ie follows a be[0] write to GPSTAT, else holds; reset values
module gamepad_props (
    input  wire        clk, rst,
    input  wire        sel, we, addr2,
    input  wire [3:0]  be,
    input  wire [31:0] wdata,
    input  wire        latch_s, pclk_s, data_s
);
    wire [31:0] rdata;
    wire        irq, chg, ie, latch_p, pclk_p;
    wire [4:0]  nb;
    wire [11:0] sh, d;
    gamepad dut (.clk(clk), .rst(rst), .sel(sel), .we(we), .be(be), .addr2(addr2), .wdata(wdata),
                 .rdata(rdata), .latch_s(latch_s), .pclk_s(pclk_s), .data_s(data_s), .irq(irq),
                 .sh(sh), .nb(nb), .d(d), .chg(chg), .ie(ie), .latch_p(latch_p), .pclk_p(pclk_p));

    reg armed = 1'b0, rst_q = 1'b0, armed_q = 1'b0;
    reg data_q = 0, sel_q = 0, we_q = 0, addr2_q = 0, latch_q = 0, pclk_q = 0, chg_q = 0, ie_q = 0, latch_pq = 0, pclk_pq = 0;
    reg [3:0] be_q = 0; reg [31:0] wdata_q = 0; reg [4:0] nb_q = 0; reg [11:0] sh_q = 0, d_q = 0;
    always @(posedge clk) begin
        if (rst) armed <= 1'b1;
        rst_q <= rst; armed_q <= armed;
        sel_q <= sel; we_q <= we; addr2_q <= addr2; be_q <= be; wdata_q <= wdata;
        data_q <= data_s; latch_q <= latch_s; pclk_q <= pclk_s; chg_q <= chg; ie_q <= ie; nb_q <= nb; sh_q <= sh; d_q <= d;
        latch_pq <= latch_p; pclk_pq <= pclk_p;
    end

    wire step  = armed_q && !rst_q;
    wire lr    = latch_q && !latch_pq;
    wire cr    = pclk_q && !pclk_pq;
    wire ld    = lr && (nb_q == 5'd24 || nb_q == 5'd12);
    wire wst   = sel_q && we_q && be_q[0] && addr2_q;
    wire pr0 = d != 12'hFFF;

    always @(*) begin
        if (armed_q && rst_q) assert (d == 12'hFFF && sh == 12'hFFF && nb == 0 && !chg && !ie);   // P6 reset
        if (armed && !addr2)                                                                            // P2
            assert (rdata == {16'b0, pr0, 3'b0, pr0 ? d : 12'h0});
        if (armed && addr2) assert (rdata == {30'b0, ie, chg});
        if (armed) assert (irq == (chg & ie));                                                           // P4
        if (step) begin
            if (d != d_q) assert (lr && (nb_q == 5'd12 || nb_q == 5'd24));                              // P1
            if (ld) assert (d == sh_q);
            if (!ld) assert (d == d_q);
            if (ld && d != d_q) assert (chg);                                               // P3
            if (chg && !chg_q) assert (d != d_q);
            if (!chg && chg_q) assert (wst && wdata_q[0] && d == d_q);
            if (wst && wdata_q[0] && !(ld && d != d_q)) assert (!chg);                       // W1C
            if (lr) assert (nb == 5'd0);                                                                // P5
            else if (cr) assert (nb == (nb_q == 5'd31 ? 5'd31 : nb_q + 5'd1));
            else assert (nb == nb_q);
            if (cr) assert (sh == {sh_q[10:0], data_q});
            else assert (sh == sh_q);
            if (wst) assert (ie == wdata_q[1]); else assert (ie == ie_q);                               // P6
        end
    end

`ifdef SBY_COVER
    always @(*) begin
        cover (step && ld && nb_q == 5'd24 && d != d_q);   // a 24-bit load that changes d
        cover (step && ld && nb_q == 5'd12 && d != d_q);   // a 12-bit load
        cover (step && lr && !ld);              // an ignored partial frame
        cover (step && !chg && chg_q);          // a W1C
        cover (step && ld && d == d_q);         // an identical frame
    end
`endif
endmodule
