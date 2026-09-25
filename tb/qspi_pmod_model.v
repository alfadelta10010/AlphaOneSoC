// Behavioural model of the TinyTapeout QSPI Pmod: a W25Q128JV flash on CS0
// and two 8 MB PSRAMs on CS1 (A) and CS2 (B), sharing one quad bus.
//
// It implements the commands src/qspi_ctrl.v issues, and stops the run on
// anything else, so a protocol mistake in the controller cannot pass
// silently:
//
//   0xEB  quad I/O read   8 cmd bits on IO0, 6 address nibbles, 6 dummy
//                         cycles, then data. On the flash the first two dummy
//                         cycles are the mode byte, which must not be 0xAx
//                         (that would put a real W25Q into continuous-read
//                         mode). Accepted on all three chips.
//   0x38  quad write      8 cmd bits, 6 address nibbles, then data. PSRAM
//                         only: on the W25Q128JV-DTR 0x38 is Enter QPI.
//   0x66, 0x99            PSRAM reset enable / reset. Both PSRAMs may be
//                         selected together for these, and for the QPI-form
//                         0xF5 below.
//   0xFF                  flash: continuous-read mode reset / Exit QPI.
//
// Start-up state. The Pmod is shared between designs and not power cycled,
// so it can be handed over in a state the controller does not speak. These
// plusargs start the model in such a state, to check that qspi_ctrl's
// start-up sequence gets it out:
//
//   +PSRAM_QPI=1   both PSRAMs in QPI mode: the only command they then accept
//                  is 0xF5 (Exit QPI) sent in QPI form, as two nibbles.
//   +FLASH_CRM=1   flash in continuous-read mode: it takes the first clocks as
//                  an address, and leaves the mode only on 8 clocks of 1111.
//   +FLASH_QPI=1   flash in QPI mode (W25Q128JV-DTR): leaves it on 0xFF in QPI
//                  form.
//   Any other traffic to a device in one of these states stops the run.
//
// Also checked: at most one chip selected (bar the PSRAM broadcast above),
// the host driving IO through the command and address phases, the host and
// a device never driving IO at the same time, the PSRAM's maximum
// chip-select-low time (tCEM) and every chip's minimum deselect time (tCPH).
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
// by hierarchical reference or with +FLASH_FILE=.

