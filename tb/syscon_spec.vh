// Spec constants for syscon + its watchdog, written from the specification and
// not from src/syscon.v. Used by tb_syscon.v and by the SoC-level syscon
// benches. Sources: docs/ROADMAP.md 1.2 (map, FINISH codes, RESET_CAUSE), the
// user's answers of 2026-10-23 (assumptions A4-A17 in build/wo/WO-14), Linux
// dw_wdt.c / snps,dw-wdt (the watchdog window). Byte offsets inside the 64 KB
// syscon window; plain macros so a harness outside a module can include them.
`ifndef SYSCON_SPEC_VH
`define SYSCON_SPEC_VH

// Register map (SYS-001)
`define SYS_FINISH      16'h0000   // W; reads 0 [ROADMAP 1.2]
`define SYS_CAUSE       16'h0004   // RESET_CAUSE: R, W1C on lane 0 [A6]
`define SYS_BOOTMODE    16'h0008   // BOOT_MODE: R/W lane 0, [7:0] [A7]
`define SYS_CHIPID      16'h000C   // CHIP_ID: R [A8]
`define SYS_STRAPS      16'h0010   // STRAPS: R, [0] = rd_late, [1] = no-stream strap, as latched [A12]
`define SYS_CLKGATE     16'h0014   // reserved, RAZ/WI [A9]
`define SYS_POWER       16'h0018   // reserved, RAZ/WI [A9]
`define SYS_QSPICFG     16'h001C   // QSPI_CFG: R/W lane 0, {27'b0, DDR_CAP, DDR, STREAM}; reset by rst_soc
`define QCFG_CAP_RESET  3'd2                  // DDR_CAP after any reset (DDR-CONTRACT 4 item 3)

// FINISH status codes, wdata[15:0] (SYS-003, sifive_test convention) [A3, A4]
`define FIN_REBOOT      16'h7777
`define FIN_OFF         16'h5555
`define FIN_FAIL        16'h3333

// RESET_CAUSE bits [A6]
`define RC_PIN          32'h1
`define RC_SOFT         32'h2
`define RC_WDT          32'h4
`define BM_MASK         32'hFF                // [A7]
`define CHIP_ID_SPEC    32'h4131_5301         // [A8]
`define REBOOT_EDGES    2                     // [A10]

// Watchdog window, DesignWare layout (SYS-014) [A14]
`define WDT_BASE        16'h0100
`define WDT_CR          16'h0100
`define WDT_TORR        16'h0104
`define WDT_CCVR        16'h0108
`define WDT_CRR         16'h010C
`define WDT_STAT        16'h0110
`define WDT_EOI         16'h0114
`define WDT_COMP1       16'h01F4
`define WDT_COMP1_VAL   32'h40
`define WDT_KEY         8'h76                 // CRR restart key (dw_wdt.c)
`define WDT_TOP_RESET   4'hF
`define WDT_TAP_LSB     14                    // tap bit t = mtime[14 + t] [A17]

// SoC test mailbox words (WO-12): reserved-zero inside syscon's window
`define MB_EVENT        16'h07F0
`define MB_ARG          16'h07F4
`define MB_STATUS       16'h07F8
`define MB_SPARE        16'h07FC

`endif
