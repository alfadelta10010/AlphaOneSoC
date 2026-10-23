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
//   +0x04  RESET_CAUSE  R / W1C (lane 0). [0] PIN, [1] SOFT. 0x1 after a pin
//                       reset; a reboot sets SOFT and keeps PIN.
//   +0x08  BOOT_MODE    R/W (lane 0), [7:0]. 0 after a pin reset, kept
//                       across a reboot: software's note to the next boot.
//   +0x0C  CHIP_ID      R, the CHIP_ID parameter.
//   +0x10  STRAPS       R. [0] = the rd_late strap as latched at the last pin
//                       reset.
//   +0x14  CLK_GATE     reserved: reads 0, writes ignored.
//   +0x18  POWER        reserved: reads 0, writes ignored.
//   +0x1C               reads 0, writes ignored.
//
// The whole 64 KB window is decoded: only +0x00..+0x1C are registers, every
// other word reads 0 and ignores writes, with no alias. That includes the
// SoC test mailbox words at +0x7F0..+0x7FC. syscon never holds ready low.
//
// Reset architecture. Two resets exist inside the SoC. `rst` (the chip's
// reset, rst_n through the wrapper) resets only syscon's sticky state:
// RESET_CAUSE, BOOT_MODE, the strap flop and the hold flops. `rst_soc` =
// rst | rq | off resets every other block. A reboot raises rq for two clock
// edges, as long as the shortest pin reset, so every block restarts exactly
// as it does after rst_n rises; power-off sets `off`, which holds rst_soc
// until rst. rst_soc is a function of rst and flops alone (nothing from the
// bus) and is used only as a synchronous reset. syscon's own bus writes are
// ignored while rst_soc is high, so it never resets itself mid-write.
//
// The strap lives here because qspi_ctrl's `late` flop reloads whenever its
// reset is high: during a reboot it must see the value latched at the pin
// reset, not the live pin. rd_late follows the pin while rst is high (as
// before syscon existed) and the latched value otherwise.
//
// CLK_GATE and POWER are reserved rather than implemented: nothing gates a
// clock yet, and a register with no function is an ABI nobody can define.
// The offsets are kept so the map does not move when they arrive.

`default_nettype none

module syscon #(
    parameter [31:0] CHIP_ID = 32'h4131_5301   // "A1S", revision 0x01
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
    output wire        rd_late         // to qspi_ctrl
);

    reg       rq, rq2, off, strap_q;
    reg [1:0] cause;
    reg [7:0] boot_mode;

    wire       hit     = (addr[15:5] == 11'd0);     // +0x00..+0x1C
    wire [2:0] idx     = addr[4:2];
    wire       wr      = sel & we & hit & ~rst_soc;
    wire       fin     = wr & (idx == 3'd0) & (be[1:0] == 2'b11);
    wire       reboot  = fin & (wdata[15:0] == 16'h7777);
    wire       halt    = fin & ((wdata[15:0] == 16'h5555) | (wdata[15:0] == 16'h3333));
    wire       w_cause = wr & (idx == 3'd1) & be[0];
    wire       w_mode  = wr & (idx == 3'd2) & be[0];

    always @(posedge clk) begin
        if (rst) begin
            rq        <= 1'b0;
            rq2       <= 1'b0;
            off       <= 1'b0;
            cause     <= 2'b01;
            boot_mode <= 8'h00;
            strap_q   <= strap_rd_late;
        end else begin
            rq        <= reboot | (rq & ~rq2);
            rq2       <= rq & ~rq2;
            off       <= off | halt;
            cause[0]  <= cause[0] & ~(w_cause & wdata[0]);
            cause[1]  <= (cause[1] & ~(w_cause & wdata[1])) | reboot;
            if (w_mode) boot_mode <= wdata[7:0];
        end
    end

    assign rst_soc = rst | rq | off;
    assign rd_late = rst ? strap_rd_late : strap_q;

    assign rdata = ~hit         ? 32'h0000_0000
                 : idx == 3'd1  ? {30'b0, cause}
                 : idx == 3'd2  ? {24'b0, boot_mode}
                 : idx == 3'd3  ? CHIP_ID
                 : idx == 3'd4  ? {31'b0, strap_q}
                 :                32'h0000_0000;   // FINISH, +0x14, +0x18, +0x1C

    wire _unused = &{be[3:2], wdata[31:16], 1'b0};

endmodule

`default_nettype wire
