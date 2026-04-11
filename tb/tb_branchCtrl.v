`timescale 1ns / 1ps
module tb_branchCtrl;
    reg  [2:0]  funct3;
    reg  [31:0] r1, r2;
    wire        branchValid;
    integer pass_count = 0, fail_count = 0;

    branchCtrl uut(.funct3(funct3), .r1(r1), .r2(r2), .branchValid(branchValid));

    task check(input expected, input [159:0] name);
        begin
            #1;
            if (branchValid === expected) begin
                pass_count = pass_count + 1;
            end else begin
                fail_count = fail_count + 1;
                $display("FAIL: %0s | f3=%03b r1=0x%08h r2=0x%08h | got=%b exp=%b",
                         name, funct3, r1, r2, branchValid, expected);
            end
        end
    endtask

    initial begin
        $dumpfile("tb_branchCtrl.vcd");
        $dumpvars(0, tb_branchCtrl);
        $display("=== Branch Controller Testbench ===");

        // ---- BEQ (000) ----
        funct3 = 3'b000;
        r1 = 32'd5;  r2 = 32'd5;  check(1'b1, "BEQ equal");
        r1 = 32'd5;  r2 = 32'd6;  check(1'b0, "BEQ not equal");
        r1 = 32'h0;  r2 = 32'h0;  check(1'b1, "BEQ both zero");
        r1 = 32'hFFFFFFFF; r2 = 32'hFFFFFFFF; check(1'b1, "BEQ both -1");
        r1 = 32'h80000000; r2 = 32'h80000000; check(1'b1, "BEQ both min");

        // ---- BNE (001) ----
        funct3 = 3'b001;
        r1 = 32'd5;  r2 = 32'd6;  check(1'b1, "BNE different");
        r1 = 32'd5;  r2 = 32'd5;  check(1'b0, "BNE equal");
        r1 = 32'h0;  r2 = 32'h1;  check(1'b1, "BNE 0 vs 1");
        r1 = 32'h80000000; r2 = 32'h7FFFFFFF; check(1'b1, "BNE min vs max");

        // ---- BLT (100) signed less than ----
        funct3 = 3'b100;
        r1 = 32'd3;  r2 = 32'd5;  check(1'b1, "BLT 3<5");
        r1 = 32'd5;  r2 = 32'd3;  check(1'b0, "BLT 5>3");
        r1 = 32'd5;  r2 = 32'd5;  check(1'b0, "BLT equal");
        r1 = 32'hFFFFFFFF; r2 = 32'd0; check(1'b1, "BLT -1<0");
        r1 = 32'd0; r2 = 32'hFFFFFFFF; check(1'b0, "BLT 0>-1");
        r1 = 32'h80000000; r2 = 32'h7FFFFFFF; check(1'b1, "BLT min<max");
        r1 = 32'h7FFFFFFF; r2 = 32'h80000000; check(1'b0, "BLT max>min");
        r1 = 32'hFFFFFFFE; r2 = 32'hFFFFFFFF; check(1'b1, "BLT -2<-1");
        r1 = 32'h80000000; r2 = 32'h80000001; check(1'b1, "BLT min<min+1");

        // ---- BGE (101) signed greater or equal ----
        funct3 = 3'b101;
        r1 = 32'd5;  r2 = 32'd3;  check(1'b1, "BGE 5>=3");
        r1 = 32'd3;  r2 = 32'd5;  check(1'b0, "BGE 3<5");
        r1 = 32'd5;  r2 = 32'd5;  check(1'b1, "BGE equal");
        r1 = 32'd0;  r2 = 32'hFFFFFFFF; check(1'b1, "BGE 0>=-1");
        r1 = 32'hFFFFFFFF; r2 = 32'd0; check(1'b0, "BGE -1<0");
        r1 = 32'h7FFFFFFF; r2 = 32'h80000000; check(1'b1, "BGE max>=min");

        // ---- BLTU (110) unsigned less than ----
        funct3 = 3'b110;
        r1 = 32'd3;  r2 = 32'd5;  check(1'b1, "BLTU 3<5");
        r1 = 32'd5;  r2 = 32'd3;  check(1'b0, "BLTU 5>3");
        r1 = 32'd5;  r2 = 32'd5;  check(1'b0, "BLTU equal");
        r1 = 32'd0;  r2 = 32'hFFFFFFFF; check(1'b1, "BLTU 0<maxu");
        r1 = 32'hFFFFFFFF; r2 = 32'd0; check(1'b0, "BLTU maxu>0");
        r1 = 32'h7FFFFFFF; r2 = 32'h80000000; check(1'b1, "BLTU 7F<80u");
        r1 = 32'h80000000; r2 = 32'h7FFFFFFF; check(1'b0, "BLTU 80>7Fu");

        // ---- BGEU (111) unsigned greater or equal ----
        funct3 = 3'b111;
        r1 = 32'd5;  r2 = 32'd3;  check(1'b1, "BGEU 5>=3");
        r1 = 32'd3;  r2 = 32'd5;  check(1'b0, "BGEU 3<5");
        r1 = 32'd5;  r2 = 32'd5;  check(1'b1, "BGEU equal");
        r1 = 32'hFFFFFFFF; r2 = 32'd0; check(1'b1, "BGEU maxu>=0");
        r1 = 32'd0; r2 = 32'hFFFFFFFF; check(1'b0, "BGEU 0<maxu");
        r1 = 32'h80000000; r2 = 32'h7FFFFFFF; check(1'b1, "BGEU 80>=7Fu");

        // ---- Invalid funct3 (010, 011) ----
        funct3 = 3'b010;
        r1 = 32'd1; r2 = 32'd2; check(1'b0, "Invalid f3=010");
        funct3 = 3'b011;
        r1 = 32'd1; r2 = 32'd2; check(1'b0, "Invalid f3=011");

        $display("\n=== Branch Results: %0d passed, %0d failed ===", pass_count, fail_count);
        if (fail_count == 0) $display("ALL BRANCH TESTS PASSED");
        $finish;
    end
endmodule
