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
//
// Two checks, labelled apart:
//   FAIL(xchk)  rf_fields vs decoder(compressed_decoder(x)): two design blocks
//               against each other.
//   FAIL(model) rf_fields vs a table written from the spec (Unpriv ch. 2
//               formats, C chapter listings; a primed field r' names x(8+r')),
//               so a misreading shared by compressed_decoder and rf_fields
//               cannot pass.
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
    integer n_rs1 = 0, n_rs2 = 0, n_m_ill = 0, n_m_leg = 0, n_note = 0;


    // ── The spec model ──────────────────────────────────────────────────────
    // One case per instruction. m_legal: the encoding is an instruction on
    // this core (HINTs are legal); m_n1/m_n2: it reads rs1/rs2 (a read of x0
    // is modelled as no read); m_r1/m_r2: which register; m_row: its name.
    localparam NROW = 41;
    reg [8*10-1:0] rname [0:NROW-1];
    integer rcnt [0:NROW-1];
    reg        m_legal, m_n1, m_n2;
    reg [4:0]  m_r1, m_r2;
    integer    m_row;
    reg [4:0]  q_rd, q_p1, q_p2;
    reg        q_nz;

    task model;
        input [31:0] w;
        begin
            m_legal = 1'b1; m_n1 = 1'b0; m_n2 = 1'b0; m_r1 = 5'd0; m_r2 = 5'd0; m_row = 40;
            q_rd = w[11:7]; q_p1 = {2'b01, w[9:7]}; q_p2 = {2'b01, w[4:2]};
            case (w[1:0])
            2'b00: case (w[15:13])
                3'b000: begin m_row = 0; m_n1 = 1; m_r1 = 5'd2; m_legal = (w[12:5] != 8'd0); end
                3'b010: begin m_row = 1; m_n1 = 1; m_r1 = q_p1; end
                3'b110: begin m_row = 2; m_n1 = 1; m_r1 = q_p1; m_n2 = 1; m_r2 = q_p2; end
                default: m_legal = 1'b0;
            endcase
            2'b01: case (w[15:13])
                3'b000: begin m_row = 3; m_n1 = 1; m_r1 = q_rd; end
                3'b001: m_row = 21;
                3'b010: m_row = 22;
                3'b011: begin
                    q_nz = ({w[12], w[6:2]} != 6'd0);
                    if (q_rd == 5'd2) begin m_row = 4; m_n1 = 1; m_r1 = 5'd2; m_legal = q_nz; end
                    else begin m_row = 23; m_legal = q_nz; end
                end
                3'b100: case (w[11:10])
                    2'b00: begin m_row = 5; m_n1 = 1; m_r1 = q_p1; m_legal = !w[12]; end
                    2'b01: begin m_row = 6; m_n1 = 1; m_r1 = q_p1; m_legal = !w[12]; end
                    2'b10: begin m_row = 7; m_n1 = 1; m_r1 = q_p1; end
                    2'b11: begin
                        m_n1 = 1; m_r1 = q_p1; m_n2 = 1; m_r2 = q_p2;
                        m_legal = !w[12];
                        case (w[6:5])
                            2'b00: m_row = 8;
                            2'b01: m_row = 9;
                            2'b10: m_row = 10;
                            2'b11: m_row = 11;
                        endcase
                        if (w[12]) begin m_n1 = 0; m_n2 = 0; m_row = 40; end
                    end
                endcase
                3'b101: m_row = 24;
                3'b110: begin m_row = 12; m_n1 = 1; m_r1 = q_p1; end
                3'b111: begin m_row = 13; m_n1 = 1; m_r1 = q_p1; end
            endcase
            2'b10: case (w[15:13])
                3'b000: begin m_row = 14; m_n1 = 1; m_r1 = q_rd; m_legal = !w[12]; end
                3'b010: begin m_row = 15; m_n1 = 1; m_r1 = 5'd2; m_legal = (q_rd != 5'd0); end
                3'b100: begin
                    if (!w[12]) begin
                        if (w[6:2] == 5'd0) begin m_row = 16; m_n1 = 1; m_r1 = q_rd; m_legal = (q_rd != 5'd0); end
                        else begin m_row = 17; m_n2 = 1; m_r2 = w[6:2]; end
                    end else begin
                        if (q_rd == 5'd0 && w[6:2] == 5'd0) m_row = 25;
                        else if (w[6:2] == 5'd0) begin m_row = 18; m_n1 = 1; m_r1 = q_rd; end
                        else begin m_row = 19; m_n1 = 1; m_r1 = q_rd; m_n2 = 1; m_r2 = w[6:2]; end
                    end
                end
                3'b110: begin m_row = 20; m_n1 = 1; m_r1 = 5'd2; m_n2 = 1; m_r2 = w[6:2]; end
                default: m_legal = 1'b0;
            endcase
            2'b11: case (w[6:2])
                5'b01100: begin m_row = 26; m_n1 = 1; m_r1 = w[19:15]; m_n2 = 1; m_r2 = w[24:20]; end // OP
                5'b01011: begin m_row = 27; m_n1 = 1; m_r1 = w[19:15]; m_n2 = 1; m_r2 = w[24:20]; end // AMO
                5'b01000: begin m_row = 28; m_n1 = 1; m_r1 = w[19:15]; m_n2 = 1; m_r2 = w[24:20]; end // STORE
                5'b11000: begin m_row = 29; m_n1 = 1; m_r1 = w[19:15]; m_n2 = 1; m_r2 = w[24:20]; end // BRANCH
                5'b00100: begin m_row = 30; m_n1 = 1; m_r1 = w[19:15]; end // OP-IMM
                5'b00000: begin m_row = 31; m_n1 = 1; m_r1 = w[19:15]; end // LOAD
                5'b11001: begin m_row = 32; m_n1 = 1; m_r1 = w[19:15]; end // JALR
                5'b00011: begin m_row = 33; m_n1 = 1; m_r1 = w[19:15]; end // MISC-MEM
                5'b11100: begin m_row = 34; m_n1 = !w[14] && (w[14:12] != 3'b000); m_r1 = w[19:15]; end // SYSTEM: CSR reg forms
                5'b01101: m_row = 35; // LUI
                5'b00101: m_row = 36; // AUIPC
                5'b11011: m_row = 37; // JAL
                default: m_legal = 1'b0;
            endcase
            endcase
        end
    endtask

    task setnames;
        begin
            rname[0]="C.ADDI4SPN"; rname[1]="C.LW"; rname[2]="C.SW"; rname[3]="C.ADDI";
            rname[4]="C.ADDI16SP"; rname[5]="C.SRLI"; rname[6]="C.SRAI"; rname[7]="C.ANDI";
            rname[8]="C.SUB"; rname[9]="C.XOR"; rname[10]="C.OR"; rname[11]="C.AND";
            rname[12]="C.BEQZ"; rname[13]="C.BNEZ"; rname[14]="C.SLLI"; rname[15]="C.LWSP";
            rname[16]="C.JR"; rname[17]="C.MV"; rname[18]="C.JALR"; rname[19]="C.ADD";
            rname[20]="C.SWSP"; rname[21]="C.JAL"; rname[22]="C.LI"; rname[23]="C.LUI";
            rname[24]="C.J"; rname[25]="C.EBREAK"; rname[26]="OP"; rname[27]="AMO";
            rname[28]="STORE"; rname[29]="BRANCH"; rname[30]="OP-IMM"; rname[31]="LOAD";
            rname[32]="JALR"; rname[33]="MISC-MEM"; rname[34]="SYSTEM"; rname[35]="LUI";
            rname[36]="AUIPC"; rname[37]="JAL"; rname[38]="-"; rname[39]="-"; rname[40]="illegal";
        end
    endtask

    task mcheck;
        begin
            model(fetched);
            if (m_legal) begin
                if (m_n1 && m_r1 != 5'd0) begin
                    checks = checks + 1; rcnt[m_row] = rcnt[m_row] + 1;
                    if (f_rs1 !== m_r1) begin
                        fails = fails + 1;
                        if (fails <= 20)
                            $display("FAIL(model): rs1 fetched=0x%08h %0s: spec x%0d, rf_fields x%0d", fetched, rname[m_row], m_r1, f_rs1);
                    end
                end
                if (m_n2 && m_r2 != 5'd0) begin
                    checks = checks + 1; rcnt[m_row] = rcnt[m_row] + 1;
                    if (f_rs2 !== m_r2) begin
                        fails = fails + 1;
                        if (fails <= 20)
                            $display("FAIL(model): rs2 fetched=0x%08h %0s: spec x%0d, rf_fields x%0d", fetched, rname[m_row], m_r2, f_rs2);
                    end
                end
            end
        end
    endtask

    task check;
        begin
            #1;
            mcheck;
            if (d_rs1 != 5'd0) begin
                checks = checks + 1; n_rs1 = n_rs1 + 1;
                if (f_rs1 !== d_rs1) begin
                    fails = fails + 1;
                    if (fails <= 20)
                        $display("FAIL(xchk): rs1 fetched=0x%08h decoded x%0d, rf_fields x%0d", fetched, d_rs1, f_rs1);
                end
            end
            if (d_rs2 != 5'd0) begin
                checks = checks + 1; n_rs2 = n_rs2 + 1;
                if (f_rs2 !== d_rs2) begin
                    fails = fails + 1;
                    if (fails <= 20)
                        $display("FAIL(xchk): rs2 fetched=0x%08h decoded x%0d, rf_fields x%0d", fetched, d_rs2, f_rs2);
                end
            end
        end
    endtask

    initial begin
        $display("=== rf_fields Testbench ===");
        setnames;
        for (i = 0; i < NROW; i = i + 1) rcnt[i] = 0;
        for (i = 0; i < 65536; i = i + 1) begin
            if (i[1:0] != 2'b11) begin
                fetched = i;
                fetched[31:16] = $random;
                #1;
                model(fetched);
                if (m_legal) n_m_leg = n_m_leg + 1; else n_m_ill = n_m_ill + 1;
                if (m_legal == c_illegal) begin
                    n_note = n_note + 1;
                    if (n_note <= 5)
                        $display("NOTE(legal): fetched=0x%08h %0s: model %0s, compressed_decoder %0s", fetched,
                                 rname[m_row], m_legal ? "legal" : "illegal", c_illegal ? "illegal" : "legal");
                end
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
        $display("legal: model %0d legal + %0d illegal; compressed_decoder %0d legal + %0d illegal; %0d differ",
                 n_m_leg, n_m_ill, n_c, n_c_ill, n_note);
        if (n_m_leg != 49152 - n_m_ill) begin
            $display("FAIL(model): legal count %0d != 49152 - %0d illegal", n_m_leg, n_m_ill);
            fails = fails + 1;
        end
        $display("rows: checked non-x0 reads per instruction (model)");
        for (i = 0; i < 38; i = i + 1)
            if (i <= 20 || (i >= 26 && i <= 34)) begin   // rows that read a register
                $display("  rows %-10s %0d", rname[i], rcnt[i]);
                if (rcnt[i] == 0) begin
                    $display("FAIL(model): row %0s has no checked read", rname[i]);
                    fails = fails + 1;
                end
            end
        $display("\n=== rf_fields Results: %0d checks, %0d failed ===", checks, fails);
        if (fails == 0) $display("PASS tb_rf_fields (%0d checks)", checks);
        else            $display("FAIL tb_rf_fields: %0d failures, %0d checks", fails, checks);
        $finish;
    end
endmodule
