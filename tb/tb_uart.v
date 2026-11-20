// Unit testbench for src/uart.v, the 16550A UART (WO-49 design, WO-50 bench).
//
// The oracle is the 16550A datasheet, the Linux 8250 driver's use of it and
// the WO-49 register table -- NOT the RTL. Models:
//
//   * a register model (DLAB, IER, DLL/DLM, LCR {DLAB,SBC}, FCR FEN/trigger,
//     MCR reset 0x02, SCR) and a scoreboard predicting all 32 bits of every
//     read, and every side effect (RBR pop, OE cleared by an LSR read);
//   * an RX FIFO model (8 x {err, data}), FIFOERR, OE on a full FIFO, FE and
//     BI per head entry (they leave with the pop), IIR priority (RLS > RDA >
//     CTI > THRE), `irq` on every clock, the 1/2/4/7 trigger table, the
//     character timeout (640 ticks of 16x clock after the last push, pop or
//     clear, +-1 tick) and RTS# (rx_n <= 6, one clock after the change);
//   * a TX model: a one-deep THR model, a reference RECEIVER on the tx pin
//     (every transition on the 16x grid, every bit exactly 16 ticks, the
//     bytes in THR order, a frame per queued byte), THRE / TEMT from the
//     queue and the decoded frame, THR back-pressure bounds;
//   * a reference TRANSMITTER on RX, asynchronous to clk (any phase, baud off
//     by up to +-2 %), with flow control off (default) or honouring RTS#,
//     good frames, framing errors, breaks and glitches. The stop-bit sample
//     is predicted as a window of a few clocks; reads and writes that depend
//     on RX or TX state are held outside the windows, and the per-clock
//     checks are masked inside them;
//   * the Linux 8250 sequences as directed phases: startup (FCR 01/07/00,
//     LSR/RBR/IIR/MSR reads, the THRE and TXEN tests), set_termios (FCR 0x81,
//     DLAB divisor), the IRQ handler (IIR -> LSR -> RBR while DR|BI -> THR one
//     byte per THRE interrupt (tx-threshold), __stop_tx), polled receive;
//   * loopback (MCR.LOOP): bytes written to THR come back through RBR; the
//     tx pin and RTS# stay 1; MSR maps OUT2/OUT1/DTR/RTS.
//
// Traffic floors per seed (a miss FAILs) are met by construction in directed
// phases and counted from the scoreboard.
//
// Plusargs: +SEED=<n>, +NRAND=<n> random operations.

