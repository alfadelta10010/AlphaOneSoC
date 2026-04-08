// Testbench for muldiv.v — RV32M multi-cycle multiply/divide unit
//
// Tests all 8 operations: MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU
// Covers: normal values, boundary cases (0, 1, -1, INT_MIN, INT_MAX),
//         division-by-zero, and signed overflow (INT_MIN / -1).

`timescale 1ns/1ps

module tb_muldiv;

    // ── DUT signals ──────────────────────────────────────────────────────────
    reg         clk, rst, start;
    reg  [2:0]  op;
    reg  [31:0] a, b;
    wire [31:0] result;
    wire        busy, done;

    // ── op encodings ─────────────────────────────────────────────────────────
    localparam MUL    = 3'd0;
    localparam MULH   = 3'd1;
    localparam MULHSU = 3'd2;
    localparam MULHU  = 3'd3;
    localparam DIV    = 3'd4;
    localparam DIVU   = 3'd5;
    localparam REM    = 3'd6;
    localparam REMU   = 3'd7;

    // ── Score tracking ────────────────────────────────────────────────────────
    integer pass_count, fail_count;

    muldiv dut(
        .clk   (clk),
        .rst   (rst),
        .start (start),
        .op    (op),
        .a     (a),
        .b     (b),
        .result(result),
        .busy  (busy),
        .done  (done)
    );

    // 10 ns clock
    initial clk = 0;
    always #5 clk = ~clk;

    // ── Task: issue one operation and wait for done ───────────────────────────
    task run_op;
        input [2:0]  t_op;
        input [31:0] t_a, t_b;
        begin
            @(negedge clk);
            op    = t_op;
            a     = t_a;
            b     = t_b;
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            // Wait for done pulse
            @(posedge done);
            @(negedge clk); // settle
        end
    endtask

    // ── Task: check result ────────────────────────────────────────────────────
    task check;
        input [31:0]  got;
        input [31:0]  exp;
        input [255:0] name;
        begin
            if (got === exp) begin
                pass_count = pass_count + 1;
            end else begin
                fail_count = fail_count + 1;
                $display("FAIL  %-40s | got=0x%08h  exp=0x%08h", name, got, exp);
            end
        end
    endtask

    // ── Main test sequence ────────────────────────────────────────────────────
    initial begin
        pass_count = 0;
        fail_count = 0;
        start = 0; op = 0; a = 0; b = 0;

        // Reset
        rst = 1;
        repeat(4) @(posedge clk);
        @(negedge clk); rst = 0;

        // ──────────────────────────────────────────────────────────────────────
        $display("=== MUL (lower 32 bits of signed product) ===");
        // ──────────────────────────────────────────────────────────────────────

        run_op(MUL, 32'd3, 32'd7);
        check(result, 32'd21, "MUL  3 * 7");

        run_op(MUL, 32'hFFFFFFFF, 32'hFFFFFFFF);   // (-1)*(-1) lower = 1
        check(result, 32'd1, "MUL -1 * -1 (lower)");

        run_op(MUL, 32'd0, 32'hDEADBEEF);
        check(result, 32'd0, "MUL  0 * x");

        run_op(MUL, 32'h80000000, 32'd2);           // INT_MIN * 2 lower = 0
        check(result, 32'd0, "MUL  INT_MIN * 2 (lower)");

        run_op(MUL, 32'd1, 32'hDEADBEEF);
        check(result, 32'hDEADBEEF, "MUL  1 * DEADBEEF");

        run_op(MUL, 32'hFFFFFFFF, 32'd2);           // (-1)*2 lower = -2 = 0xFFFFFFFE
        check(result, 32'hFFFFFFFE, "MUL -1 * 2 (lower)");

        run_op(MUL, 32'd100, 32'd200);
        check(result, 32'd20000, "MUL  100 * 200");

        run_op(MUL, 32'h00010001, 32'h00010001);   // 65537 * 65537 = 4295098369 → lower = 0x00020001
        check(result, 32'h00020001, "MUL  65537 * 65537 (lower)");

        // ──────────────────────────────────────────────────────────────────────
        $display("=== MULH (upper 32 bits, signed × signed) ===");
        // ──────────────────────────────────────────────────────────────────────

        run_op(MULH, 32'd3, 32'd7);                 // upper = 0
        check(result, 32'd0, "MULH  3 * 7 (upper)");

        run_op(MULH, 32'hFFFFFFFF, 32'hFFFFFFFF);  // (-1)*(-1) = 1; upper = 0
        check(result, 32'd0, "MULH -1 * -1 (upper)");

        run_op(MULH, 32'h80000000, 32'h80000000);  // (-2^31)*(-2^31) = 2^62; upper = 0x40000000
        check(result, 32'h40000000, "MULH  INT_MIN * INT_MIN (upper)");

        run_op(MULH, 32'h80000000, 32'd1);          // (-2^31)*1; upper = -1 = 0xFFFFFFFF
        check(result, 32'hFFFFFFFF, "MULH  INT_MIN * 1 (upper)");

        run_op(MULH, 32'hFFFFFFFF, 32'd1);          // (-1)*1; upper = -1 = 0xFFFFFFFF
        check(result, 32'hFFFFFFFF, "MULH -1 * 1 (upper)");

        run_op(MULH, 32'h7FFFFFFF, 32'h7FFFFFFF);  // INT_MAX^2 upper = 0x3FFFFFFF
        check(result, 32'h3FFFFFFF, "MULH  INT_MAX * INT_MAX (upper)");

        // ──────────────────────────────────────────────────────────────────────
        $display("=== MULHSU (upper 32 bits, signed × unsigned) ===");
        // ──────────────────────────────────────────────────────────────────────

        run_op(MULHSU, 32'hFFFFFFFF, 32'hFFFFFFFF);// (-1)*0xFFFFFFFF; upper = -1
        check(result, 32'hFFFFFFFF, "MULHSU -1 * 0xFFFFFFFF (upper)");

        run_op(MULHSU, 32'd1, 32'hFFFFFFFF);        // 1 * 0xFFFFFFFF; upper = 0
        check(result, 32'd0, "MULHSU  1 * 0xFFFFFFFF (upper)");

        run_op(MULHSU, 32'h80000000, 32'hFFFFFFFF); // -2^31 * (2^32-1) = -(2^63-2^31); upper = 0x80000000
        check(result, 32'h80000000, "MULHSU  INT_MIN * 0xFFFFFFFF (upper)");

        run_op(MULHSU, 32'd0, 32'hFFFFFFFF);
        check(result, 32'd0, "MULHSU  0 * 0xFFFFFFFF");

        // ──────────────────────────────────────────────────────────────────────
        $display("=== MULHU (upper 32 bits, unsigned × unsigned) ===");
        // ──────────────────────────────────────────────────────────────────────

        run_op(MULHU, 32'hFFFFFFFF, 32'hFFFFFFFF); // (2^32-1)^2 upper = 0xFFFFFFFE
        check(result, 32'hFFFFFFFE, "MULHU  0xFFFF * 0xFFFF (upper)");

        run_op(MULHU, 32'd1, 32'hFFFFFFFF);         // 1*(2^32-1); upper = 0
        check(result, 32'd0, "MULHU  1 * 0xFFFFFFFF (upper)");

        run_op(MULHU, 32'd0, 32'hFFFFFFFF);
        check(result, 32'd0, "MULHU  0 * 0xFFFFFFFF");

        // ──────────────────────────────────────────────────────────────────────
        $display("=== DIV (signed division) ===");
        // ──────────────────────────────────────────────────────────────────────

        run_op(DIV, 32'd20, 32'd5);
        check(result, 32'd4, "DIV  20 / 5");

        run_op(DIV, 32'hFFFFFFEB, 32'hFFFFFFFF);   // (-21) / (-1) = 21
        check(result, 32'd21, "DIV -21 / -1");

        run_op(DIV, 32'hFFFFFFEB, 32'd7);           // (-21) / 7 = -3
        check(result, 32'hFFFFFFFD, "DIV -21 / 7");

        run_op(DIV, 32'd20, 32'hFFFFFFFB);          // 20 / (-5) = -4
        check(result, 32'hFFFFFFFC, "DIV  20 / -5");

        run_op(DIV, 32'd7, 32'd0);                  // div-by-zero → 0xFFFFFFFF
        check(result, 32'hFFFFFFFF, "DIV  7 / 0 (div-by-zero)");

        run_op(DIV, 32'h80000000, 32'hFFFFFFFF);   // overflow → INT_MIN
        check(result, 32'h80000000, "DIV  INT_MIN / -1 (overflow)");

        run_op(DIV, 32'd0, 32'd5);                  // 0 / 5 = 0
        check(result, 32'd0, "DIV  0 / 5");

        run_op(DIV, 32'd1, 32'd1);
        check(result, 32'd1, "DIV  1 / 1");

        // ──────────────────────────────────────────────────────────────────────
        $display("=== DIVU (unsigned division) ===");
        // ──────────────────────────────────────────────────────────────────────

        run_op(DIVU, 32'd20, 32'd5);
        check(result, 32'd4, "DIVU  20 / 5");

        run_op(DIVU, 32'hFFFFFFFF, 32'd1);          // (2^32-1) / 1
        check(result, 32'hFFFFFFFF, "DIVU  0xFFFFFFFF / 1");

        run_op(DIVU, 32'hFFFFFFFF, 32'hFFFFFFFF);   // 1
        check(result, 32'd1, "DIVU  0xFFFFFFFF / 0xFFFFFFFF");

        run_op(DIVU, 32'd5, 32'd0);                 // div-by-zero → 0xFFFFFFFF
        check(result, 32'hFFFFFFFF, "DIVU  5 / 0 (div-by-zero)");

        run_op(DIVU, 32'h80000000, 32'h7FFFFFFF);   // 2^31 / (2^31-1) = 1
        check(result, 32'd1, "DIVU  0x80000000 / 0x7FFFFFFF");

        // ──────────────────────────────────────────────────────────────────────
        $display("=== REM (signed remainder) ===");
        // ──────────────────────────────────────────────────────────────────────

        run_op(REM, 32'd20, 32'd6);                 // 20 % 6 = 2
        check(result, 32'd2, "REM  20 % 6");

        run_op(REM, 32'hFFFFFFEB, 32'd7);           // (-21) % 7 = 0
        check(result, 32'd0, "REM -21 % 7");

        run_op(REM, 32'hFFFFFFEC, 32'd5);           // (-20) % 5 = 0
        check(result, 32'd0, "REM -20 % 5");

        run_op(REM, 32'hFFFFFFED, 32'd5);           // (-19) % 5 = -4 = 0xFFFFFFFC
        check(result, 32'hFFFFFFFC, "REM -19 % 5");

        run_op(REM, 32'd7, 32'd0);                  // div-by-zero → dividend = 7
        check(result, 32'd7, "REM  7 % 0 (div-by-zero)");

        run_op(REM, 32'h80000000, 32'hFFFFFFFF);    // overflow → 0
        check(result, 32'd0, "REM  INT_MIN % -1 (overflow)");

        run_op(REM, 32'd0, 32'd7);                  // 0 % 7 = 0
        check(result, 32'd0, "REM  0 % 7");

        // ──────────────────────────────────────────────────────────────────────
        $display("=== REMU (unsigned remainder) ===");
        // ──────────────────────────────────────────────────────────────────────

        run_op(REMU, 32'd20, 32'd6);                // 20 % 6 = 2
        check(result, 32'd2, "REMU  20 % 6");

        run_op(REMU, 32'hFFFFFFFF, 32'hFFFFFFFE);   // (2^32-1) % (2^32-2) = 1
        check(result, 32'd1, "REMU  0xFFFFFFFF % 0xFFFFFFFE");

        run_op(REMU, 32'd5, 32'd0);                 // div-by-zero → dividend = 5
        check(result, 32'd5, "REMU  5 % 0 (div-by-zero)");

        run_op(REMU, 32'hFFFFFFFF, 32'hFFFFFFFF);   // 0
        check(result, 32'd0, "REMU  0xFFFFFFFF % 0xFFFFFFFF");

        run_op(REMU, 32'h80000000, 32'h7FFFFFFF);   // 2^31 % (2^31-1) = 1
        check(result, 32'd1, "REMU  0x80000000 % 0x7FFFFFFF");

        // ── Summary ──────────────────────────────────────────────────────────
        $display("");
        $display("=== MulDiv Results: %0d passed, %0d failed ===",
                 pass_count, fail_count);
        if (fail_count == 0)
            $display("ALL PASSED");
        else
            $display("FAILURES DETECTED");
        $finish;
    end

    // Safety timeout
    initial begin
        #500000;
        $display("TIMEOUT — simulation hung");
        $finish;
    end

endmodule
