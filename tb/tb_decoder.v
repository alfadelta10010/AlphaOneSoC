`timescale 1ns / 1ps
module tb_decoder;
    // decoder (src/decoder.v) against the RV32 instruction formats
    // (Unprivileged ISA 2.2 and the A, Zicsr, Zifencei chapters): for each
    // opcode the fields its format has -- rd [11:7], rs1 [19:15], rs2 [24:20],
    // funct3 [14:12], funct7 [31:25] -- must be extracted, and a register
    // field the format does not have must read 0. That is load-bearing:
    // fyracore masks a register read with the decoded field (rd/rs1/rs2 = 0
    // means x0), so LUI's operand is x0 because LUI has no rs1, and the
    // use-hazard compare sees no register the instruction does not read. A
    // funct3/funct7 the format lacks is not checked, nor funct7 of the OP-IMM
    // instructions other than the shifts (its bits are immediate there). Every
    // one of the 128 opcodes gets 4096 seeded random words (+SEED=). Prints
    // PASS/FAIL with the number of checks.
    reg  [31:0] instIn;
    wire [6:0]  opcode;
    wire [4:0]  rd, rs1, rs2;
    wire [2:0]  funct3;
    wire [6:0]  funct7;
    decoder uut(.instIn(instIn), .opcode(opcode), .rd(rd), .rs1(rs1),
                .rs2(rs2), .funct3(funct3), .funct7(funct7));

    integer checks = 0, fails = 0, seed = 1, op, k;
    integer seed0 = 1;
    reg h_rd, h_rs1, h_rs2, h_f3, h_f7;

    task automatic chk(input [8*7-1:0] what, input [6:0] got, input [6:0] want);
        begin
            checks = checks + 1;
            if (got !== want) begin
                fails = fails + 1;
                if (fails <= 25) $display("FAIL instr=%08h %0s: got %0d want %0d", instIn, what, got, want);
            end
        end
    endtask

    task check;
        begin
            {h_rd, h_rs1, h_rs2, h_f3, h_f7} = 5'b00000;
            case (instIn[6:0])
                7'b0110011: {h_rd, h_rs1, h_rs2, h_f3, h_f7} = 5'b11111;              // OP
                7'b0010011: {h_rd, h_rs1, h_rs2, h_f3, h_f7} = {4'b1101, instIn[13:12] == 2'b01}; // OP-IMM
                7'b0000011: {h_rd, h_rs1, h_rs2, h_f3, h_f7} = 5'b11010;              // LOAD
                7'b0100011: {h_rd, h_rs1, h_rs2, h_f3, h_f7} = 5'b01110;              // STORE
                7'b1100011: {h_rd, h_rs1, h_rs2, h_f3, h_f7} = 5'b01110;              // BRANCH
                7'b0110111, 7'b0010111, 7'b1101111:
                            {h_rd, h_rs1, h_rs2, h_f3, h_f7} = 5'b10000;              // LUI, AUIPC, JAL
                7'b1100111: {h_rd, h_rs1, h_rs2, h_f3, h_f7} = 5'b11010;              // JALR
                7'b1110011: {h_rd, h_rs1, h_rs2, h_f3, h_f7} = 5'b11011;              // SYSTEM
                7'b0001111: {h_rd, h_rs1, h_rs2, h_f3, h_f7} = 5'b00010;              // MISC-MEM
                7'b0101111: {h_rd, h_rs1, h_rs2, h_f3, h_f7} = 5'b11111;              // AMO
                default: ;
            endcase
            #1;
            chk("opcode", opcode, instIn[6:0]);
            chk("rd",  {2'b0, rd},  h_rd  ? {2'b0, instIn[11:7]}  : 7'd0);
            chk("rs1", {2'b0, rs1}, h_rs1 ? {2'b0, instIn[19:15]} : 7'd0);
            chk("rs2", {2'b0, rs2}, h_rs2 ? {2'b0, instIn[24:20]} : 7'd0);
            if (h_f3) chk("funct3", {4'b0, funct3}, {4'b0, instIn[14:12]});
            if (h_f7) chk("funct7", funct7, instIn[31:25]);
        end
    endtask

    initial begin
        if ($value$plusargs("SEED=%d", seed)) ;
        seed0 = seed;   // $random(seed) moves seed on: report the one that reproduces the run
        $display("=== Decoder Testbench (RV32 formats, seed %0d) ===", seed);
        for (op = 0; op < 128; op = op + 1)
            for (k = 0; k < 4096; k = k + 1) begin
                instIn = (k == 0) ? 32'hFFFF_FFFF : (k == 1) ? 32'h0 : $random(seed);
                instIn[6:0] = op;
                check;
            end
        if (fails == 0) $display("PASS tb_decoder (%0d checks, seed %0d)", checks, seed0);
        else            $display("FAIL tb_decoder: %0d failures, %0d checks, seed %0d", fails, checks, seed0);
        $finish;
    end
endmodule
