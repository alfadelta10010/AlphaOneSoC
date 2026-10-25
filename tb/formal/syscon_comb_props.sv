// syscon's reset output has no combinational path from the bus (SYS-011).
// Two copies of syscon, `a` and `b`, share clk and rst. Until the free input
// `split` first rises they get identical inputs, so their flops are equal.
// On the cycle `split` first rises, b's bus inputs (sel, we, be, addr, wdata,
// strap_rd_late, wdt_tap) are free and independent of a's; rst_soc must still
// agree. A difference could only come from a combinational path from those
// inputs to rst_soc. (The watchdog's fire feeds rq's D input, never rst_soc
// directly.) Checked by bounded model checking from reset: tb/formal/run.sh.
module syscon_comb_props (
    input  wire        clk, rst,
    input  wire        split,
    input  wire        sel, we,
    input  wire [3:0]  be,
    input  wire [15:2] addr,
    input  wire [31:0] wdata,
    input  wire        strap_rd_late,
    input  wire [15:0] wdt_tap,
    input  wire        b_sel, b_we,
    input  wire [3:0]  b_be,
    input  wire [15:2] b_addr,
    input  wire [31:0] b_wdata,
    input  wire        b_strap_rd_late,
    input  wire [15:0] b_wdt_tap
);
    reg split_q = 1'b0;             // split has been 1 on an earlier cycle
    always @(posedge clk) if (split) split_q <= 1'b1;
    wire diverge = split | split_q;

    wire [31:0] a_rdata, b_rdata;
    wire        a_rst_soc, b_rst_soc, a_rd_late, b_rd_late;

    syscon a (.clk(clk), .rst(rst), .rst_soc(a_rst_soc), .sel(sel), .we(we), .be(be),
              .addr(addr), .wdata(wdata), .rdata(a_rdata),
              .strap_rd_late(strap_rd_late), .rd_late(a_rd_late), .wdt_tap(wdt_tap));
    syscon b (.clk(clk), .rst(rst), .rst_soc(b_rst_soc),
              .sel(diverge ? b_sel : sel), .we(diverge ? b_we : we),
              .be(diverge ? b_be : be), .addr(diverge ? b_addr : addr),
              .wdata(diverge ? b_wdata : wdata), .rdata(b_rdata),
              .strap_rd_late(diverge ? b_strap_rd_late : strap_rd_late),
              .rd_late(b_rd_late), .wdt_tap(diverge ? b_wdt_tap : wdt_tap));

    always @(*) begin
        if (split && !split_q)
            assert (a_rst_soc == b_rst_soc);
    end
endmodule
