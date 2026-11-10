// glitch_mon: pin glitch monitor for tb/tb_tt_um.v on an SDF-annotated gate-level netlist (WO-34, TT01).
//
// A second top (-s tb_tt_um -s glitch_mon). It reads tb_tt_um.clk, .rst_n, .uo_out and .uio_oe by
// hierarchical reference (simulation only) and drives nothing. The pins are watched change by change
// (an always @ on the 16 bits), never sampled, so a pulse between two clock edges is seen.
//
// Spec, not RTL (tb/tb_tt_um.v header contract): from RST_CHK_NS after rst_n falls until the second clock
// edge after it rises, with or without a clock, uio_oe is 0 and uo_out is 0xB9; the SoC drives SCK and the
// chip selects on the third edge. The design also keeps the pins until e3.
//
// For each fall of rst_n (event k) it records t_f, the clock edges seen while rst_n is low, t_r, and e1..e3
// (the first three posedges of clk after rst_n rose). B = {uo_out[7:0], uio_oe[7:0]}.
//
//   M1  [t_f + RST_CHK_NS, e3 + T)   any X or Z on a B bit
//   M0  [t_f, t_f + RST_CHK_NS)      more than one change of a bit (the entry into reset is monotonic)
//   M2  [t_f + RST_CHK_NS, e3)       any change of a B bit
//   M3  [e3, e3 + T)                 more than one change of a bit; uo_out changing at all, except RTS#
//                                    (uo_out[5]) falling once (the UART asserts it out of reset: measured, WO-34)
//
// Output, one line per event (violations first, up to 20, as `<rule> <bit> <time> <old>-><new>`):
//   GLITCH-MON event <k> clk_in_reset=<n> t_r=<ns> e1=<ns> e2=<ns> e3=<ns> d_oe3=<ns>: PASS|FAIL
// and in the final block `GLITCH-MON PASS <n> events` or `GLITCH-MON FAIL ...`.
// d_oe3 is the time from e3 to uio_oe[3] rising. Vacuity guards (each a FAIL): fewer than 3 events, an
// event that never reached e3 + T, d_oe3 <= 0.05 ns (or no rise at all).
//
// Defines as in tb_tt_um.v: TCLK_NS (the clock period, T), RST_CHK_NS.
`timescale 1ns / 1ps
`ifndef TCLK_NS
`define TCLK_NS 10.0
`endif
`ifndef RST_CHK_NS
`define RST_CHK_NS 2
`endif
module glitch_mon;
    localparam real T   = `TCLK_NS;
    localparam real RST = 1.0 * `RST_CHK_NS;
    localparam integer MAXV = 20;

    wire [15:0] B = {tb_tt_um.uo_out, tb_tt_um.uio_oe};   // B[15:8] uo_out, B[7:0] uio_oe
    reg  [15:0] pb = 16'bx;

    integer k = 0, nfail = 0, nclosed = 0;
    reg     open = 1'b0, e3_seen = 1'b0, rose = 1'b0;
    integer nedge = 0, clk_in_reset = 0, nviol = 0;
    real    t_f, t_r, e1, e2, e3, d_oe3;
    integer cnt0 [0:15];
    integer cnt3 [0:15];
    string  vbuf;
    integer i;
    event   e3_ev;

    function automatic string bname(input integer b);
        string r;
        begin
            if (b >= 8) r = $sformatf("uo_out[%0d]", b - 8);
            else        r = $sformatf("uio_oe[%0d]", b);
            return r;
        end
    endfunction

    task automatic viol(input string rule, input integer b, input real t, input reg o, input reg n);
        begin
            nviol = nviol + 1;
            if (nviol <= MAXV)
                vbuf = {vbuf, $sformatf("  %s %s %0.3f %b->%b\n", rule, bname(b), t, o, n)};
        end
    endtask

    // Close event kk: the summary line, with the violations before it.
    function automatic void close_ev(input integer kk, input reg complete);
        reg ok;
        begin
            ok = (nviol == 0) && complete && (d_oe3 > 0.05);
            if (!complete) vbuf = {vbuf, "  event never reached e3 + T\n"};
            else if (!(d_oe3 > 0.05)) vbuf = {vbuf, $sformatf("  d_oe3 = %0.3f <= 0.05: uio_oe[3] did not rise, or no delay took effect\n", d_oe3)};
            if (nviol > MAXV) vbuf = {vbuf, $sformatf("  (%0d violations, first %0d shown)\n", nviol, MAXV)};
            $write("%s", vbuf);
            $display("GLITCH-MON event %0d clk_in_reset=%0d t_r=%0.3f e1=%0.3f e2=%0.3f e3=%0.3f d_oe3=%0.3f: %s",
                     kk, clk_in_reset, t_r, e1, e2, e3, d_oe3, ok ? "PASS" : "FAIL");
            if (!ok) nfail = nfail + 1;
            nclosed = nclosed + 1;
            open = 1'b0;
        end
    endfunction

    // rst_n falls: a new event (a previous one still open is cut short and fails)
    always @(negedge tb_tt_um.rst_n) begin : fall
        integer my;
        if (open) close_ev(k, 1'b0);
        k = k + 1; my = k;
        open = 1'b1; e3_seen = 1'b0; rose = 1'b0; nedge = 0; clk_in_reset = 0; nviol = 0;
        t_f = $realtime; t_r = -1.0; e1 = -1.0; e2 = -1.0; e3 = -1.0; d_oe3 = -1.0;
        vbuf = "";
        for (i = 0; i < 16; i = i + 1) begin cnt0[i] = 0; cnt3[i] = 0; end
    end

    // the start of the X window
    always @(negedge tb_tt_um.rst_n) begin : xwin
        integer my, j;
        #0;   // after the fall block of this same event has run (it increments k), whatever the scheduling order
        my = k;
        #(RST);
        if (open && k == my)
            for (j = 0; j < 16; j = j + 1)
                if (B[j] === 1'bx || B[j] === 1'bz) viol("M1", j, $realtime, B[j], B[j]);
    end

    always @(posedge tb_tt_um.rst_n) if (open) begin rose = 1'b1; t_r = $realtime; end

    always @(posedge tb_tt_um.clk) if (open) begin
        if (!rose) clk_in_reset = clk_in_reset + 1;
        else if (nedge < 3) begin
            nedge = nedge + 1;
            if (nedge == 1) e1 = $realtime;
            if (nedge == 2) e2 = $realtime;
            if (nedge == 3) begin e3 = $realtime; e3_seen = 1'b1; -> e3_ev; end
        end
    end

    // e3 + T: the event is complete
    always @(e3_ev) begin : done
        integer my;
        my = k;
        #(T);
        if (open && k == my) close_ev(k, 1'b1);
    end

    // every change of a pin bit
    always @(B) begin : chg
        integer j;
        real t;
        t = $realtime;
        for (j = 0; j < 16; j = j + 1)
            if (B[j] !== pb[j] && open) begin
                if (t < t_f + RST) begin
                    cnt0[j] = cnt0[j] + 1;
                    if (cnt0[j] > 1) viol("M0", j, t, pb[j], B[j]);
                end else begin
                    if (B[j] === 1'bx || B[j] === 1'bz) viol("M1", j, t, pb[j], B[j]);
                    if (!e3_seen) viol("M2", j, t, pb[j], B[j]);
                    else begin
                        cnt3[j] = cnt3[j] + 1;
                        if (cnt3[j] > 1) viol("M3", j, t, pb[j], B[j]);
                        // uo_out may not move here, except RTS# (uo_out[5]) falling once: it leaves reset
                        // high and the UART asserts it when it is ready to receive (tb_tt_um.v header).
                        if (j >= 8 && !(j == 13 && pb[j] === 1'b1 && B[j] === 1'b0)) viol("M3", j, t, pb[j], B[j]);
                        if (j == 3 && B[j] === 1'b1 && d_oe3 < 0.0) d_oe3 = t - e3;
                    end
                end
            end
        pb = B;
    end

    final begin
        if (open) close_ev(k, 1'b0);
        if (nclosed < 3) begin
            nfail = nfail + 1;
            $display("GLITCH-MON FAIL %0d events: fewer than 3 (the bench resets three times)", nclosed);
        end else if (nfail != 0)
            $display("GLITCH-MON FAIL %0d events, %0d failed", nclosed, nfail);
        else
            $display("GLITCH-MON PASS %0d events", nclosed);
    end
endmodule
