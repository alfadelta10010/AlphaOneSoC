`timescale 1ns / 1ps
// pinmux (src/pinmux.v) against a cycle model written from the slim-down specification: every pin has code 0
// (DEFAULT dflt[i]); pin 5 also has code 2 (RTS#), pin 6 code 4 (PWM0); pin 7 is PWM1 always (no code, no flop); WARL: any other
// code on any pin stores 0 and reads 0; through ONE flop per pin (pin = mux of the previous clock's inputs and
// stored selects); reset: selects 0 and uo = 0x39; per-lane (byte) writes (lane i/2 for pin i); bit 4i+3 reads 0.
// Directed phase first: every code 0-7 written to every pin (alone and all-pins-at-once), readback and pins. Inputs change on the negative edge; every output and read word is compared every clock.
// +SEED= seeds the random phase, +CYCLES= its length. Prints the check count and a PASS line.
module tb_pinmux;
    reg         clk = 0, rst = 1, sel = 0, we = 0;
    reg  [3:0]  be = 0;
    reg  [31:0] wdata = 0;
    reg  [6:0]  dflt = 0;
    reg         rts_n = 0;
    reg  [1:0]  pwm = 0;
    wire [31:0] rdata;
    wire [7:0]  uo;
    pinmux uut (.clk(clk), .rst(rst), .sel(sel), .we(we), .be(be), .wdata(wdata), .rdata(rdata),
                .dflt(dflt), .rts_n(rts_n), .pwm(pwm), .uo(uo));
    always #5 clk = ~clk;

    integer seed = 1, ncyc = 200000, checks = 0, errors = 0, cyc = 0;
    reg [31:0] rs;
    function [31:0] rnd(input integer dummy);
        begin rs = rs ^ (rs << 13); rs = rs ^ (rs >> 17); rs = rs ^ (rs << 5); rnd = rs; end
    endfunction

    // ------------------------------------------------------------ model
    reg [2:0] mc [0:7];          // model codes as stored (0 unless the pin's one legal alternate code was written)
    reg [7:0] muo;               // model pin flops
    reg [7:0] mmux;
    integer i, p;
    integer cv [0:63];           // pin*8+code: cycles the mux selected that code
    integer n_rst = 0, n_lane = 0, n_chg = 0, n_warl = 0;
    function [2:0] legal(input integer pin, input [2:0] code);   // WARL: the stored code
        begin
            legal = 3'd0;
            if (pin == 5 && code == 3'd2) legal = 3'd2;
            if (pin == 6 && code == 3'd4) legal = 3'd4;
        end
    endfunction
    function srcbit(input integer pin, input [2:0] code);
        begin
            case (code)
                3'd2: srcbit = rts_n;
                3'd4: srcbit = pwm[0];
                default: srcbit = dflt[pin];
            endcase
        end
    endfunction
    initial begin for (i = 0; i < 8; i = i + 1) mc[i] = 0; muo = 8'h39; for (i = 0; i < 64; i = i + 1) cv[i] = 0; end
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 8; i = i + 1) mc[i] = 3'd0;
            muo = 8'h39;
        end else begin
            for (i = 0; i < 8; i = i + 1) begin
                mmux[i] = (i == 7) ? pwm[1] : srcbit(i, mc[i]);
                cv[i*8 + mc[i]] = cv[i*8 + mc[i]] + 1;
            end
            if (sel & we) for (i = 0; i < 8; i = i + 1) if (be[i/2]) begin
                if (legal(i, wdata[4*i +: 3]) != wdata[4*i +: 3]) n_warl = n_warl + 1;
                if (mc[i] != legal(i, wdata[4*i +: 3])) n_chg = n_chg + 1;
                mc[i] = legal(i, wdata[4*i +: 3]);
            end
            muo = mmux;
        end
    end
    function [31:0] mrd(input integer dummy);
        integer k;
        begin for (k = 0; k < 8; k = k + 1) mrd[4*k +: 4] = {1'b0, mc[k]}; end
    endfunction

    task fail(input [8*8-1:0] what, input [31:0] got, input [31:0] want);
        begin errors = errors + 1;
            if (errors < 20) $display("FAIL %0s cyc %0d: got %h want %h", what, cyc, got, want); end
    endtask

    // random stimulus every negedge (sources change every clock; writes at random)
    reg force_idle = 0;
    reg [31:0] wsel;
    task drive;
        begin
            dflt = rnd(0); rts_n = rnd(0); pwm = rnd(0);
            sel = (rnd(0) % 4) != 0; we = (rnd(0) % 3) == 0; be = rnd(0); wdata = rnd(0);
            wsel = rnd(0) % 8;
            // mostly lane writes with a single lane, to hit every lane/pin pair
            if (wsel < 4) be = 4'b1 << (rnd(0) % 4);
            if (wsel == 7) begin we = 1; sel = 1; be = 4'hF; end
            if (force_idle) begin sel = 0; we = 0; end
            if ((rnd(0) % 1500) == 0) begin rst = 1; n_rst = n_rst + 1; end
            else if (rst && (rnd(0) % 3) == 0) rst = 0;
        end
    endtask
    always @(negedge clk) begin
        cyc = cyc + 1; checks = checks + 2;
        if (uo !== muo) fail("uo", uo, muo);
        if (rdata !== mrd(0)) fail("rdata", rdata, mrd(0));
        if (cyc > 3) begin
            if (sel & we & ~rst) n_lane = n_lane + (be != 4'hF);
            if (!force_idle) drive;
        end
    end

    integer miss;
    initial begin
        if (!$value$plusargs("SEED=%d", seed)) seed = 1;
        if (!$value$plusargs("CYCLES=%d", ncyc)) ncyc = 200000;
        rs = 32'h9E3779B9 ^ (seed * 32'h85EBCA6B); if (rs == 0) rs = 1;
        // reset: held 3 clocks with random sources, uo must read 0x39 and codes 0
        repeat (3) @(negedge clk);
        rst = 0;
        force_idle = 1;
        // directed: every code 0-7 on every pin (one pin at a time, then the same code on all pins), then
        // distinct codes; the checker at every negedge compares the readback and the pins against the model
        for (i = 0; i < 8; i = i + 1) for (p = 0; p < 8; p = p + 1) begin
            @(negedge clk); sel = 1; we = 1; be = 4'hF; wdata = 32'h0; wdata[4*i +: 4] = {1'b0, p[2:0]};
            dflt = 8'hA5 ^ (i * 17); rts_n = ~p[0]; pwm = {p[1], p[2]};
            @(negedge clk); sel = 0; we = 0; dflt = ~dflt; rts_n = ~rts_n; pwm = ~pwm;
            @(negedge clk); @(negedge clk);
        end
        for (p = 0; p < 8; p = p + 1) begin
            @(negedge clk); sel = 1; we = 1; be = 4'hF; wdata = {1'b0, p[2:0], 1'b0, p[2:0], 1'b0, p[2:0], 1'b0, p[2:0],
                                                                  1'b0, p[2:0], 1'b0, p[2:0], 1'b0, p[2:0], 1'b0, p[2:0]};
            dflt = 8'h5A; rts_n = p[0]; pwm = p[2:1];
            @(negedge clk); sel = 0; we = 0; @(negedge clk); dflt = 8'hA5; rts_n = ~rts_n; pwm = ~pwm; @(negedge clk);
        end
        @(negedge clk); sel = 1; we = 1; be = 4'hF; wdata = 32'h5420_0000;   // pin 7 = 5 (illegal now), pin 6 = 4, pin 5 = 2
        rts_n = 1; pwm = 2'b01; dflt = 7'h00;
        @(negedge clk); sel = 0; we = 0; @(negedge clk); @(negedge clk);
        if (rdata !== 32'h0420_0000) begin errors = errors + 1; $display("FAIL directed readback %h", rdata); end
        if (uo[7:5] !== 3'b011) begin errors = errors + 1; $display("FAIL directed pins %b", uo); end
        force_idle = 0;
        repeat (ncyc) @(posedge clk);
        @(negedge clk);
        miss = 0;
        for (i = 0; i < 8; i = i + 1) for (p = 0; p < 8; p = p + 1)
            if (legal(i, p[2:0]) == p[2:0] && cv[i*8+p] < 20) miss = miss + 1;   // only the reachable (pin, code) pairs
        if (n_rst < 3 || n_lane < 100 || n_chg < 100 || n_warl < 100) miss = miss + 100;
        if (errors == 0 && miss == 0)
            $display("PASS tb_pinmux (%0d checks, %0d resets, %0d lane writes, seed %0d)", checks, n_rst, n_lane, seed);
        else
            $display("FAIL tb_pinmux: %0d errors, %0d coverage floors missed (seed %0d)", errors, miss, seed);
        $finish;
    end
    initial begin #2000000000; $display("TIMEOUT tb_pinmux"); $finish; end
endmodule
