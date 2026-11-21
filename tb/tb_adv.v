// WO-70 adversarial bench: alphaone_soc booting a tests/soc/adv_*.S program
// from the QSPI Pmod model's flash, with the RP2350 UART model on uart_rx/tx.
// Written from the specs (docs/soc-architecture.md, docs/pins-and-peripherals.md
// 2/6/7/12, docs/boot-contract-4x4.md 1/3/4, WO-68 "Rules the engine enforces"),
// independent of tb_soc_periph's per-test cues.
//
// Mailbox (tests/soc/periph.h): FINISH +0x000 (0x5555 pass, code<<16|0x3333 fail,
// 0x7777 reboot), EVENT +0x7F0, VALUE +0x7F4, VALUE2 +0x7F8.
// The program reports its signature with EVENT 0x5C then VALUE; the bench prints
// "SIG <test> <hex>" so a driver can compare the cache modes (differential oracle).
//
// Always-on checks (every test):
//   * the Pmod model's own (tCEM, page crossing, protocol, setup/hold): $fatal;
//   * a PSRAM read with more than 5 bytes under one CE# low period is a burst;
//     while the program has declared bursts forbidden (EVENT 0xB0, until 0xB1),
//     one is a FAIL (PBURST=0, EN=0 or QSPI_CFG.STREAM=0 must give no bursts);
//   * at every reboot / watchdog reset (rst_soc rising): one clock later
//     ctl_oe = io_oe = 0 (pins released), CACHE_CTL flops 0 while held;
//   * a hang is a FAIL (+MAX_CYCLES, default 40 M).
// Cues:
//   0x34        the program set the UART divisor to VALUE: the RP2350 follows
//   0x51        send VALUE bytes back to back at line rate (pattern (k*7+3)%95+32)
//   0x52        send VALUE bytes with pseudo-random gaps of 0..3 character times
//   0x60        GPIO race: from now, after every W1C store to GPIO IN_IP (+0x1C) the
//               bench toggles gpio_in[7] `gofs` clocks later; gofs = 0,1,..,255 cycling
//   0x61        stop the GPIO race
//   0xB0 / 0xB1 bursts forbidden / allowed; 0xB2: FAIL unless a burst was seen since
//               the last 0xB1 or 0xB2 (the burst scenario really happened)
//   0xC0        expect the next reset (reboot or watchdog) to cut a PSRAM read; the
//               verdict FAILs if it did not (scenario not reached)
//   0x5C        the next VALUE is the signature
// Knobs: +TEST=, +FLASH_FILE=, +MAX_CYCLES=, +CLK_HALF_PS= (default 10000: 50 MHz),
// +RD_LATE (strap), +NO_STREAM (strap), +SEED=; the model's own (+QSPI_DELAY, ...).

