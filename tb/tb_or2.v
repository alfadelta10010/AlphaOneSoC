module tb_or2();
  reg [31:0] a_tb;
  reg [31:0] b_tb;
  wire [31:0] y_tb;
  
  or2 dut (.a(a_tb),
           .b(b_tb), 
           .y(y_tb)
          );
  
  initial begin
    $dumpfile("or2.vcd");
    $dumpvars(0, tb_or2);
    a_tb = 32'h12345678;
    b_tb = 32'h12345678;
    #1 a_tb = 32'h00000000;
    b_tb = 32'hFFFFFFFF;
    #1 $finish;
  end
endmodule