`timescale 1ns / 1ps

module tb_uart;
    localparam real T = 10.0;
    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;                      // posedges at 5 + 10k ns

    integer cyc = 0;                           // rising edges so far
    always @(posedge clk) cyc <= cyc + 1;
    reg rst_q = 1'b1;
    always @(posedge clk) rst_q <= rst;

    // ── DUT ─────────────────────────────────────────────────────────────────
    reg         sel = 1'b0, we = 1'b0, addr2 = 1'b0;
    reg  [3:0]  be = 4'h0;
    reg  [31:0] wdata = 32'h0;
    wire [31:0] rdata;
    wire        ready;
    reg         rx = 1'b1;
    wire        tx, rts_n, irq;

    uart dut (.clk(clk), .rst(rst), .sel(sel), .we(we), .be(be), .addr2(addr2),
              .wdata(wdata), .rdata(rdata), .ready(ready), .rx(rx), .tx(tx),
              .rts_n(rts_n), .irq(irq));

    // A second instance, only for DIV_RESET reaching both divisor latches.
    reg         sel2 = 1'b0;
    wire [31:0] rdata2;
    wire        ready2, tx2, rts2_n, irq2;
    uart #(.DIV_RESET(16'hA503)) dut2 (.clk(clk), .rst(rst), .sel(sel2), .we(we), .be(be),
              .addr2(addr2), .wdata(wdata), .rdata(rdata2), .ready(ready2), .rx(1'b1),
              .tx(tx2), .rts_n(rts2_n), .irq(irq2));

    // ── Reporting ───────────────────────────────────────────────────────────
    integer errors = 0, checks = 0;
    task automatic fail(input string m);
        begin
            errors = errors + 1;
            if (errors <= 60) $display("FAIL %s (cycle %0d, %0.1f ns)", m, cyc, $realtime);
            if (errors == 40) begin $display("FAIL tb_uart: stopping after 40 errors"); $finish; end
        end
    endtask
    task automatic chk(input string what, input [31:0] got, input [31:0] want);
        begin
            checks = checks + 1;
            if (got !== want) fail($sformatf("%s: got %h, want %h", what, got, want));
        end
    endtask
    string cur_section = "start";
    task automatic section(input string m);
        begin cur_section = m; $display("-- %s (cycle %0d)", m, cyc); end
    endtask

    integer seed = 1, seed0 = 1;
    function integer urand(input integer n);
        begin urand = $unsigned($random(seed)) % n; end
    endfunction

    // ── Register model ──────────────────────────────────────────────────────
    reg        m_dlab = 1'b0, m_sbc = 1'b0, m_sbc_old = 1'b0, sbc_pin = 1'b0;
    integer    sbc_edge = -1;
    reg [3:0]  m_ier = 4'h0;
    reg [7:0]  m_dll = 8'd34, m_dlm = 8'd0, m_scr = 8'h00;
    reg [4:0]  m_mcr = 5'b00010;
    reg        m_fen = 1'b0;
    reg [1:0]  m_rt = 2'b00;
    reg        m_oe = 1'b0;
    reg        m_ack = 1'b0;     // LSR read since the head became head: its BI/FE/RLS are acknowledged (16550A)
    reg        mon_on = 1'b1;

    function integer divisor(input [7:0] lo, input [7:0] hi);
        divisor = ({hi, lo} == 16'd0) ? 1 : {hi, lo};
    endfunction
    function integer cur_div;
        cur_div = divisor(m_dll, m_dlm);
    endfunction

    // RX FIFO model
    reg [8:0] rf [0:7];
    integer   rf_h = 0, rf_n = 0;
    function [8:0] head;
        head = (rf_n == 0) ? 9'd0 : rf[rf_h];
    endfunction
    function head_err;
        reg [8:0] h;
        begin h = head(); head_err = h[8] && !m_ack; end
    endfunction
    function integer err_cnt;
        integer i;
        begin
            err_cnt = 0;
            for (i = (m_ack ? 1 : 0); i < rf_n; i = i + 1) if (rf[(rf_h + i) % 8][8]) err_cnt = err_cnt + 1;
        end
    endfunction
    function integer trig_lvl;
        trig_lvl = !m_fen ? 1 : (m_rt == 2'd0) ? 1 : (m_rt == 2'd1) ? 2 : (m_rt == 2'd2) ? 4 : 7;
    endfunction

    // TX queue model: bytes written to THR whose frame has not started on the pin
    reg [7:0] tq [0:63];
    integer   tq_h = 0, tq_n = 0;

    // ── Tick grid (two-grid scheme: a divisor write restarts it) ─────────────
    reg       tick_known = 1'b0, tickp_known = 1'b0;
    integer   tick_ref = 0, tick_d = 1, tickp_ref = 0, tickp_d = 1, tick_switch = 0;
    function integer grid_known(input integer e);
        grid_known = (e >= tick_switch) ? tick_known : tickp_known;
    endfunction
    function integer is_tick(input integer e);
        if (e >= tick_switch) is_tick = tick_known  && e >= tick_ref  && (e - tick_ref)  % tick_d  == 0;
        else                  is_tick = tickp_known && e >= tickp_ref && (e - tickp_ref) % tickp_d == 0;
    endfunction
    task automatic tick_restart(input integer p, input integer d);
        begin
            tickp_known = tick_known; tickp_ref = tick_ref; tickp_d = tick_d;
            tick_switch = p + 1;
            tick_known = 1'b1; tick_ref = p + 1; tick_d = d;
        end
    endtask
    // first tick edge strictly after t (current grid)
    function integer tick_after(input integer t);
        integer s;
        begin
            s = t + 1;
            if (s <= tick_ref) tick_after = tick_ref;
            else tick_after = tick_ref + ((s - tick_ref + tick_d - 1) / tick_d) * tick_d;
        end
    endfunction

    // ── Character timeout model ─────────────────────────────────────────────
    // The counter restarts on a push (edge somewhere in cti_lo..cti_hi), a pop
    // or a clear, and sits at 0 while the FIFO is empty; at the 640th tick
    // after the restart the flag sets. +-1 tick of slack. 0 clear, 1 set, 2 unsure.
    integer cti_lo = 0, cti_hi = 0;
    function integer cti_cert(input integer e);
        integer a, b, d;
        begin
            if (rf_n == 0) cti_cert = 0;
            else if (!tick_known) cti_cert = 2;
            else begin
                d = tick_d;
                a = tick_after(cti_lo) + 639 * d;
                b = tick_after(cti_hi) + 639 * d;
                if (e < a - d - 1)      cti_cert = 0;
                else if (e > b + d + 1) cti_cert = 1;
                else                    cti_cert = 2;
            end
        end
    endfunction

    // ── TX pin decode state ─────────────────────────────────────────────────
    reg       tx_in = 1'b0;
    integer   tx_F = 0, tx_df = 1, tx_last_F = -1;
    reg [7:0] tx_byte;
    integer   stall_pend_p = 0;
    integer   rq_lastF = -1, rq_df = 1;
    reg       rq_in = 1'b0;
    integer   tx_frames = 0;
    function integer tx_unc_at(input integer e);
        integer lo, hi;
        begin
            tx_unc_at = 0;
            if (tq_n > 0 && !tx_in) tx_unc_at = 1;
            if (tx_last_F >= 0) begin
                lo = tx_last_F + 160 * tx_df - tx_df - 3;
                hi = tx_last_F + 160 * tx_df + tx_df + 6;
                if (e >= lo && e <= hi) tx_unc_at = 1;
            end
        end
    endfunction
    // frame on the pin certainly in progress at e (queue/idle state certain)
    function integer tx_busy_cert(input integer e);
        tx_busy_cert = tx_in && tx_last_F >= 0 && e < tx_last_F + 160 * tx_df - tx_df - 3;
    endfunction

    // ── RX pending frames ───────────────────────────────────────────────────
    integer   pf_lo [0:63];
    integer   pf_hi [0:63];
    reg [8:0] pf_ent [0:63];
    integer   pf_h = 0, pf_t = 0;
    reg       loop_unc = 1'b0;
    integer   rx_pushed = 0, rx_overrun = 0, fe_popped = 0, bi_popped = 0, rx_popped = 0;
    integer   rda_cnt [0:3];
    integer   cti_irqs = 0, rls_irqs = 0, thre_irqs = 0, bp_writes = 0, thr_writes = 0, loop_bytes = 0;
    integer   cts_oe = 0;
    reg       cts_run = 1'b0;
    initial begin rda_cnt[0] = 0; rda_cnt[1] = 0; rda_cnt[2] = 0; rda_cnt[3] = 0; end

    task automatic apply_push(input [8:0] ent, input integer lo, input integer hi);
        begin
            if (rf_n == 8) begin
                m_oe = 1'b1; rx_overrun = rx_overrun + 1;
                if (cts_run) cts_oe = cts_oe + 1;
            end else begin
                if (rf_n == 0) m_ack = 1'b0;
                rf[(rf_h + rf_n) % 8] = ent; rf_n = rf_n + 1;
                rx_pushed = rx_pushed + 1;
                cti_lo = lo; cti_hi = hi;
            end
        end
    endtask
    task automatic rx_resolve(input integer e);
        begin
            while (pf_h != pf_t && pf_hi[pf_h % 64] < e) begin
                apply_push(pf_ent[pf_h % 64], pf_lo[pf_h % 64], pf_hi[pf_h % 64]);
                pf_h = pf_h + 1;
            end
        end
    endtask
    function integer rx_win_at(input integer e);
        integer i;
        begin
            rx_win_at = 0;
            for (i = pf_h; i < pf_t; i = i + 1)
                if (e >= pf_lo[i % 64] && e <= pf_hi[i % 64]) rx_win_at = 1;
        end
    endfunction
    function integer unc_at(input integer e);
        begin
            unc_at = rx_win_at(e) || (cti_cert(e) == 2) || tx_unc_at(e) || loop_unc;
        end
    endfunction
    function integer unc_range(input integer e1, input integer e2);
        integer e;
        begin
            unc_range = 0;
            for (e = e1; e <= e2; e = e + 1) if (unc_at(e)) unc_range = 1;
        end
    endfunction

    // IIR identification, spec priority
    function [3:0] iid_at(input integer e);
        reg [8:0] h;
        begin
            h = head();
            if (m_ier[2] && (m_oe || head_err()))                iid_at = 4'h6;
            else if (m_ier[0] && rf_n >= trig_lvl())       iid_at = 4'h4;
            else if (m_ier[0] && cti_cert(e) == 1)         iid_at = 4'hC;
            else if (m_ier[1] && tq_n == 0)                iid_at = 4'h2;
            else                                           iid_at = 4'h1;
        end
    endfunction
    function rts_fn;
        rts_fn = !(m_mcr[1] && !m_mcr[4] && rf_n <= 6);
    endfunction

    // ── Monitors, every negedge ─────────────────────────────────────────────
    reg     unc_q = 1'b0, rts_exp_q = 1'b1;
    integer mon_k;
    reg     mon_exp;
    always @(negedge clk) begin
        if (rst_q) begin
            checks = checks + 2;
            if (tx !== 1'b1)    fail("TX is not idle (1) during reset");
            if (rts_n !== 1'b1) fail("RTS# is not deasserted (1) during reset");
            tx_in = 1'b0; tq_n = 0; tq_h = 0; tx_last_F = -1; stall_pend_p = 0;
            tick_known = 1'b0; tickp_known = 1'b0; tick_switch = 0; sbc_pin = 1'b0;
            unc_q = 1'b1; rts_exp_q = rts_fn();
        end else if (!rst && mon_on) begin
            rx_resolve(cyc);
            checks = checks + 1;
            if (!sel && ready !== 1'b1) fail("ready is low with sel low");
            if (tx !== 1'b0 && tx !== 1'b1) fail("TX is X");
            if (m_mcr[4]) begin
                chk("TX pin in loopback", tx, 1'b1);
            end else begin
                if (grid_known(cyc) && is_tick(cyc))
                    sbc_pin = (cyc > sbc_edge) ? m_sbc : m_sbc_old;
                if (tx_in && cyc >= tx_F + 160 * tx_df) tx_in = 1'b0;
                if (!tx_in) begin
                    if (sbc_pin) chk("TX held at 0 by SBC", tx, 1'b0);
                    else if (tx === 1'b0) begin
                        checks = checks + 1;
                        if (!grid_known(cyc)) fail("TX frame before the tick grid is known (bench)");
                        else if (!is_tick(cyc))
                            fail($sformatf("TX start bit fell off the 16x tick grid (edge %0d)", cyc));
                        if (tq_n == 0) fail("TX frame with no byte queued by a THR write");
                        else begin
                            tx_byte = tq[tq_h]; tq_h = (tq_h + 1) % 64; tq_n = tq_n - 1;
                        end
                        tx_in = 1'b1; tx_F = cyc; tx_df = cur_div(); tx_last_F = cyc;
                        tx_frames = tx_frames + 1;
                        if (stall_pend_p > 0) begin
                            checks = checks + 1;
                            if (stall_pend_p > cyc + 1)
                                fail($sformatf("THR write behind a full FIFO completed at edge %0d, after the next start bit (edge %0d): FIFO was not full", stall_pend_p, cyc));
                            stall_pend_p = 0;
                        end
                    end else chk("TX idle", tx, 1'b1);
                end
                if (tx_in) begin
                    mon_k = (cyc - tx_F) / (16 * tx_df);
                    mon_exp = (mon_k == 0) ? 1'b0 : (mon_k <= 8) ? tx_byte[mon_k - 1] : 1'b1;
                    mon_exp = mon_exp && !sbc_pin;
                    checks = checks + 1;
                    if (tx !== mon_exp)
                        fail($sformatf("TX pin %b, want %b: frame %02h, bit %0d, clock %0d of the frame (divisor %0d)",
                                       tx, mon_exp, tx_byte, mon_k, cyc - tx_F, tx_df));
                end
            end
            if (!unc_at(cyc)) begin
                chk("irq", irq, iid_at(cyc) != 4'h1);
                if (!unc_q) chk("RTS#", rts_n, rts_exp_q);
            end
            unc_q = unc_at(cyc);
            rts_exp_q = rts_fn();
        end
    end

    // ── Bus driver and scoreboard ───────────────────────────────────────────
    integer    last_p = 0, last_stall = 0;
    reg [31:0] last_rd;
    real       t_lastpos = -100.0;
    always @(posedge clk) t_lastpos = $realtime;

    task automatic noise;
        begin we = urand(2); be = urand(16); addr2 = urand(2); wdata = $random(seed); end
    endtask
    task automatic idle(input integer n);
        integer k;
        for (k = 0; k < n; k = k + 1) begin @(posedge clk); #1; noise; end
    endtask
    task automatic wait_cert;
        integer g;
        begin
            g = 0;
            idle(0);
            rx_resolve(cyc);
            while (unc_range(cyc, cyc + 3) && g < 200000) begin idle(1); rx_resolve(cyc); g = g + 1; end
            if (g >= 200000) fail("state never became certain (bench)");
        end
    endtask

    function [7:0] msr_fn;
        msr_fn = m_mcr[4] ? {m_mcr[3], m_mcr[2], m_mcr[0], m_mcr[1], 4'b0} : 8'hB0;
    endfunction
    function [7:0] lsr_fn(input integer e);
        reg [8:0] h;
        reg       temt;
        begin
            h = head();
            temt = (tq_n == 0) && !tx_busy_cert(e);
            lsr_fn = {m_fen && (err_cnt() != 0), temt, tq_n == 0, head_err() && h[7:0] == 8'h00,
                      head_err() && h[7:0] != 8'h00, 1'b0, m_oe, rf_n != 0};
        end
    endfunction

    task automatic model_read(input [3:0] b, input a2, input [31:0] got, input integer p);
        reg [31:0] exp;
        reg [3:0]  iid;
        reg [8:0]  h;
        begin
            rx_resolve(p);
            if (unc_at(p)) fail("read in an uncertain window (bench)");
            iid = iid_at(p);
            h = head();
            if (a2) exp = {m_scr, msr_fn(), lsr_fn(p), 3'b0, m_mcr};
            else    exp = {m_dlab, m_sbc, 6'b0, m_fen, m_fen, 2'b00, iid,
                           m_dlab ? m_dlm : {4'b0, m_ier}, m_dlab ? m_dll : h[7:0]};
            chk($sformatf("read word %0d (be %b) at edge %0d", a2, b, p), got, exp);
            if (!a2) begin
                if (iid == 4'h4 && m_fen) rda_cnt[m_rt] = rda_cnt[m_rt] + 1;
                if (iid == 4'hC) cti_irqs = cti_irqs + 1;
                if (iid == 4'h6) rls_irqs = rls_irqs + 1;
                if (iid == 4'h2) thre_irqs = thre_irqs + 1;
                if (b[0] && !m_dlab && rf_n > 0) begin
                    if (h[8] && h[7:0] != 8'h00) fe_popped = fe_popped + 1;
                    if (h[8] && h[7:0] == 8'h00) bi_popped = bi_popped + 1;
                    rx_popped = rx_popped + 1;
                    rf_h = (rf_h + 1) % 8; rf_n = rf_n - 1; m_ack = 1'b0;
                    cti_lo = p; cti_hi = p;
                end
            end else begin
                if (b[1]) begin m_oe = 1'b0; m_ack = 1'b1; end
            end
        end
    endtask

    task automatic fcr_w(input [7:0] f);
        reg chg;
        begin
            chg = (f[0] != m_fen);
            if (f[1] || chg) begin rf_n = 0; rf_h = 0; m_ack = 1'b0; end
            if (f[2] || chg) begin tq_n = 0; tq_h = 0; end
            m_fen = f[0]; m_rt = f[7:6];
        end
    endtask

    task automatic model_write(input [3:0] b, input a2, input [31:0] wd, input integer p_first,
                               input integer p, input integer nreq);
        reg dl, rst_div;
        integer lb;
        begin
            rx_resolve(p);
            dl = m_dlab; rst_div = 1'b0;
            if (!a2) begin
                if (b[0]) begin
                    if (dl) begin m_dll = wd[7:0]; rst_div = 1'b1; end
                    else begin
                        // THR: ready must have been high on the first edge unless the THR was full
                        checks = checks + 1;
                        if (m_mcr[4]) begin
                        end else if (nreq == 0) begin
                            if (p != p_first) fail($sformatf("THR write stalled (edge %0d, asked %0d) with nothing queued: ready must stay high with THR empty", p, p_first));
                        end else if (rq_in) begin
                            // nreq-1 characters wait behind the one in THR; THR is taken once the frames ahead end
                            lb = rq_lastF + 160 * rq_df * nreq - rq_df - 3;
                            if (rq_lastF < 0 || p < lb)
                                fail($sformatf("THR write accepted at edge %0d with %0d queued while the frame in the shifter ends at edge %0d: ready must be low", p, nreq, rq_lastF + 160 * rq_df));
                            if (nreq == 1) stall_pend_p = p;
                        end
                        if (p > p_first) bp_writes = bp_writes + 1;
                        thr_writes = thr_writes + 1;
                        tq[(tq_h + tq_n) % 64] = wd[7:0]; tq_n = tq_n + 1;
                    end
                end
                if (b[1]) begin
                    if (dl) begin m_dlm = wd[15:8]; rst_div = 1'b1; end
                    else m_ier = wd[11:8];
                end
                if (b[2]) fcr_w(wd[23:16]);
                if (b[3]) begin
                    m_sbc_old = m_sbc; sbc_edge = p;
                    m_dlab = wd[31]; m_sbc = wd[30];
                end
            end else begin
                if (b[0]) m_mcr = wd[4:0];
                if (b[3]) m_scr = wd[31:24];
            end
            if (rst_div) tick_restart(p, cur_div());
        end
    endtask

    integer chk_lcr_stall = 0;
    reg [7:0] lcr_before;
    task automatic bus(input w, input [3:0] b, input a2, input [31:0] wd);
        integer n, p_first, nreq;
        reg     thr;
        begin
            thr = w && b[0] && !a2 && !m_dlab;
            if (!thr) wait_cert;
            if ($realtime != t_lastpos + 1.0) begin @(posedge clk); #1; end
            rx_resolve(cyc);
            sel = 1'b1; we = w; be = b; addr2 = a2; wdata = wd;
            p_first = cyc + 1;
            nreq = tq_n; rq_lastF = tx_last_F; rq_df = tx_df; rq_in = tx_in;
            lcr_before = {m_dlab, m_sbc, 6'b0};
            #1;
            n = 0;
            while (ready !== 1'b1 && n <= 200000) begin
                if (ready !== 1'b0) fail("ready is X");
                if (chk_lcr_stall && !a2) chk("LCR unchanged while the store waits for ready", rdata[31:24], lcr_before);
                @(posedge clk); #1;
                n = n + 1;
            end
            if (n > 200000) fail("ready never rose");
            last_rd = rdata;
            @(posedge clk);
            #1;
            last_p = cyc; last_stall = n;
            sel = 1'b0;
            noise;
            if (w) model_write(b, a2, wd, p_first, last_p, nreq);
            else begin
                checks = checks + 1;
                if (last_p != p_first) fail("read stalled");
                model_read(b, a2, last_rd, last_p);
            end
        end
    endtask

    task automatic wr8(input integer off, input [7:0] v);
        bus(1'b1, 4'b0001 << (off % 4), off >= 4, {4{v}});
    endtask
    task automatic rd8(input integer off, output [7:0] v);
        begin
            bus(1'b0, 4'b0001 << (off % 4), off >= 4, $random(seed));
            v = last_rd >> (8 * (off % 4));
        end
    endtask
    reg [7:0] v8, a8;
    task automatic wr_thr(input [7:0] v);
        begin wr8(0, v); end
    endtask

    // ── Waiting ─────────────────────────────────────────────────────────────
    reg     snd_busy = 1'b0, snd_go = 1'b0, snd_abort = 1'b0;
    task automatic wait_tx_drain;
        integer g;
        begin
            g = 0;
            while ((tq_n > 0 || tx_in || (tx_last_F >= 0 && cyc <= tx_last_F + 160 * tx_df + tx_df + 8)) && g < 2000000) begin
                idle(1); g = g + 1;
            end
            if (g >= 2000000) fail("TX never drained");
        end
    endtask
    task automatic wait_quiet;
        integer g;
        begin
            g = 0;
            idle(2);
            while ((snd_busy || pf_h != pf_t || rx_win_at(cyc) || rx_win_at(cyc + 3)) && g < 4000000) begin
                idle(1); rx_resolve(cyc); g = g + 1;
            end
            if (g >= 4000000) fail("RX never quiet (bench)");
            idle(4);
        end
    endtask
    // preserve FEN, clear both FIFOs
    task automatic clear_fifos;
        begin wr8(2, 8'h06 | {m_rt, 5'b0} | m_fen); end
    endtask
    task automatic set_div(input integer v);
        begin
            wait_quiet; wait_tx_drain;
            clear_fifos;
            wr8(3, 8'h80); wr8(0, v[7:0]); wr8(1, v[15:8]); wr8(3, 8'h00);
            idle(2);
        end
    endtask
    task automatic model_reset;
        begin
            m_dlab = 0; m_sbc = 0; m_sbc_old = 0; sbc_edge = -1; m_ier = 0; m_dll = 34; m_dlm = 0;
            m_scr = 0; m_mcr = 5'b00010; m_fen = 0; m_rt = 0; m_oe = 0;
            rf_h = 0; rf_n = 0; m_ack = 0; tq_h = 0; tq_n = 0; pf_h = pf_t; loop_unc = 0;
            tx_in = 0; tx_last_F = -1; stall_pend_p = 0; sbc_pin = 0;
        end
    endtask

    // ── Reference transmitter on RX ─────────────────────────────────────────
    // kinds: 0 good, 1 framing error, 2 break, 3 glitch
    integer snd_n = 0, snd_pfe = 0, snd_pbrk = 0, snd_pgl = 0, snd_gap = 0, snd_dd = 1;
    reg     snd_cts = 1'b0;
    reg [7:0] snd_fixed;
    reg       snd_use_fixed = 1'b0;
    integer snd_sent = 0, snd_kinds [0:3];
    initial begin snd_kinds[0] = 0; snd_kinds[1] = 0; snd_kinds[2] = 0; snd_kinds[3] = 0; end

    function integer edges_at(input real t);       // posedges at or before t
        edges_at = $rtoi((t - 5.0) / 10.0) + 1;
    endfunction
    task automatic reg_frame(input [8:0] ent, input integer e0, input integer d);
        begin
            pf_lo[pf_t % 64] = e0 + 152 * d + 1;
            pf_hi[pf_t % 64] = e0 + 153 * d + 3;
            pf_ent[pf_t % 64] = ent;
            pf_t = pf_t + 1;
        end
    endtask

    always begin : sender
        integer   i, k, d, e0, kind, r;
        real      tb, t0, e, gap, f;
        reg [7:0] data;
        wait (snd_go);
        snd_go = 1'b0;
        d = snd_dd;
        for (i = 0; i < snd_n && !snd_abort; i = i + 1) begin
            e  = (urand(4001) - 2000) / 100000.0;
            tb = 16.0 * d * T * (1.0 + e);
            r = urand(100);
            kind = (r < snd_pgl) ? 3 : (r < snd_pgl + snd_pbrk) ? 2 : (r < snd_pgl + snd_pbrk + snd_pfe) ? 1 : 0;
            data = snd_use_fixed ? snd_fixed : urand(256);
            if (kind == 1 && data == 8'h00) data = 8'h01 + urand(255);
            if (snd_cts) begin
                while (rts_n !== 1'b0 && !snd_abort) @(negedge clk);
                #(urand(3000) / 100.0);
            end
            gap = (snd_gap == 0) ? 0.0 : urand(snd_gap * 4 + 1) * tb / 4.0;
            if (gap > 0.0) #(gap);
            t0 = $realtime;
            f = t0 - 5.0 - 10.0 * $floor((t0 - 5.0) / 10.0);
            if (f < 0.3 || f > 9.7) begin #0.5; t0 = $realtime; end
            e0 = edges_at(t0);
            snd_kinds[kind] = snd_kinds[kind] + 1;
            if (kind == 3) begin
                rx = 1'b0;
                #(2.0 + urand(28 * d));
                rx = 1'b1;
                #(20.0 * d * T);
            end else if (kind == 2) begin
                reg_frame({1'b1, 8'h00}, e0, d);
                rx = 1'b0;
                #(tb * (10.7 + urand(100) / 10.0));
                rx = 1'b1;
                #(tb * 2.0);
            end else begin
                reg_frame(kind == 1 ? {1'b1, data} : {1'b0, data}, e0, d);
                rx = 1'b0; #(tb);
                for (k = 0; k < 8; k = k + 1) begin rx = data[k]; #(tb); end
                rx = (kind == 0); #(tb);
                rx = 1'b1;
                if (kind == 1) #(tb * 2.0);
            end
            snd_sent = snd_sent + 1;
        end
        rx = 1'b1;
        snd_busy = 1'b0;
    end
    task automatic snd_start(input integer n, input integer pfe, input integer pbrk, input integer pgl,
                             input integer gap, input cts);
        begin
            snd_n = n; snd_pfe = pfe; snd_pbrk = pbrk; snd_pgl = pgl; snd_gap = gap; snd_cts = cts;
            snd_dd = cur_div(); snd_abort = 1'b0; snd_busy = 1'b1; snd_go = 1'b1;
            cts_run = cts;
            @(posedge clk); #1;
        end
    endtask

    // ── Linux 8250 helpers ──────────────────────────────────────────────────
    integer tx_left = 0, tx_seq = 0;
    task automatic rx_drain_polled;
        reg [7:0] lsr, v;
        integer   k;
        begin
            rd8(5, lsr);
            k = 0;
            while ((lsr[0] || lsr[4]) && k < 300) begin rd8(0, v); rd8(5, lsr); k = k + 1; end
        end
    endtask
    // the serial8250_handle_irq loop
    task automatic linux_irq_handler;
        reg [7:0] iir, lsr, v;
        integer   g, n, k;
        begin
            g = 0;
            rd8(2, iir);
            while (!iir[0] && g < 400) begin
                g = g + 1;
                rd8(5, lsr);
                k = 0;
                while ((lsr[0] || lsr[4]) && k < 300) begin rd8(0, v); rd8(5, lsr); k = k + 1; end
                if (lsr[5] && m_ier[1]) begin
                    if (tx_left > 0) begin
                        n = 1;                               // tx-threshold: one byte per THRE interrupt
                        repeat (n) begin wr_thr(8'h40 + tx_seq % 64); tx_seq = tx_seq + 1; end
                        tx_left = tx_left - n;
                    end else wr8(1, {4'b0, m_ier} & 8'h0D);      // __stop_tx
                end
                rd8(2, iir);
            end
        end
    endtask

    // random bus operation
    task automatic rand_op;
        integer r;
        reg [3:0]  bb;
        reg [31:0] wd;
        begin
            r = urand(100);
            if (r < 20)      begin rd8(2, v8); end
            else if (r < 34) begin rd8(5, v8); end
            else if (r < 48) begin rd8(0, v8); end
            else if (r < 60) begin wr_thr(urand(256)); end
            else if (r < 66) begin wr8(1, urand(16)); end
            else if (r < 71) begin
                case (urand(6))
                    0: wr8(2, 8'h01); 1: wr8(2, 8'h41); 2: wr8(2, 8'h81); 3: wr8(2, 8'hC1);
                    4: wr8(2, 8'h87 & 8'hCF); default: wr8(2, urand(2) ? 8'h00 : 8'h03 | (urand(4) << 6));
                endcase
            end
            else if (r < 75) begin wr8(4, urand(16)); end
            else if (r < 78) begin wr8(7, urand(256)); end
            else if (r < 80) begin wr8(3, urand(64)); end
            else if (r < 86) begin rd8(urand(8), v8); end
            else if (r < 90) begin
                bb = urand(15) + 1;
                bus(1'b0, bb, urand(2), $random(seed));
            end
            else if (r < 93) begin
                // multi-lane store: never FCR together with THR; DLAB stays 0, SBC 0, no LOOP
                bb = urand(15) + 1; wd = $random(seed);
                wd[31:30] = 2'b00; wd[4] = 1'b0;
                if (bb[0] && bb[2]) bb[2] = 1'b0;
                bus(1'b1, bb, urand(2), wd);
            end
            else idle(urand(40));
        end
    endtask

    // ── Tests ───────────────────────────────────────────────────────────────
    integer i, j, k, n, t, nrand, dd;
    integer divs [0:5];
    reg [31:0] v32;
    reg [3:0]  mm;

    initial begin
        if ($value$plusargs("SEED=%d", seed)) ;
        seed0 = seed;
        if (!$value$plusargs("NRAND=%d", nrand)) nrand = 3000;
        $display("tb_uart seed %0d", seed);
        divs[0] = 1; divs[1] = 2; divs[2] = 3; divs[3] = 5; divs[4] = 1; divs[5] = 2;
        model_reset;
        noise;

        // ── Reset ──────────────────────────────────────────────────────────
        section("reset");
        for (i = 0; i < 20; i = i + 1) begin
            @(posedge clk); #1; noise; sel = urand(2); rx = urand(2);
        end
        sel = 1'b0; rx = 1'b1;
        @(posedge clk); #1;
        rst = 1'b0;
        idle(2);
        chk("RTS# asserted after reset (MCR.RTS = 1, FIFO empty)", rts_n, 1'b0);
        chk("irq low after reset", irq, 1'b0);
        rd8(0, v8); chk("reset RBR", v8, 8'h00);
        rd8(1, v8); chk("reset IER", v8, 8'h00);
        rd8(2, v8); chk("reset IIR", v8, 8'h01);
        rd8(3, v8); chk("reset LCR", v8, 8'h00);
        rd8(4, v8); chk("reset MCR", v8, 8'h02);
        rd8(5, v8); chk("reset LSR", v8, 8'h60);
        rd8(6, v8); chk("reset MSR", v8, 8'hB0);
        rd8(7, v8); chk("reset SCR", v8, 8'h00);
        chk("DIV_RESET DLL (instance 2)", dut2.dll, 8'h03);
        chk("DIV_RESET DLM (instance 2)", dut2.dlm, 8'hA5);
        wr8(3, 8'h80);
        rd8(0, v8); chk("reset DLL", v8, 8'd34);
        rd8(1, v8); chk("reset DLM", v8, 8'h00);
        wr8(3, 8'h00);

        // ── Registers ──────────────────────────────────────────────────────
        section("registers");
        set_div(2);
        for (i = 0; i < 4; i = i + 1) begin
            wr8(1, 8'h5A >> i); rd8(1, v8);                   // scoreboard checks the 4-bit mask
            wr8(7, 8'hA5 ^ (8'h11 * i)); rd8(7, v8);
            wr8(4, 8'h1F >> i); rd8(4, v8);                   // incl. LOOP...
            wr8(4, 8'h0A);                                    // ...then out of it
        end
        wr8(1, 8'h00); wr8(4, 8'h02);
        wr8(3, 8'h40); idle(20); rd8(3, v8); chk("LCR SBC reads back", v8, 8'h40);
        wr8(3, 8'h00); idle(20);
        wr8(3, 8'h3F); rd8(3, v8); chk("LCR frame bits not stored", v8, 8'h00);
        for (i = 0; i < 40; i = i + 1) bus(1'b0, urand(15) + 1, urand(2), $random(seed));

        // ── Linux 8250 startup ─────────────────────────────────────────────
        section("linux startup");
        wr8(2, 8'h01); wr8(2, 8'h07); wr8(2, 8'h00);
        rd8(5, v8); chk("startup LSR", v8, 8'h60);
        rd8(0, v8); chk("startup RBR (empty reads 0)", v8, 8'h00);
        rd8(2, v8); chk("startup IIR", v8, 8'h01);
        rd8(6, v8); chk("startup MSR", v8, 8'hB0);
        // THRE test
        wr8(1, 8'h02); rd8(2, v8); chk("THRE test IIR 1", v8, 8'h02);
        chk("irq on THRE", irq, 1'b1);
        rd8(2, v8); chk("THRE test IIR 2 (level)", v8, 8'h02);
        wr8(1, 8'h00); rd8(2, v8); chk("THRE test IIR cleared", v8, 8'h01);
        wr8(1, 8'h02); rd8(2, v8); chk("THRE test IIR 3", v8, 8'h02);
        // TXEN test
        rd8(5, v8); chk("TXEN test LSR", v8[6], 1'b1);
        rd8(2, v8); chk("TXEN test IIR", v8, 8'h02);
        wr8(1, 8'h00);
        wr8(4, 8'h0B);                                        // OUT2 | DTR | RTS
        rd8(4, v8); chk("MCR", v8, 8'h0B);
        // set_termios
        wr8(2, 8'h81);
        rd8(2, v8); chk("IIR after FCR 0x81", v8, 8'hC1);
        wr8(3, 8'h83); wr8(0, 8'h02); wr8(1, 8'h00); wr8(3, 8'h03);
        rd8(3, v8); chk("LCR after 8N1", v8, 8'h00);
        wr8(1, 8'h02); rd8(2, v8); chk("FEN THRE IIR", v8, 8'hC2);
        wr8(1, 8'h00);

        // ── TX ─────────────────────────────────────────────────────────────
        section("tx");
        for (k = 0; k < 4; k = k + 1) begin
            dd = divs[k];
            set_div(dd);
            wr_thr(8'hA5);
            rd8(5, v8);
            wait_tx_drain;
            rd8(5, v8); chk("TX drained LSR", v8, 8'h60);
            // 5 back-to-back writes: the fifth stalls
            for (i = 0; i < 6; i = i + 1) wr_thr(urand(256));
            wait_tx_drain;
            // word store THR + LCR while full: LCR lands with THR
            for (i = 0; i < 5; i = i + 1) wr_thr(i);
            chk_lcr_stall = 1;
            bus(1'b1, 4'b1001, 1'b0, {8'h80, 8'h00, 8'h00, 8'h77});     // THR 77, LCR DLAB=1 (together)
            chk_lcr_stall = 0;
            wr8(3, 8'h00);
            wait_tx_drain;
        end
        // FCR[2]: clear THR, the shifter finishes
        set_div(2);
        for (i = 0; i < 2; i = i + 1) wr_thr(8'h10 + i);
        idle(40);
        wr8(2, 8'h85);
        wait_tx_drain;
        rd8(5, v8);
        for (i = 0; i < 2; i = i + 1) wr_thr(8'h20 + i);
        wr8(2, 8'h00);                                       // FEN change clears THR too
        wait_tx_drain;
        wr8(2, 8'h81);
        // SBC at idle: pin held 0 from the next tick
        wr8(3, 8'h40); idle(20 * 2); wr8(3, 8'h00); idle(20 * 2);

        // ── RX, divisor sweep, FEN = 0 buffers ─────────────────────────────
        section("rx basic");
        for (k = 0; k < 6; k = k + 1) begin
            dd = divs[k];
            set_div(dd);
            wr8(2, 8'h00);                          // FEN = 0: trigger 1, the FIFO still buffers
            snd_use_fixed = 1'b0;
            snd_start(5, 20, 10, 0, 0, 1'b0);
            wait_quiet;
            rd8(5, v8); rd8(2, v8);
            rx_drain_polled;
            wr8(2, 8'h81);
        end
        // glitches and gaps
        set_div(3);
        snd_start(30, 15, 5, 20, 3, 1'b0); wait_quiet; rx_drain_polled;

        // ── RDA at every trigger level, CTI, boundary ──────────────────────
        section("rda and cti");
        set_div(1);
        for (t = 0; t < 4; t = t + 1) begin
            n = (t == 0) ? 1 : (t == 1) ? 2 : (t == 2) ? 4 : 7;
            wr8(1, 8'h01);
            for (j = 0; j < 12; j = j + 1) begin
                wr8(2, 8'h01 | (t << 6) | 8'h06);
                // n-1 characters: no RDA yet
                if (n > 1) begin
                    snd_start(n - 1, 0, 0, 0, 0, 1'b0); wait_quiet;
                    rd8(2, v8); chk("IIR just below the trigger", v8[3:0], 4'h1);
                    snd_start(1, 0, 0, 0, 0, 1'b0); wait_quiet;
                end else begin
                    snd_start(1, 0, 0, 0, 0, 1'b0); wait_quiet;
                end
                rd8(2, v8); chk("IIR at the trigger", v8, 8'hC4);
                chk("irq at the trigger", irq, 1'b1);
                rd8(0, v8);
                rx_drain_polled;
            end
        end
        // character timeout: fewer than the trigger, then quiet
        wr8(1, 8'h01);
        for (j = 0; j < 14; j = j + 1) begin
            wr8(2, 8'h87 | 8'h06);                  // trigger 4
            snd_start(1 + j % 3, 0, 0, 0, 0, 1'b0); wait_quiet;
            // wait until the window is over, polling IIR through the uncertain stretch
            k = 0;
            rd8(2, v8);
            while (v8[3:0] == 4'h1 && k < 2000) begin idle(5); rd8(2, v8); k = k + 1; end
            chk("character timeout IIR", v8, 8'hCC);
            rd8(0, v8);                             // a pop restarts the timeout...
            rd8(2, v8);
            if (rf_n > 0) chk("CTI cleared by a pop", v8[3:0], 4'h1);
            rx_drain_polled;
        end
        wr8(1, 8'h00);

        // ── OE, FE, BI, FIFOERR, RLS ───────────────────────────────────────
        section("errors");
        set_div(1);
        for (j = 0; j < 7; j = j + 1) begin
            wr8(2, 8'hC7 & 8'hC7);
            wr8(1, (j % 2) ? 8'h04 : 8'h00);        // ELSI
            snd_start(11 + j, 0, 0, 0, 0, 1'b0); wait_quiet;
            rd8(5, v8); chk("LSR after overrun", v8[1:0], 2'b11);
            rd8(2, v8);
            rd8(5, v8); chk("OE cleared by the LSR read", v8[1], 1'b0);
            rx_drain_polled;
        end
        for (j = 0; j < 8; j = j + 1) begin
            wr8(2, 8'h81); wr8(1, 8'h05);
            snd_start(7, 30, 30, 0, 0, 1'b0); wait_quiet;
            rd8(2, v8);
            for (k = 0; k < 7; k = k + 1) begin rd8(5, v8); rd8(2, v8); rd8(0, v8); end
            rd8(5, v8);
            wr8(1, 8'h00);
        end
        // LSR for an empty-FIFO break: BI + FIFOERR
        wr8(2, 8'h87); wr8(1, 8'h04);
        snd_start(1, 0, 100, 0, 0, 1'b0); wait_quiet;
        rd8(2, v8); chk("IIR RLS", v8, 8'hC6);
        rd8(5, v8); chk("LSR for a break into an empty FIFO", v8, 8'hF1);
        rd8(2, v8); chk("ISR: RLS interrupt gone after the LSR read (S1)", v8[3:0] == 4'h6, 1'b0);
        rd8(5, v8); chk("ISR: BI cleared by the LSR read (S1)", v8[4], 1'b0);
        rd8(0, v8);
        rd8(5, v8); chk("LSR after the break is popped", v8, 8'h60);
        wr8(1, 8'h00);

        // ── RTS# ───────────────────────────────────────────────────────────
        section("rts");
        wr8(2, 8'hC7); wr8(1, 8'h00);
        for (j = 0; j < 3; j = j + 1) begin
            snd_start(8, 0, 0, 0, 0, 1'b0); wait_quiet;           // fills the FIFO: rts_n tracks rx_n
            for (k = 0; k < 4; k = k + 1) begin rd8(0, v8); end   // 4 left
            wr8(4, 8'h00); wr8(4, 8'h02);                         // RTS off/on
            rx_drain_polled;
        end
        // flow control honoured: no overrun
        wr8(2, 8'h81);
        snd_start(60, 5, 0, 0, 1, 1'b1);
        while (snd_busy) begin
            idle(urand(400)); rd8(5, v8);
            if (urand(2)) begin for (k = 0; k < urand(6); k = k + 1) rd8(0, v8); end
        end
        wait_quiet; rx_drain_polled;
        cts_run = 1'b0;
        chk("no overrun while the sender honours RTS#", cts_oe, 0);

        // ── Linux IRQ-driven loop: rx traffic, tx 60 chars, tx stop ────────
        section("linux irq loop");
        for (k = 0; k < 3; k = k + 1) begin
            set_div(divs[k]);
            wr8(2, 8'h81); wr8(1, 8'h07); wr8(4, 8'h0B);
            tx_left = 60;
            snd_start(40, 8, 3, 0, 1, 1'b0);
            n = 0;
            while ((snd_busy || tx_left > 0 || irq || rf_n > 0) && n < 100000) begin
                if (irq) linux_irq_handler; else idle(7);
                n = n + 1;
            end
            wr8(1, 8'h00);
            wait_quiet; wait_tx_drain; rx_drain_polled;
        end

        // ── Back-pressure floor ────────────────────────────────────────────
        section("back-pressure");
        set_div(1);
        for (j = 0; j < 20; j = j + 1) begin
            for (i = 0; i < 8; i = i + 1) wr_thr(urand(256));
            if (j % 4 == 3) wait_tx_drain;
        end
        wait_tx_drain;

        // ── Loopback ───────────────────────────────────────────────────────
        section("loopback");
        set_div(1);
        wr8(2, 8'h81); wr8(1, 8'h00);
        for (j = 0; j < 10; j = j + 1) begin
            wait_tx_drain; idle(4);
            wr8(4, 8'h10 | (j * 3 & 8'h0F));
            rd8(6, v8);
            mm = (j * 3) & 15;
            chk("loopback MSR", v8, {mm[3], mm[2], mm[0], mm[1], 4'b0});
            idle(4);
            n = (j == 0) ? 3 : 8;
            loop_unc = 1'b1;
            for (i = 0; i < n; i = i + 1) wr_thr(8'h30 + i + j);
            idle((n + 1) * 160 + 200);
            tq_n = 0; tq_h = 0; tx_in = 1'b0; tx_last_F = -1;
            for (i = 0; i < n; i = i + 1) apply_push({1'b0, 8'h30 + i[7:0] + j[7:0]}, cyc - 200, cyc);
            loop_bytes = loop_bytes + n;
            loop_unc = 1'b0;
            for (i = 0; i < n; i = i + 1) begin rd8(0, v8); chk("loopback byte", v8, 8'h30 + i + j); end
            wr8(4, 8'h02);
        end
        // break in loopback: SBC while LOOP
        wr8(4, 8'h12);
        wait_tx_drain;
        wr8(3, 8'h40);
        idle(14 * 16);
        wr8(3, 8'h00);
        idle(4 * 16);
        loop_unc = 1'b1;
        apply_push({1'b1, 8'h00}, cyc - 100, cyc);
        loop_unc = 1'b0;
        wr8(4, 8'h02);
        wr8(1, 8'h04);
        rd8(2, v8); chk("loopback break IIR", v8, 8'hC6);
        rd8(5, v8); chk("loopback break LSR", v8, 8'hF1);
        rd8(2, v8); chk("loopback ISR: RLS gone after the LSR read (S1)", v8[3:0] == 4'h6, 1'b0);
        rd8(0, v8);
        wr8(1, 8'h00);

        // ── Reset with a frame in flight ───────────────────────────────────
        section("reset with a frame in flight");
        set_div(2);
        for (i = 0; i < 3; i = i + 1) wr_thr(8'h55 + i);
        idle(100);
        rst = 1'b1; model_reset;
        for (i = 0; i < 10; i = i + 1) begin @(posedge clk); #1; noise; end
        rst = 1'b0;
        idle(3);
        rd8(2, v8); chk("IIR after the second reset", v8, 8'h01);
        rd8(5, v8); chk("LSR after the second reset", v8, 8'h60);
        rd8(4, v8); chk("MCR after the second reset", v8, 8'h02);

        // ── Constrained random ─────────────────────────────────────────────
        section("random");
        for (k = 0; k < 6; k = k + 1) begin
            set_div(divs[k % 4]);
            wr8(2, 8'h81);
            for (i = 0; i < nrand / 6; i = i + 1) begin
                if (!snd_busy && urand(40) == 0)
                    snd_start(1 + urand(30), urand(15), urand(6), urand(10), urand(2) * urand(3), urand(2));
                rand_op;
            end
            snd_abort = 1'b1;
            wait_quiet; cts_run = 1'b0;
            snd_abort = 1'b0;
            wait_tx_drain;
            wr8(1, 8'h00);
            rx_drain_polled;
        end

        // ── Floors ─────────────────────────────────────────────────────────
        section("floors");
        idle(20);
        $display("tb_uart: rx pushed %0d popped %0d overruns %0d FE %0d BI %0d | CTI %0d RLS %0d THRE %0d | RDA %0d/%0d/%0d/%0d | bp writes %0d tx frames %0d loop %0d",
                 rx_pushed, rx_popped, rx_overrun, fe_popped, bi_popped, cti_irqs, rls_irqs, thre_irqs,
                 rda_cnt[0], rda_cnt[1], rda_cnt[2], rda_cnt[3], bp_writes, tx_frames, loop_bytes);
        if (rx_popped < 300)    fail($sformatf("floor: %0d characters through the FIFO (< 300)", rx_popped));
        if (rx_overrun < 5)     fail($sformatf("floor: %0d overruns (< 5)", rx_overrun));
        if (cti_irqs < 10)      fail($sformatf("floor: %0d CTI interrupts (< 10)", cti_irqs));
        for (i = 0; i < 4; i = i + 1)
            if (rda_cnt[i] < 10) fail($sformatf("floor: %0d RDA interrupts at trigger %0d (< 10)", rda_cnt[i], i));
        if (fe_popped < 5)      fail($sformatf("floor: %0d FE entries popped (< 5)", fe_popped));
        if (bi_popped < 5)      fail($sformatf("floor: %0d BI entries popped (< 5)", bi_popped));
        if (bp_writes < 50)     fail($sformatf("floor: %0d back-pressured THR writes (< 50)", bp_writes));
        if (loop_bytes < 64)    fail($sformatf("floor: %0d loopback bytes (< 64)", loop_bytes));
        if (errors == 0) $display("PASS %0d checks seed %0d", checks, seed0);
        else             $display("FAIL tb_uart: %0d errors, %0d checks, seed %0d", errors, checks, seed0);
        $finish;
    end

    // A hang shows as no sim progress; cap the run.
    initial begin
        #(900_000_000);
        $display("TIMEOUT tb_uart in section \"%s\" (cycle %0d)", cur_section, cyc);
        $finish;
    end
endmodule
