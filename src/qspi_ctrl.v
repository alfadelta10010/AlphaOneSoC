// QSPI engine -- one flash or PSRAM transaction at a time, on the TinyTapeout
// QSPI Pmod (W25Q128JV flash on CS0, two 8 MB PSRAMs on CS1 / CS2, one shared
// quad bus).
//
// A transaction is: chip select low, a command, a 24-bit address on IO[3:0],
// then data on IO[3:0]. The PSRAMs run in QPI mode, where the command too
// goes out on all four lines as two nibbles. The flash uses its quad I/O
// read in the chip's default mode ("SPI mode"), where only the command is
// 8 bits on IO0 (docs/qspi-memories.md weighs the options, including QPI
// for the flash):
//
//   PSRAM read   0x0B QPI   2 cmd + 6 addr + 4 wait  + 2 per byte  (SCK)
//   PSRAM write  0x38 QPI   2 cmd + 6 addr +           2 per byte
//   flash read   0xEB SPI   8 cmd + 6 addr + 6 dummy + 2 per byte
//
// So a 4-byte PSRAM read is 20 SCK cycles (28 in SPI form) and a 4-byte
// write 16 (22). All four PSRAM wait cycles are released, giving the bus a
// full four cycles to turn around. The flash reads the first two of its six
// dummy cycles as its mode byte M7-0 and then waits four: the first two are
// driven 1111, so the mode byte is 0xFF and the flash never enters
// continuous-read mode (mode bits M5-4 = 10 -- 0xAx, but also 0x20 -- would
// make it take the next command byte as an address), and the other four are
// released. The flash's Quad Enable bit
// must already be set (it is non-volatile; TinyTapeout's QA sets it on the
// Pmods it ships).
//
// Writes never select the flash. 0x38 is the PSRAM's quad write, but on the
// W25Q128JV-DTR it is Enter QPI, which would leave the flash deaf to every
// SPI read until a power cycle. The core's PMA check already faults stores
// to flash; this is the backstop.
//
// Start-up sequence. The Pmod is shared, and the demo board does not power
// cycle it between designs, so the devices can be left in a state this
// engine does not speak -- TinyQV, for one, leaves the PSRAMs in QPI mode and
// the flash in quad continuous-read mode; a design using the flash's dual I/O
// read (BBh) can leave it in dual continuous-read mode. The PSRAM datasheet also asks for a
// reset after power-up. So before taking its first request the engine sends
// the following, and leaves the PSRAMs in QPI mode:
//
//   CS1+CS2   F5h in QPI form (2 clocks)   PSRAM: leave QPI mode; a PSRAM
//                                          already in SPI mode sees two bits
//                                          of an unfinished command
//   CS1+CS2   66h, 99h (SPI)               PSRAM: reset enable, reset
//   CS0       8 clocks of 1111             flash: all-ones mode bits end
//                                          quad continuous-read mode (6
//                                          address + 2 mode clocks)
//   CS0       16 clocks of 1111            flash: the same for dual
//                                          continuous-read mode (12 address +
//                                          4 mode clocks, W25Q128JV-DTR
//                                          8.2.11: "input FFFFh on IO0 for the
//                                          next instruction (16 clocks)")
//   CS0       FFh in QPI form (2 clocks)   flash: Exit QPI on the
//                                          W25Q128JV-DTR; a flash in SPI mode
//                                          sees two bits and ignores them
//   CS1+CS2   35h (SPI)                    PSRAM: Enter Quad (QPI) mode
//
// The 8-clock window must come first: a flash in quad continuous-read mode
// would take a 16-clock window as address, mode and 4 dummy clocks, then
// drive data from clock 12. A flash in dual continuous-read mode takes the
// 8-clock window as part of an address and stays in the mode, so the
// 16-clock window after it is what gets it out.
// The sequence starts 8 clocks after reset is released. A reset can land
// in the middle of the sequence -- a glitch, or the RP2040 pulsing it --
// and if it lands just after a PSRAM reset (99h), the restarted sequence's
// first command must still come after the PSRAM's 50 ns tRST: the reset
// lasts at least a clock, and 8 more make over 50 ns at any clock up to
// 160 MHz. The existing phase counter counts them, so it costs no flop.
// The SoC always boots from flash, so nothing is in the PSRAMs yet and they
// are always reset. The flash steps sit between the reset and 35h, far more
// than the PSRAM's 50 ns tRST. The first F5h is what gets a PSRAM we left in
// QPI mode ourselves back to SPI mode at the next reset.
// Selecting both PSRAMs at once is safe because none of these commands makes
// a device drive the bus. The sequence assumes the devices' power-up time
// (150 us for the PSRAM) has passed, which on the demo board it long has.
// It does not undo flash states only a deliberate command sets -- a burst
// wrap (77h), deep power-down (B9h), or Quad Enable cleared (the "IM" part
// ships with QE = 0) -- which the master that programs the flash must leave
// alone.
//
// Timing. SCK runs at clk/2 and idles low (SPI mode 0). The data pins change
// on the clock edge that drives SCK low and the device samples them on the
// next rising edge, a full clock later, so they are driven combinationally
// from the state: a glitch settles long before it is sampled. SCK, the chip
// selects and both output enables are registered, since a glitch on those is
// seen at once.
//
// Read data is sampled late, to cover TinyTapeout's slow I/O (the pad round
// trip has been measured at a little over 20 ns). With rd_late = 0 a nibble is
// sampled two clocks after the falling edge that launched it -- on the clock
// that drives SCK low again, one whole SCK period later -- which fits a
// device clock-to-output time plus round trip up to about 2 clocks. With
// rd_late = 1 it is sampled three clocks after, for a round trip between 1 and
// about 3 clocks: the right choice at clock rates where 2 clocks is too
// tight. It is a strap, sampled while rst is high and held after it, so a pin
// that changes later cannot move the sampling point in the middle of a read.
// Chip select
// then stays low one extra clock for the last nibble. The other side of the
// sampling edge is covered by the device's output hold time plus the same
// pad delays, since the next falling edge reaches the device only after the
// output pad delay.
//
// Chip select is high for at least two clocks between transactions.
//
// A start-up window ends with chip select rising while SCK is still high,
// and SCK falls a clock later. A flash in continuous-read mode starts
// driving data on the falling edge after its address, mode and dummy clocks;
// were that edge the one chip select rises on, its pads and ours could
// overlap for a moment. Every other transaction ends on SCK's falling edge
// (mode 0), since there the device drives nothing new.
//
// Interface. The requester (mem_ctrl) raises `start`. cs_sel and we are taken
// on the cycle the transaction starts (`start` with `idle`) and kept here (two
// flops); addr, nbytes_m1 and wdata are read combinationally from the cycle
// after that until `done`, and must be stable over those cycles. So the
// requester may still be choosing whom to serve on the start cycle, where
// only the chip and the direction have to be right, and that choice is not
// in front of the pins: the command, address and data nibbles are driven
// from this module's state and from what the requester holds steady. `done` is high
// for one cycle, the first cycle after the last data clock, and read data is
// valid in that cycle. `start` is taken only on a cycle `idle` is high, and
// `idle` is never high on the cycle `done` is, so a requester's request is
// never sampled on its own ready cycle, when it may still show the request
// being completed. Read data is shifted in at the bottom of a 32-bit
// register that is *not* cleared between transactions, so two 2-byte reads in
// a row assemble one 4-byte word (mem_ctrl's split fetch relies on this).
//
// While rst is high every pin is released (ctl_oe and io_oe low), so another
// master -- the TinyTapeout demo board's RP2040 -- can program the flash or
// load the PSRAM over the same pins before it lets the core out of reset.
// After reset SCK and the chip selects are driven, idle, for one cycle before
// the first chip select falls.

