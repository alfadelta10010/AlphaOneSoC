// PLIC, RISC-V PLIC spec 1.0.0 subset as driven by Linux irq-sifive-plic.c (sifive,plic-1.0.0): one context
// (hart 0, M-mode), NSRC level-triggered sources, 1-bit priorities (0 masks, any non-zero write reads 1),
// 1-bit threshold. Offsets inside the 4 MB window (every other word reads 0, ignores writes, no aliases):
//   0x000004 + 4(i-1) priority i     0x001000 pending (read-only)    0x002000 context 0 enable word 0
//   0x200000 context 0 threshold     0x200004 claim (read) / complete (write the id)
// Only full-word writes (be == 4'b1111) take effect. The claim is a read with sel set; the target never stalls
// (no ready port), so soc_bus's sel is the single cycle the claim happens in. meip is registered (one clock
// of latency, like MTIP) and drops two clocks after a claim. Equal priorities: lowest id wins.
// The threshold gates only meip; a claim ignores it (spec, Interrupt Claim Process).
module plic #(parameter NSRC = 9) (
    input  wire            clk,
    input  wire            rst,
    input  wire            sel,
    input  wire            we,
    input  wire [3:0]      be,
    input  wire [21:2]     addr,
    input  wire [31:0]     wdata,
    output reg  [31:0]     rdata,
    input  wire [NSRC:1]   src,
    output reg             meip
);
    reg [NSRC:1] pend, en, prio, insvc;
    reg          thr;

    wire [NSRC:1] cand = pend & en & prio;               // claimable: the claim ignores the threshold (spec)
    wire [NSRC:1] elig = cand & {NSRC{!thr}};            // notification (meip) only

    // lowest claimable id, else 0
    reg [4:0] cid;
    integer i, j, k;                         // one loop variable per always block (yosys: no shared driver)
    always @(*) begin
        cid = 5'd0;
        for (j = NSRC; j >= 1; j = j - 1) if (cand[j]) cid = j;
    end

    wire rd    = sel & ~we;
    wire wr    = sel & we & (be == 4'b1111);
    wire a_pri = (addr[21:7] == 15'd0) && (addr[6:2] != 5'd0) && (addr[6:2] <= NSRC);
    wire a_pnd = addr == 20'h00400;
    wire a_en  = addr == 20'h00800;
    wire a_thr = addr == 20'h80000;
    wire a_clm = addr == 20'h80001;
    wire claim = rd & a_clm & (cid != 5'd0);
    wire compl = wr & a_clm;

    always @(posedge clk) begin
        if (rst) begin
            pend <= 0; en <= 0; prio <= 0; insvc <= 0; thr <= 1'b0; meip <= 1'b0;
        end else begin
            meip <= |elig;
            for (i = 1; i <= NSRC; i = i + 1) begin
                if (claim && cid == i) begin pend[i] <= 1'b0; insvc[i] <= 1'b1; end
                else begin
                    if (src[i] && !insvc[i]) pend[i] <= 1'b1;
                    if (compl && wdata == i && en[i]) insvc[i] <= 1'b0;
                end
                if (wr && a_pri && addr[6:2] == i) prio[i] <= (wdata != 32'd0);
            end
            if (wr && a_en)  en  <= wdata[NSRC:1];
            if (wr && a_thr) thr <= (wdata != 32'd0);
        end
    end

    always @(*) begin
        rdata = 32'd0;
        k = 0;                               // assigned on every path: no latch on k
        if (a_pri) begin
            for (k = 1; k <= NSRC; k = k + 1) if (addr[6:2] == k) rdata = {31'd0, prio[k]};
        end
        else if (a_pnd) rdata = {{(31-NSRC){1'b0}}, pend, 1'b0};
        else if (a_en)  rdata = {{(31-NSRC){1'b0}}, en, 1'b0};
        else if (a_thr) rdata = {31'd0, thr};
        else if (a_clm) rdata = {27'd0, cid};
    end
endmodule
