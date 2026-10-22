`timescale 1ns / 1ps
// branchCtrl (src/branchCtrl.v), the core's one comparator, against RV32I
// (Unprivileged ISA 2.5): BEQ, BNE, BLT, BGE, BLTU, BGEU on every pair of
// boundary operands and a seeded random run (+SEED=, +N=); and its outputs
// to the ALU on every vector: diff = r1 - r2, lt_signed, lt_unsigned
// (branchCtrl's header). funct3 010 and 011 are reserved branch encodings the
// controller makes illegal, so their branchValid is not checked. Prints
// PASS/FAIL with the number of checks.
module tb_branchCtrl;
    reg  [2:0]  funct3;
    reg  [31:0] r1, r2;
    wire        branchValid, lts, ltu;
    wire [31:0] diff;
    branchCtrl uut(.funct3(funct3), .r1(r1), .r2(r2), .branchValid(branchValid),
                   .diff(diff), .lt_signed(lts), .lt_unsigned(ltu));

    integer checks = 0, fails = 0, seed = 1, n = 100000, i, j, k;
    integer seed0 = 1;
    reg [31:0] corner [0:11];
    reg        e_lts, e_ltu, e_taken;

    task check;
        begin
            #1;
            e_lts = $signed(r1) < $signed(r2);
            e_ltu = r1 < r2;
            case (funct3)
                3'b000: e_taken = (r1 == r2);
                3'b001: e_taken = (r1 != r2);
                3'b100: e_taken = e_lts;
                3'b101: e_taken = !e_lts;
                3'b110: e_taken = e_ltu;
                3'b111: e_taken = !e_ltu;
                default: e_taken = 1'bx;
            endcase
            checks = checks + 3;
            if (diff !== r1 - r2 || lts !== e_lts || ltu !== e_ltu) begin
                fails = fails + 1;
                if (fails <= 25)
                    $display("FAIL r1=%08h r2=%08h: diff %08h lt_signed %b lt_unsigned %b, want %08h %b %b",
                             r1, r2, diff, lts, ltu, r1 - r2, e_lts, e_ltu);
            end
            if (e_taken !== 1'bx) begin
                checks = checks + 1;
                if (branchValid !== e_taken) begin
                    fails = fails + 1;
                    if (fails <= 25)
                        $display("FAIL funct3=%03b r1=%08h r2=%08h: taken %b want %b", funct3, r1, r2, branchValid, e_taken);
                end
            end
        end
    endtask

    initial begin
        if ($value$plusargs("SEED=%d", seed)) ;
        seed0 = seed;   // $random(seed) moves seed on: report the one that reproduces the run
        if ($value$plusargs("N=%d", n)) ;
        $display("=== Branch Controller Testbench (RV32I model, seed %0d) ===", seed);
        corner[0] = 0; corner[1] = 1; corner[2] = 32'hFFFF_FFFF; corner[3] = 32'h8000_0000;
        corner[4] = 32'h7FFF_FFFF; corner[5] = 32'h8000_0001; corner[6] = 32'hFFFF_FFFE;
        corner[7] = 32'h7FFF_FFFE; corner[8] = 32'h0000_8000; corner[9] = 32'hFFFF_7FFF;
        corner[10] = 32'h0001_0000; corner[11] = 32'h0000_FFFF;
        for (k = 0; k < 8; k = k + 1)
            for (i = 0; i < 12; i = i + 1)
                for (j = 0; j < 12; j = j + 1) begin
                    funct3 = k; r1 = corner[i]; r2 = corner[j]; check;
                end
        for (i = 0; i < n; i = i + 1) begin
            funct3 = $random(seed);
            r1 = $random(seed);
            case ($unsigned($random(seed)) % 6)
                0: r2 = r1;                                   // equal
                1: r2 = r1 ^ 32'h8000_0000;                   // differ only in the sign
                2: r2 = r1 ^ (32'h1 << ($unsigned($random(seed)) % 32));  // one bit apart
                3: r2 = r1 + 1;
                default: r2 = $random(seed);
            endcase
            check;
        end
        if (fails == 0) $display("PASS tb_branchCtrl (%0d checks, seed %0d)", checks, seed0);
        else            $display("FAIL tb_branchCtrl: %0d failures, %0d checks, seed %0d", fails, checks, seed0);
        $finish;
    end
endmodule
