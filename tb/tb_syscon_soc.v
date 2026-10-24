// syscon through the whole SoC: alphaone_soc (with the reset generator in it)
// booting a program from the QSPI Pmod model's flash, the RP2350's UART on
// the UART pins, and the strap pin driving both qspi_rd_late and gpio_in[0]
// as the TinyTapeout wrapper does.
//
// The bench keeps its own model of the syscon state -- RESET_CAUSE,
// BOOT_MODE, the latched strap, the reboot / power-off hold and the
// watchdog -- written from tb/syscon_spec.vh, build/wo/WO-14 (requirements,
// assumptions A1-A18) and the docs, not from src/syscon.v. It is updated
// from what it sees at the core's data port and the pins:
//
//   * every syscon load the core makes (lanes in dmem_be) must read what the
//     model holds: FAIL "syscon load +<off>: got <g>, want <w>";
//   * rst_soc must be high exactly while the model says the SoC is held (the
//     pin reset; two edges after an acting FINISH store or a watchdog fire
//     it predicted; from the edge after a power-off store until rst); the
//     watchdog is predicted from soc.mtime[29:14] (A17) to the cycle;
//   * while the SoC is held after its first reset edge the pins sit at their
//     reset values and nothing is on the buses; the first fetch after every
//     reset is at 0x2000_0000 and returns flash word 0.
//
// Programs (tests/soc/syscon_*.S) talk to the bench through the mailbox in
// the syscon window (tests/soc/periph.h): FINISH at +0x0, EVENT / VALUE /
// VALUE2 at +0x7F0 / +0x7F4 / +0x7F8. +TEST=<name> picks the per-test
// expectations, +FLASH_FILE=<hex> (read by the Pmod model) the program,
// +MAX_CYCLES=<n> the time limit, +RD_LATE the strap run (the strap is 1
// through the pin reset and 0 from the first edge after it).
//
// Verdict at the end: the expected FINISH sequence, every reboot checked, and
// after a pass / fail store the SoC held for 200 clocks with the pins at
// their reset values.

`timescale 1ns / 1ps
`include "syscon_spec.vh"

