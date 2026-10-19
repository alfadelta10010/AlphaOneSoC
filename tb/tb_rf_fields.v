`timescale 1ns / 1ps
// rf_fields (src/decoder.v) against what EX will decode. fyracore puts
// rf_fields' registers on the register file's read addresses when IF/EX takes
// an instruction, and EX later uses the data for decoder's rs1/rs2 (masked to
// 0 where those are x0). So wherever decoder's field is not x0, rf_fields must
// name the same register, or EX computes with another register's value.
//
//   - every 16-bit encoding (bits [1:0] != 11) that compressed_decoder
//     accepts, expanded and decoded as EX does it, with random upper halves
//     (the fetch's upper 16 bits are the next instruction's)
//   - 32-bit words: every opcode, 2,048 random words each
module tb_rf_fields;
    reg  [31:0] fetched;
    wire [31:0] expanded;
    wire        c_illegal;
    wire [4:0]  f_rs1, f_rs2;
    wire [6:0]  opcode;
    wire [4:0]  rd, d_rs1, d_rs2;
    wire [2:0]  funct3;
    wire [6:0]  funct7;
    wire        compressed = (fetched[1:0] != 2'b11);

    compressed_decoder cdec(.instr_in(fetched[15:0]), .instr_out(expanded), .illegal(c_illegal));
    decoder dec(.instIn(compressed ? expanded : fetched), .opcode(opcode), .rd(rd),
                .rs1(d_rs1), .rs2(d_rs2), .funct3(funct3), .funct7(funct7));
    rf_fields uut(.instr(fetched), .rs1(f_rs1), .rs2(f_rs2));

    integer i, k, op, n_c = 0, n_c_ill = 0, n_32 = 0, checks = 0, fails = 0;
    integer n_rs1 = 0, n_rs2 = 0;

    task check;
        begin
            #1;
            if (d_rs1 != 5'd0) begin
                checks = checks + 1; n_rs1 = n_rs1 + 1;
                if (f_rs1 !== d_rs1) begin
                    fails = fails + 1;
                    if (fails <= 20)
                        $display("FAIL: rs1 fetched=0x%08h decoded x%0d, rf_fields x%0d", fetched, d_rs1, f_rs1);
                end
            end
            if (d_rs2 != 5'd0) begin
                checks = checks + 1; n_rs2 = n_rs2 + 1;
                if (f_rs2 !== d_rs2) begin
                    fails = fails + 1;
                    if (fails <= 20)
                        $display("FAIL: rs2 fetched=0x%08h decoded x%0d, rf_fields x%0d", fetched, d_rs2, f_rs2);
                end
            end
        end
    endtask

    initial begin
        $display("=== rf_fields Testbench ===");
        for (i = 0; i < 65536; i = i + 1) begin
            if (i[1:0] != 2'b11) begin
                fetched = i;
                fetched[31:16] = $random;
                #1;
                if (c_illegal) n_c_ill = n_c_ill + 1;
                else begin
                    n_c = n_c + 1;
                    check;
                end
            end
        end
        for (op = 0; op < 32; op = op + 1)
            for (k = 0; k < 2048; k = k + 1) begin
                fetched = $random;
                fetched[6:0] = {op[4:0], 2'b11};
                n_32 = n_32 + 1;
                check;
            end
        $display("compressed: %0d legal, %0d illegal skipped; 32-bit: %0d words", n_c, n_c_ill, n_32);
        $display("register fields checked: %0d rs1, %0d rs2", n_rs1, n_rs2);
        if (n_c + n_c_ill != 49152) begin
            $display("FAIL: walked %0d compressed encodings, not 49152", n_c + n_c_ill);
            fails = fails + 1;
        end
        $display("\n=== rf_fields Results: %0d checks, %0d failed ===", checks, fails);
        if (fails == 0) $display("PASS tb_rf_fields (%0d checks)", checks);
        else            $display("FAIL tb_rf_fields: %0d failures, %0d checks", fails, checks);
        $finish;
    end
endmodule
