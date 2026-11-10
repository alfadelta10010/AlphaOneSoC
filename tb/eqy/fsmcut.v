// FSM cut point (WO-24 closure experiment). Tables from the synthesis log
// (fin-3x4 yosys-synthesis.log 2167-2195, spi st at 2180-2184; the other three
// tables are unchanged from sc-3x4, log 2084-2105; gold code MSB first -> one-hot bit).
// gold: readers see clamp(q); gate: q = enc(oh), readers see onehot(clamp(q)).
// Invalid gold codes (L2 lemma: never reached) clamp to the reset code 0.
module fsmcut_gold_memsize(input [1:0] q, output [1:0] y);
  assign y = (q == 2'd3) ? 2'd0 : q;
endmodule
module fsmcut_gate_memsize(input [2:0] oh, output [1:0] q, output [2:0] dec);
  assign q = (oh[0] ? 2'b00 : 2'b00) | (oh[1] ? 2'b10 : 2'b00) | (oh[2] ? 2'b01 : 2'b00);
  wire [1:0] c = (q == 2'd3) ? 2'd0 : q;
  assign dec = {c == 2'b01, c == 2'b10, c == 2'b00};
endmodule
module fsmcut_gold_muldiv(input [2:0] q, output [2:0] y);
  assign y = (q == 3'd6 || q == 3'd7) ? 3'd0 : q;
endmodule
module fsmcut_gate_muldiv(input [5:0] oh, output [2:0] q, output [5:0] dec);
  assign q = (oh[1] ? 3'b100 : 3'b000) | (oh[2] ? 3'b010 : 3'b000) | (oh[3] ? 3'b001 : 3'b000)
           | (oh[4] ? 3'b101 : 3'b000) | (oh[5] ? 3'b011 : 3'b000);
  wire [2:0] c = (q == 3'd6 || q == 3'd7) ? 3'd0 : q;
  assign dec = {c == 3'b011, c == 3'b101, c == 3'b001, c == 3'b010, c == 3'b100, c == 3'b000};
endmodule
module fsmcut_gold_qspi(input [3:0] q, output [3:0] y);
  assign y = (q > 4'd9) ? 4'd0 : q;
endmodule
module fsmcut_gate_qspi(input [9:0] oh, output [3:0] q, output [9:0] dec);
  assign q = (oh[1] ? 4'b1000 : 4'b0000) | (oh[2] ? 4'b0100 : 4'b0000) | (oh[3] ? 4'b0010 : 4'b0000)
           | (oh[4] ? 4'b0110 : 4'b0000) | (oh[5] ? 4'b0001 : 4'b0000) | (oh[6] ? 4'b1001 : 4'b0000)
           | (oh[7] ? 4'b0101 : 4'b0000) | (oh[8] ? 4'b0011 : 4'b0000) | (oh[9] ? 4'b0111 : 4'b0000);
  wire [3:0] c = (q > 4'd9) ? 4'd0 : q;
  assign dec = {c == 4'b0111, c == 4'b0011, c == 4'b0101, c == 4'b1001, c == 4'b0001, c == 4'b0110, c == 4'b0010, c == 4'b0100, c == 4'b1000, c == 4'b0000};
endmodule
module fsmcut_gold_spi(input [1:0] q, output [1:0] y);
  assign y = (q == 2'd3) ? 2'd0 : q;
endmodule
module fsmcut_gate_spi(input [2:0] oh, output [1:0] q, output [2:0] dec);
  assign q = (oh[0] ? 2'b00 : 2'b00) | (oh[1] ? 2'b10 : 2'b00) | (oh[2] ? 2'b01 : 2'b00);
  wire [1:0] c = (q == 2'd3) ? 2'd0 : q;
  assign dec = {c == 2'b01, c == 2'b10, c == 2'b00};
endmodule
