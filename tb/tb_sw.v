// Software bench: the whole SoC at the chip's clock, booting a flash image
// from the behavioural QSPI Pmod (+FLASH_FILE=<hex>, see sw/tools/mkflash.py),
// with a UART decoder on the TX pin and a watcher on syscon's FINISH.
//
// This is the bench for the software ladder (docs/ROADMAP.md section 9): the
// program's UART text goes to stdout, at the baud rate the program set, and
// the run ends on a FINISH store:
//
//   SW-RESULT: PASS cycles=<n> instret=<n>
//   SW-RESULT: FAIL code=<n> cycles=<n> instret=<n>
//   SW-RESULT: TIMEOUT cycles=<n> instret=<n>      (+MAX_CYCLES, default 2e9, any 64-bit value)
//
// The UART decoder checks every frame (start bit mid-point, stop bit) and
// reports a framing error as an ERROR line. The memory and bus request
// checks are those of the other SoC benches (tb/req_hold_check.v).
//
// An SD card (tb/sd_spi_model.v) sits on the SPI pins as on the demo board (CS# gpio_out[7],
// SCK [3], MOSI [1], DO gpio_in[1]). +SD_IMAGE=<byte-hex> gives it a disk (sw/tools/mkdisk.sh);
// +SD_DUMP=<file> writes the disk out when the run ends, for the host to check. A card error
// (SD model `errors`) turns a PASS into a FAIL.
//
// +UART_IN=<hex> feeds the chip's UART receiver (sw/tools/mkscript.py builds the file
// from a script): each step waits until the program's output ends in a given text, then
// sends a line at the baud rate the program has set. That is how the monitor is driven.
//
// Both simulators build it; Verilator needs --timing for the Pmod model's
// delays (sw/Makefile).
`timescale 1ns / 1ps

`ifndef TCLK_NS
`define TCLK_NS 16.0                     // 62.5 MHz, the chip clock (ROADMAP section 0)
`endif

