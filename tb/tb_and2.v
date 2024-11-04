module tb_and2(a_tb, b_tb, y_tb);
  input wire [31:0] a_tb;
  input wire [31:0] b_tb;
  output wire [31:0] y_tb;
  
  and2 dut (.a(a_tb), 
            .b(b_tb), 
            .y(y_tb), 
            );
  
  initial begin
    $dumpfile("and2.vcd");
    $dumpvars(0, tb_and2);
    a_tb = 32'h12345678;
    b_tb = 32'h12345678;
    #1 a_tb = 32'h00000000;
    #1 b_tb = 32'hFFFFFFFF;
endmodule
