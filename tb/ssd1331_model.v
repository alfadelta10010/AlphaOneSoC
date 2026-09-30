// Behavioural model of the PmodOLEDrgb's SSD1331 controller on the serial
// interface, wired as docs/pins-and-peripherals.md sets the OLED up: CS# on
// out[0], SDIN (MOSI) on out[1], D/C# on out[2], SCLK on out[3], and RES#
// joined with VCCEN on out[6].
//
// It captures every byte as the controller would -- SDIN shifted in on each
// rising SCLK edge while CS# is low, MSB first, D/C# sampled on the eighth
// -- into log[] as {D/C#, byte}: D/C# = 0 is a command (the SSD1331 takes
// command parameters as commands too), 1 is display data.
//
// Protocol checks: SCLK high when CS# falls and rises (SPI mode 3 idles
// high); CS# rising only on a byte boundary; D/C# not changing inside a
// byte; no clocks while RES# is low (the controller would ignore them);
// RES# low for at least 3 us (datasheet section 7.9, power ON sequence).
// The byte format is section 7.1.3.
//
// Timing (CHECK_TIMING = 1): Table 21, "Serial Interface Timing
// Characteristics" (SSD1331 rev 1.2), in ns:
//   tcycle 150   SCLK rising edge to rising edge
//   tCLKL   75   SCLK low       tCLKH  75   SCLK high (inside a transfer)
//   tDSW    40   SDIN setup before the rising edge
//   tDHW    40   SDIN hold after it
//   tCSS    75   CS# low before the first rising edge
//   tCSH    60   last rising edge before CS# rises
//   tAS     40   D/C# stable before the eighth rising edge
//   tAH     40   D/C# stable after it
// The testbench's clock period is what makes these meaningful; a model
// driven by a testbench without one should set CHECK_TIMING = 0.
//
// Not modelled: the 100 ms VCC settling time before Display On (AFh) --
// with VCCEN tied to RES# that is software's job, and far too long to
// simulate.
//
// `fitted` = 0 (another Pmod on the header) makes the model ignore the pins.
// A testbench that breaks a rule on purpose, to see the check fire, sets
// `expect_violations`: violations are then counted in n_expected instead of
// errors, and not printed.

`timescale 1ns / 1ps

module ssd1331_model #(
    parameter CHECK_TIMING = 1
)(
    input wire fitted,
    input wire cs_n,
    input wire sck,
    input wire mosi,
    input wire dc,
    input wire res_n
);
    localparam real TCYCLE = 150.0, TCLKL = 75.0, TCLKH = 75.0, TDSW = 40.0, TDHW = 40.0,
                    TCSS = 75.0, TCSH = 60.0, TAS = 40.0, TAH = 40.0, TRES = 3000.0;

    integer   errors = 0;
    reg [8:0] log [0:8191];
    integer   nlog = 0;
    integer   bits = 0;
    reg [7:0] sh;
    real      t_cs_fall = -1.0e9, t_rise = -1.0e9, t_fall = -1.0e9, t_mosi = -1.0e9,
              t_dc = -1.0e9, t_rise8 = -1.0e9, t_res_fall = 0.0;
    reg       rise_in_cs = 1'b0;          // a rising edge since CS# fell
    integer   n_res_pulses = 0;
    reg       expect_violations = 1'b0;
    integer   n_expected = 0;

    task automatic error(input string m);
        if (expect_violations) n_expected = n_expected + 1;
        else begin
            errors = errors + 1;
            if (errors <= 20) $display("ERROR SSD1331: %s (%0.1f ns)", m, $realtime);
        end
    endtask
    task automatic tmin(input string what, input real got, input real want);
        if (CHECK_TIMING && got < want)
            error($sformatf("%s %0.1f ns, minimum %0.1f ns (Table 21)", what, got, want));
    endtask

    always @(negedge cs_n)
        if (fitted) begin
            if (sck !== 1'b1) error("CS# fell with SCLK not high (mode 3 idles high)");
            t_cs_fall = $realtime;
            rise_in_cs = 1'b0;
            bits = 0;
        end
    always @(posedge cs_n)
        if (fitted) begin
            if (bits != 0) error($sformatf("CS# rose mid-byte, after %0d bits", bits));
            if (sck !== 1'b1) error("CS# rose with SCLK not high");
            if (rise_in_cs) tmin("tCSH (last SCLK rise to CS# high)", $realtime - t_rise, TCSH);
            bits = 0;
        end

    always @(posedge sck)
        if (fitted && cs_n === 1'b0) begin
            if (res_n !== 1'b1) error("SCLK rising while RES# is low");
            if (mosi !== 1'b0 && mosi !== 1'b1) error("SDIN is X at a rising SCLK edge");
            if (!rise_in_cs) tmin("tCSS (CS# low to first SCLK rise)", $realtime - t_cs_fall, TCSS);
            else             tmin("tcycle", $realtime - t_rise, TCYCLE);
            tmin("tCLKL", $realtime - t_fall, TCLKL);
            tmin("tDSW (SDIN setup)", $realtime - t_mosi, TDSW);
            sh = {sh[6:0], mosi};
            bits = bits + 1;
            if (bits == 8) begin
                tmin("tAS (D/C# setup to the 8th rise)", $realtime - t_dc, TAS);
                if (dc !== 1'b0 && dc !== 1'b1) error("D/C# is X at the 8th rising edge");
                log[nlog % 8192] = {dc, sh};
                nlog = nlog + 1;
                bits = 0;
                t_rise8 = $realtime;
            end
            t_rise = $realtime;
            rise_in_cs = 1'b1;
        end
    always @(negedge sck)
        if (fitted && cs_n === 1'b0) begin
            if (rise_in_cs) tmin("tCLKH", $realtime - t_rise, TCLKH);
            t_fall = $realtime;
        end
    always @(mosi)
        if (fitted) begin
            if (cs_n === 1'b0 && rise_in_cs) tmin("tDHW (SDIN hold)", $realtime - t_rise, TDHW);
            t_mosi = $realtime;
        end
    always @(dc)
        if (fitted) begin
            if (cs_n === 1'b0 && bits != 0) error($sformatf("D/C# changed inside a byte, after %0d bits", bits));
            if (cs_n === 1'b0) tmin("tAH (D/C# hold after the 8th rise)", $realtime - t_rise8, TAH);
            t_dc = $realtime;
        end
    always @(negedge res_n) t_res_fall = $realtime;
    always @(posedge res_n)
        if (fitted) begin
            n_res_pulses = n_res_pulses + 1;
            if ($realtime - t_res_fall < TRES)
                error($sformatf("RES# low for %0.1f ns, minimum %0.1f", $realtime - t_res_fall, TRES));
        end
endmodule
