// muldiv (src/muldiv.v) against a model written from the specification:
//
//   * results: MUL/MULH/MULHSU/MULHU/DIV/DIVU/REM/REMU per the M chapter of
//     the Unprivileged ISA, x/0 = all ones and remainder x, INT_MIN/-1 =
//     INT_MIN and remainder 0 (REQ-MD-001); SLL/SRL/SRA by b[4:0] per RV32I
//     (REQ-MD-002). Directed corners, then a seeded random run (+SEED=,
//     +NOPS=) whose operands are drawn mostly from the boundary values;
//   * the handshake in muldiv.v's header, on every clock (REQ-MD-003): busy
//     from the cycle after start until done; done a one-cycle pulse on the
//     cycle busy drops, exactly one per start; the result valid from done
//     until the next start, whatever the inputs do meanwhile -- the
//     operands, op and shift inputs are scrambled from the cycle after start;
//   * the latency in docs/FyraCore_CPU_Reference.md 9.2 (REQ-MD-004): done
//     34 cycles after start for a multiply, 36 for a divide, 2 + shamt for
//     a shift;
//   * reset in the middle of an operation leaves the unit idle and the next
//     operation correct (REQ-MD-005).
// A new operation is started 0-3 cycles after done (0: on the done cycle
// itself). Prints PASS/FAIL with the number of checks; a watchdog fails a
// hang.
`timescale 1ns/1ps
module tb_muldiv;
    reg         clk = 0, rst = 1, start = 0;
    reg  [2:0]  op = 0;
    reg         shift = 0, sra = 0;
    reg  [31:0] a = 0, b = 0;
    wire [31:0] result;
    wire        busy, done;

    muldiv dut(.clk(clk), .rst(rst), .start(start), .op(op), .shift(shift), .sra(sra),
               .a(a), .b(b), .result(result), .busy(busy), .done(done));
    always #5 clk = ~clk;

    integer checks = 0, fails = 0, seed = 1, nops = 40000, cyc = 0;
    integer seed0 = 1;
    integer n_op [0:10];
    always @(posedge clk) cyc <= cyc + 1;

    task automatic chk(input [8*40-1:0] what, input [31:0] got, input [31:0] want);
        begin
            checks = checks + 1;
            if (got !== want) begin
                fails = fails + 1;
                if (fails <= 30) $display("FAIL %0s: got %08h want %08h (cycle %0d)", what, got, want, cyc);
            end
        end
    endtask

    // ── the model ────────────────────────────────────────────────────────
    // kind: 0-7 the M ops (muldiv.v's op table), 8 SLL, 9 SRL, 10 SRA
    function [31:0] model(input integer kind, input [31:0] x, input [31:0] y);
        reg signed [63:0] ps; reg [63:0] pu; reg signed [64:0] psu;
        reg signed [31:0] qs, rs, sx, sy, sh;
        reg ovf;
        begin
            ps  = $signed(x) * $signed(y);
            pu  = x * y;
            psu = $signed({x[31], x}) * $signed({1'b0, y});
            sx = x; sy = y;
            ovf = (x == 32'h8000_0000 && y == 32'hFFFF_FFFF);
            // Signed quotient and remainder in signed variables: inside a ?:
            // with unsigned arms, $signed(x) / $signed(y) would divide unsigned.
            if (y != 0 && !ovf) begin qs = sx / sy; rs = sx % sy; end
            else begin qs = 0; rs = 0; end
            sh = sx >>> y[4:0];
            case (kind)
                0: model = ps[31:0];
                1: model = ps[63:32];
                2: model = psu[63:32];
                3: model = pu[63:32];
                4: if (y == 0) model = 32'hFFFF_FFFF; else if (ovf) model = 32'h8000_0000; else model = qs;
                5: if (y == 0) model = 32'hFFFF_FFFF; else model = x / y;
                6: if (y == 0) model = x; else if (ovf) model = 32'h0; else model = rs;
                7: if (y == 0) model = x; else model = x % y;
                8: model = x << y[4:0];
                9: model = x >> y[4:0];
                default: model = sh;
            endcase
        end
    endfunction
    function integer latency(input integer kind, input [31:0] y);
        latency = (kind < 4) ? 34 : (kind < 8) ? 36 : 2 + y[4:0];
    endfunction

    // ── handshake monitor (every clock) ──────────────────────────────────
    reg        pend = 0, busy_q = 0, done_q = 0, have = 0;
    reg        ign = 0;      // an operation abandoned to a reset: not checked
    reg [31:0] held;
    integer    t_start, want_lat, n_done = 0, n_start = 0;
    always @(posedge clk) begin
        #1;
        if (rst) begin
            pend = 0; have = 0; ign = 0;
            checks = checks + 1;
            if (done) begin fails = fails + 1; $display("FAIL done during reset (cycle %0d)", cyc); end
        end else if (!ign) begin
            if (pend && !done) begin
                checks = checks + 1;
                if (busy !== 1'b1) begin fails = fails + 1; if (fails <= 30) $display("FAIL busy low while the operation runs (cycle %0d)", cyc); end
            end
            if (done) begin
                checks = checks + 3;
                if (!pend) begin fails = fails + 1; if (fails <= 30) $display("FAIL done with no operation running (cycle %0d)", cyc); end
                if (busy !== 1'b0 || busy_q !== 1'b1) begin fails = fails + 1; if (fails <= 30) $display("FAIL done not on the cycle busy drops (busy %b, before %b, cycle %0d)", busy, busy_q, cyc); end
                if (done_q) begin fails = fails + 1; if (fails <= 30) $display("FAIL done longer than one cycle (cycle %0d)", cyc); end
                if (pend && cyc - t_start != want_lat) begin
                    fails = fails + 1;
                    if (fails <= 30) $display("FAIL latency %0d cycles, want %0d (cycle %0d)", cyc - t_start, want_lat, cyc);
                end
                pend = 0; have = 1; held = result; n_done = n_done + 1;
            end else if (have) begin
                checks = checks + 1;
                if (result !== held) begin
                    fails = fails + 1;
                    if (fails <= 30) $display("FAIL result changed after done before the next start: %08h -> %08h (cycle %0d)", held, result, cyc);
                end
            end
            if (!pend && !done && busy !== 1'b0) begin
                checks = checks + 1; fails = fails + 1;
                if (fails <= 30) $display("FAIL busy with nothing running (cycle %0d)", cyc);
            end
        end
        busy_q = busy; done_q = done;
    end

    // ── driver ───────────────────────────────────────────────────────────
    integer gap = 1;
    reg [31:0] r_res;
    // Start one operation on the next clock (unless `now`: this clock),
    // scramble every input from the next cycle on, and wait for done.
    task automatic run(input integer kind, input [31:0] x, input [31:0] y);
        integer n;
        begin
            @(negedge clk);
            if (kind < 8) begin op = kind[2:0]; shift = 0; sra = 0; end
            else begin op = (kind == 8) ? 3'b001 : 3'b101; shift = 1; sra = (kind == 10); end
            a = x; b = y; start = 1;
            @(posedge clk);
            t_start = cyc; want_lat = latency(kind, y); pend = 1; have = 0;
            n_start = n_start + 1; n_op[kind] = n_op[kind] + 1;
            @(negedge clk);
            start = 0; a = $random(seed); b = $random(seed); op = $random(seed); shift = $random(seed); sra = $random(seed);
            n = 0;
            while (!done && n < 200) begin @(posedge clk); #2; n = n + 1; end
            if (!done) begin
                fails = fails + 1;
                $display("FAIL no done within 200 cycles (kind %0d, %08h, %08h)", kind, x, y);
            end else
                chk("result", result, model(kind, x, y));
            if (fails > 0 && fails <= 30 && result !== model(kind, x, y))
                $display("     kind %0d a=%08h b=%08h", kind, x, y);
            // the next start: on this done cycle (gap 0) or 1-3 cycles later
            gap = $unsigned($random(seed)) % 4;
            repeat (gap) @(posedge clk);
        end
    endtask

    function [31:0] pick;
        input integer dummy;
        reg [3:0] c;
        begin
            c = $random(seed);
            case (c)
                0: pick = 32'h0;          1: pick = 32'h1;          2: pick = 32'hFFFF_FFFF;
                3: pick = 32'h8000_0000;  4: pick = 32'h7FFF_FFFF;  5: pick = 32'h8000_0001;
                6: pick = 32'hFFFF_FFFE;  7: pick = 32'h1 << ($unsigned($random(seed)) % 32);
                8: pick = ~(32'h1 << ($unsigned($random(seed)) % 32));
                9: pick = $random(seed) & 32'hFF;
                10: pick = -($random(seed) & 32'hFF);
                default: pick = $random(seed);
            endcase
        end
    endfunction

    integer i, k, x, y;
    reg [31:0] corners [0:9];
    initial begin
        if ($value$plusargs("SEED=%d", seed)) ;
        seed0 = seed;   // $random(seed) moves seed on: report the one that reproduces the run
        if ($value$plusargs("NOPS=%d", nops)) ;
        for (k = 0; k <= 10; k = k + 1) n_op[k] = 0;
        $display("=== MulDiv Testbench (model, seed %0d, %0d random ops) ===", seed, nops);
        corners[0] = 0; corners[1] = 1; corners[2] = 32'hFFFF_FFFF; corners[3] = 32'h8000_0000;
        corners[4] = 32'h7FFF_FFFF; corners[5] = 2; corners[6] = 32'hFFFF_FFFE; corners[7] = 7;
        corners[8] = 32'hFFFF_FFF9; corners[9] = 32'h8000_0001;
        repeat (3) @(posedge clk);
        @(negedge clk); rst = 0;

        // every op on every pair of corners: x/0, -x/0, INT_MIN/-1, ...
        for (k = 0; k < 11; k = k + 1)
            for (x = 0; x < 10; x = x + 1)
                for (y = 0; y < 10; y = y + 1)
                    run(k, corners[x], (k >= 8) ? (y * 7) : corners[y]);
        // every shift amount, both directions, bit 5 and up ignored
        for (k = 8; k < 11; k = k + 1)
            for (y = 0; y < 64; y = y + 1)
                run(k, 32'hC3A5_96F1, y | (y[0] ? 32'hFFFF_FF00 : 0));

        // reset in the middle of an operation, at every point of a divide
        for (i = 1; i < 40; i = i + 1) begin
            @(negedge clk); op = 3'd4; shift = 0; a = 32'h8000_0000; b = 3; start = 1;
            @(posedge clk); pend = 0; ign = 1;     // the operation is abandoned
            @(negedge clk); start = 0;
            repeat (i - 1) @(negedge clk);
            rst = 1; @(negedge clk); rst = 0; have = 0;
            repeat (2) begin
                @(posedge clk); #1;
                chk("idle after reset (busy)", {31'b0, busy}, 32'b0);
                chk("idle after reset (done)", {31'b0, done}, 32'b0);
            end
            run(i % 11, pick(0), pick(0));
        end

        // random, boundary-biased
        for (i = 0; i < nops; i = i + 1) run($unsigned($random(seed)) % 11, pick(0), pick(0));

        repeat (5) @(posedge clk);
        checks = checks + 1;
        if (n_done != n_start) begin
            fails = fails + 1;
            $display("FAIL %0d operations started, %0d done", n_start, n_done);
        end
        for (k = 0; k <= 10; k = k + 1)
            if (n_op[k] < 100) begin fails = fails + 1; $display("FAIL coverage: kind %0d ran %0d times", k, n_op[k]); end
        if (fails == 0) $display("PASS tb_muldiv (%0d checks, %0d operations, seed %0d)", checks, n_start, seed0);
        else            $display("FAIL tb_muldiv: %0d failures, %0d checks, seed %0d", fails, checks, seed0);
        $finish;
    end

    initial begin
        #(64'd400_000_000);
        $display("TIMEOUT tb_muldiv");
        $finish;
    end
endmodule
