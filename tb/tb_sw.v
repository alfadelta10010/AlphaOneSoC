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
//   SW-RESULT: TIMEOUT cycles=<n> instret=<n>      (+MAX_CYCLES, default 2e9)
//
// The UART decoder checks every frame (start bit mid-point, stop bit) and
// reports a framing error as an ERROR line. The memory and bus request
// checks are those of the other SoC benches (tb/req_hold_check.v).
//
// Both simulators build it; Verilator needs --timing for the Pmod model's
// delays (sw/Makefile).
`timescale 1ns / 1ps

`ifndef TCLK_NS
`define TCLK_NS 16.6667                  // 60 MHz, the chip clock (ROADMAP section 0)
`endif

module tb_sw;
    localparam real TCLK = `TCLK_NS;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #(TCLK / 2.0) clk = ~clk;
    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    wire       qspi_sck, qspi_ctl_oe, qspi_io_oe, pmod_oe;
    wire [2:0] qspi_cs_n;
    wire [3:0] qspi_io_out, pmod_io;
    wire [3:0] qspi_io_in = pmod_oe ? pmod_io : (qspi_io_oe ? qspi_io_out : 4'bxxxx);
    wire       uart_tx, uart_rts_n;
    wire [7:0] gpio_out;
    wire [7:0] gpio_in = 8'h00;

    // The chip's own reset divisor (27); software sets the one it wants.
    alphaone_soc #(.UART_DIV_RESET(27)) soc (
        .clk(clk), .rst(rst), .qspi_rd_late(1'b0),
        .qspi_sck(qspi_sck), .qspi_cs_n(qspi_cs_n), .qspi_ctl_oe(qspi_ctl_oe),
        .qspi_io_out(qspi_io_out), .qspi_io_oe(qspi_io_oe), .qspi_io_in(qspi_io_in),
        .uart_rx(1'b1), .uart_tx(uart_tx), .uart_rts_n(uart_rts_n),
        .gpio_in(gpio_in), .gpio_out(gpio_out));

    qspi_pmod_model pmod (
        .host_sck(qspi_sck), .host_cs_n(qspi_cs_n), .host_ctl_oe(qspi_ctl_oe),
        .host_io(qspi_io_out), .host_oe(qspi_io_oe), .dev_io(pmod_io), .dev_oe(pmod_oe));

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
                end
            end
        end
    end

    // ── Run control ─────────────────────────────────────────────────────────
    integer max_cycles = 2000000000;
    integer instret = 0;
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
                if (soc.dmem_wdata[15:0] == 16'h5555 && uart_errors == 0)
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
