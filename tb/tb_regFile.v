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
  
  always begin
    clk_tb = 0;
    #5;
    clk_tb = 1;
    #5;
  end
  
  initial begin
    $dumpfile("regFile.vcd");
    $dumpvars(0, tb_regFile);
    wrEn_tb = 1'b0;
    for (int i = 0; i < 32; i = i + 1) 
      begin
        @(posedge clk_tb);
        wrEn_tb = 1'b1;
        rd_tb = i[4:0];
        dIn_tb = 32'hFFFFFF00 + i;
        @(posedge clk_tb);
        wrEn_tb = 1'b0;
      end
    
    #10;
    rs1_tb = 5'b00001;
    rs2_tb = 5'b00010;
    #10;
    rs1_tb = 5'b00011;
    rs2_tb = 5'b00100;
    #10;
    rs1_tb = 5'b00101;
    rs2_tb = 5'b00110;
    #10;
    rs1_tb = 5'b00111;
    rs2_tb = 5'b01000;
    #10;
    rs1_tb = 5'b01001;
    rs2_tb = 5'b01010;
    #10;
    rs1_tb = 5'b01011;
    rs2_tb = 5'b01100;
    #10;
    rs1_tb = 5'b01101;
    rs2_tb = 5'b01110;
    #10;
    rs1_tb = 5'b01111;
    rs2_tb = 5'b10000;
    #10;
    rs1_tb = 5'b10001;
    rs2_tb = 5'b10010;
    #10;
    rs1_tb = 5'b10011;
    rs2_tb = 5'b10100;
    #10;
    rs1_tb = 5'b10101;
    rs2_tb = 5'b10110;
    #10;
    rs1_tb = 5'b10111;
    rs2_tb = 5'b11000;
    #10;
    rs1_tb = 5'b11001;
    rs2_tb = 5'b11010;
    #10;
    rs1_tb = 5'b11011;
    rs2_tb = 5'b11100;
    #10;
    rs1_tb = 5'b11101;
    rs2_tb = 5'b11110;
    #10;
    rs1_tb = 5'b11111;
    rs2_tb = 5'b00000;
    #180;
    $finish;
  end
endmodule
