// Output pinmux, a feature overlay: every uo_out pin keeps its default function (dflt, assembled in
// alphaone_soc) until software selects the one alternate function the pin has; one flop per pin after the
// mux (F12). PINMUX word at 0x1002_0020 (carved out of the syscon window by soc_bus): pin i's code in bits
// [4i+2:4i], bit 4i+3 reads 0. Only three pins have an alternate function, so only three flops store a code:
//   pin 5: code 2 = RTS# (rts_n)      pin 6: code 4 = PWM0 (pwm[0])      pin 7: code 5 = PWM1 (pwm[1])
// Every pin's code 0 is DEFAULT dflt[i]. WARL: a write of any other code to any pin (including a code that is
// legal on another pin, and any code on pins 0-4) stores 0, the default function, and reads back 0.
// Lane be[i/2] writes pin i's nibble. Reset: alt* = 0 and uo = UO_RESET (0x39, the wrapper's in-reset value).
// Never stalls.
module pinmux #(parameter [7:0] UO_RESET = 8'h39) (
    input  wire        clk, rst,
    input  wire        sel, we,
    input  wire [3:0]  be,
    input  wire [31:0] wdata,
    output wire [31:0] rdata,
    input  wire [7:0]  dflt,
    input  wire        rts_n,
    input  wire [1:0]  pwm,
    output reg  [7:0]  uo
);
    reg alt5, alt6, alt7;                   // pin 5 = RTS#, pin 6 = PWM0, pin 7 = PWM1 selected

    assign rdata = {1'b0, alt7 ? 3'd5 : 3'd0, 1'b0, alt6 ? 3'd4 : 3'd0, 1'b0, alt5 ? 3'd2 : 3'd0, 20'd0};

    wire w = sel & we;
    always @(posedge clk) begin
        if (rst) begin
            alt5 <= 1'b0; alt6 <= 1'b0; alt7 <= 1'b0;
            uo   <= UO_RESET;
        end else begin
            if (w && be[2]) alt5 <= (wdata[22:20] == 3'd2);
            if (w && be[3]) begin
                alt6 <= (wdata[26:24] == 3'd4);
                alt7 <= (wdata[30:28] == 3'd5);
            end
            uo <= {alt7 ? pwm[1] : dflt[7], alt6 ? pwm[0] : dflt[6], alt5 ? rts_n : dflt[5], dflt[4:0]};
        end
    end
endmodule