`timescale 1ns / 1ps

module qspi_pmod_model #(
    parameter FLASH_SIZE = 65536,
    parameter RAM_SIZE   = 16777216,
    parameter TCEM_NS    = 8000,       // PSRAM maximum CS-low time
    parameter TCPH_NS    = 18,         // minimum deselect time
    parameter TCHZ_NS    = 7           // chip select high to output released
)(
    input  wire       sck,
    input  wire [2:0] cs_n,
    input  wire [3:0] host_io,
    input  wire       host_oe,
    output reg  [3:0] dev_io,
    output reg        dev_oe
);
    reg [7:0] flash [0:FLASH_SIZE-1];
    reg [7:0] ram   [0:RAM_SIZE-1];

    localparam [2:0] P_IDLE = 0, P_CMD = 1, P_ADDR = 2, P_DUMMY = 3, P_RDATA = 4,
                     P_WDATA = 5, P_IGNORE = 6, P_MODE = 7;

    reg  [2:0]  phase;
    integer delay_ns;
    reg [1023:0] flash_file;
    reg     psram_wrap, psram_qpi, flash_crm, flash_qpi;
    integer k;
    initial begin
        delay_ns = 2;
        if ($value$plusargs("QSPI_DELAY=%d", delay_ns)) ;
        psram_wrap = $test$plusargs("PSRAM_WRAP");
        psram_qpi  = $test$plusargs("PSRAM_QPI");
        flash_crm  = $test$plusargs("FLASH_CRM");
        flash_qpi  = $test$plusargs("FLASH_QPI");
        for (k = 0; k < FLASH_SIZE; k = k + 1) flash[k] = 8'h00;
        for (k = 0; k < RAM_SIZE; k = k + 1)   ram[k]   = 8'h00;
        if ($value$plusargs("FLASH_FILE=%s", flash_file))
            $readmemh(flash_file, flash);
        dev_io = 4'b0000;
        dev_oe = 1'b0;
        phase  = P_IDLE;
    end

    reg  [3:0]  n;          // bits / nibbles / cycles seen in the phase
    reg  [7:0]  cmd;
    reg  [23:0] addr;
    reg  [7:0]  mode;
    reg  [7:0]  wbyte;
    reg         hi;         // next data nibble is the high half of a byte
    reg  [1:0]  chip;       // 0 flash, 1 PSRAM A, 2 PSRAM B
    reg         both;       // both PSRAMs selected (reset broadcast)
    reg         allones;    // every nibble so far was 1111 (flash CRM exit)
    reg         first_nib;  // the next nibble out is the first of the read
    realtime    t_sel, t_desel;
    initial t_desel = -1000.0;

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

    // Is the selected device in a state where it only reads nibbles?
    wire in_qpi = (chip == 2'd0) ? flash_qpi : psram_qpi;

    // Select / deselect
    always @(cs_n) begin
        if (cs_n != 3'b111 && cs_n != 3'b110 && cs_n != 3'b101 && cs_n != 3'b011 &&
            cs_n != 3'b001)
            fail("chip selects in an impossible combination");
        if (any_sel && phase == P_IDLE) begin
            if (($realtime - t_desel) < TCPH_NS)
                fail("chip select high for less than tCPH");
            phase   = P_CMD;
            n       = 0;
            cmd     = 8'h00;
            chip    = which(cs_n);
            both    = (cs_n == 3'b001);
            allones = 1'b1;
            t_sel   = $realtime;
            if (chip == 2'd0 && flash_crm) phase = P_MODE;
        end else if (!any_sel && phase != P_IDLE) begin
            if (chip != 2'd0 && ($realtime - t_sel) > TCEM_NS)
                fail("PSRAM chip select held low longer than tCEM");
            phase   = P_IDLE;
            t_desel = $realtime;
            dev_oe <= #(TCHZ_NS) 1'b0;
        end
    end

    // Host -> device, on rising SCK
    always @(posedge sck) if (any_sel) begin
        case (phase)
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
                if (in_qpi) begin
                    // Two nibbles make the command.
                    cmd = {cmd[3:0], host_io};
                    n   = n + 1;
                    if (n == 2) begin
                        if (chip != 2'd0 && cmd == 8'hF5)      psram_qpi = 1'b0;
                        else if (chip == 2'd0 && cmd == 8'hFF) flash_qpi = 1'b0;
                        else fail("device in QPI mode got something other than its Exit QPI");
                        phase = P_IGNORE;
                    end
                end else begin
                    cmd = {cmd[6:0], host_io[0]};
                    n   = n + 1;
                    if (n == 8) begin
                        n = 0;
                        if (chip != 2'd0 && (cmd == 8'h66 || cmd == 8'h99))
                            phase = P_IGNORE;          // PSRAM reset enable / reset
                        else if (chip == 2'd0 && cmd == 8'hFF && !both)
                            phase = P_IGNORE;          // flash CRM reset / Exit QPI
                        else if (both)
                            fail("both PSRAMs selected for a read or write");
                        else if (cmd == 8'hEB || (cmd == 8'h38 && chip != 2'd0))
                            phase = P_ADDR;
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
                    phase = (cmd == 8'h38) ? P_WDATA : P_DUMMY;
                    n     = 0;
                    hi    = 1'b1;
                end
            end
            P_DUMMY: begin
                if (n < 2) begin
                    if (chip == 2'd0 && !host_oe) fail("host not driving the flash mode byte");
                    mode = {mode[3:0], host_io};
                end
                n = n + 1;
                if (n == 2 && chip == 2'd0 && mode[7:4] == 4'hA)
                    fail("mode byte 0xAx would enter continuous-read mode");
                if (n == 6) begin
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
