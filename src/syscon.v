// syscon at 0x1002_0000 -- reboot, power-off, reset cause, boot mode, chip ID
// and the read-sampling strap, in one small register block.
//
//   +0x00  FINISH       W; reads 0. The sifive_test convention, so Linux's
//                       generic syscon-reboot / syscon-poweroff drivers and
//                       the benches use the same register. Acts on a store
//                       whose lanes 0 and 1 are both written (sh or sw);
//                       status = wdata[15:0]: 0x7777 reboot, 0x5555 power-off,
//                       0x3333 fail (halts like power-off; wdata[31:16] is
//                       the code, for benches). Any other value does nothing.
//   +0x04  RESET_CAUSE  R / W1C (lane 0). [0] PIN, [1] SOFT, [2] WDT. 0x1
//                       after a pin reset; a reboot sets SOFT and keeps PIN;
//                       a watchdog expiry sets WDT. All are cleared only by
//                       W1C or the pin reset. Rule: software that wants the
//                       last reset's cause alone reads it at boot, then
//                       writes 0x7.
//   +0x08  BOOT_MODE    R/W (lane 0), [7:0]. 0 after a pin reset, kept
//                       across a reboot: software's note to the next boot.
//   +0x0C  CHIP_ID      R, the CHIP_ID parameter.
//   +0x10  STRAPS       R. [0] = the rd_late strap, [1] = the no-stream strap
//                       (ui_in[2], 1 = streaming off at reset), each as latched
//                       at the last pin reset.
//   +0x14  CLK_GATE     reserved: reads 0, writes ignored.
//   +0x18  POWER        reserved: reads 0, writes ignored.
//   +0x1C  QSPI_CFG     R/W (lane 0), reads {27'b0, DDR_CAP, DDR, STREAM}.
//                       [0] STREAM: 1 = streaming flash reads allowed (qspi_ctrl
//                       stream_en). [1] DDR: 1 = DTR flash reads (qspi_ctrl
//                       ddr). [4:2] DDR_CAP: the DDR capture point (qspi_ctrl
//                       ddr_cap). Reset by rst_soc -- every reset,
//                       reboot and watchdog expiry included: STREAM to the
//                       inverse of the no-stream strap, DDR to 0, DDR_CAP to
//                       DDR_CAP_RESET. So any reboot comes back in SDR, which is
//                       the DDR fallback.
//
//   Watchdog, Synopsys DesignWare layout (snps,dw-wdt), +0x100..+0x1FF:
//   +0x100  WDT_CR      R/W (lane 0). [0] EN: a write with bit 0 = 1 sets it;
//                       nothing but a reset clears it. [1] RESP_MODE reads 0.
//   +0x104  WDT_TORR    R/W (lane 0). [3:0] TOP, reads {TOP, TOP} in [7:0];
//                       0xFF (TOP 15) after any reset. A write also kicks.
//   +0x108  WDT_CCVR    reads 0.
//   +0x10C  WDT_CRR     W: 0x76 in lane 0 kicks; any other value is ignored.
//                       Reads 0.
//   +0x110  WDT_STAT    reads 0.
//   +0x114  WDT_EOI     reads 0.
//   +0x1F4  COMP_PARAMS_1  reads 0x40 (USE_FIX_TOP: timeout TOP = 2^(16+TOP)
//                       clocks). The rest of the window reads 0.
//
// The whole 64 KB window is decoded: only +0x00..+0x1C and the watchdog
// window +0x100..+0x1FF are registers, every other word reads 0 and ignores
// writes, with no alias. That includes the SoC test mailbox words at
// +0x7F0..+0x7FC. syscon never holds ready low.
//
// Reset architecture. Two resets exist inside the SoC. `rst` (the chip's
// reset, rst_n through the wrapper) resets only syscon's sticky state:
// RESET_CAUSE, BOOT_MODE, the strap flop and the reboot / power-off flops
// (rq, rq2, off). The watchdog's flops are on `rst_soc`, so a reboot,
// power-off or its own expiry leaves it disabled; its expiry raises `rq` like
// a FINISH 0x7777 and records WDT in RESET_CAUSE. `rst_soc` =
// rst | rq | off resets every other block. A reboot raises rq for two clock
// edges, as long as the shortest pin reset, so every block restarts exactly
// as it does after rst_n rises; power-off sets `off`, which holds rst_soc
// until rst. rst_soc is a function of rst and flops alone (nothing from the
// bus) and is used only as a synchronous reset. syscon's own bus writes are
// ignored while rst_soc is high, so it never resets itself mid-write, and
// `fire` is gated by rst_soc: the watchdog's flops clear only on the edge
// after rq or off rises, and it must not fire in the cycle between.
//
// The strap lives here because qspi_ctrl's `late` flop reloads whenever its
// reset is high: during a reboot it must see the value latched at the pin
// reset, not the live pin. rd_late follows the pin while rst is high (as
// before syscon existed) and the latched value otherwise. The no-stream strap
// is read the same way: QSPI_CFG.STREAM resets to ~(pin while rst is high,
// latched value otherwise), so a reboot does not re-read the pin.
//
// CLK_GATE and POWER are reserved rather than implemented: nothing gates a
// clock yet, and a register with no function is an ABI nobody can define.
// The offsets are kept so the map does not move when they arrive.
//
// Watchdog. The DesignWare layout is used because Linux's upstream dw_wdt
// driver (snps,dw-wdt) runs it unchanged, so there is no kernel code to carry.
// The timebase is wdt_tap = mtime[29:14]: TOP t selects mtime[14+t], whose
// rising edges come every Pt = 2^(15+t) clocks. A 2-bit count, cleared by a
// kick, by a TORR write and while disabled, counts those edges; the third one
// fires. The reset therefore comes after more than 2Pt and at most 3Pt (+1)
// clocks, i.e. more than 1x and at most 1.5x the 2^(16+TOP) timeout: never
// early unless software writes mtime (each 0->1 of the tapped bit is a tick,
// whatever moved it; Linux never writes mtime). A TORR write kicks and makes
// no tick of its own (switching the tapped bit could look like an edge). Once
// enabled it cannot be stopped, as in the DW part. CCVR reads 0.

