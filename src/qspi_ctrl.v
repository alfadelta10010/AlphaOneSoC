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
// Streaming. The flash keeps delivering the next bytes for as long as chip
// select stays low and SCK keeps clocking, so a flash read that continues the
// previous one need not send the command, address and dummy clocks again: 8 SCK
// for 4 bytes instead of 28. After a 4-byte flash read, with `stream_en` set,
// chip select stays low and SCK stays low and the bus is released (`strm`): the
// flash holds the next nibble on its pins. `p` is the halfword address of the
// next byte it will deliver. The next request:
//   * a PSRAM access or a write: chip select rises at once (closing the stream);
//   * a flash read, checked one clock later, when its address is valid
//     (S_CHK): address == p continues the stream with 4 more bytes; address ==
//     p - 2 bytes (the halfword just delivered) is a top-up of 2 bytes -- the
//     shift register still holds the last 4 bytes of the stream, so the 4
//     bytes at the address are its last 2 and the 2 new ones (the fetch reuse
//     pattern: a kept halfword followed by a 32-bit instruction); anything
//     else closes the stream and starts a normal read.
// Closing raises chip select while SCK is low and keeps it high two clocks
// before the next select falls (S_CLOSE, S_GO), as between any two
// transactions. With `stream_en` low and the engine idle the stream closes too.
// With `stream_en` tied low no stream ever opens and the pins behave as
// without this section. Reset clears `strm` with everything else; the start-up
// sequence never streams.
//
// DDR. With `ddr` set (QSPI_CFG.DDR) every flash read is an EDh DTR read
// (W25Q128JV-DTR 8.2.14, docs/qspi-memories.md; the wire protocol is derived
// in DDR-CONTRACT):
//
//   flash read   0xED SPI   8 cmd + 4 addr/mode (6 + 2 nibbles, both SCK edges)
//                           + 7 dummy + 1 per byte (SCK); 4 bytes = 23 SCK, or
//                           6 bytes = 25 when addr[1] is set
//
// The command is sent as for EBh. The address goes out a nibble per SCK edge
// with A1:A0 forced to 00 (the open is word aligned), then the mode byte FFh.
// A read at addr[1] = 1 therefore reads 6 bytes, the shift register keeping the
// last 4. The bus is released on the clock after the last mode nibble's
// falling edge. Data nibbles come out at every SCK edge from the falling edge
// of the last dummy cycle on, so the last falling edge of a read launches the
// first nibble of the next one, which the flash holds on the pins while SCK
// is paused (the held nibble). Streaming works as in SDR: a continuation of
// 4 bytes is 4 SCK, a top-up of 2 bytes is 2 SCK; the held nibble is shifted
// in on the clock that accepts a continuation (S_CHK), never before, since
// `sr` still holds the last 4 bytes of the stream.
//
// Pins. SCK keeps its flop and pin path. A DDR transaction drives IO[3:0]
// from four negedge flops (nib_n), loaded from four posedge flops (nib_p,
// loaded one clock earlier), so every host nibble changes at a falling clk
// edge, half a clock from the SCK edges on either side of it. The pin select
// (t_ddr) is constant through a transaction: it changes only on the clock
// that takes the bus.
//
// Capture. A nibble launched by an SCK edge E (a rising clk edge) is
// captured c = ddr_cap + 1 half clocks later: even c at the rising clk edge
// c/2 clocks after E straight from io_in, odd c in four negedge flops (cap_n)
// c/2 clocks after E and taken at the following rising edge. dq[3:0] is the
// launch mark pipeline (dq[k-1]: the launch k clocks ago); `sr` shifts when
// the mark at stage m1 = (ddr_cap + 2) / 2 is set. `done` comes after the
// last capture (S_TAIL waits for the marks still in flight). ddr and ddr_cap
// are latched per transaction; a change while a stream is open closes it.
// Writes, PSRAM traffic and the start-up sequence are always SDR.
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
    input  wire        stream_en,  // 1 = flash reads may keep chip select low for the next one
    input  wire        ddr,        // 1 = flash reads are EDh DTR reads (QSPI_CFG.DDR)
    input  wire [2:0]  ddr_cap,    // DDR capture point: half clocks after the launching edge, minus 1
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
    output wire [3:0]  io_out,
    output reg         io_oe,      // output enable for IO[3:0]
    input  wire [3:0]  io_in
);

    localparam [3:0] S_IDLE  = 4'd0,
                     S_CMD   = 4'd1,
                     S_ADDR  = 4'd2,
                     S_DUMMY = 4'd3,
                     S_DATA  = 4'd4,
                     S_TAIL  = 4'd5,    // rd_late: CS held for the last nibble
                     S_END   = 4'd6,
                     S_CHK   = 4'd7,    // stream open, flash read requested: addr is valid now
                     S_CLOSE = 4'd8,    // CS high, first clock (cnt[0]: a request waits)
                     S_GO    = 4'd9;    // CS high, second clock; the request starts

    reg [3:0]  state;
    reg [2:0]  cnt;     // SCK cycles left in the current phase, counting down
    reg [31:0] sr;      // read data, shifted in a nibble at a time
    reg        init;    // start-up sequence still running
    reg [2:0]  step;    // which command of it
    reg        late;    // rd_late, as sampled during reset
    reg        again;   // start-up step 4: second 8 clocks of its 16
    reg        t_we;    // the transaction in flight: its `we`...
    reg        t_psram; // ...and whether its chip is a PSRAM
    reg        strm;    // a stream is open: CS0 low, SCK low, bus released
    reg [23:1] p;       // halfword address of the next byte the stream delivers (a 24-bit
                        // address's bits 23:1; no reset: read only while strm)
    reg        t_top;   // this transfer is a 2-byte top-up of the stream
    reg [2:0]  t_sel;   // the chip selects of the request (for the close path)
    reg        t_ddr;   // this transaction (or the open stream) is an EDh DTR read
    reg [2:0]  t_cap;   // ddr_cap, as latched with it
    reg [3:0]  nib_p;   // DDR host nibble, one clock ahead of the pins
    reg [3:0]  nib_n;   // ...on the pins: changes at a falling clk edge
    reg [3:0]  cap_n;   // DDR odd-c capture, at a falling clk edge
    reg [3:0]  dq;      // DDR launch marks

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
            cmd = t_we ? 8'h38 : psram ? 8'h0B : t_ddr ? 8'hED : 8'hEB;
    end

    // The data phase counts cnt down from 7 and stops at 8 - 2*nbytes. The
    // nibble on the wire is then number 7 - cnt of the transfer: byte
    // ~cnt[2:1], high half first, which is nibble {~cnt[2:1], cnt[0]} of
    // wdata.
    wire [2:0] data_last = t_top ? 3'd4 : {~nbytes_m1, 1'b0};
    wire [2:0] wnib      = {~cnt[2:1], cnt[0]};

    reg [3:0] io_sdr;
    always @(*) begin
        case (state)
            // QPI form: high nibble first. SPI form: MSB first on IO0, with
            // IO1-IO3 held high (on a flash with QE = 0 they are /WP, /HOLD).
            S_CMD:   io_sdr = qpi_form ? (cnt[0] ? cmd[7:4] : cmd[3:0])
                                       : {3'b111, cmd[cnt]};
            S_ADDR:  io_sdr = addr[{cnt, 2'b00} +: 4];
            S_DATA:  io_sdr = wdata[{wnib, 2'b00} +: 4];
            default: io_sdr = 4'b1111;       // mode byte 0xFF, and idle
        endcase
    end
    assign io_out = t_ddr ? nib_n : io_sdr;

    // DDR host nibble for the pins from the next falling clk edge on, i.e. what
    // the next SCK edge samples. Command: IO0 bits as in SDR, A23-20 on the
    // last command clock; then addr[19:16] ... addr[3:0] with A1:A0 = 00, then
    // the mode byte FFh.
    wire [3:0] aidx = {cnt, 1'b0} - 4'd2 - {3'b0, sck};
    reg  [3:0] nib_next;
    always @(*) begin
        case (state)
            S_CMD:   nib_next = (sck && cnt == 3'd0) ? addr[23:20]
                                                     : {3'b111, cmd[sck ? cnt - 3'd1 : cnt]};
            S_ADDR:  nib_next = aidx[3] ? 4'hF
                              : aidx == 4'd0 ? {addr[3:2], 2'b00}
                              : addr[{aidx[2:0], 2'b00} +: 4];
            default: nib_next = 4'hF;
        endcase
    end
    always @(posedge clk) nib_p <= nib_next;
    always @(negedge clk) begin
        nib_n <= nib_p;
        cap_n <= io_in;
    end

    // Where a read nibble is captured (see Timing above). Late: on each
    // rising-edge clock of the data phase but the first, and in S_TAIL.
    wire sample = !t_we && !t_ddr && (late ? ((state == S_DATA && !sck && cnt != 3'd7) || state == S_TAIL)
                               :  (state == S_DATA &&  sck));

    // Chip selects for a transaction starting now. A write never selects
    // the flash.
    wire [2:0] sel_now = init ? ((step == 3'd3 || step == 3'd4 || step == 3'd5) ? 3'b001 : 3'b110)
                              : ((3'b001 << cs_sel) & {2'b11, !we});

    // A flash read that may leave a stream open (all flash reads are 4 bytes).
    wire streamable = !t_psram && !t_we && nbytes_m1 == 2'd3 && stream_en && !init;
    wire [23:1] a_hw = addr[23:1];
    wire hit_cont = (a_hw == p);
    wire hit_top  = (a_hw == p - 23'd1);

    // DDR: the dq stage that shifts a captured nibble in, the marks still in
    // flight (stages before it), a mode change of an open stream, the held
    // nibble taken at a continuation, and a launch: every SCK edge of the data
    // phase but the last falling one (it launches the held nibble), and the
    // falling edge that ends the dummies.
    wire [2:0] m1        = (t_cap + 3'd2) >> 1;
    wire       dq_hit    = dq[m1 - 3'd1];
    wire       dq_pend   = |(dq & ((4'd1 << (m1 - 3'd1)) - 4'd1));
    wire       mode_chg  = (t_ddr != ddr) || (t_ddr && t_cap != ddr_cap);
    wire       take_cont = (state == S_CHK) && t_ddr && streamable && !mode_chg && (hit_cont || hit_top);
    wire       ddr_sh    = t_ddr && !t_we && dq_hit;
    wire       launch    = t_ddr && ((state == S_DATA && !(sck && cnt == 3'd0)) ||
                                     (state == S_DUMMY && sck && cnt == 3'd0));

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
            t_ddr  <= 1'b0;
            dq     <= 4'b0;
            again  <= 1'b0;
            strm   <= 1'b0;
        end else begin
            ctl_oe <= 1'b1;
            dq <= {dq[2:0], launch};
            if (sample || take_cont)
                sr <= {sr[27:0], io_in};
            else if (ddr_sh)
                sr <= {sr[27:0], t_cap[0] ? io_in : cap_n};
            case (state)
                // ctl_oe: the pins have been driven idle for a cycle. The
                // start-up sequence waits 8 clocks after reset first (cnt
                // counts them; see Start-up sequence).
                S_IDLE: if (ctl_oe && (init ? (step != 3'd0 || cnt == 3'd7) : (start && !strm))) begin
                    state <= S_CMD;
                    cnt   <= start_qpi ? 3'd1 : 3'd7;
                    cs_n  <= ~sel_now;
                    io_oe <= 1'b1;
                    t_we    <= we;
                    t_psram <= start_psram;
                    t_sel   <= sel_now;
                    t_top   <= 1'b0;
                    t_ddr   <= ddr && !we && cs_sel == 2'd0 && !init;
                    t_cap   <= ddr_cap;
                end else if (!init && strm && start) begin
                    // A request while a stream is open: only cs_sel and we
                    // are valid. Anything but a flash read closes it at once.
                    t_we    <= we;
                    t_psram <= start_psram;
                    t_sel   <= sel_now;
                    t_top   <= 1'b0;
                    if (start_psram || we) begin
                        state <= S_CLOSE;
                        cnt   <= 3'd1;
                        cs_n  <= 3'b111;
                        strm  <= 1'b0;
                    end else
                        state <= S_CHK;
                end else if (!init && strm && (!stream_en || mode_chg)) begin
                    state <= S_CLOSE;       // nobody waiting: just close
                    cnt   <= 3'd0;
                    cs_n  <= 3'b111;
                    strm  <= 1'b0;
                end else if (init)
                    cnt <= cnt + 3'd1;
                S_CHK: begin
                    if (streamable && !mode_chg && (hit_cont || hit_top)) begin
                        state <= S_DATA;
                        cnt   <= t_ddr ? (hit_cont ? 3'd3 : 3'd1) : 3'd7;
                        t_top <= !hit_cont;
                    end else begin
                        state <= S_CLOSE;
                        cnt   <= 3'd1;
                        cs_n  <= 3'b111;
                        strm  <= 1'b0;
                    end
                end
                S_CLOSE: state <= cnt[0] ? S_GO : S_IDLE;
                S_GO: begin
                    state <= S_CMD;
                    cnt   <= t_psram ? 3'd1 : 3'd7;
                    cs_n  <= ~t_sel;
                    io_oe <= 1'b1;
                    t_ddr <= ddr && !t_we && !t_psram;
                    t_cap <= ddr_cap;
                end
                S_TAIL: if (!t_ddr || !dq_pend) begin
                    state <= S_END;
                    if (!strm)
                        cs_n <= 3'b111;
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
                    // DDR: the bus is released the clock after the last mode
                    // nibble's falling edge (the flash holds it 2 ns past it)
                    if (state == S_DUMMY && t_ddr && cnt == 3'd6 && !sck)
                        io_oe <= 1'b0;
                    if (sck) begin
                        if (state == S_DUMMY && cnt == 3'd4 && !t_ddr)
                            io_oe <= 1'b0;      // mode byte done: release the bus
                        if (state == S_DATA ? (cnt == (t_ddr ? 3'd0 : data_last)) : (cnt == 3'd0)) begin
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
                                    cnt   <= t_ddr ? 3'd3 : 3'd5;
                                end
                                // Reads: the PSRAM's 4 wait cycles are all
                                // released; the flash's 6 start with its
                                // driven mode byte (released at cnt 4 below).
                                S_ADDR: begin
                                    state <= t_we ? S_DATA : S_DUMMY;
                                    cnt   <= t_we ? 3'd7 : psram ? 3'd3 : t_ddr ? 3'd6 : 3'd5;
                                    if (!t_we && psram)
                                        io_oe <= 1'b0;
                                end
                                S_DUMMY: begin
                                    state <= S_DATA;
                                    cnt   <= t_ddr ? (addr[1] ? 3'd5 : 3'd3) : 3'd7;
                                end
                                default: begin  // S_DATA
                                    io_oe <= 1'b0;
                                    strm  <= streamable;    // leave the stream open
                                    p     <= a_hw + 23'd2;
                                    if (t_ddr ? dq_pend : (late && !t_we))
                                        state <= S_TAIL;
                                    else begin
                                        state <= S_END;
                                        if (!streamable)
                                            cs_n <= 3'b111;
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