module qspi_ctrl (
    input  wire        clk,
    input  wire        rst,
    input  wire        rd_late,    // strap, sampled during reset: read data one clock later
    // Transaction request, held by the requester until done
    input  wire        start,
    input  wire [1:0]  cs_sel,     // 0 = flash (CS0), 1 = PSRAM A (CS1), 2 = PSRAM B (CS2); taken at the start
    input  wire [23:0] addr,       // byte address within the chip
    input  wire        we,         // 1 = quad write 0x38, 0 = quad I/O read 0xEB; taken at the start
    input  wire [1:0]  nbytes_m1,  // bytes to transfer, minus one
    input  wire [31:0] wdata,      // write data, first byte sent in [7:0]
    output wire        idle,       // no transaction in progress: start is taken
    output wire        done,       // transaction complete (one cycle)
    output wire [31:0] rdata,      // bytes received, first byte in [7:0]
    // Pins
    output reg         sck,
    output reg  [2:0]  cs_n,
    output reg         ctl_oe,     // output enable for SCK and the chip selects
    output reg  [3:0]  io_out,
    output reg         io_oe,      // output enable for IO[3:0]
    input  wire [3:0]  io_in
);

    localparam [2:0] S_IDLE  = 3'd0,
                     S_CMD   = 3'd1,
                     S_ADDR  = 3'd2,
                     S_DUMMY = 3'd3,
                     S_DATA  = 3'd4,
                     S_TAIL  = 3'd5,    // rd_late: CS held for the last nibble
                     S_END   = 3'd6;

    reg [2:0]  state;
    reg [2:0]  cnt;     // SCK cycles left in the current phase, counting down
    reg [31:0] sr;      // read data, shifted in a nibble at a time
    reg        init;    // start-up sequence still running
    reg [2:0]  step;    // which command of it
    reg        late;    // rd_late, as sampled during reset
    reg        again;   // start-up step 4: second 8 clocks of its 16
    reg        t_we;    // the transaction in flight: its `we`...
    reg        t_psram; // ...and whether its chip is a PSRAM

    assign idle  = (state == S_IDLE) && !init;
    assign done  = (state == S_END)  && !init;
    // The first nibble received is the high nibble of the first byte, so the
    // register holds the bytes big-endian; swapping them back is wiring.
    assign rdata = {sr[7:0], sr[15:8], sr[23:16], sr[31:24]};

    // Start-up steps: 0 = F5h in QPI form, 1 = 66h, 2 = 99h (PSRAMs);
    // 3 = 8 clocks of 1111, 4 = 16 clocks of 1111, 5 = FFh in QPI form
    // (flash); 6 = 35h (PSRAMs). Steps 3 and 4 are FFh in SPI form, step 4
    // sent twice under one chip select. After it, PSRAM traffic is QPI form
    // and flash traffic SPI form.
    // start_*: of a transaction starting on this clock, from the request.
    // psram and qpi_form: of the transaction in flight, from t_psram.
    wire       start_psram = (cs_sel != 2'd0);
    wire       start_qpi   = init ? (step == 3'd0 || step == 3'd5) : start_psram;
    wire       psram    = t_psram;
    wire       qpi_form = init ? (step == 3'd0 || step == 3'd5) : psram;
    reg  [7:0] cmd;
    always @(*) begin
        if (init)
            case (step)
                3'd0:    cmd = 8'hF5;
                3'd1:    cmd = 8'h66;
                3'd2:    cmd = 8'h99;
                3'd6:    cmd = 8'h35;
                default: cmd = 8'hFF;
            endcase
        else
            cmd = t_we ? 8'h38 : psram ? 8'h0B : 8'hEB;
    end

    // The data phase counts cnt down from 7 and stops at 8 - 2*nbytes. The
    // nibble on the wire is then number 7 - cnt of the transfer: byte
    // ~cnt[2:1], high half first, which is nibble {~cnt[2:1], cnt[0]} of
    // wdata.
    wire [2:0] data_last = {~nbytes_m1, 1'b0};
    wire [2:0] wnib      = {~cnt[2:1], cnt[0]};

    always @(*) begin
        case (state)
            // QPI form: high nibble first. SPI form: MSB first on IO0, with
            // IO1-IO3 held high (on a flash with QE = 0 they are /WP, /HOLD).
            S_CMD:   io_out = qpi_form ? (cnt[0] ? cmd[7:4] : cmd[3:0])
                                       : {3'b111, cmd[cnt]};
            S_ADDR:  io_out = addr[{cnt, 2'b00} +: 4];
            S_DATA:  io_out = wdata[{wnib, 2'b00} +: 4];
            default: io_out = 4'b1111;       // mode byte 0xFF, and idle
        endcase
    end

    // Where a read nibble is captured (see Timing above). Late: on each
    // rising-edge clock of the data phase but the first, and in S_TAIL.
    wire sample = !t_we && (late ? ((state == S_DATA && !sck && cnt != 3'd7) || state == S_TAIL)
                               :  (state == S_DATA &&  sck));

    // Chip selects for a transaction starting now. A write never selects
    // the flash.
    wire [2:0] sel_now = init ? ((step == 3'd3 || step == 3'd4 || step == 3'd5) ? 3'b001 : 3'b110)
                              : ((3'b001 << cs_sel) & {2'b11, !we});

    always @(posedge clk) begin
        if (rst) begin
            state  <= S_IDLE;
            cnt    <= 3'd0;
            sck    <= 1'b0;
            cs_n   <= 3'b111;
            ctl_oe <= 1'b0;
            io_oe  <= 1'b0;
            init   <= 1'b1;
            step   <= 3'd0;
            late   <= rd_late;
            again  <= 1'b0;
        end else begin
            ctl_oe <= 1'b1;
            if (sample)
                sr <= {sr[27:0], io_in};
            case (state)
                // ctl_oe: the pins have been driven idle for a cycle. The
                // start-up sequence waits 8 clocks after reset first (cnt
                // counts them; see Start-up sequence).
                S_IDLE: if (ctl_oe && (init ? (step != 3'd0 || cnt == 3'd7) : start)) begin
                    state <= S_CMD;
                    cnt   <= start_qpi ? 3'd1 : 3'd7;
                    cs_n  <= ~sel_now;
                    io_oe <= 1'b1;
                    t_we    <= we;
                    t_psram <= start_psram;
                end else if (init)
                    cnt <= cnt + 3'd1;
                S_TAIL: begin
                    state <= S_END;
                    cs_n  <= 3'b111;
                end
                S_END: begin
                    state <= S_IDLE;
                    sck   <= 1'b0;
                    if (init) begin
                        step <= step + 3'd1;
                        if (step == 3'd6)
                            init <= 1'b0;
                    end
                end
                default: begin
                    // SCK toggles every clock of an active phase; everything
                    // else happens on the clock that drives it low.
                    sck <= ~sck;
                    if (sck) begin
                        if (state == S_DUMMY && cnt == 3'd4)
                            io_oe <= 1'b0;      // mode byte done: release the bus
                        if (state == S_DATA ? (cnt == data_last) : (cnt == 3'd0)) begin
                            case (state)
                                S_CMD: if (init && step == 3'd4 && !again) begin
                                    cnt   <= 3'd7;      // 8 more clocks of 1111
                                    again <= 1'b1;
                                end else if (init) begin
                                    again <= 1'b0;
                                    state <= S_END;
                                    cs_n  <= 3'b111;
                                    io_oe <= 1'b0;
                                    sck   <= 1'b1;      // SCK falls in S_END
                                end else begin
                                    state <= S_ADDR;
                                    cnt   <= 3'd5;
                                end
                                // Reads: the PSRAM's 4 wait cycles are all
                                // released; the flash's 6 start with its
                                // driven mode byte (released at cnt 4 below).
                                S_ADDR: begin
                                    state <= t_we ? S_DATA : S_DUMMY;
                                    cnt   <= t_we ? 3'd7 : psram ? 3'd3 : 3'd5;
                                    if (!t_we && psram)
                                        io_oe <= 1'b0;
                                end
                                S_DUMMY: begin state <= S_DATA; cnt <= 3'd7; end
                                default: begin  // S_DATA
                                    io_oe <= 1'b0;
                                    if (late && !t_we)
                                        state <= S_TAIL;
                                    else begin
                                        state <= S_END;
                                        cs_n  <= 3'b111;
                                    end
                                end
                            endcase
                        end else
                            cnt <= cnt - 3'd1;
                    end
                end
            endcase
        end
    end

endmodule
