`timescale 1ns / 1ps
// clint (src/clint.v) against a cycle model written from
// docs/FyraCore_CPU_Reference.md section 4 (CLINT register map) and the
// header of clint.v (REQ-CLINT-001, REQ-CLINT-002):
//
//   * msip bit 0 at 0x0000 (other bits read 0); mtimecmp low/high at
//     0x4000/0x4004, all ones after reset; mtime low/high at 0xBFF8/0xBFFC,
//     0 after reset, counting every clock with the 64-bit carry; every other
//     offset reads 0 and ignores writes; writes honour the byte lanes (wmask);
//     a write to mtime is done instead of that clock's increment;
//   * timer_irq = (mtime >= mtimecmp) one clock late (registered), 0 after
//     reset; sw_irq = msip; mtime_out = mtime.
// Checked on every clock: the read of a random offset, timer_irq, sw_irq and
// mtime_out. Stimulus is seeded (+SEED=, +NCYC=) and biased to the corners:
// mtimecmp at, just above and just below mtime, mtime about to carry into its
// upper half, single-lane writes, and resets. Prints PASS/FAIL with the
// number of checks and fails if a corner was never reached.
module tb_clint;
    reg         clk = 0, rst = 1, we = 0;
    reg  [15:0] addr = 0;
    reg  [31:0] wdata = 0;
    reg  [3:0]  wmask = 0;
    wire [31:0] rdata;
    wire        timer_irq, sw_irq;
    wire [63:0] mtime_out;
    clint uut(.clk(clk), .rst(rst), .addr(addr), .wdata(wdata), .wmask(wmask), .we(we),
              .rdata(rdata), .timer_irq(timer_irq), .sw_irq(sw_irq), .mtime_out(mtime_out));
    always #5 clk = ~clk;

    integer checks = 0, fails = 0, seed = 1, ncyc = 300000, cyc = 0;
    integer seed0 = 1;
    reg [63:0] m_time, m_cmp;
    reg        m_msip, m_tirq;
    integer cv_eq = 0, cv_rise = 0, cv_fall = 0, cv_carry = 0, cv_lane = 0, cv_twr = 0, cv_rst = 0;

    task automatic chk(input [8*16-1:0] what, input [63:0] got, input [63:0] want);
        begin
            checks = checks + 1;
            if (got !== want) begin
                fails = fails + 1;
                if (fails <= 30) $display("FAIL %0s: got %h want %h (cycle %0d addr %04h we %b mask %b)",
                                          what, got, want, cyc, addr, we, wmask);
            end
        end
    endtask

    function [63:0] lanes(input [63:0] old, input integer hi);   // apply a masked write to one half
        reg [31:0] h; integer k;
        begin
            h = hi ? old[63:32] : old[31:0];
            for (k = 0; k < 4; k = k + 1) if (wmask[k]) h[8*k +: 8] = wdata[8*k +: 8];
            lanes = hi ? {h, old[31:0]} : {old[63:32], h};
        end
    endfunction

    function [31:0] e_rdata(input [15:0] a);
        case (a)
            16'h0000: e_rdata = {31'b0, m_msip};
            16'h4000: e_rdata = m_cmp[31:0];
            16'h4004: e_rdata = m_cmp[63:32];
            16'hBFF8: e_rdata = m_time[31:0];
            16'hBFFC: e_rdata = m_time[63:32];
            default:  e_rdata = 32'h0;
        endcase
    endfunction

    task model_step;
        reg [63:0] t, c; reg tirq_next;
        begin
            if (rst) begin m_time = 0; m_cmp = 64'hFFFF_FFFF_FFFF_FFFF; m_msip = 0; m_tirq = 0; end
            else begin
                tirq_next = (m_time >= m_cmp);
                if (tirq_next && !m_tirq) cv_rise = cv_rise + 1;
                if (!tirq_next && m_tirq) cv_fall = cv_fall + 1;
                if (m_time == m_cmp) cv_eq = cv_eq + 1;
                t = m_time + 1;
                if (m_time[31:0] == 32'hFFFF_FFFF) cv_carry = cv_carry + 1;
                c = m_cmp;
                if (we) begin
                    if (wmask != 4'b1111 && wmask != 0) cv_lane = cv_lane + 1;
                    case (addr)
                        16'h0000: if (wmask[0]) m_msip = wdata[0];
                        16'h4000: c = lanes(m_cmp, 0);
                        16'h4004: c = lanes(m_cmp, 1);
                        16'hBFF8: begin t = lanes(m_time, 0); cv_twr = cv_twr + 1; end
                        16'hBFFC: begin t = lanes(m_time, 1); cv_twr = cv_twr + 1; end
                        default: ;
                    endcase
                end
                m_time = t; m_cmp = c; m_tirq = tirq_next;
            end
        end
    endtask

    function [15:0] pick_addr(input integer dummy);
        case ($unsigned($random(seed)) % 8)
            0: pick_addr = 16'h0000; 1: pick_addr = 16'h4000; 2: pick_addr = 16'h4004;
            3: pick_addr = 16'hBFF8; 4: pick_addr = 16'hBFFC;
            5: pick_addr = {$random(seed)} & 16'hFFFC;
            6: pick_addr = 16'h4000 + (($unsigned($random(seed)) % 4) << 2) - 4;
            default: pick_addr = 16'hBFF0 + (($unsigned($random(seed)) % 4) << 2);
        endcase
    endfunction

    integer gap;
    initial begin
        if ($value$plusargs("SEED=%d", seed)) ;
        seed0 = seed;   // $random(seed) moves seed on: report the one that reproduces the run
        if ($value$plusargs("NCYC=%d", ncyc)) ;
        $display("=== CLINT Testbench (model, seed %0d, %0d clocks) ===", seed, ncyc);
        m_time = 0; m_cmp = 0; m_msip = 0; m_tirq = 0;
        @(negedge clk);
        for (cyc = 0; cyc < ncyc; cyc = cyc + 1) begin
            // inputs for this clock
            if (cyc < 3 || $unsigned($random(seed)) % 20000 == 0) begin rst = 1; if (cyc >= 3) cv_rst = cv_rst + 1; end
            else rst = 0;
            we = ($unsigned($random(seed)) % 4 == 0);
            addr = pick_addr(0);
            wmask = ($unsigned($random(seed)) % 3 == 0) ? (4'b0001 << ($unsigned($random(seed)) % 4)) :
                    ($unsigned($random(seed)) % 2) ? 4'b1111 : $random(seed);
            wdata = $random(seed);
            // mtimecmp right around mtime, and mtime about to carry
            case ($unsigned($random(seed)) % 8)
                0: if (addr == 16'h4000) begin wdata = m_time[31:0] + ($unsigned($random(seed)) % 5) - 1; wmask = 4'hF; end
                1: if (addr == 16'h4004) begin wdata = m_time[63:32]; wmask = 4'hF; end
                2: if (addr == 16'hBFF8) begin wdata = 32'hFFFF_FFFF - ($unsigned($random(seed)) % 3); wmask = 4'hF; end
                3: if (addr == 16'hBFFC) begin wdata = m_cmp[63:32]; wmask = 4'hF; end
                default: ;
            endcase
            #1;
            if (!rst) begin
                chk("rdata", rdata, e_rdata(addr));
                chk("timer_irq", timer_irq, m_tirq);
                chk("sw_irq", sw_irq, m_msip);
                chk("mtime_out", mtime_out, m_time);
            end
            @(posedge clk);
            model_step;
            @(negedge clk);
        end
        $display("coverage: mtime == mtimecmp %0d, MTIP rises %0d falls %0d, low-half carries %0d, partial-lane writes %0d, mtime writes %0d, resets %0d",
                 cv_eq, cv_rise, cv_fall, cv_carry, cv_lane, cv_twr, cv_rst);
        if (cv_eq == 0 || cv_rise < 10 || cv_fall < 10 || cv_carry == 0 || cv_lane == 0 || cv_twr == 0 || cv_rst == 0) begin
            fails = fails + 1;
            $display("FAIL coverage: a CLINT corner was never reached");
        end
        if (fails == 0) $display("PASS tb_clint (%0d checks, seed %0d)", checks, seed0);
        else            $display("FAIL tb_clint: %0d failures, %0d checks, seed %0d", fails, checks, seed0);
        $finish;
    end
    initial begin #(64'd20_000_000_000); $display("TIMEOUT tb_clint"); $finish; end
endmodule
