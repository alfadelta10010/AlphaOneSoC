`timescale 1ns / 1ps
// audio (src/audio.v) against a cycle model written from the WO-55 specification: three square voices
// (f = clk/16 / 2^O / (2(P+1))), a 15-bit maximal LFSR noise source, a 4-bit-per-source linear mixer
// (level = 4 * sum, or the PCM byte), a latched level and an 8-bit PWM DAC with a 256-clock frame.
// audio_o and every read word are compared every clock. Independent checks on top of the model: a
// maximal-length reference LFSR (32767 states) that the model's noise state must follow, and the exact
// number of high clocks of audio_o in every DAC frame (= the level latched at the end of the previous
// frame). Directed phases, then a seeded random phase (+SEED=, +CYCLES=) with floors.
module tb_audio;
    reg         clk = 0, rst = 1, sel = 0, we = 0;
    reg  [3:0]  be = 0;
    reg  [4:2]  addr = 0;
    reg  [31:0] wdata = 0;
    wire [31:0] rdata;
    wire        audio_o;
    audio uut (.clk(clk), .rst(rst), .sel(sel), .we(we), .be(be), .addr(addr), .wdata(wdata),
               .rdata(rdata), .audio_o(audio_o));
    always #5 clk = ~clk;

    integer seed = 1, ncyc = 400000, checks = 0, errors = 0, cyc = 0;
    reg [31:0] rs;
    function [31:0] rnd(input integer dummy);
        begin rs = rs ^ (rs << 13); rs = rs ^ (rs >> 17); rs = rs ^ (rs << 5); rnd = rs; end
    endfunction

    // ------------------------------------------------------------ reference LFSR (x^15 + x^14 + 1)
    reg [14:0] rl;
    integer rn, rperiod;
    task ref_period;
        reg [14:0] x; integer n; reg done;
        begin
            x = 15'd1; n = 0; done = 0;
            while (!done) begin
                x = {x[0] ^ x[1], x[14:1]}; n = n + 1;
                if (x == 15'd1) done = 1;
                if (n > 40000) done = 1;
            end
            rperiod = n;
        end
    endtask

    // ------------------------------------------------------------ model
    integer m_pre;
    integer m_per [0:2], m_oct [0:2], m_vol [0:2], m_c [0:2];
    reg     m_q [0:2];
    integer m_nrate, m_nvol, m_dc, m_lvl, m_smp;
    reg     m_en, m_pcm, m_ao;
    reg [14:0] m_l;
    integer m_nsteps;                 // LFSR steps since reset/enable (follows the reference)
    integer v, mod, tk, nt, lvl_nx, sum;
    reg     mv = 0;
    integer tog [0:23];               // voice*8 + octave: toggles
    integer n_pcm [0:3];              // frames with PCM 0x00, 0x01, 0x80, 0xFF
    integer n_noise_steps = 0, n_frames = 0, n_enoff = 0;
    initial begin
        for (v = 0; v < 24; v = v + 1) tog[v] = 0;
        for (v = 0; v < 4; v = v + 1) n_pcm[v] = 0;
    end
    always @(posedge clk) begin
        if (rst) begin
            for (v = 0; v < 3; v = v + 1) begin m_per[v] = 0; m_oct[v] = 0; m_vol[v] = 0; m_c[v] = 0; m_q[v] = 0; end
            m_nrate = 0; m_nvol = 0; m_en = 0; m_pcm = 0; m_smp = 0; m_pre = 0; m_l = 15'd1; m_dc = 0; m_lvl = 0;
            m_ao = 0; m_nsteps = 0; rl = 15'd1; mv = 1;
        end else if (mv) begin
            // outputs of this clock use the state before it
            sum = (m_q[0] ? m_vol[0] : 0) + (m_q[1] ? m_vol[1] : 0) + (m_q[2] ? m_vol[2] : 0) + (m_l[0] ? m_nvol : 0);
            lvl_nx = m_pcm ? m_smp : sum * 4;
            m_ao = m_en && (m_dc < m_lvl);
            if (m_en) begin
                for (v = 0; v < 3; v = v + 1) begin
                    mod = 1 << m_oct[v];
                    tk = ((m_pre % 16) == 15) && (((m_pre / 16) % mod) == mod - 1);
                    if (tk) begin
                        if (m_c[v] == 0) begin
                            m_c[v] = m_per[v]; m_q[v] = ~m_q[v];
                            tog[v*8 + m_oct[v]] = tog[v*8 + m_oct[v]] + 1;
                        end else m_c[v] = m_c[v] - 1;
                    end
                end
                mod = 1 << m_nrate;
                nt = ((m_pre % 16) == 15) && (((m_pre / 16) % mod) == mod - 1);
                if (nt) begin
                    m_l = {m_l[0] ^ m_l[1], m_l[14:1]};
                    rl = {rl[0] ^ rl[1], rl[14:1]};
                    m_nsteps = m_nsteps + 1; n_noise_steps = n_noise_steps + 1;
                end
                if (m_dc == 255) begin
                    m_lvl = lvl_nx; n_frames = n_frames + 1;
                    if (m_pcm) begin
                        if (m_smp == 0) n_pcm[0] = n_pcm[0] + 1;
                        if (m_smp == 1) n_pcm[1] = n_pcm[1] + 1;
                        if (m_smp == 128) n_pcm[2] = n_pcm[2] + 1;
                        if (m_smp == 255) n_pcm[3] = n_pcm[3] + 1;
                    end
                end
                m_pre = (m_pre + 1) % 2048;
                m_dc = (m_dc + 1) % 256;
            end else begin
                for (v = 0; v < 3; v = v + 1) begin m_c[v] = 0; m_q[v] = 0; end
                m_pre = 0; m_l = 15'd1; rl = 15'd1; m_nsteps = 0; m_dc = 0; m_lvl = 0;
            end
            // register writes (take effect after this clock's state update)
            if (sel & we) begin
                for (v = 0; v < 3; v = v + 1) if (addr == v) begin
                    if (be[0]) m_per[v] = (m_per[v] & 32'hF00) | wdata[7:0];
                    if (be[1]) begin m_per[v] = (m_per[v] & 32'h0FF) | (wdata[11:8] << 8); m_oct[v] = wdata[14:12]; end
                    if (be[2]) m_vol[v] = wdata[19:16];
                end
                if (addr == 3) begin if (be[0]) m_nrate = wdata[2:0]; if (be[2]) m_nvol = wdata[19:16]; end
                if (addr == 4 && be[0]) begin
                    if (m_en && !wdata[0]) n_enoff = n_enoff + 1;
                    m_en = wdata[0]; m_pcm = wdata[1];
                end
                if (addr == 5 && be[0]) m_smp = wdata[7:0];
            end
        end
    end
    function [31:0] mrd(input [4:2] a);
        begin
            case (a)
                3'd0: mrd = {12'b0, m_vol[0][3:0], 1'b0, m_oct[0][2:0], m_per[0][11:0]};
                3'd1: mrd = {12'b0, m_vol[1][3:0], 1'b0, m_oct[1][2:0], m_per[1][11:0]};
                3'd2: mrd = {12'b0, m_vol[2][3:0], 1'b0, m_oct[2][2:0], m_per[2][11:0]};
                3'd3: mrd = {12'b0, m_nvol[3:0], 13'b0, m_nrate[2:0]};
                3'd4: mrd = {30'b0, m_pcm, m_en};
                3'd5: mrd = {24'b0, m_smp[7:0]};
                default: mrd = 32'd0;
            endcase
        end
    endfunction

    task fail(input [8*8-1:0] what, input [31:0] got, input [31:0] want);
        begin errors = errors + 1;
            if (errors < 20) $display("FAIL %0s cyc %0d: got %h want %h", what, cyc, got, want); end
    endtask

    // per-frame high clocks. The DAC output of clock n comes from dc of clock n-1; frame = dc 0..255.
    integer hc = 0, fr_dc = -1, fr_lvl = 0, fr_ok = 0;
    integer prev_dc, prev_lvl, prev_en;
    always @(posedge clk) if (mv) begin
        #2;  // after the posedge updates; the address changes only on negedges
        cyc = cyc + 1; checks = checks + 2;
        if (audio_o !== m_ao) fail("audio_o", audio_o, m_ao);
        if (rdata !== mrd(addr)) fail("rdata", rdata, mrd(addr));
        // the model's LFSR must follow the independent reference; a frame must hold exactly lvl highs
        if (m_en && m_l !== rl) fail("lfsr", m_l, rl);
        checks = checks + 1;
    end
    // frame accounting, sampled at the same edge as the model (blocking: reads the model's post-update dc)
    // the clock that just ended consumed dc = (m_dc - 1) mod 256 with the lvl then current
    integer cdc, clvl;
    always @(negedge clk) if (mv && m_en) begin
        cdc = (m_dc + 255) % 256;
        // lvl consumed at that clock: m_lvl unless that clock was dc == 255 (lvl updated after use)
        clvl = (cdc == 255) ? fr_lvl : m_lvl;
        if (cdc == 0) begin hc = 0; fr_lvl = m_lvl; fr_ok = 1; end
        hc = hc + audio_o;
        if (cdc == 255 && fr_ok) begin
            checks = checks + 1;
            if (hc != fr_lvl) begin errors = errors + 1; if (errors < 20) $display("FAIL frame cyc %0d: high %0d want %0d", cyc, hc, fr_lvl); end
        end
    end else begin fr_ok = 0; hc = 0; end

    // ------------------------------------------------------------ directed helpers
    task bus(input [4:2] a, input [31:0] d, input [3:0] b, input w);
        begin @(negedge clk); sel = 1; we = w; addr = a; wdata = d; be = b; end
    endtask
    task idle(input integer n);
        begin @(negedge clk); sel = 0; we = 0; repeat (n) @(negedge clk); end
    endtask
    task wr(input [4:2] a, input [31:0] d); begin bus(a, d, 4'hF, 1); end endtask
    task wrb(input [4:2] a, input [31:0] d, input [3:0] b); begin bus(a, d, b, 1); end endtask
    task rd(input [4:2] a); begin bus(a, 32'hDEADBEEF, 4'hF, 0); end endtask
    task rdall; integer j; begin for (j = 0; j < 8; j = j + 1) rd(j); sel = 0; end endtask
    function [31:0] tone(input [3:0] vol, input [2:0] o, input [11:0] p);
        begin tone = {12'b0, vol, 1'b0, o, p}; end
    endfunction

    integer o1, i1, m;
    task random_phase;
        reg [31:0] r, r2;
        begin
            repeat (ncyc) begin
                @(negedge clk);
                r = rnd(0);
                sel = (r[3:0] != 0); we = (r[6:4] == 0); be = r[10:7]; addr = r[13:11]; wdata = rnd(0);
                if (r[16:14] == 0 && addr != 3'd4) begin
                    // small periods, the low octaves, so toggles happen
                    r2 = rnd(0);
                    if (addr < 3) wdata = tone(r2[3:0], r2[6:4] % 4, r2[10:7] % 6);
                    be = (r2[12:11] == 0) ? rnd(0) : 4'b0011 | (r2[13] ? 4'b0100 : 0);
                end
                if (r[19:17] == 0 && !(r[27:24] == 0)) begin     // CTRL: mostly on
                    addr = 3'd4; we = 1; sel = 1; be = 4'h1; wdata = {30'b0, r[24], (r[23:20] != 0)};
                end
                if (r[19:17] == 1) begin addr = 3'd5; we = 1; sel = 1; be = 4'h1; wdata = (r[23:20] == 0) ? 32'hFF : (r[23:20] == 1) ? 32'h0 : rnd(0); end
                if ((rnd(0) % 60000) == 0) rst = 1; else if (rst) rst = 0;
            end
            @(negedge clk); sel = 0; we = 0;
        end
    endtask

    integer miss, vtog_ok, vv, oo, nref;
    reg [14:0] xs;
    initial begin
        if (!$value$plusargs("SEED=%d", seed)) seed = 1;
        if (!$value$plusargs("CYCLES=%d", ncyc)) ncyc = 400000;
        rs = 32'h9E3779B9 ^ (seed * 32'h85EBCA6B); if (rs == 0) rs = 1;
        ref_period;
        checks = checks + 1;
        if (rperiod != 32767) begin errors = errors + 1; $display("FAIL reference LFSR period %0d", rperiod); end
        repeat (3) @(negedge clk);
        rst = 0;
        rdall;
        // register map: lanes, WARL, reserved words
        wr(3'd0, 32'hFFFFFFFF); rd(3'd0); wr(3'd1, 32'h00A5C3E1); rd(3'd1); wrb(3'd2, 32'h11223344, 4'b0100); rd(3'd2);
        wrb(3'd2, 32'h11223344, 4'b0010); rd(3'd2); wrb(3'd2, 32'h11223344, 4'b0001); rd(3'd2);
        wrb(3'd2, 32'h11223344, 4'b1000); rd(3'd2);
        wr(3'd3, 32'hFFFFFFFF); rd(3'd3); wr(3'd4, 32'hFFFFFFFF); rd(3'd4); wr(3'd5, 32'hFFFFFFFF); rd(3'd5);
        wr(3'd6, 32'hFFFFFFFF); rd(3'd6); rd(3'd7);
        wr(3'd4, 0); wr(3'd0, 0); wr(3'd1, 0); wr(3'd2, 0); wr(3'd3, 0);
        // tones: every voice at octaves 0..3 (one per round), small periods, EN on
        for (o1 = 0; o1 < 4; o1 = o1 + 1) begin
            wr(3'd0, tone(4'd15, o1, 12'd0)); wr(3'd1, tone(4'd7, (o1 + 1) % 4, 12'd1)); wr(3'd2, tone(4'd3, (o1 + 2) % 4, 12'd2));
            wr(3'd4, 32'd1);
            idle(80 * 16 * 2 * (1 << 3) * 3 + 100);
            wr(3'd4, 32'd0); idle(5);
        end
        // big octave and period (12-bit P written in two lanes)
        wr(3'd0, tone(4'd9, 3'd7, 12'hABC)); rd(3'd0);
        wr(3'd0, tone(4'd9, 3'd5, 12'd3)); wr(3'd1, tone(4'd5, 3'd6, 12'd0)); wr(3'd4, 32'd1); idle(40000);
        // a new P takes effect at the next reload; EN off/on
        wr(3'd0, tone(4'd15, 3'd0, 12'd40)); idle(3000); wr(3'd0, tone(4'd15, 3'd0, 12'd2)); idle(3000);
        wr(3'd4, 0); idle(50); wr(3'd4, 1); idle(2000);
        // noise: every rate, other voices muted; the per-frame highs check the level
        wr(3'd0, 0); wr(3'd1, 0); wr(3'd2, 0);
        for (m = 0; m < 8; m = m + 1) begin wr(3'd3, {12'b0, 4'd15, 13'b0, m[2:0]}); idle(256 * 70 + 100); end
        // the whole noise period at rate 0 (32767 states * 16 clocks)
        wr(3'd4, 0); idle(3); wr(3'd3, {12'b0, 4'd9, 13'b0, 3'd0}); wr(3'd4, 1);
        nref = 0;
        idle(32767 * 16 + 4000);
        // mixer: all four sources, a range of volumes
        wr(3'd0, tone(4'd15, 3'd0, 12'd0)); wr(3'd1, tone(4'd8, 3'd0, 12'd1)); wr(3'd2, tone(4'd1, 3'd1, 12'd0));
        wr(3'd3, {12'b0, 4'd14, 13'b0, 3'd1}); idle(256 * 80);
        // PCM: frames at 0x00, 0x01, 0x80, 0xFF and mid values
        wr(3'd4, 32'd3);
        wr(3'd5, 0);   idle(256 * 4);
        wr(3'd5, 1);   idle(256 * 4);
        wr(3'd5, 128); idle(256 * 4);
        wr(3'd5, 255); idle(256 * 4);
        wr(3'd5, 7); idle(256 * 3); wr(3'd5, 200); idle(256 * 3); wr(3'd4, 32'd1); idle(256 * 3);
        wr(3'd4, 32'd0); idle(600); rd(3'd4);
        random_phase;
        idle(4);
        miss = 0;
        for (vv = 0; vv < 3; vv = vv + 1) begin
            vtog_ok = 0;
            for (oo = 0; oo < 8; oo = oo + 1) if (tog[vv*8 + oo] >= 50) vtog_ok = vtog_ok + 1;
            if (vtog_ok < 3) begin miss = miss + 1; $display("floor: voice %0d toggles >= 50 at %0d octaves", vv, vtog_ok); end
        end
        for (vv = 0; vv < 4; vv = vv + 1) if (n_pcm[vv] < 2) begin miss = miss + 1; $display("floor: PCM value %0d frames %0d", vv, n_pcm[vv]); end
        if (n_noise_steps < 32767) begin miss = miss + 1; $display("floor: noise steps %0d", n_noise_steps); end
        if (n_enoff < 3) miss = miss + 1;
        if (errors == 0 && miss == 0)
            $display("PASS tb_audio (%0d checks, %0d frames, %0d noise steps, seed %0d)", checks, n_frames, n_noise_steps, seed);
        else
            $display("FAIL tb_audio: %0d errors, %0d coverage floors missed (seed %0d)", errors, miss, seed);
        $finish;
    end
    initial begin #4000000000; $display("TIMEOUT tb_audio"); $finish; end
endmodule
