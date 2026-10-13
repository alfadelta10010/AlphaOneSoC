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

`timescale 1ns / 1ps

module tb_tt_um;
    localparam real    TCLK  = 10.0;  // as tb_qspi: the Makefile's QSPI delays assume it
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
    wire [7:0] ui_in = {tb_in[7:4], uart_rx, tb_in[2:1], strap_on ? strap : tb_in[0]};
    wire [7:0] uo_out, uio_out, uio_oe;
    wire [7:0] uio_pin;

    tt_um_alfadelta10010_alphaone_soc dut (
`ifdef USE_POWER_PINS
        .VPWR(1'b1), .VGND(1'b0),
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
        #2;
        if (!rst_n) check_reset_pins("2 ns after rst_n fell");
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

    integer   seen = 0;               // bytes of the stream handled
    integer   n_rx0 = 0;              // rp.rx_n when the stream began
    reg       done = 1'b0;
    integer   snap1, snap2;
    reg [7:0] want;

    function automatic [31:0] ram_word(input integer a);
        ram_word = {pmod.ram[a + 3], pmod.ram[a + 2], pmod.ram[a + 1], pmod.ram[a]};
    endfunction

    task automatic on_byte(input [7:0] b);
        integer k;
        begin
            if (seen < N_OUT) begin
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

    // RTS# while a received byte waits: the program cannot have read RBR
    // within the half bit since the stop bit was sampled.
    always @(rp.tx_sent)
        if (rp.tx_sent > 0 && uo_out[5] !== 1'b1)
            fail("RTS# low at the end of a received byte, before the program read it");

    // ── Run ─────────────────────────────────────────────────────────────────
    integer max_cycles = 0;

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

    initial begin
        if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)) max_cycles = 400_000;
        rd_late = $test$plusargs("RD_LATE");
        strap = rd_late;

        // 1. The demo board's firmware: the clock stopped, a pulse on rst_n,
        //    then the clock. The chip stays in reset, pins and all, until the
        //    clock has run for two edges.
        #20 rst_n = 1'b0;
        #50 rst_n = 1'b1;
        #30 check_reset_pins("after a reset pulse with the clock stopped");
        clk_on = 1'b1;

        // 2. With the clock running, off the edge, the flash driving the bus.
        aim_at_flash_read;
        #3 rst_n = 1'b0;
        repeat (6) @(posedge clk);
        #1 rst_n = 1'b1;

        // 3. A pulse that fits between two clock edges.
        aim_at_flash_read;
        #2 rst_n = 1'b0;
        #3 rst_n = 1'b1;
        if (rp.rx_n != 0) fail("UART traffic before the last reset");
        n_rx0 = rp.rx_n;
        cs0_falls = 0; sck_rises = 0;
        // The strap is free to change once the second edge has gone.
        repeat (2) @(posedge clk);
        #1 strap = !rd_late;

        while (!done && cyc < max_cycles) @(posedge clk);
        if (!done)
            fail($sformatf("no 'Z' within %0d cycles: %0d of %0d bytes seen", max_cycles, seen,
                           N_OUT + 3 * N_IN + 4));
        // Let a stray extra byte arrive.
        repeat (16 * 12) @(posedge clk);
        if (cs0_falls == 0 || sck_rises == 0) fail("no flash read on uio[0] and uio[3]");
        if (rp.errors != 0) fail($sformatf("%0d RP2350 UART errors", rp.errors));
        if (rp.tx_pending() != 0) fail("a byte for the program was never sent: RTS# stayed high");
        if (errors == 0) $display("PASS tb_tt_um (QSPI_DELAY=%0d ns, rd_late=%0d, %0d cycles)",
                                  pmod.delay_ns, rd_late, cyc);
        else             $display("FAIL tb_tt_um: %0d errors", errors);
        $finish;
    end
endmodule
