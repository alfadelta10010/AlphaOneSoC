// AlphaOneSoC top level: FyraCore, the bus fabric, the memory controller and
// QSPI engine for the TinyTapeout QSPI Pmod, and the CLINT.
//
// Address map (docs/soc-architecture.md):
//
//   0x2000_0000  flash   16 MB  read, execute        QSPI CS0
//   0x8000_0000  PSRAM   16 MB  read, write, execute QSPI CS1 (A) / CS2 (B)
//   0x0200_0000  CLINT   64 KB
//   0x1000_0000  UART / 0x1001_0000 GPIO / 0x1002_0000 syscon   (reserved)
//
// qspi_rd_late is a strap for the QSPI read-sampling point: 0 samples two
// clocks after the device's launching edge, 1 three (see qspi_ctrl.v). Pick
// it from the clock frequency and the measured pad round trip.
//
// Boot: there is no boot ROM. boot_sel picks the reset PC -- 0 boots from
// flash at 0x2000_0000, 1 from PSRAM at 0x8000_0000 -- and while rst is high
// every QSPI pin is released, so an external master can program the flash or
// load the PSRAM first. Whatever it wrote is the first thing the core runs.
//
// The PMA_* parameters default to the map above. They are exposed only so
// the verification testbench can size the CLINT window to Spike's and switch
// off the IO window Spike has no device behind.

module alphaone_soc #(
    parameter [31:0] MARCHID      = 32'h0000_0000,
    parameter [31:0] PMA_IO0_BASE = 32'h0200_0000,
    parameter [31:0] PMA_IO0_TOP  = 32'h0200_FFFF,
    parameter [31:0] PMA_IO1_BASE = 32'h1000_0000,
    parameter [31:0] PMA_IO1_TOP  = 32'h1002_FFFF
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       boot_sel,      // 0 = flash, 1 = PSRAM
    input  wire       qspi_rd_late,  // strap: sample QSPI read data a clock later
    // QSPI Pmod
    output wire       qspi_sck,
    output wire [2:0] qspi_cs_n,     // CS0 flash, CS1 PSRAM A, CS2 PSRAM B
    output wire       qspi_ctl_oe,   // output enable for SCK and the chip selects
    output wire [3:0] qspi_io_out,
    output wire       qspi_io_oe,
    input  wire [3:0] qspi_io_in
);

    // ── Core ────────────────────────────────────────────────────────────────
    wire [31:0] imem_addr, imem_rdata;
    wire        imem_req, imem_ready;
    wire [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    wire [3:0]  dmem_be;
    wire        dmem_req, dmem_we, dmem_ready;
    wire        timer_irq, sw_irq;
    wire [63:0] mtime;

    fyracore #(
        .MARCHID     (MARCHID),
        .PMA_IO0_BASE(PMA_IO0_BASE),
        .PMA_IO0_TOP (PMA_IO0_TOP),
        .PMA_IO1_BASE(PMA_IO1_BASE),
        .PMA_IO1_TOP (PMA_IO1_TOP)
    ) cpu (
        .clk         (clk),
        .rst         (rst),
        .boot_addr   (boot_sel ? 32'h8000_0000 : 32'h2000_0000),
        .imem_addr   (imem_addr),
        .imem_req    (imem_req),
        .imem_rdata  (imem_rdata),
        .imem_ready  (imem_ready),
        .dmem_req    (dmem_req),
        .dmem_addr   (dmem_addr),
        .dmem_wdata  (dmem_wdata),
        .dmem_be     (dmem_be),
        .dmem_we     (dmem_we),
        .dmem_rdata  (dmem_rdata),
        .dmem_ready  (dmem_ready),
        .timer_irq   (timer_irq),
        .external_irq(1'b0),           // no PLIC
        .sw_irq      (sw_irq),
        .mtime_in    (mtime),
        .fencei_flush(),               // nothing caches instructions
        .dbg_pc      (),
        .dbg_retired (),
        .dbg_instr   (),
        .dbg_compressed(),
        .dbg_trap    ()
    );

    // ── Bus fabric ──────────────────────────────────────────────────────────
    wire        mem_d_req, mem_d_ready;
    wire [31:0] mem_d_rdata;
    wire        clint_sel;
    wire [31:0] clint_rdata;

    soc_bus bus (
        .d_req       (dmem_req),
        .d_addr      (dmem_addr),
        .d_rdata     (dmem_rdata),
        .d_ready     (dmem_ready),
        .mem_req     (mem_d_req),
        .mem_rdata   (mem_d_rdata),
        .mem_ready   (mem_d_ready),
        .clint_sel   (clint_sel),
        .clint_rdata (clint_rdata),
        .uart_sel    (),
        .uart_rdata  (32'h0000_0000),
        .gpio_sel    (),
        .gpio_rdata  (32'h0000_0000),
        .syscon_sel  (),
        .syscon_rdata(32'h0000_0000)
    );

    // ── Memory controller + QSPI engine ─────────────────────────────────────
    wire        q_start, q_we, q_idle, q_done;
    wire [1:0]  q_cs, q_nbytes_m1;
    wire [23:0] q_addr;
    wire [31:0] q_wdata, q_rdata;

    mem_ctrl memc (
        .clk        (clk),
        .rst        (rst),
        .i_req      (imem_req),
        .i_addr     (imem_addr),
        .i_rdata    (imem_rdata),
        .i_ready    (imem_ready),
        .d_req      (mem_d_req),
        .d_addr     (dmem_addr),
        .d_wdata    (dmem_wdata),
        .d_be       (dmem_be),
        .d_we       (dmem_we),
        .d_rdata    (mem_d_rdata),
        .d_ready    (mem_d_ready),
        .q_start    (q_start),
        .q_cs       (q_cs),
        .q_addr     (q_addr),
        .q_we       (q_we),
        .q_nbytes_m1(q_nbytes_m1),
        .q_wdata    (q_wdata),
        .q_idle     (q_idle),
        .q_done     (q_done),
        .q_rdata    (q_rdata)
    );

    qspi_ctrl qspi (
        .clk      (clk),
        .rst      (rst),
        .rd_late  (qspi_rd_late),
        .start    (q_start),
        .cs_sel   (q_cs),
        .addr     (q_addr),
        .we       (q_we),
        .nbytes_m1(q_nbytes_m1),
        .wdata    (q_wdata),
        .idle     (q_idle),
        .done     (q_done),
        .rdata    (q_rdata),
        .sck      (qspi_sck),
        .cs_n     (qspi_cs_n),
        .ctl_oe   (qspi_ctl_oe),
        .io_out   (qspi_io_out),
        .io_oe    (qspi_io_oe),
        .io_in    (qspi_io_in)
    );

    // ── CLINT ───────────────────────────────────────────────────────────────
    clint clint_inst (
        .clk      (clk),
        .rst      (rst),
        .addr     (dmem_addr[15:0]),
        .wdata    (dmem_wdata),
        .wmask    (dmem_be),
        .we       (clint_sel && dmem_we),
        .rdata    (clint_rdata),
        .timer_irq(timer_irq),
        .sw_irq   (sw_irq),
        .mtime_out(mtime)
    );

endmodule
