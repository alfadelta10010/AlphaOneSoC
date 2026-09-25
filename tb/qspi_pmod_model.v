// Behavioural model of the TinyTapeout QSPI Pmod: a W25Q128JV flash on CS0
// and two 8 MB PSRAMs on CS1 (A) and CS2 (B), sharing one quad bus.
//
// It implements exactly the two commands src/qspi_ctrl.v issues, and stops the
// run on anything else, so a protocol mistake in the controller cannot pass
// silently:
//
//   0xEB  quad I/O read   8 cmd bits on IO0, 6 address nibbles, 6 dummy
//                         cycles, then data. On the flash the first two dummy
//                         cycles are the mode byte, which must not be 0xAx
//                         (that would put a real W25Q into continuous-read
//                         mode). Accepted on all three chips.
//   0x38  quad write      8 cmd bits, 6 address nibbles, then data. PSRAM
//                         only: the flash has no such command.
//
// Also checked: exactly one chip selected at a time, the host driving IO
// through the command and address phases, the host and a device never driving
// IO at the same time, and the PSRAM's maximum chip-select-low time.
//
// Data goes out on each falling SCK edge after `+QSPI_DELAY` ns (default 2),
// which stands in for the device's clock-to-output time plus both pad delays.
// qspi_ctrl samples late (one full SCK period after the launching edge), so it
// should tolerate any delay below one SCK period.
//
// Memory: ram[] is the two PSRAMs back to back (A at 0, B at 8 MB), zero-filled.
// flash[] holds the first FLASH_SIZE bytes of flash; reads above that return
// 0, the same as Spike's zero-filled RAM model of the flash window. Load them
// by hierarchical reference or with +FLASH_FILE=.

`timescale 1ns / 1ps

module qspi_pmod_model #(
    parameter FLASH_SIZE = 65536,
    parameter RAM_SIZE   = 16777216,
    parameter TCEM_NS    = 8000        // PSRAM maximum CS-low time
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

    localparam [2:0] P_IDLE = 0, P_CMD = 1, P_ADDR = 2, P_DUMMY = 3, P_RDATA = 4, P_WDATA = 5;

    reg  [2:0]  phase;
    integer delay_ns;
    reg [1023:0] flash_file;
    integer k;
    initial begin
        delay_ns = 2;
        if ($value$plusargs("QSPI_DELAY=%d", delay_ns)) ;
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
    realtime    t_sel;

    wire any_sel = (cs_n != 3'b111);

    function [1:0] which(input [2:0] c);
        which = !c[0] ? 2'd0 : !c[1] ? 2'd1 : 2'd2;
    endfunction

    function [7:0] rd(input [1:0] c, input [23:0] a);
        if (c == 2'd0) rd = (a < FLASH_SIZE) ? flash[a] : 8'h00;
        else           rd = ram[{c == 2'd2, a[22:0]}];
    endfunction

    task fail(input [8*80-1:0] msg);
        begin
            $display("ERROR: qspi_pmod_model: %0s (cs_n=%b cmd=%02h addr=%06h t=%0t)",
                     msg, cs_n, cmd, addr, $time);
            $fatal(1);
        end
    endtask

    // Select / deselect
    always @(cs_n) begin
        if (cs_n != 3'b111 && cs_n != 3'b110 && cs_n != 3'b101 && cs_n != 3'b011)
            fail("more than one chip selected");
        if (any_sel && phase == P_IDLE) begin
            phase = P_CMD;
            n     = 0;
            cmd   = 8'h00;
            chip  = which(cs_n);
            t_sel = $realtime;
        end else if (!any_sel && phase != P_IDLE) begin
            if (chip != 2'd0 && ($realtime - t_sel) > TCEM_NS)
                fail("PSRAM chip select held low longer than tCEM");
            phase = P_IDLE;
            dev_oe <= #(delay_ns) 1'b0;
        end
    end

    // Host -> device, on rising SCK
    always @(posedge sck) if (any_sel) begin
        case (phase)
            P_CMD: begin
                if (!host_oe) fail("host not driving IO0 during the command");
                cmd = {cmd[6:0], host_io[0]};
                n   = n + 1;
                if (n == 8) begin
                    if (cmd != 8'hEB && !(cmd == 8'h38 && chip != 2'd0))
                        fail("unsupported command for this chip");
                    phase = P_ADDR;
                    n     = 0;
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
                    phase = P_RDATA;
                    hi    = 1'b1;
                end
            end
            P_WDATA: begin
                if (!host_oe) fail("host not driving IO during write data");
                if (hi) wbyte[7:4] = host_io;
                else begin
                    wbyte[3:0] = host_io;
                    ram[{chip == 2'd2, addr[22:0]}] = wbyte;
                    addr = addr + 24'd1;
                end
                hi = !hi;
            end
            default: ;
        endcase
    end

    // Device -> host, on falling SCK. The first data nibble goes out after the
    // falling edge that ends the last dummy cycle.
    always @(negedge sck) if (any_sel && phase == P_RDATA) begin
        dev_oe <= #(delay_ns) 1'b1;
        dev_io <= #(delay_ns) (hi ? rd(chip, addr) >> 4 : rd(chip, addr) & 8'h0F);
        if (!hi) addr = addr + 24'd1;
        hi = !hi;
    end

    // Bus contention
    always @(*) if (host_oe && dev_oe) fail("host and device both driving IO");

endmodule
