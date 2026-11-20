// WO-47: PLIC (src/plic.v), NSRC = 9, free src and bus inputs. State exposed by run.sh PRE (plic.conf).
//   P1 claim read value is 0 (nothing claimable) or the lowest claimable id (pend&en&prio, threshold ignored)
//   P2 insvc[i] -> !pend[i] (invariant)
//   P3 meip == |elig of the previous cycle
//   P4 complete clears insvc[i] only when en[i]; P5 non-full-word writes change nothing
//   P6 the unmapped words named in the WO read 0; P7 pend rises only from src & !insvc, falls only on a claim
module plic_props (
    input  wire         clk, rst,
    input  wire         sel, we,
    input  wire [3:0]   be,
    input  wire [21:2]  addr,
    input  wire [31:0]  wdata,
    input  wire [9:1]   src
);
    localparam N = 9;
    wire [31:0] rdata; wire meip;
    wire [N:1] pend, en, prio, insvc; wire thr;
    plic dut (.clk(clk), .rst(rst), .sel(sel), .we(we), .be(be), .addr(addr), .wdata(wdata),
                          .rdata(rdata), .src(src), .meip(meip),
                          .pend(pend), .en(en), .prio(prio), .insvc(insvc), .thr(thr));

    reg armed = 1'b0, rst_q = 1'b0, armed_q = 1'b0, sel_q = 0, we_q = 0, thr_q = 0;
    reg [3:0] be_q = 0; reg [21:2] addr_q = 0; reg [31:0] wdata_q = 0; reg [N:1] src_q = 0;
    reg [N:1] pend_q = 0, en_q = 0, prio_q = 0, insvc_q = 0;
    always @(posedge clk) begin
        if (rst) armed <= 1'b1;
        rst_q <= rst; armed_q <= armed; sel_q <= sel; we_q <= we; be_q <= be; addr_q <= addr;
        wdata_q <= wdata; src_q <= src; thr_q <= thr; pend_q <= pend; en_q <= en; prio_q <= prio; insvc_q <= insvc;
    end

    wire step = armed_q && !rst_q;
    wire [N:1] elig   = pend & en & prio & {N{!thr}};
    wire [N:1] elig_q = pend_q & en_q & prio_q & {N{!thr_q}};
    wire [N:1] cand   = pend & en & prio;
    wire [N:1] cand_q = pend_q & en_q & prio_q;
    wire wr_q    = sel_q && we_q && be_q == 4'b1111;
    wire claimr  = sel && !we && addr == 20'h80001;
    wire claimr_q = sel_q && !we_q && addr_q == 20'h80001;
    wire compl_q = wr_q && addr_q == 20'h80001;

    reg [N:1] done_q = 0;
    always @(posedge clk) done_q <= (step && compl_q) ? (insvc_q & ~insvc) : {N{1'b0}};

    // reference lowest eligible id
    reg [4:0] lo, lo_q; integer k;
    always @(*) begin
        lo = 0; lo_q = 0;
        for (k = N; k >= 1; k = k - 1) begin if (cand[k]) lo = k; if (cand_q[k]) lo_q = k; end
    end

    integer j;
    always @(*) begin
        if (armed && claimr) assert (rdata == {27'd0, lo});                                           // P1
        if (armed) assert ((insvc & pend) == 0);                                                      // P2
        if (armed && addr == 20'h00000) assert (rdata == 0);                                          // P6
        if (armed && addr == 20'h00401) assert (rdata == 0);
        if (armed && addr == 20'h00801) assert (rdata == 0);
        if (armed && addr == 20'h00820) assert (rdata == 0);
        if (armed && addr == 20'h80002) assert (rdata == 0);
        if (armed && addr == 20'h80400) assert (rdata == 0);
        if (armed && addr == 20'h00400) assert (rdata == {22'd0, pend, 1'b0});
        if (armed && addr == 20'h00800) assert (rdata == {22'd0, en, 1'b0});
        if (armed && addr == 20'h80000) assert (rdata == {31'd0, thr});
        if (armed_q && rst_q) assert (pend == 0 && en == 0 && prio == 0 && insvc == 0 && !thr && !meip);
        if (step) begin
            assert (meip == (|elig_q));                                                               // P3
            for (j = 1; j <= N; j = j + 1) begin
                if (claimr_q && lo_q == j) assert (!pend[j] && insvc[j]);                             // P7, claim
                else begin
                    assert (pend[j] == (pend_q[j] | (src_q[j] & !insvc_q[j])));
                    if (compl_q && wdata_q == j && en_q[j]) assert (!insvc[j]);                      // P4
                    else assert (insvc[j] == insvc_q[j]);
                end
                if (wr_q && addr_q[21:7] == 0 && addr_q[6:2] == j) assert (prio[j] == (wdata_q != 0));
                else assert (prio[j] == prio_q[j]);
            end
            if (wr_q && addr_q == 20'h00800) assert (en == wdata_q[N:1]); else assert (en == en_q);
            if (wr_q && addr_q == 20'h80000) assert (thr == (wdata_q != 0)); else assert (thr == thr_q);
            if (!wr_q) assert (en == en_q && thr == thr_q && prio == prio_q);                         // P5
        end
    end

`ifdef SBY_COVER
    always @(*) begin
        for (k = 1; k <= N; k = k + 1) cover (step && claimr_q && lo_q == k);                         // claim of each id
        cover (step && compl_q && (insvc_q & ~insvc) != 0);                                           // a completion
        cover (step && (done_q & src_q & pend) != 0);                                                 // re-pend after completion, src held
        cover (step && (pend_q & en_q & prio_q) != 0 && !thr_q && meip);                              // meip high, thr 0
        cover (step && thr_q && claimr_q && lo_q != 0);                                               // claim succeeds with threshold up
        cover (step && (pend_q & en_q & prio_q) != 0 && thr_q && !meip);                              // meip low, thr 1, same pend
    end
`endif
endmodule
