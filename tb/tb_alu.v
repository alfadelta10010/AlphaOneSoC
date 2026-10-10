`timescale 1ns / 1ps
module tb_alu;
    reg  [31:0] d1, d2;
    reg  [4:0]  control;
    wire [31:0] result;
    integer pass_count = 0, fail_count = 0;

    // SUB and SLT(U) come from the core's shared comparator (branchCtrl.v),
    // which fyracore feeds the same operands.
    wire [31:0] sub_res;
    wire        lts, ltu;
    branchCtrl cmp(.funct3(3'b000), .r1(d1), .r2(d2), .branchValid(),
                   .diff(sub_res), .lt_signed(lts), .lt_unsigned(ltu));
    alu uut(.d1(d1), .d2(d2), .sub_res(sub_res), .lt_signed(lts), .lt_unsigned(ltu),
            .result(result), .control(control));

    task check(input [31:0] expected, input [159:0] name);
        begin
            #1;
            if (result === expected) begin
                pass_count = pass_count + 1;
            end else begin
                fail_count = fail_count + 1;
                $display("FAIL: %0s | d1=0x%08h d2=0x%08h ctrl=%05b | got=0x%08h exp=0x%08h",
                         name, d1, d2, control, result, expected);
            end
        end
    endtask

    initial begin
        $dumpfile("tb_alu.vcd");
        $dumpvars(0, tb_alu);
        $display("=== ALU Testbench ===");

        // ---- ADD (00000) ----
        control = 5'b00000;
        d1 = 32'd10; d2 = 32'd20; check(32'd30, "ADD basic");
        d1 = 32'h0; d2 = 32'h0; check(32'h0, "ADD zero+zero");
        d1 = 32'hFFFFFFFF; d2 = 32'h1; check(32'h0, "ADD wrap");
        d1 = 32'h7FFFFFFF; d2 = 32'h1; check(32'h80000000, "ADD signed ovf");
        d1 = 32'h80000000; d2 = 32'h80000000; check(32'h0, "ADD min+min");
        d1 = 32'hFFFFFFFF; d2 = 32'hFFFFFFFF; check(32'hFFFFFFFE, "ADD -1+-1");
        d1 = 32'hDEADBEEF; d2 = 32'h0; check(32'hDEADBEEF, "ADD identity");

        // ---- SUB (01000) ----
        control = 5'b01000;
        d1 = 32'd30; d2 = 32'd10; check(32'd20, "SUB basic");
        d1 = 32'd10; d2 = 32'd30; check(32'hFFFFFFEC, "SUB negative");
        d1 = 32'h0; d2 = 32'h0; check(32'h0, "SUB zero");
        d1 = 32'h80000000; d2 = 32'h1; check(32'h7FFFFFFF, "SUB min-1");
        d1 = 32'h0; d2 = 32'h80000000; check(32'h80000000, "SUB 0-min");
        d1 = 32'hFFFFFFFF; d2 = 32'hFFFFFFFF; check(32'h0, "SUB self");

        // SLL, SRL and SRA are done serially in muldiv.v (tb_muldiv.v).

        // ---- SLT (00010) ----
        control = 5'b00010;
        d1 = 32'd5; d2 = 32'd10; check(32'h1, "SLT 5<10");
        d1 = 32'd10; d2 = 32'd5; check(32'h0, "SLT 10>5");
        d1 = 32'd5; d2 = 32'd5; check(32'h0, "SLT equal");
        d1 = 32'hFFFFFFFF; d2 = 32'd0; check(32'h1, "SLT -1<0");
        d1 = 32'd0; d2 = 32'hFFFFFFFF; check(32'h0, "SLT 0>-1");
        d1 = 32'h80000000; d2 = 32'h7FFFFFFF; check(32'h1, "SLT min<max");
        d1 = 32'h7FFFFFFF; d2 = 32'h80000000; check(32'h0, "SLT max>min");
        d1 = 32'h80000000; d2 = 32'h80000000; check(32'h0, "SLT min==min");
        d1 = 32'hFFFFFFFE; d2 = 32'hFFFFFFFF; check(32'h1, "SLT -2<-1");
        d1 = 32'hFFFFFFFF; d2 = 32'hFFFFFFFE; check(32'h0, "SLT -1>-2");

        // ---- SLTU (00011) ----
        control = 5'b00011;
        d1 = 32'd5; d2 = 32'd10; check(32'h1, "SLTU 5<10");
        d1 = 32'd10; d2 = 32'd5; check(32'h0, "SLTU 10>5");
        d1 = 32'hFFFFFFFF; d2 = 32'd0; check(32'h0, "SLTU FF>0u");
        d1 = 32'd0; d2 = 32'hFFFFFFFF; check(32'h1, "SLTU 0<FFu");
        d1 = 32'h0; d2 = 32'h0; check(32'h0, "SLTU 0==0");
        d1 = 32'h80000000; d2 = 32'h7FFFFFFF; check(32'h0, "SLTU 80>7Fu");
        d1 = 32'd0; d2 = 32'd1; check(32'h1, "SLTU 0<1");

        // ---- XOR (00100) ----
        control = 5'b00100;
        d1 = 32'hFF00FF00; d2 = 32'h0F0F0F0F; check(32'hF00FF00F, "XOR pattern");
        d1 = 32'hFFFFFFFF; d2 = 32'hFFFFFFFF; check(32'h0, "XOR self=0");
        d1 = 32'h0; d2 = 32'h0; check(32'h0, "XOR zero");
        d1 = 32'hFFFFFFFF; d2 = 32'h0; check(32'hFFFFFFFF, "XOR with 0");
        d1 = 32'hAAAAAAAA; d2 = 32'h55555555; check(32'hFFFFFFFF, "XOR complement");

        // ---- OR (00110) ----
        control = 5'b00110;
        d1 = 32'hFF00FF00; d2 = 32'h0F0F0F0F; check(32'hFF0FFF0F, "OR pattern");
        d1 = 32'h0; d2 = 32'h0; check(32'h0, "OR zeros");
        d1 = 32'hFFFFFFFF; d2 = 32'h0; check(32'hFFFFFFFF, "OR with 0");

        // ---- AND (00111) ----
        control = 5'b00111;
        d1 = 32'hFF00FF00; d2 = 32'h0F0F0F0F; check(32'h0F000F00, "AND pattern");
        d1 = 32'hFFFFFFFF; d2 = 32'h0; check(32'h0, "AND with 0");
        d1 = 32'hFFFFFFFF; d2 = 32'hFFFFFFFF; check(32'hFFFFFFFF, "AND all 1s");

        // M-extension (MUL/MULH/MULHSU/MULHU/DIV/DIVU/REM/REMU) is now handled
        // by the muldiv.v module, not the ALU.  Those operations are covered by
        // tb_muldiv.v.  The ALU returns 0 for op codes 5'b10xxx (default case).

        // ---- Default ----
        control = 5'b11111;
        d1 = 32'hDEADBEEF; d2 = 32'hCAFEBABE; check(32'h0, "Default=0");
        control = 5'b01001;
        d1 = 32'h12345678; d2 = 32'h9ABCDEF0; check(32'h0, "Unused op=0");

        $display("\n=== ALU Results: %0d passed, %0d failed ===", pass_count, fail_count);
        if (fail_count == 0) $display("ALL ALU TESTS PASSED");
        $finish;
    end
endmodule
