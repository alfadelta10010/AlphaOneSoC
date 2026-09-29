// Behavioural model of the TinyTapeout QSPI Pmod: a W25Q128JV flash on CS0
// and two 8 MB PSRAMs on CS1 (A) and CS2 (B), sharing one quad bus.
//
// It implements the commands src/qspi_ctrl.v issues, and stops the run on
// anything else, so a protocol mistake in the controller cannot pass
// silently. SPI form = the 8-bit command on IO0; QPI form = the command as
// two nibbles on IO[3:0]. Address and data are always on IO[3:0].
//
//   flash, SPI mode:
//     0xEB  quad I/O read  6 address nibbles, 6 dummy cycles, data. The first
//                          two dummy cycles are the mode byte M7-0, whose
//                          bits M5-4 must not be 10 (that would put a real
//                          W25Q into continuous-read mode; the other bits are
//                          don't-care, so 0x20 enters it as surely as 0xA0).
//     0xFF                 continuous-read mode reset / Exit QPI (ignored).
//   PSRAM, SPI mode:
//     0xEB  quad read      6 address nibbles, 6 wait cycles, data.
//     0x38  quad write     6 address nibbles, data.
//     0x66, 0x99           reset enable / reset (back to SPI mode).
//     0x35                 Enter Quad (QPI) mode.
//   The PSRAM needs a user-issued reset to finish initialising after power-up
//   (APS6404L datasheet section 7), and 99h resets only when it immediately
//   follows 66h (section 12). So every PSRAM starts out waiting for that reset:
//   until 66h then 99h reach it, anything but 66h, 99h and Exit QPI stops the
//   run. The model insists on it whatever state the chip is handed over in,
//   since the controller cannot know that state.
//   PSRAM, QPI mode (all QPI form):
//     0x0B  fast read      6 address nibbles, 4 wait cycles, data.
//     0x38, 0x02  write    6 address nibbles, data.
//     0x66, 0x99           reset enable / reset (back to SPI mode).
//     0xF5                 Exit Quad mode.
//   Both PSRAMs may be selected together for 0x35, 0x66, 0x99 and 0xF5.
//   0x38 is never accepted by the flash: on the W25Q128JV-DTR it is Enter QPI.
//
// Start-up state. The Pmod is shared between designs and not power cycled,
// so it can be handed over in a state the controller does not speak. These
// plusargs start the model in such a state, to check that qspi_ctrl's
// start-up sequence gets it out:
//
//   +PSRAM_QPI=1   both PSRAMs in QPI mode (commands in QPI form only).
//   +FLASH_CRM=1   flash in continuous-read mode: it takes the first clocks as
//                  an address, and leaves the mode only on 8 clocks of 1111.
//   +FLASH_QPI=1   flash in QPI mode (W25Q128JV-DTR): leaves it on 0xFF in QPI
//                  form.
//   +FLASH_DCRM=1  flash in dual I/O continuous-read mode (BBh with mode bits
//                  M5-4 = 10, W25Q128JV-DTR 8.2.11): it takes the first 12
//                  clocks as an address on IO1:0 and the next 4 as mode bits,
//                  then drives dual data. A window that ends before the mode
//                  bits leaves the mode set; mode bits other than 10 end it.
//   +PSRAM_A_QPI=1, +PSRAM_B_QPI=1
//                  only that PSRAM in QPI mode, as a design that used one chip
//                  leaves them. A broadcast then reaches the two chips in
//                  different forms, and each decodes it as its own mode does.
//   Any other traffic to a device in one of these states stops the run.
//
// Also checked: at most one chip selected (bar the PSRAM broadcast above),
// the host driving IO through the command and address phases, the host and
// a device never driving IO at the same time, the PSRAM's maximum
// chip-select-low time (tCEM), every chip's minimum deselect time (tCPH) and
// the PSRAM's reset time (tRST: 50 ns from the end of 99h to its next
// command, APS6404L table 10).
//
// Pins. The model takes the host's pins with their output enable
// (host_ctl_oe for SCK and the chip selects) and applies what the Pmod does
// to a released pin: the chip selects are pulled up (10k on the Pmod), SCK
// is not and floats -- X here. A chip select may only fall once SCK has
// been driven low for TSCK_CS_NS (mode 0; the flash's /CS setup times are
// 3 ns), so a host that selects a chip on the same edge it starts driving
// SCK -- a clock edge of unknown level -- stops the run. Testbenches connect
// the raw pins and leave this to the model.
//
// +PSRAM_WRAP=1 makes the PSRAMs wrap a read or write at the end of each 1 KB
// page, as a part without row-boundary crossing does (the -3SQN rather than
// the -3SQR). qspi_ctrl must not depend on crossing.
//
// Data goes out on each falling SCK edge after +QSPI_DELAY ns (default 2),
// which stands in for the device's clock-to-output time plus both pad delays.
// The device lets go of the bus TCHZ_NS after chip select rises, not after
// that whole round trip: contention happens at the pins, and the host's next
// drive and the chip select both reach them through the same output pads.
//
// Memory: ram[] is the two PSRAMs back to back (A at 0, B at 8 MB), zero-filled.
// flash[] holds the first FLASH_SIZE bytes of flash; reads above that return
// 0, the same as Spike's zero-filled RAM model of the flash window. Load them
// by hierarchical reference or with +FLASH_FILE=, a path of up to 1023
// characters; a longer one, or a file that cannot be opened, stops the run.

