`timescale 1ns / 1ps
// audio (src/audio.v) against a cycle model written from the WO-63 specification: one square voice
// (f = clk/16 / 2^O / (2(P+1))), TONE0 at 0x00 = {O, P}, CTRL at 0x10 bit 0 = EN, every other offset and bit reads
// 0 and ignores writes. audio_o is the voice's square flop (0 while EN is low). audio_o and every read word are
// compared every clock. Independent checks on top of the model: the measured toggle period of the Tetris notes
// (Korobeiniki table in audio.v) against 16 * 2^O * 2 * (P + 1) clocks, and that EN = 0 holds the pin low and
// restarts the counters. Directed phases, then a seeded random phase (+SEED=, +CYCLES=) with floors.
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

    // ------------------------------------------------------------ model
    integer m_pre, m_per, m_oct, m_c, mod, tk;
    reg     m_q, m_en;
    reg     mv = 0;
    integer tog [0:7];                // toggles per octave
    integer n_enoff = 0;
    initial begin : ini integer v; for (v = 0; v < 8; v = v + 1) tog[v] = 0; end
    always @(posedge clk) begin
        if (rst) begin
            m_per = 0; m_oct = 0; m_c = 0; m_q = 0; m_en = 0; m_pre = 0; mv = 1;
        end else if (mv) begin
            if (m_en) begin
                mod = 1 << m_oct;
                tk = ((m_pre % 16) == 15) && (((m_pre / 16) % mod) == mod - 1);
                if (tk) begin
                    if (m_c == 0) begin m_c = m_per; m_q = ~m_q; tog[m_oct] = tog[m_oct] + 1; end
                    else m_c = m_c - 1;
                end
                m_pre = (m_pre + 1) % 2048;
            end else begin m_c = 0; m_q = 0; m_pre = 0; end
            if (sel & we) begin
                if (addr == 0) begin
                    if (be[0]) m_per = (m_per & 32'hF00) | wdata[7:0];
                    if (be[1]) begin m_per = (m_per & 32'h0FF) | (wdata[11:8] << 8); m_oct = wdata[14:12]; end
                end
                if (addr == 4 && be[0]) begin
                    if (m_en && !wdata[0]) n_enoff = n_enoff + 1;
                    m_en = wdata[0];
                end
            end
        end
    end
    function [31:0] mrd(input [4:2] a);
        begin
            case (a)
                3'd0: mrd = {17'b0, m_oct[2:0], m_per[11:0]};
                3'd4: mrd = {31'b0, m_en};
                default: mrd = 32'd0;
            endcase
        end
    endfunction

    task fail(input [8*8-1:0] what, input [31:0] got, input [31:0] want);
        begin errors = errors + 1;
            if (errors < 20) $display("FAIL %0s cyc %0d: got %h want %h", what, cyc, got, want); end
    endtask

    always @(posedge clk) if (mv) begin
        #2;  // after the posedge updates; the address changes only on negedges
        cyc = cyc + 1; checks = checks + 2;
        if (audio_o !== m_q) fail("audio_o", audio_o, m_q);
        if (rdata !== mrd(addr)) fail("rdata", rdata, mrd(addr));
    end

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
    function [31:0] tone(input [2:0] o, input [11:0] p);
        begin tone = {17'b0, o, p}; end
    endfunction

    // measured period of audio_o: clocks between two rising edges, after the tone settled
    integer last_rise, per_meas, nedge;
    reg ao_d = 0;
    always @(posedge clk) begin
        ao_d <= audio_o;
        if (audio_o && !ao_d) begin
            if (last_rise >= 0) per_meas = cyc - last_rise;
            last_rise = cyc; nedge = nedge + 1;
        end
    end
    integer n_notes = 0;
    task note(input [2:0] o, input [11:0] p);
        integer want;
        begin
            wr(3'd4, 0); idle(3); wr(3'd0, tone(o, p)); last_rise = -1; per_meas = 0; nedge = 0; wr(3'd4, 1);
            idle(32 * (1 << o) * (p + 1) * 3 + 400);      // three periods
            want = 16 * (1 << o) * 2 * (p + 1);
            checks = checks + 1; n_notes = n_notes + 1;
            if (per_meas != want) begin errors = errors + 1; $display("FAIL note O=%0d P=%0d: period %0d want %0d", o, p, per_meas, want); end
        end
    endtask

    integer o1, miss, oo, nok;
    task random_phase;
        reg [31:0] r, r2;
        begin
            repeat (ncyc) begin
                @(negedge clk);
                r = rnd(0);
                sel = (r[3:0] != 0); we = (r[6:4] == 0); be = r[10:7]; addr = r[13:11]; wdata = rnd(0);
                if (r[16:14] == 0 && addr != 3'd4) begin
                    r2 = rnd(0);
                    if (addr == 0) wdata = tone(r2[6:4] % 4, r2[10:7] % 6);
                    be = (r2[12:11] == 0) ? rnd(0) : 4'b0011;
                end
                if (r[19:17] == 0 && !(r[27:24] == 0)) begin     // CTRL: mostly on
                    addr = 3'd4; we = 1; sel = 1; be = 4'h1; wdata = {30'b0, r[24], (r[23:20] != 0)};
                end
                if ((rnd(0) % 60000) == 0) rst = 1; else if (rst) rst = 0;
            end
            @(negedge clk); sel = 0; we = 0;
        end
    endtask

    initial begin
        if (!$value$plusargs("SEED=%d", seed)) seed = 1;
        if (!$value$plusargs("CYCLES=%d", ncyc)) ncyc = 400000;
        rs = 32'h9E3779B9 ^ (seed * 32'h85EBCA6B); if (rs == 0) rs = 1;
        last_rise = -1; per_meas = 0; nedge = 0;
        repeat (3) @(negedge clk);
        rst = 0;
        rdall;
        // register map: lanes, WARL, reserved words, bits that used to be volume/PCM
        wr(3'd0, 32'hFFFFFFFF); rd(3'd0); wrb(3'd0, 32'h00A5C3E1, 4'b0001); rd(3'd0); wrb(3'd0, 32'h00A5C3E1, 4'b0010); rd(3'd0);
        wrb(3'd0, 32'h00A5C3E1, 4'b0100); rd(3'd0); wrb(3'd0, 32'h00A5C3E1, 4'b1000); rd(3'd0);
        wr(3'd1, 32'hFFFFFFFF); rd(3'd1); wr(3'd2, 32'hFFFFFFFF); rd(3'd2); wr(3'd3, 32'hFFFFFFFF); rd(3'd3);
        wr(3'd4, 32'hFFFFFFFF); rd(3'd4); wr(3'd5, 32'hFFFFFFFF); rd(3'd5);
        wr(3'd6, 32'hFFFFFFFF); rd(3'd6); rd(3'd7);
        wr(3'd4, 0); wr(3'd0, 0);
        // tones: every octave, small periods, EN on
        for (o1 = 0; o1 < 8; o1 = o1 + 1) begin
            wr(3'd0, tone(o1, 12'd0));
            wr(3'd4, 32'd1);
            idle(80 * 16 * 2 * (1 << o1) * 3 / 2 + 100);
            wr(3'd4, 32'd0); idle(5);
        end
        wr(3'd0, tone(3'd7, 12'hABC)); rd(3'd0);
        // the Tetris notes (audio.v table), measured periods
        note(3'd3, 12'd2962);   // E2
        note(3'd3, 12'd2218);   // A2
        note(3'd1, 12'd2962);   // E4
        note(3'd1, 12'd2218);   // A4
        note(3'd0, 12'd3954);   // B4
        note(3'd0, 12'd3732);   // C5
        note(3'd0, 12'd3324);   // D5
        note(3'd0, 12'd2962);   // E5
        note(3'd0, 12'd2795);   // F5
        note(3'd0, 12'd2490);   // G5
        note(3'd0, 12'd2218);   // A5
        // a new P takes effect at the next reload; EN off/on
        wr(3'd0, tone(3'd0, 12'd40)); idle(3000); wr(3'd0, tone(3'd0, 12'd2)); idle(3000);
        wr(3'd4, 0); idle(50); wr(3'd4, 1); idle(2000);
        wr(3'd4, 32'd0); idle(600); rd(3'd4);
        random_phase;
        idle(4);
        miss = 0; nok = 0;
        for (oo = 0; oo < 8; oo = oo + 1) if (tog[oo] >= 50) nok = nok + 1;
        if (nok < 5) begin miss = miss + 1; $display("floor: toggles >= 50 at %0d octaves", nok); end
        if (n_enoff < 3) miss = miss + 1;
        if (errors == 0 && miss == 0)
            $display("PASS tb_audio (%0d checks, %0d notes measured, seed %0d)", checks, n_notes, seed);
        else
            $display("FAIL tb_audio: %0d errors, %0d coverage floors missed (seed %0d)", errors, miss, seed);
        $finish;
    end
    initial begin #4000000000; $display("TIMEOUT tb_audio"); $finish; end
endmodule
