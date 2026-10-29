// Pin-level testbench for the TinyTapeout top level
// (src/tt_um_alfadelta10010_alphaone_soc.v). It touches the design through
// its 24 project pins, clk and rst_n and nothing else -- no reference into
// the design -- so the same bench runs on a gate-level netlist of the top
// level (compile with -DUSE_POWER_PINS for one that has power pins). The
// board around the pins is wired here from the pinout table in
// docs/pins-and-peripherals.md, not from the wrapper:
//
//   * tb/qspi_pmod_model.v on uio, with what the Pmod does to a released
//     pin: the chip selects are pulled up, SCK and SD0..SD3 float (X);
//   * tb/rp2350_uart_model.v on uo_out[4] (TX), ui_in[3] (RX) and
//     uo_out[5] (RTS#, its CTS);
//   * the testbench itself on the GPIO pins and on ui_in[0], the
//     qspi_rd_late strap during reset.
//
// tests/soc/tt_pins.S runs from the Pmod model's flash (+FLASH_FILE=) and
// reports over the UART; its header lists the cues. It is reset three times
// on the way, and has to start again each time:
//
//   1. as the demo board's firmware does it: the clock stopped, rst_n pulsed
//      low, and the clock started only afterwards;
//   2. with the clock running, off the clock edge, in the middle of a flash
//      read, while the flash is driving the bus; held for six clocks;
//   3. the same, but a pulse shorter than a clock that no clock edge sees.
//
// Checked:
//
//   * in reset -- from 2 ns after rst_n falls until the second clock edge
//     after it rises, clock or no clock -- uio_oe is 0 and uo_out is 0x39 (TX
//     and RTS# high, GPIO OUT 0x09). The SoC then drives SCK and the chip
//     selects on the third edge, no sooner and no later, which fixes the
//     length of the reset's release at the pins;
//   * the four SCK / chip select output enables are one signal, and the four
//     SD ones another;
//   * from the first reset on, no X on uo_out, on uio_oe, or on a uio_out pin
//     that is driven;
//   * GPIO OUT on uo_out[7:6] and [3:0], GPIO IN from all of ui_in;
//   * RTS# high while the received byte waits to be read;
//   * PSRAM A on uio[6] and PSRAM B on uio[7], flash on uio[0];
//   * the strap: +RD_LATE holds ui_in[0] at 1 through each reset, and the run
//     then needs the Pmod model's +QSPI_DELAY=25 +QSPI_HOLD=12, which only
//     rd_late = 1 can read; without it ui_in[0] is 0. After the last reset
//     ui_in[0] flips 1 ns after the second clock edge, the earliest it is
//     allowed to, and later it is GPIO IN 0: neither may move the sampling
//     point.
//
// +TEST=reboot runs tests/soc/tt_reboot.S instead, from phase 1 above only
// (the program does its own resets, through the syscon). Pins only again:
//
//   * a reboot (FINISH 0x7777) looks at the pins like a pin reset after rst_n
//     rises: from the first falling clock edge with uio_oe[3] low, two samples
//     with uio_oe 0 and uo_out 0x39, the third with SCK and the chip selects
//     driven again. The window starts within a bound of the program's cue
//     byte ('r', 'R'); each pin changes at most once into it and once out of
//     it, never twice at one time stamp, and only just after a clock edge;
//   * the program's bytes (RESET_CAUSE, BOOT_MODE, STRAPS, CHIP_ID) are the
//     spec's, in tb/syscon_spec.vh and docs/ROADMAP.md 1.2, not read from src/;
//   * the strap is latched once: every STRAPS byte is the value at the last
//     pin reset, whatever ui_in[0] does since. With +RD_LATE the later boots
//     can fetch only if the engine kept rd_late = 1.
//
// +TEST=isa and +TEST=sig run real programs (tests/isa, scripts/gl) through
// the same pins. The program reports over the UART and powers off:
//
//   isa  'P' (pass), or 'F' and four bytes, gp/TESTNUM little-endian (fail);
//   sig  'S' (and, with +SIG_UART, the signature words raw, little-endian).
//
// then, within 20,000 clocks of the report, the pins must show the power-off
// (uio_oe 0, uo_out 0x39) and hold it for 200 clocks, so every program also
// exercises syscon's `off` path. For sig the bench then reads the signature
// from the board's PSRAM, the Pmod model outside the chip, from SIG_BEGIN up
// to SIG_END (+SIG_BEGIN=<hex> +SIG_END=<hex>), writes it to +SIG_OUT=<file>
// (8 hex digits a line, RISCOF's format) and compares it with +SIG_REF=<file>,
// Spike's signature. With +SIG_UART the UART copy must equal the PSRAM copy.
//
// On a gate-level netlist run it with +RF_X (the register file macro model
// starts at X, as the silicon does) and +RF_COLLIDE_X, like the TT test. Every
// flop of the netlist starts at X too, with no initialisation: the strictest
// X case. Random initial flop values are left out on purpose: in Icarus the
// state sits inside the cell UDPs and cannot be set cheaply, and the X start
// is the more pessimistic of the two.
//
// Gate level: scripts/gl/run_gl.sh compiles this bench against a LibreLane
// netlist (the pnl with power pins, -DUSE_POWER_PINS, plus TT's usual defines
// -DGL_TEST -DFUNCTIONAL -DSIM -DUNIT_DELAY=#0 for the cell models). That is a
// zero-delay functional run: this is not an SDF-timed bench, and the TCLK_NS /
// IN_DLY_NS defines below only exist for a one-off SDF run. Timing sign-off is
// STA in the harden, not a simulation.
//
// Limits: in zero-delay RTL every flop changes at the same time stamp, so a
// hazard between two flops through a gate cannot show (the uo_out[1] / [3]
// mux while the SPI transmitter is on). The per-pin check catches extra edges
// between clock edges and windows with more than one edge; the real glitch
// check is this bench on the SDF-annotated netlist.

`timescale 1ns / 1ps

// For a simulation with real delays (an SDF-annotated netlist) the clock
// period, the two inputs driven just after an edge, and the reset-to-pins
// check are defines. The defaults are this bench as it always ran. With
// delays, IN_DLY_NS belongs at the SDC's input delay (0.2 * TCLK_NS): 1 ns is
// inside the window STA assumes no input moves in, and a release there can
// beat the clock edge it follows to the flops. The Pmod model's delays are
// nanoseconds for a 10 ns clock; scale them with TCLK_NS.
`ifndef TCLK_NS
`define TCLK_NS 10.0
`endif
`ifndef IN_DLY_NS
`define IN_DLY_NS 1
`endif
`ifndef RST_CHK_NS
`define RST_CHK_NS 2
`endif

module tb_tt_um;
    localparam real    TCLK  = `TCLK_NS;  // 10 by default, as tb_qspi: the Makefile's QSPI delays assume it
    localparam integer N_OUT = 9;     // tests/soc/tt_pins.S has the same two
    localparam integer N_IN  = 9;

    reg clk = 1'b0;
    reg clk_on = 1'b0;                // the board's clock is running
    always #(TCLK / 2.0) if (clk_on) clk = ~clk;
    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    reg        rst_n = 1'b1;
    reg        rd_late = 1'b0;        // +RD_LATE
    reg        strap = 1'b0;          // ui_in[0] until the program wants GPIO IN
    reg        strap_on = 1'b1;       // ui_in[0] is the strap, not tb_in[0]
    reg  [7:0] tb_in = 8'h00;
    wire       uart_rx;
    reg        kp_fit = 1'b0, oled_fit = 1'b0;   // +TEST=soc: the PmodKYPD / PmodOLEDrgb are fitted
    reg [15:0] keys = 16'h0000;
    wire [3:0] kp_row;
    wire [7:0] ui_in = {kp_fit ? kp_row : tb_in[7:4], uart_rx, tb_in[2:1], strap_on ? strap : tb_in[0]};
    wire [7:0] uo_out, uio_out, uio_oe;
    wire [7:0] uio_pin;
`ifdef USE_POWER_PINS
    // Nets, not constants: a hardened netlist declares its power pins inout.
    wire       VPWR = 1'b1;
    wire       VGND = 1'b0;
`endif

    tt_um_alfadelta10010_alphaone_soc dut (
`ifdef USE_POWER_PINS
        .VPWR(VPWR), .VGND(VGND),
