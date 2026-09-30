// Unit testbench for src/gpio.v: GPIO OUT/IN and the OLED's SPI transmitter.
//
// Checked against models written from the specification (the header of
// src/gpio.v and docs/pins-and-peripherals.md), not from the RTL:
//
//   * a register model predicting every read (OUT with bits 4-5 reading 0,
//     IN through a two-flop synchroniser, DATA reading 0, CTRL with BUSY)
//     and every output pin on every clock: bits 7-6, 2 and 0 are OUT; 5-4
//     are 0; 3 and 1 are OUT bits 3 and 1 while EN = 0, and SCK / MOSI
//     while EN = 1 (SCK idle-high and MOSI holding the last bit sent when no
//     byte is shifting);
//   * IN: a read completing on edge p returns the input as sampled on edge
//     p - 2, never p - 1;
//   * a mode-3 SPI protocol checker on the pins, for every DIV: SCK idles
//     high; every low and high phase inside a byte is exactly 2^DIV clocks;
//     MOSI changes only together with a falling SCK edge, so it is stable
//     for at least half a period before and after every rising edge; bytes
//     are 8 rising edges, MSB first, and equal what was written to DATA;
//     SCK stays high at least half a period between bytes;
//   * back-pressure: every register write with byte lane 0 (the only lane
//     writes use) waits while a byte is shifting, and the byte keeps the
//     shifter busy for one half-period after its last rising edge, so a
//     waiting write -- DATA, OUT (CS#, D/C) or CTRL -- completes exactly on
//     the edge after that. Nothing on OUT's pins can change under a byte.
//     Writes without lane 0 and all reads never wait;
//   * as built, and checked exactly: the first falling SCK edge of a byte
//     comes one half-period after the DATA write, and BUSY reads 1 from the
//     edge after the write through the end of that extra half-period.
//
// The bus driver follows the core's contract, as in tb_uart.v. Plusargs:
// +SEED=<n>, +NRAND=<n>.

