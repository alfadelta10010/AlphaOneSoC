`timescale 1ns / 1ps
module tb_csr;
    reg         clk, rst;
    reg  [11:0] addr;   // Used as both raddr and waddr in unit tests
    reg  [31:0] wdata;
    reg  [1:0]  op;
    reg         we;
    wire [31:0] rdata;
    reg         trap, mret_sig;
    reg  [31:0] trap_pc, trap_cause, trap_val;
    wire [31:0] mtvec_out, mepc_out;
    reg         instret_inc;
    wire        mstatus_mie;
    wire        csr_addr_valid;
    integer pass_count = 0, fail_count = 0;

    csr uut(
        .clk(clk), .rst(rst), .raddr(addr), .waddr(addr), .wdata(wdata),
        .op(op), .we(we), .rdata(rdata),
        .trap(trap), .mret(mret_sig), .trap_pc(trap_pc),
        .trap_cause(trap_cause), .trap_val(trap_val),
        .mtvec_out(mtvec_out), .mepc_out(mepc_out),
        .instret_inc(instret_inc), .mstatus_mie(mstatus_mie),
        .csr_addr_valid(csr_addr_valid)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    task check_read(input [31:0] expected, input [159:0] name);
        begin
            #1;
            if (rdata === expected)
                pass_count = pass_count + 1;
            else begin
                fail_count = fail_count + 1;
                $display("FAIL: %0s | addr=0x%03h | got=0x%08h exp=0x%08h", name, addr, rdata, expected);
            end
        end
    endtask

    initial begin
        $dumpfile("tb_csr.vcd");
        $dumpvars(0, tb_csr);
        $display("=== CSR Testbench ===");

        // Init
        rst = 1; we = 0; op = 0; addr = 0; wdata = 0;
        trap = 0; mret_sig = 0; trap_pc = 0; trap_cause = 0; trap_val = 0;
        instret_inc = 0;
        @(posedge clk); @(posedge clk);
        rst = 0;
        @(negedge clk);

        // Read-only CSRs
        addr = 12'hF11; check_read(32'h0, "mvendorid=0");
        addr = 12'hF12; check_read(32'h0, "marchid=0");
        addr = 12'hF13; check_read(32'h1, "mimpid=1");
        addr = 12'hF14; check_read(32'h0, "mhartid=0");
        // misa: RV32IMAC = 01_0000000000_01000100000101
        addr = 12'h301; check_read({2'b01, 4'b0, 26'b00000000000001000100000101}, "misa");

        // mstatus after reset: MPP=11 (bits 12:11)
        addr = 12'h300; check_read(32'h0000_1800, "mstatus after reset");

        // CSRRW: write mtvec
        @(posedge clk);
        addr = 12'h305; wdata = 32'h0000_0100; op = 2'b01; we = 1;
        @(posedge clk); we = 0; op = 0;
        @(negedge clk);
        addr = 12'h305; check_read(32'h0000_0100, "mtvec after CSRRW");
        #1; if (mtvec_out !== 32'h0000_0100) begin fail_count=fail_count+1; $display("FAIL: mtvec_out"); end
        else pass_count=pass_count+1;

        // CSRRS: set bits in mscratch
        @(posedge clk);
        addr = 12'h340; wdata = 32'hAAAA_AAAA; op = 2'b01; we = 1; // First write
        @(posedge clk); we = 0; op = 0;
        @(negedge clk);
        addr = 12'h340; check_read(32'hAAAAAAAA, "mscratch write");

        @(posedge clk);
        addr = 12'h340; wdata = 32'h5555_5555; op = 2'b10; we = 1; // Set bits
        @(posedge clk); we = 0; op = 0;
        @(negedge clk);
        addr = 12'h340; check_read(32'hFFFFFFFF, "mscratch after CSRRS");

        // CSRRC: clear bits in mscratch
        @(posedge clk);
        addr = 12'h340; wdata = 32'h0F0F0F0F; op = 2'b11; we = 1;
        @(posedge clk); we = 0; op = 0;
        @(negedge clk);
        addr = 12'h340; check_read(32'hF0F0F0F0, "mscratch after CSRRC");

        // mepc: write and check bit 0 cleared
        @(posedge clk);
        addr = 12'h341; wdata = 32'h0000_0103; op = 2'b01; we = 1;
        @(posedge clk); we = 0; op = 0;
        @(negedge clk);
        addr = 12'h341; check_read(32'h0000_0102, "mepc bit0 cleared");

        // Cycle counter: run a few cycles and check
        addr = 12'hB00;
        @(negedge clk);
        begin : cycle_check
            reg [31:0] cyc1, cyc2;
            cyc1 = rdata;
            @(posedge clk); @(posedge clk); @(posedge clk);
            @(negedge clk);
            cyc2 = rdata;
            if (cyc2 > cyc1) pass_count = pass_count + 1;
            else begin fail_count = fail_count+1; $display("FAIL: mcycle not incrementing"); end
        end

        // Instret counter
        @(posedge clk);
        instret_inc = 1;
        @(posedge clk); @(posedge clk); @(posedge clk);
        instret_inc = 0;
        @(posedge clk);
        @(negedge clk);
        addr = 12'hB02;
        #1; if (rdata >= 32'd3) pass_count = pass_count + 1;
        else begin fail_count = fail_count+1; $display("FAIL: minstret=%0d", rdata); end

        // Trap handling
        @(posedge clk);
        // First enable MIE
        addr = 12'h300; wdata = 32'h0000_1808; op = 2'b01; we = 1; // MIE=1, MPP=11
        @(posedge clk); we = 0; op = 0;
        @(negedge clk);
        addr = 12'h300;
        #1; if (mstatus_mie !== 1'b1) begin fail_count=fail_count+1; $display("FAIL: MIE not set"); end
        else pass_count=pass_count+1;

        // Trigger trap (set up at negedge, captured at posedge)
        @(negedge clk);
        trap = 1; trap_pc = 32'h0000_0200; trap_cause = 32'd11; trap_val = 32'h0;
        @(posedge clk); #1;
        trap = 0;
        @(negedge clk);
        addr = 12'h341; check_read(32'h0000_0200, "mepc after trap");
        addr = 12'h342; check_read(32'd11, "mcause after trap");
        // MIE should be cleared, MPIE should have old MIE
        addr = 12'h300;
        #1;
        if (rdata[3] !== 1'b0) begin fail_count=fail_count+1; $display("FAIL: MIE not cleared on trap"); end
        else pass_count=pass_count+1;
        if (rdata[7] !== 1'b1) begin fail_count=fail_count+1; $display("FAIL: MPIE not set on trap"); end
        else pass_count=pass_count+1;

        // MRET (set up at negedge, captured at posedge)
        @(negedge clk);
        mret_sig = 1;
        @(posedge clk); #1;
        mret_sig = 0;
        @(negedge clk);
        addr = 12'h300;
        #1;
        if (rdata[3] !== 1'b1) begin fail_count=fail_count+1; $display("FAIL: MIE not restored on MRET"); end
        else pass_count=pass_count+1;

        // Write to read-only CSR should be ignored
        @(posedge clk);
        addr = 12'hF14; wdata = 32'hFF; op = 2'b01; we = 1;
        @(posedge clk); we = 0; op = 0;
        @(negedge clk);
        addr = 12'hF14; check_read(32'h0, "mhartid unchanged after write");

        // Unknown CSR reads 0
        addr = 12'hFFF; check_read(32'h0, "Unknown CSR reads 0");

        // CSR address validity checks
        addr = 12'h300; #1;
        if (csr_addr_valid !== 1'b1) begin fail_count=fail_count+1; $display("FAIL: mstatus should be valid"); end
        else pass_count=pass_count+1;

        addr = 12'hF14; #1;
        if (csr_addr_valid !== 1'b1) begin fail_count=fail_count+1; $display("FAIL: mhartid should be valid"); end
        else pass_count=pass_count+1;

        addr = 12'hFFF; #1;
        if (csr_addr_valid !== 1'b0) begin fail_count=fail_count+1; $display("FAIL: 0xFFF should be invalid"); end
        else pass_count=pass_count+1;

        addr = 12'h123; #1;
        if (csr_addr_valid !== 1'b0) begin fail_count=fail_count+1; $display("FAIL: 0x123 should be invalid"); end
        else pass_count=pass_count+1;

        $display("\n=== CSR Results: %0d passed, %0d failed ===", pass_count, fail_count);
        if (fail_count == 0) $display("ALL CSR TESTS PASSED");
        $finish;
    end
endmodule
