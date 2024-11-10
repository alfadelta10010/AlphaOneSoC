module tb_PWM();

    // Testbench signals
    reg clk;
    reg [3:0] frequency;
    reg [3:0] duty_cycle;
    wire pwm_out;

    // Instantiate the PWM module
    PWM uut (
        .clk(clk),
        .frequency(frequency),
        .duty_cycle(duty_cycle),
        .pwm_out(pwm_out)
    );

    // Clock generation
    initial begin
        clk = 0;
        forever #50 clk = ~clk;  // 10ns period (100 MHz clock)
    end
    initial begin
        $monitor("Time = %0t | Frequency = %b | Duty Cycle = %b | PWM Out = %b", 
                 $time, frequency, duty_cycle, pwm_out);
    end

    // Test sequence
    initial begin
        $dumpfile("PWM.vcd");
        $dumpvars(0, tb_PWM);
        // Initialize inputs
        frequency = 4'b1111;     // Set initial frequency
        duty_cycle = 4'b0010;    // Set initial duty cycle
        
        // Observe PWM output at different settings
        #1500;                    // Wait for some time
        
        // Test case 1: Increase duty cycle to 50%
        duty_cycle = 4'b1000;
        #1500;

        // Test case 2: Increase duty cycle to 75%
        duty_cycle = 4'b1100;
        #1500;

        // Test case 3: Increase frequency, 50% duty cycle
        frequency = 4'b0100;
        duty_cycle = 4'b0010;
        #1500;

        // Test case 4: Max frequency, max duty cycle (100%)
        frequency = 4'b1111;
        duty_cycle = 4'b1111;
        #1500;

        // End simulation
        $stop;
    end
endmodule

