`timescale 1ns / 1ps
`ifndef CHIP_HZ
`define CHIP_HZ 62500000
`endif
// pwm (src/pwm.v) against a cycle model written from the WO-54 specification (SiFive pwm0 layout, two built
// of four 16-bit comparators, WO-63: pwmcmp2/3 read 0xFFFF, writes ignored, ip/pwm_o[3:2] constant 0; slim-down: no sticky, no one-shot, no irq output, cfg bits 8 and 13 read 0 and ignore writes), not from the RTL. pwm_o and every read word are compared
// every clock. Independent oracle (from Linux pwm-sifive.c, not the RTL): scale/cmp from the driver's arithmetic,
// period 2^(16+scale), high clocks (65536-cmp)<<scale, pin = ip, reset cmp 0xFFFF, CMP/CFG readbacks. Directed phases, then a seeded constrained-random phase (+SEED=, +CYCLES=)
// with coverage floors. Inputs change on the negative edge and are sampled on the positive one.
module tb_pwm;
    reg         clk = 0, rst = 1, sel = 0, we = 0;
    reg  [3:0]  be = 0;
    reg  [5:2]  addr = 0;
    reg  [31:0] wdata = 0;
    wire [31:0] rdata;
    wire [1:0]  pwm_o;
    pwm uut (.clk(clk), .rst(rst), .sel(sel), .we(we), .be(be), .addr(addr), .wdata(wdata),
             .rdata(rdata), .pwm_o(pwm_o));
    always #5 clk = ~clk;

    integer seed = 1, ncyc = 600000, checks = 0, errors = 0, cyc = 0;
    reg [31:0] rs;
    function [31:0] rnd(input integer dummy);
        begin rs = rs ^ (rs << 13); rs = rs ^ (rs >> 17); rs = rs ^ (rs << 5); rnd = rs; end
    endfunction

    // ------------------------------------------------------------ model
    integer m_scale, m_pre, m_s, m_en_cnt;
    reg     m_zc, m_always;
    reg [3:0]  m_ip;
    reg [15:0] m_cmp [0:3];
    reg        mv = 0;
    integer    n_wrap [0:15];           // full 16-bit wraps per scale (counter tick at 0xFFFF)
    integer    n_zc = 0, n_ignored = 0, n_below = 0, n_l3 = 0, n_cnt = 0, n_ipset = 0;
    integer    k, mod, tick;
    reg [3:0]  ge;
    reg        en, zr, wrap;   // wrap: statistics only (counter tick at 0xFFFF)
    initial for (k = 0; k < 16; k = k + 1) n_wrap[k] = 0;
    always @(posedge clk) begin
        if (rst) begin
            m_scale = 0; m_zc = 0; m_always = 0; m_ip = 0; m_pre = 0; m_s = 0;
            for (k = 0; k < 4; k = k + 1) m_cmp[k] = 16'hFFFF;
            mv = 1;
        end else if (mv) begin
            for (k = 0; k < 4; k = k + 1) ge[k] = (k < 2) && (m_s >= m_cmp[k]);
            en = m_always;
            mod = 1 << m_scale;
            tick = en && ((m_pre % mod) == mod - 1);
            zr = m_zc & ge[0];
            wrap = tick && (m_s == 65535);
            if (wrap) n_wrap[m_scale] = n_wrap[m_scale] + 1;
            if (zr && en) n_zc = n_zc + 1;
            if (sel & we & (addr == 4'd2)) begin m_pre = 0; m_s = 0; n_cnt = n_cnt + 1; end
            else if (zr) begin m_pre = 0; m_s = 0; end
            else if (en) begin m_pre = (m_pre + 1) % 32768; if (tick) m_s = (m_s + 1) % 65536; end
            if (sel & we & (addr == 4'd0) & be[3]) begin m_ip = wdata[31:28] & 4'b0011; n_l3 = n_l3 + 1; end
            else begin
                if ((ge & ~m_ip) != 0) n_ipset = n_ipset + 1;
                m_ip = ge;
            end
            if (sel & we & (addr == 4'd0) & be[0]) m_scale = wdata[3:0];
            if (sel & we & (addr == 4'd0) & be[1]) begin
                m_zc = wdata[9]; m_always = wdata[12];
                if (wdata[8] | wdata[13]) n_ignored = n_ignored + 1;
            end
            for (k = 0; k < 2; k = k + 1) if (sel & we & (addr == 4'd8 + k)) begin
                if (be[0]) m_cmp[k][7:0]  = wdata[7:0];
                if (be[1]) m_cmp[k][15:8] = wdata[15:8];
            end
        end
    end
    function [31:0] mrd(input [3:0] a);
        begin
            case (a)
                4'd0:  mrd = {m_ip, 12'b0, 2'b0, 1'b0, m_always, 2'b0, m_zc, 1'b0, 4'b0, m_scale[3:0]};
                4'd4:  mrd = 32'd0 + m_s[15:0];
                4'd8:  mrd = {16'b0, m_cmp[0]};
                4'd9:  mrd = {16'b0, m_cmp[1]};
                4'd10: mrd = {16'b0, m_cmp[2]};
                4'd11: mrd = {16'b0, m_cmp[3]};
                default: mrd = 32'd0;
            endcase
        end
    endfunction

    task fail(input [8*8-1:0] what, input [31:0] got, input [31:0] want);
        begin errors = errors + 1;
            if (errors < 20) $display("FAIL %0s cyc %0d: got %h want %h", what, cyc, got, want); end
    endtask

    // the reads: the address of the current cycle is read every clock (sel not required for a read)
    reg rd_en = 1;
    always @(posedge clk) if (mv) begin
        #2;  // after the posedge updates; the address changes only on negedges
        cyc = cyc + 1; checks = checks + 2;
        if (pwm_o !== m_ip) fail("pwm_o", pwm_o, m_ip);
        if (rdata !== mrd(addr)) fail("rdata", rdata, mrd(addr));
    end

    // ------------------------------------------------------------ directed helpers (drive on the negedge)
    task bus(input [3:0] a, input [31:0] d, input [3:0] b, input w);
        begin @(negedge clk); sel = 1; we = w; addr = a; wdata = d; be = b; end
    endtask
    task idle(input integer n);
        begin @(negedge clk); sel = 0; we = 0; repeat (n) @(negedge clk); end
    endtask
    task wr(input [3:0] a, input [31:0] d);   begin bus(a, d, 4'hF, 1); end endtask
    task wrb(input [3:0] a, input [31:0] d, input [3:0] b); begin bus(a, d, b, 1); end endtask
    task rd(input [3:0] a); begin bus(a, 32'hDEADBEEF, 4'hF, 0); end endtask
    task rdall;
        integer j;
        begin for (j = 0; j < 16; j = j + 1) rd(j); sel = 0; end
    endtask
    task cfg(input integer sc, input zc, input stk, input alw, input one);
        begin wr(4'd0, {4'd0, 12'b0, 2'b0, one, alw, 2'b0, zc, stk, 4'b0, sc[3:0]} & 32'h0FFFFFFF); end
    endtask

    // ---- oracle from Linux drivers/pwm/pwm-sifive.c (not from the RTL), rate = the chip clock (`CHIP_HZ, Makefile CHIP_HZ):
    //   scale = clamp(ilog2(period * rate / 1e9) - 16, 0, 15)   (apply: pwm_sifive_apply)
    //   frac  = min(duty * 65536 / period, 65535), cmp = 65535 - frac, CFG = EN_ALWAYS | scale
    // Pin polarity: pwm_o = ip, high while pwms >= cmp, so one period is 2^(16+scale) clocks and the pin
    // is high (65536 - cmp) << scale of them (cmp 0: always high; cmp 0xFFFF: one tick). Reset cmp = 0xFFFF.
    function integer drv_scale(input [63:0] period_ns);
        reg [63:0] t; integer l;
        begin
            t = (period_ns * `CHIP_HZ) / 1000000000;
            l = 0; while (t > 1) begin t = t >> 1; l = l + 1; end
            l = l - 16; if (l < 0) l = 0; if (l > 15) l = 15;
            drv_scale = l;
        end
    endfunction
    function integer drv_cmp(input [63:0] period_ns, input [63:0] duty_ns);
        reg [63:0] f;
        begin f = (duty_ns * 65536) / period_ns; if (f > 65535) f = 65535; drv_cmp = 65535 - f; end
    endfunction
    task chk_rd(input [3:0] a, input [31:0] want);
        begin
            rd(a); @(posedge clk); #1;
            checks = checks + 1;
            if (a == 4'd0) begin if ((rdata & 32'h0FFFFFFF) !== want) begin errors = errors + 1; $display("FAIL readback cfg: %h want %h", rdata, want); end end
            else if (rdata !== want) begin errors = errors + 1; $display("FAIL readback word %0d: %h want %h", a, rdata, want); end
        end
    endtask
    // one apply() as the driver does it, then (run) measure pwm_o over two periods
    integer hc, t_prev, t_first, t_second, nedge;
    task drv_one(input integer ch, input [63:0] period_ns, input [63:0] duty_ns, input run);
        integer sc, c, n, want, per;
        reg prev, r1;
        begin
            r1 = 0; ch = ch & 1;     // only channels 0 and 1 are built
            sc = drv_scale(period_ns); c = drv_cmp(period_ns, duty_ns);
            wr(4'd8 + ch, c);                              // PWMCMP
            wr(4'd0, (32'd1 << 12) | sc);                  // PWMCFG = EN_ALWAYS | scale (full word, others 0)
            chk_rd(4'd8 + ch, c);                          // get_state: duty = 0xFFFF - CMP
            chk_rd(4'd0, (32'd1 << 12) | sc);              // CFG: EN_ALWAYS, scale
            if (run) begin
                per = 1 << (16 + sc);
                n = 0; hc = 0; nedge = 0; prev = pwm_o[ch]; t_first = 0; t_second = 0;
                while (n < 2 * per + 64) begin
                    @(negedge clk); n = n + 1;
                    if (pwm_o[ch] && !prev) begin
                        nedge = nedge + 1;
                        if (nedge == 1) t_first = n; else if (nedge == 2) t_second = n;
                    end
                    if (nedge == 1) begin if (pwm_o[ch] && r1) hc = hc + 1; else r1 = 0; end
                    if (pwm_o[ch] && !prev && nedge == 1) begin r1 = 1; hc = 1; end
                    prev = pwm_o[ch];
                end
                want = (65536 - c) << sc;
                checks = checks + 2;
                if (c != 0) begin
                    if (nedge < 2 || (t_second - t_first) != per) begin
                        errors = errors + 1;
                        $display("FAIL period ch%0d sc%0d cmp %0d: %0d want %0d", ch, sc, c, t_second - t_first, per);
                    end
                    // hc counts the first high run only (until the first low after the first edge)
                    if (hc != want && want < per) begin
                        errors = errors + 1; $display("FAIL duty ch%0d sc%0d cmp %0d: high %0d want %0d", ch, sc, c, hc, want);
                    end
                end else if (nedge != 0 || !pwm_o[ch]) begin
                    errors = errors + 1; $display("FAIL cmp 0 not always high ch%0d", ch);
                end
            end
            wr(4'd0, 0); wr(4'd2, 0);
            wr(4'd8 + ch, 32'hFFFF);
            idle(4);
        end
    endtask

    integer ph, i2, tmr_n, e0;
    integer ch_i;
    task random_phase;
        reg [31:0] r, r2; integer sc2;
        begin
            ph = 0;
            repeat (ncyc) begin
                @(negedge clk);
                r = rnd(0);
                sel = (r[3:0] != 0); we = (r[7:5] == 0); be = r[11:8]; addr = r[15:12]; wdata = rnd(0);
                if (r[19:16] < 6) begin               // cmp writes biased to small values, so wraps happen
                    addr = 4'd8 + r[21:20]; wdata = rnd(0) % 64; we = 1; sel = 1; be = 4'h3;
                end
                if (r[19:16] == 6) begin               // config write, small scales, zerocmp mostly
                    addr = 0; we = 1; sel = 1; r2 = rnd(0);
                    sc2 = (r2[7:6] == 0) ? 10 : (r2[3:0] % 5);
                    wdata = {r2[31:28], 12'b0, 2'b0, r2[9], r2[10], 2'b0, (r2[13:12] != 0), r2[14], 4'b0, sc2[3:0]};
                    if (r2[17:16] != 0) be = 4'b0011; else be = r2[21:18];
                end
                if (r[19:16] == 7 && (r[31:28] == 1)) begin addr = 4'd2; we = 1; sel = 1; end
                if ((rnd(0) % 20000) == 0) rst = 1; else if (rst) rst = 0;
            end
            @(negedge clk); sel = 0; we = 0;
        end
    endtask

    integer miss, sc;
    initial begin
        if (!$value$plusargs("SEED=%d", seed)) seed = 1;
        if (!$value$plusargs("CYCLES=%d", ncyc)) ncyc = 600000;
        rs = 32'h9E3779B9 ^ (seed * 32'h85EBCA6B); if (rs == 0) rs = 1;
        repeat (3) @(negedge clk);
        rst = 0;
        // reset values, all words, wide (no stalls: rdata is combinational)
        rdall;
        // register map: scale, flags, ip lane 3, cmp lanes, WARL, pwms write ignored
        cfg(5, 1, 1, 0, 0); rdall; wr(4'd0, 0); wr(4'd4, 32'hFFFF); rdall;
        wrb(4'd8, 32'hAABBCCDD, 4'b0001); rd(4'd8); wrb(4'd8, 32'hAABBCCDD, 4'b0010); rd(4'd8);
        wrb(4'd8, 32'hAABBCCDD, 4'b1100); rd(4'd8); wr(4'd8, 32'hFFFF0123); rd(4'd8);
        wrb(4'd0, 32'hF0000000, 4'b1000); rd(4'd0); wrb(4'd0, 32'h00000000, 4'b1000); rd(4'd0);
        wrb(4'd0, 32'hFFFFFFFF, 4'b0111); rdall; wr(4'd0, 0);
        wr(4'd8, 32'hFFFF); wr(4'd9, 32'hFFFF); wr(4'd10, 32'hFFFF); wr(4'd11, 32'hFFFF);
        // reset readback from the datasheet: cmp 0xFFFF, cfg 0, pwmcount/pwms 0
        chk_rd(4'd0, 0); chk_rd(4'd2, 0); chk_rd(4'd4, 0);
        chk_rd(4'd8, 32'hFFFF); chk_rd(4'd9, 32'hFFFF); chk_rd(4'd10, 32'hFFFF); chk_rd(4'd11, 32'hFFFF);   // not built: 0xFFFF = duty 0 for pwm-sifive get_state
        // pwm-sifive.c sequence: 1 ms period -> scale 0; 100 ms -> scale 6; 30 s -> scale 14 (readback only)
        for (sc = 0; sc < 4; sc = sc + 1) begin
            drv_one(sc, 1000000, 0, 1);
            drv_one(sc, 1000000, 10000, 1);
            drv_one((sc + 1) % 4, 1000000, 500000, 1);
            drv_one((sc + 2) % 4, 1000000, 990000, 1);
            drv_one((sc + 3) % 4, 1000000, 1000000, 1);
        end
        drv_one(0, 4000000, 1000000, 1);                 // scale 1 (4 ms)
        drv_one(1, 8000000, 4000000, 1);                 // scale 2 (8 ms)
        drv_one(2, 100000000, 50000000, 0); chk_rd(4'd0, 0);   // scale 6, 100 ms: registers only
        wr(4'd10, 32'd32767); wr(4'd0, (32'd1 << 12) | 6); chk_rd(4'd0, (32'd1 << 12) | 6); wr(4'd0, 0); chk_rd(4'd10, 32'hFFFF); wr(4'd10, 32'hFFFF);   // a write to cmp2 is ignored
        drv_one(3, 30000000000, 7500000000, 0);          // scale 14, 30 s: registers only
        chk_rd(4'd0, 0);
        if (drv_scale(1000000) != 0 || drv_scale(100000000) != 6 || drv_scale(30000000000) != 14) begin
            errors = errors + 1; $display("FAIL oracle scales %0d %0d %0d", drv_scale(1000000), drv_scale(100000000), drv_scale(30000000000));
        end
        // cmp written below s: a running counter, cmp0 jumped under s, ip follows at once (a one-clock delay)
        wr(4'd8, 32'hFFFF); cfg(0, 0, 0, 1, 0); idle(200); wr(4'd9, 32'd3); wr(4'd9, 32'hFFFF); wr(4'd10, 32'd3); wr(4'd11, 32'd3); rd(4'd10); rd(4'd11); idle(5);
        wr(4'd0, 0); wr(4'd2, 0);
        // zerocmp timer (sticky is gone: ip follows the comparators), software clear on lane 3 (sb), period cmp0 * 2^scale + 1 clocks
        for (sc = 0; sc < 8; sc = sc + 1) begin
            wr(4'd8, 32'd5 + sc); wr(4'd2, 0);
            cfg(sc, 1, 1, 1, 0);
            idle(((5 + sc + 1) << sc) * 3 + 20);
            rd(4'd0);
            wrb(4'd0, 32'h0, 4'b1000); rd(4'd0); idle(3);        // lane-3 write of 0 sets ip
            wr(4'd0, 0); wrb(4'd0, 32'h0, 4'b1000); idle(2);
        end
        // zerocmp timer, cfg bits 8 and 13 written 0
        wr(4'd2, 0); wr(4'd8, 32'd7); wr(4'd9, 32'd2); cfg(0, 1, 0, 1, 0); idle(400); wr(4'd0, 0);
        // slim-down: bits 8 (sticky) and 13 (oneshot) read 0 and ignore writes; a oneshot write does not start the counter
        for (sc = 0; sc < 7; sc = sc + 1) begin
            wr(4'd8, 32'd3); wr(4'd2, 0); cfg(sc, 1, 0, 0, 1); idle(((3 + 1) << sc) * 2 + 30); chk_rd(4'd0, (32'd1 << 9) | sc); chk_rd(4'd4, 0);
        end
        wr(4'd0, 32'h0000_2100); chk_rd(4'd0, 0); wr(4'd0, 32'h0000_3300); chk_rd(4'd0, 32'h0000_1200); wr(4'd0, 0);
        wr(4'd8, 32'hFFFF); wr(4'd2, 0); cfg(0, 0, 1, 0, 1); idle(100); chk_rd(4'd0, 0); chk_rd(4'd4, 0);
        // pwmcount write restarts (also in the same clock as a tick)
        cfg(0, 0, 0, 1, 0); idle(1000); wr(4'd2, 0); rd(4'd4); idle(3); wr(4'd2, 32'h1234); rd(4'd4); wr(4'd0, 0);
        // in reset: registers return
        wr(4'd8, 32'h0044); wr(4'd0, 32'h3000); idle(10); rst = 1; idle(3); rst = 0; rdall;
        random_phase;
        idle(4);
        miss = 0;
        if (n_wrap[0] < 1 || n_wrap[1] < 1 || n_wrap[2] < 1) miss = miss + 1;
        if (n_zc < 20) miss = miss + 1;
        if (n_ignored < 20) miss = miss + 1;
        if (n_l3 < 10 || n_cnt < 10 || n_ipset < 20) miss = miss + 1;
        if (errors == 0 && miss == 0)
            $display("PASS tb_pwm (%0d checks, %0d zerocmp periods, %0d ignored sticky/oneshot writes, %0d wraps, seed %0d)",
                     checks, n_zc, n_ignored, n_wrap[0] + n_wrap[1] + n_wrap[2], seed);
        else
            $display("FAIL tb_pwm: %0d errors, %0d coverage floors missed (wraps %0d %0d %0d zc %0d ign %0d l3 %0d cnt %0d ipset %0d) (seed %0d)",
                     errors, miss, n_wrap[0], n_wrap[1], n_wrap[2], n_zc, n_ignored, n_l3, n_cnt, n_ipset, seed);
        $finish;
    end
    initial begin #4000000000; $display("TIMEOUT tb_pwm"); $finish; end
endmodule
