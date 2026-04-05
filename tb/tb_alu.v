`timescale 1ns / 1ps
module tb_alu;
    reg  [31:0] d1, d2;
    reg  [4:0]  control;
    wire [31:0] result;
    integer pass_count = 0, fail_count = 0;

    alu uut(.d1(d1), .d2(d2), .result(result), .control(control));

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

        // ---- SLL (00001) ----
        control = 5'b00001;
        d1 = 32'h1; d2 = 32'd0; check(32'h1, "SLL by 0");
        d1 = 32'h1; d2 = 32'd1; check(32'h2, "SLL by 1");
        d1 = 32'h1; d2 = 32'd31; check(32'h80000000, "SLL by 31");
        d1 = 32'hFFFFFFFF; d2 = 32'd4; check(32'hFFFFFFF0, "SLL fill");
        d1 = 32'hABCDEF01; d2 = 32'h00000020; check(32'hABCDEF01, "SLL shamt masked to 5 bits");
        d1 = 32'h12345678; d2 = 32'h00000010; check(32'h56780000, "SLL by 16");

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

        // ---- SRL (00101) ----
        control = 5'b00101;
        d1 = 32'h80000000; d2 = 32'd1; check(32'h40000000, "SRL sign>>1");
        d1 = 32'hFFFFFFFF; d2 = 32'd4; check(32'h0FFFFFFF, "SRL fill 0");
        d1 = 32'h80000000; d2 = 32'd31; check(32'h1, "SRL >>31");
        d1 = 32'hDEADBEEF; d2 = 32'd0; check(32'hDEADBEEF, "SRL >>0");
        d1 = 32'h12345678; d2 = 32'd8; check(32'h00123456, "SRL >>8");

        // ---- SRA (01101) ----
        control = 5'b01101;
        d1 = 32'h80000000; d2 = 32'd1; check(32'hC0000000, "SRA neg>>1");
        d1 = 32'h80000000; d2 = 32'd31; check(32'hFFFFFFFF, "SRA neg>>31");
        d1 = 32'h7FFFFFFF; d2 = 32'd1; check(32'h3FFFFFFF, "SRA pos>>1");
        d1 = 32'h40000000; d2 = 32'd0; check(32'h40000000, "SRA >>0");
        d1 = 32'hFFFFFF00; d2 = 32'd8; check(32'hFFFFFFFF, "SRA neg>>8");
        d1 = 32'h00FF0000; d2 = 32'd16; check(32'h000000FF, "SRA pos>>16");

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

        // ---- MUL (10000) ----
        control = 5'b10000;
        d1 = 32'd6; d2 = 32'd7; check(32'd42, "MUL 6*7");
        d1 = 32'd0; d2 = 32'd1000; check(32'd0, "MUL 0*x");
        d1 = 32'hFFFFFFFF; d2 = 32'hFFFFFFFF; check(32'h1, "MUL -1*-1");
        d1 = 32'hFFFFFFFF; d2 = 32'd2; check(32'hFFFFFFFE, "MUL -1*2");
        d1 = 32'd1; d2 = 32'd1; check(32'd1, "MUL 1*1");
        d1 = 32'h80000000; d2 = 32'd2; check(32'h0, "MUL min*2 low");
        d1 = 32'h10000; d2 = 32'h10000; check(32'h0, "MUL large low");

        // ---- MULH (10001) ----
        control = 5'b10001;
        d1 = 32'd6; d2 = 32'd7; check(32'h0, "MULH small");
        d1 = 32'hFFFFFFFF; d2 = 32'hFFFFFFFF; check(32'h0, "MULH -1*-1 hi");
        d1 = 32'hFFFFFFFF; d2 = 32'd2; check(32'hFFFFFFFF, "MULH -1*2 hi");
        d1 = 32'h80000000; d2 = 32'h80000000; check(32'h40000000, "MULH min*min");

        // ---- MULHU (10011) ----
        control = 5'b10011;
        d1 = 32'hFFFFFFFF; d2 = 32'hFFFFFFFF; check(32'hFFFFFFFE, "MULHU max*max");
        d1 = 32'd6; d2 = 32'd7; check(32'h0, "MULHU small");
        d1 = 32'h80000000; d2 = 32'd2; check(32'h1, "MULHU 80*2 hi");

        // ---- MULHSU (10010) ----
        control = 5'b10010;
        d1 = 32'hFFFFFFFF; d2 = 32'd2; check(32'hFFFFFFFF, "MULHSU -1*2u");
        d1 = 32'd2; d2 = 32'hFFFFFFFF; check(32'h1, "MULHSU 2*FFu");
        d1 = 32'd6; d2 = 32'd7; check(32'h0, "MULHSU small");

        // ---- DIV (10100) ----
        control = 5'b10100;
        d1 = 32'd42; d2 = 32'd6; check(32'd7, "DIV 42/6");
        d1 = 32'hFFFFFFFA; d2 = 32'd2; check(32'hFFFFFFFD, "DIV -6/2");
        d1 = 32'd10; d2 = 32'd0; check(32'hFFFFFFFF, "DIV by 0");
        d1 = 32'h80000000; d2 = 32'hFFFFFFFF; check(32'h80000000, "DIV overflow");
        d1 = 32'd7; d2 = 32'd2; check(32'd3, "DIV truncate");
        d1 = 32'hFFFFFFF9; d2 = 32'hFFFFFFFE; check(32'd3, "DIV -7/-2=3");

        // ---- DIVU (10101) ----
        control = 5'b10101;
        d1 = 32'd42; d2 = 32'd6; check(32'd7, "DIVU 42/6");
        d1 = 32'hFFFFFFFF; d2 = 32'd2; check(32'h7FFFFFFF, "DIVU FFu/2");
        d1 = 32'd10; d2 = 32'd0; check(32'hFFFFFFFF, "DIVU by 0");
        d1 = 32'd0; d2 = 32'd5; check(32'd0, "DIVU 0/5");

        // ---- REM (10110) ----
        control = 5'b10110;
        d1 = 32'd7; d2 = 32'd2; check(32'd1, "REM 7%2");
        d1 = 32'hFFFFFFF9; d2 = 32'd2; check(32'hFFFFFFFF, "REM -7%2=-1");
        d1 = 32'd10; d2 = 32'd0; check(32'd10, "REM by 0");
        d1 = 32'h80000000; d2 = 32'hFFFFFFFF; check(32'd0, "REM overflow");
        d1 = 32'd10; d2 = 32'd10; check(32'd0, "REM exact");

        // ---- REMU (10111) ----
        control = 5'b10111;
        d1 = 32'd7; d2 = 32'd2; check(32'd1, "REMU 7%2");
        d1 = 32'hFFFFFFFF; d2 = 32'd2; check(32'd1, "REMU FFu%2");
        d1 = 32'd10; d2 = 32'd0; check(32'd10, "REMU by 0");

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
