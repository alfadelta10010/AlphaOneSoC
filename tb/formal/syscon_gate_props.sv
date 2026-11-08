// No watchdog fire while the SoC is held (SYS-008, SYS-016, SYS-019; SA-009).
// syscon's `fire` is gated by ~rst_soc: the watchdog's flops clear only on
// the edge after rq or off rises, and it must not fire in the cycle between.
// All inputs are free, wdt_tap included. `armed` is set by the first rst, as
// in the other harnesses; the checks are gated on it. Ports only.
//   P1  a cycle held (rst_soc high, rst low) never sets RESET_CAUSE.WDT on its
//       edge: seen at the port as WDT clear in a held cycle and set in the
//       next, with the same word (RESET_CAUSE) addressed.
//   P2  after any held edge the watchdog is disabled: CR reads EN = 0.
//   P3  after any held edge QSPI_CFG (+0x1C) has DDR = 0 and DDR_CAP = 0:
//       every reset, reboot and watchdog expiry returns to SDR.
module syscon_gate_props (
    input  wire        clk, rst,
    input  wire        sel, we,
    input  wire [3:0]  be,
    input  wire [15:2] addr,
    input  wire [31:0] wdata,
    input  wire        strap_rd_late, strap_no_stream,
    input  wire [15:0] wdt_tap
);
    wire [31:0] rdata;
    wire        rst_soc, rd_late;
    syscon dut (.clk(clk), .rst(rst), .rst_soc(rst_soc), .sel(sel), .we(we), .be(be),
                .addr(addr), .wdata(wdata), .rdata(rdata),
                .strap_rd_late(strap_rd_late), .rd_late(rd_late), .wdt_tap(wdt_tap),
                .strap_no_stream(strap_no_stream));

    reg armed = 1'b0;
    always @(posedge clk) if (rst) armed <= 1'b1;

    reg held_q = 1'b0, hq2 = 1'b0;
    always @(posedge clk) begin
        held_q <= armed && !rst && rst_soc && addr == 14'd1 && !rdata[2];
        hq2    <= armed && !rst && rst_soc;
    end

    always @(*) begin
        assert (!(armed && held_q && !rst && addr == 14'd1 && rdata[2]));   // P1
        assert (!(armed && hq2 && addr == 14'h40 && rdata[0]));             // P2
        assert (!(armed && hq2 && addr == 14'd7 && (rdata[1] || rdata[4:2] != 3'd0)));   // P3
    end

`ifdef SBY_COVER
    // antecedents of the implication asserts above: an unreached one makes its assert vacuous
    always @(*) begin
        cover (armed && held_q && !rst && addr == 14'd1); cover (armed && hq2 && addr == 14'h40);
        cover (armed && hq2 && addr == 14'd7);
    end
`endif
endmodule
