`timescale 1ns / 1ps
`include "syscon_spec.vh"
// syscon + watchdog (src/syscon.v) against a cycle model written from the
// specification (tb/syscon_spec.vh, build/wo/WO-14: requirements SYS-001..018,
// assumptions A1-A17), not from the RTL. Checked on every clock: rst_soc,
// rd_late and, for every read, rdata. Every fire the model predicts is also
// checked against the watchdog's stated bound: more than 2*Pt and at most
// 3*Pt+1 clocks after the last kick, enable or TORR write (Pt = period of the
// tapped bit, 2^(t+1) clocks here: wdt_tap is a free-running counter, a scaled
// mtime). The DUT's fires are held to that bound through the model: rst_soc
// is compared with it on every clock.
//
// Stimulus: directed sections, an exhaustive sweep of every word offset, then
// seeded constrained-random (+SEED=, +CYCLES=) with coverage floors. Inputs
// change on the negative edge and are sampled on the positive one.
module tb_syscon;
    reg         clk = 0;
    reg         rst = 1, sel = 0, we = 0, pin = 1;
    reg  [3:0]  be = 0;
    reg  [13:0] aw = 0;               // addr[15:2]
    reg  [31:0] wdata = 0;
    reg  [31:0] tc = 0;               // scaled mtime: wdt_tap = tc[15:0]
    wire        rst_soc, rd_late;
    wire [31:0] rdata;
    syscon uut (
        .clk(clk), .rst(rst), .rst_soc(rst_soc), .sel(sel), .we(we), .be(be),
        .addr(aw), .wdata(wdata), .rdata(rdata),
        .strap_rd_late(pin), .rd_late(rd_late), .wdt_tap(tc[15:0]));
    always #5 clk = ~clk;
    always @(posedge clk) tc <= tc + 1;

    integer checks = 0, fails = 0, cyc = 0, fires = 0;
    integer seed = 1, seed0 = 1, ncyc = 200000, gseed = 12345;

    // ------------------------------------------------------------ the model
    reg        mv = 0;                // model valid (after the first reset edge)
    reg [2:0]  m_cause;
    reg [7:0]  m_bm;
    reg        m_strap, m_off, m_en, m_tprev;
    reg [3:0]  m_top;
    integer    m_hold, m_ticks, lclr = 0;
    reg        prev_rst = 1, prev_pin = 1;

    // coverage (random phase only)
    reg        cv_on = 0;
    integer cv_reboot = 0, cv_off = 0, cv_fail = 0, cv_fires = 0, cv_ign = 0;
    integer cv_w1c0 = 0, cv_w1c1 = 0, cv_w1c2 = 0, cv_bm = 0, cv_good = 0, cv_bad = 0;
    integer cv_hdone = 0;
    integer cv_torr = 0, cv_hw = 0, cv_rsth = 0, cv_rsto = 0, cv_hpin = 0;

    task chk(input [8*10-1:0] what, input [31:0] got, input [31:0] want);
        begin
            checks = checks + 1;
            if (got !== want) begin
                fails = fails + 1;
                if (fails <= 30)
                    $display("FAIL %0s: got %h want %h (cycle %0d: rst %b sel %b we %b be %b addr %04h wdata %h)",
                             what, got, want, cyc, rst, sel, we, be, {aw, 2'b00}, wdata);
            end
        end
    endtask

    task xfail(input [8*40-1:0] msg);
        begin
            fails = fails + 1;
            if (fails <= 30) $display("FAIL %0s (cycle %0d)", msg, cyc);
        end
    endtask

    function [31:0] e_rd(input [13:0] a);
        begin
            e_rd = 32'h0;
            if (a < 14'd8) begin
                case (a[2:0])
                    3'd1: e_rd = {29'b0, m_cause};
                    3'd2: e_rd = {24'b0, m_bm};
                    3'd3: e_rd = `CHIP_ID_SPEC;
                    3'd4: e_rd = {31'b0, m_strap};
                    default: e_rd = 32'h0;
                endcase
            end else if (a[13:6] == 8'h01) begin
                case (a[5:0])
                    6'd0:  e_rd = {31'b0, m_en};
                    6'd1:  e_rd = {24'b0, m_top, m_top};
                    6'd61: e_rd = `WDT_COMP1_VAL;
                    default: e_rd = 32'h0;
                endcase
            end
        end
    endfunction

    // The watchdog will fire at the coming edge (decided from the state now).
    function pred_fire(input dummy);
        begin
            pred_fire = mv && !rst && !(m_hold > 0 || m_off) && m_en &&
                        (tc[m_top] & ~m_tprev) && (m_ticks == 2);
        end
    endfunction

    always @(posedge clk) begin : model
        reg        held, wt, tk, fr, kick, torr, cren, soft, offs, ign;
        reg [2:0]  w1c;
        reg [3:0]  ntop;
        integer    nt, d, p;
        cyc = cyc + 1;
        if (mv) begin
            held = (m_hold > 0) || m_off;
            chk("rst_soc", rst_soc, rst | held);
            chk("rd_late", rd_late, rst ? pin : m_strap);
            if (sel && !we && !rst) chk("rdata", rdata, e_rd(aw));
        end
        if (rst) begin
            if (mv && !prev_rst && cv_on) begin
                if (m_hold > 0) cv_rsth = cv_rsth + 1;
                if (m_off)      cv_rsto = cv_rsto + 1;
            end
            m_cause = 3'b001; m_bm = 8'h00; m_strap = pin; m_hold = 0; m_off = 0;
            m_en = 0; m_top = `WDT_TOP_RESET; m_ticks = 0; m_tprev = 1; mv = 1;
        end else if (mv) begin
            if (m_hold > 0 || m_off) begin
                if (cv_on && sel && we) cv_hw = cv_hw + 1;
                if (cv_on && pin !== prev_pin) cv_hpin = cv_hpin + 1;
                if (cv_on && m_hold == 1 && !m_off) cv_hdone = cv_hdone + 1;
                if (m_hold > 0) m_hold = m_hold - 1;
                m_en = 0; m_top = `WDT_TOP_RESET; m_ticks = 0; m_tprev = 1;
            end else begin
                wt = tc[m_top];
                tk = wt & ~m_tprev;
                fr = m_en & tk & (m_ticks == 2);
                kick = 0; torr = 0; cren = 0; soft = 0; offs = 0; ign = 0; w1c = 0; ntop = m_top;
                if (sel && we) begin
                    if (aw < 14'd8) begin
                        case (aw[2:0])
                            3'd0: if (be[1:0] == 2'b11) begin
                                      if (wdata[15:0] == `FIN_REBOOT) soft = 1;
                                      else if (wdata[15:0] == `FIN_OFF || wdata[15:0] == `FIN_FAIL) offs = 1;
                                      else ign = 1;
                                  end else ign = 1;
                            3'd1: if (be[0]) w1c = wdata[2:0];
                            3'd2: if (be[0]) begin
                                      m_bm = wdata[7:0];
                                      if (cv_on) cv_bm = cv_bm + 1;
                                  end
                            default: ;
                        endcase
                    end else if (aw[13:6] == 8'h01 && be[0]) begin
                        case (aw[5:0])
                            6'd0: if (wdata[0]) cren = 1;
                            6'd1: begin torr = 1; ntop = wdata[3:0]; end
                            6'd3: if (wdata[7:0] == `WDT_KEY) kick = 1;
                            default: ;
                        endcase
                    end
                end
                if (cv_on) begin
                    if (soft) cv_reboot = cv_reboot + 1;
                    if (offs && wdata[15:0] == `FIN_OFF)  cv_off = cv_off + 1;
                    if (offs && wdata[15:0] == `FIN_FAIL) cv_fail = cv_fail + 1;
                    if (ign && aw == 14'd0) cv_ign = cv_ign + 1;
                    if (w1c[0] && m_cause[0]) cv_w1c0 = cv_w1c0 + 1;
                    if (w1c[1] && m_cause[1]) cv_w1c1 = cv_w1c1 + 1;
                    if (w1c[2] && m_cause[2]) cv_w1c2 = cv_w1c2 + 1;
                    if (kick && m_en && m_ticks > 0) cv_good = cv_good + 1;
                    if (sel && we && m_en && m_ticks > 0 && !kick && !torr && (aw == 14'h43 || wdata[7:0] == `WDT_KEY)) cv_bad = cv_bad + 1;
                    if (torr && m_en) cv_torr = cv_torr + 1;
                    if (fr) cv_fires = cv_fires + 1;
                end
                // independent timing check of the stated bound (SYS-015)
                if (fr) begin
                    p = 1 << (m_top + 1);
                    d = cyc - lclr;
                    checks = checks + 1;
                    fires = fires + 1;
                    if (!(d > 2 * p && d <= 3 * p + 1)) begin
                        fails = fails + 1;
                        if (fails <= 30)
                            $display("FAIL wdt timing: fire %0d clocks after the last clear, allowed (%0d, %0d] (TOP %0d, cycle %0d)",
                                     d, 2 * p, 3 * p + 1, m_top, cyc);
                    end
                end
                if (kick || torr) lclr = cyc;
                if (cren && !m_en) lclr = cyc;
                nt = m_ticks;
                if (m_en && tk && m_ticks < 2) nt = m_ticks + 1;
                if (kick || torr || !m_en) nt = 0;
                m_cause = (m_cause & ~w1c) | (soft ? 3'b010 : 3'b000) | (fr ? 3'b100 : 3'b000);
                m_tprev = torr | wt;
                m_en = m_en | cren;
                m_top = ntop;
                m_ticks = nt;
                if (soft || fr) m_hold = `REBOOT_EDGES;
                if (offs) m_off = 1;
            end
        end
        prev_rst = rst;
        prev_pin = pin;
    end

    // ------------------------------------------------------------ stimulus
    function [31:0] gr(input dummy);
        begin gr = $random(gseed); end
    endfunction
    function integer rnd(input integer n);
        begin rnd = $unsigned($random(seed)) % n; end
    endfunction

    task nxt;
        begin @(negedge clk); end
    endtask
    task drv(input s, input w, input [3:0] b, input [15:0] off, input [31:0] d);
        begin sel = s; we = w; be = b; aw = off[15:2]; wdata = d; end
    endtask
    task drv_idle;   // no access; the other bus lines carry garbage
        reg [31:0] g;
        begin g = gr(0); sel = 0; we = g[0]; be = g[4:1]; aw = g[18:5]; wdata = gr(0); end
    endtask
    task st(input [15:0] off, input [31:0] d, input [3:0] b);
        begin nxt; drv(1, 1, b, off, d); end
    endtask
    task ld(input [15:0] off);
        begin nxt; drv(1, 0, 4'hF, off, gr(0)); end
    endtask
    task idle(input integer n);
        integer i;
        begin for (i = 0; i < n; i = i + 1) begin nxt; drv_idle; end end
    endtask
    // a pin reset of n edges; pins[i] is the strap pin on edge i; then one idle
    // cycle with the pin at pa
    task prst(input integer n, input [7:0] pins, input pa);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin nxt; rst = 1; pin = pins[i]; drv_idle; end
            nxt; rst = 0; pin = pa; drv_idle;
        end
    endtask
    task prs;   // a plain pin reset, strap 1
        begin prst(2, 8'b11, 1'b1); end
    endtask
    task rd_regs;
        integer k;
        begin for (k = 0; k < 8; k = k + 1) ld(k * 4); end
    endtask
    task rd_win;
        integer k;
        begin for (k = 0; k < 64; k = k + 1) ld(16'h0100 + k * 4); end
    endtask
    // idle until tc & (P-1) == tgt at a negative edge (the value the coming edge samples)
    task wait_phase(input integer t, input integer tgt);
        integer pm;
        begin
            pm = (1 << (t + 1)) - 1;
            nxt; drv_idle;
            while ((tc & pm) != tgt) begin nxt; drv_idle; end
        end
    endtask
    task wait_fire(input integer lim);
        integer f0, i;
        begin
            f0 = fires; i = 0;
            while (fires == f0 && i < lim) begin nxt; drv_idle; i = i + 1; end
            if (fires == f0) xfail("expected a watchdog fire, none came");
        end
    endtask
    // idle to the cycle in which the watchdog fires; leaves the negedge open
    // for the caller to drive that cycle
    task aim_fire(input integer lim);
        integer i;
        begin
            i = 0;
            nxt; drv_idle;
            while (!pred_fire(0) && i < lim) begin nxt; drv_idle; i = i + 1; end
            if (!pred_fire(0)) xfail("could not aim at a fire");
        end
    endtask
    // The clock before a fire: count 2, no tick at the coming edge, a tick at
    // the edge after it (SA-009, SYS-019). Leaves the negedge open.
    function pre_fire(input dummy);
        reg [31:0] tn;
        begin
            tn = tc + 1;
            pre_fire = mv && !rst && m_hold == 0 && !m_off && m_en && m_ticks == 2 &&
                       !tc[m_top] && tn[m_top];
        end
    endfunction
    task aim_pre_fire(input integer lim);
        integer i;
        begin
            i = 0;
            nxt; drv_idle;
            while (!pre_fire(0) && i < lim) begin nxt; drv_idle; i = i + 1; end
            if (!pre_fire(0)) xfail("could not aim at the clock before a fire");
        end
    endtask
    task wdt_arm(input [3:0] t);
        begin st(`WDT_TORR, t, 4'h1); st(`WDT_CR, 32'h1, 4'h1); end
    endtask

    // ---------------------------------------------------------- sections
    integer i, j, k, m, t, ph, c, P, nph, tgt, f0;
    reg [31:0] dd, d2;
    reg [3:0]  bb;
    reg [15:0] oo;

    function [15:0] reg_off(input integer n);
        begin
            case (n)
                8:  reg_off = `WDT_CR;
                9:  reg_off = `WDT_TORR;
                10: reg_off = `WDT_CCVR;
                11: reg_off = `WDT_CRR;
                12: reg_off = `WDT_STAT;
                13: reg_off = `WDT_EOI;
                14: reg_off = `WDT_COMP1;
                default: reg_off = n * 4;
            endcase
        end
    endfunction
    function [31:0] data_of(input integer n);
        begin
            case (n)
                0: data_of = 32'h0000_0000;
                1: data_of = 32'hFFFF_FFFF;
                2: data_of = 32'hA5A5_A5A5;
                3: data_of = 32'h0000_0076;
                default: data_of = 32'h0000_0001;
            endcase
        end
    endfunction
    function [15:0] fin_status(input integer n);
        begin
            case (n)
                0: fin_status = 16'h7777;  1: fin_status = 16'h5555;  2: fin_status = 16'h3333;
                3: fin_status = 16'h7776;  4: fin_status = 16'h5554;  5: fin_status = 16'h3332;
                6: fin_status = 16'h0000;  7: fin_status = 16'hFFFF;  default: fin_status = 16'h7577;
            endcase
        end
    endfunction
    function [3:0] fin_lanes(input integer n);
        begin
            case (n)
                0: fin_lanes = 4'b0001; 1: fin_lanes = 4'b0010; 2: fin_lanes = 4'b0011;
                3: fin_lanes = 4'b0100; 4: fin_lanes = 4'b1000; 5: fin_lanes = 4'b1100;
                6: fin_lanes = 4'b0111; 7: fin_lanes = 4'b1011; default: fin_lanes = 4'b1111;
            endcase
        end
    endfunction
    function [15:0] fin_upper(input integer n);
        begin
            case (n) 0: fin_upper = 16'h0000; 1: fin_upper = 16'h7777; default: fin_upper = 16'hFFFF; endcase
        end
    endfunction

    task sec(input [8*40-1:0] name);
        begin $display("section: %0s (cycle %0d)", name, cyc); end
    endtask

    task s_reset;
        begin
            sec("pin reset, reset values, strap");
            prst(3, 3'b101, 1'b0);          // strap latched 1 on the last edge
            rd_regs; rd_win;
            for (i = 0; i < 6; i = i + 1) begin nxt; pin = ~pin; drv(1, 0, 4'hF, `SYS_STRAPS, 32'h0); end
            prst(3, 3'b011, 1'b1);          // 1, 1, 0: latched 0
            rd_regs; rd_win;
            for (i = 0; i < 6; i = i + 1) begin nxt; pin = ~pin; drv(1, 0, 4'hF, `SYS_STRAPS, 32'h0); end
            prst(4, 4'b0110, 1'b0);         // 0, 1, 1, 0
            rd_regs;
            prst(1, 1'b1, 1'b0);            // a one-edge reset
            rd_regs;
            idle(2);
        end
    endtask

    task s_regs;
        begin
            sec("every register, every lane mask");
            for (k = 0; k < 15; k = k + 1) begin
                prs;
                oo = reg_off(k);
                for (m = 1; m < 16; m = m + 1)
                    for (j = 0; j < 5; j = j + 1) begin
                        st(oo, data_of(j), m);
                        ld(oo); ld(`SYS_CAUSE); ld(`SYS_BOOTMODE); ld(`WDT_CR); ld(`WDT_TORR);
                    end
                for (j = 0; j < 5; j = j + 1) begin st(oo, data_of(j), 4'h0); ld(oo); end
            end
            prs;
        end
    endtask

    task s_finish;
        begin
            sec("FINISH matrix");
            prs;
            st(`SYS_BOOTMODE, 32'hA5, 4'h1);
            for (i = 0; i < 9; i = i + 1)
                for (j = 0; j < 9; j = j + 1)
                    for (k = 0; k < 3; k = k + 1) begin
                        st(`SYS_FINISH, {fin_upper(k), fin_status(i)}, fin_lanes(j));
                        ld(`SYS_CAUSE); ld(`SYS_STRAPS);
                        idle(3);
                        if (m_off) prs;
                        ld(`SYS_CAUSE); ld(`SYS_BOOTMODE); ld(`SYS_FINISH);
                    end
            // the replicated forms a core makes (sb, sh at +0 and +2)
            for (i = 0; i < 3; i = i + 1)
                for (j = 0; j < 4; j = j + 1) begin
                    oo = fin_status(i);
                    dd = {2{oo}};
                    case (j) 0: bb = 4'b0001; 1: bb = 4'b0010; 2: bb = 4'b0011; default: bb = 4'b1100; endcase
                    if (j < 2) dd = {4{oo[7:0]}};
                    st(`SYS_FINISH, dd, bb);
                    ld(`SYS_CAUSE); idle(3);
                    if (m_off) prs;
                    ld(`SYS_CAUSE);
                end
            prs;
        end
    endtask

    task wr_kind(input integer kind, input integer n);   // one write during a hold
        begin
            case (kind % 7)
                0: st(`SYS_BOOTMODE, 32'h5A + n, 4'h1);
                1: st(`SYS_CAUSE, 32'h7, 4'h1);
                2: st(`WDT_CR, 32'h1, 4'h1);
                3: st(`WDT_TORR, 32'h0, 4'h1);
                4: st(`SYS_FINISH, 32'h5555, 4'h3);
                5: st(`SYS_FINISH, 32'h7777, 4'hF);
                default: st(`WDT_CRR, 32'h76, 4'h1);
            endcase
        end
    endtask

    task s_held;
        begin
            sec("writes while held, resets during holds");
            prs;
            // a reboot, then a write on every cycle of the hold and after it
            for (k = 0; k < 7; k = k + 1) begin
                st(`SYS_BOOTMODE, 32'h11, 4'h1);
                st(`SYS_FINISH, 32'h7777, 4'h3);
                for (j = 0; j < 6; j = j + 1) wr_kind(k + j, j);
                ld(`SYS_BOOTMODE); ld(`SYS_CAUSE); ld(`WDT_CR); ld(`WDT_TORR);
                prs;
            end
            // power-off (and fail), the same writes, then the pin reset
            for (k = 0; k < 7; k = k + 1) begin
                st(`SYS_BOOTMODE, 32'h11, 4'h1);
                st(`SYS_FINISH, (k & 1) ? 32'h5555 : 32'hDEAD_3333, 4'h3);
                for (j = 0; j < 9; j = j + 1) wr_kind(k + j, j);
                ld(`SYS_BOOTMODE); ld(`SYS_CAUSE); ld(`WDT_CR); ld(`WDT_TORR);
                prs;
                ld(`SYS_BOOTMODE); ld(`SYS_CAUSE);
            end
            // a pin reset on each edge of a reboot hold, and during power-off
            for (k = 0; k < 4; k = k + 1) begin
                st(`SYS_BOOTMODE, 32'h22, 4'h1);
                st(`SYS_FINISH, 32'h7777, 4'h3);
                idle(k);
                prst(1, 1'b0, 1'b1);
                ld(`SYS_CAUSE); ld(`SYS_BOOTMODE); ld(`SYS_STRAPS);
                idle(2);
            end
            for (k = 0; k < 4; k = k + 1) begin
                st(`SYS_FINISH, 32'h5555, 4'h3);
                idle(k);
                prst(1 + (k & 1), 2'b10, 1'b0);
                ld(`SYS_CAUSE); ld(`SYS_STRAPS);
                idle(2);
            end
            // two reboots back to back, at every distance across the hold boundary
            for (k = 0; k < 7; k = k + 1) begin
                st(`SYS_FINISH, 32'h7777, 4'h3);
                idle(k);
                st(`SYS_FINISH, 32'h7777, 4'h3);
                idle(5);
                ld(`SYS_CAUSE); ld(`SYS_BOOTMODE);
            end
            // a reboot, then immediately a BOOT_MODE store
            for (k = 0; k < 4; k = k + 1) begin
                st(`SYS_FINISH, 32'h7777, 4'h3);
                idle(k);
                st(`SYS_BOOTMODE, 32'hC0 + k, 4'h1);
                idle(3); ld(`SYS_BOOTMODE);
            end
            prs;
        end
    endtask

    task set_all_causes;   // RESET_CAUSE = PIN | SOFT | WDT
        begin
            prs;
            st(`SYS_FINISH, 32'h7777, 4'h3);
            idle(4);
            wdt_arm(4'h0);
            wait_fire(100);
            idle(4);
            ld(`SYS_CAUSE);
        end
    endtask

    task s_w1c;
        begin
            sec("RESET_CAUSE W1C orders");
            for (k = 0; k < 6; k = k + 1) begin
                set_all_causes;
                for (j = 0; j < 3; j = j + 1) begin
                    case ((k < 2 ? j : k < 4 ? (j + 1) % 3 : (j + 2) % 3) ^ (k & 1 ? 1 : 0))
                        0: dd = 32'h1;  1: dd = 32'h2;  default: dd = 32'h4;
                    endcase
                    if (k >= 4 && (k & 1)) dd = (j == 0) ? 32'h6 : (j == 1) ? 32'h1 : 32'h4;
                    st(`SYS_CAUSE, dd, 4'h1); ld(`SYS_CAUSE);
                end
                st(`SYS_CAUSE, 32'hFFFF_FFF8, 4'hF); ld(`SYS_CAUSE);   // no low bits: nothing
                st(`SYS_CAUSE, 32'h0000_0007, 4'hE); ld(`SYS_CAUSE);   // lane 0 not written
                st(`SYS_CAUSE, 32'h0000_0007, 4'h1); ld(`SYS_CAUSE);
            end
            prs;
        end
    endtask

    task s_wdt_regs;
        begin
            sec("watchdog registers");
            prs;
            rd_win;
            for (k = 0; k < 16; k = k + 1) begin
                st(`WDT_TORR, 32'hA5A5_A5A0 | k, 4'h1); ld(`WDT_TORR);
                st(`WDT_TORR, {28'h0, k[3:0]}, 4'hE); ld(`WDT_TORR);
            end
            st(`WDT_TORR, 32'hF, 4'h1);
            ld(`WDT_CR);
            st(`WDT_CR, 32'hFFFF_FFFE, 4'hF); ld(`WDT_CR);
            st(`WDT_CR, 32'h1, 4'hE); ld(`WDT_CR);
            st(`WDT_CR, 32'h1, 4'h1); ld(`WDT_CR);
            st(`WDT_CR, 32'h0, 4'hF); ld(`WDT_CR);
            st(`WDT_CR, 32'h2, 4'h1); ld(`WDT_CR);
            st(`WDT_CR, 32'h0, 4'h1); ld(`WDT_CR);
            rd_win;
            prs; rd_win;
        end
    endtask

    task s_wdt_timing;
        begin
            sec("watchdog timing, all 16 TOPs");
            prs;
            for (t = 0; t < 16; t = t + 1) begin
                P = 1 << (t + 1);
                nph = (t <= 9) ? 8 : (t <= 13) ? 4 : 2;
                if (nph > P) nph = P;
                for (ph = 0; ph < nph; ph = ph + 1) begin
                    tgt = ph * (P / nph);
                    st(`WDT_TORR, t, 4'h1);
                    wait_phase(t, tgt);
                    drv(1, 1, 4'h1, `WDT_CR, 32'h1);
                    wait_fire(4 * P + 100);
                    idle(1); ld(`WDT_CR); ld(`WDT_TORR); ld(`SYS_CAUSE);
                    if (t == 0 && ph == 0) idle(200000);           // 3*P15 and a margin
                    else if (t < 12) idle(4 * P);
                    else idle(2000);
                    ld(`WDT_CR); ld(`WDT_TORR);
                end
            end
            prs;
        end
    endtask

    task kick_form(input integer n);
        begin
            case (n % 4)
                0: st(`WDT_CRR, 32'h76, 4'h1);
                1: st(`WDT_CRR, 32'hFFFF_FF76, 4'hF);
                2: st(`WDT_CRR, 32'h5A00_1276, 4'h5);
                default: st(`WDT_CRR, 32'h0000_0076, 4'h3);
            endcase
        end
    endtask

    task s_kicks;
        begin
            sec("kicks, bad kicks");
            prs;
            for (t = 0; t < 7; t = t + 1) begin
                P = 1 << (t + 1);
                wdt_arm(t);
                f0 = fires;
                for (k = 0; k < 14; k = k + 1) begin
                    idle(2 * P - 2);
                    kick_form(k);
                end
                if (fires != f0) xfail("watchdog fired under good kicks");
                wait_fire(3 * P + 10);
                idle(2);
            end
            // bad kicks reload nothing: the watchdog fires on time
            for (k = 0; k < 16; k = k + 1) begin
                prs;
                wdt_arm(4'h2);
                f0 = fires;
                for (j = 0; j < 45; j = j + 1) begin
                    nxt;
                    case (k)
                        0:  drv(1, 1, 4'h1, `WDT_CRR, 32'h75);
                        1:  drv(1, 1, 4'h1, `WDT_CRR, 32'h77);
                        2:  drv(1, 1, 4'h2, `WDT_CRR, 32'h0000_7600);
                        3:  drv(1, 1, 4'h2, `WDT_CRR, 32'h0000_0076);
                        4:  drv(1, 1, 4'hE, `WDT_CRR, 32'h7676_7676);
                        5:  drv(1, 1, 4'hF, `WDT_CCVR, 32'h76);
                        6:  drv(1, 1, 4'hF, `WDT_STAT, 32'h76);
                        7:  drv(1, 1, 4'hF, `WDT_EOI, 32'h76);
                        8:  drv(1, 1, 4'hF, `WDT_COMP1, 32'h76);
                        9:  drv(1, 1, 4'hF, 16'h030C, 32'h76);
                        10: drv(1, 1, 4'hF, 16'h050C, 32'h76);
                        11: drv(1, 1, 4'hF, 16'h110C, 32'h76);
                        12: drv(1, 1, 4'hF, 16'h410C, 32'h76);
                        13: drv(1, 1, 4'hF, 16'h000C, 32'h76);
                        14: drv(1, 1, 4'hF, `WDT_CRR, 32'hFFFF_FF77);
                        default: drv(1, 1, 4'h0, `WDT_CRR, 32'h76);
                    endcase
                end
                if (fires == f0) xfail("a bad kick reloaded the watchdog");
                idle(3);
            end
            prs;
        end
    endtask

    integer cells = 0, cells_want = 0;
    reg hit;
    task s_torr;
        integer t2, lim;
        begin
            sec("TORR write at every phase and count");
            for (t = 0; t < 4; t = t + 1) begin
                P = 1 << (t + 1);
                for (c = 0; c < 3; c = c + 1)
                    for (ph = 0; ph < P; ph = ph + 1) begin
                        cells_want = cells_want + 1;
                        prs;
                        st(`WDT_TORR, t, 4'h1);
                        t2 = ((c + ph) & 1) ? ((t + 1) & 3) : t;
                        hit = 0;
                        if (c == 0) begin
                            wait_phase(t, (ph + P - 1) & (P - 1));
                            drv(1, 1, 4'h1, `WDT_CR, 32'h1);
                            nxt; drv(1, 1, 4'h1, `WDT_TORR, t2);
                            hit = 1;
                        end else begin
                            st(`WDT_CR, 32'h1, 4'h1);
                            nxt; drv_idle;
                            lim = 0;
                            while (!hit && m_hold == 0 && !m_off && lim < 100) begin
                                if (m_ticks == c && (tc & (P - 1)) == ph) hit = 1;
                                else begin nxt; drv_idle; lim = lim + 1; end
                            end
                            if (hit) drv(1, 1, 4'h1, `WDT_TORR, t2);
                        end
                        if (hit) begin
                            cells = cells + 1;
                            wait_fire(3 * (1 << (t2 + 1)) + 20);
                        end
                        idle(2);
                    end
            end
            prs;
        end
    endtask

    task s_strap;
        begin
            sec("strap through holds");
            for (m = 0; m < 2; m = m + 1) begin
                prst(3, {m[0], ~m[0], ~m[0]}, ~m[0]);     // latched m, pin after ~m
                ld(`SYS_STRAPS);
                st(`SYS_FINISH, 32'h7777, 4'h3);
                for (i = 0; i < 6; i = i + 1) begin nxt; pin = ~pin; drv(1, 0, 4'hF, `SYS_STRAPS, 32'h0); end
                idle(2); ld(`SYS_STRAPS);
                st(`SYS_FINISH, 32'h5555, 4'h3);
                for (i = 0; i < 8; i = i + 1) begin nxt; pin = ~pin; drv(1, 0, 4'hF, `SYS_STRAPS, 32'h0); end
                idle(2);
                prst(2, {~m[0], ~m[0]}, m[0]);              // re-latched to ~m
                ld(`SYS_STRAPS);
                st(`SYS_FINISH, 32'h3333, 4'hF);
                for (i = 0; i < 5; i = i + 1) begin nxt; pin = ~pin; drv(1, 0, 4'hF, `SYS_STRAPS, 32'h0); end
                prs;
            end
        end
    endtask

    task s_poweroff_wdt;
        begin
            sec("power-off with the watchdog enabled");
            for (t = 0; t < 4; t = t + 1) begin
                prs;
                wdt_arm(t);
                st(`SYS_FINISH, (t & 1) ? 32'h1234_3333 : 32'h5555, 4'h3);
                for (i = 0; i < 6; i = i + 1) begin idle(1 << (t + 1)); ld(`SYS_CAUSE); end
                prst(2, 2'b01, 1'b1);
                ld(`SYS_CAUSE); ld(`WDT_CR);
            end
            prs;
        end
    endtask

    task s_same;
        begin
            sec("same-cycle watchdog cases");
            for (k = 0; k < 21; k = k + 1) begin
                if (k != 1) prs;
                wdt_arm(4'h1);
                if (k >= 16) aim_pre_fire(100); else aim_fire(100);
                case (k)
                    0, 1: drv(1, 1, 4'h1, `SYS_CAUSE, 32'h4);
                    2:    drv(1, 1, 4'hF, `SYS_CAUSE, 32'h7);
                    3:    drv(1, 1, 4'h3, `SYS_FINISH, 32'h7777);
                    4:    drv(1, 1, 4'hF, `SYS_FINISH, 32'h0000_5555);
                    5:    drv(1, 1, 4'h3, `SYS_FINISH, 32'h7777_3333);
                    6:    drv(1, 1, 4'h1, `WDT_CRR, 32'h76);
                    7:    drv(1, 1, 4'h1, `WDT_TORR, 32'h1);
                    8:    drv(1, 1, 4'h1, `SYS_BOOTMODE, 32'h5C);
                    9:    drv(1, 1, 4'h1, `WDT_CR, 32'h0);
                    10, 11, 12: drv_idle;
                    13:   drv(1, 0, 4'hF, `SYS_CAUSE, 32'h0);
                    14:   drv(1, 1, 4'h1, `WDT_TORR, 32'h5);
                    15:   drv(1, 1, 4'hF, `SYS_FINISH, 32'h7777);
                    16:   drv(1, 1, 4'h3, `SYS_FINISH, 32'h0000_7777);
                    17:   drv(1, 1, 4'hF, `SYS_FINISH, 32'h0000_5555);
                    18:   drv(1, 1, 4'h3, `SYS_FINISH, 32'hDEAD_3333);
                    19:   drv(1, 1, 4'h1, `WDT_CRR, 32'h76);
                    20:   drv(1, 1, 4'h1, `WDT_TORR, 32'h1);
                    default: drv_idle;
                endcase
                if (k >= 10 && k <= 12) begin
                    idle(k - 10);
                    prst(1, 1'b0, 1'b1);
                end
                if (k == 19 || k == 20) wait_fire(40);
                ld(`SYS_CAUSE); ld(`SYS_BOOTMODE); ld(`WDT_CR); ld(`WDT_TORR);
                idle(6);
                ld(`SYS_CAUSE);
                if (m_off) begin idle(20); prs; end
            end
            prs;
        end
    endtask

    task s_sweep;
        integer a, n;
        begin
            sec("exhaustive offset sweep");
            set_all_causes;
            for (a = 0; a < 16384; a = a + 1) begin
                if (a != 1 && !(a >= 14'h40 && a < 14'h80)) begin
                    st(a * 4, 32'hFFFF_FFFF, 4'hF);
                    if (a >= 3) begin
                        st(a * 4, 32'h0000_7777, 4'hF);
                        st(a * 4, 32'h0000_5555, 4'hF);
                    end
                    ld(a * 4); ld(`SYS_CAUSE); ld(`SYS_BOOTMODE); ld(`SYS_STRAPS); ld(`WDT_CR); ld(`WDT_TORR);
                end
            end
            st(`SYS_CAUSE, 32'hFFFF_FFFF, 4'hF); ld(`SYS_CAUSE); ld(`SYS_BOOTMODE);
            set_all_causes;
            for (a = 127; a >= 64; a = a - 1) begin
                st(a * 4, 32'hFFFF_FFFF, 4'hF);
                st(a * 4, 32'h0000_7777, 4'hF);
                st(a * 4, 32'h0000_5555, 4'hF);
                ld(a * 4); ld(`SYS_CAUSE); ld(`SYS_BOOTMODE); ld(`SYS_STRAPS); ld(`WDT_CR); ld(`WDT_TORR);
            end
            prs;
        end
    endtask

    // ---------------------------------------------------------- random
    localparam KS = 20;  // 3 in KS accesses are steered into a kick while the watchdog counts
    task rnd_access;
        reg [13:0] a;
        reg [31:0] d;
        reg [3:0]  b;
        reg        w;
        integer    r, q;
        begin
            r = rnd(100);
            if (r < 30) begin a = rnd(8); if (rnd(3) == 0) a = 14'd1; end
            else if (r < 45) begin
                if (rnd(2) == 0) begin
                    case (rnd(9))
                        0: a = 14'h40; 1: a = 14'h41; 2: a = 14'h43; 3: a = 14'h42;
                        4: a = 14'h44; 5: a = 14'h45; 6: a = 14'h41; 7: a = 14'h41; default: a = 14'h7D;
                    endcase
                end else a = 14'h40 + rnd(64);
            end else if (r < 65) begin
                case (rnd(5))
                    0: begin q = 3 + rnd(11); if (q == 6) q = 7; a = rnd(8) | (14'd1 << q); end
                    1: a = (16'h07F0 >> 2) + rnd(4);
                    2: begin q = rnd(3); a = (q == 0) ? (16'h4004 >> 2) : (q == 1) ? (16'hBFF8 >> 2) : (16'hBFFC >> 2); end
                    3: a = (16'hFFE0 >> 2) + rnd(8);
                    default: begin q = 7 + rnd(7); a = (14'h40 + rnd(64)) | (14'd1 << q); end
                endcase
            end else a = rnd(16384);
            w = rnd(2);
            case (rnd(4)) 0: b = 4'hF; 1: b = 4'hF; 2: b = 4'b0001 << rnd(4); default: b = rnd(16); endcase
            case (rnd(8))
                0: d = 32'h0;  1: d = 32'hFFFF_FFFF;  2: d = 32'hA5A5_A5A5;
                3: d = {$random(seed), 8'h76} >> 0;
                default: d = $random(seed);
            endcase
            if (a == 14'd0 && w && rnd(10) < 7) begin
                d[15:0] = fin_status(rnd(9));
                case (rnd(3)) 0: d[31:16] = 16'h0; 1: d[31:16] = 16'h7777; default: d[31:16] = $random(seed); endcase
                if (rnd(10) < 6) begin case (rnd(4)) 0: b = 4'b0011; 1: b = 4'b1111; 2: b = 4'b0111; default: b = 4'b1011; endcase end
            end
            if (a == 14'h43 && w && rnd(10) < 7) begin d[7:0] = 8'h76; if (rnd(10) < 7) b[0] = 1; end
            if (a == 14'h41 && w && rnd(10) < 7) d[3:0] = rnd(4);
            if (a == 14'h41 && w && rnd(10) < 7) b[0] = 1;
            if (a == 14'h40 && w && rnd(10) < 7) begin d[0] = 1; b[0] = 1; end
            if (a == 14'd1 && w && rnd(10) < 7) begin
                case (rnd(6)) 0: d[2:0] = 3'b001; 1, 4: d[2:0] = 3'b010; 2, 5: d[2:0] = 3'b100; default: d[2:0] = 3'b111; endcase
                if (rnd(10) < 8) b[0] = 1;
            end
            // steer: with the watchdog counting, kicks (good and bad) are what matter
            if (m_en && m_ticks > 0 && !m_off && m_hold == 0 && rnd(KS) < 3) begin
                a = 14'h43; w = 1; b = 4'h1;
                d = $random(seed);
                if (rnd(3) != 0) d[7:0] = 8'h76;
                else if (d[7:0] == 8'h76) d[7:0] = 8'h77;
            end
            nxt; drv(1, w, b, a * 4, d);
        end
    endtask

    integer rcnt, ri;
    task s_random;
        begin
            sec("constrained random");
            prs;
            cv_on = 1; rcnt = 0;
            for (ri = 0; ri < ncyc; ri = ri + 1) begin
                if (rcnt > 0) begin nxt; rst = 1; rcnt = rcnt - 1; pin = rnd(2); drv_idle; end
                else begin
                    if (rnd(m_off ? 300 : (m_hold > 0) ? 6 : 2000) == 0) begin
                        nxt; rst = 1; rcnt = rnd(4); pin = rnd(2); drv_idle;
                    end else begin
                        rst = 0; pin = rnd(2);
                        if (rnd(100) < 60) rnd_access;
                        else begin nxt; rst = 0; pin = rnd(2); drv_idle; end
                    end
                end
            end
            nxt; rst = 0; drv_idle;
            cv_on = 0;
            $display("coverage: reboots %0d power-offs %0d fails %0d fires %0d ignored-FINISH %0d W1C %0d/%0d/%0d BM-writes %0d good-kicks %0d bad-kicks %0d TORR-enabled %0d held-writes %0d rst-in-hold %0d rst-in-off %0d held-pin-changes %0d hold-done %0d",
                     cv_reboot, cv_off, cv_fail, cv_fires, cv_ign, cv_w1c0, cv_w1c1, cv_w1c2, cv_bm, cv_good, cv_bad,
                     cv_torr, cv_hw, cv_rsth, cv_rsto, cv_hpin, cv_hdone);
            if (cv_reboot < 50 || cv_off < 20 || cv_fail < 20 || cv_fires < 30 || cv_ign < 500 ||
                cv_w1c0 < 50 || cv_w1c1 < 50 || cv_w1c2 < 50 || cv_bm < 500 || cv_good < 200 ||
                cv_bad < 200 || cv_torr < 50 || cv_hw < 200 || cv_rsth < 5 || cv_rsto < 5 || cv_hpin < 50 || cv_hdone < 100) begin
                fails = fails + 1;
                $display("FAIL coverage: a floor was missed (see the coverage line)");
            end
        end
    endtask

    initial begin
        if ($value$plusargs("SEED=%d", seed)) ;
        seed0 = seed;
        if ($value$plusargs("CYCLES=%d", ncyc)) ;
        $display("=== syscon testbench (cycle model, seed %0d, %0d random cycles) ===", seed0, ncyc);
        rst = 1; pin = 1; drv_idle;
        prst(3, 3'b111, 1'b1);
        s_reset;
        s_regs;
        s_finish;
        s_held;
        s_w1c;
        s_wdt_regs;
        s_strap;
        s_poweroff_wdt;
        s_kicks;
        s_torr;
        $display("TORR cells reached: %0d of %0d", cells, cells_want);
        if (cells != cells_want) xfail("TORR phase/count cells not all reached");
        s_same;
        s_wdt_timing;
        s_sweep;
        s_random;
        idle(4);
        $display("end time %0d ns", $time);
        if (fails == 0) $display("PASS tb_syscon (%0d checks, %0d watchdog fires, seed %0d)", checks, fires, seed0);
        else            $display("FAIL tb_syscon: %0d failures, %0d checks, seed %0d", fails, checks, seed0);
        $finish;
    end
    initial begin #1; #(64'd100_000_000 + 64'd50 * ncyc); $display("TIMEOUT tb_syscon"); $finish; end
endmodule
