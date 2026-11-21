// SoC-level testbench for the peripherals: alphaone_soc booting a test
// program from the QSPI Pmod model's flash, with the demo board's devices
// on its pins (docs/pins-and-peripherals.md):
//
//   * tb/rp2350_uart_model.v on uart_tx / uart_rx; its CTS is the chip's RTS# tap
//     (uart_rts_n) in the UART programs and uo[5] in pinmux, which selects the
//     RTS# feature on that pin (+UART_FLOW=1 does the same for any program);
//   * tb/ssd1331_model.v, the PmodOLEDrgb, and tb/sd_spi_model.v (CS# = OUT bit 5)
//     on the chip pins uo[0,1,2,3,6] and uo[5], through the pad delays;
//   * tb/keypad_model.v, the PmodKYPD, on gpio_out[3:0] and gpio_in[7:4];
//   * monitors on uo[7] (audio: high clocks per 256-clock frame, tone period)
//     and uo[2] (PWM: high time and period), for audio.S, pwm_linux.S and pinmux.S.
//   gpio_in[3] is the UART's RX line, as on the chip, and gpio_in[0] the
//   rd_late strap (0 here).
//
// The core runs at 50 MHz (TCLK = 20 ns), so the SSD1331 timing checks
// mean what they say, and the UART's divisor resets to UART_DIV = 4 so a
// character takes 640 clocks -- slower than a store loop running from
// flash (about 57 clocks per instruction), so back-pressure really stalls.
//
// Programs (tests/soc/*.S) talk to the testbench through a mailbox in the
// syscon window (tests/soc/periph.h): FINISH at +0x000 (QEMU's sifive_test
// codes: 0x5555 pass, (code << 16) | 0x3333 fail, a word store), EVENT (a
// cue), VALUE and VALUE2 at +0x7F0 / +0x7F4 / +0x7F8, decoded exactly;
// every other syscon word is not the mailbox. The verdict is taken at
// FINISH: no UART or SSD1331 byte may arrive after it, and the core's ports
// are not checked after it (a FINISH powers the SoC off once the syscon
// exists). +TEST=<name>
// picks the test's cues and final checks; +FLASH_FILE=<hex> (read by the
// Pmod model) is its program; +MAX_CYCLES=<n> the time limit.
//
// On every clock, whatever the test: the core's data and fetch requests
// are held until ready (tb/req_hold_check.v); the UART and GPIO blocks drop
// ready only while selected (soc_bus's contract); no interrupt is injected
// while a data request waits; TX and RTS# are never X.

`timescale 1ns / 1ps

`ifndef TCLK_NS
`define TCLK_NS 20.0                     // the SD runs (make test-soc-spi) build with -DTCLK_NS=16.0, the chip clock
`endif