`timescale 1ns / 1ps

module tb_gpio;
    localparam real T = 10.0;
    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;
    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;
    reg rst_q = 1'b1;
    always @(posedge clk) rst_q <= rst;

    reg         sel = 1'b0, we = 1'b0;
    reg  [3:0]  be = 4'h0;
    reg  [1:0]  addr = 2'd0;
    reg  [31:0] wdata = 32'h0;
    wire [31:0] rdata;
    wire        ready;
    reg  [7:0]  gin = 8'h00;
    wire [7:0]  gout;

    gpio dut (.clk(clk), .rst(rst), .sel(sel), .we(we), .be(be), .addr(addr), .wdata(wdata),
              .rdata(rdata), .ready(ready), .in(gin), .out(gout));

    // ── Reporting ───────────────────────────────────────────────────────────
    integer errors = 0, checks = 0;
    task automatic fail(input string m);
        begin
            errors = errors + 1;
            if (errors <= 60) $display("FAIL %s (cycle %0d, %0.1f ns)", m, cyc, $realtime);
        end
    endtask
    task automatic chk(input string what, input [31:0] got, input [31:0] want);
        begin
            checks = checks + 1;
            if (got !== want) fail($sformatf("%s: got %h, want %h", what, got, want));
        end
    endtask
    task automatic section(input string m);
        $display("-- %s (cycle %0d)", m, cyc);
    endtask
    integer seed = 1;
    function integer urand(input integer n);
        begin urand = $unsigned($random(seed)) % n; end
    endfunction

    // The input as each rising edge sampled it (the testbench only changes it
    // between edges).
    reg [7:0] in_at [0:15];
    always @(posedge clk) in_at[(cyc + 1) % 16] = gin;

    // ── Model ───────────────────────────────────────────────────────────────
    reg  [7:0] m_out;
    reg        m_en;
    reg  [1:0] m_div;
    reg        m_mosi;               // MOSI once the shifter is idle
    integer    by_w = -1000;         // edge the latest DATA write completed on
    integer    by_h = 1;             // its half-period, clocks
    integer    n_stalled = 0, n_bytes = 0, n_bytes_en = 0;
    integer    sp_d [$];             // bytes expected on the pins (EN = 1)
    integer    sp_w [$];             // their DATA write edges
    integer    sp_h [$];             // and half-periods
    integer    bytes_by_div [0:3];
    initial begin bytes_by_div[0] = 0; bytes_by_div[1] = 0; bytes_by_div[2] = 0; bytes_by_div[3] = 0; end

    function integer busy_end;       // last edge before which BUSY reads 1
        busy_end = by_w + 17 * by_h;
    endfunction
    function integer busy_at(input integer p);   // BUSY as a read completing on p sees it
        busy_at = (p >= by_w + 1 && p <= busy_end()) ? 1 : 0;
    endfunction

    task automatic model_reset;
        begin
            m_out = 8'h09; m_en = 1'b0; m_div = 2'd0; m_mosi = 1'b0;
            by_w = -1000; by_h = 1;
            sp_d.delete(); sp_w.delete(); sp_h.delete();
        end
    endtask

    // ── Pin checker, and the SPI protocol checker ───────────────────────────
    reg     sck_p = 1'b1, mosi_p = 1'b0, en_p = 1'b0;
    integer sp_bits = 0, sp_last_rise = -1000, sp_last_fall = -1000, sp_last_mosi = -1000;
    integer sp_x;
    reg [7:0] sp_byte;
    reg     sck, mosi;
    reg [7:0] pin_prev;
    integer pin_ok_from = 0;         // no pin changes expected under a byte before this

    always @(negedge clk) begin
        if (rst_q) begin
            checks = checks + 1;
            if (gout !== 8'h09) fail($sformatf("out during reset: %h, want 09", gout));
            sck_p = 1'b1; mosi_p = gout[1]; en_p = 1'b0; sp_bits = 0;
        end else begin
            checks = checks + 1;
            if ({gout[7:6], gout[2], gout[0]} !== {m_out[7:6], m_out[2], m_out[0]} || gout[5:4] !== 2'b00)
                fail($sformatf("out = %h, OUT = %h", gout, m_out));
            // CS#, D/C and the rest never change while a byte is shifting.
            if (cyc > by_w + 1 && cyc <= busy_end() && {gout[7:6], gout[2], gout[0]} !== {pin_prev[7:6], pin_prev[2], pin_prev[0]})
                fail("an OUT pin changed while a SPI byte was shifting");
            sck = gout[3]; mosi = gout[1];
            if (!m_en) begin
                if (sck !== m_out[3] || mosi !== m_out[1])
                    fail($sformatf("EN = 0: out[3], out[1] = %b%b, want OUT bits %b%b", sck, mosi, m_out[3], m_out[1]));
            end else if (!en_p) begin
                // Just switched to the shifter: it must be idle-looking.
                if (cyc > busy_end() && (sck !== 1'b1 || mosi !== m_mosi))
                    fail($sformatf("EN turned on while idle: SCK %b MOSI %b, want 1 %b", sck, mosi, m_mosi));
            end else begin
                if (sck !== 1'b0 && sck !== 1'b1) fail("SCK is X");
                if (mosi !== 1'b0 && mosi !== 1'b1) fail("MOSI is X");
                // MOSI moves only with a falling SCK edge.
                if (mosi !== mosi_p) begin
                    checks = checks + 1;
                    if (!(sck_p === 1'b1 && sck === 1'b0))
                        fail("MOSI changed without a falling SCK edge");
                    if (cyc - sp_last_rise < sp_hh())
                        fail($sformatf("MOSI hold after the rising edge: %0d clocks", cyc - sp_last_rise));
                    sp_last_mosi = cyc;
                end
                if (sck_p === 1'b1 && sck === 1'b0) begin                 // falling
                    checks = checks + 1;
                    if (sp_bits == 0) begin
                        if (sp_d.size() == 0) fail("SCK fell with no byte written");
                        else begin
                            if (cyc != sp_w[0] + sp_h[0])
                                fail($sformatf("first falling SCK edge %0d clocks after the DATA write, want %0d",
                                               cyc - sp_w[0], sp_h[0]));
                            if (cyc - sp_last_rise < sp_h[0])
                                fail($sformatf("SCK high only %0d clocks between bytes", cyc - sp_last_rise));
                        end
                    end else if (cyc - sp_last_rise != sp_hh())
                        fail($sformatf("SCK high phase %0d clocks inside a byte, want %0d", cyc - sp_last_rise, sp_hh()));
                    sp_last_fall = cyc;
                end
                if (sck_p === 1'b0 && sck === 1'b1) begin                 // rising
                    checks = checks + 1;
                    if (sp_d.size() == 0) fail("SCK rose with no byte written");
                    else begin
                        if (cyc - sp_last_fall != sp_h[0])
                            fail($sformatf("SCK low phase %0d clocks, want %0d", cyc - sp_last_fall, sp_h[0]));
                        if (cyc - sp_last_mosi < sp_h[0])
                            fail($sformatf("MOSI setup before the rising edge: %0d clocks", cyc - sp_last_mosi));
                        sp_byte = {sp_byte[6:0], mosi};
                        sp_bits = sp_bits + 1;
                        if (sp_bits == 8) begin
                            chk("SPI byte", sp_byte, sp_d[0]);
                            n_bytes_en = n_bytes_en + 1;
                            bytes_by_div[sp_h[0] == 1 ? 0 : sp_h[0] == 2 ? 1 : sp_h[0] == 4 ? 2 : 3] =
                                bytes_by_div[sp_h[0] == 1 ? 0 : sp_h[0] == 2 ? 1 : sp_h[0] == 4 ? 2 : 3] + 1;
                            sp_x = sp_d.pop_front(); sp_x = sp_w.pop_front(); sp_x = sp_h.pop_front();
                            sp_bits = 0;
                        end
                    end
                    sp_last_rise = cyc;
                end
                // Idle: SCK high, MOSI holding the last bit.
                if (cyc > busy_end() && (sck !== 1'b1 || mosi !== m_mosi))
                    fail($sformatf("idle shifter: SCK %b MOSI %b, want 1 %b", sck, mosi, m_mosi));
            end
            sck_p = sck; mosi_p = mosi; en_p = m_en;
        end
        pin_prev = gout;
    end
    function integer sp_hh;          // half-period of the byte on the pins
        sp_hh = (sp_h.size() > 0) ? sp_h[0] : by_h;
    endfunction

    // ready may be low only while selected.
    always @(negedge clk)
        if (!rst_q && !sel && ready !== 1'b1) fail("ready low while not selected");

    // ── Bus driver ──────────────────────────────────────────────────────────
    real    t_lastpos = -100.0;
    always @(posedge clk) t_lastpos = $realtime;
    integer last_p, last_stall;
    reg [31:0] last_rd;

    task automatic noise;
        begin we = urand(2); be = urand(16); addr = urand(4); wdata = $random(seed); end
    endtask
    task automatic idle(input integer n);
        integer k;
        for (k = 0; k < n; k = k + 1) begin @(posedge clk); #1; noise; end
    endtask

    task automatic bus(input w, input [3:0] b, input [1:0] a, input [31:0] wd);
        integer    n, p_first, want, busy;
        reg [11:0] snap;
        begin
            if ($realtime != t_lastpos + 1.0) begin @(posedge clk); #1; end
            sel = 1'b1; we = w; be = b; addr = a; wdata = wd;
            p_first = cyc + 1;
            snap = {dut.out_r, dut.spi_en, dut.spi_div, 1'b0};
            #1;
            n = 0;
            while (ready !== 1'b1 && n <= 10000) begin
                if (ready !== 1'b0) fail("ready is X");
                @(posedge clk); #1;
                n = n + 1;
                if ({dut.out_r, dut.spi_en, dut.spi_div, 1'b0} !== snap)
                    fail("a register was written while the store was still waiting for ready");
            end
            last_rd = rdata;
            @(posedge clk);
            #1;
            last_p = cyc; last_stall = n;
            sel = 1'b0;
            noise;
            checks = checks + 1;
            // Only writes with lane 0 wait, and only for the byte in flight.
            want = (w && b[0] && busy_end() + 1 > p_first) ? busy_end() + 1 : p_first;
            if (last_p != want)
                fail($sformatf("%s addr %0d be %b completed on edge %0d, want %0d (shifter busy to %0d)",
                               w ? "write" : "read", a, b, last_p, want, busy_end()));
            if (last_p > p_first) n_stalled = n_stalled + 1;
            if (w) begin
                if (b[0]) begin
                    case (a)
                        2'd0: m_out = {wd[7:6], 2'b00, wd[3:0]};
                        2'd2: begin
                                  by_w = last_p; by_h = 1 << m_div; n_bytes = n_bytes + 1;
                                  if (m_en) begin
                                      sp_d.push_back(wd[7:0]); sp_w.push_back(last_p); sp_h.push_back(1 << m_div);
                                  end
                                  m_mosi = wd[0];
                              end
                        2'd3: begin m_en = wd[0]; m_div = wd[2:1]; end
                        default: ;
                    endcase
                end
            end else begin
                busy = busy_at(last_p);
                case (a)
                    2'd0: chk("OUT", last_rd, {24'h0, m_out[7:6], 2'b00, m_out[3:0]});
                    2'd1: chk("IN (input two edges before)", last_rd, {24'h0, in_at[(last_p - 2) % 16]});
                    2'd2: chk("DATA reads 0", last_rd, 32'h0);
                    2'd3: chk("CTRL", last_rd, {23'h0, busy[0], 5'h0, m_div, m_en});
                endcase
            end
        end
    endtask
    task automatic wr(input [1:0] a, input [31:0] v);
        bus(1'b1, 4'b0001, a, v);
    endtask
    task automatic rd(input [1:0] a, output [31:0] v);
        begin bus(1'b0, 4'b1111, a, $random(seed)); v = last_rd; end
    endtask
    task automatic wait_idle;
        reg [31:0] v;
        begin v = 32'h100; while (v[8]) rd(2'd3, v); end
    endtask
    // Change the input between edges, at a random point in the cycle.
    task automatic set_in(input [7:0] v);
        begin #(2.0 + urand(500) / 100.0); gin = v; end
    endtask

    // ── Tests ───────────────────────────────────────────────────────────────
    reg [31:0] v;
    integer    i, j, k, n, bi, a, dv, nrand;

    initial begin
        if ($value$plusargs("SEED=%d", seed)) ;
        if (!$value$plusargs("NRAND=%d", nrand)) nrand = 4000;
        model_reset;
        noise;

        section("reset");
        for (i = 0; i < 12; i = i + 1) begin
            @(posedge clk); #1; noise; sel = urand(2); gin = $random(seed);
        end
        sel = 1'b0; gin = 8'hA5;
        @(posedge clk); #1;
        rst = 1'b0;
        idle(3);
        for (a = 0; a < 4; a = a + 1)
            for (bi = 0; bi < 16; bi = bi + 1) bus(1'b0, bi, a, $random(seed));
        rd(0, v); chk("OUT after reset", v, 32'h09);
        rd(3, v); chk("CTRL after reset", v, 32'h00);

        section("register writes, every address and byte enable");
        for (k = 0; k < 3; k = k + 1)
            for (a = 0; a < 4; a = a + 1)
                for (bi = 0; bi < 16; bi = bi + 1) begin
                    v = $random(seed);
                    bus(1'b1, bi, a, v);
                    for (j = 0; j < 4; j = j + 1) bus(1'b0, urand(16), j, $random(seed));
                    if (a == 2 && bi[0]) begin
                        // a byte is shifting: every lane-0 write waits for it
                        bus(1'b1, 4'b0001 | (urand(8) << 1), urand(4) == 2 ? 2'd2 : 2'd0, $random(seed));
                        wait_idle;
                    end
                end

        section("OUT masking");
        wr(0, 32'hFFFF_FFFF);
        rd(0, v); chk("OUT bits 4-5 read 0", v, 32'hCF);
        wr(0, 32'h0000_0030);
        rd(0, v); chk("OUT bits 4-5 ignore writes", v, 32'h00);
        wr(0, 32'h0000_0009);

        section("IN synchroniser");
        for (i = 0; i < 300; i = i + 1) begin
            fork
                set_in($random(seed));
                rd(1, v);
            join
            if (urand(3) == 0) rd(1, v);
        end
        // Held: the new value exactly two edges on, not one.
        for (i = 0; i < 20; i = i + 1) begin
            @(posedge clk); set_in(~gin);
            rd(1, v); rd(1, v); rd(1, v);
        end

        section("SPI, every DIV");
        for (dv = 0; dv < 4; dv = dv + 1) begin
            wr(3, 32'h1 | (dv << 1));
            for (i = 0; i < 12; i = i + 1) begin
                case (i)
                    0: v = 8'h00; 1: v = 8'hFF; 2: v = 8'h55; 3: v = 8'hAA;
                    4: v = 8'h80; 5: v = 8'h01; default: v = $random(seed);
                endcase
                wr(2, v);                             // back to back: each waits for the last
                if (i % 4 == 3) begin
                    for (j = urand(30); j > 0; j = j - 1) rd(3, v);   // BUSY polling
                    idle(urand(3 << dv));
                end
            end
            wait_idle;
            // A word store and a halfword store to DATA send lane 0.
            bus(1'b1, 4'b1111, 2'd2, 32'h1234_56C3);
            bus(1'b1, 4'b0011, 2'd2, 32'h0000_3C3C);
            wait_idle;
            // Lanes 1-3 alone write nothing and never wait.
            wr(2, 8'h96);
            for (bi = 2; bi < 16; bi = bi + 2) bus(1'b1, bi, urand(4), $random(seed));
            wait_idle;
        end

        section("OLED byte sequence, no BUSY polling");
        // sw DATA; sw OUT(D/C); sw DATA; sw DATA; sw OUT(CS# = 1): the OUT
        // writes wait for the byte, so CS# and D/C never move under one.
        for (dv = 0; dv < 4; dv = dv + 1) begin
            wr(3, 32'h1 | (dv << 1));
            wr(0, 32'h48);                           // RES# 1, SCK idle 1, CS# 0, D/C 0
            for (i = 0; i < 4; i = i + 1) begin
                wr(2, 8'hA5 + i);                    // command
                wr(0, 32'h4C);                       // D/C = 1
                wr(2, 8'h3C);                        // data
                wr(2, 8'h3D);
                wr(0, 32'h4D);                       // CS# = 1
                wr(0, 32'h48);                       // CS# = 0, D/C = 0
            end
            wait_idle;
        end

        section("CTRL waits for the byte");
        wr(3, 32'h1 | (3 << 1));
        wr(2, 8'hE7);
        wr(3, 32'h1);                                // DIV 3 -> 0: must wait, or SCK is cut short
        wr(2, 8'h18);
        wait_idle;
        // BUSY is read-only.
        wr(3, 32'h0000_0101);
        rd(3, v); chk("CTRL: BUSY ignores writes", v, 32'h1);

        section("EN mux");
        for (i = 0; i < 16; i = i + 1) begin
            wr(3, urand(4) << 1);                    // EN 0
            wr(0, $random(seed));
            wr(2, $random(seed));                    // shifts with the pins left to OUT
            for (j = urand(20); j > 0; j = j - 1) rd(3, v);
            wait_idle;
            wr(0, $random(seed) | 32'h8);
            wr(3, (urand(4) << 1) | 1);              // EN 1: SCK idle high, MOSI = last bit
            idle(urand(4));
            wr(2, $random(seed));
            wr(0, $random(seed));                    // stored, but bits 1 and 3 stay on the shifter
            rd(0, v);
            wait_idle;
        end

        section("random");
        for (i = 0; i < nrand; i = i + 1) begin
            case (urand(12))
                0, 1:    wr(2, $random(seed));
                2:       bus(1'b1, urand(16), 2'd2, $random(seed));
                3:       wr(0, $random(seed));
                4:       bus(1'b1, urand(16), urand(4), $random(seed));
                5:       wr(3, urand(8));
                6, 7:    bus(1'b0, urand(16), urand(4), $random(seed));
                8:       fork set_in($random(seed)); rd(1, v); join
                9:       rd(3, v);
                default: idle(urand(24));
            endcase
        end
        wait_idle;

        section("reset while shifting");
        wr(3, 32'h1 | (2 << 1));
        wr(0, 32'hC6);
        wr(2, 8'h5A);
        idle(9);
        rst = 1'b1;
        @(posedge clk); #1;
        model_reset;
        idle(4);
        rst = 1'b0;
        idle(2);
        rd(0, v); chk("OUT after reset", v, 32'h09);
        rd(3, v); chk("CTRL after reset", v, 32'h00);
        wr(3, 32'h1);
        wr(2, 8'h81);
        wait_idle;

        idle(10);
        $display("tb_gpio: %0d bytes written, %0d seen on the pins (DIV 0: %0d, 1: %0d, 2: %0d, 3: %0d), %0d accesses waited",
                 n_bytes, n_bytes_en, bytes_by_div[0], bytes_by_div[1], bytes_by_div[2], bytes_by_div[3], n_stalled);
        if (bytes_by_div[0] < 10 || bytes_by_div[3] < 10 || n_stalled < 50)
            fail("coverage: too few bytes per DIV or too few waits");
        if (sp_d.size() != 0) fail($sformatf("%0d bytes written never appeared on the pins", sp_d.size()));
        if (errors == 0) $display("PASS tb_gpio (%0d checks)", checks);
        else             $display("FAIL tb_gpio: %0d errors, %0d checks", errors, checks);
        $finish;
    end

    initial begin
        #(200_000_000);
        $display("TIMEOUT tb_gpio");
        $finish;
    end
endmodule
