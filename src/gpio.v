// GPIO at 0x1001_0000 -- eight outputs, eight inputs, and (from 0x20) a
// tiny_spi-compatible SPI controller (src/spi.v) that borrows two of the
// outputs. The window is decoded on addr[5:2] (16 word slots) and aliases
// every 64 bytes through its 64 KB.
//
//   0x00  OUT     read/write. Bit i drives out[i]. Bits 1 and
//                 3 are the MOSI and SCK pin flops: while EN = 1 the SPI
//                 engine drives them and OUT writes to those two bits are
//                 ignored. Reads return this block's outputs (after the pinmux
//                 they are not the pads). Resets to 0xB9: SD CS# (bit 5) and
//                 OLED CS# (bit 0) high, bit 7 high, bit 4 high (the UART TX
//                 idle level if pin 4 is switched to GPIO), SCK at the mode-3
//                 idle level (bit 3 high), the OLED held in reset with its
//                 panel supply off (bit 6 low).
//   0x04  IN      read only. in[7:0] through a two-flop synchroniser.
//   0x08          reserved: reads 0, writes ignored.
//   0x0C  SPICTL  bit 0 EN: 1 = the SPI engine owns out[1] and out[3].
//                 bit 8 BUSY (read only) = !TXE. Resets to 0.
//   0x10-0x1C     reserved.
//   0x20  RXDATA  read only: the byte received with the last byte sent;
//                 valid once TXE = 1.
//   0x24  TXDATA  write: put a byte in the holding register. Read: that
//                 register (the byte written but not yet loaded, or after a
//                 load the byte received with the byte before).
//   0x28  STATUS  Read: bit 0 TXE = engine idle and holding register
//                 empty; bit 1 TXR = holding register empty. Write: bits 1:0
//                 are tiny_spi's IRQ enables (TXR, TXE; reset 0); a write
//                 never waits. spi_irq = (TXR & en1) | (TXE & en0), level.
//   0x2C  CONTROL bit 0 CPHA, bit 1 CPOL; resets to 3 (mode 3).
//   0x30  BAUD    bits 7:0, resets to 0xFF. SCK = clk / (2 x (BAUD + 1)).
//   0x34-0x3C     reserved.
//
// Registers are words; writes take lane 0 (be[0]) and ignore the rest, so a
// byte, halfword or word store to the register's address writes it.
//
// Back-pressure (ready low, only while selected, on a write): a TXDATA write
// waits while the holding register is full, and every other write waits for
// TXE. That keeps CS# and D/C (OUT bits 0, 2, 7) still under a byte (the
// SSD1331 samples D/C on the byte's eighth rising SCK edge and needs CS# and
// D/C held 60 / 40 ns after it, so software can write `TXDATA; OUT` back to
// back without polling), and keeps a change of mode, BAUD or EN from cutting
// a phase short. Reads never wait.
//
// Departures from the tiny_spi RTL: a TXDATA write to a full holding
// register waits (tiny_spi overwrote it); TXE also needs the holding register
// empty; STATUS writes set the IRQ enables and never wait; CONTROL, BAUD and the data registers have
// reset values.

module gpio (
    input  wire        clk,
    input  wire        rst,
    // Bus: the core's request/ready handshake (soc_bus)
    input  wire        sel,        // request for this target
    input  wire        we,
    input  wire [3:0]  be,
    input  wire [5:2]  addr,
    input  wire [31:0] wdata,
    output wire [31:0] rdata,
    output wire        ready,      // low only while a write waits for the SPI engine
    // Pins
    input  wire [7:0]  in,         // asynchronous
    output wire [7:0]  out,
    output wire [7:0]  in_sync,    // the synchronised inputs (gamepad)
    output wire        spi_irq
);

    localparam [3:0] S_OUT = 4'd0, S_IN = 4'd1, S_CTL = 4'd3,
                     S_RX = 4'd8, S_TX = 4'd9, S_ST = 4'd10, S_CON = 4'd11, S_BAUD = 4'd12;

    reg [7:0] in_m, in_s;          // synchroniser
    reg [7:0] out_r;               // bits 7:4, 2, 0 only; 3 and 1 live in spi's pin flops
    reg       spi_en;

    wire [7:0] s_rx, s_tx, s_baud;
    wire [1:0] s_con;
    wire       s_txe, s_txr, p_mosi, p_sck;

    wire req   = sel && we && be[0];
    wire stall = (addr == S_TX) ? !s_txr : (addr == S_ST) ? 1'b0 : !s_txe;
    assign ready = !(req && stall);
    wire   wr    = req && ready;
    assign in_sync = in_s;

    spi spi_inst (
        .clk     (clk),
        .rst     (rst),
        .en      (spi_en),
        .miso    (in_m[1]),
        .wdata   (wdata[7:0]),
        .wr_tx   (wr && addr == S_TX),
        .wr_ctl  (wr && addr == S_CON),
        .wr_baud (wr && addr == S_BAUD),
        .wr_en   (wr && addr == S_CTL && wdata[0]),
        .wr_out  (wr && addr == S_OUT),
        .wr_st   (wr && addr == S_ST),
        .rxdata  (s_rx),
        .txdata  (s_tx),
        .txe     (s_txe),
        .txr     (s_txr),
        .control (s_con),
        .baud_o  (s_baud),
        .p_mosi  (p_mosi),
        .p_sck   (p_sck),
        .irq     (spi_irq)
    );

    // MOSI and SCK come straight from flops: no mux, so a change of EN and of
    // an OUT bit on the same edge cannot make a glitch on the pin.
    assign out = {out_r[7:4], p_sck, out_r[2], p_mosi, out_r[0]};

    assign rdata = (addr == S_OUT)  ? {24'b0, out} :
                   (addr == S_IN)   ? {24'b0, in_s} :
                   (addr == S_CTL)  ? {23'b0, !s_txe, 7'b0, spi_en} :
                   (addr == S_RX)   ? {24'b0, s_rx} :
                   (addr == S_TX)   ? {24'b0, s_tx} :
                   (addr == S_ST)   ? {30'b0, s_txr, s_txe} :
                   (addr == S_CON)  ? {30'b0, s_con} :
                   (addr == S_BAUD) ? {24'b0, s_baud} :
                                      32'h0000_0000;

    always @(posedge clk) begin
        in_m <= in;
        in_s <= in_m;
    end

    always @(posedge clk) begin
        if (rst) begin
            out_r  <= 8'hB1;                // OUT 0xB9 with p_sck (bit 3) reset high
            spi_en <= 1'b0;
        end else begin
            if (wr && addr == S_OUT)
                out_r <= {wdata[7:4], 1'b0, wdata[2], 1'b0, wdata[0]};
            if (wr && addr == S_CTL)
                spi_en <= wdata[0];
        end
    end

endmodule
