// Golden-reference bench for the UP5K twin: fpga_top (tapeout wrapper + picorv32 core) on its pins, the
// repo's QSPI Pmod model (flash + 2 PSRAM) on uio and its RP2350 UART model on uo_out[4] / ui_in[3],
// both from the pin (git archive $PIN tb). The firmware image is loaded as the flash content.
//
//   defines:  -DF_HZ=<core clock Hz>   (the clock period and the UART bit time follow from it)
//   plusargs: +FLASH_FILE=<hex>   +GOLDEN=<transcript path>   +MAXCYC=<cycles>
//
// The UART transcript is written byte by byte to the +GOLDEN file; the run ends on a line that starts
// with "ALL PASS" or "FAILED", or at +MAXCYC cycles.
`timescale 1ns / 1ps
`ifndef F_HZ
`define F_HZ 20000000
`endif
module tb_up5k;
    localparam real    TCLK = 1.0e9 / `F_HZ;
    localparam integer DIV  = (`F_HZ + 8 * 115200) / (16 * 115200);

    reg clk = 1'b0;
    always #(TCLK / 2.0) clk = ~clk;
    reg rst_n = 1'b0;
    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    wire       uart_rx;
    wire [7:0] ui_in = {4'b0000, uart_rx, 3'b000};      // straps (ui_in[0], ui_in[2]) = 0
    wire [7:0] uo_out;
    tri  [7:0] uio;

    fpga_top dut (.clk(clk), .rst_n(rst_n), .ui_in(ui_in), .uo_out(uo_out), .uio(uio));

    // the Pmod: chip selects pulled up (10k on the Pmod), SCK floats; SD0..SD3 are uio[1], [2], [4], [5]
    // (iverilog resolves a weak pull-up against a strong 0 on an SB_IO pin to X, so the pull-up is a function)
    // The Pmod model only watches the pins once the SoC is out of reset (`armed`): with random power-up flops
    // (scripts/run_vl_rand.sh) the pins glitch before the first reset edge, which the ASIC does too and which the
    // model's SCK-before-CS check would flag. Pins are hi-Z/high to the model until then.
    reg armed = 1'b0;
    wire [2:0] cs_pin_raw = {uio[7] === 1'bz ? 1'b1 : uio[7], uio[6] === 1'bz ? 1'b1 : uio[6], uio[0] === 1'bz ? 1'b1 : uio[0]};
    wire [2:0] cs_pin = armed ? cs_pin_raw : 3'b111;
    wire [7:0] oe = dut.uio_oe;
    wire [3:0] sd_pin = {uio[5], uio[4], uio[2], uio[1]};
    wire [3:0] sd_oe  = {oe[5], oe[4], oe[2], oe[1]};
    wire [3:0] host_io = {sd_oe[3] ? sd_pin[3] : 1'bx, sd_oe[2] ? sd_pin[2] : 1'bx,
                          sd_oe[1] ? sd_pin[1] : 1'bx, sd_oe[0] ? sd_pin[0] : 1'bx};
    wire [3:0] pmod_io;
    wire       pmod_oe;
    assign uio[1] = pmod_oe ? pmod_io[0] : 1'bz;
    assign uio[2] = pmod_oe ? pmod_io[1] : 1'bz;
    assign uio[4] = pmod_oe ? pmod_io[2] : 1'bz;
    assign uio[5] = pmod_oe ? pmod_io[3] : 1'bz;
    qspi_pmod_model pmod (
        .host_sck(uio[3]), .host_cs_n(cs_pin), .host_ctl_oe(armed & oe[3]),
        .host_io(host_io), .host_oe(&sd_oe), .dev_io(pmod_io), .dev_oe(pmod_oe));

    rp2350_uart_model #(.BIT_NS(16.0 * DIV * TCLK)) rp (.tx(uo_out[4]), .rx(uart_rx), .cts_n(1'b0));

    // reset: clock running, rst_n low for 8 clocks (the SoC needs the second edge after release)
    initial begin
        repeat (8) @(posedge clk);
        #(TCLK / 4.0) rst_n = 1'b1;
        repeat (2) @(posedge clk);
        armed = 1'b1;
    end

    // +HB=<n>: progress line every n cycles (cycle, last fetch address, last data address)
    integer hb = 0;
    reg [31:0] last_if = 0, last_d = 0;
    initial if (!$value$plusargs("HB=%d", hb)) hb = 0;
    always @(posedge clk) begin
        if (dut.u_dut.soc.cpu.p_valid && dut.u_dut.soc.cpu.p_instr)  last_if <= dut.u_dut.soc.cpu.p_addr;
        if (dut.u_dut.soc.cpu.p_valid && !dut.u_dut.soc.cpu.p_instr) last_d  <= dut.u_dut.soc.cpu.p_addr;
        if (hb != 0 && cyc % hb == 0 && cyc != 0) $display("HB cyc=%0d pc=%h data=%h", cyc, last_if, last_d);
    end

    // transcript
    integer fd, shown = 0, maxcyc;
    reg [8*128-1:0] gpath;
    reg done = 1'b0;
    initial begin
        if (!$value$plusargs("GOLDEN=%s", gpath)) gpath = "golden.txt";
        if (!$value$plusargs("MAXCYC=%d", maxcyc)) maxcyc = 200_000_000;
        fd = $fopen(gpath, "w");
    end
    reg [7:0] ch;
    always @(posedge clk) if (!done && shown < rp.rx_n) begin
        ch = rp.rx_buf[shown % 16384];
        shown = shown + 1;
        $fwrite(fd, "%c", ch); $fflush(fd);
        $write("%c", ch);
    end
    // end-of-run: the last complete line is ALL PASS or starts with FAILED
    reg [7:0] c0, c1;
    integer   last_start;
    always @(posedge clk) if (!done && shown > 0 && rp.rx_buf[(shown - 1) % 16384] == 8'h0A) begin
        // find the start of the last line
        last_start = shown - 1;
        while (last_start > 0 && rp.rx_buf[(last_start - 1) % 16384] != 8'h0A) last_start = last_start - 1;
        c0 = rp.rx_buf[last_start % 16384]; c1 = rp.rx_buf[(last_start + 1) % 16384];
        if ((c0 == "A" && c1 == "L") || (c0 == "F" && c1 == "A" && rp.rx_buf[(last_start + 2) % 16384] == "I" &&
             rp.rx_buf[(last_start + 3) % 16384] == "L" && rp.rx_buf[(last_start + 4) % 16384] == "E")) begin
            done = 1'b1;
            repeat (50) @(posedge clk);
            $display("SIM DONE cycles=%0d uart_errors=%0d bad_frames=%0d", cyc, rp.errors, rp.rx_frames_bad);
            $fclose(fd);
            $finish;
        end
    end
    always @(posedge clk) if (cyc >= maxcyc && !done) begin
        done = 1'b1;
        $display("\nSIM TIMEOUT cycles=%0d", cyc);
        $fclose(fd);
        $finish;
    end
endmodule
