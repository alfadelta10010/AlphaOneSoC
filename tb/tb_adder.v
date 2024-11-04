module tb_adder(a_tb, b_tb, s_tb);
  output reg [31:0] a_tb;
  output reg [31:0] b_tb;
  input wire [31:0] s_tb;
  
  adder dut (.a(a_tb), 
             .b(b_tb), 
             .s(s_tb), 
            );
  
  initial begin
    $dumpfile("adder.vcd");
    $dumpvars(0, tb_adder);
    a_tb = 32'h00000000;
    b_tb = 32'h00000004;
    #1 a_tb = 32'hFA000004;
    #1 b_tb = 32'hFF000008;
  end
endmodule
