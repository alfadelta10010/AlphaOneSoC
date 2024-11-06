module tb_decoder();
  reg [31:0] instIn_tb;
  wire [4:0] rd_tb;
  wire [4:0] rs1_tb;
  wire [4:0] rs2_tb;
  wire [31:0] instOut_tb;
  wire [6:0] opcode_tb;
  wire [2:0] fn3_tb;
  wire [6:0] fn7_tb;
  
  decoder dut(.instIn(instIn_tb), 
        .opcode(opcode_tb), 
        .rd(rd_tb), 
        .rs1(rs1_tb), 
        .rs2(rs2_tb), 
        .fn3(fn3_tb), 
        .fn7(fn7_tb));
  
  initial begin
    $dumpfile("decoder.vcd");
    $dumpvars(0, tb_decoder);
    #1 instIn_tb = 32'h00848933;
    #1 instIn_tb = 32'h10100493;
    #1 instIn_tb = 32'h0082a223;
    #1 instIn_tb = 32'h0002a303;
    #1 instIn_tb = 32'h014c6463;
    #1 instIn_tb = 32'h7ff080e7;
    #1 instIn_tb = 32'h0000006f;
    #1 instIn_tb = 32'h872370b7;
    #1 instIn_tb = 32'h10000917;
    #1 instIn_tb = 32'h41425313;
    #1 $finish;
  end
endmodule
