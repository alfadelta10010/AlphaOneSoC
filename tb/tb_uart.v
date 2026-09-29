// Unit testbench for src/uart.v, the 16550-compatible UART.
//
// Everything is checked against models written from the specification
// (docs/pins-and-peripherals.md, the header of src/uart.v, the 16550), not
// from the RTL:
//
//   * a register model (DLAB, IER, DLL/DLM, LCR) and a scoreboard that
//     predicts all four lanes of every read -- LSR and IIR included, from
//     the transmitter and receiver models below -- and every side effect
//     (an RBR pop, an OE clear);
//   * a model of the TX pin on every clock, from the 16x tick grid (one
//     tick every divisor clocks; restarted on the clock after a DLL/DLM
//     write, as a 16550 reloads its counter; learnt from the first start
//     bit after reset): the start bit begins on the first tick after the
//     THR write, every bit is exactly 16 ticks, data LSB first, a full
//     stop bit -- divisors 0 (as 1), 1, 2, 3, 5, 27, 300 and 1000; and
//     LCR's break control (SBC), which holds the pin at 0 from the first
//     tick after it is set to the first tick after it is cleared, whether
//     or not a frame is shifting underneath;
//   * THR back-pressure: THRE rises on the frame's 160th tick, one tick
//     before the stop bit ends on the pin, and a THR write must complete on
//     the first edge at which it is requested and THRE is set -- no sooner
//     and no later;
//   * a reference transmitter on RX, asynchronous to clk (any phase, baud off
//     by up to +/-3%), that can honour CTS (= RTS#) or ignore it, and that
//     sends glitches, framing errors and breaks. Its model predicts when DR,
//     OE and BI may rise -- a window derived from the documented sampling
//     (two-flop synchroniser, 16x ticks, start bit re-checked at mid-bit,
//     each bit sampled at its middle) -- and a read inside the window
//     accepts either. A frame whose bits all read 0, stop bit included, is
//     a break: BI rises with the DR (RBR = 0) or OE it brings;
//   * an RTS# checker: deasserted during reset, while a frame is being
//     received and while RBR holds a byte; asserted exactly one clock after
//     the pop that empties RBR, and whenever the receiver is idle and empty.
//
// The bus driver follows the core's contract (src/fyracore.v): a request is
// held until ready, which is sampled #1 after the inputs change so the
// combinational ready has settled, and the transfer completes on the clock
// edge where it is high. Between transfers the other inputs carry random
// values, as they do on the SoC bus, where every target sees every address.
//
// A few checks look inside the DUT, only to line a stimulus up with an exact
// clock edge (the same-cycle priority tests) or to see that a store waiting
// for ready has not written any register yet.
//
// Plusargs: +SEED=<n> (random run), +NRAND=<n> operations per random phase.
// Prints PASS or FAIL lines; `make test-uart` fails on any FAIL.