`endif
        .ui_in(ui_in), .uo_out(uo_out), .uio_in(uio_pin), .uio_out(uio_out), .uio_oe(uio_oe),
        .ena(1'b1), .clk(clk), .rst_n(rst_n));

    // ── The QSPI Pmod on uio ────────────────────────────────────────────────
    wire [3:0] pmod_io;
    wire       pmod_oe;
    // SD0..SD3 are uio[1], [2], [4], [5]; each pin has its own output enable.
    wire [3:0] sd_out = {uio_out[5], uio_out[4], uio_out[2], uio_out[1]};
    wire [3:0] sd_oe  = {uio_oe[5],  uio_oe[4],  uio_oe[2],  uio_oe[1]};
    wire [3:0] host_io = {sd_oe[3] ? sd_out[3] : 1'bx, sd_oe[2] ? sd_out[2] : 1'bx,
                          sd_oe[1] ? sd_out[1] : 1'bx, sd_oe[0] ? sd_out[0] : 1'bx};
    wire [3:0] sd_pin = pmod_oe ? pmod_io : host_io;
    assign uio_pin = {uio_oe[7] ? uio_out[7] : 1'b1,     // CS2: pulled up
                      uio_oe[6] ? uio_out[6] : 1'b1,     // CS1: pulled up
                      sd_pin[3], sd_pin[2],
                      uio_oe[3] ? uio_out[3] : 1'bx,     // SCK: floats
                      sd_pin[1], sd_pin[0],
                      uio_oe[0] ? uio_out[0] : 1'b1};    // CS0: pulled up

    qspi_pmod_model pmod (
        .host_sck(uio_out[3]), .host_cs_n({uio_out[7], uio_out[6], uio_out[0]}),
        .host_ctl_oe(uio_oe[3]), .host_io(host_io), .host_oe(&sd_oe),
        .dev_io(pmod_io), .dev_oe(pmod_oe));

    // ── The RP2350's UART: 16 clocks a bit, the divisor tt_pins.S sets ──────
    rp2350_uart_model #(.BIT_NS(16.0 * TCLK)) rp (
        .tx(uo_out[4]), .rx(uart_rx), .cts_n(uo_out[5]));

    // The demo board's other devices, on the pins as tests/soc programs use them
    // (docs/pins-and-peripherals.md): the SSD1331 on CS# [0], MOSI [1], D/C [2],
    // SCK [3], RES# [6]; the keypad's columns on [3:0], its rows on ui_in[7:4].
    ssd1331_model oled (.fitted(oled_fit), .cs_n(uo_out[0]), .sck(uo_out[3]), .mosi(uo_out[1]),
                        .dc(uo_out[2]), .res_n(uo_out[6]));
    keypad_model kp (.col(uo_out[3:0]), .pressed(keys), .row(kp_row));

`ifdef SDF_FILE
    initial $sdf_annotate(`SDF_FILE, dut);
`endif

    integer errors = 0;
    task automatic fail(input string m);
        begin
            errors = errors + 1;
            if (errors <= 40) $display("FAIL %s (cycle %0d)", m, cyc);
        end
    endtask

    // ── Reset at the pins ───────────────────────────────────────────────────
    // The chip is in reset from rst_n falling to the second clock edge after
    // it rises. `edges` counts the clock edges since then, up to 3.
    reg     reset_seen = 1'b0;
    integer edges = 3;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) edges = 0;
        else if (edges < 3) edges = edges + 1;
    always @(negedge rst_n) reset_seen = 1'b1;
    wire in_reset = !rst_n || edges < 2;

    task automatic check_reset_pins(input string when);
        begin
            if (uio_oe !== 8'h00) fail($sformatf("uio_oe = %b %s", uio_oe, when));
            if (uo_out !== 8'h39) fail($sformatf("uo_out = %h %s, want 39", uo_out, when));
        end
    endtask

    // 2 ns after rst_n falls, wherever the clock is.
    always @(negedge rst_n) begin
        #(`RST_CHK_NS);
        if (!rst_n) check_reset_pins($sformatf("%0g ns after rst_n fell", 1.0 * `RST_CHK_NS));
    end

    // ── Checks on every clock ───────────────────────────────────────────────
    wire [5:0] gpio_pins = {uo_out[7:6], uo_out[3:0]};
    integer i;
    integer edges_q = 3;              // `edges` at the previous falling edge
    always @(negedge clk) if (reset_seen) begin
        if (uio_oe[0] !== uio_oe[3] || uio_oe[6] !== uio_oe[3] || uio_oe[7] !== uio_oe[3])
            fail($sformatf("uio_oe = %b: the SCK and chip select enables differ", uio_oe));
        if (uio_oe[2] !== uio_oe[1] || uio_oe[4] !== uio_oe[1] || uio_oe[5] !== uio_oe[1])
            fail($sformatf("uio_oe = %b: the SD0..SD3 enables differ", uio_oe));
        if (^uio_oe === 1'bx) fail($sformatf("uio_oe = %b has an X", uio_oe));
        if (^uo_out === 1'bx) fail($sformatf("uo_out = %b has an X", uo_out));
        for (i = 0; i < 8; i = i + 1)
            if (uio_oe[i] === 1'b1 && uio_out[i] === 1'bx)
                fail($sformatf("uio_out[%0d] is driven with an X", i));
        if (in_reset) check_reset_pins("in reset");
        // The two edges after rst_n rises are the SoC's reset. On the third
        // qspi_ctrl drives SCK and the chip selects (its ctl_oe is 0 only in
        // reset), so a release one edge shorter or longer shows here.
        if (rst_n && edges == 2) check_reset_pins("after the second clock edge out of reset");
        if (rst_n && edges == 3 && edges_q == 2 && uio_oe[3] !== 1'b1)
            fail("SCK and the chip selects not driven on the third clock edge out of reset");
        edges_q = edges;
    end

    // Chip select falls and SCK edges at the pins.
    integer cs0_falls = 0, cs1_falls = 0, cs2_falls = 0, sck_rises = 0;
    always @(negedge uio_pin[0]) cs0_falls = cs0_falls + 1;
    always @(negedge uio_pin[6]) cs1_falls = cs1_falls + 1;
    always @(negedge uio_pin[7]) cs2_falls = cs2_falls + 1;
    always @(posedge uio_pin[3]) sck_rises = sck_rises + 1;

    // ── The program's UART stream ───────────────────────────────────────────
    reg [7:0] out_vals [0:N_OUT-1];
    reg [7:0] in_pats  [0:N_IN-1];
    initial begin
        // out_vals of tests/soc/tt_pins.S
        out_vals[0] = 8'h01; out_vals[1] = 8'h02; out_vals[2] = 8'h04; out_vals[3] = 8'h08;
        out_vals[4] = 8'h40; out_vals[5] = 8'h80; out_vals[6] = 8'hFF; out_vals[7] = 8'h00;
        out_vals[8] = 8'h09;
        in_pats[0] = 8'h01; in_pats[1] = 8'h02; in_pats[2] = 8'h04; in_pats[3] = 8'h10;
        in_pats[4] = 8'h20; in_pats[5] = 8'h40; in_pats[6] = 8'h80; in_pats[7] = 8'h00;
        in_pats[8] = 8'hF7;
    end

    string    testname = "";
    reg       reboot_test = 1'b0;     // +TEST=reboot
    reg       isa_test = 1'b0;        // +TEST=isa or +TEST=sig
    reg       sig_test = 1'b0;        // +TEST=sig
    reg       sig_uart = 1'b0;        // +SIG_UART
    reg [31:0] sig_begin = 32'h0, sig_end = 32'h0, fail_num = 32'h0;
    integer   rep_state = 0;          // 0 first byte, 1 failing TESTNUM, 2 UART signature, 3 reported
    integer   rep_n = 0;
    reg       rep_done = 1'b0;        // the program has reported
    reg [7:0] usig [0:65535];
    reg [31:0] sig_ref [0:16383];
    string    sig_ref_file = "", sig_out_file = "";
    integer   seen = 0;               // bytes of the stream handled
    integer   n_rx0 = 0;              // rp.rx_n when the stream began
    reg       done = 1'b0;
    integer   snap1, snap2;
    reg [7:0] want;

    function automatic [31:0] ram_word(input integer a);
        ram_word = {pmod.ram_rd(a + 3), pmod.ram_rd(a + 2), pmod.ram_rd(a + 1), pmod.ram_rd(a)};
    endfunction

    // ── tests/soc/tt_reboot.S: the expected stream, from the spec ───────────
    // Nine bytes a boot: its letter, RESET_CAUSE, BOOT_MODE, STRAPS, CHIP_ID
    // (4), then the cue for the next reboot. RESET_CAUSE accumulates.
    localparam integer RB_N = 37;     // bytes of the stream, the final 'Z' included
    reg [31:0] rb_letters = "bBCD";
    reg [31:0] rb_cues    = "rRwp";
    reg [31:0] rb_cause   = {8'h07, 8'h03, 8'h03, 8'h01};
    reg [31:0] rb_bm      = {8'hA5, 8'hA5, 8'h5A, 8'h00};
    reg [31:0] rb_chip    = 32'h4131_5301;   // CHIP_ID, user-confirmed
    function automatic [7:0] rb_exp(input integer idx);
        integer k, j;
        begin
            k = idx / 9; j = idx % 9;
            if (idx == RB_N - 1) rb_exp = "Z";
            else case (j)
                0: rb_exp = rb_letters[8 * (3 - k) +: 8];
                1: rb_exp = rb_cause[8 * k +: 8];
                2: rb_exp = rb_bm[8 * k +: 8];
                3: rb_exp = {7'b0, rd_late};          // latched at the last pin reset
                8: rb_exp = rb_cues[8 * (3 - k) +: 8];
                default: rb_exp = rb_chip[8 * (j - 4) +: 8];
            endcase
        end
    endfunction

    // The reboot window at the pins, timed from the cue byte. wstate: 0 idle,
    // 1 waiting for the window, 2 second low sample, 3 the third sample,
    // 4 the 10 clocks after it. phase: 1 from the cue to the window, 2 from
    // the window on (the per-pin transition counts below).
    reg [7:0] cue_chr = 8'h00;
    integer wstate = 0, phase = 0, cue_cyc = 0, cue_kind = 0, w_lo = 0, w_hi = 0, w_post = 0;
    integer win_dist = 0;
    integer cnt [0:15];
    integer ci;
    initial for (ci = 0; ci < 16; ci = ci + 1) cnt[ci] = 0;

    reg po_arm = 1'b0;                // the cue 'p' has arrived: power-off watch
    task automatic rb_cue(input [7:0] chr, input integer kind, input integer lo, input integer hi);
        integer n;
        begin
            cue_cyc = cyc; cue_chr = chr; cue_kind = kind; w_lo = lo; w_hi = hi;
            for (n = 0; n < 16; n = n + 1) cnt[n] = 0;
            wstate = 1; phase = 1;
        end
    endtask

    task automatic on_byte_reboot(input [7:0] b);
        integer k, j;
        begin
            k = seen / 9; j = seen % 9;
            if (seen >= RB_N) fail($sformatf("byte %h after the end of the stream", b));
            else if (b !== rb_exp(seen))
                fail($sformatf("byte %0d is %h, want %h", seen, b, rb_exp(seen)));
            else if (seen == RB_N - 1) done = 1'b1;
            else if (j == 8) begin
                case (b)
                    "r", "R": rb_cue(b, k, 0, 4000);
                    // The kick comes after the cue: the timeout (2^16 clocks) is
                    // more than 65,536 clocks from the cue, and at most 1.5 timeouts
                    // + 1 (E1) from the kick, which is CUE_TO_KICK clocks at most
                    // after the cue.
                    "w": rb_cue(b, k, 65536, 98305 + 1 + 1000);
                    "p": po_arm = 1'b1;
                    default: ;
                endcase
            end
        end
    endtask

    reg        soc_test = 1'b0;                 // +TEST=soc
    // the program, as a number (a case on a string does not compile in Icarus)
    localparam integer ID_uart_hello = 1;
    localparam integer ID_uart_echo = 2;
    localparam integer ID_uart_linux = 3;
    localparam integer ID_oled_spi = 4;
    localparam integer ID_keypad = 5;
    localparam integer ID_irq_stall = 6;
    localparam integer ID_periph_access = 7;
    localparam integer ID_clint_decode = 8;
    localparam integer ID_syscon_regs = 9;
    localparam integer ID_syscon_reboot = 10;
    localparam integer ID_syscon_strap = 11;
    localparam integer ID_syscon_fail = 12;
    localparam integer ID_syscon_wdt = 13;
    localparam integer ID_syscon_wdt_split = 14;
    localparam integer ID_syscon_poweroff = 15;
    localparam integer ID_syscon_pinreset = 16;
    integer pid = 0;
    function automatic integer prog_id(input string p);
        begin
            prog_id = 0;
            if (p == "uart_hello") prog_id = ID_uart_hello;
            if (p == "uart_echo") prog_id = ID_uart_echo;
            if (p == "uart_linux") prog_id = ID_uart_linux;
            if (p == "oled_spi") prog_id = ID_oled_spi;
            if (p == "keypad") prog_id = ID_keypad;
            if (p == "irq_stall") prog_id = ID_irq_stall;
            if (p == "periph_access") prog_id = ID_periph_access;
            if (p == "clint_decode") prog_id = ID_clint_decode;
            if (p == "syscon_regs") prog_id = ID_syscon_regs;
            if (p == "syscon_reboot") prog_id = ID_syscon_reboot;
            if (p == "syscon_strap") prog_id = ID_syscon_strap;
            if (p == "syscon_fail") prog_id = ID_syscon_fail;
            if (p == "syscon_wdt") prog_id = ID_syscon_wdt;
            if (p == "syscon_wdt_split") prog_id = ID_syscon_wdt_split;
            if (p == "syscon_poweroff") prog_id = ID_syscon_poweroff;
            if (p == "syscon_pinreset") prog_id = ID_syscon_pinreset;
        end
    endfunction
    // ── +TEST=soc +PROG=<name>: the mailbox programs of tests/soc ───────────
    // Everything below reads the pins and the boards around them (pmod, rp,
    // oled, kp), never the design. The program reports over the UART in
    // frames (tests/soc/periph.h, -DMB_UART): 0x10 code (a cue), 0x11 / 0x12 /
    // 0x13 and four bytes LE (VALUE, VALUE2, FINISH); every other byte is the
    // program's own traffic. Each program's row is in soc_setup.
    string     prog = "";
    integer    s_div = 1;                // the RP2350's divisor at the start
    reg        s_expect_fail = 1'b0;     // syscon_fail: FINISH (0x5A << 16) | 0x3333, VALUE2 0x1234
    integer    s_n_ev = 0, s_n_val = 0;
    integer    s_ev [0:31];              // the cue codes, in order
    reg [31:0] s_val [0:31];             // the VALUE frames, where the row knows them
    reg        s_val_known = 1'b0;
    integer    s_ev_i = 0, s_val_i = 0;
    string     s_pay = "", s_want = "";
    integer    s_exp_re = 0, s_exp_po = 1, s_exp_cut = 0;
    reg        s_fin = 1'b0, s_v2_seen = 1'b0;
    reg [31:0] s_fin_word = 32'h0, s_v2 = 32'h0, s_last_val = 32'h0;
    integer    s_oled_fin = 0, s_rx_fin = 0, s_win_fin = 0;
    reg [8:0]  want_oled [0:127];
    integer    n_want_oled = 0;
    integer    po_lim = 3000;            // clocks from the cue 'p' / 0x53 to the power-off
    integer    fr_st = 0, fr_tag = 0, fr_n = 0;
    reg [31:0] fr_acc = 32'h0;
    integer    s_cue_cyc = 0, s_strap_cyc = 0, s_cts0 = 0, s_cts1 = 0, s_cts_wait = 0;
    integer    s_lo = 0, s_hi = 0, s_d_last = 0;
    reg [31:0] s_mt [0:7];
    reg [15:0] kp_sets [0:27];
    integer    ki;
    initial begin
        for (ki = 0; ki < 16; ki = ki + 1) kp_sets[ki] = 16'h1 << ki;      // each key alone
        kp_sets[16] = 16'h0000; kp_sets[17] = 16'h8421; kp_sets[18] = 16'h1248;
        kp_sets[19] = 16'h1111; kp_sets[20] = 16'h2222; kp_sets[21] = 16'h4444;
        kp_sets[22] = 16'h8888; kp_sets[23] = 16'h4812; kp_sets[24] = 16'h2184;
        kp_sets[25] = 16'h0021; kp_sets[26] = 16'h1200; kp_sets[27] = 16'h0000;
    end

    // The reboot / power-off windows, generically (the form of tt_reboot's
    // detector): a window opens at the first falling clock edge with
    // uio_oe[3] low while rst_n has been high for 3 edges; two low samples and
    // a driven third are a reboot, 200 low samples a power-off; a pin reset
    // inside it is a cut.
    integer    sw_on = 0, sw_st = 0, sw_low = 0, sw_n = 0, sw_re = 0, sw_po = 0, sw_cut = 0;
    integer    sw_fl = 0, sw_a = 0, sw_b = 0, sw_idle = 0, sw_split = 0, sw_data = 0, sw_fl_ok = 0;
    reg [2:0]  sw_prev = 3'b111;         // {CS2, CS1, CS0} at the previous sample
    reg [23:0] a_start = 24'hFFFFFF;     // PSRAM A: the address the latest read began at (when it started driving)
    always @(posedge pmod_oe) if (soc_test && uio_pin[6] === 1'b0 && pmod.cmd === 8'h0B) a_start = pmod.addr;
    reg        fl_arm = 1'b0;            // the first flash read after a reboot must be at address 0
    reg        pr_arm = 1'b0;            // a pin reset inside the next window
    reg [7:0]  pr_in = 8'h00;
    integer    sw_dist;
    event      pr_go;

    task automatic push_oled(input dc, input [7:0] b);
        begin want_oled[n_want_oled] = {dc, b}; n_want_oled = n_want_oled + 1; end
    endtask

    task automatic soc_setup;
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
            s_div = 1; s_exp_re = 0; s_exp_po = 1; s_exp_cut = 0;
            case (pid)
                ID_uart_hello: begin
                    s_div = 27; s_want = "Hello, world!\015\nHello, world!\015\n";
                end
                ID_uart_echo: begin
                    s_div = 4; s_want = "The quick brown fox jumps over the lazy dog, 0123456789!\015\n";
                    s_n_ev = 3; s_ev[0] = 1; s_ev[1] = 2; s_ev[2] = 3;
                end
                ID_uart_linux: begin
                    s_div = 4;
                    s_want = {"earlycon: AlphaOne\015\n",
                              "tx_chars 0123456789 abcdefghijklmnopqrstuvwxyz ABCDEF\015\n",
                              "console: polled\015\n", "console: fifo path, 16 at a time\015\n"};
                    s_n_ev = 2; s_ev[0] = 4; s_ev[1] = 5;
                    s_n_val = 1; s_val_known = 1'b1; s_val[0] = 32'd4;   // VALUE s5: four tx_chars bursts
                end
                ID_oled_spi: begin
                    s_div = 1; oled_fit = 1'b0;
                    s_n_ev = 2; s_ev[0] = 9; s_ev[1] = 10;
                    for (k = 0; k < 48; k = k + 1) push_oled(1'b0, init[k]);
                    for (k = 0; k < 16; k = k + 1) push_oled(1'b1, pix[k]);
                    push_oled(1'b0, 8'hA4); push_oled(1'b1, 8'h3C); push_oled(1'b1, 8'h3D);
                    push_oled(1'b0, 8'hA6); push_oled(1'b1, 8'h5A); push_oled(1'b1, 8'hA5);
                    push_oled(1'b0, 8'hAF);
                    push_oled(1'b0, 8'hE3);
                end
                ID_keypad: begin
                    s_div = 1; kp_fit = 1'b1;
                    s_n_ev = 28; s_n_val = 28; s_val_known = 1'b1;
                    for (k = 0; k < 28; k = k + 1) begin s_ev[k] = 1; s_val[k] = {16'h0, kp_sets[k]}; end
                end
                ID_irq_stall: begin
                    s_div = 4;
                    for (k = 0; k < 12; k = k + 1) s_want = {s_want, "AB"};
                    for (k = 0; k < 9; k = k + 1)  s_want = $sformatf("%sP%c", s_want, 8'h5A);
                    s_n_ev = 9; for (k = 0; k < 9; k = k + 1) s_ev[k] = 4;
                    for (k = 0; k < 16; k = k + 1) begin push_oled(1'b0, 8'h55); push_oled(1'b0, 8'hAA); end
                end
                ID_periph_access: begin
                    s_div = 27; s_want = "ABq";
                    s_n_ev = 12;
                    s_ev[0] = 'h10; s_ev[1] = 'h10; s_ev[2] = 'h20; s_ev[3] = 'h20; s_ev[4] = 'h20;
                    s_ev[5] = 'h21; s_ev[6] = 'h20; s_ev[7] = 'h20; s_ev[8] = 'h20; s_ev[9] = 'h20;
                    s_ev[10] = 'h30; s_ev[11] = 'h20;
                    s_n_val = 10; s_val_known = 1'b1;
                    s_val[0] = "q"; s_val[1] = "m"; s_val[2] = 8'h09; s_val[3] = 8'hCF; s_val[4] = 8'h81;
                    s_val[5] = 8'hC1; s_val[6] = 8'h41; s_val[7] = 8'h4E; s_val[8] = 8'h49; s_val[9] = 8'h49;
                    push_oled(1'b0, 8'h81); push_oled(1'b0, 8'h7E); push_oled(1'b0, 8'h5A); push_oled(1'b0, 8'hC3);
                end
                ID_clint_decode: s_div = 1;
                ID_syscon_regs: s_div = 1;
                ID_syscon_reboot: begin
                    s_div = 27; s_n_val = 5; s_exp_re = 4;
                end
                ID_syscon_strap: begin
                    s_div = 1; s_n_ev = 1; s_ev[0] = 'h52; s_n_val = 1; s_val_known = 1'b1;
                    s_val[0] = {31'b0, rd_late}; s_exp_re = 1;
                end
                ID_syscon_fail: begin s_div = 1; s_expect_fail = 1'b1; end
                ID_syscon_wdt: begin
                    s_div = 1; s_n_ev = 1; s_ev[0] = 'h56; s_n_val = 1; s_val_known = 1'b1;
                    s_val[0] = 32'd1; s_exp_re = 1;
                end
                ID_syscon_wdt_split: begin s_div = 1; s_exp_re = 12; end
                ID_syscon_poweroff: begin
                    s_div = 1; s_n_ev = 1; s_ev[0] = 'h53; s_exp_po = 2; po_lim = 10000;
                end
                ID_syscon_pinreset: begin
                    s_div = 1; s_n_ev = 3; s_ev[0] = 'h54; s_ev[1] = 'h55; s_ev[2] = 'h57;
                    s_exp_re = 1; s_exp_cut = 2;
                end
                default: fail($sformatf("+PROG=%s: not a program of this bench", prog));
            endcase
            // no payload byte may look like a frame tag
            for (k = 0; k < s_want.len(); k = k + 1)
                if (s_want[k] >= 8'h10 && s_want[k] <= 8'h13) fail("an expected payload byte starts a frame");
        end
    endtask

    task automatic soc_event(input [7:0] code);
        begin
            s_cue_cyc = cyc;
            if (s_ev_i >= s_n_ev) fail($sformatf("an unexpected cue %h (after %0d cues)", code, s_ev_i));
            else if (s_ev[s_ev_i] != code)
                fail($sformatf("cue %0d is %h, want %h", s_ev_i, code, s_ev[s_ev_i]));
            case (pid)
                ID_uart_echo: begin
                    if (code == 1) begin rp.set_flow(1'b1); rp.send_str("The quick brown fox jumps over the lazy dog, 0123456789!\015\n"); s_cts0 = s_cts_wait; end
                    if (code == 2) begin s_cts1 = s_cts_wait; rp.set_flow(1'b0); rp.send_str("XYZ"); end
                    if (code == 3) rp.set_flow(1'b1);
                end
                ID_uart_linux: begin
                    if (code == 4) rp.set_baud(16.0 * 3 * TCLK);
                    if (code == 5) begin rp.set_flow(1'b1); rp.send_str("ls -l /dev\015"); end
                end
                ID_oled_spi: begin
                    if (code == 9) oled.expect_violations = 1'b1;
                    if (code == 10) begin
                        oled.expect_violations = 1'b0;
                        if (oled.n_expected == 0) fail("oled_spi: a byte at DIV 1 (80 ns SCK) raised no SSD1331 timing error");
                    end
                end
                ID_keypad: if (code == 1 && s_ev_i < 28) keys = kp_sets[s_ev_i];
                ID_irq_stall: rp.send_byte("a" + s_ev_i);
                ID_periph_access: begin
                    if (code == 'h10) rp.send_byte(s_last_val[7:0]);
                    if (code == 'h20 && gpio_pins !== {s_last_val[7:6], s_last_val[3:0]})
                        fail($sformatf("periph_access: OUT = %h, uo_out[7:6], [3:0] = %b, want %b", s_last_val,
                                       gpio_pins, {s_last_val[7:6], s_last_val[3:0]}));
                    if (code == 'h21) tb_in = 8'hA4;
                    if (code == 'h30) oled_fit = 1'b1;
                end
                ID_syscon_strap: begin strap = !rd_late; s_strap_cyc = cyc; end
                ID_syscon_wdt: begin s_lo = 65536; s_hi = 98305 + 1 + 1000; end
                ID_syscon_poweroff: po_arm = 1'b1;
                ID_syscon_pinreset: begin
                    if (code == 'h54) begin pr_arm = 1'b1; pr_in = 8'h80; end
                    if (code == 'h57) begin pr_arm = 1'b1; pr_in = 8'h40; s_lo = 65536; s_hi = 98305 + 1 + 4000; end
                end
                default: ;
            endcase
            s_ev_i = s_ev_i + 1;
        end
    endtask

    task automatic soc_frame(input integer tag, input [31:0] w);
        begin
            if (tag == 'h11) begin
                s_last_val = w;
                if (s_val_i >= s_n_val) fail($sformatf("an unexpected VALUE %h (after %0d)", w, s_val_i));
                else begin
                    if (s_val_known && w !== s_val[s_val_i])
                        fail($sformatf("VALUE %0d is %h, want %h", s_val_i, w, s_val[s_val_i]));
                    if (prog == "syscon_reboot") s_mt[s_val_i] = w;
                end
                s_val_i = s_val_i + 1;
            end else if (tag == 'h12) begin
                s_v2 = w; s_v2_seen = 1'b1;
            end else begin
                s_fin = 1'b1; s_fin_word = w;
                s_oled_fin = oled.nlog; s_rx_fin = rp.rx_n; s_win_fin = sw_n;
                if (s_expect_fail) begin
                    if (w !== {16'h005A, 16'h3333} || !s_v2_seen || s_v2 !== 32'h1234)
                        fail($sformatf("FINISH %h, VALUE2 %h (seen %0d): want 005a3333 and 00001234", w, s_v2, s_v2_seen));
                end else if (w !== 32'h5555)
                    fail($sformatf("the program reports FINISH %h (code %0d), VALUE2 %h (seen %0d)", w, w[31:16], s_v2, s_v2_seen));
                if (s_win_fin != s_exp_re + s_exp_cut + s_exp_po - 1)
                    fail($sformatf("%0d reboot / power-off windows before the verdict, want %0d", s_win_fin,
                                   s_exp_re + s_exp_cut + s_exp_po - 1));
                rep_done = 1'b1;
            end
        end
    endtask

    task automatic on_byte_soc(input [7:0] b);
        begin
            if (s_fin) fail($sformatf("byte %h after the FINISH frame", b));
            else case (fr_st)
                0: if (b >= 8'h10 && b <= 8'h13) begin
                       fr_tag = b; fr_n = 0; fr_acc = 32'h0; fr_st = (b == 8'h10) ? 1 : 2;
                   end else s_pay = $sformatf("%s%c", s_pay, b);
                1: begin fr_st = 0; soc_event(b); end
                default: begin
                    fr_acc[8 * fr_n +: 8] = b; fr_n = fr_n + 1;
                    if (fr_n == 4) begin fr_st = 0; soc_frame(fr_tag, fr_acc); end
                end
            endcase
        end
    endtask

    // UART flow control: clocks the RP2350 held a character for CTS.
    always @(posedge clk) if (soc_test && rp.tx_head != rp.tx_tail && !rp.tx_busy && uo_out[5]) s_cts_wait = s_cts_wait + 1;

    always @(negedge clk) if (soc_test && sw_on != 0) begin
        case (sw_st)
            0: if (rst_n && edges >= 3 && uio_oe[3] === 1'b0) begin
                   sw_n = sw_n + 1; sw_low = 1; sw_st = 1;
                   if (!sw_prev[0]) sw_fl = sw_fl + 1;
                   else if (!sw_prev[1]) sw_a = sw_a + 1;
                   else if (!sw_prev[2]) sw_b = sw_b + 1;
                   else sw_idle = sw_idle + 1;
                   if (!sw_prev[2]) sw_data = sw_data + 1;
                   // a page-split fetch: the first half reads 0x3FC..0x3FF, the second begins at 0x400
                   if (a_start >= 24'h0003FC && a_start <= 24'h0003FF) sw_split = sw_split + 1;
                   sw_dist = cyc - s_cue_cyc;
                   if (s_hi != 0) begin
                       if (sw_dist <= s_lo || sw_dist > s_hi)
                           fail($sformatf("window %0d clocks after the cue, want %0d < d <= %0d", sw_dist, s_lo, s_hi));
                       else $display("NOTE window %0d clocks after the cue (bound %0d < d <= %0d)", sw_dist, s_lo, s_hi);
                       s_d_last = sw_dist; s_lo = 0; s_hi = 0;
                   end
                   if (prog == "syscon_strap" && (s_strap_cyc == 0 || s_strap_cyc > cyc))
                       fail("the strap had not moved when the reboot window opened");
                   $display("NOTE window %0d at cycle %0d: cut class %s, last flash/PSRAM command %h addr %h, PSRAM A read began at %h", sw_n, cyc,
                            !sw_prev[0] ? "flash" : !sw_prev[1] ? "psram-A" : !sw_prev[2] ? "psram-B" : "idle",
                            pmod.cmd, pmod.addr, a_start);
                   check_reset_pins("in a reboot / power-off window, first sample");
                   if (pr_arm) begin pr_arm = 1'b0; -> pr_go; end
               end else sw_prev = {uio_pin[7], uio_pin[6], uio_pin[0]};
            1: begin
                   if (!rst_n) begin sw_cut = sw_cut + 1; sw_st = 4; end
                   else if (uio_oe[3] === 1'b0) begin
                       sw_low = sw_low + 1;
                       check_reset_pins("in a reboot / power-off window");
                       if (sw_low == 200) begin sw_po = sw_po + 1; sw_st = 3; end
                   end else begin
                       if (sw_low == 2) begin sw_re = sw_re + 1; fl_arm = 1'b1; end
                       else fail($sformatf("window of %0d samples: neither a reboot (2) nor a power-off (200)", sw_low));
                       sw_st = 0; sw_prev = {uio_pin[7], uio_pin[6], uio_pin[0]};
                   end
               end
            default: if (rst_n && edges >= 3 && uio_oe[3] === 1'b1) begin sw_st = 0; sw_prev = {uio_pin[7], uio_pin[6], uio_pin[0]}; end
        endcase
    end
    always @(pr_go) begin
        #(`IN_DLY_NS);
        if (uio_oe[3] !== 1'b0) fail("the pin reset did not land inside a hold");
        rst_n = 1'b0; tb_in = tb_in | pr_in;
        repeat (2) @(posedge clk);
        #(`IN_DLY_NS) rst_n = 1'b1;
    end
    // (the model's addr counts up with the data, so it is read when the flash starts driving)
    always @(posedge pmod_oe) if (soc_test && fl_arm && uio_pin[0] === 1'b0 && pmod.cmd === 8'hEB) begin
        fl_arm = 1'b0;
        // (the model's addr counts up with the data, and by the time it drives it may have moved by a byte)
        if (pmod.addr > 24'h3) fail($sformatf("the first flash read after a reboot is at %h, want 0", pmod.addr));
        else sw_fl_ok = sw_fl_ok + 1;
    end

    // irq_stall's log in PSRAM B (tests/soc/irq_stall.S): word 0 the count,
    // entry n (mepc) at +4+4n, each part's store-completion address at +0x7F0..
    task irq_log_check;
        integer n, part, hits [1:3], tot [1:3];
        reg [31:0] mepc, x;
        begin
            hits[1] = 0; hits[2] = 0; hits[3] = 0; tot[1] = 0; tot[2] = 0; tot[3] = 0;
            if (ram_word('hFFF000) !== 32'd37) fail($sformatf("irq_stall: the log holds %0d interrupts, want 37", ram_word('hFFF000)));
            else for (n = 0; n < 37; n = n + 1) begin
                part = (n < 12) ? 1 : (n < 28) ? 2 : 3;
                x = ram_word('hFFF7F0 + 4 * (part - 1));
                mepc = ram_word('hFFF004 + 4 * n);
                tot[part] = tot[part] + 1;
                if (mepc == x) hits[part] = hits[part] + 1;
                if (mepc + 32'h30 < x || mepc > x + 32'h10)
                    fail($sformatf("irq_stall part %0d: interrupt %0d taken at mepc %h, the part's store completes at %h", part, n, mepc, x));
            end
            $display("NOTE irq_stall: interrupts taken right after the held store (mepc = its next instruction): THR %0d of %0d, SPI DATA %0d of %0d, amoswap %0d of %0d",
                     hits[1], tot[1], hits[2], tot[2], hits[3], tot[3]);
            if (hits[1] == 0 || hits[2] == 0 || hits[3] == 0) fail("irq_stall: some part never had an interrupt land on its held store");
        end
    endtask

    task automatic soc_final;
        integer k;
        begin
            if (s_pay != s_want)
                fail($sformatf("the RP2350 received \"%s\" (%0d characters), want \"%s\" (%0d)", s_pay, s_pay.len(), s_want, s_want.len()));
            if (s_ev_i != s_n_ev) fail($sformatf("%0d cues, want %0d", s_ev_i, s_n_ev));
            if (s_val_i != s_n_val) fail($sformatf("%0d VALUE frames, want %0d", s_val_i, s_n_val));
            if (rp.rx_n != s_rx_fin + 0 && s_fin) fail($sformatf("%0d byte(s) arrived after the FINISH frame", rp.rx_n - s_rx_fin));
            if (oled.nlog != s_oled_fin) fail($sformatf("%0d SSD1331 byte(s) arrived after the verdict", oled.nlog - s_oled_fin));
            if (sw_re != s_exp_re || sw_po != s_exp_po || sw_cut != s_exp_cut)
                fail($sformatf("windows: %0d reboots, %0d power-offs, %0d cut by a pin reset; want %0d, %0d, %0d",
                               sw_re, sw_po, sw_cut, s_exp_re, s_exp_po, s_exp_cut));
            if (sw_n != sw_re + sw_po + sw_cut) fail("a window that is none of reboot, power-off or cut");
            if (sw_fl_ok != sw_re) fail($sformatf("%0d reboots, but the first flash read at address 0 came after %0d of them", sw_re, sw_fl_ok));
            if (n_want_oled != 0 || oled_fit) begin
                if (oled.nlog != n_want_oled) fail($sformatf("the SSD1331 got %0d bytes, want %0d", oled.nlog, n_want_oled));
                for (k = 0; k < oled.nlog && k < n_want_oled; k = k + 1)
                    if (oled.log[k] !== want_oled[k])
                        fail($sformatf("SSD1331 byte %0d = {D/C %b, %h}, want {D/C %b, %h}", k,
                                       oled.log[k][8], oled.log[k][7:0], want_oled[k][8], want_oled[k][7:0]));
            end
            if (oled.errors != 0) fail($sformatf("%0d SSD1331 errors", oled.errors));
            case (pid)
                ID_uart_echo: begin
                    $display("NOTE uart_echo: the RP2350 held characters for CTS %0d clocks; %0d characters sent against CTS",
                             s_cts1 - s_cts0, rp.tx_sent_cts_off);
                    if (s_cts1 - s_cts0 == 0) fail("uart_echo: flow control never held the RP2350 back");
                    if (rp.tx_sent_cts_off != 2) fail("uart_echo: want exactly Y and Z sent against CTS");
                end
                ID_uart_linux: if (rp.tx_sent_cts_off != 0) fail("uart_linux: a character was sent against CTS");
                ID_oled_spi: begin
                    $display("NOTE oled_spi: %0d SSD1331 bytes, %0d RES# pulses, %0d timing violations flagged on the DIV 1 byte",
                             oled.nlog, oled.n_res_pulses, oled.n_expected);
                    if (oled.n_res_pulses != 1) fail("oled_spi: want one RES# pulse");
                end
                ID_irq_stall: irq_log_check;
                ID_syscon_reboot: begin
                    for (k = 1; k < 5; k = k + 1)
                        if (s_mt[k] > s_mt[0] + 64 || s_mt[k] + 64 < s_mt[0])
                            fail($sformatf("mtime at the start of boot %0d is %0d, boot 1's %0d", k + 1, s_mt[k], s_mt[0]));
                    $display("NOTE syscon_reboot: mtime at the starts %0d %0d %0d %0d %0d; %0d window(s) cut a flash read",
                             s_mt[0], s_mt[1], s_mt[2], s_mt[3], s_mt[4], sw_fl);
                    if (sw_fl < 1) fail("syscon_reboot: no reboot cut a flash read");
                end
                ID_syscon_wdt: $display("NOTE syscon_wdt: window d = %0d clocks after the cue frame", s_d_last);
                ID_syscon_wdt_split: begin
                    $display("NOTE syscon_wdt_split: %0d windows, %0d on a split fetch (PSRAM A's last read began at 0x3FC..0x3FF), %0d on PSRAM B (data)",
                             sw_n, sw_split, sw_data);
                    if (sw_split < 1) fail("syscon_wdt_split: no fire between the halves of a split fetch");
                    if (sw_data < 1) fail("syscon_wdt_split: no fire on a data transaction");
                end
                ID_keypad: if (s_ev_i != 28) fail("keypad: not every pattern was scanned");
                default: ;
            endcase
            $display("NOTE soc %s: %0d cues, %0d VALUE frames, %0d windows (%0d reboots, %0d power-offs, %0d cut by a pin reset)",
                     prog, s_ev_i, s_val_i, sw_n, sw_re, sw_po, sw_cut);
        end
    endtask

    initial begin #1; if (soc_test) rp.set_baud(16.0 * s_div * TCLK); end

    task automatic on_byte_isa(input [7:0] b);
        begin
            case (rep_state)
                0: case (b)
                    "P": if (sig_test) fail("a 'P' from a signature test"); else begin rep_state = 3; rep_done = 1'b1; end
                    "F": begin rep_state = 1; rep_n = 0; end
                    "S": if (!sig_test) fail("an 'S' from a pass/fail test");
                         else if (sig_uart && sig_end > sig_begin) begin rep_state = 2; rep_n = 0; end
                         else begin rep_state = 3; rep_done = 1'b1; end
                    default: fail($sformatf("first byte %h, want P, F or S", b));
                endcase
                1: begin
                    fail_num[8 * rep_n +: 8] = b;
                    rep_n = rep_n + 1;
                    if (rep_n == 4) begin
                        fail($sformatf("the program reports TESTNUM %0d (gp = %h)", fail_num, fail_num));
                        rep_state = 3; rep_done = 1'b1;
                    end
                end
                2: begin
                    usig[rep_n] = b;
                    rep_n = rep_n + 1;
                    if (rep_n == sig_end - sig_begin) begin rep_state = 3; rep_done = 1'b1; end
                end
                default: fail($sformatf("byte %h after the report", b));
            endcase
        end
    endtask

    // After the report: the power-off at the pins, within 20,000 clocks, held 200.
    integer pw_i, pw_cyc;
    always begin : isa_poweroff
        @(posedge rep_done);
        pw_i = 0;
        while (!(uio_oe === 8'h00 && uo_out === 8'h39) && pw_i < 20000) begin @(negedge clk); pw_i = pw_i + 1; end
        if (pw_i >= 20000) fail("no power-off within 20000 clocks of the report");
        else begin
            pw_cyc = cyc;
            repeat (200) begin @(negedge clk); check_reset_pins("in power-off after the report"); end
            if (errors == 0) $display("POWEROFF seen at cycle %0d, held 200 clocks", pw_cyc);
        end
        done = 1'b1;
    end

    task automatic on_byte(input [7:0] b);
        integer k;
        begin
            if (isa_test) begin
                on_byte_isa(b);
            end else if (soc_test) begin
                on_byte_soc(b);
            end else if (reboot_test) begin
                on_byte_reboot(b);
            end else if (seen < N_OUT) begin
                // 1. an 'o' per OUT value
                k = seen;
                if (b !== "o") fail($sformatf("byte %0d is %h, want 'o'", seen, b));
                if (gpio_pins !== {out_vals[k][7:6], out_vals[k][3:0]})
                    fail($sformatf("OUT = %h: uo_out[7:6], [3:0] = %b, want %b", out_vals[k],
                                   gpio_pins, {out_vals[k][7:6], out_vals[k][3:0]}));
            end else if (seen < N_OUT + 3 * N_IN) begin
                // 2. 'i', then the byte sent to it, then IN
                k = (seen - N_OUT) / 3;
                case ((seen - N_OUT) % 3)
                    0: begin
                        if (b !== "i") fail($sformatf("byte %0d is %h, want 'i'", seen, b));
                        strap_on = 1'b0;
                        tb_in = in_pats[k];
                        rp.send_byte(8'h30 + k);
                    end
                    1: if (b !== 8'h30 + k)
                           fail($sformatf("RX: sent %h, the program read %h", 8'h30 + k, b));
                    2: begin
                        // ui_in[3] is the RX line, idle (high) by now
                        want = {in_pats[k][7:4], 1'b1, in_pats[k][2:0]};
                        if (b !== want)
                            fail($sformatf("ui_in = %b: IN read %b", want, b));
                    end
                endcase
            end else begin
                // 3. and 4.
                case (seen - N_OUT - 3 * N_IN)
                    0: begin
                        if (b !== "a") fail($sformatf("byte %0d is %h, want 'a'", seen, b));
                        snap1 = cs1_falls; snap2 = cs2_falls;
                    end
                    1: begin
                        if (b !== "b") fail($sformatf("byte %0d is %h, want 'b'", seen, b));
                        if (cs1_falls - snap1 < 2 || cs2_falls != snap2)
                            fail($sformatf("PSRAM A store and load: uio[6] fell %0d times, uio[7] %0d",
                                           cs1_falls - snap1, cs2_falls - snap2));
                        if (ram_word('h100) !== 32'h1234ABCD)
                            fail($sformatf("PSRAM A holds %h at 0x100, want 1234abcd", ram_word('h100)));
                        snap1 = cs1_falls; snap2 = cs2_falls;
                    end
                    2: begin
                        if (b !== "c") fail($sformatf("byte %0d is %h, want 'c'", seen, b));
                        if (cs2_falls - snap2 < 2 || cs1_falls != snap1)
                            fail($sformatf("PSRAM B store and load: uio[7] fell %0d times, uio[6] %0d",
                                           cs2_falls - snap2, cs1_falls - snap1));
                        if (ram_word('h800100) !== 32'h89EF4567)
                            fail($sformatf("PSRAM B holds %h at 0x100, want 89ef4567", ram_word('h800100)));
                    end
                    3: begin
                        if (b !== "Z") fail($sformatf("byte %0d is %h, want 'Z'", seen, b));
                        done = 1'b1;
                    end
                    default: fail($sformatf("byte %h after the end of the stream", b));
                endcase
            end
            seen = seen + 1;
        end
    endtask
    always @(rp.rx_n)
        if (rp.rx_n > n_rx0) on_byte(rp.rx_buf[(rp.rx_n - 1) % 16384]);

    always @(negedge clk) if (reboot_test) begin
        case (wstate)
            1: if (uio_oe[3] === 1'b0) begin
                    win_dist = cyc - cue_cyc;
                    if (win_dist <= w_lo || win_dist > w_hi)
                        fail($sformatf("reboot window %0d clocks after cue '%c', want %0d < d <= %0d",
                                       win_dist, cue_chr, w_lo, w_hi));
                    else
                        $display("NOTE reboot window %0d clocks after the cue '%c' (bound %0d < d <= %0d)",
                                 win_dist, cue_chr, w_lo, w_hi);
                    check_reset_pins("in the reboot window, first sample");
                    for (ci = 0; ci < 16; ci = ci + 1) cnt[ci] = 0;
                    phase = 2; wstate = 2;
                end else if (cyc - cue_cyc > w_hi) begin
                    fail($sformatf("no reboot window within %0d clocks of the cue '%c'", w_hi,
                                   cue_chr));
                    phase = 0; wstate = 0;
                end
            2: begin
                    check_reset_pins("in the reboot window, second sample");
                    wstate = 3;
                end
            3: begin
                    if (uio_oe[3] !== 1'b1)
                        fail("reboot window longer than two samples: SCK and the chip selects not driven on the third");
                    wstate = 4; w_post = 10;
                end
            4: begin
                    w_post = w_post - 1;
                    if (w_post == 0) begin phase = 0; wstate = 0; end
                end
        endcase
    end

    // One transition per pin: each bit of uo_out and uio_oe changes at most
    // once into the window (in the cycle that enters it) and once out of it, never twice at one time stamp,
    // and only just after a rising clock edge.
    realtime t_pos = -1.0e9;
    integer cj;
    // Before the window the program is running and its pins move as they
    // like (flash fetches); what counts is the clock cycle that enters the
    // window, so the count starts again at every edge until the window opens.
    always @(posedge clk) begin
        t_pos = $realtime;
        if (phase == 1) for (cj = 0; cj < 16; cj = cj + 1) cnt[cj] = 0;
    end
    wire [15:0] pins16 = {uio_oe, uo_out};
    genvar gp;
    generate for (gp = 0; gp < 16; gp = gp + 1) begin : pin
        realtime last_t = -1.0;
        always @(pins16[gp]) if (phase != 0) begin
            if ($realtime == last_t)
                fail($sformatf("%s[%0d] changed twice at %0t", gp < 8 ? "uo_out" : "uio_oe", gp % 8, $realtime));
            last_t = $realtime;
            if ($realtime - t_pos > 1.0 * `RST_CHK_NS)
                fail($sformatf("%s[%0d] changed %0g ns after the clock edge", gp < 8 ? "uo_out" : "uio_oe",
                               gp % 8, $realtime - t_pos));
            cnt[gp] = cnt[gp] + 1;
            if (cnt[gp] > 1)
                fail($sformatf("%s[%0d] changed twice %s the reboot window", gp < 8 ? "uo_out" : "uio_oe",
                               gp % 8, phase == 1 ? "going into" : "coming out of"));
        end
    end endgenerate

    // Quiet pins: from the cue to the window nothing but the reboot moves
    // uo_out or the SCK / chip select enables (uio_oe 0, 3, 6, 7); the one
    // allowed transition is the cycle that enters the window. The cycle's
    // count is folded into q_early at the next edge, so at the first sample
    // q_early holds every transition before the entering cycle.
    wire [11:0] quiet = {uio_oe[7], uio_oe[6], uio_oe[3], uio_oe[0], uo_out};
    integer q_early = 0, q_cur = 0;
    always @(quiet) if (phase == 1) q_cur = q_cur + 1;
    always @(posedge clk) if (phase == 1) begin q_early = q_early + q_cur; q_cur = 0; end
    always @(posedge clk) if (phase == 0) begin q_early = 0; q_cur = 0; end
    always @(negedge clk) if (reboot_test && wstate == 1 && uio_oe[3] === 1'b0 && q_early != 0)
        fail($sformatf("%0d transitions on uo_out / SCK and chip select enables between the cue '%c' and the window",
                       q_early, cue_chr));

    // Power-off: once the pins are at their reset values they stay there for
    // 5,000 clocks whatever the board does -- GPIO IN, the strap pin and a byte
    // from the RP2350 -- with no chip select fall and no SCK edge. Then the
    // testbench's pin reset (IN[7] = 1, strap back at its run value) starts the
    // program again, which sends 'Z'.
    integer po_i, po_c0, po_c1, po_c2, po_s;
    always begin : poweroff_watch
        @(posedge po_arm);
        po_i = 0;
        while (uio_oe[3] !== 1'b0 && po_i < po_lim) begin @(negedge clk); po_i = po_i + 1; end
        if (uio_oe[3] !== 1'b0) fail($sformatf("no power-off within %0d clocks of the cue", po_lim));
        else begin
            check_reset_pins("at the start of power-off");
            po_c0 = cs0_falls; po_c1 = cs1_falls; po_c2 = cs2_falls; po_s = sck_rises;
            rp.set_flow(1'b0);
            rp.send_byte(8'hA5);
            for (po_i = 1; po_i <= 5000; po_i = po_i + 1) begin
                @(negedge clk);
                check_reset_pins("in power-off");
                if (po_i % 50 == 0) begin
                    #1;
                    tb_in[6:0] = tb_in[6:0] + 7'd37;
                    strap = !strap;
                end
            end
            if (cs0_falls != po_c0 || cs1_falls != po_c1 || cs2_falls != po_c2 || sck_rises != po_s)
                fail($sformatf("chip select falls %0d/%0d/%0d, SCK rises %0d during power-off",
                               cs0_falls - po_c0, cs1_falls - po_c1, cs2_falls - po_c2, sck_rises - po_s));
            rp.set_flow(1'b1);
            tb_in[7] = 1'b1;
            strap = rd_late;
            // As phase 2 of the default run: clock running, off the edge,
            // held for four edges.
            @(posedge clk);
            #3 rst_n = 1'b0;
            repeat (4) @(posedge clk);
            #(`IN_DLY_NS) rst_n = 1'b1;
        end
    end

    // RTS# while a received byte waits: the program cannot have read RBR
    // within the half bit since the stop bit was sampled.
    always @(rp.tx_sent)
        if (rp.tx_sent > 0 && uo_out[5] !== 1'b1)
            fail("RTS# low at the end of a received byte, before the program read it");

    // ── Run ─────────────────────────────────────────────────────────────────
    integer max_cycles = 0;
    string  tag = "";

    // The run below ends by itself soon after max_cycles. This ends it when
    // it is stuck waiting for a pin that never moves, or a clock that never
    // starts.
    initial begin
        #1;
        #(1.0 * (max_cycles + 1000) * TCLK);
        $display("TIMEOUT tb_tt_um: stuck at cycle %0d, %0d bytes seen", cyc, seen);
        $finish;
    end

    // Wait for the flash to be driving read data, two clocks into it.
    task automatic aim_at_flash_read;
        reg aimed;
        begin
            aimed = 1'b0;
            while (!aimed) begin
                @(posedge pmod_oe);
                aimed = (uio_pin[0] === 1'b0);
            end
            repeat (2) @(posedge clk);
            if (pmod_oe !== 1'b1 || uio_pin[0] !== 1'b0)
                fail("the reset was not aimed at a flash read");
        end
    endtask

    // The signature, from the PSRAM model (SIG_BEGIN is in PSRAM A, at 0x8000_0000).
    task automatic read_signature;
        integer n, w, mism, first, fo;
        reg [31:0] got;
        begin
            n = (sig_end - sig_begin) / 4;
            for (w = 0; w < 16384; w = w + 1) sig_ref[w] = 32'hx;
            if (sig_ref_file != "") $readmemh(sig_ref_file, sig_ref);
            fo = (sig_out_file != "") ? $fopen(sig_out_file, "w") : 0;
            mism = 0; first = -1;
            if (n <= 0 || n > 16384) fail($sformatf("signature of %0d words (%h..%h)", n, sig_begin, sig_end));
            else for (w = 0; w < n; w = w + 1) begin
                got = ram_word(sig_begin - 32'h8000_0000 + 4 * w);
                if (fo != 0) $fdisplay(fo, "%08x", got);
                if (got !== sig_ref[w]) begin
                    if (first < 0) begin
                        first = w;
                        fail($sformatf("signature word %0d at %h is %h, want %h", w, sig_begin + 4 * w, got, sig_ref[w]));
                    end
                    mism = mism + 1;
                end
                if (sig_uart && {usig[4 * w + 3], usig[4 * w + 2], usig[4 * w + 1], usig[4 * w]} !== got)
                    fail($sformatf("UART signature word %0d is %h, PSRAM holds %h", w,
                                   {usig[4 * w + 3], usig[4 * w + 2], usig[4 * w + 1], usig[4 * w]}, got));
            end
            if (fo != 0) $fclose(fo);
            if (mism != 0) fail($sformatf("%0d of %0d signature words differ", mism, n));
            else $display("NOTE signature: %0d words match%s", n, sig_uart ? " (UART copy equal to the PSRAM copy)" : "");
        end
    endtask

    initial begin
        rd_late = $test$plusargs("RD_LATE");
        if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)) max_cycles = 400_000;
        if ($value$plusargs("TEST=%s", testname)) begin
            reboot_test = (testname == "reboot");
            isa_test = (testname == "isa" || testname == "sig");
            sig_test = (testname == "sig");
            soc_test = (testname == "soc");
        end
        sig_uart = $test$plusargs("SIG_UART");
        if (soc_test) begin
            if (!$value$plusargs("PROG=%s", prog)) fail("+TEST=soc needs +PROG=<name>");
            pid = prog_id(prog);
            soc_setup;
        end
        if (!$value$plusargs("SIG_BEGIN=%h", sig_begin)) sig_begin = 32'h0;
        if (!$value$plusargs("SIG_END=%h", sig_end)) sig_end = 32'h0;
        if (!$value$plusargs("SIG_REF=%s", sig_ref_file)) sig_ref_file = "";
        if (!$value$plusargs("SIG_OUT=%s", sig_out_file)) sig_out_file = "";
        strap = rd_late;

        // 1. The demo board's firmware: the clock stopped, a pulse on rst_n,
        //    then the clock. The chip stays in reset, pins and all, until the
        //    clock has run for two edges.
        #20 rst_n = 1'b0;
        #50 rst_n = 1'b1;
        #30 check_reset_pins("after a reset pulse with the clock stopped");
        clk_on = 1'b1;

        if (!(reboot_test || soc_test)) begin
            // 2. With the clock running, off the edge, the flash driving the bus.
            aim_at_flash_read;
            #3 rst_n = 1'b0;
            repeat (6) @(posedge clk);
            #(`IN_DLY_NS) rst_n = 1'b1;

            // 3. A pulse that fits between two clock edges.
            aim_at_flash_read;
            #2 rst_n = 1'b0;
            #3 rst_n = 1'b1;
        end
        if (rp.rx_n != 0) fail("UART traffic before the last reset");
        n_rx0 = rp.rx_n;
        cs0_falls = 0; sck_rises = 0;
        // The strap is free to change once the second edge has gone.
        repeat (2) @(posedge clk);
        #(`IN_DLY_NS) strap = soc_test ? 1'b0 : !rd_late;
        if (soc_test) begin sw_on = 1; oled_fit = (prog == "oled_spi" || prog == "irq_stall"); end

        while (!done && cyc < max_cycles) @(posedge clk);
        if (!done && (isa_test || soc_test)) begin
            $display("TIMEOUT tb_tt_um %s: no report and power-off within %0d cycles (%0d bytes seen)", testname, max_cycles, seen);
            fail("timeout");
        end else if (!done)
            fail($sformatf("no 'Z' within %0d cycles: %0d of %0d bytes seen", max_cycles, seen,
                           reboot_test ? RB_N : N_OUT + 3 * N_IN + 4));
        if (done && sig_test) read_signature;
        // Let a stray extra byte arrive.
        repeat (soc_test ? 16 * 12 * s_div + 400 : 16 * 12) @(posedge clk);
        if (soc_test) soc_final;
        if (cs0_falls == 0 || sck_rises == 0) fail("no flash read on uio[0] and uio[3]");
        if (rp.errors != 0) fail($sformatf("%0d RP2350 UART errors", rp.errors));
        if (rp.tx_pending() != 0) fail("a byte for the program was never sent: RTS# stayed high");
        tag = reboot_test ? " reboot" : "";
        if (isa_test) tag = {" ", testname};
        if (soc_test) tag = {" soc ", prog};
        if (errors == 0) $display("PASS tb_tt_um%s (QSPI_DELAY=%0d ns, rd_late=%0d, %0d cycles)",
                                  tag, pmod.delay_ns, rd_late, cyc);
        else             $display("FAIL tb_tt_um: %0d errors", errors);
        $finish;
    end
endmodule
