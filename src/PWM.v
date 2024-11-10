module PWM(
    input clk,                 // System clock
    input [3:0] frequency,     // 4-bit frequency control
    input [3:0] duty_cycle,    // 4-bit duty cycle control
    output reg pwm_out         // PWM output
);

    reg [7:0] counter = 0;         // 8-bit counter for controlling PWM

    always @(posedge clk) begin
        if(counter < frequency - 1)
        counter <= counter + 1;  // Increment counter at each clock cycle
        else
        counter <= 0;

        // Set the PWM output based on duty cycle comparison
        if (counter < duty_cycle)
            pwm_out <= 1;
        else
            pwm_out <= 0;
    end
endmodule

