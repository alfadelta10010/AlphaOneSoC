// The core's one comparator: r1 - r2 decides a branch, and the same
// subtractor gives the ALU its SUB, SLT(I) and SLTU(I) results (fyracore
// feeds r2 = rs2 for a branch, the ALU's second operand otherwise). A branch
// never needs the ALU's SUB/SLT in the same cycle -- the ALU computes the
// branch target then -- so one subtractor serves both.
//
// Structure (pure restructure, same function as the plain r1 - r2 compare):
// the branch decision does NOT wait for the subtractor's ripple carry. LibreLane's
// area synthesis (SYNTH_STRATEGY "AREA 2") maps a plain "r1 < r2" or
// "(r1 - r2) == 0" as a ripple of wide AND/OR gates (~10 ns through the
// register-file macro into br_r). So the compare is spelled out as a log-depth
// tree: per bit a (less, equal) pair, then five levels of the MSB-priority
// combine (L, E) = (Lh | Eh & Ll, Eh & El). The (* keep *) on every level's
// wires is deliberate: it stops ABC from collapsing the tree back into a ripple.
// eq is the tree's root E (XNOR + balanced AND), lt_unsigned its root L; the
// subtractor now only produces diff for the ALU's SUB.
module branchCtrl(
    input  wire [2:0]  funct3,
    input  wire [31:0] r1,
    input  wire [31:0] r2,
    output reg         branchValid,
    // For the ALU
    output wire [31:0] diff,         // r1 - r2
    output wire        lt_signed,
    output wire        lt_unsigned
);
    assign diff = r1 - r2;

    // Level 0: per bit, less (r1 bit 0, r2 bit 1) and equal
    (* keep *) wire [31:0] l0 = ~r1 & r2;
    (* keep *) wire [31:0] e0 = ~(r1 ^ r2);
    // Levels 1..5: pairwise MSB-priority combine, high half wins
    (* keep *) wire [15:0] l1, e1;
    (* keep *) wire [7:0]  l2, e2;
    (* keep *) wire [3:0]  l3, e3;
    (* keep *) wire [1:0]  l4, e4;
    (* keep *) wire        l5, e5;

    genvar i;
    generate
        for (i = 0; i < 16; i = i + 1) begin : g1
            assign l1[i] = l0[2*i+1] | (e0[2*i+1] & l0[2*i]);
            assign e1[i] = e0[2*i+1] & e0[2*i];
        end
        for (i = 0; i < 8; i = i + 1) begin : g2
            assign l2[i] = l1[2*i+1] | (e1[2*i+1] & l1[2*i]);
            assign e2[i] = e1[2*i+1] & e1[2*i];
        end
        for (i = 0; i < 4; i = i + 1) begin : g3
            assign l3[i] = l2[2*i+1] | (e2[2*i+1] & l2[2*i]);
            assign e3[i] = e2[2*i+1] & e2[2*i];
        end
        for (i = 0; i < 2; i = i + 1) begin : g4
            assign l4[i] = l3[2*i+1] | (e3[2*i+1] & l3[2*i]);
            assign e4[i] = e3[2*i+1] & e3[2*i];
        end
    endgenerate
    assign l5 = l4[1] | (e4[1] & l4[0]);
    assign e5 = e4[1] & e4[0];

    wire eq            = e5;
    assign lt_unsigned = l5;
    assign lt_signed   = (r1[31] != r2[31]) ? r1[31] : l5;

    // funct3 encoding matches RISC-V spec
    always @(*) begin
        case (funct3)
            3'b000:  branchValid =  eq;           // BEQ
            3'b001:  branchValid = !eq;            // BNE
            3'b100:  branchValid =  lt_signed;     // BLT
            3'b101:  branchValid = !lt_signed;     // BGE
            3'b110:  branchValid =  lt_unsigned;   // BLTU
            3'b111:  branchValid = !lt_unsigned;   // BGEU
            default: branchValid = 1'b0;
        endcase
    end
endmodule