module tb_sw;
    localparam real TCLK = `TCLK_NS;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #(TCLK / 2.0) clk = ~clk;
    reg [63:0] cyc = 64'd0;            // 64 bits: a run of more than 2^31 clocks (34 s of chip time) is legal
    always @(posedge clk) cyc <= cyc + 1;

    wire       qspi_sck, qspi_ctl_oe, qspi_io_oe, pmod_oe;
    wire [2:0] qspi_cs_n;
    wire [3:0] qspi_io_out, pmod_io;
    wire [3:0] qspi_io_in = pmod_oe ? pmod_io : (qspi_io_oe ? qspi_io_out : 4'bxxxx);
    wire       uart_tx, uart_rts_n;
    reg        uart_rx_r = 1'b1;
    wire [7:0] gpio_out;
    tri1       sd_do;
    wire [7:0] gpio_in = {6'b000000, sd_do, 1'b0};

    // The chip's own reset divisor (34); software sets the one it wants. Flash streaming
    // is on, as it is by default (the strap pin low).
    alphaone_soc soc (
        .clk(clk), .rst(rst), .qspi_no_stream(1'b0), .qspi_rd_late(1'b0),
        .qspi_sck(qspi_sck), .qspi_cs_n(qspi_cs_n), .qspi_ctl_oe(qspi_ctl_oe),
        .qspi_io_out(qspi_io_out), .qspi_io_oe(qspi_io_oe), .qspi_io_in(qspi_io_in),
        .uart_rx(uart_rx_r), .uart_tx(uart_tx), .uart_rts_n(uart_rts_n),
        .gpio_in(gpio_in), .gpio_out(gpio_out));

    qspi_pmod_model pmod (
        .host_sck(qspi_sck), .host_cs_n(qspi_cs_n), .host_ctl_oe(qspi_ctl_oe),
        .host_io(qspi_io_out), .host_oe(qspi_io_oe), .dev_io(pmod_io), .dev_oe(pmod_oe));

    sd_spi_model #(.DISK_BLKS(8192)) sd (
        .fitted(1'b1), .cs_n(gpio_out[7]), .sck(gpio_out[3]), .di(gpio_out[1]),
        .expect_violations(1'b0), .do_o(sd_do));
    reg [8*1024-1:0] sd_name;
    initial if ($value$plusargs("SD_IMAGE=%s", sd_name)) begin
        $readmemh(sd_name, sd.disk);
        sd.use_disk = 1'b1;
    end
    // +UART_DIV=<n>: the divisor the program has set when the run ends must be n (the boot contract's
    // rate, ROADMAP 9.1 rule 2). The decoder follows whatever the program sets, so without this a
    // wrong divisor in the loader would still print readable text.
    integer exp_div;
    task sd_finish;
        begin
            if ($value$plusargs("UART_DIV=%d", exp_div) && {soc.uart_inst.dlm, soc.uart_inst.dll} != exp_div[15:0]) begin
                uart_errors = uart_errors + 1;
                $display("ERROR uart: divisor %0d at the end, want %0d", {soc.uart_inst.dlm, soc.uart_inst.dll}, exp_div);
            end
            if ($value$plusargs("SD_DUMP=%s", sd_name)) $writememh(sd_name, sd.disk);
            if (sd.n_cmd != 0)
                $display("SD: %0d commands, %0d blocks read, %0d written, %0d errors",
                         sd.n_cmd, sd.n_rd_blk, sd.n_wr_blk, sd.errors);
        end
    endtask

    reg done = 1'b0;
    req_hold_check #(.W(69), .NAME("dmem request")) chk_dmem (
        .clk(clk), .rst(rst || done), .take(soc.dmem_req), .hold(soc.dmem_req), .done(soc.dmem_ready),
        .payload({soc.dmem_addr, soc.dmem_we, soc.dmem_be, soc.dmem_we ? soc.dmem_wdata : 32'h0}));
    req_hold_check #(.W(32), .NAME("imem request")) chk_imem (
        .clk(clk), .rst(rst || done), .take(soc.imem_req), .hold(soc.imem_req), .done(soc.imem_ready),
        .payload(soc.imem_addr));

    // ── UART decoder: 8N1 at 16 x divisor clocks per bit ────────────────────
    integer uart_errors = 0, uart_bytes = 0;
    reg [7:0] ub;
    real      bit_ns, t_start;
    integer   k;
    reg [8*32-1:0] tail = 0;        // the last 32 characters the program sent
    initial begin
        #1;
        forever begin
            @(negedge uart_tx);
            if (!rst && !done) begin
                bit_ns = 16.0 * {soc.uart_inst.dlm, soc.uart_inst.dll} * TCLK;
                #(bit_ns * 0.5);
                if (uart_tx !== 1'b0) begin
                    uart_errors = uart_errors + 1;
                    $display("ERROR uart: start bit glitch (cycle %0d)", cyc);
                end else begin
                    for (k = 0; k < 8; k = k + 1) begin
                        #(bit_ns);
                        ub[k] = uart_tx;
                    end
                    #(bit_ns);
                    if (uart_tx !== 1'b1) begin
                        uart_errors = uart_errors + 1;
                        $display("ERROR uart: framing error (cycle %0d)", cyc);
                    end
                    uart_bytes = uart_bytes + 1;
                    $write("%c", ub);
                    tail = {tail[8*31-1:0], ub};
                end
            end
        end
    end

    // ── UART input: steps of {wait length, wait text, send length, send bytes}, ───
    // ended by a wait length of 255.
    reg [7:0] sc [0:8191];
    reg [8*1024-1:0] in_name;
    // Its own loop variables: the decoder above runs at the same time, and a variable they
    // shared made each loop advance the other's index (Icarus then saw framing errors).
    integer pos, wl, sl, i, kk;
    reg [8*32-1:0] pat;
    reg [7:0] sb;
    real in_ns;
    initial begin
        if ($value$plusargs("UART_IN=%s", in_name)) begin
            $readmemh(in_name, sc);
            pos = 0;
            wl = sc[0];
            while (wl != 255) begin
                pos = pos + 1;
                pat = 0;
                for (i = 0; i < wl; i = i + 1) pat = {pat[8*31-1:0], sc[pos + i]};
                pos = pos + wl;
                sl = sc[pos]; pos = pos + 1;
                while ((tail << (8 * (32 - wl))) != (pat << (8 * (32 - wl))) || rst)
                    @(posedge clk);
                #1;                           // off the clock edge, as the reset release (below)
                tail = 0;
                for (i = 0; i < sl; i = i + 1) begin
                    sb = sc[pos + i];
                    if ($test$plusargs("RXTRACE")) $display("TB-RX send %02x cyc %0d", sb, cyc);
                    in_ns = 16.0 * {soc.uart_inst.dlm, soc.uart_inst.dll} * TCLK;
                    uart_rx_r = 1'b0; #(in_ns);
                    for (kk = 0; kk < 8; kk = kk + 1) begin uart_rx_r = sb[kk]; #(in_ns); end
                    uart_rx_r = 1'b1; #(in_ns * 2.0);
                end
                pos = pos + sl;
                wl = sc[pos];
            end
        end
    end

    // ── Run control ─────────────────────────────────────────────────────────
    reg [63:0] max_cycles = 64'd2000000000;
    reg [63:0] instret = 64'd0;
    always @(posedge clk) if (!rst && soc.cpu.dbg_retired) instret <= instret + 1;

    initial begin
        if ($value$plusargs("MAX_CYCLES=%d", max_cycles)) ;
        repeat (10) @(posedge clk);
        // Not at the edge itself: the DUT's flops and this process would race, and the
        // simulators resolve that differently (Verilator released the QSPI pins a clock
        // earlier than Icarus). A board releases reset a little after the edge.
        #1 rst = 1'b0;
    end

    wire fin = soc.dmem_req && soc.dmem_we && soc.dmem_ready &&
               soc.dmem_addr == 32'h1002_0000 && soc.dmem_be[1:0] == 2'b11;
    always @(posedge clk) begin
        if (!rst && !done) begin
            if (fin && (soc.dmem_wdata[15:0] == 16'h5555 || soc.dmem_wdata[15:0] == 16'h3333)) begin
                done = 1'b1;
                $write("\n");
                sd_finish;
                if (soc.dmem_wdata[15:0] == 16'h5555 && uart_errors == 0 && sd.errors == 0)
                    $display("SW-RESULT: PASS cycles=%0d instret=%0d", cyc, instret);
                else
                    $display("SW-RESULT: FAIL code=%0d cycles=%0d instret=%0d",
                             soc.dmem_wdata[15:0] == 16'h5555 ? 0 : soc.dmem_wdata[31:16], cyc, instret);
                $finish;
            end else if (cyc >= max_cycles) begin
                done = 1'b1;
                $write("\n");
                $display("SW-RESULT: TIMEOUT cycles=%0d instret=%0d", cyc, instret);
                $finish;
            end
        end
    end
endmodule
