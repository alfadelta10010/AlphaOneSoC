`timescale 1ns / 1ps
module tb_regFile;
    reg         clk, rst, wrEn;
    reg  [4:0]  rs1, rs2, rd;   // the two registers check2 reads
    reg  [4:0]  rs;             // the one read port
    reg  [31:0] dIn;
    wire [31:0] r;
    reg  [31:0] r1, r2;
    integer pass_count = 0, fail_count = 0, i;

    regFile #(32) uut(
        .clk(clk), .rst(rst), .wrEn(wrEn),
        .rs(rs), .rd(rd),
        .dIn(dIn), .r(r)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    task check1(input [4:0] reg_num, input [31:0] expected, input [159:0] name);
        begin
            rs1 = reg_num;
            rs = reg_num;
            #1;
            r1 = r;
            if (r1 === expected) begin
                pass_count = pass_count + 1;
            end else begin
                fail_count = fail_count + 1;
                $display("FAIL: %0s | reg x%0d | got=0x%08h exp=0x%08h",
                         name, reg_num, r1, expected);
            end
        end
    endtask

    // Reads rs1, then rs2, through the one port.
    task check2(input [31:0] exp_r1, input [31:0] exp_r2, input [159:0] name);
        begin
            rs = rs1;
            #1;
            r1 = r;
            rs = rs2;
            #1;
            r2 = r;
            if (r1 === exp_r1 && r2 === exp_r2) begin
                pass_count = pass_count + 1;
            end else begin
                fail_count = fail_count + 1;
                $display("FAIL: %0s | rs1=%0d rs2=%0d | r1=0x%08h(exp 0x%08h) r2=0x%08h(exp 0x%08h)",
                         name, rs1, rs2, r1, exp_r1, r2, exp_r2);
            end
        end
    endtask

    // Write a register: set up at negedge, captured at next posedge
    task write_reg(input [4:0] dest, input [31:0] data);
        begin
            @(negedge clk);
            wrEn = 1; rd = dest; dIn = data;
            @(posedge clk);  // write captured here
            #1;              // let non-blocking settle
            wrEn = 0;
        end
    endtask

    initial begin
        $dumpfile("tb_regFile.vcd");
        $dumpvars(0, tb_regFile);
        $display("=== Register File Testbench ===");

        // Reset
        rst = 1; wrEn = 0; rd = 0; dIn = 0; rs1 = 0; rs2 = 0; rs = 0;
        @(posedge clk); @(posedge clk);
        #1;
        rst = 0;

        // x0 should always read 0
        @(negedge clk);
        rs1 = 5'd0; rs2 = 5'd0;
        check2(32'h0, 32'h0, "x0 reads zero after reset");

        // Write to all registers x0..x31 using negedge setup
        for (i = 0; i < 32; i = i + 1) begin
            @(negedge clk);
            wrEn = 1; rd = i[4:0]; dIn = 32'hA000_0000 + i;
            @(posedge clk); // captured here
            #1;
        end
        wrEn = 0;

        // x0 must still be 0 (hardwired)
        @(negedge clk);
        rs1 = 5'd0; rs2 = 5'd1;
        check2(32'h0, 32'hA0000001, "x0 hardwired, x1 written");

        // Read all registers x1..x31 individually
        for (i = 1; i < 32; i = i + 1) begin
            check1(i[4:0], 32'hA0000000 + i, "Read all regs");
        end

        // Write then read
        write_reg(5'd10, 32'hBEEF_CAFE);
        @(negedge clk);
        rs1 = 5'd10; rs2 = 5'd10;
        check2(32'hBEEF_CAFE, 32'hBEEF_CAFE, "Read after write x10");

        // Overwrite x10
        write_reg(5'd10, 32'h1234_5678);
        @(negedge clk);
        rs1 = 5'd10; rs2 = 5'd10;
        check2(32'h12345678, 32'h12345678, "Overwrite x10");

        // Write to x0 should be ignored
        write_reg(5'd0, 32'hDEAD_BEEF);
        @(negedge clk);
        rs1 = 5'd0; rs2 = 5'd0;
        check2(32'h0, 32'h0, "x0 write ignored");

        // Write disabled — x15 should retain its value from bulk write
        @(negedge clk);
        wrEn = 0; rd = 5'd15; dIn = 32'hFFFF_0000;
        @(posedge clk); #1;
        @(negedge clk);
        check1(5'd15, 32'hA000000F, "Write disabled");

        // Reset leaves the registers alone: they have no reset (boot code
        // clears them), so their values survive it
        @(negedge clk);
        rst = 1;
        @(posedge clk); @(posedge clk);
        #1;
        rst = 0;
        @(negedge clk);
        rs1 = 5'd10; rs2 = 5'd15;
        check2(32'h12345678, 32'hA000000F, "Reset leaves regs");

        // Simultaneous read of two different registers
        write_reg(5'd5, 32'h5555_5555);
        write_reg(5'd6, 32'h6666_6666);
        @(negedge clk);
        rs1 = 5'd5; rs2 = 5'd6;
        check2(32'h55555555, 32'h66666666, "Two reads, diff regs");

        // Edge: max register x31
        write_reg(5'd31, 32'h7FFF_FFFF);
        @(negedge clk);
        rs1 = 5'd31; rs2 = 5'd31;
        check2(32'h7FFFFFFF, 32'h7FFFFFFF, "x31 read/write");

        // Rapid successive writes to same register — last write wins
        write_reg(5'd20, 32'h1111_1111);
        write_reg(5'd20, 32'h2222_2222);
        write_reg(5'd20, 32'h3333_3333);
        @(negedge clk);
        check1(5'd20, 32'h33333333, "Last write wins");

        // Read two different registers one after the other
        write_reg(5'd1, 32'hAAAA_BBBB);
        write_reg(5'd2, 32'hCCCC_DDDD);
        @(negedge clk);
        rs1 = 5'd1; rs2 = 5'd2;
        check2(32'hAAAABBBB, 32'hCCCCDDDD, "Two reads");

        $display("\n=== RegFile Results: %0d passed, %0d failed ===", pass_count, fail_count);
        if (fail_count == 0) $display("ALL REGFILE TESTS PASSED");
        $finish;
    end
endmodule
