// TinyTapeout top level: alphaone_soc on the project's 24 pins. The pinout,
// the board wiring and the reasons for both are in
// docs/pins-and-peripherals.md.
//
//   ui_in[7:0]   GPIO IN, all eight pins. Two of them have a second job:
//   ui_in[0]       the qspi_rd_late strap, read during reset (see below)
//   ui_in[3]       UART RX
//   uo_out[3:0]  GPIO OUT 3:0 ([1] / [3] are MOSI / SCK while the SPI
//                transmitter is on)
//   uo_out[4]    UART TX
//   uo_out[5]    UART RTS#
//   uo_out[7:6]  GPIO OUT 7:6
//   uio[0]       QSPI CS0, flash         uio[3]  QSPI SCK
//   uio[6]       QSPI CS1, PSRAM A       uio[7]  QSPI CS2, PSRAM B
//   uio[1], uio[2], uio[4], uio[5]       QSPI SD0, SD1, SD2, SD3
//
// Reset. rst_n comes from the board and is asynchronous to clk; the SoC's
// reset is synchronous and active high. rst is set by rst_n itself, with or
// without a clock, and cleared by the second clock edge after rst_n rises.
// It has to be set without a clock: the demo board's firmware stops the
// clock, pulses rst_n and only then starts the clock, so a reset that waited
// for a clock edge would never see that pulse. Those two edges are also what
// carries the reset into the SoC's flops, so any pulse on rst_n, however
// short, resets the chip.
//
// While rst is high the pins do not depend on a clock either, or on what the
// SoC's flops happened to power up with:
//   * all eight bidirectional pins are inputs. Whoever holds the chip in
//     reset owns the QSPI bus and can program the flash through it;
//   * uo_out shows the SoC's reset values: TX and RTS# high, GPIO OUT 0x09.
// The strap on ui_in[0] is read on every clock edge while rst is high, the
// last of them the second edge after rst_n rises: hold it until then.
//
// ena is high whenever the design is powered, and is not used.

`default_nettype none

module tt_um_alfadelta10010_alphaone_soc (
    input  wire [7:0] ui_in,    // dedicated inputs
    output wire [7:0] uo_out,   // dedicated outputs
    input  wire [7:0] uio_in,   // bidirectional pins: input path
    output wire [7:0] uio_out,  // bidirectional pins: output path
    output wire [7:0] uio_oe,   // bidirectional pins: output enable, 1 = output
    input  wire       ena,      // 1 while the design is powered
    input  wire       clk,
    input  wire       rst_n     // reset, active low, asynchronous
);

    // ── Reset: asserted asynchronously, released synchronously ──────────────
    reg [1:0] rst_sync;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) rst_sync <= 2'b11;
        else        rst_sync <= {rst_sync[0], 1'b0};
    wire rst = rst_sync[1];

    // ── SoC ─────────────────────────────────────────────────────────────────
    wire       qspi_sck, qspi_ctl_oe, qspi_io_oe;
    wire [2:0] qspi_cs_n;
    wire [3:0] qspi_io_out;
    wire       uart_tx, uart_rts_n;
    wire [7:0] gpio_out;

    alphaone_soc soc (
        .clk         (clk),
        .rst         (rst),
        .qspi_rd_late(ui_in[0]),
        .qspi_sck    (qspi_sck),
        .qspi_cs_n   (qspi_cs_n),
        .qspi_ctl_oe (qspi_ctl_oe),
        .qspi_io_out (qspi_io_out),
        .qspi_io_oe  (qspi_io_oe),
        .qspi_io_in  ({uio_in[5], uio_in[4], uio_in[2], uio_in[1]}),
        .uart_rx     (ui_in[3]),
        .uart_tx     (uart_tx),
        .uart_rts_n  (uart_rts_n),
        .gpio_in     (ui_in),
        .gpio_out    (gpio_out)
    );

    // ── Pins ────────────────────────────────────────────────────────────────
    // UO_RESET is what the SoC itself drives once reset has reached it (the
    // UART's and the GPIO block's reset values), so nothing moves when rst
    // falls. Each bit comes down to one two-input gate of rst and the SoC's
    // bit, which cannot glitch when only rst changes.
    localparam [7:0] UO_RESET = 8'h39;
    assign uo_out  = rst ? UO_RESET
                         : {gpio_out[7:6], uart_rts_n, uart_tx, gpio_out[3:0]};

    assign uio_out = {qspi_cs_n[2], qspi_cs_n[1], qspi_io_out[3], qspi_io_out[2],
                      qspi_sck, qspi_io_out[1], qspi_io_out[0], qspi_cs_n[0]};

    wire ctl_oe = qspi_ctl_oe && !rst;    // SCK and the chip selects
    wire io_oe  = qspi_io_oe  && !rst;    // SD0..SD3
    assign uio_oe  = {ctl_oe, ctl_oe, io_oe, io_oe, ctl_oe, io_oe, io_oe, ctl_oe};

    // gpio_out[5:4] are always 0: those two pins are the UART's.
    wire _unused = &{ena, uio_in[7:6], uio_in[3], uio_in[0], gpio_out[5:4], 1'b0};

endmodule

`default_nettype wire
