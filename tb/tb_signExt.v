module tb_signExt();
  reg [6:0] opcode_tb;
  reg [31:0] instIn_tb;
  wire [31:0] immOut_tb;
  signExt dut (.opcode(opcode_tb), 
               .instIn(instIn_tb), 
               .immOut(immOut_tb)
              );
  initial begin
    $dumpfile("signExt.vcd");
    $dumpvars(0, tb_signExt);
    instIn_tb = 32'hX;
    #1 opcode_tb = 7'b0110011; // R-type
    instIn_tb = 32'h00208033;  // 0x00000000
    #1 opcode_tb = 7'b0010011; // I-type
    instIn_tb = 32'h00b40413;  // 0x0000000B
    #1 opcode_tb = 7'b0010011; // I-type
    instIn_tb = 32'hff638393;  // 0xFFFFFFF6
    #1 opcode_tb = 7'b0100011; // S-type
    instIn_tb = 32'h00818323;  // 0x00000006
    #1 opcode_tb = 7'b0000011; // Load-type
    instIn_tb = 32'h00c18083;  // 0x0000000C
    #1 opcode_tb = 7'b0010011; // I-type - SRAI
    instIn_tb = 32'h4070d093;  // 7 !
    #1 opcode_tb = 7'b1100011; // B-type
    instIn_tb = 32'hfe000ae3;  // 0xFFFFFFF4
    #1 opcode_tb = 7'b1100111; // JALR
    instIn_tb = 32'h010100e7;  // 0x00000010
    #1 opcode_tb = 7'b1101111; // JAL
    instIn_tb = 32'h004000ef;  // 0x00000010 !
    #1 opcode_tb = 7'b0110111; // LUI
    instIn_tb = 32'hfffff037;  // 0xFFFFF000
    #1 opcode_tb = 7'b0010111; // AUIPC
    instIn_tb = 32'hf0101017;  // 0xF0101000
    #1 $finish;
  end
endmodule