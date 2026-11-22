// AlphaOneSoC top level: FyraCore, the bus fabric, the memory controller and
// QSPI engine for the TinyTapeout QSPI Pmod, the CLINT, the UART and the
// GPIO block (with the SPI controller for the OLED and an SD card).
//
// Address map (docs/soc-architecture.md):
//
//   0x2000_0000  flash   16 MB  read, execute        QSPI CS0
//   0x8000_0000  PSRAM   16 MB  read, write, execute QSPI CS1 (A) / CS2 (B)
//   0x0200_0000  CLINT   64 KB
//   0x0C00_0000  PLIC    4 MB, 9 sources (src/plic.v): 1 UART, 2 SPI, 3 gamepad, 4 GPIO input change
//                        (level, gpio.v IN_IE/IN_IP), 5-6 PWM cmp0-1 (7-8 tied 0: cmp2-3 not built), 9 watchdog
//   0x1000_0000  UART    16550 subset, byte registers (src/uart.v)
//   0x1001_0000  GPIO    OUT / IN / SPICTL, SPI controller at +0x20 (src/gpio.v, src/spi.v)
//   0x1002_0000  syscon  reboot, power-off, reset cause, boot mode, chip ID,
//                        straps, watchdog at +0x100 (src/syscon.v); the pinmux
//                        at 0x1002_0020 (src/pinmux.v) is carved out of it
//   0x1003_0000  PWM     SiFive pwm0 layout, comparators 0-1 built (2-3 read 0xFFFF) (src/pwm.v)
//   0x1003_0100  audio   one square tone, TONE0 + CTRL.EN (src/audio.v)
//   0x1002_0024  CACHE_CTL  [0] EN, [1] reads 1, [2] PBURST (PSRAM line fills in one CE# period; needs
//                        QSPI_CFG.STREAM and a core clock >= 15 MHz, tCEM 8 us); carved out of syscon in
//                        soc_bus, the flops are in this file; the cache is 256 B with two data macros (src/cache.v)
//   The GPIO window's +0x10 / +0x14 (every 64-byte alias) is the gamepad receiver
//   (GAMEPAD, GPSTAT, src/gamepad.v); the carves are decoded in soc_bus.
//
// Chip pins (docs/pins-and-peripherals.md): every uo_out pin is one flop of the
// pinmux (`uo`), after the mux of its default function and the features
// software can select (GPIO OUT, RTS#, audio, PWM0-3). Defaults: [0] OLED CS#
// = OUT[0], [1] MOSI = OUT[1], [2] D/C = OUT[2], [3] SCK = OUT[3], [4] UART TX,
// [5] SD CS# = OUT[5], [6] RES#/VCCEN = OUT[6], [7] audio. RX is ui_in[3], the
// gamepad's LATCH / CLOCK / DATA are ui_in[4] / [5] / [6], and gpio_in reads all
// eight ui_in pins, RX and the rd_late strap included. uart_tx, uart_rts_n and
// gpio_out are the pre-mux signals, kept as taps for the benches. The TinyTapeout
// top level (src/tt_um_alfadelta10010_alphaone_soc.v) maps `uo` to the pins.
//
// qspi_rd_late is a strap for the QSPI read-sampling point: 0 samples two
// clocks after the device's launching edge, 1 three (see qspi_ctrl.v). Pick
// it from the clock frequency and the measured pad round trip. syscon latches
// it at the pin reset and hands qspi_ctrl the latched value during a reboot.
// qspi_no_stream is read the same way: 1 resets QSPI_CFG.STREAM to 0 (every
// flash read its own command), 0 to 1 (streaming); software can change it
// afterwards, and any reboot returns to the strap's value, held from the pin reset.
//
// Two resets: `rst` (the chip's reset) resets only syscon's sticky state
// (RESET_CAUSE, BOOT_MODE, the strap, the reboot / power-off flops); syscon's
// rst_soc = rst | reboot | power-off resets every other block. A reboot
// (FINISH 0x7777) holds rst_soc for two clock edges, as the shortest pin reset
// does; power-off (0x5555, or 0x3333 fail) holds it until rst.
//
// Boot: from flash, always -- the reset PC is 0x2000_0000, the first byte of
// flash. There is no boot ROM: whatever was last programmed there is the
// first thing the core runs, and anything that runs from PSRAM is put there by
// code in flash. While rst or a reboot/power-off holds the SoC in reset every
// QSPI pin is released, so an external master (the demo board's RP2040) can
// program the flash first. A reboot restarts the SoC exactly like a pin reset,
// except that RESET_CAUSE, BOOT_MODE and the rd_late strap survive it.
//
// The PMA_* parameters default to the map above. They are exposed only so
// the verification testbench can size the CLINT window to Spike's and switch
// off the IO window Spike has no device behind.

