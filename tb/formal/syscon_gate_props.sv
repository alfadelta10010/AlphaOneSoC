// No watchdog fire while the SoC is held (SYS-008, SYS-016, SYS-019; SA-009).
// syscon's `fire` is gated by ~rst_soc: the watchdog's flops clear only on
// the edge after rq or off rises, and it must not fire in the cycle between.
// All inputs are free, wdt_tap included. `armed` is set by the first rst, as
// in the other harnesses; the checks are gated on it. Ports only.
//   P1  a cycle held (rst_soc high, rst low) never sets RESET_CAUSE.WDT on its
//       edge: seen at the port as WDT clear in a held cycle and set in the
//       next, with the same word (RESET_CAUSE) addressed.
//   P2  after any held edge the watchdog is disabled and out of interrupt mode: CR reads 0 (EN = 0, RMOD = 0).
//   P4  after any held edge wdt_irq (the one-clock first-expiry pulse) is 0.
//   P5  a STAT read (+0x110) returns exactly the flag `stat`, rebuilt at the ports: the flag is
//       set by the wdt_irq pulse (stat and the pulse rise on the same edge, so the pulse cycle
//       already reads 1) and cleared by a kick (CRR 0x76 on lane 0), a TORR write, an EOI read
//       or a held reset: sh <= (sh | wdt_irq) & ~clear.
//   P6  wdt_irq is a pulse: never high in two consecutive clocks (the first expiry needs stat
//       clear, and stat stays set after it).
//   P3  after any held edge QSPI_CFG (+0x1C) has DDR = 0 and DDR_CAP = DDR_CAP_RESET (the harness parameter, 2 since 6dee0f1;
//       syscon keeps its own default, so a changed reset value is a FAIL here until this follows):
//       every reset, reboot and watchdog expiry returns to SDR.
module syscon_gate_props #(parameter [2:0] DDR_CAP_RESET = 3'd2) (
    input  wire        clk, rst,
    input  wire        sel, we,
    input  wire [3:0]  be,
    input  wire [15:2] addr,
    input  wire [31:0] wdata,
    input  wire        strap_rd_late, strap_no_stream,
    input  wire [15:0] wdt_tap
);
    wire [31:0] rdata;
    wire        rst_soc, rd_late, wdt_irq;
    syscon dut (.clk(clk), .rst(rst), .rst_soc(rst_soc), .sel(sel), .we(we), .be(be),
                .addr(addr), .wdata(wdata), .rdata(rdata),
                .strap_rd_late(strap_rd_late), .rd_late(rd_late), .wdt_tap(wdt_tap),
                .strap_no_stream(strap_no_stream), .wdt_irq(wdt_irq));

    reg armed = 1'b0;
    always @(posedge clk) if (rst) armed <= 1'b1;

    reg held_q = 1'b0, hq2 = 1'b0;
    always @(posedge clk) begin
        held_q <= armed && !rst && rst_soc && addr == 14'd1 && !rdata[2];
        hq2    <= armed && !rst && rst_soc;
    end

    // the STAT flag rebuilt from the pulse and the clearing events seen at the ports
    wire clr_ev = (sel && we && be[0] && addr == 14'h41)                          // TORR write
               || (sel && we && be[0] && addr == 14'h43 && wdata[7:0] == 8'h76)   // CRR kick
               || (sel && !we && addr == 14'h45);                                 // EOI read
    reg  sh = 1'b0, irq_q = 1'b0;
    wire sh_now = sh | wdt_irq;
    always @(posedge clk) begin
        sh    <= !armed || rst_soc ? 1'b0 : (sh_now && !clr_ev);
        irq_q <= wdt_irq;
    end

    always @(*) begin
        assert (!(armed && held_q && !rst && addr == 14'd1 && rdata[2]));   // P1
        assert (!(armed && hq2 && addr == 14'h40 && rdata[1:0] != 2'b00));    // P2
        assert (!(armed && hq2 && wdt_irq));                                // P4
        assert (!(armed && sel && !we && addr == 14'h44 && rdata != {31'b0, sh_now}));   // P5
        assert (!(armed && irq_q && wdt_irq));                              // P6
        assert (!(armed && hq2 && addr == 14'd7 && (rdata[1] || rdata[4:2] != DDR_CAP_RESET)));   // P3
    end

`ifdef SBY_COVER
    // antecedents of the implication asserts above: an unreached one makes its assert vacuous
    always @(*) begin
        cover (armed && held_q && !rst && addr == 14'd1); cover (armed && hq2 && addr == 14'h40);
        cover (armed && hq2 && addr == 14'd7);
        cover (armed && wdt_irq); cover (armed && sel && !we && addr == 14'h44 && rdata[0]);
        cover (armed && sh && !wdt_irq && sel && !we && addr == 14'h44 && rdata[0]);
    end
`endif
endmodule
