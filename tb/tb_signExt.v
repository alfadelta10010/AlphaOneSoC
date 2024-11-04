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
    #1 opcode_tb = 7'b0110011; //R-type
    instIn_tb = 32'h01190933; //XXXXXX
    #1 opcode_tb = 7'b0010011; //I-type
    instIn_tb = 32'hfffb8b93; // -1
    #1 opcode_tb = 7'b0100011; //S-type
    instIn_tb = 32'h0082a223; //4
    #1 opcode_tb = 7'b0000011; //Load-type
    instIn_tb = 32'h00C0A283; // 12
    #1 opcode_tb = 7'b0010011; //I-type - SRAI
    instIn_tb = 32'h40015093; // 0
    #1 opcode_tb = 7'b1100011; //B-type
    instIn_tb = 32'h014c6463; //0000002c
    #1 opcode_tb = 7'b1100111; //JALR
    instIn_tb = 32'h7ff080e7; // 0x7FF
    #1 opcode_tb = 7'b1101111; //JAL
    instIn_tb = 32'h0000006f; //0000007c
    #1 opcode_tb = 7'b0110111; //LUI
    instIn_tb = 32'h872370b7; //0x87237
    #1 opcode_tb = 7'b0010111; //AUIPC
    instIn_tb = 32'h10000917; //0x10000
    #1 $finish;
  end
endmodule