module alphaone_soc #(
    parameter [31:0] MARCHID      = 32'h0000_0000,
    parameter [31:0] PMA_IO0_BASE = 32'h0200_0000,
    parameter [31:0] PMA_IO0_TOP  = 32'h0200_FFFF,
    parameter [31:0] PMA_IO1_BASE = 32'h1000_0000,
    parameter [31:0] PMA_IO1_TOP  = 32'h1003_FFFF,
    parameter [31:0] PMA_IO2_BASE = 32'h0C00_0000,  // PLIC, 4 MB
    parameter [31:0] PMA_IO2_TOP  = 32'h0C3F_FFFF,
    // UART divisor out of reset: 34 = 114,890 baud at the documented 62.5 MHz clock
    parameter [15:0] UART_DIV_RESET = 16'd34
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       qspi_no_stream, // strap: 1 = flash streaming off at reset
    input  wire       qspi_rd_late,  // strap: sample QSPI read data a clock later
    // QSPI Pmod
    output wire       qspi_sck,
    output wire [2:0] qspi_cs_n,     // CS0 flash, CS1 PSRAM A, CS2 PSRAM B
    output wire       qspi_ctl_oe,   // output enable for SCK and the chip selects
    output wire [3:0] qspi_io_out,
    output wire       qspi_io_oe,
    input  wire [3:0] qspi_io_in,
    // UART
    input  wire       uart_rx,
    output wire       uart_tx,
    output wire       uart_rts_n,
    // GPIO (out[1] / out[3] are MOSI / SCK while the SPI controller is on)
    input  wire [7:0] gpio_in,
    output wire [7:0] gpio_out,
    // uart_tx, uart_rts_n and gpio_out above are pre-mux taps; the pins are
    output wire [7:0] uo
);

    // ── Core ────────────────────────────────────────────────────────────────
    wire        rst_soc;                // syscon: reset for every block but itself
    wire [31:0] imem_addr, imem_rdata;
    wire        imem_req, imem_ready;
    wire [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    wire [3:0]  dmem_be;
    wire        dmem_req, dmem_we, dmem_ready;
    wire        timer_irq, sw_irq, meip;
    wire        core_fencei;
    wire [63:0] mtime;

    fyracore #(
        .MARCHID     (MARCHID),
        .PMA_IO0_BASE(PMA_IO0_BASE),
        .PMA_IO0_TOP (PMA_IO0_TOP),
        .PMA_IO1_BASE(PMA_IO1_BASE),
        .PMA_IO1_TOP (PMA_IO1_TOP),
        .PMA_IO2_BASE(PMA_IO2_BASE),
        .PMA_IO2_TOP (PMA_IO2_TOP)
    ) cpu (
        .clk         (clk),
        .rst         (rst_soc),
        .boot_addr   (32'h2000_0000),     // flash
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
        .external_irq(meip),
        .sw_irq      (sw_irq),
        .mtime_in    (mtime),
        .fencei_flush(core_fencei),
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
    wire        uart_sel, uart_ready, gpio_sel, gpio_ready;
    wire [31:0] uart_rdata, gpio_rdata;
    wire        syscon_sel, qspi_late, qspi_stream_en, qspi_ddr;
    wire [2:0]  qspi_ddr_cap;
    wire [31:0] syscon_rdata;

    wire        plic_sel, uart_irq, gpio_spi_irq, gpio_in_irq;
    wire [7:0]  gpio_in_sync;
    wire [31:0] plic_rdata;
    wire        gamepad_sel, pinmux_sel, pwm_sel, audio_sel, gamepad_irq, audio_o;
    wire        cache_sel, cache_active;
    wire [31:0] cache_rdata;
    wire        c_req, c_ready;          // mem_ctrl's fetch port (behind the cache)
    wire [31:0] c_addr, c_rdata;
    reg         cache_en;                // CACHE_CTL.EN, reset 0 by rst_soc
    reg         cache_pburst;            // CACHE_CTL.PBURST, reset 0 by rst_soc
    wire        c_burst, q_burst;        // PSRAM line burst qualifier: cache -> mem_ctrl -> qspi_ctrl
    wire [31:0] gamepad_rdata, pinmux_rdata, pwm_rdata, audio_rdata;
    wire [3:0]  pwm_o, pwm_irq;

    soc_bus bus (
        .clk         (clk),
        .rst         (rst_soc),
        .d_req       (dmem_req),
        .d_addr      (dmem_addr),
        .d_rdata     (dmem_rdata),
        .d_ready     (dmem_ready),
        .mem_req     (mem_d_req),
        .mem_rdata   (mem_d_rdata),
        .mem_ready   (mem_d_ready),
        .clint_sel   (clint_sel),
        .clint_rdata (clint_rdata),
        .plic_sel    (plic_sel),
        .plic_rdata  (plic_rdata),
        .uart_sel    (uart_sel),
        .uart_rdata  (uart_rdata),
        .uart_ready  (uart_ready),
        .gpio_sel    (gpio_sel),
        .gpio_rdata  (gpio_rdata),
        .gpio_ready  (gpio_ready),
        .syscon_sel  (syscon_sel),
        .syscon_rdata(syscon_rdata),
        .gamepad_sel (gamepad_sel),
        .gamepad_rdata(gamepad_rdata),
        .pinmux_sel  (pinmux_sel),
        .pinmux_rdata(pinmux_rdata),
        .pwm_sel     (pwm_sel),
        .pwm_rdata   (pwm_rdata),
        .audio_sel   (audio_sel),
        .audio_rdata (audio_rdata),
        .cache_sel   (cache_sel),
        .cache_rdata (cache_rdata)
    );

    wire        wdt_irq;

    // ── syscon ──────────────────────────────────────────────────────────────
    syscon syscon_inst (
        .clk          (clk),
        .rst          (rst),
        .rst_soc      (rst_soc),
        .sel          (syscon_sel),
        .we           (dmem_we),
        .be           (dmem_be),
        .addr         (dmem_addr[15:2]),
        .wdata        (dmem_wdata),
        .rdata        (syscon_rdata),
        .strap_rd_late(qspi_rd_late),
        .strap_no_stream(qspi_no_stream),
        .rd_late      (qspi_late),
        .qspi_stream_en(qspi_stream_en),
        .qspi_ddr     (qspi_ddr),
        .qspi_ddr_cap (qspi_ddr_cap),
        .wdt_tap      (mtime[29:14]),
        .wdt_irq      (wdt_irq)
    );

    // ── Memory controller + QSPI engine ─────────────────────────────────────
    wire        q_start, q_we, q_idle, q_done;
    wire [1:0]  q_cs, q_nbytes_m1;
    wire [23:0] q_addr;
    wire [31:0] q_wdata, q_rdata;

    // CACHE_CTL (0x1002_0024): [0] EN (rw, reset 0), [1] reads 1 (a cache is built),
    // [2] PBURST (rw, reset 0): PSRAM line fills may use one chip select period per line (needs EN).
    // Writing EN 0 -> 1 starts cold.
    always @(posedge clk) begin
        if (rst_soc) begin
            cache_en     <= 1'b0;
            cache_pburst <= 1'b0;
        end else if (cache_sel && dmem_we && dmem_be[0]) begin
            cache_en     <= dmem_wdata[0];
            cache_pburst <= dmem_wdata[2];
        end
    end
    assign cache_rdata = {29'd0, cache_pburst, 1'b1, cache_en};

    cache icache (
        .clk          (clk),
        .rst          (rst_soc),
        .en           (cache_en),
        .fencei_flush (core_fencei),
        .f_req        (imem_req),
        .f_addr       (imem_addr),
        .f_rdata      (imem_rdata),
        .f_ready      (imem_ready),
        .m_req        (c_req),
        .m_addr       (c_addr),
        .m_burst      (c_burst),
        .pburst       (cache_pburst),
        .m_rdata      (c_rdata),
        .m_ready      (c_ready),
        .d_req        (mem_d_req),
        .d_we         (dmem_we),
        .d_addr       (dmem_addr),
        .d_ready      (mem_d_ready),
        .active       (cache_active)
    );

    mem_ctrl memc (
        .clk        (clk),
        .rst        (rst_soc),
        .i_req      (c_req),
        .i_addr     (c_addr),
        .i_burst    (c_burst),
        .i_rdata    (c_rdata),
        .i_ready    (c_ready),
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
        .q_burst    (q_burst),
        .q_idle     (q_idle),
        .q_done     (q_done),
        .q_rdata    (q_rdata)
    );

    qspi_ctrl qspi (
        .clk      (clk),
        .rst      (rst_soc),
        .rd_late  (qspi_late),
        .stream_en(qspi_stream_en),
        .ddr      (qspi_ddr),
        .ddr_cap  (qspi_ddr_cap),
        .burst    (q_burst),
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
        .rst      (rst_soc),
        .addr     (dmem_addr[15:0]),
        .wdata    (dmem_wdata),
        .wmask    (dmem_be),
        .we       (clint_sel && dmem_we),
        .rdata    (clint_rdata),
        .timer_irq(timer_irq),
        .sw_irq   (sw_irq),
        .mtime_out(mtime)
    );

    // ── PLIC ────────────────────────────────────────────────────────────────
    plic #(.NSRC(9)) plic_inst (
        .clk  (clk),
        .rst  (rst_soc),
        .sel  (plic_sel),
        .we   (dmem_we),
        .be   (dmem_be),
        .addr (dmem_addr[21:2]),
        .wdata(dmem_wdata),
        .rdata(plic_rdata),
        .src  ({wdt_irq,       // 9 watchdog (WO-61)
                pwm_irq,       // 8..5 PWM cmp3..0
                gpio_in_irq,   // 4 GPIO input change (gpio.v IN_IE / IN_IP)
                gamepad_irq,   // 3
                gpio_spi_irq,  // 2
                uart_irq}),    // 1
        .meip (meip)
    );

    // ── UART ────────────────────────────────────────────────────────────────
    uart #(
        .DIV_RESET(UART_DIV_RESET)
    ) uart_inst (
        .clk  (clk),
        .rst  (rst_soc),
        .sel  (uart_sel),
        .we   (dmem_we),
        .be   (dmem_be),
        .addr2(dmem_addr[2]),
        .wdata(dmem_wdata),
        .rdata(uart_rdata),
        .ready(uart_ready),
        .irq  (uart_irq),
        .rx   (uart_rx),
        .tx   (uart_tx),
        .rts_n(uart_rts_n)
    );

    // ── GPIO + SPI controller ──────────────────────────────────────────────
    gpio gpio_inst (
        .clk  (clk),
        .rst  (rst_soc),
        .sel  (gpio_sel),
        .we   (dmem_we),
        .be   (dmem_be),
        .addr (dmem_addr[5:2]),
        .wdata(dmem_wdata),
        .rdata(gpio_rdata),
        .ready(gpio_ready),
        .in   (gpio_in),
        .out  (gpio_out),
        .in_sync(gpio_in_sync),     // for the gamepad receiver
        .spi_irq(gpio_spi_irq),
        .in_irq (gpio_in_irq)
    );

    // ── Gamepad receiver (GPIO slot +0x10 / +0x14) ─────────────────────────
    gamepad gamepad_inst (
        .clk    (clk),
        .rst    (rst_soc),
        .sel    (gamepad_sel),
        .we     (dmem_we),
        .be     (dmem_be),
        .addr2  (dmem_addr[2]),
        .wdata  (dmem_wdata),
        .rdata  (gamepad_rdata),
        .latch_s(gpio_in_sync[4]),
        .pclk_s (gpio_in_sync[5]),
        .data_s (gpio_in_sync[6]),
        .irq    (gamepad_irq)
    );

    // ── PWM (0x1003_0000) and audio (0x1003_0100) ──────────────────────────
    pwm pwm_inst (
        .clk   (clk),
        .rst   (rst_soc),
        .sel   (pwm_sel),
        .we    (dmem_we),
        .be    (dmem_be),
        .addr  (dmem_addr[5:2]),
        .wdata (dmem_wdata),
        .rdata (pwm_rdata),
        .pwm_o (pwm_o),
        .irq   (pwm_irq)
    );

    audio audio_inst (
        .clk    (clk),
        .rst    (rst_soc),
        .sel    (audio_sel),
        .we     (dmem_we),
        .be     (dmem_be),
        .addr   (dmem_addr[4:2]),
        .wdata  (dmem_wdata),
        .rdata  (audio_rdata),
        .audio_o(audio_o)
    );

    // ── Pinmux (0x1002_0020): the uo_out pin flops ─────────────────────────
    pinmux pinmux_inst (
        .clk  (clk),
        .rst  (rst_soc),
        .sel  (pinmux_sel),
        .we   (dmem_we),
        .be   (dmem_be),
        .wdata(dmem_wdata),
        .rdata(pinmux_rdata),
        .dflt ({audio_o, gpio_out[6], gpio_out[5], uart_tx, gpio_out[3:0]}),
        .gpio (gpio_out),
        .rts_n(uart_rts_n),
        .audio(audio_o),
        .pwm  (pwm_o),
        .uo   (uo)
    );

endmodule