`timescale 1ns / 1ps

module qspi_pmod_model #(
    parameter FLASH_SIZE = 65536,
    parameter RAM_SIZE   = 16777216,
    parameter TCEM_NS    = 8000,       // PSRAM maximum CS-low time
    parameter TCPH_NS    = 18,         // minimum deselect time
    parameter TCHZ_NS    = 7,          // chip select high to output released
    parameter TSCK_CS_NS = 3,          // SCK driven low before chip select falls
    parameter TRST_NS    = 50          // PSRAM: end of 99h to the next command
)(
    input  wire       host_sck,
    input  wire [2:0] host_cs_n,
    input  wire       host_ctl_oe,  // host drives SCK and the chip selects
    input  wire [3:0] host_io,
    input  wire       host_oe,
    output reg  [3:0] dev_io,
    output reg        dev_oe
);
    // The pins as the devices see them (see Pins above).
    wire [2:0] cs_n = host_ctl_oe ? host_cs_n : 3'b111;
    wire       sck  = host_ctl_oe ? host_sck  : 1'bx;

    reg [7:0] flash [0:FLASH_SIZE-1];
    reg [7:0] ram   [0:RAM_SIZE-1];

    localparam [3:0] P_IDLE = 0, P_CMD = 1, P_ADDR = 2, P_DUMMY = 3, P_RDATA = 4,
                     P_WDATA = 5, P_IGNORE = 6, P_MODE = 7,
                     P_DCRM = 8,    // flash in dual continuous-read: address + mode
                     P_DDATA = 9;   // ... and now driving dual data

    reg  [3:0]  phase;
    integer delay_ns;
    // 1024 characters, as tb_rivercore's INIT_FILE: $value$plusargs cuts a
    // longer path short without a word, and $readmemh of the stub only warns.
    reg [8191:0] flash_file;
    integer      flash_fd;
    reg     psram_wrap, flash_crm, flash_qpi, flash_dcrm;
    // Per PSRAM, bit 0 = A (CS1), bit 1 = B (CS2).
    reg [1:0] psram_qpi;    // in QPI mode
    reg [1:0] psram_rst;    // reset since power-up: reads, writes and 35h allowed
    reg [1:0] psram_rsten;  // the last command was Reset Enable (66h)
    reg [1:0] rsten_q;      // psram_rsten as it was when this transaction began
    integer k;
    initial begin
        delay_ns = 2;
        if ($value$plusargs("QSPI_DELAY=%d", delay_ns)) ;
        psram_wrap = $test$plusargs("PSRAM_WRAP");
        psram_qpi  = {$test$plusargs("PSRAM_QPI") || $test$plusargs("PSRAM_B_QPI"),
                      $test$plusargs("PSRAM_QPI") || $test$plusargs("PSRAM_A_QPI")};
        psram_rst  = 2'b00;
        psram_rsten = 2'b00;
        flash_crm  = $test$plusargs("FLASH_CRM");
        flash_qpi  = $test$plusargs("FLASH_QPI");
        flash_dcrm = $test$plusargs("FLASH_DCRM");
        for (k = 0; k < FLASH_SIZE; k = k + 1) flash[k] = 8'h00;
        for (k = 0; k < RAM_SIZE; k = k + 1)   ram[k]   = 8'h00;
        if ($value$plusargs("FLASH_FILE=%s", flash_file)) begin
            // A path that fills the buffer may have been cut short.
            if (flash_file[8191:8184] != 8'h00) begin
                $display("ERROR: qspi_pmod_model: FLASH_FILE path longer than 1023 characters");
                $fatal(1);
            end
            flash_fd = $fopen(flash_file, "r");
            if (flash_fd == 0) begin
                $display("ERROR: qspi_pmod_model: cannot open FLASH_FILE=%0s", flash_file);
                $fatal(1);
            end
            $fclose(flash_fd);
            $readmemh(flash_file, flash);
        end
        dev_io = 4'b0000;
        dev_oe = 1'b0;
        phase  = P_IDLE;
    end

    reg  [4:0]  n;          // bits / nibbles / cycles seen in the phase
    reg  [7:0]  cmd;
    reg  [23:0] addr;
    reg  [7:0]  mode;
    reg  [7:0]  wbyte;
    reg         hi;         // next data nibble is the high half of a byte
    reg  [1:0]  chip;       // 0 flash, 1 PSRAM A, 2 PSRAM B
    reg         both;       // both PSRAMs selected (reset broadcast)
    reg         allones;    // every nibble so far was 1111 (flash CRM exit)
    reg         first_nib;  // the next nibble out is the first of the read
    reg  [3:0]  wait_n;     // dummy / wait cycles before read data
    reg         mixed;      // broadcast to PSRAMs in different modes
    reg  [1:0]  qpi_sel;    // psram_qpi when this transaction began
    reg  [7:0]  cmd_q;      // mixed broadcast: the QPI chip's command
    reg  [1:0]  rst_now;    // PSRAMs reset in this transaction
    realtime    t_sel, t_desel, t_sck;
    realtime    t_rst [0:1];
    initial begin
        t_desel  = -1000.0;
        t_rst[0] = -1000.0;
        t_rst[1] = -1000.0;
    end

    // SCK driven low before a chip select falls (see Pins above). Checked
    // 1 ps after the select, once every update of that time step has landed:
    // SCK and the chip selects change on the same clock edge, and the order
    // the simulator runs their blocks in is not defined.
    event selected;
    always @(sck) t_sck = $realtime;
    always @(selected) begin
        #0.001;
        if (sck !== 1'b0 || (t_sel - t_sck) < TSCK_CS_NS)
            fail("chip select fell before SCK was driven low");
    end

    wire any_sel = (cs_n != 3'b111);

    function [1:0] which(input [2:0] c);
        which = !c[0] ? 2'd0 : !c[1] ? 2'd1 : 2'd2;
    endfunction

    function [23:0] ram_index(input [1:0] c, input [23:0] a);
        ram_index = {c == 2'd2, a[22:0]};
    endfunction

    function [7:0] rd(input [1:0] c, input [23:0] a);
        if (c == 2'd0) rd = (a < FLASH_SIZE) ? flash[a] : 8'h00;
        else           rd = ram[ram_index(c, a)];
    endfunction

    // Next byte address: the PSRAMs wrap at a 1 KB page in wrap mode.
    function [23:0] next_addr(input [1:0] c, input [23:0] a);
        next_addr = (c != 2'd0 && psram_wrap) ? {a[23:10], a[9:0] + 10'd1} : a + 24'd1;
    endfunction

    task fail(input [8*80-1:0] msg);
        begin
            $display("ERROR: qspi_pmod_model: %0s (cs_n=%b cmd=%02h addr=%06h t=%0t)",
                     msg, cs_n, cmd, addr, $time);
            $fatal(1);
        end
    endtask

    // The PSRAMs selected, as a psram_* mask.
    wire [1:0] psel = both ? 2'b11 : (chip == 2'd1) ? 2'b01 : (chip == 2'd2) ? 2'b10 : 2'b00;

    // Is the selected device in a state where it only reads nibbles? (A
    // broadcast to PSRAMs in different modes is decoded per chip: `mixed`.)
    wire in_qpi = (chip == 2'd0) ? flash_qpi : |(psram_qpi & psel);

    // A PSRAM command other than 66h, 99h and Exit QPI: the chip must have
    // had its power-up reset.
    task need_reset(input [1:0] m);
        if ((psram_rst & m) != m)
            fail("PSRAM command before its power-up reset (66h, 99h)");
    endtask

    // 66h: reset enable, for the next command only. 99h right after it:
    // reset, which also returns the chip to SPI mode. A 99h not preceded by
    // 66h is ignored, as on the chip.
    task psram_reset_cmd(input [7:0] c, input [1:0] m);
        if (c == 8'h66)
            psram_rsten = psram_rsten | m;
        else begin
            psram_qpi = psram_qpi & ~(rsten_q & m);
            psram_rst = psram_rst |  (rsten_q & m);
            rst_now   = rst_now   |  (rsten_q & m);
        end
    endtask

    // A command broadcast to both PSRAMs, as the chips in mask m decode it:
    // Exit QPI (a QPI-form command), reset enable, reset, Enter QPI (an
    // SPI-form command). Anything else would make both drive the bus.
    task broadcast_cmd(input [7:0] c, input [1:0] m, input qpi);
        if (qpi && c == 8'hF5)
            psram_qpi = psram_qpi & ~m;
        else if (c == 8'h66 || c == 8'h99)
            psram_reset_cmd(c, m);
        else if (!qpi && c == 8'h35) begin
            need_reset(m);
            psram_qpi = psram_qpi | m;
        end else
            fail("both PSRAMs selected for a read or write");
    endtask

    // Select / deselect
    always @(cs_n) begin
        if (cs_n != 3'b111 && cs_n != 3'b110 && cs_n != 3'b101 && cs_n != 3'b011 &&
            cs_n != 3'b001)
            fail("chip selects in an impossible combination");
        if (any_sel && phase == P_IDLE) begin
            if (($realtime - t_desel) < TCPH_NS)
                fail("chip select high for less than tCPH");
            -> selected;
            phase   = P_CMD;
            n       = 0;
            cmd     = 8'h00;
            chip    = which(cs_n);
            both    = (cs_n == 3'b001);
            allones = 1'b1;
            t_sel   = $realtime;
            qpi_sel = psram_qpi;
            mixed   = both && psram_qpi[0] != psram_qpi[1];
            rst_now = 2'b00;
            if ((!cs_n[1] && ($realtime - t_rst[0]) < TRST_NS) ||
                (!cs_n[2] && ($realtime - t_rst[1]) < TRST_NS))
                fail("PSRAM selected within tRST of its reset");
            // Any command ends a reset enable; 66h sets it again. (From cs_n:
            // psel, a wire, may not have caught up with chip and both yet.)
            rsten_q     = psram_rsten;
            psram_rsten = psram_rsten & cs_n[2:1];
            if (chip == 2'd0 && flash_crm)  phase = P_MODE;
            if (chip == 2'd0 && flash_dcrm) begin
                phase = P_DCRM;
                mode  = 8'h00;
            end
        end else if (!any_sel && phase != P_IDLE) begin
            if (chip != 2'd0 && ($realtime - t_sel) > TCEM_NS)
                fail("PSRAM chip select held low longer than tCEM");
            if (rst_now[0]) t_rst[0] = $realtime;
            if (rst_now[1]) t_rst[1] = $realtime;
            phase   = P_IDLE;
            t_desel = $realtime;
            dev_oe <= #(TCHZ_NS) 1'b0;
        end
    end

    // Flash in dual continuous-read mode, once its address and mode are in:
    // the falling edge after them starts dual data. Checked 1 ps later, so a
    // chip select that rises on that same edge ends the read first.
    always @(negedge sck) if (phase == P_DDATA) begin
        #0.001;
        if (any_sel && phase == P_DDATA)
            fail("flash in dual continuous-read mode drove read data");
    end

    // Host -> device, on rising SCK
    always @(posedge sck) if (any_sel) begin
        case (phase)
            P_DCRM: begin
                // Dual continuous-read: 12 address clocks, then M7-0 two bits
                // a clock. Undriven mode bits are unknown, so they fail.
                n = n + 1;
                if (n > 12)
                    mode = {mode[5:0], host_oe ? host_io[1:0] : 2'bxx};
                if (n == 16) begin
                    if (^mode[5:4] === 1'bx)
                        fail("flash in dual continuous-read mode got undriven mode bits");
                    if (mode[5:4] != 2'b10) flash_dcrm = 1'b0;
                    phase = P_DDATA;
                end
            end
            P_MODE: begin
                // Flash in continuous-read mode: 8 clocks of 1111 end it.
                allones = allones && host_oe && (host_io == 4'b1111);
                n = n + 1;
                if (n == 8) begin
                    if (!allones) fail("flash in continuous-read mode got a command");
                    flash_crm = 1'b0;
                    phase = P_IGNORE;
                end
            end
            P_CMD: begin
                if (!host_oe) fail("host not driving IO during the command");
                if (mixed) begin
                    // Broadcast to PSRAMs in different modes: the QPI chip
                    // takes two nibbles, the SPI chip eight bits on IO0.
                    cmd_q = {cmd_q[3:0], host_io};
                    cmd   = {cmd[6:0], host_io[0]};
                    n     = n + 1;
                    if (n == 2) broadcast_cmd(cmd_q, qpi_sel, 1'b1);
                    if (n == 8) begin
                        broadcast_cmd(cmd, ~qpi_sel, 1'b0);
                        phase = P_IGNORE;
                    end
                end else if (in_qpi) begin
                    // Two nibbles make the command.
                    cmd = {cmd[3:0], host_io};
                    n   = n + 1;
                    if (n == 2) begin
                        n     = 0;
                        phase = P_IGNORE;
                        if (chip == 2'd0) begin
                            if (cmd == 8'hFF) flash_qpi = 1'b0;
                            else fail("flash in QPI mode got something other than its Exit QPI");
                        end else if (cmd == 8'hF5)
                            psram_qpi = psram_qpi & ~psel;   // Exit QPI
                        else if (cmd == 8'h66 || cmd == 8'h99)
                            psram_reset_cmd(cmd, psel);
                        else if (both)
                            fail("both PSRAMs selected for a read or write");
                        else if (cmd == 8'h0B || cmd == 8'h38 || cmd == 8'h02) begin
                            need_reset(psel);
                            phase = P_ADDR;
                        end else
                            fail("unsupported QPI command for the PSRAM");
                    end
                end else begin
                    cmd = {cmd[6:0], host_io[0]};
                    n   = n + 1;
                    if (n == 8) begin
                        n = 0;
                        if (chip != 2'd0 && (cmd == 8'h66 || cmd == 8'h99)) begin
                            psram_reset_cmd(cmd, psel); // PSRAM reset enable / reset
                            phase = P_IGNORE;
                        end else if (chip != 2'd0 && cmd == 8'h35) begin
                            need_reset(psel);
                            psram_qpi = psram_qpi | psel;   // PSRAM Enter Quad mode
                            phase = P_IGNORE;
                        end
                        else if (chip == 2'd0 && cmd == 8'hFF && !both)
                            phase = P_IGNORE;          // flash CRM reset / Exit QPI
                        else if (both)
                            fail("both PSRAMs selected for a read or write");
                        else if (cmd == 8'hEB || (cmd == 8'h38 && chip != 2'd0)) begin
                            if (chip != 2'd0) need_reset(psel);
                            phase = P_ADDR;
                        end
                        else
                            fail("unsupported command for this chip");
                    end
                end
            end
            P_ADDR: begin
                if (!host_oe) fail("host not driving IO during the address");
                addr = {addr[19:0], host_io};
                n    = n + 1;
                if (n == 6) begin
                    phase  = (cmd == 8'h38 || cmd == 8'h02) ? P_WDATA : P_DUMMY;
                    // Wait cycles: 4 for the PSRAM's QPI 0x0B, 6 for 0xEB.
                    wait_n = (cmd == 8'h0B) ? 4'd4 : 4'd6;
                    n      = 0;
                    hi     = 1'b1;
                end
            end
            P_DUMMY: begin
                if (n < 2) begin
                    if (chip == 2'd0 && !host_oe) fail("host not driving the flash mode byte");
                    mode = {mode[3:0], host_io};
                end
                n = n + 1;
                if (n == 2 && chip == 2'd0 && mode[5:4] == 2'b10)
                    fail("mode bits M5-4 = 10 would enter continuous-read mode");
                if (n == wait_n) begin
                    phase     = P_RDATA;
                    hi        = 1'b1;
                    first_nib = 1'b1;
                end
            end
            P_WDATA: begin
                if (!host_oe) fail("host not driving IO during write data");
                if (hi) wbyte[7:4] = host_io;
                else begin
                    wbyte[3:0] = host_io;
                    ram[ram_index(chip, addr)] = wbyte;
                    addr = next_addr(chip, addr);
                end
                hi = !hi;
            end
            default: ;
        endcase
    end

    // Device -> host, on falling SCK. The first data nibble goes out after the
    // falling edge that ends the last dummy cycle.
    // Each nibble lands delay_ns later. Only the first of a read turns the
    // device's output on; chip select rising turns it off after TCHZ_NS. So
    // the nibble launched by the falling edge that deselects the chip -- which
    // lands after the release -- changes dev_io but never drives the pins.
    always @(negedge sck) if (any_sel && phase == P_RDATA) begin
        if (first_nib) dev_oe <= #(delay_ns) 1'b1;
        dev_io <= #(delay_ns) (hi ? rd(chip, addr) >> 4 : rd(chip, addr) & 8'h0F);
        if (!hi) addr = next_addr(chip, addr);
        hi = !hi;
        first_nib = 1'b0;
    end

    // Bus contention
    always @(*) if (host_oe && dev_oe) fail("host and device both driving IO");

endmodule
