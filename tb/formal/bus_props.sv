// SoC bus rules (WO-31 part A, REQ-BUS-001; rewritten for the two-phase IO path, WO-51 / D14):
// soc_bus with the real plic, uart and gpio behind it, port maps as in src/alphaone_soc.v (address,
// we, be and wdata fan out unchanged). Every other input is free, including the read data of the
// gamepad, pinmux, PWM and audio (they never hold ready low, so no block is needed behind them). soc_bus is stateful now (one phase
// flop `ph`, the 32-bit io_q), so this is a pdr proof.
//   B1  every IO select is low when ph = 1; at most one select high; ph implies an IO request
//   B2  per IO request exactly one edge with sel && ready before d_ready (counter n: 0 at the start
//       of a request, 1 at d_ready, never above 1)
//   B3  d_ready for an IO address only when ph = 1; d_rdata is the addressed target's read data of
//       the cycle before (the phase-1 completing edge); ph rises only on a phase-1 edge where
//       every target is ready (back-pressure lengthens phase 1)
//   B4  a target's ready is low only while its select is high (uart, gpio)
//   B5  memory path: mem_req == d_req && is_mem, d_ready / d_rdata are the memory controller's
//   B6  decode: select = phase 1 && its window; CLINT and PLIC never both; PLIC only with bit 27;
//       the carves are exact: gamepad = GPIO slot with addr[5:3] == 2 (gpio_sel is the rest), pinmux =
//       0x1002_0020 only (syscon_sel is the rest), PWM / audio = slot 3 by addr[8]
//   B1-B4 and B6 cover the gamepad, pinmux, PWM and audio selects as well (WO-58)
// Assumptions: (a) PMA: d_req implies d_addr is in one of the windows of docs/soc-architecture.md
// (flash 0x2000_0000 +16 MB, PSRAM 0x8000_0000 +16 MB, CLINT 0x0200_0000, PLIC 0x0C00_0000 +4 MB,
// UART 0x1000_0000, GPIO 0x1001_0000, syscon 0x1002_0000, PWM/audio 0x1003_0000, +64 KB each); (b) the core's contract:
// a request not completed (d_ready low) stays, with address, we, be and wdata unchanged, to the next
// clock, except across a reset.
module bus_props (
    input  wire        clk, rst,
    input  wire        d_req, d_we,
    input  wire [31:0] d_addr, d_wdata,
    input  wire [3:0]  d_be,
    input  wire        mem_ready,
    input  wire [31:0] mem_rdata, clint_rdata, syscon_rdata,
    input  wire [31:0] gamepad_rdata, pinmux_rdata, pwm_rdata, audio_rdata,
    input  wire        uart_rx,
    input  wire [7:0]  gpio_in
);
    wire        d_ready, mem_req, clint_sel, plic_sel, uart_sel, gpio_sel, syscon_sel, uart_ready, gpio_ready;
    wire        gamepad_sel, pinmux_sel, pwm_sel, audio_sel;
    wire [31:0] d_rdata, uart_rdata, gpio_rdata, plic_rdata;
    wire        uart_tx, uart_rts_n, uart_irq, meip;
    wire [7:0]  gpio_out;

    soc_bus bus (.clk(clk), .rst(rst), .d_req(d_req), .d_addr(d_addr), .d_rdata(d_rdata), .d_ready(d_ready),
        .mem_req(mem_req), .mem_rdata(mem_rdata), .mem_ready(mem_ready),
        .clint_sel(clint_sel), .clint_rdata(clint_rdata),
        .plic_sel(plic_sel), .plic_rdata(plic_rdata),
        .uart_sel(uart_sel), .uart_rdata(uart_rdata), .uart_ready(uart_ready),
        .gpio_sel(gpio_sel), .gpio_rdata(gpio_rdata), .gpio_ready(gpio_ready),
        .syscon_sel(syscon_sel), .syscon_rdata(syscon_rdata),
        .gamepad_sel(gamepad_sel), .gamepad_rdata(gamepad_rdata),
        .pinmux_sel(pinmux_sel), .pinmux_rdata(pinmux_rdata),
        .pwm_sel(pwm_sel), .pwm_rdata(pwm_rdata),
        .audio_sel(audio_sel), .audio_rdata(audio_rdata));
    plic #(.NSRC(9)) plic_inst (.clk(clk), .rst(rst), .sel(plic_sel), .we(d_we), .be(d_be), .addr(d_addr[21:2]),
        .wdata(d_wdata), .rdata(plic_rdata), .src({8'b0, uart_irq}), .meip(meip));
    uart uart_inst (.clk(clk), .rst(rst), .sel(uart_sel), .we(d_we), .be(d_be), .addr2(d_addr[2]),
        .wdata(d_wdata), .rdata(uart_rdata), .ready(uart_ready), .irq(uart_irq), .rx(uart_rx), .tx(uart_tx), .rts_n(uart_rts_n));
    gpio gpio_inst (.clk(clk), .rst(rst), .sel(gpio_sel), .we(d_we), .be(d_be), .addr(d_addr[5:2]),
        .wdata(d_wdata), .rdata(gpio_rdata), .ready(gpio_ready), .in(gpio_in), .out(gpio_out));

    reg armed = 1'b0;               // a reset has been applied; every assert is gated on it
    always @(posedge clk) if (rst) armed <= 1'b1;

    wire w_flash  = d_addr[31:24] == 8'h20;
    wire w_psram  = d_addr[31:24] == 8'h80;
    wire w_clint  = d_addr[31:16] == 16'h0200;
    wire w_plic   = d_addr[31:22] == 10'h030;
    wire w_uart   = d_addr[31:16] == 16'h1000;
    wire w_gpioa  = d_addr[31:16] == 16'h1001;
    wire w_syscon_s = d_addr[31:16] == 16'h1002;
    wire w_slot3  = d_addr[31:16] == 16'h1003;
    wire w_gamepad = w_gpioa && (d_addr[5:3] == 3'b010);            // +0x10..+0x17 of every alias
    wire w_pinmux  = w_syscon_s && (d_addr[15:2] == 14'h0008);      // 0x1002_0020 only
    wire w_pwm     = w_slot3 && !d_addr[8];
    wire w_audio   = w_slot3 &&  d_addr[8];
    wire w_gpio    = w_gpioa && !w_gamepad;                          // the rest of the GPIO slot
    wire w_syscon  = w_syscon_s && !w_pinmux;                        // the rest of the syscon slot
    wire w_mem    = w_flash || w_psram;
    wire w_io     = w_clint || w_plic || w_uart || w_gpioa || w_syscon_s || w_slot3;

    wire [31:0] exp_rd = w_clint ? clint_rdata : w_plic ? plic_rdata : w_uart ? uart_rdata :
                         w_gamepad ? gamepad_rdata : w_gpio ? gpio_rdata :
                         w_pinmux ? pinmux_rdata : w_syscon ? syscon_rdata :
                         w_audio ? audio_rdata : pwm_rdata;
    wire        sel_any = clint_sel || plic_sel || uart_sel || gpio_sel || syscon_sel ||
                          gamepad_sel || pinmux_sel || pwm_sel || audio_sel;
    wire        edge_io = clint_sel || plic_sel || syscon_sel || gamepad_sel || pinmux_sel || pwm_sel || audio_sel ||
                          (uart_sel && uart_ready) || (gpio_sel && gpio_ready);

    // one clock of history, and the per-request edge counter
    reg         p_ok = 1'b0;        // the previous clock was a non-reset clock after arming
    reg         p_hold = 1'b0;      // ... and left a request pending
    reg         p_io_edge = 1'b0;   // ... and had a phase-1 completing edge
    reg         p_sel_stall = 1'b0; // ... and had a select with a target not ready
    reg  [31:0] p_addr, p_wdata, p_exp;
    reg  [3:0]  p_be;
    reg         p_we;
    // the spec's phase flop, an independent shadow built from the module's pins: the bus's own `ph` must
    // match it (d_ready for IO == ph_s, selects gated by !ph_s). Reset together with the bus.
    reg         ph_s = 1'b0;
    wire        io_acc = d_req && w_io && !ph_s;
    always @(posedge clk) ph_s <= rst ? 1'b0 : (io_acc && uart_ready && gpio_ready) ? 1'b1 : 1'b0;
    reg         n = 1'b0;           // edges seen for the current IO request (an assert keeps it <= 1)
    always @(posedge clk) begin
        p_ok        <= armed && !rst;
        p_hold      <= d_req && !d_ready;
        p_io_edge   <= edge_io;
        p_sel_stall <= sel_any && !(uart_ready && gpio_ready);
        p_addr <= d_addr; p_wdata <= d_wdata; p_be <= d_be; p_we <= d_we; p_exp <= exp_rd;
        if (rst || (d_req && w_io && d_ready)) n <= 1'b0;
        else if (edge_io)                     n <= 1'b1;
    end

    always @(*) begin
        assume (!d_req || w_mem || w_io);                                           // PMA
        if (p_ok && p_hold) begin                                                    // core contract
            assume (d_req && d_addr == p_addr && d_we == p_we && d_be == p_be && d_wdata == p_wdata);
        end
        if (armed) begin
            assert (uart_ready || uart_sel);                                        // B4
            assert (gpio_ready || gpio_sel);
            // B1
            if (ph_s) assert (!sel_any);
            if (ph_s) assert (!mem_req && !uart_sel);
            assert (({3'b0, mem_req} + clint_sel + plic_sel + uart_sel + gpio_sel + syscon_sel +
                     gamepad_sel + pinmux_sel + pwm_sel + audio_sel) <= 6'd1);
            // B2
            assert (!(n && edge_io));                                               // never a second edge
            if (d_req && w_io && d_ready) assert (n);                               // exactly one by d_ready
            // B3
            if (d_req && w_io) assert (d_ready == ph_s);
            if (d_req && w_io && d_ready && p_ok) assert (d_rdata == p_exp);
            if (ph_s && p_ok) assert (p_io_edge && !p_sel_stall);                 // ph rises on a real edge
            // B5
            assert (mem_req == (d_req && w_mem));
            if (d_req && w_mem) assert (d_ready == mem_ready);
            if (d_req && w_mem) assert (d_rdata == mem_rdata);
            // B6
            assert (clint_sel  == (d_req && !ph_s && w_clint));
            assert (plic_sel   == (d_req && !ph_s && w_plic));
            assert (uart_sel   == (d_req && !ph_s && w_uart));
            assert (gpio_sel   == (d_req && !ph_s && w_gpio));
            assert (syscon_sel == (d_req && !ph_s && w_syscon));
            assert (gamepad_sel == (d_req && !ph_s && w_gamepad));
            assert (pinmux_sel  == (d_req && !ph_s && w_pinmux));
            assert (pwm_sel     == (d_req && !ph_s && w_pwm));
            assert (audio_sel   == (d_req && !ph_s && w_audio));
            assert (!(clint_sel && plic_sel));
            if (plic_sel) assert (d_addr[27]);
        end
    end

`ifdef SBY_COVER
    // back-pressured write (phase 1 lasts), a read with a side effect (a PLIC claim edge, a UART read
    // edge), a memory access straight after phase 2
    reg p_ph = 1'b0;
    always @(posedge clk) p_ph <= ph_s;
    always @(*) begin
        cover (armed && !uart_ready && uart_sel && d_we);
        cover (armed && !gpio_ready && gpio_sel);
        cover (armed && plic_sel && !d_we && w_plic);
        cover (armed && uart_sel && uart_ready && !d_we);
        cover (armed && p_ph && !ph_s && mem_req);
        cover (armed && d_req && w_io && d_ready && d_rdata != 32'h0);
    end
`endif
endmodule
