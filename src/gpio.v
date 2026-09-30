// GPIO at 0x1001_0000 -- eight outputs, eight inputs, and a transmit-only
// SPI shifter for the OLED that borrows two of the outputs.
//
//   0x00  OUT   read/write. Bit i drives out[i]. Bits 4 and 5 are the UART's
//               pins (TX, RTS#): they read 0 and ignore writes. Resets to
//               0x09: the OLED held in reset with its panel supply off (bit 6
//               low), its CS# deselected (bit 0 high) and SCK at the mode-3
//               idle level (bit 3 high), so turning the shifter on makes no
//               edge; on the keypad, two columns high and two low, which
//               nothing reads until software scans.
//   0x04  IN    read only. in[7:0] through a two-flop synchroniser.
//   0x08  DATA  write only (reads 0). Shifts the byte in [7:0] out on MOSI,
//               MSB first. A byte is one store.
//   0x0C  CTRL  bit 0 EN: 1 = the shifter drives out[1] (MOSI) and out[3]
//                         (SCK) in place of OUT bits 1 and 3.
//               bits 2:1 DIV: SCK = clk / 2^(DIV+1).
//               bit 8 BUSY (read only): a byte is shifting.
//
// Registers are words; writes take lane 0 (be[0]) and ignore the rest, so a
// byte, halfword or word store to the register's address writes it. The
// window is decoded on addr[3:2] only and aliases through its 64 KB.
//
// Back-pressure: every register write waits (ready low) while a byte is
// shifting -- the same mechanism as the UART's THR. For DATA that makes a
// byte one store. For OUT it is what keeps CS# and D/C (OUT bits 0 and 2)
// still under a byte: the SSD1331 samples D/C on the byte's eighth rising
// SCK edge and needs CS# and D/C held 60 / 40 ns after it, so software can
// write `DATA; OUT` back to back without polling BUSY. For CTRL it keeps a
// change of DIV or EN from cutting an SCK phase short. Reads never wait, so
// BUSY can be polled.
//
// SPI mode 3: SCK idles high, MOSI changes on SCK's falling edge and the
// device samples it on the rising edge, half an SCK period later. MOSI only
// ever changes on a falling edge (it is its own flop), so the device also
// gets half a period of hold after each rising edge, whatever the core does
// next. A byte is 16 SCK half-periods, and then one more with SCK held high
// before the shifter goes idle, so a write waiting behind the byte lands at
// least half a period after its last rising edge. CS# and D/C are ordinary
// OUT bits, driven by software around the bytes. The SSD1331 needs an SCK
// period of at least 150 ns and each phase at least 75 ns: DIV = 2 exactly
// meets that at 53 MHz, so use it up to about 48 MHz and DIV = 3 above.
//
// The shifter needs no bit counter. spi_sh is loaded with {data, 1}: each
// falling edge moves its top bit to MOSI and shifts in a 0 at the bottom, so
// after the eighth the marker 1 has reached the top and the rest is zero.
// The rising edge that follows is the byte's last, and the half-period after
// it (SCK high, spi_sh still 9'h100) ends the byte. Idle is spi_sh == 0.

module gpio (
    input  wire        clk,
    input  wire        rst,
    // Bus: the core's request/ready handshake (soc_bus)
    input  wire        sel,        // request for this target
    input  wire        we,
    input  wire [3:0]  be,
    input  wire [3:2]  addr,
    input  wire [31:0] wdata,
    output wire [31:0] rdata,
    output wire        ready,      // low only while a write waits for a shifting byte
    // Pins
    input  wire [7:0]  in,         // asynchronous
    output wire [7:0]  out         // [5:4] belong to the UART and are 0 here
);

    reg [7:0] in_m, in_s;          // synchroniser
    reg [7:0] out_r;               // bits 5:4 unused
    reg       spi_en;
    reg [1:0] spi_div;
    reg [8:0] spi_sh;
    reg [2:0] spi_pre;             // clocks into the current half-period
    reg       spi_sck;
    reg       spi_mosi;
    wire      spi_busy = (spi_sh != 9'd0);

    // A half-period is 2^DIV clocks: spi_pre counts clocks from the load and
    // an edge falls when its low DIV bits are all ones.
    wire [2:0] div_mask = {spi_div == 2'd3, spi_div[1], spi_div != 2'd0};
    wire       spi_tick = &(spi_pre | ~div_mask);

    assign ready = !(sel && we && be[0] && spi_busy);
    wire   wr    = sel && we && be[0] && ready;

    assign rdata = (addr == 2'd0) ? {24'b0, out_r[7:6], 2'b00, out_r[3:0]} :
                   (addr == 2'd1) ? {24'b0, in_s} :
                   (addr == 2'd3) ? {23'b0, spi_busy, 5'b0, spi_div, spi_en} :
                                    32'h0000_0000;

    assign out = {out_r[7:6], 2'b00,
                  spi_en ? spi_sck  : out_r[3],
                  out_r[2],
                  spi_en ? spi_mosi : out_r[1],
                  out_r[0]};

    always @(posedge clk) begin
        in_m <= in;
        in_s <= in_m;
    end

    always @(posedge clk) begin
        if (rst) begin
            out_r    <= 8'h09;
            spi_en   <= 1'b0;
            spi_div  <= 2'd0;
            spi_sh   <= 9'd0;
            spi_pre  <= 3'd0;
            spi_sck  <= 1'b1;
            spi_mosi <= 1'b0;
        end else begin
            if (wr && addr == 2'd0)
                out_r <= {wdata[7:6], 2'b00, wdata[3:0]};
            if (wr && addr == 2'd3) begin
                spi_en  <= wdata[0];
                spi_div <= wdata[2:1];
            end

            if (wr && addr == 2'd2) begin
                spi_sh  <= {wdata[7:0], 1'b1};
                spi_pre <= 3'd0;
            end else if (spi_busy) begin
                spi_pre <= spi_pre + 3'd1;
                if (spi_tick) begin
                    if (spi_sck && spi_sh == 9'h100) begin
                        spi_sh   <= 9'd0;                 // hold after the last rise
                    end else begin
                        spi_sck  <= !spi_sck;
                        if (spi_sck) begin                // falling edge
                            spi_mosi <= spi_sh[8];
                            spi_sh   <= {spi_sh[7:0], 1'b0};
                        end
                    end
                end
            end
        end
    end

endmodule
