`timescale 1ns / 1ps
// gamepad (src/gamepad.v) against a cycle model written from the WO-53 specification, fed by an
// asynchronous TinyTapeout Gamepad Pmod model (100 kHz +-5 % clock, data set half a period before each
// rising clock, latch after the last bit, random report gaps, random phase against clk) through a
// two-flop synchroniser, as gpio has. The cycle model predicts GAMEPAD, GPSTAT and irq on every clock.
// An independent frame oracle (what the Pmod sent: 12 or 24 bits load pad 0 from the last 12 bits, pad 1
// is not kept and reads 0, any other count is ignored) checks the model's loaded value after every frame.
// Seeded (+SEED=, +FRAMES=), floors enforced, bus reads/writes random on every clock.
module tb_gamepad;
    reg         clk = 0, rst = 1, sel = 0, we = 0, addr2 = 0;
    reg  [3:0]  be = 0;
    reg  [31:0] wdata = 0;
    reg         latch_a = 0, pclk_a = 0, data_a = 0;
    reg         l1 = 0, l2 = 0, p1 = 0, p2 = 0, d1 = 0, d2 = 0;
    wire [31:0] rdata;
    wire        irq;
    gamepad uut (.clk(clk), .rst(rst), .sel(sel), .we(we), .be(be), .addr2(addr2), .wdata(wdata),
                 .rdata(rdata), .latch_s(l2), .pclk_s(p2), .data_s(d2), .irq(irq));
    always #8 clk = ~clk;                         // 62.5 MHz
    always @(posedge clk) begin l1 <= latch_a; l2 <= l1; p1 <= pclk_a; p2 <= p1; d1 <= data_a; d2 <= d1; end

    integer seed = 1, nframes = 140, checks = 0, errors = 0, cyc = 0;
    reg [31:0] rs;
    function [31:0] rnd(input integer dummy);
        begin rs = rs ^ (rs << 13); rs = rs ^ (rs >> 17); rs = rs ^ (rs << 5); rnd = rs; end
    endfunction

    // ------------------------------------------------------------ cycle model (from the spec text)
    reg        mv = 0, m_pp, m_lp, m_chg, m_ie;
    integer    m_nb;
    reg [11:0] m_sh, m_d;
    reg        pr, lr, ldn, w1c;
    reg [11:0] dn;
    integer    n_load = 0, n_chg = 0, n_ign = 0, n_race = 0, n_same = 0, n_abs = 0, n_12 = 0, n_ident = 0;
    always @(posedge clk) begin
        if (rst) begin
            m_pp = 0; m_lp = 0; m_chg = 0; m_ie = 0; m_nb = 0; m_sh = 12'hFFF; m_d = 12'hFFF; mv = 1;
        end else if (mv) begin
            pr = p2 & ~m_pp; lr = l2 & ~m_lp;
            ldn = lr && (m_nb == 24 || m_nb == 12);
            dn = m_sh;
            w1c = sel & we & be[0] & addr2 & wdata[0];
            if (lr && !ldn) n_ign = n_ign + 1;
            if (ldn) begin
                n_load = n_load + 1;
                if (m_nb == 12) n_12 = n_12 + 1;
                if (dn != m_d) n_chg = n_chg + 1; else n_ident = n_ident + 1;
                if (dn == 12'hFFF) n_abs = n_abs + 1;
                if (w1c) n_race = n_race + 1;
                if (pr) n_same = n_same + 1;
            end
            if (pr) m_sh = {m_sh[10:0], d2};
            if (lr) m_nb = 0; else if (pr && m_nb != 31) m_nb = m_nb + 1;
            if (ldn && dn != m_d) m_chg = 1; else if (w1c) m_chg = 0;
            if (ldn) m_d = dn;
            if (sel & we & be[0] & addr2) m_ie = wdata[1];
            m_pp = p2; m_lp = l2;
        end
    end
    function [31:0] mrd(input a2);
        reg pr0;
        begin
            pr0 = (m_d != 12'hFFF);
            if (a2) mrd = {30'b0, m_ie, m_chg};
            else mrd = {16'h0, pr0, 3'b0, pr0 ? m_d : 12'h0};
        end
    endfunction

    task fail(input [8*8-1:0] what, input [31:0] got, input [31:0] want);
        begin errors = errors + 1;
            if (errors < 20) $display("FAIL %0s cyc %0d: got %h want %h", what, cyc, got, want); end
    endtask

    // ------------------------------------------------------------ bus: compare, then drive, on the negedge
    reg [31:0] r;
    always @(negedge clk) begin
        cyc = cyc + 1;
        if (mv) begin
            checks = checks + 2;
            if (rdata !== mrd(addr2)) fail("rdata", rdata, mrd(addr2));
            if (irq !== (m_chg & m_ie)) fail("irq", irq, m_chg & m_ie);
        end
        r = rnd(0);
        sel = (r[1:0] != 0); addr2 = r[2]; we = (r[7:4] == 0); be = r[11:8]; wdata = rnd(0);
        if (r[15:12] == 0) begin we = 1; sel = 1; addr2 = 1; be[0] = 1; wdata[1] = (r[19:16] != 0); wdata[0] = 0; end   // IE set, mostly on
        // race a W1C against a load that happens at the next posedge
        if (mv && !rst && l2 && !m_lp && (m_nb == 12 || m_nb == 24) && r[20]) begin
            sel = 1; we = 1; addr2 = 1; be[0] = 1; wdata[0] = 1;
        end
        if (!rst && !(l2 && !m_lp) && !(p2 && !m_pp) && r[27:21] == 0) begin   // plain W1C
            sel = 1; we = 1; addr2 = 1; be[0] = 1; wdata[0] = 1;
        end
    end

    // ------------------------------------------------------------ Pmod model and frame oracle
    reg [63:0] v, vlast;
    reg [11:0] o_d = 12'hFFF;
    integer half, nb, i, n_frames = 0, kind, gapc;
    reg        same_cycle;
    reg [11:0] pa, pb;
    integer eff;
    task frame(input integer n, input [63:0] val, input sc);
        begin
            // sc: latch rises together with the last clock edge (same synchroniser cycle)
            #(rnd(0) % 16000 / 1000.0);
            for (i = 0; i < n; i = i + 1) begin
                half = 4750 + rnd(0) % 500;
                data_a = val[n-1-i];
                #(half / 2.0 * 2.0);
                pclk_a = 1;
                if (sc && i == n - 1) latch_a = 1;
                #(half);
                pclk_a = 0;
            end
            if (sc) begin #(1500); latch_a = 0; end
            else begin
                #(200 + rnd(0) % 2000); latch_a = 1; #(1000 + rnd(0) % 3000); latch_a = 0;
            end
            // oracle: what a loaded frame is; the same-cycle latch sees one bit fewer and the stream shifted
            eff = sc ? n - 1 : n;
            if (eff == 24 || eff == 12) o_d = sc ? val[12:1] : val[11:0];
            repeat (12) @(posedge clk);
            @(negedge clk);
            checks = checks + 1;
            if (m_d !== o_d) begin errors = errors + 1; if (errors < 20) $display("FAIL oracle frame %0d (n=%0d sc=%0d): d %h want %h", n_frames, n, sc, m_d, o_d); end
            n_frames = n_frames + 1;
            if (sc) n_same = n_same + 0;
        end
    endtask
    task mkpad(output [11:0] p);
        begin p = rnd(0); if ((rnd(0) % 8) == 0) p = 12'hFFF; if ((rnd(0) % 8) == 0) p = 12'h000; end
    endtask

    integer miss;
    initial begin
        if (!$value$plusargs("SEED=%d", seed)) seed = 1;
        if (!$value$plusargs("FRAMES=%d", nframes)) nframes = 140;
        rs = 32'h9E3779B9 ^ (seed * 32'h85EBCA6B); if (rs == 0) rs = 1;
        vlast = 0;
        repeat (4) @(negedge clk);
        rst = 0;
        repeat (20) @(negedge clk);
        for (kind = 0; kind < nframes; kind = kind + 1) begin
            mkpad(pa); mkpad(pb);
            v = {rnd(0), rnd(0)};
            case (rnd(0) % 16)
                0, 1, 2, 3, 4, 5: begin v[23:0] = {pb, pa}; frame(24, v, 0); end                 // full frame
                6, 7: begin v[11:0] = pa; frame(12, v, 0); end                                   // single pad
                8: begin v[23:0] = vlast[23:0]; frame(24, v, 0); end                             // identical frame
                9: begin v[23:0] = {12'hFFF, 12'hFFF}; frame(24, v, 0); end                      // both absent
                10: begin frame(1 + rnd(0) % 11, v, 0); end                                      // partial (short)
                11: begin frame(13 + rnd(0) % 11, v, 0); end                                     // partial (13..23)
                12: begin frame(25 + rnd(0) % 16, v, 0); end                                     // long (25..40, nb saturates)
                13: begin v[23:0] = {pb, pa}; frame(24, v, 1); end                               // latch with last clock: ignored
                14: begin v[24:1] = {pb, pa}; frame(25, v, 1); end                               // ... so 25 bits load
                15: begin frame(0, v, 0); end                                                    // latch alone
            endcase
            if (kind % 7 != 6) vlast = v;
            // report gap 0.2 .. 2 ms (mostly the short end)
            if (rnd(0) % 5 == 0) #(200000 + rnd(0) % 1800000); else #(200000 + rnd(0) % 100000);
            if (kind % 37 == 36) begin @(negedge clk); rst = 1; o_d = 12'hFFF; @(negedge clk); @(negedge clk); rst = 0; end
        end
        // floors continue with extra full frames if one is short
        while (n_load < 100 || n_chg < 20 || n_ign < 10 || n_race < 5 || n_same < 1 || n_abs < 5 || n_12 < 10) begin
            mkpad(pa); mkpad(pb); v = {rnd(0), rnd(0)}; v[23:0] = {pb, pa}; frame(24, v, 0);
            if (n_ign < 10) frame(7, v, 0);
            if (n_12 < 10) frame(12, v, 0);
            #(200000);
        end
        repeat (30) @(negedge clk);
        miss = 0;
        if (n_load < 100 || n_chg < 20 || n_ign < 10) miss = 1;
        if (errors == 0 && miss == 0)
            $display("PASS tb_gamepad (%0d checks, %0d loads, %0d changes, %0d ignored, %0d raced W1C, seed %0d)",
                     checks, n_load, n_chg, n_ign, n_race, seed);
        else
            $display("FAIL tb_gamepad: %0d errors, %0d floors missed (seed %0d)", errors, miss, seed);
        $finish;
    end
    initial begin #3000000000; $display("TIMEOUT tb_gamepad"); $finish; end
endmodule
