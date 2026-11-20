// WO-55: audio (src/audio.v), k-induction at length 1. Every property relates one non-reset step to the
// previous one (state and inputs copied in *_q). White-box ports exposed by run.sh PRE (audio.conf).
//   R   reset values, read-back layout
//   P1  !EN -> audio_o low one clock later; audio_o == EN & (dc < lvl)
//   P2  lvl changes only at dc == FF (or is cleared with EN low); then it takes the mixer level; dc counts
//   P3  PWM frame: with EN on since the frame start, the high clocks of a frame equal lvl. Inductive through a
//       ghost count gh == min(dc, lvl) (a bounded run would need > 260 steps)
//   P4  LFSR never 0, shifts exactly on its tick, held at 1 while EN is low
//   P5  q toggles iff its voice ticks with c == 0; c reloads P / counts down / holds 0 with EN low
//   P6  sum <= 60; pre counts while EN; config registers take byte-lane writes
module audio_props (
    input  wire        clk, rst,
    input  wire        sel, we,
    input  wire [3:0]  be,
    input  wire [4:2]  addr,
    input  wire [31:0] wdata
);
    wire [31:0] rdata;
    wire        audio_o, en, pcm;
    wire [35:0] per, c;
    wire [8:0]  oct;
    wire [11:0] vol;
    wire [2:0]  q, nrate;
    wire [3:0]  nvol;
    wire [7:0]  smp, dc, lvl;
    wire [10:0] pre;
    wire [14:0] l;
    wire [5:0]  sum;
    audio dut (.clk(clk), .rst(rst), .sel(sel), .we(we), .be(be), .addr(addr), .wdata(wdata), .rdata(rdata),
               .audio_o(audio_o), .per(per), .c(c), .oct(oct), .vol(vol), .q(q), .nrate(nrate), .nvol(nvol),
               .en(en), .pcm(pcm), .smp(smp), .dc(dc), .lvl(lvl), .pre(pre), .l(l), .sum(sum));

    reg armed = 1'b0, rst_q = 1'b0, armed_q = 1'b0;
    reg sel_q = 0, we_q = 0, en_q = 0, pcm_q = 0, ao_q = 0;
    reg [3:0] be_q = 0, nvol_q = 0; reg [4:2] addr_q = 0; reg [31:0] wdata_q = 0;
    reg [35:0] per_q = 0, c_q = 0; reg [8:0] oct_q = 0; reg [11:0] vol_q = 0; reg [2:0] q_q = 0, nrate_q = 0;
    reg [7:0] smp_q = 0, dc_q = 0, lvl_q = 0; reg [10:0] pre_q = 0; reg [14:0] l_q = 0; reg [5:0] sum_q = 0;
    reg [8:0] gh = 0; reg gv = 0, gv_q = 0;
    always @(posedge clk) begin
        if (rst) armed <= 1'b1;
        rst_q <= rst; armed_q <= armed; gv_q <= gv;
        sel_q <= sel; we_q <= we; be_q <= be; addr_q <= addr; wdata_q <= wdata;
        en_q <= en; pcm_q <= pcm; ao_q <= audio_o; nvol_q <= nvol; per_q <= per; c_q <= c; oct_q <= oct;
        vol_q <= vol; q_q <= q; nrate_q <= nrate; smp_q <= smp; dc_q <= dc; lvl_q <= lvl; pre_q <= pre;
        l_q <= l; sum_q <= sum;
        // ghost: high clocks of the frame so far (audio_o is the flop of dc_q < lvl_q), valid while EN stayed on
        if (rst) begin gh <= 9'd0; gv <= 1'b0; end
        else begin
            gh <= en ? ((dc == 8'd0 ? 9'd0 : gh) + (dc < lvl ? 9'd1 : 9'd0)) : 9'd0;
            gv <= en && (dc == 8'd0 || gv);
        end
    end

    wire step = armed_q && !rst_q;
    wire w_q  = sel_q && we_q;
    wire b_q  = pre_q[3:0] == 4'hF;
    wire [7:0] level_q = pcm_q ? smp_q : {sum_q, 2'b00};
    wire [6:0] nm_q = (7'd1 << nrate_q) - 7'd1;
    wire nt_q = b_q && ((pre_q[10:4] & nm_q) == nm_q);
    wire [8:0] mn = (dc < lvl) ? {1'b0, dc} : {1'b0, lvl};

    integer i;
    reg [11:0] cq, pq; reg [2:0] oq; reg [6:0] mq; reg tq, wr;
    reg [11:0] pe; reg [2:0] oe; reg [3:0] ve;
    always @(*) begin
        if (armed_q && rst_q) assert (per == 0 && oct == 0 && vol == 0 && c == 0 && q == 0 && nrate == 0 &&
                                      nvol == 0 && !en && !pcm && smp == 0 && pre == 0 && l == 15'd1 &&
                                      dc == 0 && lvl == 0 && !audio_o);                               // R
        if (armed) begin
            case (addr)
                3'd0: assert (rdata == {12'b0, vol[3:0],  1'b0, oct[2:0], per[11:0]});
                3'd1: assert (rdata == {12'b0, vol[7:4],  1'b0, oct[5:3], per[23:12]});
                3'd2: assert (rdata == {12'b0, vol[11:8], 1'b0, oct[8:6], per[35:24]});
                3'd3: assert (rdata == {12'b0, nvol, 13'b0, nrate});
                3'd4: assert (rdata == {30'b0, pcm, en});
                3'd5: assert (rdata == {24'b0, smp});
                default: assert (rdata == 32'b0);
            endcase
            assert (l != 15'd0);                                                                      // P4
            assert (sum <= 6'd60);                                                                    // P6
            if (gv && dc != 8'd0) assert (gh == mn);                                                  // P3 invariant
        end
        if (step) begin
            if (!en_q) assert (!audio_o);                                                             // P1
            assert (audio_o == (en_q && dc_q < lvl_q));
            assert (dc == (en_q ? dc_q + 8'd1 : 8'd0));                                               // P2
            if (!en_q) assert (lvl == 0);
            else if (dc_q == 8'hFF) assert (lvl == level_q);
            else assert (lvl == lvl_q);
            if (gv_q && en_q && dc_q == 8'hFF) assert (gh == {1'b0, lvl_q});                             // P3
            assert (pre == (en_q ? pre_q + 11'd1 : 11'd0));                                           // P6
            assert (l == (!en_q ? 15'd1 : nt_q ? {l_q[0] ^ l_q[1], l_q[14:1]} : l_q));                // P4
            for (i = 0; i < 3; i = i + 1) begin                                                       // P5
                cq = c_q[12*i +: 12]; pq = per_q[12*i +: 12]; oq = oct_q[3*i +: 3];
                mq = (7'd1 << oq) - 7'd1; tq = en_q && b_q && ((pre_q[10:4] & mq) == mq);
                assert (q[i] == (en_q && (q_q[i] ^ (tq && cq == 12'd0))));
                assert (c[12*i +: 12] == (!en_q ? 12'd0 : !tq ? cq : cq == 12'd0 ? pq : cq - 12'd1));
                wr = w_q && addr_q == i;
                pe = pq; oe = oq; ve = vol_q[4*i +: 4];
                if (wr && be_q[0]) pe[7:0] = wdata_q[7:0];
                if (wr && be_q[1]) begin pe[11:8] = wdata_q[11:8]; oe = wdata_q[14:12]; end
                if (wr && be_q[2]) ve = wdata_q[19:16];
                assert (per[12*i +: 12] == pe && oct[3*i +: 3] == oe && vol[4*i +: 4] == ve);
            end
            assert (nrate == ((w_q && addr_q == 3'd3 && be_q[0]) ? wdata_q[2:0] : nrate_q));
            assert (nvol == ((w_q && addr_q == 3'd3 && be_q[2]) ? wdata_q[19:16] : nvol_q));
            assert (en == ((w_q && addr_q == 3'd4 && be_q[0]) ? wdata_q[0] : en_q));
            assert (pcm == ((w_q && addr_q == 3'd4 && be_q[0]) ? wdata_q[1] : pcm_q));
            assert (smp == ((w_q && addr_q == 3'd5 && be_q[0]) ? wdata_q[7:0] : smp_q));
        end
    end

`ifdef SBY_COVER
    always @(*) begin
        cover (step && q[0] != q_q[0]);                                // voice 0 toggles
        cover (step && q[1] != q_q[1]);                                // voice 1 toggles
        cover (step && q[2] != q_q[2]);                                // voice 2 toggles
        cover (step && l != l_q && en_q);                              // noise shifts
        cover (step && en_q && !en && pre_q != 0);                     // EN off mid-count
        cover (step && pcm && smp == 8'hFF && en);                     // PCM full-scale sample, DAC running
        // the 256-clock frame (lvl latch, high clocks, PCM full scale at the pin) is out of cover depth: proved by P2/P3
    end
`endif
endmodule
