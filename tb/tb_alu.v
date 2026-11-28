`timescale 1ns / 1ps
// alu (src/alu.v) with the shared comparator it takes SUB/SLT/SLTU from
// (src/branchCtrl.v, wired as fyracore wires it: r2 = the ALU's d2), against
// RV32I (Unprivileged ISA 2.4): ADD, SUB, SLT, SLTU, XOR, OR, AND for the
// codes the controller issues for them (00000, 01000, 00010, 00011, 00100,
// 00110, 00111) and the single-cycle shifts SLL, SRL, SRA (00001, 00101,
// 01101; amount d2[4:0], the upper bits ignored). No other code is ever
// issued, so nothing is required of the ALU's output for them. Corners (0, 1, -1, INT_MIN, INT_MAX, and their neighbours) on both
// operands, then a seeded random run (+SEED=, +N=) half of whose operands are
// boundary values. Prints PASS/FAIL with the number of checks.
module tb_alu;
    reg  [31:0] d1, d2;
    reg  [4:0]  control;
    wire [31:0] result, sub_res;
    wire        lts, ltu;
    branchCtrl cmp(.funct3(3'b000), .r1(d1), .r2(d2), .branchValid(),
                   .diff(sub_res), .lt_signed(lts), .lt_unsigned(ltu));
    alu uut(.d1(d1), .d2(d2), .sub_res(sub_res), .lt_signed(lts), .lt_unsigned(ltu),
            .result(result), .control(control));

    integer checks = 0, fails = 0, seed = 1, n = 200000, i, j, k;
    integer seed0 = 1;
    reg [4:0]  codes [0:9];
    reg [31:0] corner [0:11];

    function [31:0] model(input [4:0] c, input [31:0] x, input [31:0] y);
        case (c)
            5'b00000: model = x + y;
            5'b01000: model = x - y;
            5'b00010: model = ($signed(x) < $signed(y)) ? 32'd1 : 32'd0;
            5'b00011: model = (x < y) ? 32'd1 : 32'd0;
            5'b00100: model = x ^ y;
            5'b00110: model = x | y;
            5'b00001: model = x << y[4:0];
            5'b00101: model = x >> y[4:0];
            5'b01101: model = $signed(x) >>> y[4:0];
            default:  model = x & y;       // 00111
        endcase
    endfunction

    task check;
        begin
            #1;
            checks = checks + 1;
            if (result !== model(control, d1, d2)) begin
                fails = fails + 1;
                if (fails <= 25)
                    $display("FAIL ctrl=%05b d1=%08h d2=%08h: got %08h want %08h",
                             control, d1, d2, result, model(control, d1, d2));
            end
        end
    endtask

    function [31:0] pick(input integer dummy);
        case ($unsigned($random(seed)) % 8)
            0: pick = corner[$unsigned($random(seed)) % 12];
            1: pick = 32'h1 << ($unsigned($random(seed)) % 32);
            2: pick = corner[$unsigned($random(seed)) % 12] + ($random(seed) % 3);
            default: pick = $random(seed);
        endcase
    endfunction

    initial begin
        if ($value$plusargs("SEED=%d", seed)) ;
        seed0 = seed;   // $random(seed) moves seed on: report the one that reproduces the run
        if ($value$plusargs("N=%d", n)) ;
        $display("=== ALU Testbench (RV32I model, seed %0d) ===", seed);
        codes[0] = 5'b00000; codes[1] = 5'b01000; codes[2] = 5'b00010; codes[3] = 5'b00011;
        codes[4] = 5'b00100; codes[5] = 5'b00110; codes[6] = 5'b00111;
        codes[7] = 5'b00001; codes[8] = 5'b00101; codes[9] = 5'b01101;
        corner[0] = 0; corner[1] = 1; corner[2] = 32'hFFFF_FFFF; corner[3] = 32'h8000_0000;
        corner[4] = 32'h7FFF_FFFF; corner[5] = 32'h8000_0001; corner[6] = 32'hFFFF_FFFE;
        corner[7] = 32'h7FFF_FFFE; corner[8] = 32'h0000_FFFF; corner[9] = 32'hFFFF_0000;
        corner[10] = 32'hAAAA_AAAA; corner[11] = 32'h5555_5555;
        for (k = 0; k < 10; k = k + 1)
            for (i = 0; i < 12; i = i + 1)
                for (j = 0; j < 12; j = j + 1) begin
                    control = codes[k]; d1 = corner[i]; d2 = corner[j]; check;
                end
        // every shift amount and direction on mixed-sign operands, shamt 0 and 31
        for (k = 7; k < 10; k = k + 1)
            for (j = 0; j < 64; j = j + 1) begin
                control = codes[k]; d1 = 32'hC3A5_96F1; d2 = j | (j[0] ? 32'hFFFF_FF00 : 0); check;
                control = codes[k]; d1 = 32'h5A5A_1234; d2 = j; check;
                control = codes[k]; d1 = 32'h8000_0000; d2 = j; check;
            end
        for (i = 0; i < n; i = i + 1) begin
            control = codes[$unsigned($random(seed)) % 10];
            d1 = pick(0); d2 = pick(0);
            if (($random(seed) & 15) == 0) d2 = d1;          // equal operands
            check;
        end
        if (fails == 0) $display("PASS tb_alu (%0d checks, seed %0d)", checks, seed0);
        else            $display("FAIL tb_alu: %0d failures, %0d checks, seed %0d", fails, checks, seed0);
        $finish;
    end
endmodule
