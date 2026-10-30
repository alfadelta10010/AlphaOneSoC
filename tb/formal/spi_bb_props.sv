// Black-box bounded check of the SPI controller (WO-29 7.2 spi_bb): gpio's
// ports only, no exposed names, against a reference model written here from
// WO-28 sections 1.2 and 2 as a timeline. It shares no name with the RTL. It
// is the cross-check that the white-box proofs describe the right thing.
//   E1  SCK on out[3]: A level for B+1 clocks, then ~A for B+1, per bit; CPOL idle
//   E2  MOSI on out[1]: the byte, MSB first, changing only at a launch
//   E3  bit k is the in[1] value of the clock before the last clock of its B
//       phase (launch + 2B clocks); RXDATA at TXE and TXDATA after a load
//   E4  TXE rises exactly 16(B+1) clocks after the first launch, and the
//       first launch is the clock after the write is accepted
//   E5  every write other than TXDATA waits for TXE, then lands
// The model counts clocks of the byte with (phase, hp, bitk) instead of one
// counter t, to avoid a divide by B+1: launch k = clock 2k(B+1), A->B edge
// B+1 clocks later, sample at clock 2k(B+1)+2B.
// The one assumption: a BAUD write carries wdata[7:0] = 0 (BAUD 0), so a
// byte is 16 clocks and depth 24 reaches a whole byte (BAUD <= 1 at depth 40 gave no verdict in 1800 s). Checks start
// at the first reset (armed).
module spi_bb_props (
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
    gpio dut (.clk(clk), .rst(rst), .sel(sel), .we(we), .be(be), .addr(addr), .wdata(wdata),
              .rdata(rdata), .ready(ready), .in(in), .out(out));

    reg armed = 1'b0;
    // ---- the model
    reg [7:0] o_s;                      // OUT bits 0,2,6,7
    reg       en_s, cpol_s, cpha_s;
    reg [7:0] baud_s;
    reg [7:0] bb_s, txd_s, rxsh_s, rxlast_s;
    reg       bba_s, busy_s, phase_s;   // phase_s 0 = A, 1 = B
    reg [7:0] hp_s;                     // clocks into the current phase
    reg [2:0] bitk_s;
    reg       sck_s, mosi_s;            // the pin values while the engine is not driving them

    wire       a_lvl = cpol_s ^ cpha_s;
    wire       last  = busy_s && phase_s && hp_s == baud_s && bitk_s == 3'd7;
    wire       txe_s = !busy_s && !bba_s;
    wire       txr_s = !bba_s;
    wire       req   = sel && we && be[0];
    wire       ready_s = !(req && (addr == 4'd9 ? bba_s : !txe_s));
    wire       acc   = req && ready;
    wire       sample = busy_s && ((baud_s == 8'd0) ? !phase_s : (phase_s && hp_s + 8'd1 == baud_s));
    wire       drive = en_s && busy_s;
    wire       exp_sck  = drive ? (phase_s ? !a_lvl : a_lvl) : sck_s;
    wire       exp_mosi = drive ? txd_s[7 - bitk_s] : mosi_s;
    wire       ld_idle = !busy_s && bba_s;
    wire       ld_b2b  = last && bba_s;

    always @(posedge clk) begin
        if (rst) begin
            armed <= 1'b1;
            o_s <= 8'h81; en_s <= 0; cpol_s <= 1; cpha_s <= 1; baud_s <= 8'hFF;
            bb_s <= 0; txd_s <= 0; rxsh_s <= 0; rxlast_s <= 0;
            bba_s <= 0; busy_s <= 0; phase_s <= 0; hp_s <= 0; bitk_s <= 0; sck_s <= 1; mosi_s <= 0;
        end else begin
            // engine
            if (busy_s) begin
                if (sample) rxsh_s <= {rxsh_s[6:0], in[1]};
                if (en_s) begin sck_s <= last ? cpol_s : exp_sck; mosi_s <= exp_mosi; end
                if (hp_s != baud_s) hp_s <= hp_s + 8'd1;
                else begin
                    hp_s <= 0;
                    if (!phase_s) phase_s <= 1;
                    else begin
                        phase_s <= 0;
                        if (bitk_s != 3'd7) bitk_s <= bitk_s + 3'd1;
                        else begin
                            bitk_s <= 0;
                            if (bba_s) begin txd_s <= bb_s; bba_s <= 0; bb_s <= rxsh_s; end
                            else begin busy_s <= 0; rxlast_s <= rxsh_s; end
                        end
                    end
                end
            end else if (bba_s) begin
                busy_s <= 1; phase_s <= 0; hp_s <= 0; bitk_s <= 0;
                txd_s <= bb_s; bba_s <= 0; bb_s <= rxlast_s;
            end
            // bus writes
            if (acc) begin
                case (addr)
                4'd0:  begin
                           o_s <= {wdata[7:6], 3'b000, wdata[2], 1'b0, wdata[0]};
                           if (!en_s) begin sck_s <= wdata[3]; mosi_s <= wdata[1]; end
                       end
                4'd3:  begin en_s <= wdata[0]; if (wdata[0]) sck_s <= cpol_s; end
                4'd9:  begin bb_s <= wdata[7:0]; bba_s <= 1; end
                4'd11: begin cpol_s <= wdata[1]; cpha_s <= wdata[0]; if (en_s) sck_s <= wdata[1]; end
                4'd12: baud_s <= wdata[7:0];
                default: ;
                endcase
            end
        end
    end

    always @(*) begin
        assume (!(acc && addr == 4'd12 && wdata[7:0] != 8'd0));
        if (armed) begin
            assert (ready == ready_s);                                              // E5 (stall rule on the timeline)
            assert (out[5:4] == 2'b00);
            assert (out[0] == o_s[0] && out[2] == o_s[2] && out[6] == o_s[6] && out[7] == o_s[7]);
            assert (out[3] == exp_sck);                                             // E1
            assert (out[1] == exp_mosi);                                            // E2
            if (addr == 4'd3)  assert (rdata == {23'b0, !txe_s, 7'b0, en_s});
            if (addr == 4'd8 && txe_s) assert (rdata == {24'b0, rxlast_s});         // E3 (RXDATA at TXE)
            if (addr == 4'd9)  assert (rdata == {24'b0, bb_s});                     // E3 (TXDATA after a load)
            if (addr == 4'd10) assert (rdata == {30'b0, txr_s, txe_s});             // E4
            if (addr == 4'd11) assert (rdata == {30'b0, cpol_s, cpha_s});
            if (addr == 4'd12) assert (rdata == {24'b0, baud_s});
            if (addr == 4'd0)  assert (rdata == {24'b0, out});
            if (addr == 4'd2 || (addr >= 4'd4 && addr <= 4'd7) || addr >= 4'd13) assert (rdata == 32'h0);
        end
    end
endmodule