`default_nettype none

module syscon #(
    parameter [31:0] CHIP_ID = 32'h4131_5301,  // "A1S", revision 0x01
    parameter [2:0]  DDR_CAP_RESET = 3'd2      // QSPI_CFG.DDR_CAP after any reset
)(
    input  wire        clk,
    input  wire        rst,            // the chip's reset (rst_n): sticky state
    output wire        rst_soc,        // reset for every other block
    input  wire        sel,            // soc_bus syscon_sel
    input  wire        we,
    input  wire [3:0]  be,
    input  wire [15:2] addr,
    input  wire [31:0] wdata,
    output wire [31:0] rdata,
    input  wire        strap_rd_late,  // the strap pin (ui_in[0])
    input  wire        strap_no_stream,// the strap pin (ui_in[2]): 1 = streaming off at reset
    output wire        rd_late,        // to qspi_ctrl
    output wire        qspi_stream_en, // QSPI_CFG.STREAM
    output wire        qspi_ddr,       // QSPI_CFG.DDR
    output wire [2:0]  qspi_ddr_cap,   // QSPI_CFG.DDR_CAP
    input  wire [15:0] wdt_tap         // mtime[29:14]
);

    reg       rq, rq2, off, strap_q, strap_ns_q;
    reg       cfg_stream, cfg_ddr;
    reg [2:0] cfg_cap;
    reg [2:0] cause;
    reg       en, tprev;
    reg [3:0] top;
    reg [1:0] cnt;
    reg [7:0] boot_mode;

    wire       hit     = (addr[15:5] == 11'd0);     // +0x00..+0x1C
    wire [2:0] idx     = addr[4:2];
    wire       wr      = sel & we & hit & ~rst_soc;
    wire       fin     = wr & (idx == 3'd0) & (be[1:0] == 2'b11);
    wire       reboot  = fin & (wdata[15:0] == 16'h7777);
    wire       halt    = fin & ((wdata[15:0] == 16'h5555) | (wdata[15:0] == 16'h3333));
    wire       w_cause = wr & (idx == 3'd1) & be[0];
    wire       w_mode  = wr & (idx == 3'd2) & be[0];
    wire       w_cfg   = wr & (idx == 3'd7) & be[0];
    wire       ns_now  = rst ? strap_no_stream : strap_ns_q;

    wire       whit    = (addr[15:8] == 8'h01);     // +0x100..+0x1FF
    wire [5:0] widx    = addr[7:2];
    wire       wwr     = sel & we & whit & ~rst_soc & be[0];
    wire       w_cr    = wwr & (widx == 6'd0);
    wire       w_torr  = wwr & (widx == 6'd1);
    wire       kick    = wwr & (widx == 6'd3) & (wdata[7:0] == 8'h76);
    wire       tap     = wdt_tap[top];
    wire       tick    = tap & ~tprev;
    wire       fire    = en & tick & (cnt == 2'd2) & ~rst_soc;

    always @(posedge clk) begin
        if (rst_soc) begin
            en    <= 1'b0;
            top   <= 4'hF;
            cnt   <= 2'd0;
            tprev <= 1'b0;
        end else begin
            tprev <= w_torr | tap;
            if (w_cr & wdata[0]) en <= 1'b1;
            if (w_torr) top <= wdata[3:0];
            if (~en | kick | w_torr) cnt <= 2'd0;
            else if (tick) cnt <= cnt + 2'd1;
        end
    end

    always @(posedge clk) begin
        if (rst_soc) begin
            cfg_stream <= ~ns_now;
            cfg_ddr    <= 1'b0;
            cfg_cap    <= DDR_CAP_RESET;
        end else if (w_cfg) begin
            cfg_stream <= wdata[0];
            cfg_ddr    <= wdata[1];
            cfg_cap    <= wdata[4:2];
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            rq        <= 1'b0;
            rq2       <= 1'b0;
            off       <= 1'b0;
            cause     <= 3'b001;
            boot_mode <= 8'h00;
            strap_q   <= strap_rd_late;
            strap_ns_q <= strap_no_stream;
        end else begin
            rq        <= reboot | fire | (rq & ~rq2);
            rq2       <= rq & ~rq2;
            off       <= off | halt;
            cause[0]  <= cause[0] & ~(w_cause & wdata[0]);
            cause[1]  <= (cause[1] & ~(w_cause & wdata[1])) | reboot;
            cause[2]  <= (cause[2] & ~(w_cause & wdata[2])) | fire;
            if (w_mode) boot_mode <= wdata[7:0];
        end
    end

    assign rst_soc = rst | rq | off;
    assign rd_late = rst ? strap_rd_late : strap_q;
    assign qspi_stream_en = cfg_stream;
    assign qspi_ddr       = cfg_ddr;
    assign qspi_ddr_cap   = cfg_cap;

    assign rdata = whit         ? (widx == 6'd0  ? {31'b0, en}
                                 : widx == 6'd1  ? {24'b0, top, top}
                                 : widx == 6'd61 ? 32'h0000_0040   // +0x1F4
                                 :                 32'h0000_0000)
                 : ~hit         ? 32'h0000_0000
                 : idx == 3'd1  ? {29'b0, cause}
                 : idx == 3'd2  ? {24'b0, boot_mode}
                 : idx == 3'd3  ? CHIP_ID
                 : idx == 3'd4  ? {30'b0, strap_ns_q, strap_q}
                 : idx == 3'd7  ? {27'b0, cfg_cap, cfg_ddr, cfg_stream}
                 :                32'h0000_0000;   // FINISH, +0x14, +0x18

    wire _unused = &{be[3:2], wdata[31:16], 1'b0};

endmodule

`default_nettype wire