`timescale 1ns / 1ps

module tb_uart;
    localparam real T = 10.0;                 // clock period, ns
    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    integer cyc = 0;                          // rising edges so far
    always @(posedge clk) cyc <= cyc + 1;
    // rst as the last rising edge saw it: the monitors check reset values
    // only once an edge has applied the reset, and stop once one has not.
    reg rst_q = 1'b1;
    always @(posedge clk) rst_q <= rst;

    // ── DUTs ────────────────────────────────────────────────────────────────
    reg         sel = 1'b0, we = 1'b0, addr2 = 1'b0;
    reg  [3:0]  be = 4'h0;
    reg  [31:0] wdata = 32'h0;
    wire [31:0] rdata;
    wire        ready;
    reg         rx = 1'b1;
    wire        tx, rts_n;

    uart dut (.clk(clk), .rst(rst), .sel(sel), .we(we), .be(be), .addr2(addr2),
              .wdata(wdata), .rdata(rdata), .ready(ready), .rx(rx), .tx(tx), .rts_n(rts_n));

    // A second instance, only for DIV_RESET reaching both divisor latches.
    reg         sel2 = 1'b0;
    wire [31:0] rdata2;
    wire        ready2, tx2, rts2_n;
    uart #(.DIV_RESET(16'hA503)) dut2 (.clk(clk), .rst(rst), .sel(sel2), .we(we), .be(be),
              .addr2(addr2), .wdata(wdata), .rdata(rdata2), .ready(ready2), .rx(1'b1),
              .tx(tx2), .rts_n(rts2_n));

    // ── Reporting ───────────────────────────────────────────────────────────
    integer errors = 0, checks = 0;
    task automatic fail(input string m);
        begin
            errors = errors + 1;
            if (errors <= 60) $display("FAIL %s (cycle %0d, %0.1f ns)", m, cyc, $realtime);
        end
    endtask
    // A stimulus the models cannot predict: a testbench bug, reported as one.
    task automatic tb_bug(input string m);
        fail({"testbench: ", m});
    endtask
    task automatic chk(input string what, input [31:0] got, input [31:0] want);
        begin
            checks = checks + 1;
            if (got !== want) fail($sformatf("%s: got %h, want %h", what, got, want));
        end
    endtask
    string cur_section = "start";
    task automatic section(input string m);
        begin
            cur_section = m;
            $display("-- %s (cycle %0d)", m, cyc);
        end
    endtask

    integer seed = 1;
    function integer urand(input integer n);          // 0 .. n-1
        begin urand = $unsigned($random(seed)) % n; end
    endfunction

    // ── Register model ──────────────────────────────────────────────────────
    reg       m_dlab, m_erbfi, m_etbei;
    // SBC: its value, the value before the last LCR write, and that write's
    // edge. A tick on edge e applies the value written on an edge before e.
    reg       m_sbc = 1'b0, m_sbc_old = 1'b0, sbc_pin = 1'b0;
    integer   sbc_edge = -1;
    reg [7:0] m_dll, m_dlm;
    function integer divisor(input [7:0] lo, input [7:0] hi);
        divisor = ({hi, lo} == 16'd0) ? 1 : {hi, lo};  // 0 counts as 1
    endfunction
    function integer cur_div;
        cur_div = divisor(m_dll, m_dlm);
    endfunction

    // ── Transmit model: THR back-pressure and the TX pin ────────────────────
    // The baud generator makes one 16x tick every divisor clocks. It runs
    // freely, except that a completed DLL or DLM write restarts it: the next
    // clock ticks, and the new divisor applies from there (as a 16550
    // reloads its counter when a divisor latch is written). The model keeps
    // that tick grid -- learnt from the first start bit after reset, then
    // moved by every divisor write -- and from it predicts the TX pin on
    // every clock: a THR write's start bit begins on the first tick after
    // the write, every bit (start, 8 data LSB first, stop) is exactly 16
    // ticks, THRE rises on the frame's 160th tick, one tick before the stop
    // bit ends on the pin, and a THR write completes on the first edge at
    // which it is requested and THRE is set -- no sooner and no later.
    // Divisor writes in the middle of a frame (the random run rewrites the
    // divisor with its own value) just move the grid; the model follows.
    //
    // Cycle numbers are edges: a transfer that completes on edge p has
    // cyc == p right after it, and a sample at the following falling edge
    // sees what edge p registered.
    reg       f_active = 1'b0;    // a frame written and not yet off the pin
    integer   f_W, f_ticks, f_d, f_thre_edge;
    reg [7:0] f_data;
    integer   tx_frames = 0, tx_writes = 0, tx_stalls = 0;
    reg       mon_on = 1'b1;
    // The tick grid: edges tick_ref + k * tick_d from edge tick_switch on,
    // the previous grid before it.
    reg       tick_known = 1'b0, tickp_known = 1'b0;
    integer   tick_ref = 0, tick_d = 1, tickp_ref = 0, tickp_d = 1, tick_switch = 0;
    integer   tx_frames_by_div [0:3];         // coverage: d=1, 2-3, 4-31, >=32
    initial begin tx_frames_by_div[0] = 0; tx_frames_by_div[1] = 0;
                  tx_frames_by_div[2] = 0; tx_frames_by_div[3] = 0; end

    function integer grid_known(input integer e);
        grid_known = (e >= tick_switch) ? tick_known : tickp_known;
    endfunction
    function integer is_tick(input integer e);
        if (e >= tick_switch) is_tick = tick_known  && e >= tick_ref  && (e - tick_ref)  % tick_d  == 0;
        else                  is_tick = tickp_known && e >= tickp_ref && (e - tickp_ref) % tickp_d == 0;
    endfunction
    // A divisor latch write completed on edge p.
    task automatic tick_restart(input integer p, input integer d);
        begin
            tickp_known = tick_known; tickp_ref = tick_ref; tickp_d = tick_d;
            tick_switch = p + 1;
            tick_known = 1'b1; tick_ref = p + 1; tick_d = d;
        end
    endtask

    // THRE (= TEMT) as seen by a read completing on edge p.
    function integer thre_at(input integer p);
        thre_at = (!f_active || (f_thre_edge >= 0 && p > f_thre_edge)) ? 1 : 0;
    endfunction

    task automatic tx_frame_done;
        begin
            tx_frames = tx_frames + 1;
            if (f_d == 1)      tx_frames_by_div[0] = tx_frames_by_div[0] + 1;
            else if (f_d < 4)  tx_frames_by_div[1] = tx_frames_by_div[1] + 1;
            else if (f_d < 32) tx_frames_by_div[2] = tx_frames_by_div[2] + 1;
            else               tx_frames_by_div[3] = tx_frames_by_div[3] + 1;
            f_active = 1'b0;
        end
    endtask

    task automatic tx_taken(input [7:0] data, input integer p_first, input integer p);
        integer busy_until, want;
        begin
            tx_writes = tx_writes + 1;
            if (p > p_first) tx_stalls = tx_stalls + 1;
            busy_until = !f_active ? 0 : (f_thre_edge >= 0 ? f_thre_edge + 1 : -1);
            checks = checks + 1;
            if (busy_until < 0)
                fail($sformatf("THR write (%02h) taken on edge %0d while the frame written on edge %0d is still going (tick %0d of 160)",
                               data, p, f_W, f_ticks));
            else begin
                want = (p_first > busy_until) ? p_first : busy_until;
                if (p != want)
                    fail($sformatf("THR write (%02h) completed on edge %0d, want %0d (requested for %0d, THRE from %0d): ready must be low exactly while busy",
                                   data, p, want, p_first, busy_until));
            end
            if (f_active) tx_frame_done;        // its stop bit ends on the next tick
            f_active = 1'b1; f_W = p; f_ticks = 0; f_d = cur_div(); f_data = data; f_thre_edge = -1;
        end
    endtask

    integer   mt_bit;
    reg       mt_exp;
    always @(negedge clk) begin
        if (rst_q) begin
            checks = checks + 1;
            if (tx !== 1'b1) fail("TX is not idle (1) during reset");
            if (f_active) tx_writes = tx_writes - 1;      // a frame reset cut off
            f_active = 1'b0;
            tick_known = 1'b0; tickp_known = 1'b0; tick_switch = 0;
            sbc_pin = 1'b0;
        end else if (mon_on) begin
            if (tx !== 1'b0 && tx !== 1'b1) fail("TX is X");
            // SBC reaches the pin on a tick.
            if (grid_known(cyc) && is_tick(cyc))
                sbc_pin = (cyc > sbc_edge) ? m_sbc : m_sbc_old;
            else if (!grid_known(cyc) && m_sbc)
                tb_bug("SBC set before the tick grid is known");
            if (f_active) begin
                if (cyc > f_W) begin
                    if (!grid_known(cyc)) begin
                        // No grid yet (reset): the start bit shows where it is.
                        if (tx === 1'b0) begin
                            checks = checks + 1;
                            tick_known = 1'b1; tick_ref = cyc; tick_d = f_d; tick_switch = cyc;
                            f_ticks = 1;
                        end else if (cyc >= f_W + f_d) begin
                            fail($sformatf("TX: no start bit within one 16x tick (%0d clocks) of the THR write", f_d));
                            tick_known = 1'b1; tick_ref = cyc; tick_d = f_d; tick_switch = cyc;
                        end
                    end else if (is_tick(cyc))
                        f_ticks = f_ticks + 1;
                end
                if (f_ticks == 160 && f_thre_edge < 0) f_thre_edge = cyc;
                mt_bit = (f_ticks - 1) / 16;        // 0 start, 1-8 data, 9 stop
                mt_exp = (f_ticks == 0)  ? 1'b1 :
                         (mt_bit == 0)   ? 1'b0 :
                         (mt_bit <= 8)   ? f_data[mt_bit - 1] : 1'b1;
                mt_exp = mt_exp && !sbc_pin;
                checks = checks + 1;
                if (tx !== mt_exp)
                    fail($sformatf("TX pin %b, want %b: frame %02h (divisor %0d), 16x tick %0d, %0d clocks after the THR write, SBC %0d",
                                   tx, mt_exp, f_data, f_d, f_ticks, cyc - f_W, sbc_pin));
                if (f_ticks >= 161) tx_frame_done;
            end else begin
                checks = checks + 1;
                if (tx !== !sbc_pin)
                    fail(sbc_pin ? "TX not held at 0 by SBC" : "TX not idle with no frame written");
            end
        end
    end

    // ── Receive model ───────────────────────────────────────────────────────
    // DR and OE rise at the stop bit's middle sample; the model knows only a
    // window for it (see rxm_start). A pending rise is resolved when a read
    // sees it, or when the window has passed. The random driver keeps RBR
    // pops out of DR windows and start-bit detection windows, and OE-clearing
    // reads out of OE windows while OE is already set, so every frame's fate
    // is certain.
    // K_LATE_BRK: a framing error whose line then stays low for a whole
    // frame more -- a break that began inside the character.
    localparam integer K_GOOD = 0, K_BAD = 1, K_GLITCH = 2, K_LATE_BRK = 3;
    reg        rxm_on = 1'b1;
    reg        dr_val = 1'b0, dr_pend = 1'b0;
    real       dr_lo, dr_hi;
    reg  [7:0] rbr_pend;
    reg        oe_val = 1'b0, oe_pend = 1'b0;
    real       oe_lo, oe_hi;
    // BI: pending from a break's start to its stop-bit sample, rising with
    // that frame's DR (bi_link 1) or OE (bi_link 2).
    reg        bi_val = 1'b0, bi_pend = 1'b0;
    real       bi_lo, bi_hi;
    integer    bi_link = 0, rx_breaks = 0, bi_seen = 0;
    reg  [7:0] m_rbr;
    reg        m_rbr_known = 1'b0;
    integer    rx_kept = 0, rx_dropped = 0, rx_popped = 0, rx_bad = 0, rx_glitches = 0;
    integer    oe_seen = 0;
    // The frame now on the line, for RTS# and the detection window.
    real       fr_t0 = -1.0e9, fr_hi_from = 1.0e18, fr_hi_to = -1.0e18;
    integer    fr_d = 1;
    reg        fr_brk = 1'b0;            // the frame on the line is a break
    real       rx_quiet_from = 1.0e18;   // RTS# must be asserted from here, if RBR is empty
    integer    pop_hold_until = -1;      // RTS# still deasserted on this edge (the pop)
    reg        rts_chk_on = 1'b1;

    task automatic rxm_advance(input real t);
        begin
            if (dr_pend && t > dr_hi) begin
                dr_pend = 1'b0; dr_val = 1'b1; m_rbr = rbr_pend; m_rbr_known = 1'b1;
            end
            if (oe_pend && t > oe_hi) begin
                oe_pend = 1'b0; oe_val = 1'b1;
            end
            if (bi_pend && t > bi_hi) begin
                bi_pend = 1'b0; bi_val = 1'b1;
            end
        end
    endtask
    function integer dr_at(input real t);   // 0, 1, or 2 = either
        if (dr_pend) dr_at = (t <= dr_lo) ? 0 : 2;
        else         dr_at = dr_val;
    endfunction
    function integer oe_at(input real t);
        if (oe_val)       oe_at = 1;
        else if (oe_pend) oe_at = (t <= oe_lo) ? 0 : 2;
        else              oe_at = 0;
    endfunction
    function integer bi_at(input real t);
        if (bi_val)       bi_at = 1;
        else if (bi_pend) bi_at = (t <= bi_lo) ? 0 : 2;
        else              bi_at = 0;
    endfunction

    // A falling edge on RX at t0 (the reference transmitter calls this).
    // Sampling bounds, for divisor d and clock period T: the start bit is
    // seen by the synchroniser on the first edge after t0 and detected on
    // a 16x tick at least two edges later -- in (t0 + 2T, t0 + (d + 2)T] --
    // and the stop bit's middle is 152 ticks after detection.
    task automatic rxm_start(input real t0, input integer d, input [7:0] data, input integer kind);
        reg brk;
        real sh;                         // a late break's samples: 144 ticks later
        begin
            brk = (kind == K_BAD && data == 8'h00) || kind == K_LATE_BRK;
            sh  = (kind == K_LATE_BRK) ? 144.0 * d * T : 0.0;
            fr_brk = brk;
            fr_t0 = t0; fr_d = d;
            fr_hi_from = (kind == K_GLITCH) ? 1.0e18 : t0 + (d + 3) * T;
            // A good frame keeps RTS# deasserted until the stop bit's sample
            // at the earliest; from there a pending or set DR does.
            fr_hi_to   = (kind == K_GOOD) ? t0 + (152*d + 2) * T : 1.0e18;
            rx_quiet_from = (kind == K_GOOD)   ? t0 + (153*d + 4) * T :
                            (kind == K_GLITCH) ? t0 + (9*d + 4) * T : 1.0e18;
            if (kind == K_GLITCH) rx_glitches = rx_glitches + 1;
            if (kind == K_BAD || kind == K_LATE_BRK) rx_bad = rx_bad + 1;
            if (rxm_on) begin
                rxm_advance(t0 + 2.0 * T);
                if (dr_pend) tb_bug("a frame starts inside the previous frame's DR window");
                if (oe_pend) tb_bug("a frame starts inside the previous frame's OE window");
                if (bi_pend) tb_bug("a frame starts inside the previous frame's BI window");
                if (kind == K_GOOD || brk) begin
                    if (!dr_val) begin
                        dr_pend = 1'b1; rbr_pend = brk ? 8'h00 : data;
                        dr_lo = t0 + (152*d + 2) * T + sh; dr_hi = t0 + (153*d + 2) * T + sh;
                        rx_kept = rx_kept + 1;
                        bi_link = 1;
                    end else begin
                        oe_pend = 1'b1;
                        oe_lo = t0 + (152*d + 2) * T + sh; oe_hi = t0 + (153*d + 2) * T + sh;
                        rx_dropped = rx_dropped + 1;
                        bi_link = 2;
                    end
                end
                if (brk) begin
                    bi_pend = 1'b1;
                    bi_lo = t0 + (152*d + 2) * T + sh; bi_hi = t0 + (153*d + 2) * T + sh;
                    rx_breaks = rx_breaks + 1;
                end
            end
        end
    endtask
    // The line went high again after a frame whose stop bit was 0. After a
    // break the receiver wants half a bit (8 ticks) of high line first.
    task automatic rxm_line_high(input real th);
        begin
            fr_hi_to      = fr_brk ? th + (7*fr_d + 2) * T : th + 2.0 * T;
            rx_quiet_from = fr_brk ? th + (8*fr_d + 4) * T : th + 4.0 * T;
            if (fr_t0 + (153*fr_d + 4) * T > rx_quiet_from) rx_quiet_from = fr_t0 + (153*fr_d + 4) * T;
        end
    endtask

    task automatic rxm_reset;
        begin
            dr_val = 1'b0; dr_pend = 1'b0; oe_val = 1'b0; oe_pend = 1'b0; m_rbr_known = 1'b0;
            bi_val = 1'b0; bi_pend = 1'b0;
            fr_t0 = -1.0e9; fr_hi_from = 1.0e18; fr_hi_to = -1.0e18;
            pop_hold_until = -1;
        end
    endtask

    // Would an RBR pop completing at tp be unambiguous?
    real snd_next_fall = 1.0e18;             // the random transmitter's next start bit
    function integer pop_ok(input real tp);
        pop_ok = !(dr_pend && tp > dr_lo - T)
              && !(tp >= fr_t0 - T && tp <= fr_t0 + (fr_d + 4) * T)
              && !(tp >= snd_next_fall - 2.0 * T && tp <= snd_next_fall + (fr_d + 4) * T);
    endfunction
    function integer oeclr_ok(input real tp);
        oeclr_ok = !(oe_pend && oe_val && tp > oe_lo) && !(bi_pend && bi_val && tp > bi_lo);
    endfunction

    // RTS# checker.
    real rts_now;
    reg  rts_hi, rts_lo;
    always @(negedge clk) begin
        rts_now = $realtime;
        if (rst_q) begin
            checks = checks + 1;
            if (rts_n !== 1'b1) fail("RTS# asserted during reset");
        end else begin
            if (rts_n !== 1'b0 && rts_n !== 1'b1) fail("RTS# is X");
            if (rts_chk_on) begin
                rts_hi = (rts_now >= fr_hi_from && rts_now <= fr_hi_to)
                      || (rxm_on && (dr_val || (dr_pend && rts_now > dr_lo)))
                      || (cyc <= pop_hold_until);
                rts_lo = rxm_on && rts_now >= rx_quiet_from && !dr_val && !dr_pend
                      && cyc > pop_hold_until;
                if (rts_hi && rts_lo) tb_bug("RTS# model wants both levels");
                else if (rts_hi && rts_n !== 1'b1) begin
                    checks = checks + 1;
                    fail("RTS# asserted while a frame is being received or RBR holds a byte");
                end else if (rts_lo && rts_n !== 1'b0) begin
                    checks = checks + 1;
                    fail("RTS# not asserted while the receiver is idle and RBR is empty");
                end else if (rts_hi || rts_lo) checks = checks + 1;
            end
        end
    end

    // An IO target may hold ready low only while it is selected (soc_bus).
    always @(negedge clk)
        if (!rst_q) begin
            if (!sel && ready !== 1'b1)   fail("ready low while not selected");
            if (!sel2 && ready2 !== 1'b1) fail("dut2 ready low while not selected");
        end

    // ── Bus driver ──────────────────────────────────────────────────────────
    integer    last_p;       // edge the last transfer completed on
    real       last_pt;      // and its time
    integer    last_stall;   // cycles it waited
    reg [31:0] last_rd;

    task automatic noise;
        begin we = urand(2); be = urand(16); addr2 = urand(2); wdata = $random(seed); end
    endtask
    task automatic idle(input integer n);
        integer k;
        for (k = 0; k < n; k = k + 1) begin @(posedge clk); #1; noise; end
    endtask

    task automatic model_write(input [3:0] b, input a2, input [31:0] wd,
                               input integer p_first, input integer p);
        reg old_dlab;
        begin
            old_dlab = m_dlab;
            if (!a2) begin
                if (old_dlab && (b[0] || b[1])) begin
                    // A divisor latch write restarts the baud generator: the
                    // receiver's samples may come up to a tick early too.
                    if (dr_pend) begin dr_lo = dr_lo - cur_div() * T; fr_hi_to = fr_hi_to - cur_div() * T; end
                    if (oe_pend) oe_lo = oe_lo - cur_div() * T;
                end
                if (b[0]) begin
                    if (old_dlab) m_dll = wd[7:0];
                    else          tx_taken(wd[7:0], p_first, p);
                end
                if (b[1]) begin
                    if (old_dlab) m_dlm = wd[15:8];
                    else begin m_erbfi = wd[8]; m_etbei = wd[9]; end
                end
                if (old_dlab && (b[0] || b[1])) tick_restart(p, cur_div());
                if (b[3]) begin
                    m_dlab = wd[31];
                    m_sbc_old = m_sbc; m_sbc = wd[30]; sbc_edge = p;
                end
            end
            if (!(b[0] && !a2 && !old_dlab)) begin
                checks = checks + 1;
                if (p != p_first) fail($sformatf("a write that is not to THR (be %b, addr2 %0d) stalled", b, a2));
            end
        end
    endtask

    task automatic model_read(input [3:0] b, input a2, input [31:0] got,
                              input integer p, input integer p_first, input real tp);
        integer    dpos, opos, bpos, thre, dh, oh, bh, nm, first;
        reg  [7:0] mt;
        reg [31:0] e, m, e0, m0;
        reg  [7:0] iir, rbrv;
        reg        all_d1, all_d0, all_o1, all_o0, all_b1;
        begin
            checks = checks + 1;
            if (p != p_first) fail("a read stalled");
            if (rxm_on) rxm_advance(tp);
            thre = thre_at(p);
            dpos = rxm_on ? dr_at(tp) : 2;
            opos = rxm_on ? oe_at(tp) : 2;
            bpos = rxm_on ? bi_at(tp) : 2;
            nm = 0; first = 1;
            for (dh = 0; dh < 2; dh = dh + 1)
                for (oh = 0; oh < 2; oh = oh + 1)
                  for (bh = 0; bh < 2; bh = bh + 1) begin
                    mt[dh*4+oh*2+bh] = 1'b0;
                    // A pending break's BI rises on the same edge as the DR or
                    // OE it brings, when that one is still pending too.
                    if ((dpos == 2 || dpos == dh) && (opos == 2 || opos == oh) &&
                        (bpos == 2 || bpos == bh) &&
                        !(rxm_on && bi_pend && bi_link == 1 && dr_pend && bh != dh) &&
                        !(rxm_on && bi_pend && bi_link == 2 && oe_pend && !oe_val && bh != oh)) begin
                        if (a2) begin
                            e = {8'h00, 8'hB0, 1'b0, thre[0], thre[0], bh[0], 2'b00, oh[0], dh[0], 8'h00};
                            m = 32'hFFFF_FFFF;
                        end else begin
                            iir  = (m_erbfi && dh) ? 8'h04 : (m_etbei && thre) ? 8'h02 : 8'h01;
                            rbrv = (dr_pend && dh) ? rbr_pend : m_rbr;
                            e = {m_dlab, m_sbc, 6'b0, iir, m_dlab ? m_dlm : {6'b0, m_etbei, m_erbfi},
                                 m_dlab ? m_dll : rbrv};
                            m = 32'hFFFF_FFFF;
                            // RBR is only defined while DR is set.
                            if (!m_dlab && !(rxm_on && dh && (dr_pend || m_rbr_known))) m[7:0] = 8'h00;
                        end
                        if (first) begin e0 = e; m0 = m; first = 0; end
                        if ((got & m) === (e & m)) begin mt[dh*4+oh*2+bh] = 1'b1; nm = nm + 1; end
                    end
                  end
            if (nm == 0)
                fail($sformatf("read offsets %0d-%0d be %b (DLAB %0d): got %h, want %h (mask %h)",
                               a2 ? 4 : 0, a2 ? 7 : 3, b, m_dlab, got, e0, m0));
            else if (rxm_on) begin
                // mt index = dh*4 + oh*2 + bh
                all_d1 = !(mt[0] || mt[1] || mt[2] || mt[3]); all_d0 = !(mt[4] || mt[5] || mt[6] || mt[7]);
                all_o1 = !(mt[0] || mt[1] || mt[4] || mt[5]); all_o0 = !(mt[2] || mt[3] || mt[6] || mt[7]);
                all_b1 = !(mt[0] || mt[2] || mt[4] || mt[6]);
                if (dr_pend && all_d1) begin
                    dr_pend = 1'b0; dr_val = 1'b1; m_rbr = rbr_pend; m_rbr_known = 1'b1;
                end
                if (a2) begin
                    if (all_o1) oe_seen = oe_seen + 1;
                    if (all_b1) bi_seen = bi_seen + 1;
                    if (oe_pend && all_o1 && !oe_val) begin oe_pend = 1'b0; oe_val = 1'b1; end
                    if (bi_pend && all_b1 && !bi_val) begin bi_pend = 1'b0; bi_val = 1'b1; end
                end
            end
            // Side effects of the completed load.
            if (!a2 && b[0] && !m_dlab && rxm_on) begin
                // Ambiguous only if it may clear a DR that is set: inside a
                // DR window, or while a start bit is being detected.
                if (dr_pend && tp > dr_lo) tb_bug("RBR read inside a DR window");
                if (dr_val && tp >= fr_t0 + T && tp <= fr_t0 + (fr_d + 3) * T)
                    tb_bug("RBR read while a start bit is being detected");
                if (dr_val) begin
                    dr_val = 1'b0; rx_popped = rx_popped + 1; pop_hold_until = p;
                end
            end
            if (a2 && b[1] && rxm_on) begin
                if (oe_pend && oe_val && tp > oe_lo) tb_bug("LSR read inside an OE window while OE is set");
                if (bi_pend && bi_val && tp > bi_lo) tb_bug("LSR read inside a BI window while BI is set");
                oe_val = 1'b0;
                bi_val = 1'b0;
            end
        end
    endtask

    // One transfer, the way the core makes it: the request goes up 1 ns after
    // a rising edge (the core drives it from flops) and stays up until the
    // edge it completes on; returns 1 ns after that edge. Called at any other
    // time -- after a fork that waited on the RX line, say -- it first waits
    // for the next edge, or a request raised just before an edge would be
    // taken on it without the task knowing.
    real t_lastpos = -100.0;
    always @(posedge clk) t_lastpos = $realtime;
    task automatic bus(input w, input [3:0] b, input a2, input [31:0] wd);
        integer    n, p_first;
        reg [18:0] snap;
        real       tp;
        begin
            if ($realtime != t_lastpos + 1.0) begin @(posedge clk); #1; end
            sel = 1'b1; we = w; be = b; addr2 = a2; wdata = wd;
            p_first = cyc + 1;
            snap = {dut.dlab, dut.erbfi, dut.etbei, dut.dll, dut.dlm};
            #1;
            n = 0;
            while (ready !== 1'b1 && n <= 200000) begin
                if (ready !== 1'b0) fail("ready is X");
                @(posedge clk); #1;
                n = n + 1;
                // A write waiting for ready must not have written anything.
                if ({dut.dlab, dut.erbfi, dut.etbei, dut.dll, dut.dlm} !== snap)
                    fail("a register was written while the store was still waiting for ready");
            end
            if (n > 200000) fail("ready never rose");
            last_rd = rdata;
            @(posedge clk);
            tp = $realtime;
            #1;
            last_p = cyc; last_pt = tp; last_stall = n;
            sel = 1'b0;
            noise;
            if (w) model_write(b, a2, wd, p_first, last_p);
            else   model_read(b, a2, last_rd, last_p, p_first, tp);
        end
    endtask

    // Byte-register helpers; offset 0-7. Store data is replicated across the
    // lanes, as the core does.
    task automatic wr8(input integer off, input [7:0] v);
        bus(1'b1, 4'b0001 << (off % 4), off >= 4, {4{v}});
    endtask
    task automatic rd8(input integer off, output [7:0] v);
        begin
            bus(1'b0, 4'b0001 << (off % 4), off >= 4, $random(seed));
            v = last_rd >> (8 * (off % 4));
        end
    endtask

    // Program the divisor, then give the baud generator time to count down
    // whatever it had loaded from the old one (see "divisor reload" below).
    task automatic set_div(input integer v);
        integer old;
        begin
            old = cur_div();
            wr8(3, 8'h80); wr8(0, v[7:0]); wr8(1, v[15:8]); wr8(3, 8'h00);
            idle(old + 2);
        end
    endtask

    task automatic wait_tx_idle;
        reg [7:0] v;
        begin
            v = 0;
            while (!v[6]) begin rd8(5, v); if (!v[6]) idle(urand(8)); end
        end
    endtask

    // Model reset, for a reset released on the edge after this is called.
    task automatic model_reset;
        begin
            m_dlab = 1'b0; m_erbfi = 1'b0; m_etbei = 1'b0; m_dll = 8'd27; m_dlm = 8'd0;
            m_sbc = 1'b0; m_sbc_old = 1'b0; sbc_edge = -1;
            if (dr_val || dr_pend) rx_kept = rx_kept - 1;  // a byte reset threw away
            rxm_reset;
        end
    endtask

    // ── Reference transmitter (the far end of RX) ───────────────────────────
    function real bit_ns(input integer d, input real err);
        bit_ns = 16.0 * d * T * (1.0 + err);
    endfunction

    task automatic rx_frame(input [7:0] data, input real tb, input integer d,
                            input stop, input real extra_low);
        real    t0;
        integer i;
        begin
            t0 = $realtime;
            rx = 1'b0;
            // After a framing error the receiver counts one more frame of low
            // line from the bad stop bit's sample. The tests keep extra_low
            // either at most 3 bits (no break) or at least 11 (a break): in
            // between, whether it is one depends on the sampling phase.
            if (!stop && data != 8'h00 && extra_low > 3.5 * tb && extra_low < 11.0 * tb)
                tb_bug("framing error with an ambiguous low tail");
            rxm_start(t0, d, data, stop ? K_GOOD : (data != 8'h00 && extra_low >= 11.0 * tb) ? K_LATE_BRK : K_BAD);
            #(tb);
            for (i = 0; i < 8; i = i + 1) begin rx = data[i]; #(tb); end
            rx = stop;
            #(tb);
            if (!stop) begin
                if (extra_low > 0.0) #(extra_low);
                rx = 1'b1;
                rxm_line_high($realtime);
            end
        end
    endtask
    task automatic rx_glitch(input real len, input integer d);
        begin
            rx = 1'b0;
            rxm_start($realtime, d, 8'h00, K_GLITCH);
            #(len);
            rx = 1'b1;
        end
    endtask
    task automatic rx_break(input real len, input integer d);
        begin
            rx = 1'b0;
            rxm_start($realtime, d, 8'h00, K_BAD);
            #(len);
            rx = 1'b1;
            rxm_line_high($realtime);
        end
    endtask
    // A break of len1, a high glitch of g, then len2 more of low line: one
    // break, since the glitch is under half a bit.
    task automatic rx_break_glitch(input real len1, input real g, input real len2, input integer d);
        begin
            rx = 1'b0;
            rxm_start($realtime, d, 8'h00, K_BAD);
            #(len1);
            rx = 1'b1;
            #(g);
            rx = 1'b0;
            #(len2);
            rx = 1'b1;
            rxm_line_high($realtime);
        end
    endtask
    // CTS: a sender with flow control checks it before each character.
    task automatic wait_cts;
        begin
            while (rts_n !== 1'b0) @(negedge clk);
            #(urand(3000) / 100.0);           // its own synchroniser, 0-30 ns
        end
    endtask

    // Poll LSR until DR, then pop RBR; the model checks both values.
    task automatic get_byte;
        reg [7:0] v;
        integer   k;
        begin
            v = 0; k = 0;
            while (!v[0] && k < 100000) begin rd8(5, v); k = k + 1; if (!v[0]) idle(urand(5)); end
            if (!v[0]) fail("DR never rose");
            rd8(0, v);
        end
    endtask

    // Wait for the model's windows to close and the line to go quiet.
    task automatic rx_settle;
        begin
            while ($realtime < rx_quiet_from + 2.0 * T || dr_pend || oe_pend || bi_pend) begin
                idle(1);
                rxm_advance($realtime);
            end
        end
    endtask

    // ── Random traffic on RX, for the random run ────────────────────────────
    reg     snd_run = 1'b0, snd_cts = 1'b1, snd_active = 1'b0;
    integer snd_d = 1, snd_sent = 0;
    always begin : rand_sender
        real      tb, e, t0, lat;
        reg [7:0] data;
        integer   kind;
        wait (snd_run);
        snd_active = 1'b1;
        data = urand(256);
        e    = (urand(6001) - 3000) / 100000.0;
        tb   = bit_ns(snd_d, e);
        kind = urand(100);
        if (snd_cts) begin
            while (rts_n !== 1'b0 && snd_run) @(negedge clk);
            if (snd_run) begin
                lat = urand(3000) / 100.0;
                if (urand(4) == 0) lat = lat + urand(3) * tb;     // an idle gap
                #(lat);
            end
        end else begin
            // Publish the start at least four clocks ahead, clear of the
            // previous frame's DR/OE window.
            if (urand(3) == 0) lat = 4.0 * T + urand(30) * tb;
            else               lat = 4.0 * T + urand(1000) / 1000.0 * tb;
            t0 = $realtime + lat;
            if (dr_pend && t0 < dr_hi) t0 = dr_hi + T;
            if (oe_pend && t0 < oe_hi) t0 = oe_hi + T;
            if (bi_pend && t0 < bi_hi) t0 = bi_hi + T;
            snd_next_fall = t0;
            #(t0 - $realtime);
        end
        if (snd_run) begin
            if (kind < 4)       rx_glitch((1 + urand(8*snd_d - 1)) * T - 0.5, snd_d);
            else if (kind < 8)  rx_frame(data, tb, snd_d, 1'b0, urand(3) * tb);
            else if (kind < 10) rx_break((10 + urand(20)) * tb, snd_d);
            else                rx_frame(data, tb, snd_d, 1'b1, 0.0);
            snd_sent = snd_sent + 1;
            #(tb);          // at least a bit of idle before the next start
        end
        snd_next_fall = 1.0e18;
        snd_active = 1'b0;
    end

    task automatic sender_stop;
        begin
            snd_run = 1'b0;
            while (snd_active) idle(1);
        end
    endtask

    // ── Tests ───────────────────────────────────────────────────────────────
    reg [7:0]  v8, a8;
    reg [31:0] v32;
    integer    i, j, k, n, d, a2i, bi, dl, p0, p1, t_rise;
    real       tb, t0r;
    integer    divs [0:6];
    integer    nrand;

    initial begin
        if ($value$plusargs("SEED=%d", seed)) ;
        if (!$value$plusargs("NRAND=%d", nrand)) nrand = 1500;
        model_reset;
        noise;

        // ── Reset ──────────────────────────────────────────────────────────
        section("reset");
        // Hold reset for a while with the bus and RX busy: TX and RTS# must
        // stay 1 on every clock (the checkers above).
        for (i = 0; i < 20; i = i + 1) begin
            @(posedge clk); #1;
            noise; sel = urand(2); rx = urand(2);
        end
        sel = 1'b0; rx = 1'b1;
        @(posedge clk); #1;
        rst = 1'b0;
        rx_quiet_from = $realtime + T;
        chk("RTS# on the last clock of reset", rts_n, 1'b1);
        @(posedge clk); @(negedge clk);
        chk("RTS# on the first clock after reset", rts_n, 1'b0);
        chk("TX on the first clock after reset", tx, 1'b1);
        @(posedge clk); #1;

        // Reset values, every offset, both DLAB settings, every byte enable.
        section("reset values");
        for (bi = 0; bi < 16; bi = bi + 1) begin
            bus(1'b0, bi, 1'b0, $random(seed));
            bus(1'b0, bi, 1'b1, $random(seed));
        end
        rd8(5, v8); chk("LSR after reset", v8, 8'h60);
        rd8(2, v8); chk("IIR after reset", v8, 8'h01);
        rd8(1, v8); chk("IER after reset", v8, 8'h00);
        rd8(3, v8); chk("LCR after reset", v8, 8'h00);
        rd8(4, v8); chk("MCR after reset", v8, 8'h00);
        rd8(6, v8); chk("MSR after reset", v8, 8'hB0);
        rd8(7, v8); chk("SCR after reset", v8, 8'h00);
        rd8(0, v8); chk("RBR after reset (DR clear)", v8, 8'h00);
        wr8(3, 8'h80);
        rd8(0, v8); chk("DLL after reset", v8, 8'd27);
        rd8(1, v8); chk("DLM after reset", v8, 8'd0);
        for (bi = 0; bi < 16; bi = bi + 1) begin
            bus(1'b0, bi, 1'b0, $random(seed));
            bus(1'b0, bi, 1'b1, $random(seed));
        end
        wr8(3, 8'h00);
        // DIV_RESET reaches both latches (the second instance).
        sel2 = 1'b1; we = 1'b1; be = 4'b1000; addr2 = 1'b0; wdata = 32'h8000_0000;
        @(posedge clk); #1;
        we = 1'b0; be = 4'b0011; #1;
        chk("dut2 DLL/DLM from DIV_RESET = A503", rdata2[15:0], 16'hA503);
        @(posedge clk); #1;
        we = 1'b1; be = 4'b1000; wdata = 32'h0;
        @(posedge clk); #1;
        sel2 = 1'b0; noise;

        // ── Register semantics: every offset x every byte enable x DLAB ─────
        section("register writes, every lane and byte enable");
        set_div(2);
        for (k = 0; k < 2; k = k + 1)
            for (a2i = 0; a2i < 2; a2i = a2i + 1)
                for (bi = 0; bi < 16; bi = bi + 1) begin
                    // DLAB for this write
                    wr8(3, k ? 8'h80 : 8'h00);
                    v32 = $random(seed);
                    // Keep the divisor small: lane 1 is DLM under DLAB.
                    if (k) v32[15:8] = urand(2);
                    bus(1'b1, bi, a2i, v32);
                    // Read everything back under both DLAB settings.
                    bus(1'b0, 4'b1111, 1'b0, 0); bus(1'b0, 4'b1111, 1'b1, 0);
                    wr8(3, m_dlab ? 8'h00 : 8'h80);
                    bus(1'b0, 4'b1110, 1'b0, 0); bus(1'b0, 4'b1111, 1'b1, 0);
                    // Put the divisor back before the next THR write.
                    if (cur_div() != 2) begin
                        n = cur_div();
                        wr8(3, 8'h80); wr8(0, 8'd2); wr8(1, 8'd0);
                        idle(n + 2);
                    end
                    wr8(3, 8'h00);
                    wait_tx_idle;
                end
        // The DLM/DLL latches hold any value, and a word store writes each
        // lane from its own byte.
        wr8(3, 8'h80);
        bus(1'b1, 4'b1111, 1'b0, 32'h83C7A55A);   // LCR 83, FCR C7, DLM A5, DLL 5A
        bus(1'b0, 4'b1111, 1'b0, 0);
        chk("word store under DLAB: DLL", last_rd[7:0], 8'h5A);
        chk("word store under DLAB: DLM", last_rd[15:8], 8'hA5);
        chk("word store under DLAB: LCR", last_rd[31:24], 8'h80);
        bus(1'b1, 4'b0011, 1'b0, 32'h0000_0002);
        idle(3); wr8(3, 8'h00); idle(32'hA55A + 2);
        // Writes to the read-only and ignored registers change nothing.
        for (i = 0; i < 20; i = i + 1) begin
            bus(1'b1, urand(16), 1'b1, $random(seed));      // MCR, LSR, MSR, SCR
            bus(1'b1, 4'b0100, 1'b0, $random(seed));        // FCR
            bus(1'b0, 4'b1111, 1'b1, 0);
            bus(1'b0, 4'b1110, 1'b0, 0);
        end

        // ── Transmit: frame timing at each divisor ──────────────────────────
        section("transmit timing");
        divs[0] = 27; divs[1] = 0; divs[2] = 1; divs[3] = 2; divs[4] = 3; divs[5] = 5; divs[6] = 300;
        for (k = 0; k < 7; k = k + 1) begin
            if (k > 0) set_div(divs[k]);
            else if (cur_div() != 27) set_div(27);
            n = (divs[k] >= 27) ? 3 : 10;
            for (i = 0; i < n; i = i + 1) begin
                case (i)
                    0: v8 = 8'h00;  1: v8 = 8'hFF;  2: v8 = 8'h55;  3: v8 = 8'hAA;
                    4: v8 = 8'h01;  5: v8 = 8'h80;  default: v8 = urand(256);
                endcase
                wr8(0, v8);                       // back to back: all but the first stall
                if (i % 3 == 2) begin
                    rd8(5, a8); rd8(2, a8);       // LSR and IIR while busy
                    idle(urand(20));
                end
            end
            wait_tx_idle;
        end
        if (tx_stalls < 10) fail("transmit timing: THR writes did not stall");

        // ── Back-pressure ───────────────────────────────────────────────────
        section("back-pressure");
        set_div(3);
        wr8(1, 8'h02);                              // ETBEI, so IIR tracks THRE
        wr8(0, 8'h11);
        // Writes to anything but THR complete at once while TX is busy.
        bus(1'b1, 4'b0010, 1'b0, 32'h0000_0300);   // IER
        bus(1'b1, 4'b0100, 1'b0, 32'h00C7_0000);   // FCR
        bus(1'b1, 4'b1000, 1'b0, 32'h0300_0000);   // LCR (DLAB stays 0)
        for (bi = 0; bi < 16; bi = bi + 1) bus(1'b1, bi, 1'b1, $random(seed));
        bus(1'b1, 4'b0000, 1'b0, $random(seed));   // no lanes at all
        bus(1'b0, 4'b1111, 1'b0, 0);
        bus(1'b0, 4'b1111, 1'b1, 0);
        // Under DLAB, lane 0 is DLL: no stall, even though TX is busy.
        wr8(3, 8'h80);
        bus(1'b1, 4'b0011, 1'b0, 32'h0000_0003);   // same divisor, 3
        chk("DLL write under DLAB while TX busy: no stall", last_stall, 0);
        wr8(3, 8'h00);
        // A word store writing THR and LCR (setting DLAB) while TX is busy:
        // nothing is written until THR is taken, so DLAB cannot flip under
        // it and turn the THR write into a DLL write.
        wr8(0, 8'h22);
        bus(1'b1, 4'b1111, 1'b0, 32'h80C7_035A);   // LCR 80, FCR C7, IER 03, THR 5A
        chk("THR+LCR word store waited", last_stall > 0, 1'b1);
        bus(1'b0, 4'b1111, 1'b0, 0);               // DLAB now 1: DLL/DLM unchanged
        wr8(3, 8'h00);
        rd8(1, v8); chk("IER written by the stalled word store, once", v8, 8'h03);
        // A halfword store (THR + IER) while busy: IER waits for THR too.
        bus(1'b1, 4'b0011, 1'b0, 32'h0000_0077);   // THR 77, IER 00
        chk("THR+IER halfword store waited", last_stall > 0, 1'b1);
        rd8(1, v8); chk("IER from the stalled halfword store", v8, 8'h00);
        // A word store with DLAB set, clearing it, while TX is busy: lane 0 is
        // DLL, so it does not wait, and DLAB clears on the same edge.
        wr8(3, 8'h80);
        bus(1'b1, 4'b1011, 1'b0, 32'h0000_0003);
        chk("DLL+DLM+LCR word store under DLAB: no stall", last_stall, 0);
        rd8(3, v8); chk("DLAB cleared by that store", v8, 8'h00);
        wait_tx_idle;
        wr8(1, 8'h00);

        // ── Break control (LCR.SBC) ─────────────────────────────────────────
        // The TX model holds the pin at 0 from the first tick after SBC is
        // set to the first tick after it is cleared.
        section("break control");
        for (k = 0; k < 3; k = k + 1) begin
            set_div(k == 0 ? 1 : k == 1 ? 3 : 27);
            d = cur_div();
            wr8(3, 8'h40);                            // break, line idle
            idle(40 * d);
            rd8(3, v8); chk("LCR reads SBC back", v8, 8'h40);
            wr8(3, 8'h00);
            idle(20 * d);
            wr8(0, 8'h5A);                            // a frame under a break:
            wr8(3, 8'h40);                            //   shifts, the pin stays 0
            wait_tx_idle;
            idle(20 * d);
            wr8(3, 8'h00);
            wr8(0, 8'hC3);                            // break raised mid-frame,
            idle(16 * 3 * d);                         //   then cleared mid-frame
            wr8(3, 8'h40);
            idle(16 * 3 * d + urand(16 * d));
            wr8(3, 8'h00);
            wait_tx_idle;
            wr8(3, 8'hC0); wr8(3, 8'h00);             // with DLAB too, and back
            idle(40 * d);
        end

        // ── Receive: random bytes, baud error, every divisor ────────────────
        section("receive");
        divs[0] = 1; divs[1] = 2; divs[2] = 3; divs[3] = 5; divs[4] = 27;
        for (k = 0; k < 5; k = k + 1) begin
            set_div(divs[k]);
            d = cur_div();
            n = (d >= 27) ? 4 : 16;
            for (i = 0; i < n; i = i + 1) begin
                case (i)
                    0: tb = bit_ns(d,  0.03);   1: tb = bit_ns(d, -0.03);
                    2: tb = bit_ns(d,  0.0);    default: tb = bit_ns(d, (urand(6001) - 3000) / 100000.0);
                endcase
                case (i)
                    0: v8 = 8'h00; 1: v8 = 8'hFF; 2: v8 = 8'h55; 3: v8 = 8'hAA;
                    4: v8 = 8'h80; 5: v8 = 8'h01; default: v8 = urand(256);
                endcase
                fork
                    begin wait_cts; rx_frame(v8, tb, d, 1'b1, 0.0); end
                    get_byte;
                join
            end
            rx_settle;
        end
        // Both baud extremes on the bytes whose last bits sit nearest the
        // sampling limits, at divisors 1 and 4.
        for (k = 0; k < 2; k = k + 1) begin
            set_div(k ? 4 : 1);
            d = cur_div();
            for (i = 0; i < 12; i = i + 1) begin
                case (i % 6)
                    0: v8 = 8'h00; 1: v8 = 8'hFF; 2: v8 = 8'h55; 3: v8 = 8'hAA; 4: v8 = 8'h7F; 5: v8 = 8'hFE;
                endcase
                tb = bit_ns(d, (i < 6) ? 0.03 : -0.03);
                fork
                    begin wait_cts; rx_frame(v8, tb, d, 1'b1, 0.0); end
                    get_byte;
                join
            end
            rx_settle;
        end
        // A sender with flow control leaves the line idle between frames, so
        // the stop bit's sample (9.5 to 9.5625 bits in) may fall past a fast
        // sender's stop bit: +/-4.5% still samples every bit inside it.
        section("receive, baud error swept over +/-4.5%");
        for (k = 0; k < 4; k = k + 1) begin
            set_div(k == 0 ? 1 : k == 1 ? 2 : k == 2 ? 4 : 13);
            d = cur_div();
            for (j = -9; j <= 9; j = j + 1)
                for (i = 0; i < 3; i = i + 1) begin
                    v8 = (i == 0) ? 8'h7F : (i == 1) ? 8'hFE : urand(256);
                    fork
                        begin wait_cts; rx_frame(v8, bit_ns(d, j * 0.005), d, 1'b1, 0.0); end
                        get_byte;
                    join
                end
            rx_settle;
        end
        if (rx_popped != rx_kept || rx_kept < 300) fail($sformatf("receive: %0d kept, %0d popped", rx_kept, rx_popped));

        // ── Glitches: anything shorter than half a bit is ignored ───────────
        section("glitches");
        for (k = 0; k < 3; k = k + 1) begin
            set_div(k == 0 ? 1 : (k == 1 ? 2 : 4));
            d = cur_div();
            for (i = 1; i < 8 * d; i = i + 1) begin
                idle(urand(7));
                #(urand(1000) / 100.0);
                rx_glitch(i * T - 0.05, d);         // just under i clocks
                rx_settle;
                rd8(5, v8);                          // LSR 0x60: nothing arrived
            end
            // Just under half a bit, then a real byte right after.
            rx_glitch(8 * d * T - 0.05, d);
            rx_settle;
            fork
                begin wait_cts; rx_frame(8'hC3, bit_ns(d, 0.0), d, 1'b1, 0.0); end
                get_byte;
            join
            rx_settle;
        end

        // ── Framing errors and breaks ───────────────────────────────────────
        section("framing error and break");
        set_div(2); d = 2; tb = bit_ns(d, 0.0);
        for (i = 0; i < 3; i = i + 1) begin
            // Stop bit 0, then the line stays low for 0, 1 or 3 more bits.
            fork
                begin wait_cts; rx_frame(8'hA5 + i, tb, d, 1'b0, i == 0 ? 0.0 : (2*i - 1) * tb); end
            join
            rx_settle;
            rd8(5, v8);                              // LSR 0x60: dropped, no OE
            fork
                begin wait_cts; rx_frame(8'h3C + i, tb, d, 1'b1, 0.0); end
                get_byte;
            join
            rx_settle;
        end
        // A framing error whose line goes high for less than a bit before the
        // next start bit: the receiver must be looking for it again.
        fork
            begin wait_cts; rx_frame(8'h96, tb, d, 1'b0, 0.0); #(tb * 0.25); rx_frame(8'h69, tb, d, 1'b1, 0.0); end
            begin rx_settle; get_byte; end
        join
        rx_settle;
        // Breaks of 1.5 and 4 frames: BI, and DR with a zero byte in RBR.
        for (i = 0; i < 2; i = i + 1) begin
            wait_cts;
            rx_break((i ? 40.0 : 15.0) * tb, d);
            rx_settle;
            chk("RTS# while the break's zero byte waits", rts_n, 1'b1);
            rd8(5, v8); chk("LSR after a break", v8, 8'h71);
            rd8(5, v8); chk("LSR read again: BI cleared", v8, 8'h61);
            rd8(0, v8); chk("a break loads 0 into RBR", v8, 8'h00);
            rd8(5, v8); chk("LSR after popping the break", v8, 8'h60);
            fork
                begin wait_cts; rx_frame(8'h5A, tb, d, 1'b1, 0.0); end
                get_byte;
            join
            rx_settle;
        end
        // A break the length of one frame exactly: a zero byte with a zero
        // stop bit.
        fork
            begin wait_cts; rx_frame(8'h00, tb, d, 1'b0, 0.0); end
        join
        rx_settle;
        rd8(5, v8); chk("LSR after a frame-long break", v8, 8'h71);
        rd8(0, v8); chk("frame-long break: RBR", v8, 8'h00);
        // A break while RBR is full (a sender ignoring CTS): OE and BI, and
        // RBR keeps the older byte.
        wait_cts; rx_frame(8'h6B, tb, d, 1'b1, 0.0); rx_settle;
        rx_break(15.0 * tb, d); rx_settle;
        rd8(5, v8); chk("LSR after a break with RBR full", v8, 8'h73);
        rd8(5, v8); chk("then BI and OE cleared", v8, 8'h61);
        rd8(0, v8); chk("RBR keeps the byte before the break", v8, 8'h6B);
        rd8(5, v8);
        // A break that begins inside a character: the character ends in a
        // framing error, and the line stays low for a whole frame more.
        wait_cts;
        rx_frame(8'hF7, tb, d, 1'b0, 14.0 * tb); rx_settle;
        rd8(5, v8); chk("LSR after a break that began mid-character", v8, 8'h71);
        rd8(0, v8); chk("mid-character break: RBR", v8, 8'h00);
        rd8(5, v8);
        // A high glitch of a quarter bit inside a long break is not the end
        // of it: the receiver wants half a bit of high line first, so there
        // is one break, not two (a second would set OE, RBR being full).
        wait_cts;
        rx_break_glitch(15.0 * tb, 0.25 * tb, 12.0 * tb, d); rx_settle;
        rd8(5, v8); chk("LSR after a break with a glitch inside", v8, 8'h71);
        rd8(0, v8); chk("glitched break: RBR", v8, 8'h00);
        rd8(5, v8); chk("glitched break: one break only", v8, 8'h60);
        // A framing error is not a break: one data bit of 1 is enough.
        fork
            begin wait_cts; rx_frame(8'h80, tb, d, 1'b0, 3.0 * tb); end
        join
        rx_settle;
        rd8(5, v8); chk("LSR after a framing error on 0x80", v8, 8'h60);
        if (rx_bad < 11) fail("framing: too few bad frames sent");

        // ── Overrun ─────────────────────────────────────────────────────────
        section("overrun");
        set_div(2); d = 2; tb = bit_ns(d, 0.0);
        n = rx_dropped;
        // A arrives and is left in RBR; B ignores CTS: dropped, OE at its stop.
        wait_cts; rx_frame(8'hA1, tb, d, 1'b1, 0.0);
        rx_settle;
        chk("RTS# with RBR full", rts_n, 1'b1);
        rx_frame(8'hB2, tb, d, 1'b1, 0.0);
        rx_settle;
        rd8(6, v8);                                 // MSR: does not clear OE
        bus(1'b0, 4'b1101, 1'b1, 0);                // SCR, MSR, MCR: neither
        rd8(5, v8); chk("LSR after the overrun", v8, 8'h63);
        rd8(5, v8); chk("LSR read again: OE cleared", v8, 8'h61);
        rd8(0, v8); chk("RBR keeps the older byte", v8, 8'hA1);
        rd8(5, v8); chk("LSR after the pop", v8, 8'h60);
        // Two dropped frames before LSR is read: one OE.
        wait_cts; rx_frame(8'hC1, tb, d, 1'b1, 0.0);
        rx_settle;
        rx_frame(8'hD2, tb, d, 1'b1, 0.0); rx_settle;
        rx_frame(8'hE3, tb, d, 1'b1, 0.0); rx_settle;
        bus(1'b0, 4'b1111, 1'b1, 0);                // a word read of 4-7 includes LSR: clears OE
        chk("word read of offsets 4-7 sees OE", last_rd[9:8], 2'b11);
        rd8(5, v8); chk("LSR after the word read", v8, 8'h61);
        rd8(0, v8);
        // A frame with a bad stop bit while RBR is full sets no OE (there is
        // no FE bit, and the frame is dropped either way).
        wait_cts; rx_frame(8'hF4, tb, d, 1'b0, 0.0); rx_settle;    // RBR empty: dropped, no DR
        rd8(5, v8); chk("LSR after a framing error", v8, 8'h60);
        wait_cts; rx_frame(8'h15, tb, d, 1'b1, 0.0); rx_settle;
        rx_frame(8'h26, tb, d, 1'b0, 0.0); rx_settle;
        rd8(5, v8); chk("LSR after a framing error with RBR full", v8, 8'h61);
        rd8(0, v8);
        // A frame that starts while RBR is full is dropped even if RBR is
        // popped while it is still arriving.
        wait_cts; rx_frame(8'h37, tb, d, 1'b1, 0.0); rx_settle;
        fork
            rx_frame(8'h48, tb, d, 1'b1, 0.0);
            begin #(tb * 4.0); @(posedge clk); #1; rd8(0, v8); end
        join
        rx_settle;
        chk("byte popped during the dropped frame", v8, 8'h37);
        rd8(5, v8); chk("LSR: frame lost, OE set, DR clear", v8, 8'h62);
        rd8(5, v8);
        if (rx_dropped - n != 4) fail($sformatf("overrun: %0d frames dropped, want 4", rx_dropped - n));
        // A flood from a sender ignoring CTS: 16 frames back to back. The
        // oldest byte stays in RBR, the rest are dropped, OE is set.
        n = rx_dropped;
        wait_cts; rx_frame(8'h01, tb, d, 1'b1, 0.0);
        for (i = 0; i < 16; i = i + 1) rx_frame(8'h10 + i, bit_ns(d, (urand(401) - 200) / 10000.0), d, 1'b1, 0.0);
        rx_settle;
        chk("flood: RTS# still deasserted", rts_n, 1'b1);
        rd8(5, v8); chk("flood: LSR", v8, 8'h63);
        rd8(0, v8); chk("flood: the oldest byte is kept", v8, 8'h01);
        rd8(5, v8); chk("flood: LSR after the pop", v8, 8'h60);
        if (rx_dropped - n != 16) fail($sformatf("flood: %0d frames dropped, want 16", rx_dropped - n));

        // ── Same-cycle priorities (lined up on exact edges) ─────────────────
        section("same-cycle priorities");
        set_div(2); d = 2; tb = bit_ns(d, 0.0);
        rxm_on = 1'b0;                              // checked explicitly here
        // (a) DR is set on the same edge as an RBR read with DR clear: set wins.
        fork
            begin wait_cts; rx_frame(8'h9C, tb, d, 1'b1, 0.0); end
            begin
                @(posedge clk); #1;
                while (!(dut.rx_busy && dut.rx_bit == 4'd9 && dut.rx_ph == 4'd7 && dut.tick)) begin
                    @(posedge clk); #1;
                end
                rd8(0, v8);
                p0 = last_p;
            end
        join
        rd8(5, v8); chk("(a) DR set on the edge of an RBR read: DR stays set", v8[0], 1'b1);
        rd8(0, v8); chk("(a) the byte", v8, 8'h9C);
        rd8(5, v8); chk("(a) popped", v8, 8'h60);
        // (b) OE is set on the same edge as an LSR read: the read sees it
        //     clear, and it stays set for the next read.
        wait_cts; rx_frame(8'hAB, tb, d, 1'b1, 0.0);
        idle(10);
        fork
            rx_frame(8'hBC, tb, d, 1'b1, 0.0);
            begin
                @(posedge clk); #1;
                while (!(dut.rx_busy && dut.rx_bit == 4'd9 && dut.rx_ph == 4'd7 && dut.tick)) begin
                    @(posedge clk); #1;
                end
                rd8(5, v8);
                chk("(b) LSR read on the edge OE is set: sees it clear", v8, 8'h61);
            end
        join
        rd8(5, v8); chk("(b) OE set after that read", v8, 8'h63);
        rd8(5, v8); chk("(b) then cleared", v8, 8'h61);
        rd8(0, v8); chk("(b) older byte kept", v8, 8'hAB);
        idle(40);
        // (c) RBR popped on the edge a start bit is detected: that frame
        //     started while RBR was full, so it is dropped.
        for (k = 0; k < 2; k = k + 1) begin
            set_div(k ? 4 : 1); d = cur_div(); tb = bit_ns(d, 0.0);
            wait_cts; rx_frame(8'hCD, tb, d, 1'b1, 0.0);
            idle(10);
            fork
                rx_frame(8'hDE, tb, d, 1'b1, 0.0);
                begin
                    @(posedge clk); #1;
                    while (!(!dut.rx_busy && dut.tick && !dut.rx_s)) begin @(posedge clk); #1; end
                    rd8(0, v8);
                    chk("(c) pop on the detection edge returns the older byte", v8, 8'hCD);
                end
            join
            #(tb * 2.0); idle(4);
            rd8(5, v8); chk("(c) frame dropped: OE, no DR", v8, 8'h62);
            chk("(c) RTS# asserted after the dropped frame", rts_n, 1'b0);
            rd8(5, v8);
        end
        // (d) RBR popped the edge before: the frame is kept (divisor 1, where
        //     the detection edge is two after the synchroniser's first flop
        //     sees the start bit).
        set_div(1); d = 1; tb = bit_ns(d, 0.0);
        wait_cts; rx_frame(8'hEF, tb, d, 1'b1, 0.0);
        idle(10);
        fork
            rx_frame(8'hF0, tb, d, 1'b1, 0.0);
            begin
                @(posedge clk); #1;
                while (!(!dut.rx_busy && dut.rx_sync == 2'b10)) begin @(posedge clk); #1; end
                rd8(0, v8);
                chk("(d) pop the edge before detection", v8, 8'hEF);
            end
        join
        #(tb * 2.0); idle(4);
        rd8(5, v8); chk("(d) frame kept", v8, 8'h61);
        rd8(0, v8); chk("(d) the new byte", v8, 8'hF0);
        rd8(5, v8); chk("(d) empty", v8, 8'h60);
        // (e) Only a load that selects offset 5 clears OE.
        wait_cts; rx_frame(8'h12, tb, d, 1'b1, 0.0); idle(10);
        rx_frame(8'h23, tb, d, 1'b1, 0.0); #(tb); idle(4);
        for (bi = 0; bi < 16; bi = bi + 1)
            if (!bi[1]) begin
                bus(1'b0, bi, 1'b1, 0);
                chk($sformatf("(e) load of offsets 4-7 be %b leaves OE", bi[3:0]), last_rd[9:8], 2'b11);
                if (!bi[0]) bus(1'b0, bi | 2, 1'b0, 0);   // nor do offsets 1-3 (0 would pop)
            end
        rd8(5, v8); chk("(e) LSR clears OE", v8, 8'h63);
        rd8(5, v8); chk("(e) cleared", v8, 8'h61);
        rd8(0, v8);
        idle(40);
        // (f) BI is set on the same edge as an LSR read: the read sees it
        //     clear, and it stays set for the next read (as OE in (b)).
        wait_cts;
        fork
            rx_break(15.0 * tb, d);
            begin
                @(posedge clk); #1;
                while (!(dut.rx_busy && dut.rx_bit == 4'd9 && dut.rx_ph == 4'd7 && dut.tick)) begin
                    @(posedge clk); #1;
                end
                rd8(5, v8);
                chk("(f) LSR read on the edge BI is set: sees it clear", v8, 8'h60);
            end
        join
        rd8(5, v8); chk("(f) BI and DR set after that read", v8, 8'h71);
        rd8(5, v8); chk("(f) then BI cleared", v8, 8'h61);
        rd8(0, v8); chk("(f) the break's zero byte", v8, 8'h00);
        idle(40);
        rxm_reset;
        rx_quiet_from = $realtime;
        rxm_on = 1'b1;

        // ── Which loads pop RBR ─────────────────────────────────────────────
        section("RBR pop lanes");
        set_div(2); d = 2; tb = bit_ns(d, 0.0);
        n = rx_popped;
        wait_cts; rx_frame(8'h5E, tb, d, 1'b1, 0.0); rx_settle;
        rd8(5, v8);
        for (bi = 0; bi < 16; bi = bi + 1) begin
            if (!bi[0]) bus(1'b0, bi, 1'b0, 0);     // offsets 1-3 only
            bus(1'b0, bi, 1'b1, 0);                 // offsets 4-7
        end
        wr8(3, 8'h80);
        for (bi = 0; bi < 16; bi = bi + 1) bus(1'b0, bi, 1'b0, 0);   // DLL, not RBR
        wr8(3, 8'h00);
        wr8(0, 8'h5E);                              // a THR write does not pop
        bus(1'b1, 4'b0001, 1'b0, 32'h0000_0000);
        rd8(5, v8); chk("DR still set after loads that do not select offset 0", v8[0], 1'b1);
        chk("RTS# still deasserted", rts_n, 1'b1);
        if (rx_popped != n) fail("a load that does not select offset 0 popped RBR");
        // Every load that does select offset 0 pops.
        for (bi = 1; bi < 16; bi = bi + 2) begin
            if (bi != 1) begin wait_cts; rx_frame(urand(256), tb, d, 1'b1, 0.0); rx_settle; end
            bus(1'b0, bi, 1'b0, 0);
            rd8(5, v8);
        end
        if (rx_popped != n + 8) fail($sformatf("RBR pop lanes: %0d pops, want 8", rx_popped - n));
        wait_tx_idle;

        // ── IIR: the whole truth table ──────────────────────────────────────
        section("IIR");
        set_div(8); d = 8; tb = bit_ns(d, 0.0);
        for (k = 0; k < 2; k = k + 1) begin              // DR
            if (k) begin wait_cts; rx_frame(8'h42, tb, d, 1'b1, 0.0); rx_settle; end
            for (i = 0; i < 4; i = i + 1) begin          // ETBEI, ERBFI
                wr8(1, i);
                rd8(2, v8);                              // THRE = 1
                chk($sformatf("IIR DR=%0d IER=%0d THRE=1", k, i), v8,
                    (k && i[0]) ? 8'h04 : i[1] ? 8'h02 : 8'h01);
                wr8(0, 8'h00);
                rd8(2, v8);                              // THRE = 0
                chk($sformatf("IIR DR=%0d IER=%0d THRE=0", k, i), v8, (k && i[0]) ? 8'h04 : 8'h01);
                // IER's other bits read 0 and do nothing.
                wr8(1, 8'hFC | i);
                rd8(1, v8); chk("IER keeps bits 0-1 only", v8, i);
                wait_tx_idle;
            end
            if (k) rd8(0, v8);
        end
        wr8(1, 8'h00);

        // ── Reset in the middle of everything ───────────────────────────────
        section("reset while busy");
        set_div(4); d = 4; tb = bit_ns(d, 0.0);
        wait_cts; rx_frame(8'h77, tb, d, 1'b1, 0.0); rx_settle;   // DR = 1
        wr8(1, 8'h03);
        wr8(0, 8'h81);                                            // TX busy
        fork
            rx_frame(8'h88, tb, d, 1'b1, 0.0);                    // an overrun in flight
            begin
                #(tb * 3.0);
                @(posedge clk); #1;
                wr8(3, 8'h80);
                rst = 1'b1;
                @(posedge clk); @(negedge clk);
                chk("TX in the first clock of reset", tx, 1'b1);
                chk("RTS# in the first clock of reset", rts_n, 1'b1);
            end
        join
        for (i = 0; i < 20; i = i + 1) begin @(posedge clk); #1; noise; sel = urand(2); end
        rxm_on = 1'b0;                                            // reset throws it away
        rx_break(5.0 * tb, d);                                    // traffic during reset
        rx_frame(8'h99, tb, d, 1'b1, 0.0);
        @(posedge clk); #1;
        sel = 1'b0;
        model_reset;
        rxm_on = 1'b1;
        rst = 1'b0;
        rx_quiet_from = $realtime + T;
        idle(2);
        chk("RTS# after reset", rts_n, 1'b0);
        rd8(5, v8); chk("LSR after reset", v8, 8'h60);
        rd8(2, v8); chk("IIR after reset", v8, 8'h01);
        rd8(1, v8); chk("IER after reset", v8, 8'h00);
        rd8(3, v8); chk("LCR after reset", v8, 8'h00);
        rd8(0, v8); chk("RBR after reset (DR clear)", v8, 8'h00);
        wr8(3, 8'h80); rd8(0, v8); chk("DLL after reset", v8, 8'd27); wr8(3, 8'h00);
        wr8(0, 8'h3E);                                            // at divisor 27
        fork
            begin wait_cts; rx_frame(8'h4F, bit_ns(27, 0.01), 27, 1'b1, 0.0); end
            get_byte;
        join
        wait_tx_idle;
        rx_settle;

        // ── Constrained random ──────────────────────────────────────────────
        for (k = 0; k < 2; k = k + 1) begin
            section(k ? "random, sender ignores CTS" : "random, sender honours CTS");
            set_div(1 + urand(3));
            snd_d = cur_div();
            n = rx_dropped; j = oe_seen;
            snd_cts = !k;
            snd_run = 1'b1;
            for (i = 0; i < nrand; i = i + 1) begin
                t0r = $realtime - 1.0 + T;          // when an access issued now completes
                case (urand(20))
                    0, 1, 2, 3: begin               // THR write: byte, halfword or word store
                        if (m_dlab) wr8(3, 8'h00);
                        v32 = $random(seed);
                        v32[31] = 1'b0;             // keep DLAB clear
                        case (urand(3))
                            0: bus(1'b1, 4'b0001, 1'b0, v32);
                            1: bus(1'b1, 4'b0011, 1'b0, v32);
                            2: bus(1'b1, 4'b1111, 1'b0, v32);
                        endcase
                    end
                    4, 5, 6: begin                  // poll LSR, pop if DR
                        bi = oeclr_ok(t0r) ? 4'b0010 : 4'b0001;
                        bus(1'b0, bi, 1'b1, 0);
                        t0r = $realtime - 1.0 + T;
                        if (!m_dlab && dr_val && pop_ok(t0r)) begin
                            rd8(0, v8);
                        end
                    end
                    7, 8: begin                     // IIR-driven service, as the 8250 driver
                        rd8(2, v8);
                        t0r = $realtime - 1.0 + T;
                        if (!m_dlab && dr_val && pop_ok(t0r)) rd8(0, v8);
                    end
                    9, 10, 11: begin                // any load, any lanes
                        a2i = urand(2); bi = urand(16);
                        if (!a2i && bi[0] && !m_dlab && !pop_ok(t0r)) bi[0] = 1'b0;
                        if (a2i && bi[1] && !oeclr_ok(t0r)) bi[1] = 1'b0;
                        bus(1'b0, bi, a2i, $random(seed));
                    end
                    12, 13: begin                   // any store that keeps the divisor
                        a2i = urand(2); bi = urand(16); v32 = $random(seed);
                        if (!a2i && m_dlab) begin v32[7:0] = m_dll; v32[15:8] = m_dlm; end
                        bus(1'b1, bi, a2i, v32);
                    end
                    14: begin                       // IER
                        wr8(3, 8'h00); wr8(1, urand(256));
                    end
                    15: begin                       // new divisor, with everything quiet
                        sender_stop;
                        rx_settle;
                        if (m_dlab) wr8(3, 8'h00);
                        wait_tx_idle;
                        if (dr_val) rd8(0, v8);
                        set_div(urand(10) == 0 ? 17 : urand(5));
                        snd_d = cur_div();
                        snd_run = 1'b1;
                    end
                    default: idle(urand(60));
                endcase
            end
            sender_stop;
            rx_settle;
            wr8(3, 8'h00);                          // DLAB and SBC off
            rd8(5, v8);
            if (dr_val) rd8(0, v8);
            wait_tx_idle;
            if (rx_kept != rx_popped) fail($sformatf("random: %0d frames kept, %0d popped", rx_kept, rx_popped));
            if (!k && rx_dropped != n) fail("random with CTS: a frame was dropped");
            if (k && (rx_dropped == n || oe_seen == j)) fail("random without CTS: no overrun happened");
        end

        // ── Divisor reload ──────────────────────────────────────────────────
        // A 16550 reloads its baud counter when a divisor latch is written
        // (PC16550D: "Upon loading either of the Divisor Latches, a 16-bit
        // baud counter is immediately loaded ... This prevents long counts on
        // initial load."). Lower the divisor from 1000 to 1 just after a tick,
        // when the counter holds nearly all of the old count, and let the far
        // end send at the new rate at once: the byte must arrive. Then the
        // same with a THR write: its start bit must begin one clock (a tick at
        // divisor 1) after the write (the TX model checks the whole frame).
        section("divisor reload");
        wait_tx_idle;
        for (k = 0; k < 2; k = k + 1) begin
            set_div(1000);
            while (!dut.tick) idle(1);
            idle(1);
            rxm_on = 1'b0;
            wr8(3, 8'h80); wr8(0, 8'd1); wr8(1, 8'd0); wr8(3, 8'h00);
            if (k == 0) begin
                rx_frame(8'h5A, bit_ns(1, 0.0), 1, 1'b1, 0.0);
                idle(20);
                rd8(5, v8);
                checks = checks + 1;
                if (!v8[0])
                    fail("divisor reload: a byte sent at the new rate right after DLL/DLM were lowered (1000 -> 1) was lost: the baud generator keeps counting down the old divisor before the new one takes effect");
                else begin rd8(0, v8); chk("divisor reload: byte", v8, 8'h5A); end
            end else begin
                wr8(0, 8'h01);
                p0 = last_p;
                t_rise = -1;
                for (i = 0; i < 3000 && t_rise < 0; i = i + 1) begin
                    @(negedge clk);
                    if (tx === 1'b0) t_rise = cyc;
                end
                chk("divisor reload: clocks from the THR write to its start bit", t_rise - p0, 1);
            end
            wait_tx_idle;
            idle(40);
            rxm_reset;
            rx_quiet_from = $realtime;
            rxm_on = 1'b1;
        end
        wr8(0, 8'h5A);
        wait_tx_idle;

        // ── Summary ─────────────────────────────────────────────────────────
        idle(20);
        $display("tb_uart: %0d TX frames (d=1: %0d, d=2-3: %0d, d=4-31: %0d, d>=32: %0d), %0d THR writes stalled",
                 tx_frames, tx_frames_by_div[0], tx_frames_by_div[1], tx_frames_by_div[2],
                 tx_frames_by_div[3], tx_stalls);
        $display("tb_uart: RX %0d kept, %0d dropped (overrun), %0d popped, %0d bad-stop/break (%0d breaks), %0d glitches, OE seen %0d times, BI %0d",
                 rx_kept, rx_dropped, rx_popped, rx_bad, rx_breaks, rx_glitches, oe_seen, bi_seen);
        if (rx_breaks < 10 || bi_seen < 5) fail($sformatf("too few breaks: %0d sent, BI seen %0d times", rx_breaks, bi_seen));
        if (tx_frames != tx_writes) fail($sformatf("%0d THR writes but %0d frames", tx_writes, tx_frames));
        if (errors == 0) $display("PASS tb_uart (%0d checks)", checks);
        else             $display("FAIL tb_uart: %0d errors, %0d checks", errors, checks);
        $finish;
    end

    // A hang (a checker waiting on CTS that never comes, say) shows as no
    // bus transfer completing. The longest quiet stretch in a passing run is
    // 0.48 ms (transmit timing at divisor 300; seeds 1-3), and a whole run is
    // about 10 ms, so 5 ms without a transfer stops it: a hung mutant costs
    // seconds of wall time, not the 400 ms cap's forty minutes.
    initial last_pt = 0.0;
    always begin
        #(1_000_000);
        if ($realtime - last_pt > 5_000_000.0) begin
            $display("TIMEOUT tb_uart: no bus transfer for 5 ms, in section \"%s\" (cycle %0d)",
                     cur_section, cyc);
            $finish;
        end
    end
    initial begin
        #(400_000_000);
        $display("TIMEOUT tb_uart");
        $finish;
    end
endmodule