module tb_soc_periph;
    localparam real    TCLK     = `TCLK_NS;
    localparam integer UART_DIV = 4;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #(TCLK / 2.0) clk = ~clk;
    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    // ── The SoC and the QSPI Pmod ───────────────────────────────────────────
    wire       qspi_sck, qspi_ctl_oe, qspi_io_oe, pmod_oe;
    wire [2:0] qspi_cs_n;
    wire [3:0] qspi_io_out, pmod_io;
    wire [3:0] qspi_io_in = pmod_oe ? pmod_io : (qspi_io_oe ? qspi_io_out : 4'bxxxx);
    wire       uart_tx, uart_rts_n, uart_rx;
    wire [7:0] gpio_out, gpio_in, uo;

    alphaone_soc #(.UART_DIV_RESET(UART_DIV)) soc (
        .clk(clk), .rst(rst), .qspi_rd_late(1'b0), .qspi_no_stream(1'b0),
        .qspi_sck(qspi_sck), .qspi_cs_n(qspi_cs_n), .qspi_ctl_oe(qspi_ctl_oe),
        .qspi_io_out(qspi_io_out), .qspi_io_oe(qspi_io_oe), .qspi_io_in(qspi_io_in),
        .uart_rx(uart_rx), .uart_tx(uart_tx), .uart_rts_n(uart_rts_n),
        .gpio_in(gpio_in), .gpio_out(gpio_out), .uo(uo));

    qspi_pmod_model pmod (
        .host_sck(qspi_sck), .host_cs_n(qspi_cs_n), .host_ctl_oe(qspi_ctl_oe),
        .host_io(qspi_io_out), .host_oe(qspi_io_oe), .dev_io(pmod_io), .dev_oe(pmod_oe));

    // ── The board ───────────────────────────────────────────────────────────
    // CTS: the chip's RTS# tap, or uo[5] when a program selects RTS# on that pin through the pinmux
    reg  cts_pin = 1'b0;
    rp2350_uart_model #(.BIT_NS(16.0 * UART_DIV * TCLK)) rp (
        .tx(uart_tx), .rx(uart_rx), .cts_n(cts_pin ? uo[5] : uart_rts_n));
    // Pad delays (WO-29 6.3): the OLED and the SD card sit behind RT_OUT on the chip pins (uo) they
    // use, and the card's DO reaches gpio_in[1] through RT_IN. Both are transport delays
    // (a nonblocking assignment with a delay), never an inertial `assign #`. Defaults 0 + 0,
    // 12.5 + 12.5 in the SD runs; +RT_OUT=<ns> +RT_IN=<ns> override. The keypad and the
    // UART stay undelayed.
    real      rt_out = 0.0, rt_in = 0.0;
    reg [7:0] pd = 8'h39;
    always @(uo[0]) pd[0] <= #(rt_out) uo[0];
    always @(uo[1]) pd[1] <= #(rt_out) uo[1];
    always @(uo[2]) pd[2] <= #(rt_out) uo[2];
    always @(uo[3]) pd[3] <= #(rt_out) uo[3];
    always @(uo[5]) pd[5] <= #(rt_out) uo[5];
    always @(uo[6]) pd[6] <= #(rt_out) uo[6];
    reg oled_fitted = 1'b0;
    ssd1331_model oled (
        .fitted(oled_fitted), .cs_n(pd[0]), .sck(pd[3]), .mosi(pd[1]),
        .dc(pd[2]), .res_n(pd[6]));
    // SD card on CS# uo[5] (GPIO OUT bit 5), SCK uo[3], MOSI uo[1], DO -> gpio_in[1] with a pull-up
    reg     sd_used = 1'b0, sd_fitted = 1'b0, sd_ev = 1'b0, expect_fail = 1'b0;
    tri1    sd_do_c;
    reg     do_d = 1'b1;
    sd_spi_model sd (.fitted(sd_fitted), .cs_n(pd[5]), .sck(pd[3]), .di(pd[1]),
                     .expect_violations(sd_ev), .do_o(sd_do_c));
    always @(sd_do_c) do_d <= #(rt_in) sd_do_c;
    reg        kp_fitted = 1'b0;
    reg [15:0] keys = 16'h0000;
    wire [3:0] kp_row;
    keypad_model kp (.col(gpio_out[3:0]), .pressed(keys), .row(kp_row));
    reg [7:0]  tb_in = 8'h00;
    // The gamepad Pmod's LATCH / CLOCK / DATA on ui_in[4] / [5] / [6]; the model idles high until enabled
    wire       gp_latch, gp_clock, gp_data;
    gamepad_model gp (.latch(gp_latch), .clock(gp_clock), .data(gp_data));
    reg        gp_on = 1'b0;                  // gamepad.S / +GAMEPAD=1: the Pmod drives ui_in[6:4]
    wire [3:0] hi_in = kp_fitted ? kp_row : gp_on ? {tb_in[7], gp_data, gp_clock, gp_latch} : tb_in[7:4];
    assign gpio_in = {hi_in, uart_rx, tb_in[2], sd_used ? do_d : tb_in[1], tb_in[0]};

    // ── Checks on every clock ───────────────────────────────────────────────
    reg done = 1'b0, passed = 1'b0, failed = 1'b0;
    // After FINISH the core's ports are not this bench's business: once the
    // syscon exists a FINISH powers the SoC off one clock later and cuts the
    // fetch the core's spin loop has outstanding.
    req_hold_check #(.W(69), .NAME("dmem request")) chk_dmem (
        .clk(clk), .rst(rst || done), .take(soc.dmem_req), .hold(soc.dmem_req), .done(soc.dmem_ready),
        .payload({soc.dmem_addr, soc.dmem_we, soc.dmem_be, soc.dmem_we ? soc.dmem_wdata : 32'h0}));
    req_hold_check #(.W(32), .NAME("imem request")) chk_imem (
        .clk(clk), .rst(rst || done), .take(soc.imem_req), .hold(soc.imem_req), .done(soc.imem_ready),
        .payload(soc.imem_addr));

    integer errors = 0;
    task automatic fail(input string m);
        begin
            errors = errors + 1;
            if (errors <= 40) $display("FAIL %s (cycle %0d)", m, cyc);
        end
    endtask

    // White-box counters, for the tests' final checks and coverage.
    integer n_thr = 0, n_pop = 0;          // THR loads, RBR pops
    integer uart_wait = 0, gpio_wait = 0;  // clocks a store waited
    integer uart_waits = 0;                // stores that waited
    reg     uart_waiting = 1'b0;
    reg     pend_in_stall = 1'b0;          // an interrupt pending while a store waited
    integer cts_wait = 0;                  // clocks the RP2350 held a character for CTS
    integer in_lag_min = 1000000;          // clocks from an OUT write to the next IN read
    integer last_out_wr = -1000;
    always @(posedge clk)
        if (!rst) begin
            if (soc.uart_ready !== 1'b1 && !soc.uart_sel) fail("UART ready low while not selected");
            if (soc.gpio_ready !== 1'b1 && !soc.gpio_sel) fail("GPIO ready low while not selected");
            if (soc.cpu.irq_inject && soc.dmem_req && !soc.dmem_ready)
                fail("interrupt injected while a data request waits");
            if (uart_tx !== 1'b0 && uart_tx !== 1'b1) fail("uart_tx is X");
            if (uart_rts_n !== 1'b0 && uart_rts_n !== 1'b1) fail("uart_rts_n is X");
            if (^uo === 1'bx) fail("uo is X");
            if (soc.uart_inst.wr_thr) n_thr = n_thr + 1;
            if (soc.uart_inst.rd_rbr) n_pop = n_pop + 1;
            if (soc.uart_sel && !soc.uart_ready) begin
                uart_wait = uart_wait + 1;
                if (!uart_waiting) uart_waits = uart_waits + 1;
            end
            uart_waiting = soc.uart_sel && !soc.uart_ready;
            if (soc.gpio_sel && !soc.gpio_ready) gpio_wait = gpio_wait + 1;
            if (soc.cpu.any_irq_pend && soc.dmem_req && soc.dmem_we && !soc.dmem_ready
                && (soc.uart_sel || soc.gpio_sel)) pend_in_stall = 1'b1;
            if (rp.tx_head != rp.tx_tail && !rp.tx_busy && uart_rts_n) cts_wait = cts_wait + 1;
            if (soc.gpio_sel && soc.gpio_ready && soc.dmem_addr[3:2] == 2'd0 && soc.dmem_we)
                last_out_wr = cyc;
            if (soc.gpio_sel && soc.gpio_ready && soc.dmem_addr[3:2] == 2'd1 && !soc.dmem_we
                && cyc - last_out_wr < in_lag_min) in_lag_min = cyc - last_out_wr;
        end

    // ── Mailbox ─────────────────────────────────────────────────────────────
    string     test;
    reg [31:0] result = 0, value = 0, value2 = 0;
    integer    rx_fin = 0, oled_fin = 0, res_fin = 0;
    wire       mb = soc.dmem_req && soc.dmem_we && soc.dmem_ready && soc.dmem_addr[31:16] == 16'h1002;

    // ── PWM and audio monitors (pwm_linux, pinmux, audio) ───────────────────
    reg  [31:0] m2_eh = 0, m2_ep = 0, m7_eh = 0, m7_ep = 0;
    reg         m2_clr = 1'b0, m7_clr = 1'b0;
    wire [31:0] m2_hi_ok, m2_per_ok, m2_n_hi, m2_n_pulse, m7_hi_ok, m7_per_ok, m7_n_hi, m7_n_pulse;
    pin_meter m2 (.clk(clk), .pin(uo[2]), .clr(m2_clr), .exp_hi(m2_eh), .exp_per(m2_ep),
                  .hi_ok(m2_hi_ok), .per_ok(m2_per_ok), .n_hi(m2_n_hi), .n_pulse(m2_n_pulse));
    pin_meter m7 (.clk(clk), .pin(uo[7]), .clr(m7_clr), .exp_hi(m7_eh), .exp_per(m7_ep),
                  .hi_ok(m7_hi_ok), .per_ok(m7_per_ok), .n_hi(m7_n_hi), .n_pulse(m7_n_pulse));
    always @(posedge clk) begin if (m2_clr) m2_clr <= 1'b0; if (m7_clr) m7_clr <= 1'b0; end

    // audio (one square voice, WO-63): the rising edges of uo[7]. Every phase restarts the voice (EN off, then
    // on), so every distance between two consecutive rising edges is exactly the tone period, 32 * 2^O * (P + 1)
    // clocks (the pin lags the block by a constant). The same monitor serves audio.S and tune.S.
    integer au_n = 0, au_hi = 0, au_last = 0;
    reg     au_prev = 1'b0;
    integer au_dist [0:127];
    always @(posedge clk) if (!rst && (test == "audio" || test == "tune")) begin
        if (uo[7] === 1'b1) au_hi = au_hi + 1;
        if (uo[7] === 1'b1 && !au_prev) begin
            if (au_n > 0 && au_n < 128) au_dist[au_n - 1] = cyc - au_last;
            au_last = cyc; au_n = au_n + 1;
        end
        au_prev = (uo[7] === 1'b1);
    end
    function integer au_want(input integer ph);
        begin
            if (test == "tune")
                case (ph)
                    1: au_want = 32 * 2963;  2: au_want = 32 * 3955;  3: au_want = 32 * 3733;  4: au_want = 32 * 3325;
                    5: au_want = 32 * 3733;  6: au_want = 32 * 3955;  7: au_want = 64 * 2219;  8: au_want = 64 * 2219;
                    default: au_want = 0;
                endcase
            else au_want = (ph == 1) ? 1024 : (ph == 2) ? 1280 : (ph == 3) ? 1312 : 0;
        end
    endfunction
    task automatic au_eval(input integer ph);
        integer i, bad, want, last_ph, min_n;
        begin
            want = au_want(ph); last_ph = (test == "tune") ? 9 : 4;
            min_n = (test == "tune") ? 3 : 40;
            if (ph == last_ph) begin
                if (au_hi != 0) fail($sformatf("%0s phase %0d: EN 0 but uo[7] was high %0d clocks", test, ph, au_hi));
            end else if (au_n < min_n) fail($sformatf("%0s phase %0d: only %0d rising edges", test, ph, au_n));
            else begin
                bad = 0;
                for (i = 0; i < au_n - 1 && i < 127; i = i + 1) if (au_dist[i] != want) bad = bad + 1;
                $display("%0s phase %0d: %0d rising edges, tone period %0d clocks (want %0d), %0d wrong",
                         test, ph, au_n, au_dist[0], want, bad);
                if (bad != 0) fail($sformatf("%0s phase %0d: %0d of %0d periods not %0d clocks", test, ph, bad, au_n - 1, want));
            end
            au_n = 0; au_hi = 0;
        end
    endtask

    // PWM on a pin: a phase needs one rising-edge distance and one high time of the expected size
    task automatic pw_eval(input integer pin, input integer ph, input [31:0] hi_ok, per_ok, n_pulse);
        begin
            $display("%s phase %0d on uo[%0d]: %0d pulses, %0d with the expected high time, %0d with the expected period",
                     test, ph, pin, n_pulse, hi_ok, per_ok);
            if (hi_ok < 1 || per_ok < 1)
                fail($sformatf("%s phase %0d: uo[%0d] had %0d pulses, %0d of the expected high time, %0d of the expected period",
                               test, ph, pin, n_pulse, hi_ok, per_ok));
        end
    endtask
    // sd_cs: the pin flop follows OUT one clock later
    realtime t_g5 = 0.0, t_u5 = 0.0;
    always @(gpio_out[5]) t_g5 = $realtime;
    always @(uo[5])       t_u5 = $realtime;

    // sd_reboot_a / _b: FINISH 0x7777 is the reboot under test (WO-29 8)
    reg     rb_seen = 1'b0;
    integer rb_cyc = 0, rb_st = 0;
    reg     is_rb = 1'b0;
    task automatic finish(input [3:0] be, input [31:0] w);
        begin
          if (is_rb && !rb_seen && be === 4'b1111 && w[15:0] == 16'h7777) begin
            rb_seen = 1'b1; rb_cyc = cyc; rb_st = soc.gpio_inst.spi_inst.st; sd_ev = 1'b1;
          end else begin
            done = 1'b1;
            rx_fin = rp.rx_n;  oled_fin = oled.nlog;  res_fin = oled.n_res_pulses;
            if (be !== 4'b1111)
                fail($sformatf("%s: FINISH written with lanes %b (want a word store)", test, be));
            else if (^w === 1'bx)
                fail($sformatf("%s: FINISH written with %h", test, w));
            else if (w[15:0] == 16'h5555) passed = 1'b1;
            else if (w[15:0] == 16'h3333) begin failed = 1'b1; result = {16'h0, w[31:16]}; end
            else if (w[15:0] == 16'h7777)
                fail($sformatf("%s: FINISH 0x7777 (reboot) in a test that expects none", test));
            else
                fail($sformatf("%s: FINISH written with %h: not 0x5555, (code << 16) | 0x3333 or 0x7777", test, w));
          end
        end
    endtask
    // after a reboot under test: the pins stay at the reset value, and no SCK edge reaches a selected card
    always @(posedge clk) if (rb_seen && cyc > rb_cyc + 8 && !done && (gpio_out !== 8'hB9 || uo !== 8'h39))
        fail($sformatf("%s: gpio_out = %h, uo = %h after the reboot, want b9 and 39", test, gpio_out, uo));
    always @(uo[3]) if (rb_seen && cyc > rb_cyc + 8 && uo[5] === 1'b0)
        fail($sformatf("%s: SCK edge with the SD card selected after the reboot", test));

    // The line uart_echo's RP2350 types (tests/soc/uart_echo.S has its copy).
`define ECHO_LINE "The quick brown fox jumps over the lazy dog, 0123456789!\015\n"

    // Per-test state
    integer    ph[0:7];                    // counter snapshots at cues
    integer    kp_set = 0;
    integer    irq_part = 0, irq_hits[0:3], irq_n[0:3], c_byte = 0;
    reg [15:0] kp_sets [0:27];
    integer    i;
    initial begin
        for (i = 0; i < 16; i = i + 1) kp_sets[i] = 16'h1 << i;   // each key alone
        kp_sets[16] = 16'h0000; kp_sets[17] = 16'h8421; kp_sets[18] = 16'h1248;
        kp_sets[19] = 16'h1111; kp_sets[20] = 16'h2222; kp_sets[21] = 16'h4444;
        kp_sets[22] = 16'h8888; kp_sets[23] = 16'h4812; kp_sets[24] = 16'h2184;
        kp_sets[25] = 16'h0021; kp_sets[26] = 16'h1200; kp_sets[27] = 16'h0000;
        for (i = 0; i < 4; i = i + 1) begin irq_hits[i] = 0; irq_n[i] = 0; end
    end

    // ── +MB_UART: the program also sends its cues and values over the UART ───
    // (tests/soc/periph.h, built with -DMB_UART [-DMB_DIV=n]). The stream the
    // RP2350 compares is the payload without the frames; the divisor follows
    // +MB_DIV (default the reset divisor); uart_linux's baud change follows its
    // cue frame, which the program sends before it writes the divisor.
    // +CACHE_EN: the instruction cache is switched on (CACHE_CTL.EN) two clocks after every release of rst_soc, as a
    // program's first stores would; a reboot or pin reset clears EN again, as in the hardware.
    reg cache_en_arg;
    initial cache_en_arg = $test$plusargs("CACHE_EN");
    reg cache_pb_arg;                 // +CACHE_PBURST: CACHE_CTL.PBURST forced on with EN (PSRAM line bursts)
    initial cache_pb_arg = $test$plusargs("CACHE_PBURST");
    always @(posedge soc.rst_soc) if (cache_en_arg) release soc.cache_en;
    always @(posedge soc.rst_soc) if (cache_pb_arg) release soc.cache_pburst;
    always @(negedge soc.rst_soc) if (cache_en_arg) begin repeat (2) @(posedge clk); if (!soc.rst_soc) force soc.cache_en = 1'b1; end
    always @(negedge soc.rst_soc) if (cache_pb_arg) begin repeat (2) @(posedge clk); if (!soc.rst_soc) force soc.cache_pburst = 1'b1; end
    reg        mb_uart = 1'b0;
    integer    mb_div = UART_DIV, mb_seen = 0, mb_st = 0, mb_n = 0, mb_tag = 0;
    string     mb_pay = "";
    initial begin
        mb_uart = $test$plusargs("MB_UART");
        if (!$value$plusargs("MB_DIV=%d", mb_div)) mb_div = UART_DIV;
        #1 if (mb_uart) rp.set_baud(16.0 * mb_div * TCLK);
    end
    always @(rp.rx_n) if (mb_uart) begin : mb_demux
        reg [7:0] b;
        while (mb_seen < rp.rx_n) begin
            b = rp.rx_buf[mb_seen % 16384]; mb_seen = mb_seen + 1;
            if (mb_st == 0) begin
                if (b >= 8'h10 && b <= 8'h13) begin mb_tag = b; mb_n = 0; mb_st = (b == 8'h10) ? 1 : 2; end
                else if (b == 8'h00) fail("a NUL byte in the payload (it would vanish from the string)");
                else mb_pay = $sformatf("%s%c", mb_pay, b);
            end else if (mb_st == 1) begin
                mb_st = 0;
                if (test == "uart_linux" && b == 8'd4) rp.set_baud(16.0 * 3 * TCLK);
                // uart_echo acts on the frame, as the pins bench does: the program polls LSR
                // while it sends the frame, and a poll after "XYZ" has arrived would clear OE
                if (test == "uart_echo") begin
                    if (b == 1) begin rp.set_flow(1'b1); rp.send_str(`ECHO_LINE); ph[1] = cts_wait; end
                    if (b == 2) begin ph[2] = cts_wait; rp.set_flow(1'b0); rp.send_str("XYZ"); end
                    if (b == 3) rp.set_flow(1'b1);
                end
            end else begin
                mb_n = mb_n + 1;
                if (mb_n == 4) mb_st = 0;
            end
        end
    end

    integer pidx = 0, brk_go = 0;
    task automatic send_pat(input integer n);
        integer k;
        for (k = 0; k < n; k = k + 1) begin
            rp.send_byte(8'h20 + ((pidx * 7 + 3) % 95)); pidx = pidx + 1;
        end
    endtask
    // plic_uart cue 5: a break on RX, 12 bit times, with the line otherwise idle
    always @(brk_go) if (brk_go != 0) begin
        while (rp.tx_pending() != 0) @(posedge clk);
        rp.rx = 1'b0; #(12.0 * rp.bit_ns); rp.rx = 1'b1;
    end

    task automatic on_event(input [31:0] e);
        begin
            if (test == "uart_hello" && e >= 1 && e <= 3) begin
                ph[e] = uart_wait; ph[e + 3] = uart_waits;
            end else if (test == "uart_echo" && !mb_uart) begin
                if (e == 1) begin rp.set_flow(1'b1); rp.send_str(`ECHO_LINE); ph[1] = cts_wait; end
                if (e == 2) begin ph[2] = cts_wait; rp.set_flow(1'b0); rp.send_str("XYZ"); end
                if (e == 3) rp.set_flow(1'b1);
            end else if (test == "plic_uart") begin
                // the Linux-order interrupt program: a pattern byte n is 0x20 + (7n + 3) mod 95
                rp.set_flow(1'b0);
                if (e >= 1 && e <= 3) send_pat(e == 1 ? 5 : e == 2 ? 16 : 40);
                if (e == 4) send_pat(8);
                if (e == 5) brk_go = brk_go + 1;
                if (e == 6 || e == 7 || e == 8) send_pat(1);
            end else if (test == "uart_linux") begin
                if (e == 4 && !mb_uart) rp.set_baud(16.0 * 3 * TCLK);
                if (e == 5) begin rp.set_flow(1'b1); rp.send_str("ls -l /dev\015"); end
            end else if (test == "oled_spi") begin
                if (e == 9)  oled.expect_violations = 1'b1;
                if (e == 10) begin
                    oled.expect_violations = 1'b0;
                    if (oled.n_expected == 0)
                        fail("oled_spi: a byte at DIV 1 (80 ns SCK) raised no SSD1331 timing error");
                end
            end else if (test == "gamepad") begin
                case (e)
                    1: begin gp.present0 = 1'b1; gp.pad0 = 12'h123; end
                    2: begin gp.present1 = 1'b1; gp.pad1 = 12'h456; end   // pad 1 is not kept: nothing changes
                    3: gp.present0 = 1'b0;
                    4: begin gp.present1 = 1'b0; gp.present0 = 1'b1; gp.pad0 = 12'h0AA; end
                    default: ;
                endcase
            end else if (test == "gpio_irq") begin
                // one edge of one pin per cue (gpio_irq.S): 1 pin 7 rises, 2 pin 2 rises, 3 pin 0 rises, 4 pin 4 rises, 5 pin 2 falls
                case (e)
                    1: tb_in[7] = 1'b1;
                    2: tb_in[2] = 1'b1;
                    3: tb_in[0] = 1'b1;
                    4: tb_in[4] = 1'b1;
                    5: tb_in[2] = 1'b0;
                    default: ;
                endcase
            end else if (test == "pwm_linux") begin
                if (e >= 2 && e <= 4) pw_eval(2, e - 1, m2_hi_ok, m2_per_ok, m2_n_pulse);
                m2_clr <= 1'b1;
                case (e)
                    1: begin m2_eh = 32'h4001;  m2_ep = 32'h10000; end
                    2: begin m2_eh = 32'h8002;  m2_ep = 32'h20000; end
                    3: begin m2_eh = 32'h20004; m2_ep = 32'h40000; end
                    default: ;
                endcase
            end else if (test == "audio" || test == "tune") begin
                if (e >= 2) au_eval(e - 1); else begin au_n = 0; au_hi = 0; end   // edges before cue 1 (register checks) do not count
            end else if (test == "sd_cs") begin
                if (e == 1 || e == 2) begin
                    if (uo[5] !== (e == 2)) fail($sformatf("sd_cs cue %0d: uo[5] = %b", e, uo[5]));
                    if (t_u5 - t_g5 != TCLK)
                        fail($sformatf("sd_cs cue %0d: uo[5] followed OUT bit 5 after %0.1f ns, want one clock (%0.1f)", e, t_u5 - t_g5, TCLK));
                end
                if (e == 3 || e == 4) begin
                    // OUT bits 7 and 4 move without reaching their pins: audio (low) and UART TX (idle high) stay
                    if (uo[5] !== 1'b1 || uo[7] !== 1'b0 || uo[4] !== 1'b1)
                        fail($sformatf("sd_cs cue %0d: uo = %b, want uo[5] 1, uo[7] 0, uo[4] 1", e, uo));
                end
            end else if (test == "pinmux") begin
                if (e == 1) send_pat(64);
                if (e == 8) begin
                    // RTS# on uo[5]: nothing was read for 24 characters, so the 8-deep FIFO is nearly full,
                    // RTS# is deasserted (pin high) and the model holds the rest of the paste
                    if (uo[5] !== 1'b1) fail("pinmux cue 8: RTS# (uo[5]) still asserted with the RX FIFO nearly full");
                    if (rp.tx_sent < 7 || rp.tx_sent > 10)
                        fail($sformatf("pinmux cue 8: the model sent %0d characters before CTS went off, want 7..10", rp.tx_sent));
                    if (rp.tx_pending() == 0) fail("pinmux cue 8: the model has nothing left to send (flow control did not hold it)");
                end
                if (e == 2 && uo[5] !== 1'b0) fail("pinmux cue 2: uo[5] high after OUT bit 5 went low");
                if (e == 3 && (uo[4] !== 1'b0 || uo[7] !== 1'b0)) fail($sformatf("pinmux cue 3: uo[4], uo[7] = %b %b, want 0 0", uo[4], uo[7]));
                if (e == 4 && (uo[4] !== 1'b1 || uo[7] !== 1'b1)) fail($sformatf("pinmux cue 4: uo[4], uo[7] = %b %b, want 1 1", uo[4], uo[7]));
                if (e == 5 && (uo[4] !== 1'b1 || uo[7] !== 1'b0)) fail($sformatf("pinmux cue 5: uo[4], uo[7] = %b %b, want 1 0", uo[4], uo[7]));
                if (e == 6) begin m7_eh = 32'h4001; m7_ep = 32'h10000; m7_clr <= 1'b1; end
                if (e == 7) begin pw_eval(7, 6, m7_hi_ok, m7_per_ok, m7_n_pulse); m7_clr <= 1'b1; end
            end else if (test == "keypad") begin
                if (e == 1) keys = kp_sets[kp_set];
            end else if (test == "irq_stall") begin
                if (e >= 1 && e <= 3) begin
                    irq_part = e;
                    if (e == 2) oled_fitted = 1'b1;
                    pend_in_stall = 1'b0;
                end
                if (e == 4) begin rp.send_byte("a" + c_byte); c_byte = c_byte + 1; end
                if (e == 5) begin ph[5] = n_thr; ph[6] = n_pop; end
                if (e == 6 && (n_thr - ph[5] != 1 || n_pop - ph[6] != 1))
                    fail($sformatf("irq_stall: amoswap.w to THR made %0d THR loads and %0d RBR pops, want 1 and 1",
                                   n_thr - ph[5], n_pop - ph[6]));
            end else if (test == "periph_access") begin
                if (e == 32'h10) rp.send_byte(value[7:0]);
                // all eight OUT bits are real (WO-52); the chip pins that follow them by default are uo[6:5] and [3:0]
                if (e == 32'h20 && gpio_out !== value[7:0])
                    fail($sformatf("periph_access: gpio_out = %h, want %h", gpio_out, value[7:0]));
                if (e == 32'h20 && {uo[6:5], uo[3:0]} !== {value[6:5], value[3:0]})
                    fail($sformatf("periph_access: uo = %h, want OUT bits 6:5 and 3:0 of %h", uo, value[7:0]));
                if (e == 32'h21) tb_in = 8'hA4;
                if (e == 32'h30) oled_fitted = 1'b1;
            end
        end
    endtask

    integer sdv [0:7];
    integer n_sdv = 0;
    task automatic on_value(input [31:0] v);
        begin
            if (sd_used) begin if (n_sdv < 8) sdv[n_sdv] = v; n_sdv = n_sdv + 1; end
            if (test == "keypad") begin
                if (v !== {16'h0, kp_sets[kp_set]})
                    fail($sformatf("keypad: pattern %0d, pressed %h, scanned %h", kp_set, kp_sets[kp_set], v));
                kp_set = kp_set + 1;
            end else if (test == "irq_stall" && irq_part >= 1) begin
                // The handler reports mepc. An interrupt that was pending while
                // a store waited must have been taken right after that store.
                irq_n[irq_part] = irq_n[irq_part] + 1;
                if (pend_in_stall) begin
                    irq_hits[irq_part] = irq_hits[irq_part] + 1;
                    if (v !== value2)
                        fail($sformatf("irq_stall part %0d: interrupt pending during a held store taken with mepc %h, want %h (the next instruction)",
                                       irq_part, v, value2));
                end
                pend_in_stall = 1'b0;
            end
        end
    endtask

    always @(posedge clk)
        if (!rst && mb && !done) begin
            if (soc.dmem_addr[15:0] == 16'h0000) finish(soc.dmem_be, soc.dmem_wdata);
            else if (soc.dmem_addr[15:0] == 16'h07F0 || soc.dmem_addr[15:0] == 16'h07F4 ||
                     soc.dmem_addr[15:0] == 16'h07F8) begin
                if (soc.dmem_be !== 4'b1111)
                    fail($sformatf("%s: mailbox +%h written with lanes %b (want a word store)",
                                   test, soc.dmem_addr[15:0], soc.dmem_be));
                else case (soc.dmem_addr[3:2])
                    2'd0: on_event(soc.dmem_wdata);
                    2'd1: begin value = soc.dmem_wdata; on_value(soc.dmem_wdata); end
                    default: value2 = soc.dmem_wdata;
                endcase
            end
            // +0x7FC (spare) and every other word: not the mailbox
        end

    // ── Expected outputs ────────────────────────────────────────────────────
    function automatic string want_uart;
        integer k;
        string  s;
        begin
            s = "";
            if (test == "uart_hello") s = "Hello, world!\015\nHello, world!\015\n";
            if (test == "uart_echo")  s = `ECHO_LINE;
            if (test == "uart_linux")
                s = {"earlycon: AlphaOne\015\n",
                     "tx_chars 0123456789 abcdefghijklmnopqrstuvwxyz ABCDEF\015\n",
                     "console: polled\015\n", "console: fifo path, 16 at a time\015\n"};
            if (test == "irq_stall") begin
                // the one-byte THR: part A sends ABA per round (the third store is held), part C two P and the amoswap's Z
                for (k = 0; k < 12; k = k + 1) s = {s, "ABA"};
                for (k = 0; k < 9; k = k + 1)  s = $sformatf("%sPP%c", s, 8'h5A);
            end
            if (test == "periph_access") s = "ABq";
            if (test == "plic_uart")
                for (k = 61; k < 69; k = k + 1) s = $sformatf("%s%c", s, 8'h20 + ((k * 7 + 3) % 95));
            want_uart = s;
        end
    endfunction

    // SSD1331 log: {D/C#, byte}
    reg [8:0] want_oled [0:255];
    integer   n_want_oled = 0;
    task automatic push_oled(input dc, input [7:0] b);
        begin want_oled[n_want_oled] = {dc, b}; n_want_oled = n_want_oled + 1; end
    endtask
    task automatic setup_oled;
        integer k;
        reg [7:0] init [0:47];
        reg [7:0] pix [0:15];
        begin
            {init[0], init[1], init[2], init[3], init[4], init[5], init[6], init[7]} =
                {8'hAE, 8'hA0, 8'h72, 8'hA1, 8'h00, 8'hA2, 8'h00, 8'hA4};
            {init[8], init[9], init[10], init[11], init[12], init[13], init[14], init[15]} =
                {8'hA8, 8'h3F, 8'hAD, 8'h8E, 8'hB0, 8'h0B, 8'hB1, 8'h31};
            {init[16], init[17], init[18], init[19], init[20], init[21], init[22], init[23]} =
                {8'hB3, 8'hF0, 8'h8A, 8'h64, 8'h8B, 8'h78, 8'h8C, 8'h64};
            {init[24], init[25], init[26], init[27], init[28], init[29], init[30], init[31]} =
                {8'hBB, 8'h3A, 8'hBE, 8'h3E, 8'h87, 8'h06, 8'h81, 8'h91};
            {init[32], init[33], init[34], init[35], init[36], init[37], init[38], init[39]} =
                {8'h82, 8'h50, 8'h83, 8'h7D, 8'h2E, 8'h25, 8'h00, 8'h00};
            {init[40], init[41], init[42], init[43], init[44], init[45], init[46], init[47]} =
                {8'h5F, 8'h3F, 8'h15, 8'h10, 8'h13, 8'h75, 8'h08, 8'h09};
            {pix[0], pix[1], pix[2], pix[3], pix[4], pix[5], pix[6], pix[7]} =
                {8'hF8, 8'h00, 8'h07, 8'hE0, 8'h00, 8'h1F, 8'hFF, 8'hFF};
            {pix[8], pix[9], pix[10], pix[11], pix[12], pix[13], pix[14], pix[15]} =
                {8'h00, 8'h00, 8'h84, 8'h10, 8'hFF, 8'hE0, 8'h07, 8'hFF};
            if (test == "oled_spi") begin
                for (k = 0; k < 48; k = k + 1) push_oled(1'b0, init[k]);
                for (k = 0; k < 16; k = k + 1) push_oled(1'b1, pix[k]);
                push_oled(1'b0, 8'hA4); push_oled(1'b1, 8'h3C); push_oled(1'b1, 8'h3D);
                push_oled(1'b0, 8'hA6); push_oled(1'b1, 8'h5A); push_oled(1'b1, 8'hA5);
                push_oled(1'b0, 8'hAF);
                push_oled(1'b0, 8'hE3);
            end
            if (test == "spi_mixed") begin
                // tests/soc/spi_mixed.S: 12 commands, then 64 pixels twice, pixel i = (5 i + 0x21) & 0xFF
                {init[0], init[1], init[2], init[3], init[4], init[5], init[6], init[7]} =
                    {8'hAE, 8'hA0, 8'h72, 8'hA1, 8'h00, 8'hA2, 8'h00, 8'hA4};
                {init[8], init[9], init[10], init[11]} = {8'hA8, 8'h3F, 8'h87, 8'h06};
                for (k = 0; k < 12; k = k + 1) push_oled(1'b0, init[k]);
                for (k = 0; k < 64; k = k + 1) push_oled(1'b1, (5 * k + 8'h21) & 8'hFF);
                for (k = 0; k < 64; k = k + 1) push_oled(1'b1, (5 * k + 8'h21) & 8'hFF);
            end
            if (test == "irq_stall")
                for (k = 0; k < 16; k = k + 1) begin push_oled(1'b0, 8'h55); push_oled(1'b0, 8'hAA); end
            if (test == "periph_access") begin
                push_oled(1'b0, 8'h81); push_oled(1'b0, 8'h7E); push_oled(1'b0, 8'h5A); push_oled(1'b0, 8'hC3);
            end
        end
    endtask

    // ── The SD runs' final checks: exact counts, from the model and from the program's report ─
    string  sd_detail = "";
    integer sd_busy = 3, exp_cmds, exp_baud;
    task automatic sd_checks;
        begin
            if ($value$plusargs("SD_BUSY=%d", sd_busy)) ;
            if (test == "spi_mixed") begin
                exp_cmds = 12 + 2 * (sd_busy - 3);
                if (sd.n_rd_blk != 1 || sd.n_wr_blk != 0) fail("spi_mixed: want 1 block read, 0 written");
                if (n_sdv != 2 || sdv[0] != 140 || sdv[1] != 512) fail("spi_mixed: the program's report is not {140 OLED bytes, 512 bytes checked}");
                if (oled_fin != sdv[0]) fail("spi_mixed: the SSD1331 byte count differs from the program's N_OLED");
                sd_detail = $sformatf("sd: %0d errors, %0d cmds, %0d blocks read, %0d bytes checked, oled: %0d bytes, %0d errors",
                                      sd.errors, sd.n_cmd, sd.n_rd_blk, sdv[1], oled_fin, oled.errors);
            end else begin
                exp_cmds = 10 + 2 * sd_busy;
                exp_baud = (test == "sd_b1") ? 1 : 2;
                if (sd.n_rd_blk != 4 || sd.n_wr_blk != 1) fail($sformatf("%s: sd read %0d blocks, wrote %0d; want 4 and 1", test, sd.n_rd_blk, sd.n_wr_blk));
                if (n_sdv != 3 || sdv[0] != 2048 || sdv[1] != 4 || sdv[2] != exp_baud)
                    fail($sformatf("%s: the program reports %0d values: bytes %0d, crc16 %0d, baud %0d; want 2048, 4, %0d",
                                   test, n_sdv, sdv[0], sdv[1], sdv[2], exp_baud));
                if (sd.sck_min_dt_ns < ((exp_baud == 1) ? 48.0 : 80.0))
                    fail($sformatf("%s: the data-phase SCK period was %0.1f ns", test, sd.sck_min_dt_ns));
                sd_detail = $sformatf("sd: %0d errors, %0d cmds, %0d blocks read, %0d written, %0d bytes checked, %0d crc16, baud %0d, race %0d",
                                      sd.errors, sd.n_cmd, sd.n_rd_blk, sd.n_wr_blk, sdv[0], sdv[1], sdv[2], sd.n_race);
            end
            if (sd.n_cmd != exp_cmds) fail($sformatf("%s: the card saw %0d commands, want %0d", test, sd.n_cmd, exp_cmds));
            if (sd.n_race != 0) fail($sformatf("%s: n_race = %0d, want 0", test, sd.n_race));
            if (sd.errors != 0) fail($sformatf("%s: %0d SD model errors", test, sd.errors));
        end
    endtask

    // ── Run ─────────────────────────────────────────────────────────────────
    integer    max_cycles, k;
    string     got_u, exp_u;
    initial begin
        if (!$value$plusargs("TEST=%s", test)) test = "";
        is_rb = (test == "sd_reboot_a") || (test == "sd_reboot_b");
        sd_used = ((test.len() >= 3 && test.substr(0, 2) == "sd_") && test != "sd_cs") || test == "spi_mixed";
        if ($value$plusargs("UART_FLOW=%d", k)) cts_pin = (k != 0);
        if (test == "pinmux") cts_pin = 1'b1;
        if (cts_pin) rp.set_flow(1'b1);
        if (test == "gamepad" || $test$plusargs("GAMEPAD")) begin
            gp_on = 1'b1; gp.present0 = 1'b0; gp.present1 = 1'b0; gp.pad0 = 12'h0; gp.pad1 = 12'h0;
            #100 gp.enable = 1'b1;
        end
        sd_fitted = sd_used && test != "sd_absent";
        expect_fail = $test$plusargs("EXPECT_FAIL");
        if (sd_used) begin rt_out = 12.5; rt_in = 12.5; end
        if ($value$plusargs("RT_OUT=%f", rt_out)) ;
        if ($value$plusargs("RT_IN=%f", rt_in)) ;
        if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)) max_cycles = sd_used ? 150_000_000 : 3_000_000;
        if (test == "oled_spi" || test == "spi_mixed") oled_fitted = 1'b1;
        if (test == "keypad")   kp_fitted = 1'b1;
        setup_oled;
        repeat (10) @(posedge clk);
        #1 rst = 1'b0;
        while (!done && cyc < max_cycles) @(posedge clk);
        if (!done) begin
            fail($sformatf("%s: no FINISH within %0d cycles (pc %h)", test, max_cycles, soc.cpu.pc));
        end else if (failed && expect_fail) begin
            $display("%s: negative control: FINISH fail code %h, value seen %h", test, result, value2);
            if (test == "sd_absent" && result != 32'h1) fail("sd_absent: want the CMD0 R1 timeout (code 1)");
        end else if (failed) begin
            fail($sformatf("%s: program check %h failed (value seen %h)", test, result, value2));
        end else if (passed && expect_fail) begin
            fail($sformatf("%s: the negative control passed: the program should have failed", test));
        end else if (passed) begin
            // Let the UART's last character reach the RP2350.
            repeat (16 * 3 * 12 * UART_DIV) @(posedge clk);   // (mb_div <= UART_DIV in every MB_UART run)
            if (rp.rx_n != rx_fin)
                fail($sformatf("%s: %0d UART byte(s) arrived after FINISH: the program did not drain TX", test, rp.rx_n - rx_fin));
            if (oled.nlog != oled_fin)
                fail($sformatf("%s: %0d SSD1331 byte(s) arrived after FINISH", test, oled.nlog - oled_fin));
            if (mb_uart) got_u = mb_pay; else got_u = rp.rx_str();
            exp_u = want_uart();
            if (got_u != exp_u)
                fail($sformatf("%s: the RP2350 received \"%s\" (%0d characters), want \"%s\" (%0d)",
                               test, got_u, got_u.len(), exp_u, exp_u.len()));
            if (oled_fin != n_want_oled)
                fail($sformatf("%s: the SSD1331 got %0d bytes, want %0d", test, oled_fin, n_want_oled));
            for (k = 0; k < oled_fin && k < n_want_oled; k = k + 1)
                if (oled.log[k] !== want_oled[k])
                    fail($sformatf("%s: SSD1331 byte %0d = {D/C %b, %h}, want {D/C %b, %h}", test, k,
                                   oled.log[k][8], oled.log[k][7:0], want_oled[k][8], want_oled[k][7:0]));
            if (sd_used && !is_rb) sd_checks;
            if (is_rb) begin
                if (!rb_seen) fail($sformatf("%s: the reboot never happened", test));
                if (rb_st != ((test == "sd_reboot_a") ? 1 : 2))
                    fail($sformatf("%s: the reboot hit SPI state %0d (1 = A, 2 = B), not the intended phase", test, rb_st));
                if (sd.n_race != ((test == "sd_reboot_a") ? 1 : 0))
                    fail($sformatf("%s: n_race = %0d, want %0d", test, sd.n_race, (test == "sd_reboot_a") ? 1 : 0));
                sd_detail = $sformatf("reboot in SPI state %0d, race %0d, cycle %0d", rb_st, sd.n_race, rb_cyc);
            end
            // Per-test coverage: the scenario each test is for really happened.
            if (test == "cache_ctl")
                $display("cache_ctl: 64 nops cold from PSRAM, EN = 1: %0d cycles with PBURST 0, %0d with PBURST 1", value2, value);
            if (test == "uart_hello") begin
                $display("uart_hello: part 1 (no polling) %0d stores waited %0d clocks; part 2 (LSR polled) %0d waited",
                         ph[5] - ph[4], ph[2] - ph[1], ph[6] - ph[5]);
                // the shifter and the one-byte THR take the first two stores without waiting; the
                // exact count (measured, stable: the stores are paced by the flash fetches) pins the depth,
                // so a deeper or shallower THR shows
                if (ph[5] - ph[4] != 13) fail($sformatf("uart_hello: %0d of 15 unpolled THR stores waited, want exactly 13", ph[5] - ph[4]));
                if (ph[3] != ph[2]) fail("uart_hello: a THR store waited although LSR.THRE was polled");
            end
            if (test == "uart_echo") begin
                $display("uart_echo: the RP2350 held characters for CTS %0d clocks; %0d characters sent against CTS",
                         ph[2] - ph[1], rp.tx_sent_cts_off);
                // 16550A (WO-50): RTS# drops only with fewer than two RX FIFO entries free, so the
                // popping program never holds the RP2350 back and nothing is sent against CTS.
                if (rp.tx_sent_cts_off != 0) fail("uart_echo: a character was sent against CTS");
            end
            if (test == "uart_linux") begin
                $display("uart_linux: %0d THR stores waited (%0d clocks)", uart_waits, uart_wait);
                // tx_chars writes one byte per THRE interrupt and never waits; the waits are the console
                // FIFO-path stress (16 stores in a row against the one-byte THR). The exact count (measured)
                // pins the depth
                // (with the instruction cache on the stores come faster: measured 30, stable for PBURST 0 and 1;
                // the count depends on the CPU speed, so each mode has its own exact number)
                if (uart_waits != (cache_en_arg ? 30 : 25))
                    fail($sformatf("uart_linux: %0d THR stores waited, want exactly %0d", uart_waits, cache_en_arg ? 30 : 25));
                if (rp.tx_sent_cts_off != 0) fail("uart_linux: a character was sent against CTS");
            end
            if (test == "audio") au_eval(4);
            if (test == "tune") au_eval(9);
            if (test == "pwm_linux") begin
                if (m2_n_hi != 0) fail($sformatf("pwm_linux phase 4: uo[2] high %0d clocks after PWM off and the default map", m2_n_hi));
            end
            if (test == "pinmux") begin
                $display("pinmux: the model held %0d clocks for CTS, %0d characters sent against CTS, %0d sent", cts_wait, rp.tx_sent_cts_off, rp.tx_sent);
                if (rp.tx_sent != 64) fail($sformatf("pinmux: the RP2350 sent %0d characters, want 64", rp.tx_sent));
                if (cts_wait == 0) fail("pinmux: RTS# never held the RP2350 back");
                if (rp.tx_sent_cts_off != 0) fail("pinmux: a character was sent against CTS");
                if (m7_n_hi != 0) fail($sformatf("pinmux: uo[7] high %0d clocks after PWM0 left the pin", m7_n_hi));
            end
            if (test == "oled_spi") begin
                $display("oled_spi: %0d SSD1331 bytes, %0d GPIO clocks waited, %0d RES# pulses, %0d timing violations flagged on the deliberate DIV 1 byte",
                         oled_fin, gpio_wait, res_fin, oled.n_expected);
                if (res_fin != 1) fail("oled_spi: want one RES# pulse");
            end
            if (test == "keypad") begin
                $display("keypad: %0d patterns scanned; the IN read that follows an OUT write came %0d clocks after it at the soonest",
                         kp_set, in_lag_min);
                if (kp_set != 28) fail("keypad: not every pattern was scanned");
            end
            if (test == "irq_stall") begin
                $display("irq_stall: interrupts pending during a held store: THR %0d of %0d, SPI TXDATA %0d of %0d, amoswap %0d of %0d",
                         irq_hits[1], irq_n[1], irq_hits[2], irq_n[2], irq_hits[3], irq_n[3]);
                if (irq_n[1] != 12 || irq_n[2] != 16 || irq_n[3] != 9) fail("irq_stall: wrong interrupt count");
                if (irq_hits[1] == 0 || irq_hits[2] == 0 || irq_hits[3] == 0)
                    fail("irq_stall: some part never had its interrupt arrive during the held store");
            end
        end
        if (rp.errors != 0) fail($sformatf("%s: %0d RP2350 UART errors", test, rp.errors));
        if (oled.errors != 0) fail($sformatf("%s: %0d SSD1331 errors", test, oled.errors));
        if (sd_used && !is_rb && !expect_fail && sd.errors != 0) fail($sformatf("%s: %0d SD model errors", test, sd.errors));
        if (errors == 0 && sd_used && expect_fail) $display("PASS %s (expected FINISH fail code seen)", test);
        else if (errors == 0 && sd_used) $display("PASS %s (%s)", test, sd_detail);
        else if (errors == 0) $display("PASS tb_soc_periph %s (%0d cycles)", test, cyc);
        else             $display("FAIL tb_soc_periph %s: %0d errors", test, errors);
        $finish;
    end
endmodule
