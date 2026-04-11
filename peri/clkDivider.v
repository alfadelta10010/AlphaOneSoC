module clkDivider(clk, rst, n, out);
input wire clk, rst;
input wire [2:0]n;
output reg out;
reg [2:0] val = 0;

always@ (posedge clk)
begin
    if(rst) begin
    val <= 0;
    out <= 1'b0;
    end
    else if (val == n) begin
        val <= 0;;
        out <= ~out;
    end
    else begin
        out <= out;
        val <= val + 1'b1;
    end
    
end
endmodule

