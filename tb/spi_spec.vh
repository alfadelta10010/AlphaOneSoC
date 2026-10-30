// Specification constants for the SPI controller benches (WO-29), written
// from WO-28 sections 1-3 and WO-29 sections 2-3, never from src/spi.v.
//
// Sources, in order: the Linux driver drivers/spi/spi-oc-tiny.c (function
// tiny_spi_txrx_bufs, the polled branch, and tiny_spi_baud); the OpenCores
// tiny_spi RTL for the register semantics; WO-28 1.2, 1.3, 2.1-2.5, 3; the
// SD Physical Layer Simplified Specification chapter 7; the SSD1331 Table 21.
//
// Driver blob hash: NOT RECORDED. The coder had no network, so the polled loop
// in tb_spi.v and tests/soc/spi_drv.S is transcribed from WO-28 1.1, which is
// the same bus sequence rotated by one write (SA-SPI-08):
//     write TXDATA(b0)
//     for i = 1 .. len-1: write TXDATA(b[i]); wait STATUS.TXR; read TXDATA -> rx[i-1]
//     wait STATUS.TXE; read RXDATA -> rx[len-1]
// baud = min(DIV_ROUND_UP(freq, 2 * hz), 1 << baud_width) - 1.
//
// Assumptions that became the spec (coordinator, 2026-10-30, Q3-Q5), SA-SPI-*:
//   A1 / SA-SPI-01 unlisted bits of RXDATA, TXDATA, STATUS, CONTROL, BAUD and
//                  SPICTL read 0 and ignore writes (Q5).
//   A2 / SA-SPI-02 RXDATA or TXDATA read in the middle of a byte: don't-care
//                  (not compared) but never X (Q3). TXDATA is nevertheless
//                  compared whenever bb holds a written byte.
//   A3 / SA-SPI-03 MOSI after an EN 0->1 write holds OUT bit 1's last value
//                  until the first LOAD (Q4).
//   A4 / SA-SPI-04 a STATUS write or a reserved-slot write while busy stalls
//                  until TXE, then does nothing.
//   A5 / SA-SPI-05 SCK and CS# changing on the same timestamp at a reboot is
//                  a counted race, allowed only in sd_reboot (Q6).
//   SA-SPI-08      the driver source was not available offline (see above).
//   SD timing figures (14 / 50 ns output delay, 0 hold, 5 ns setup and hold)
//   are from memory and stay "to verify against the SD Physical Layer
//   Simplified Specification v9.x" (Q7). They are parameters of the models.

`ifndef SPI_SPEC_VH
`define SPI_SPEC_VH

// Clock: 62.5 MHz, the chip clock on sky26d.
`define SPI_T_NS      16.0

// GPIO window slots, addr[5:2] of the 64-byte-aliased window at 0x1001_0000.
`define SL_OUT        4'd0
`define SL_IN         4'd1
`define SL_SPICTL     4'd3
`define SL_RXDATA     4'd8     // 0x20
`define SL_TXDATA     4'd9     // 0x24
`define SL_STATUS     4'd10    // 0x28: bit 0 TXE, bit 1 TXR
`define SL_CONTROL    4'd11    // 0x2C: bit 0 CPHA, bit 1 CPOL
`define SL_BAUD       4'd12    // 0x30

// Reset values (SPI-003).
`define SPI_OUT_RESET   8'h89
`define SPI_CTL_RESET   2'b11
`define SPI_BAUD_RESET  8'hFF
`define SPI_UO_RESET    8'hB9  // uo_out at the wrapper, every reset path

// Timing (SPI-006): a byte is 16 (B+1) clocks; the first launch is the clock
// after the TXDATA write; the sample is at launch + 2B + 1 clocks.
`define SPI_BYTE_CLKS(b)    (16 * ((b) + 1))
`define SPI_SAMPLE_OFF(b)   (2 * (b) + 1)

// Card and pad timing (SPI-018), ns. rt + T_ODLY must be < (2B+1) T.
`define SD_T_ODLY      14.0
`define SD_T_ODLY_ID   50.0
`define SD_T_OH        0.0
`define SD_T_ISU       5.0
`define SD_T_IH        5.0

`endif