`timescale 1ns / 1ps

module tb_adv;
    localparam integer UART_DIV = 4;
    integer half_ps = 10000;
    initial if (!$value$plusargs("CLK_HALF_PS=%d", half_ps)) half_ps = 10000;
    real tclk;
    initial tclk = 2.0 * half_ps / 1000.0;

    reg clk = 1'b0;
    reg rst = 1'b1;
    initial begin #0.001; forever begin #(half_ps / 1000.0) clk = ~clk; end end
    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    reg rd_late = 1'b0, no_stream = 1'b0;
    initial begin rd_late = $test$plusargs("RD_LATE"); no_stream = $test$plusargs("NO_STREAM"); end

    wire       qspi_sck, qspi_ctl_oe, qspi_io_oe, pmod_oe;
    wire [2:0] qspi_cs_n;
    wire [3:0] qspi_io_out, pmod_io;
    wire [3:0] qspi_io_in = pmod_oe ? pmod_io : (qspi_io_oe ? qspi_io_out : 4'bxxxx);
    wire       uart_tx, uart_rts_n, uart_rx;
    wire [7:0] gpio_out, uo;
    reg  [3:0] gin_hi = 4'h0;
    wire [7:0] gpio_in = {gin_hi, uart_rx, 3'b000};

    alphaone_soc #(.UART_DIV_RESET(UART_DIV)) soc (
        .clk(clk), .rst(rst), .qspi_rd_late(rd_late), .qspi_no_stream(no_stream),
        .qspi_sck(qspi_sck), .qspi_cs_n(qspi_cs_n), .qspi_ctl_oe(qspi_ctl_oe),
        .qspi_io_out(qspi_io_out), .qspi_io_oe(qspi_io_oe), .qspi_io_in(qspi_io_in),
        .uart_rx(uart_rx), .uart_tx(uart_tx), .uart_rts_n(uart_rts_n),
        .gpio_in(gpio_in), .gpio_out(gpio_out), .uo(uo));

    qspi_pmod_model pmod (
        .host_sck(qspi_sck), .host_cs_n(qspi_cs_n), .host_ctl_oe(qspi_ctl_oe),
        .host_io(qspi_io_out), .host_oe(qspi_io_oe), .dev_io(pmod_io), .dev_oe(pmod_oe));

    // RP2350: no flow control (the default map has no RTS# pin)
    rp2350_uart_model #(.BIT_NS(16.0 * UART_DIV * 20.0)) rp (
        .tx(uart_tx), .rx(uart_rx), .cts_n(1'b0));
    initial #0.002 rp.set_baud(16.0 * UART_DIV * tclk);

    string  test;
    integer errors = 0;
    reg     done = 1'b0;
    task automatic fail(input string m);
        begin errors = errors + 1; $display("FAIL %s: %s (cycle %0d)", test, m, cyc); end
    endtask

    // ── Burst monitor (pins + the model's byte counter) ──────────────────────
    wire    ps_sel  = qspi_ctl_oe && (qspi_cs_n[2:1] != 2'b11);
    integer prb_at_open = 0, n_burst = 0, n_burst_win = 0, max_rd = 0, n_ps_rd = 0;
    reg     no_burst = 1'b0;
    real    tcem_seen = 0.0;
    always @(posedge ps_sel) prb_at_open = pmod.n_prb;
    always @(negedge ps_sel) begin : bmon
        integer b;
        b = pmod.n_prb - prb_at_open;
        if (b > 0) n_ps_rd = n_ps_rd + 1;
        if (b > max_rd) max_rd = b;
        if (b > 5) begin
            n_burst = n_burst + 1; n_burst_win = n_burst_win + 1;
            if (no_burst) fail($sformatf("a PSRAM read burst of %0d bytes while bursts are forbidden (EN/PBURST/STREAM)", b));
        end
    end

    // ── Reset monitor ────────────────────────────────────────────────────────
    integer n_reset = 0, n_cut_ps = 0, n_cut_burst = 0, want_cut = 0;
    always @(posedge soc.rst_soc) if (!rst) begin
        n_reset = n_reset + 1;
        if (ps_sel) begin
            n_cut_ps = n_cut_ps + 1;
            if (pmod.n_prb - prb_at_open > 4 || soc.cache_pburst) n_cut_burst = n_cut_burst + 1;
        end
        $display("NOTE %s: reset %0d at cycle %0d, PSRAM CE# low %0d, bytes in this CE# %0d, pburst %b en %b",
                 test, n_reset, cyc, ps_sel, pmod.n_prb - prb_at_open, soc.cache_pburst, soc.cache_en);
        @(posedge clk); #1;
        if (qspi_ctl_oe !== 1'b0 || qspi_io_oe !== 1'b0)
            fail($sformatf("reset %0d: QSPI pins not released one clock into the reset (ctl_oe %b io_oe %b)",
                           n_reset, qspi_ctl_oe, qspi_io_oe));
        if (soc.cache_en !== 1'b0 || soc.cache_pburst !== 1'b0)
            fail($sformatf("reset %0d: CACHE_CTL not cleared by the reset", n_reset));
    end
    // interrupts landing on a PSRAM read (coverage of the "during a fill" scenarios)
    integer n_meip = 0, n_meip_fill = 0, n_wdt_pulse = 0, n_wdt_fill = 0;
    always @(posedge soc.meip) if (!rst) begin n_meip = n_meip + 1; if (ps_sel) n_meip_fill = n_meip_fill + 1; end
    always @(posedge clk) if (!rst && soc.wdt_irq) begin
        n_wdt_pulse = n_wdt_pulse + 1; if (ps_sel) n_wdt_fill = n_wdt_fill + 1;
        $display("NOTE %s: watchdog interrupt pulse at cycle %0d, PSRAM CE# low %0d, bytes in this CE# %0d", test, cyc, ps_sel, pmod.n_prb - prb_at_open);
    end
    // while the SoC runs, the chip selects must never be X or float
    always @(posedge clk) if (!rst && !soc.rst_soc && qspi_ctl_oe && ^qspi_cs_n === 1'bx) fail("chip select X");

    // ── Mailbox ──────────────────────────────────────────────────────────────
    wire    mb = soc.dmem_req && soc.dmem_we && soc.dmem_ready && soc.dmem_addr[31:16] == 16'h1002;
    reg [31:0] value = 0, value2 = 0, result = 0;
    reg     sig_next = 1'b0, passed = 1'b0, failed = 1'b0;
    integer n_sig = 0, n_spare = 0;
    reg [31:0] sig = 0;
    integer seed = 1;
    initial if (!$value$plusargs("SEED=%d", seed)) seed = 1;

    task automatic send_n(input integer n, input integer gaps);
        integer k, g;
        begin
            for (k = 0; k < n; k = k + 1) begin
                if (gaps) begin g = {$random(seed)} % 4; repeat (g * 160 * UART_DIV) @(posedge clk); end
                rp.send_byte(8'd32 + ((k * 7 + 3) % 95));
            end
        end
    endtask

    // GPIO race: toggle gpio_in[7] gofs clocks after each W1C of IN_IP
    reg     grace = 1'b0;
    integer gofs = 0, n_tog = 0;
    always @(posedge clk)
        if (!rst && grace && soc.dmem_req && soc.dmem_we && soc.dmem_ready &&
            soc.dmem_addr == 32'h1001_001C) fork : tog
            begin : t1
                integer o;
                o = gofs; gofs = (gofs + 1) % 256;
                repeat (o) @(posedge clk);
                #1 gin_hi[3] = ~gin_hi[3]; n_tog = n_tog + 1;
            end
        join_none

    always @(posedge clk)
        if (!rst && mb && !done) begin
            if (soc.dmem_addr[15:0] == 16'h0000 && soc.dmem_be[1:0] == 2'b11) begin
                if (soc.dmem_wdata[15:0] == 16'h5555) begin passed = 1'b1; done = 1'b1; end
                else if (soc.dmem_wdata[15:0] == 16'h3333) begin failed = 1'b1; result = soc.dmem_wdata; done = 1'b1; end
            end else if (soc.dmem_addr[15:0] == 16'h07F0) begin
                case (soc.dmem_wdata)
                    32'h34: rp.set_baud(16.0 * value * tclk);
                    32'h51: fork send_n(value, 0); join_none
                    32'h52: fork send_n(value, 1); join_none
                    32'h60: begin grace = 1'b1; gofs = 0; end
                    32'h61: grace = 1'b0;
                    32'hB0: no_burst = 1'b1;
                    32'hB1: begin no_burst = 1'b0; n_burst_win = 0; end
                    32'hB2: begin if (n_burst_win == 0) fail("cue B2: no PSRAM burst happened in the window"); n_burst_win = 0; end
                    32'hC0: want_cut = want_cut + 1;
                    32'h5C: sig_next = 1'b1;
                    default: ;
                endcase
            end else if (soc.dmem_addr[15:0] == 16'h07F4) begin
                value = soc.dmem_wdata;
                if (sig_next) begin sig = soc.dmem_wdata; sig_next = 1'b0; n_sig = n_sig + 1;
                    $display("SIG %s %0d %h", test, n_sig, soc.dmem_wdata); end
            end else if (soc.dmem_addr[15:0] == 16'h07F8) value2 = soc.dmem_wdata;
            else if (soc.dmem_addr[15:0] == 16'h07FC) begin
                n_spare = n_spare + 1;
                if (n_spare <= 40) $display("NOTE %s: spare %h (cycle %0d)", test, soc.dmem_wdata, cyc);
            end
        end

    integer max_cycles;
    initial begin
        if (!$value$plusargs("TEST=%s", test)) test = "";
        if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)) max_cycles = 40_000_000;
        repeat (10) @(posedge clk);
        #1 rst = 1'b0;
        while (!done && cyc < max_cycles) @(posedge clk);
        if (!done) fail($sformatf("no FINISH within %0d cycles (pc %h)", max_cycles, soc.cpu.pc));
        else if (failed) fail($sformatf("program check %0d failed (value2 %h, value %h)", result[31:16], value2, value));
        if (want_cut > n_cut_ps)
            fail($sformatf("%0d reset(s) were cued to cut a PSRAM read, %0d did", want_cut, n_cut_ps));
        if (rp.errors != 0) fail($sformatf("%0d RP2350 UART errors", rp.errors));
        $display("NOTE %s: %0d PSRAM reads, %0d bursts (largest %0d bytes), tCEM max %0.1f ns, %0d resets (%0d cut a PSRAM read, %0d a burst), %0d gpio toggles, meip rises %0d (%0d on a PSRAM read)",
                 test, n_ps_rd, n_burst, max_rd, pmod.tcem_max, n_reset, n_cut_ps, n_cut_burst, n_tog, n_meip, n_meip_fill);
        if (errors == 0) $display("PASS tb_adv %s (%0d cycles)", test, cyc);
        else             $display("FAIL tb_adv %s: %0d errors", test, errors);
        $finish;
    end
endmodule
