module tb_regFile();
  reg clk_tb, wrEn_tb;
  reg [4:0] rd_tb;
  reg [4:0] rs1_tb;
  reg [4:0] rs2_tb;
  reg [31:0] dIn_tb;
  wire [31:0] r1_tb;
  wire [31:0] r2_tb;
  
  regFile dut (.clk(clk_tb), 
               .wen(wrEn_tb), 
               .rd(rd_tb), 
               .rs1(rs1_tb), 
               .rs2(rs2_tb), 
               .r1(r1_tb),
               .r2(r2_tb),
               .dIn(dIn_tb)
              );
  
  always
    begin
      clk_tb = 0;
      #5;
      clk_tb = 1;
      #5;
    end
  
  initial begin
    $dumpfile("regFile.vcd");
    $dumpvars(0, tb_regFile);
    rd_tb = 5'b01010;
    din_tb = 32'hBABEFACE;
    #2 wrEn_tb = 1;
    #2 rs1_tb = 5'b00010;
    rs2_tb = 5'b01010;
    #5 rs2_tb = 5'bX;
    rd_tb = 5'b00010;
    #5 $finish;
  end
endmodule