module tb_syscon_soc;
    localparam real    TCLK     = 20.0;
    localparam integer UART_DIV = 4;
    localparam integer HOLD_CLOCKS = 200;     // power-off hold checked after the verdict

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #(TCLK / 2.0) clk = ~clk;
    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    // ── The SoC and the QSPI Pmod ───────────────────────────────────────────
    reg        strap = 1'b0;                  // drives qspi_rd_late and gpio_in[0]
    reg  [7:0] tb_in = 8'h00;
    wire       qspi_sck, qspi_ctl_oe, qspi_io_oe, pmod_oe;
    wire [2:0] qspi_cs_n;
    wire [3:0] qspi_io_out, pmod_io;
    wire [3:0] qspi_io_in = pmod_oe ? pmod_io : (qspi_io_oe ? qspi_io_out : 4'bxxxx);
    wire       uart_tx, uart_rts_n, uart_rx;
    wire [7:0] gpio_out;
    wire [7:0] gpio_in = {tb_in[7:4], uart_rx, tb_in[2:1], strap};

    // No override of syscon's CHIP_ID: syscon_regs reads the one the chip ships.
    alphaone_soc #(.UART_DIV_RESET(UART_DIV)) soc (
        .clk(clk), .rst(rst), .qspi_rd_late(strap),
        .qspi_sck(qspi_sck), .qspi_cs_n(qspi_cs_n), .qspi_ctl_oe(qspi_ctl_oe),
        .qspi_io_out(qspi_io_out), .qspi_io_oe(qspi_io_oe), .qspi_io_in(qspi_io_in),
        .uart_rx(uart_rx), .uart_tx(uart_tx), .uart_rts_n(uart_rts_n),
        .gpio_in(gpio_in), .gpio_out(gpio_out));

    qspi_pmod_model pmod (
        .host_sck(qspi_sck), .host_cs_n(qspi_cs_n), .host_ctl_oe(qspi_ctl_oe),
        .host_io(qspi_io_out), .host_oe(qspi_io_oe), .dev_io(pmod_io), .dev_oe(pmod_oe));

    rp2350_uart_model #(.BIT_NS(16.0 * UART_DIV * TCLK)) rp (
        .tx(uart_tx), .rx(uart_rx), .cts_n(uart_rts_n));

    // ── Handshake checkers (tb_rivercore.v's SOC_TB hookups) ────────────────
    // Reset by the pin reset and by the SoC reset: a reboot cuts whatever the
    // core had outstanding.
    wire chk_rst = rst || soc.rst_soc;
    req_hold_check #(.W(32), .NAME("imem request")) chk_imem (
        .clk(clk), .rst(chk_rst), .take(soc.imem_req), .hold(soc.imem_req),
        .done(soc.imem_ready), .payload(soc.imem_addr));
    req_hold_check #(.W(69), .NAME("dmem request")) chk_dmem (
        .clk(clk), .rst(chk_rst), .take(soc.dmem_req), .hold(soc.dmem_req),
        .done(soc.dmem_ready),
        .payload({soc.dmem_addr, soc.dmem_we, soc.dmem_be, soc.dmem_we ? soc.dmem_wdata : 32'h0}));
    req_hold_check #(.W(69), .NAME("mem_ctrl data request")) chk_memd (
        .clk(clk), .rst(chk_rst), .take(soc.memc.d_req), .hold(soc.memc.d_req),
        .done(soc.memc.d_ready),
        .payload({soc.memc.d_addr, soc.memc.d_we, soc.memc.d_be,
                  soc.memc.d_we ? soc.memc.d_wdata : 32'h0}));
    req_hold_check #(.W(61), .NAME("QSPI transaction"), .DONE_NEEDS_REQ(1), .LATE(1)) chk_qspi (
        .clk(clk), .rst(chk_rst), .take(soc.qspi.idle && soc.qspi.start),
        .hold(soc.qspi.start), .done(soc.qspi.done),
        .payload({soc.qspi.cs_sel, soc.qspi.addr, soc.qspi.we, soc.qspi.nbytes_m1,
                  soc.qspi.we ? soc.qspi.wdata : 32'h0}));

    integer errors = 0;
    task automatic fail(input string m);
        begin
            errors = errors + 1;
            if (errors <= 40) $display("FAIL %s (cycle %0d)", m, cyc);
        end
    endtask

    // ── Per-test expectations ───────────────────────────────────────────────
    string  test;
    integer exp_fin_reboots = 0;     // FINISH 0x7777 stores
    integer exp_wdt_reboots = 0;     // watchdog expiries
    integer exp_events      = 0;     // EVENT stores
    integer exp_values      = 0;     // VALUE stores
    reg     fin_noise_ok    = 1'b0;  // non-acting stores to FINISH are on purpose
    reg     fail_expected   = 1'b0;  // the program ends in a FINISH fail store
    reg [15:0] exp_fail_code = 16'h0;
    integer max_cycles;

    // ── Syscon model ────────────────────────────────────────────────────────
    reg  [2:0]  m_cause = `RC_PIN;
    reg  [7:0]  m_bm    = 8'h00;
    reg         m_strap = 1'b0;
    integer     m_hold  = 0;             // reboot edges left
    reg         m_off   = 1'b0;          // power-off / fail: held until rst
    reg         m_en    = 1'b0;          // watchdog
    reg  [3:0]  m_top   = `WDT_TOP_RESET;
    integer     m_ticks = 0;
    reg         m_tprev = 1'b1;
    integer     last_clear = 0;          // cycle of the last kick, enable or TORR write
    integer     why = 0;                 // what caused the current hold: 1 FINISH reboot,
                                         // 2 watchdog, 3 pass, 4 fail
    wire [15:0] tap = soc.mtime[29:14];  // A17

    // SoC-side signals of the core's syscon accesses (pre-edge values when
    // sampled in the clocked block).
    wire        sc_acc = (soc.dmem_req === 1'b1) && (soc.dmem_ready === 1'b1) &&
                         (soc.dmem_addr[31:16] === 16'h1002);
    wire        sc_wr  = sc_acc && (soc.dmem_we === 1'b1);
    wire        sc_rd  = sc_acc && (soc.dmem_we === 1'b0);

    function automatic [31:0] model_word(input [15:0] off);   // byte offset, word aligned
        begin
            if      (off == `SYS_CAUSE)    model_word = {29'b0, m_cause};
            else if (off == `SYS_BOOTMODE) model_word = {24'b0, m_bm};
            else if (off == `SYS_CHIPID)   model_word = `CHIP_ID_SPEC;
            else if (off == `SYS_STRAPS)   model_word = {31'b0, m_strap};
            else if (off == `WDT_CR)       model_word = {31'b0, m_en};
            else if (off == `WDT_TORR)     model_word = {24'b0, m_top, m_top};
            else if (off == `WDT_COMP1)    model_word = `WDT_COMP1_VAL;
            else                           model_word = 32'h0;   // FINISH, reserved, mailbox, everything else
        end
    endfunction

    // ── Bench state ─────────────────────────────────────────────────────────
    reg     done = 1'b0, passed = 1'b0, failed = 1'b0, abort = 1'b0;
    integer post_done = 0;
    reg [15:0] fail_code = 16'h0;
    reg [31:0] value = 0, value2 = 0;
    integer n_fin = 0, n_wdt = 0, n_off = 0;        // reboots by FINISH / watchdog, power-offs
    integer n_loads = 0, n_stores = 0, n_events = 0, n_values = 0;
    integer cls_rb [0:3];                           // bus state at the reset of each reboot
    integer cls_all [0:3];                          // ... and of every reset (power-off too)
    integer n_cut = 0;                              // reboots that cut a flash read
    integer ev_cls = 0;                             // class sampled at E1 for the NOTE
    reg     await_fetch = 1'b0, await_word = 1'b0;
    reg [31:0] mt_ref = 0;                          // syscon_reboot: boot 1's mtime report

    initial begin : init_cls
        integer k;
        for (k = 0; k < 4; k = k + 1) begin cls_rb[k] = 0; cls_all[k] = 0; end
    end

    task automatic on_event(input [31:0] e);
        begin
            n_events = n_events + 1;
            if (n_events > exp_events)
                fail($sformatf("%s: unexpected EVENT %h", test, e));
            else if (test == "syscon_reboot") begin
                if (e !== 32'h51) fail($sformatf("%s: EVENT %h, want 51", test, e));
            end
        end
    endtask

    task automatic on_value(input [31:0] v);
        begin
            n_values = n_values + 1;
            if (n_values > exp_values)
                fail($sformatf("%s: unexpected VALUE %h", test, v));
            else if (test == "syscon_reboot") begin
                // mtime at the program's first instructions of each boot: the
                // CLINT restarted at every reboot, so it is the same every time
                if (n_values == 1) mt_ref = v;
                else if (v > mt_ref + 64 || v + 64 < mt_ref)
                    fail($sformatf("syscon_reboot: boot %0d read mtime %0d at its start, boot 1 read %0d (CLINT not restarted?)",
                                   n_values, v, mt_ref));
            end
        end
    endtask

    function automatic [8*16-1:0] cls_name(input integer c);
        case (c)
            0: cls_name = "fetch";
            1: cls_name = "fetch-split-2nd";
            2: cls_name = "data";
            default: cls_name = "idle";
        endcase
    endfunction

    // ── The clocked checker and model ───────────────────────────────────────
    reg        prev_rsoc = 1'b0;
    always @(posedge clk) begin : model
        reg        s_rst, s_rsoc, held, exp_rsoc;
        reg [31:0] word, mask, wdat;
        reg [13:0] w_off;
        reg [3:0]  be;
        reg        fin_act, w_cr, w_torr, kick, tick, fire, tap_bit;
        integer    n, lo, cls;

        s_rst    = rst;
        s_rsoc   = soc.rst_soc;
        exp_rsoc = s_rst | (m_hold > 0) | m_off;
        held     = exp_rsoc;

        // ---- rst_soc must be what the model says --------------------------
        if (s_rsoc !== exp_rsoc) begin
            if (exp_rsoc) begin
                if (why == 2) fail("watchdog did not fire (rst_soc low where the model predicts the reboot)");
                else          fail("rst_soc low where the model holds the SoC");
            end else
                fail("SoC reset without a pin reset, FINISH or watchdog fire");
        end

        // ---- first edge of a hold that is not the pin reset (E1) ----------
        if (s_rsoc === 1'b1 && !prev_rsoc && !s_rst) begin
            if (soc.memc.second === 1'b1)                         cls = 1;
            else if (!soc.qspi.idle && soc.memc.gnt_d === 1'b1)   cls = 2;
            else if (!soc.qspi.idle)                              cls = 0;
            else                                                  cls = 3;
            cls_all[cls] = cls_all[cls] + 1;
            if (why == 1 || why == 2) cls_rb[cls] = cls_rb[cls] + 1;
            if (qspi_cs_n[0] === 1'b0 && (why == 1 || why == 2)) n_cut = n_cut + 1;
            $display("NOTE %s #%0d at cycle %0d: bus %0s, flash cs_n %b%0s",
                     why == 1 ? "reboot" : why == 2 ? "watchdog reboot" : why == 3 ? "power-off" :
                     why == 4 ? "fail halt" : "reset",
                     why == 1 ? n_fin : why == 2 ? n_wdt : n_off, cyc, cls_name(cls), qspi_cs_n[0],
                     (qspi_cs_n[0] === 1'b0) ? " (a flash read cut short)" : "");
        end
        if (s_rsoc === 1'b1) begin await_fetch = 1'b1; await_word = 1'b1; end

        // ---- pins and buses while the SoC is held (after its first reset edge)
        if (cyc >= 3 && prev_rsoc === 1'b1 && s_rsoc === 1'b1) begin
            if (qspi_cs_n !== 3'b111)  fail($sformatf("held: qspi_cs_n = %b, want 111", qspi_cs_n));
            if (qspi_ctl_oe !== 1'b0)  fail("held: qspi_ctl_oe is not 0");
            if (qspi_io_oe !== 1'b0)   fail("held: qspi_io_oe is not 0");
            if (gpio_out !== 8'h09)    fail($sformatf("held: gpio_out = %h, want 09", gpio_out));
            if (uart_tx !== 1'b1)      fail("held: uart_tx is not 1");
            if (uart_rts_n !== 1'b1)   fail("held: uart_rts_n is not 1");
            if ((soc.imem_req === 1'b1 && soc.imem_ready === 1'b1) ||
                (soc.dmem_req === 1'b1 && soc.dmem_ready === 1'b1))
                fail("held: a bus handshake while the SoC is in reset");
        end
        // ---- no X on an output, whatever the state -------------------------
        if (cyc >= 3) begin
            if (^{qspi_cs_n, qspi_ctl_oe, qspi_io_oe, uart_tx, uart_rts_n, gpio_out} === 1'bx)
                fail("X on a SoC output");
            if (qspi_ctl_oe === 1'b1 && ^qspi_sck === 1'bx) fail("X on qspi_sck while driven");
            if (qspi_io_oe === 1'b1 && ^qspi_io_out === 1'bx) fail("X on qspi_io_out while driven");
        end

        // ---- first fetch after a reset -------------------------------------
        if (s_rsoc !== 1'b1) begin
            if (await_fetch && soc.imem_req === 1'b1) begin
                await_fetch = 1'b0;
                if (soc.imem_addr !== 32'h2000_0000)
                    fail($sformatf("first fetch after a reset at %h, want 20000000", soc.imem_addr));
            end
            if (await_word && soc.imem_req === 1'b1 && soc.imem_ready === 1'b1) begin
                await_word = 1'b0;
                if (soc.imem_rdata !== {pmod.flash_rd(24'd3), pmod.flash_rd(24'd2),
                                        pmod.flash_rd(24'd1), pmod.flash_rd(24'd0)})
                    fail($sformatf("first fetch after a reset returned %h, not flash word 0 (%h)",
                                   soc.imem_rdata, {pmod.flash_rd(24'd3), pmod.flash_rd(24'd2),
                                                    pmod.flash_rd(24'd1), pmod.flash_rd(24'd0)}));
            end
        end

        // ---- ready: low only while its target is selected -----------------
        if (!s_rst && s_rsoc !== 1'b1) begin
            if (soc.uart_ready !== 1'b1 && !soc.uart_sel) fail("UART ready low while not selected");
            if (soc.gpio_ready !== 1'b1 && !soc.gpio_sel) fail("GPIO ready low while not selected");
            if (soc.syscon_sel === 1'b1 && soc.dmem_ready !== 1'b1) fail("syscon held ready low");
        end

        // ---- syscon load against the model ---------------------------------
        be = soc.dmem_be;
        if (!held && sc_rd) begin
            n_loads = n_loads + 1;
            mask = {{8{be[3]}}, {8{be[2]}}, {8{be[1]}}, {8{be[0]}}};
            word = model_word({soc.dmem_addr[15:2], 2'b00});
            if ((soc.dmem_rdata & mask) !== (word & mask))
                fail($sformatf("syscon load +%h: got %h, want %h (lanes %b)",
                               {soc.dmem_addr[15:2], 2'b00}, soc.dmem_rdata & mask, word & mask, be));
        end

        // ---- model update ---------------------------------------------------
        if (s_rst) begin
            // pin reset: PIN only, BOOT_MODE 0, strap re-latched, watchdog off
            m_cause = `RC_PIN; m_bm = 8'h00; m_strap = strap;
            m_hold = 0; m_off = 1'b0; why = 0;
            m_en = 1'b0; m_top = `WDT_TOP_RESET; m_ticks = 0; m_tprev = 1'b1; last_clear = cyc;
        end else if (held) begin
            // the SoC is held: no write takes effect; the watchdog is on rst_soc
            if (m_hold > 0) m_hold = m_hold - 1;
            m_en = 1'b0; m_top = `WDT_TOP_RESET; m_ticks = 0; m_tprev = 1'b1; last_clear = cyc;
        end else begin
            w_off = soc.dmem_addr[15:2];
            wdat  = soc.dmem_wdata;
            fin_act = 1'b0; w_cr = 1'b0; w_torr = 1'b0; kick = 1'b0;
            if (sc_wr) begin
                n_stores = n_stores + 1;
                case ({w_off, 2'b00})
                    `SYS_FINISH: begin
                        if (be[1:0] == 2'b11 &&
                            (wdat[15:0] == `FIN_REBOOT || wdat[15:0] == `FIN_OFF || wdat[15:0] == `FIN_FAIL))
                            fin_act = 1'b1;
                        else if (!fin_noise_ok)
                            fail($sformatf("%s: stray FINISH store (lanes %b, data %h)", test, be, wdat));
                    end
                    `SYS_CAUSE:    if (be[0]) m_cause = m_cause & ~wdat[2:0];
                    `SYS_BOOTMODE: if (be[0]) m_bm = wdat[7:0];
                    `WDT_CR:       w_cr = be[0] && wdat[0];
                    `WDT_TORR:     w_torr = be[0];
                    `WDT_CRR:      kick = be[0] && (wdat[7:0] == `WDT_KEY);
                    default: ;
                endcase
            end
            // watchdog: a tick is a rising edge of the tapped bit; the third
            // tick after the last clear fires, but never on a held edge (A18).
            tap_bit = tap[m_top];
            tick    = m_en && tap_bit && !m_tprev;
            fire    = m_en && tick && (m_ticks == 2);
            if (fire) begin
                n  = cyc - last_clear;
                lo = 1 << (16 + m_top);
                $display("NOTE watchdog reset %0d clocks after the last clear (TOP %0d)", n, m_top);
                if (!(n > lo && n <= lo + lo / 2 + 1))
                    fail($sformatf("watchdog fired %0d clocks after the last clear, TOP %0d wants (%0d, %0d]",
                                   n, m_top, lo, lo + lo / 2 + 1));
            end
            if (!m_en || kick || w_torr) begin m_ticks = 0; last_clear = cyc; end
            else if (tick) m_ticks = m_ticks + 1;
            if (w_torr) begin m_top = wdat[3:0]; m_tprev = 1'b1; end
            else m_tprev = tap_bit;
            if (w_cr) m_en = 1'b1;
            // events of this edge
            if (fin_act) begin
                if (wdat[15:0] == `FIN_REBOOT) begin
                    m_hold = `REBOOT_EDGES; m_cause = m_cause | `RC_SOFT; why = 1;
                    n_fin = n_fin + 1;
                    if (n_fin > exp_fin_reboots) begin
                        fail($sformatf("%s: unexpected FINISH reboot %0d", test, n_fin)); abort = 1'b1;
                    end
                end else begin
                    m_off = 1'b1; n_off = n_off + 1;
                    done = 1'b1;
                    if (wdat[15:0] == `FIN_OFF) begin passed = 1'b1; why = 3; end
                    else begin failed = 1'b1; fail_code = wdat[31:16]; why = 4; end
                end
            end
            if (fire) begin
                m_cause = m_cause | `RC_WDT;
                if (!fin_act) begin m_hold = `REBOOT_EDGES; why = 2; end
                n_wdt = n_wdt + 1;
                if (n_wdt > exp_wdt_reboots) begin
                    fail($sformatf("%s: unexpected watchdog reboot %0d", test, n_wdt)); abort = 1'b1;
                end
            end
            // mailbox
            if (sc_wr && !fin_act) begin
                if (w_off == 14'h1FC || w_off == 14'h1FD || w_off == 14'h1FE) begin
                    if (be !== 4'b1111)
                        fail($sformatf("%s: mailbox +%h written with lanes %b (want a word store)",
                                       test, {w_off, 2'b00}, be));
                    else case (w_off[1:0])
                        2'd0: on_event(wdat);
                        2'd1: begin value = wdat; on_value(wdat); end
                        default: value2 = wdat;
                    endcase
                end
            end
        end

        if (done) post_done = post_done + 1;
        prev_rsoc = (s_rsoc === 1'b1);
    end

    // ── Run ─────────────────────────────────────────────────────────────────
    reg rd_late_run;
    initial begin
        if (!$value$plusargs("TEST=%s", test)) test = "";
        if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)) max_cycles = 3_000_000;
        rd_late_run = $test$plusargs("RD_LATE");
        strap = rd_late_run;
        if (test == "syscon_regs") begin
            fin_noise_ok = 1'b1;
        end else if (test == "syscon_reboot") begin
            exp_fin_reboots = 4; exp_events = 1; exp_values = 5;
        end else begin
            fail($sformatf("unknown +TEST=%0s", test));
        end
        repeat (10) @(posedge clk);
        #1 rst = 1'b0;
        // the earliest the pin may change: from the first edge after rst falls
        if (rd_late_run) begin @(posedge clk); #1 strap = 1'b0; end
        while (!(done && post_done >= HOLD_CLOCKS) && !abort && cyc < max_cycles) @(posedge clk);
        if (!done && !abort) begin
            $display("TIMEOUT tb_syscon_soc %s: no FINISH within %0d cycles (pc %h, %0d reboots, %0d watchdog reboots)",
                     test, max_cycles, soc.cpu.pc, n_fin, n_wdt);
            errors = errors + 1;
        end else if (done) begin
            if (failed && !fail_expected)
                fail($sformatf("%s: program check %h failed (value seen %h)", test, fail_code, value2));
            if (failed && fail_expected && fail_code !== exp_fail_code)
                fail($sformatf("%s: FINISH fail code %h, want %h", test, fail_code, exp_fail_code));
            if (passed && fail_expected)
                fail($sformatf("%s: the program passed, want the fail code %h", test, exp_fail_code));
            if (n_fin != exp_fin_reboots)
                fail($sformatf("%s: %0d FINISH reboots, want %0d", test, n_fin, exp_fin_reboots));
            if (n_wdt != exp_wdt_reboots)
                fail($sformatf("%s: %0d watchdog reboots, want %0d", test, n_wdt, exp_wdt_reboots));
            if (n_events != exp_events)
                fail($sformatf("%s: %0d EVENT stores, want %0d", test, n_events, exp_events));
            if (n_values != exp_values)
                fail($sformatf("%s: %0d VALUE stores, want %0d", test, n_values, exp_values));
            if (post_done < HOLD_CLOCKS || !m_off)
                fail($sformatf("%s: the power-off hold was not observed", test));
            if (n_loads == 0) fail($sformatf("%s: no syscon load was checked", test));
            // coverage floors: the scenario each test is for really happened
            if (test == "syscon_reboot" && cls_rb[0] < 1)
                fail("syscon_reboot: no reboot landed on a flash fetch in flight");
        end
        if (rp.errors != 0) fail($sformatf("%s: %0d RP2350 UART errors", test, rp.errors));
        if (errors == 0)
            $display("PASS tb_syscon_soc %s (%0d cycles, %0d syscon loads and %0d stores checked, %0d reboots, %0d watchdog reboots, resets on fetch/split-2nd/data/idle = %0d/%0d/%0d/%0d, %0d flash reads cut)",
                     test, cyc, n_loads, n_stores, n_fin, n_wdt,
                     cls_all[0], cls_all[1], cls_all[2], cls_all[3], n_cut);
        else
            $display("FAIL tb_syscon_soc %s: %0d errors", test, errors);
        $finish;
    end
endmodule
