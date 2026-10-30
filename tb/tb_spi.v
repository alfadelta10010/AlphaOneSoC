// Unit bench for the SPI controller inside gpio (src/gpio.v + src/spi.v):
// WO-29 section 5. The expected value of every check comes from a timing
// model written from WO-29 5.2 and WO-28 sections 1-2 (tb/spi_spec.vh), not
// from the RTL. The model takes its edges from its own write and load times,
// never from the DUT's pins: a mutant that moves both a pin and its own
// timing is therefore seen.
//
// Every clock: out[7:0], ready, and every read's rdata against the model (and
// no X on out, ready or rdata). The bus is driven as soc_bus does: one access
// per cycle, held while ready is low, changed on the negative edge, checked
// on the positive edge.
//
// Timing equations (T = 16 ns, B = BAUD frozen at the load, P = B + 1):
//   a LOAD is at w + 1 for an idle engine (w = the accepted TXDATA write), or
//   at the end of the byte that is shifting; with L the load edge, bit k
//   launches at L + 2kP, its A->B edge is at L + 2kP + P, its sample edge is
//   L + 2kP + 2P - 1 (the in[1] value presented at that edge), the byte ends
//   at L + 16P. SCK is A = CPOL ^ CPHA from a launch to its A->B edge, ~A
//   until the next launch, CPOL when idle; MOSI is TX bit k from launch k.
//
// Sections T01-T13 are directed, then a random phase with coverage floors.
// T04 (the MISO probe) and T14 (the round-trip sweep) are in the same bench.
//
// Plusargs: +SEED=<n> (default 1), +CYCLES=<n> (random phase, default 300000).
`timescale 1ns/1ps
`include "spi_spec.vh"

module tb_spi;
    localparam real T = `SPI_T_NS;

    reg         clk = 1'b0, rst = 1'b1;
    reg         sel = 1'b0, we = 1'b0;
    reg  [3:0]  be = 4'hF;
    reg  [5:2]  addr = 4'd0;
    reg  [31:0] wdata = 32'h0;
    reg  [7:0]  in_hi = 8'h00;           // in[7:2] and in[0]: random
    wire        in1;                     // MISO: the probe or the analog slave
    wire [31:0] rdata;
    wire        ready;
    wire [7:0]  out;
    wire [7:0]  in = {in_hi[7:2], in1, in_hi[0]};

    always #(T / 2.0) clk = ~clk;

    gpio dut (.clk(clk), .rst(rst), .sel(sel), .we(we), .be(be), .addr(addr), .wdata(wdata),
              .rdata(rdata), .ready(ready), .in(in), .out(out));

    // ── Random numbers (xorshift, seeded by +SEED) ──────────────────────────
    reg [31:0] rs = 32'h1;
    function [31:0] rnd(input integer dummy);
        begin
            rs = rs ^ (rs << 13); rs = rs ^ (rs >> 17); rs = rs ^ (rs << 5);
            rnd = rs;
        end
    endfunction
    function integer rn(input integer n);
        reg [31:0] v;
        begin v = rnd(0); rn = v % n; end
    endfunction

    // ── Reporting ───────────────────────────────────────────────────────────
    integer errors = 0, checks = 0, sec_err = 0, ecnt = 0;
    string  section = "start";
    task automatic fail(input string what, input [31:0] got, input [31:0] exp);
        begin
            errors = errors + 1; sec_err = sec_err + 1;
            if (errors <= 40)
                $display("FAIL cycle %0d [%0s] %0s: got %h, want %h", ecnt, section, what, got, exp);
        end
    endtask
    task automatic ckv(input string what, input [31:0] got, input [31:0] exp);
        begin checks = checks + 1; if (got !== exp) fail(what, got, exp); end
    endtask
    task automatic sect(input string name);
        begin
            if (section != "start") $display("%0s: %0d errors", section, sec_err);
            sec_err = 0; section = name;
        end
    endtask

    // ── The model ───────────────────────────────────────────────────────────
    reg        armed = 1'b0;
    reg        x_ok = 1'b0;              // rdata may legitimately be X (RT sweep, failing region)
    reg [7:0]  m_o = 8'h81;              // OUT bits 7, 6, 2, 0
    reg        m_p1 = 1'b0, m_p3 = 1'b1; // MOSI and SCK pin flops
    reg        m_en = 1'b0, m_cpol = 1'b1, m_cpha = 1'b1;
    reg [7:0]  m_baud = 8'hFF, m_bb = 8'h00, m_sr = 8'h00, m_tx = 8'h00, m_rx = 8'h00;
    reg        m_bba = 1'b0, m_active = 1'b0;
    integer    m_L = 0, m_P = 1;
    reg [7:0]  m_inm = 8'hxx, m_ins = 8'hxx;     // in_m, in_s: the IN synchroniser
    integer    last_acc_edge = 0;

    function [7:0] m_pins(input dummy);
        m_pins = {m_o[7:6], 2'b00, m_p3, m_o[2], m_p1, m_o[0]};
    endfunction

    // Coverage (5.4)
    integer cov_mode [0:3];
    integer cov_bin [0:7];
    integer cov_rx0 [0:7];
    integer cov_rx1 [0:7];
    integer n_bytes = 0, n_b2b = 0, n_txd_stall = 0, n_nobe0_busy = 0, n_en01 = 0, n_en10 = 0;
    integer n_rst_a = 0, n_rst_b = 0, n_rst_bba = 0, n_rdmid = 0, n_probe = 0;
    integer n_stall [0:4];               // OUT, SPICTL, CONTROL, BAUD, STATUS/reserved
    reg     cur_stalled = 1'b0;
    // Snapshot of every counter at the start of the random phase: the floors of the random
    // phase apply to the difference, so the directed tests cannot meet them alone.
    integer s_mode [0:3];
    integer s_bin [0:7];
    integer s_rx0 [0:7];
    integer s_rx1 [0:7];
    integer s_stall [0:4];
    integer s_b2b, s_txd_stall, s_nobe0, s_en01, s_en10, s_rst_a, s_rst_b, s_rst_bba, s_rdmid;
    integer n_idld_rd = 0;               // TXDATA reads after an IDLE load, before the next TXDATA write
    reg     last_ld_idle = 1'b0;
    integer ii;
    task snap;
        integer q;
        begin
            for (q = 0; q < 4; q = q + 1) s_mode[q] = cov_mode[q];
            for (q = 0; q < 8; q = q + 1) begin s_bin[q] = cov_bin[q]; s_rx0[q] = cov_rx0[q]; s_rx1[q] = cov_rx1[q]; end
            for (q = 0; q < 5; q = q + 1) s_stall[q] = n_stall[q];
            s_b2b = n_b2b; s_txd_stall = n_txd_stall; s_nobe0 = n_nobe0_busy; s_en01 = n_en01; s_en10 = n_en10;
            s_rst_a = n_rst_a; s_rst_b = n_rst_b; s_rst_bba = n_rst_bba; s_rdmid = n_rdmid;
        end
    endtask
    initial begin
        for (ii = 0; ii < 4; ii = ii + 1) cov_mode[ii] = 0;
        for (ii = 0; ii < 8; ii = ii + 1) begin cov_bin[ii] = 0; cov_rx0[ii] = 0; cov_rx1[ii] = 0; end
        for (ii = 0; ii < 5; ii = ii + 1) n_stall[ii] = 0;
    end

    reg        probe_active = 1'b0;      // this byte's MISO is the probe
    reg        probe_drive = 1'b0, in1_probe = 1'b0;
    integer    probe_force = 0;          // 0 random per byte, 1 always the probe, 2 never
    reg [7:0]  plan = 8'h00, plan_prev = 8'h00;   // the RX byte the probe plays for this byte

    always @(posedge clk) begin : model
        reg        txe, exp_stall, acc, do_ld, skip;
        reg [7:0]  txn, bbn;
        reg [31:0] exp_rd;
        integer    t, k, r, bin, cls;
        ecnt = ecnt + 1;
        txe = !m_active && !m_bba;
        exp_stall = sel && we && be[0] && ((addr == `SL_TXDATA) ? m_bba : !txe);
        acc = sel && we && be[0] && !exp_stall;
        if (armed) begin
            checks = checks + 3;
            if (ready !== !exp_stall) fail("ready", ready, !exp_stall);
            if (out !== m_pins(0)) fail("out", out, m_pins(0));
            if (^out === 1'bx) fail("X on out", out, 0);
            if (sel && !we) begin
                skip = 1'b0;
                case (addr)
                    `SL_OUT:     exp_rd = {24'b0, m_pins(0)};
                    `SL_IN:      begin exp_rd = {24'b0, m_ins}; skip = (^m_ins === 1'bx); end
                    4'd3:        exp_rd = {23'b0, !txe, 7'b0, m_en};
                    `SL_RXDATA:  begin exp_rd = {24'b0, m_sr}; skip = m_active; if (m_active) n_rdmid = n_rdmid + 1; end
                    `SL_TXDATA:  begin exp_rd = {24'b0, m_bb}; if (last_ld_idle) n_idld_rd = n_idld_rd + 1; end
                    `SL_STATUS:  exp_rd = {30'b0, !m_bba, txe};
                    `SL_CONTROL: exp_rd = {30'b0, m_cpol, m_cpha};
                    `SL_BAUD:    exp_rd = {24'b0, m_baud};
                    default:     exp_rd = 32'h0;
                endcase
                checks = checks + 1;
                if (!x_ok && ^rdata === 1'bx) fail("X on rdata", rdata, exp_rd);
                else if (!skip && rdata !== exp_rd) fail("rdata", rdata, exp_rd);
            end
        end
        if (sel && we && be[0] && exp_stall) cur_stalled = 1'b1;
        if (sel && we && !be[0] && m_active) n_nobe0_busy = n_nobe0_busy + 1;

        if (rst) begin
            if (m_active) begin
                t = ecnt - m_L;
                if ((t % (2 * m_P)) < m_P) n_rst_a = n_rst_a + 1; else n_rst_b = n_rst_b + 1;
            end
            if (m_bba) n_rst_bba = n_rst_bba + 1;
            m_o = 8'h81; m_p1 = 1'b0; m_p3 = 1'b1; m_en = 1'b0; m_cpol = 1'b1; m_cpha = 1'b1;
            m_baud = 8'hFF; m_bb = 8'h00; m_sr = 8'h00; m_bba = 1'b0; m_active = 1'b0;
            armed = 1'b1; cur_stalled = 1'b0; last_ld_idle = 1'b0;
        end else begin
            // ---- the engine, from the load time
            do_ld = 1'b0;
            if (m_active) begin
                t = ecnt - m_L;
                if (t < 16 * m_P && (t % (2 * m_P)) == 2 * m_P - 1) begin
                    k = t / (2 * m_P);
                    m_rx[7 - k] = in[1];
                    if (in[1] === 1'b0) cov_rx0[7 - k] = cov_rx0[7 - k] + 1;
                    if (in[1] === 1'b1) cov_rx1[7 - k] = cov_rx1[7 - k] + 1;
                    if (probe_active) n_probe = n_probe + 1;
                end
                if (t == 16 * m_P) begin
                    if (probe_active) begin checks = checks + 1; if (m_rx !== plan) fail("probe: byte sampled by the model is not the planned one", m_rx, plan); end
                    if (m_bba) begin bbn = m_rx; txn = m_bb; do_ld = 1'b1; n_b2b = n_b2b + 1; last_ld_idle = 1'b0; end
                    else begin m_sr = m_rx; m_active = 1'b0; if (m_en) m_p3 = m_cpol; end
                end
            end else if (m_bba) begin
                bbn = m_sr; txn = m_bb; do_ld = 1'b1; last_ld_idle = 1'b1;
            end
            if (do_ld) begin
                m_bb = bbn; m_tx = txn; m_bba = 1'b0; m_active = 1'b1; m_L = ecnt;
                m_P = m_baud + 1; m_rx = 8'hxx;
                n_bytes = n_bytes + 1;
                cov_mode[{m_cpol, m_cpha}] = cov_mode[{m_cpol, m_cpha}] + 1;
                bin = (m_baud <= 3) ? m_baud : (m_baud <= 77) ? 4 : (m_baud == 78) ? 5 : (m_baud <= 253) ? 6 : 7;
                cov_bin[bin] = cov_bin[bin] + 1;
                new_byte_hook;
            end
            if (m_active && m_en) begin
                t = ecnt - m_L; k = t / (2 * m_P); r = t % (2 * m_P);
                m_p1 = m_tx[7 - k];
                m_p3 = (r < m_P) ? (m_cpol ^ m_cpha) : ~(m_cpol ^ m_cpha);
            end
            // ---- the bus write
            if (acc) begin
                last_acc_edge = ecnt;
                cls = (addr == 4'd0) ? 0 : (addr == 4'd3) ? 1 : (addr == `SL_CONTROL) ? 2 : (addr == `SL_BAUD) ? 3 : 4;
                if (cur_stalled) begin
                    if (addr == `SL_TXDATA) n_txd_stall = n_txd_stall + 1; else n_stall[cls] = n_stall[cls] + 1;
                end
                cur_stalled = 1'b0;
                case (addr)
                    4'd0: begin
                        if (!m_en) begin m_p1 = wdata[1]; m_p3 = wdata[3]; end
                        m_o = {wdata[7:6], 3'b000, wdata[2], 1'b0, wdata[0]};
                    end
                    4'd3: begin
                        if (wdata[0]) m_p3 = m_cpol;
                        if (wdata[0] && !m_en) n_en01 = n_en01 + 1;
                        if (!wdata[0] && m_en) n_en10 = n_en10 + 1;
                        m_en = wdata[0];
                    end
                    `SL_TXDATA: begin m_bb = wdata[7:0]; m_bba = 1'b1; last_ld_idle = 1'b0; end
                    `SL_CONTROL: begin
                        m_cpol = wdata[1]; m_cpha = wdata[0];
                        if (m_en) m_p3 = wdata[1];
                    end
                    `SL_BAUD: m_baud = wdata[7:0];
                    default: ;
                endcase
            end
        end
        m_ins = m_inm; m_inm = in;
    end

    // MISO source of the byte now shifting (5.5): the probe, or the analog slave.
    task new_byte_hook;
        begin
            plan_prev = plan; plan = rnd(0);
            probe_active = (probe_force == 1) || (probe_force == 0 && rn(2) == 1);
        end
    endtask
    // At every negative edge the probe sets in[1] for the coming positive edge: at the
    // sample edge of bit k the RX bit k, at every other edge the complement of the RX
    // bit whose sample edge is nearest (ties: the earlier bit). A DUT that samples one
    // clock early, one clock late, at the A->B edge or through in_s gets the complement.
    always @(negedge clk) begin : probe
        integer t, k0, ph, dprev, dnext, kb;
        reg v;
        probe_drive = probe_active && m_active;
        if (probe_drive) begin
            t = ecnt + 1 - m_L; k0 = t / (2 * m_P); ph = t % (2 * m_P);
            if (t >= 16 * m_P) v = ~plan[0];
            else if (ph == 2 * m_P - 1) v = plan[7 - k0];
            else begin
                dprev = ph + 1; dnext = 2 * m_P - 1 - ph;
                kb = (k0 > 0 && dprev <= dnext) ? k0 - 1 : k0;
                v = ~plan[7 - kb];
            end
            in1_probe = v;
        end
    end

    // ── Analog slave (a generic SPI slave on transport-delayed pins) ────────
    real       rt_out = 0.0, rt_in = 0.0;        // ns
    reg        sck_d = 1'b1, mosi_d = 1'b0, cs_d = 1'b1;
    always @(out[3]) sck_d  <= #(rt_out) out[3];  // transport delays: NBA with a delay
    always @(out[1]) mosi_d <= #(rt_out) out[1];  // (never an inertial `assign #`)
    always @(out[0]) cs_d   <= #(rt_out) out[0];
    reg        do_pre = 1'b0, do_d = 1'b0;
    always @(do_pre) do_d <= #(rt_in) do_pre;
    assign     in1 = probe_drive ? in1_probe : do_d;

    reg        xwin_en = 1'b1;                    // X from +t_OH to +t_ODLY at each change
    reg [7:0]  sl_mem [0:1023];                   // bytes the slave sends
    reg [7:0]  sl_cap [0:1023];                   // bytes the slave received on MOSI
    integer    sl_k = 0, sl_ck = 0;
    task slv_present(input b);
        begin
            if (xwin_en) begin do_pre = 1'bx; do_pre <= #(`SD_T_ODLY) b; end
            else do_pre = b;
        end
    endtask
    task slv_next;
        begin slv_present(sl_mem[(sl_k / 8) % 1024][7 - (sl_k % 8)]); sl_k = sl_k + 1; end
    endtask
    task slv_capture;
        begin sl_cap[(sl_ck / 8) % 1024][7 - (sl_ck % 8)] = mosi_d; sl_ck = sl_ck + 1; end
    endtask
    always @(negedge cs_d) begin
        sl_k = 0; sl_ck = 0;
        if (!m_cpha) slv_next;               // CPHA 0: the first bit appears at the CS# fall
    end
    always @(sck_d) if (cs_d === 1'b0) begin
        if (sck_d !== m_cpol) begin          // leading edge
            if (m_cpha) slv_next; else slv_capture;
        end else begin                       // trailing edge
            if (m_cpha) slv_capture; else slv_next;
        end
    end

    // ── Bus tasks (driven on the negative edge) ─────────────────────────────
    task acc_now(input w, input [3:0] b, input [5:2] a, input [31:0] d, output [31:0] r);
        begin
            sel = 1'b1; we = w; be = b; addr = a; wdata = d;
            @(posedge clk);
            while (!ready) @(posedge clk);
            r = rdata;
            #1 sel = 1'b0; we = 1'b0;
        end
    endtask
    task acc(input w, input [3:0] b, input [5:2] a, input [31:0] d, output [31:0] r);
        begin @(negedge clk); acc_now(w, b, a, d, r); end
    endtask
    reg [31:0] dummy_r;
    task wr(input [5:2] a, input [31:0] d);   begin acc(1'b1, 4'h1, a, d, dummy_r); end endtask
    task rd(input [5:2] a, output [31:0] r);  begin acc(1'b0, 4'hF, a, 32'h0, r); end endtask
    task idle(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                @(negedge clk);
                sel = 1'b0; we = rn(2); be = rn(16); addr = rn(16); wdata = rnd(0);
            end
        end
    endtask
    // Clocks from the (last) load edge to the next positive edge: 0 when that edge is the load.
    function integer tnext(input dummy);
        tnext = (m_bba && !m_active) ? 0 : (ecnt + 1 - m_L);
    endfunction
    // Return at a negative edge such that the next positive edge is at t == tn
    // (clocks after the load edge of the byte now shifting).
    task aim(input integer tn);
        integer g;
        begin
            g = 0;
            @(negedge clk);
            while (tnext(0) != tn && g < 200000) begin
                sel = 1'b0; we = rn(2); be = rn(16); addr = rn(16); wdata = rnd(0);
                @(negedge clk); g = g + 1;
            end
            if (g >= 200000) fail("aim: never reached the clock", tn, 0);
        end
    endtask
    task wait_txe;
        reg [31:0] v; integer g;
        begin
            g = 0; v = 0;
            while (!v[0] && g < 100000) begin rd(`SL_STATUS, v); g = g + 1; end
            if (!v[0]) fail("wait_txe timed out", v, 1);
        end
    endtask
    task wait_txr;
        reg [31:0] v; integer g;
        begin
            g = 0; v = 0;
            while (!v[1] && g < 100000) begin rd(`SL_STATUS, v); g = g + 1; end
            if (!v[1]) fail("wait_txr timed out", v, 2);
        end
    endtask
    task cfg(input [1:0] mode, input [7:0] b);   // CONTROL, BAUD, EN = 1
        begin wr(`SL_CONTROL, mode); wr(`SL_BAUD, b); wr(4'd3, 1); end
    endtask
    task pulse_rst(input integer n);
        begin
            @(negedge clk); rst = 1'b1;
            repeat (n) @(negedge clk);
            rst = 1'b0;
        end
    endtask

    // ── The Linux polled driver loop (WO-28 1.1), the three paths ───────────
    reg [7:0] tx_buf [0:511];
    reg [7:0] rx_buf [0:511];
    // drv_slow = 1: a slow driver, every write after the first waits 16(B+1) + 0..7 clocks, so the
    // engine is idle and the write is loaded from IDLE (bb <= sr, REQ-SPI-011), not back-to-back.
    reg     drv_slow = 1'b0;
    integer drv_B = 0;
    task drv_xfer(input integer len, input do_tx, input do_rx);
        integer i; reg [31:0] v;
        begin
            wr(`SL_TXDATA, do_tx ? tx_buf[0] : 8'hFF);
            for (i = 1; i < len; i = i + 1) begin
                if (drv_slow) idle(16 * (drv_B + 1) + rn(8));
                wr(`SL_TXDATA, do_tx ? tx_buf[i] : 8'hFF);
                wait_txr;
                if (do_rx) begin rd(`SL_TXDATA, v); rx_buf[i - 1] = v[7:0]; end
            end
            wait_txe;
            if (do_rx) begin rd(`SL_RXDATA, v); rx_buf[len - 1] = v[7:0]; end
        end
    endtask
    // One chip-selected transfer against the analog slave; checks both directions.
    task drv_frame(input integer len, input do_tx, input do_rx);
        integer i;
        begin
            for (i = 0; i < len + 2; i = i + 1) begin sl_mem[i % 1024] = rnd(0); end
            for (i = 0; i < len; i = i + 1) tx_buf[i] = rnd(0);
            wait_txe;
            wr(4'd0, 32'h0000_0081 & ~32'h1);            // OLED CS# low (OUT bit 0), SD CS# stays high... bit 7 = 1
            drv_xfer(len, do_tx, do_rx);
            for (i = 0; i < len; i = i + 1) begin
                if (do_rx) ckv("driver: received byte", rx_buf[i], sl_mem[i]);
                if (do_tx) ckv("driver: byte the slave captured", sl_cap[i], tx_buf[i]);
            end
            wr(4'd0, 32'h0000_0081);                     // CS# high
        end
    endtask

    // ── Sections ────────────────────────────────────────────────────────────
    reg [31:0] v;
    integer    i, j, m, p, bi;
    reg [7:0]  bset [0:6];
    reg [7:0]  bsel;

    task t01;
        begin
            sect("T01 reset values");
            for (i = 0; i < 16; i = i + 1) begin
                rd(i[3:0], v);
                case (i)
                    0:  ckv("OUT reset", v, 32'h89);
                    10: ckv("STATUS reset", v, 32'h3);
                    11: ckv("CONTROL reset", v, 32'h3);
                    12: ckv("BAUD reset", v, 32'hFF);
                    1:  ;
                    default: ckv("reset value of a reserved slot / register", v, 32'h0);
                endcase
            end
        end
    endtask

    task t02;
        reg [7:0] pat [0:3];
        reg [31:0] up;
        begin
            sect("T02 registers");
            pat[0] = 8'h00; pat[1] = 8'hFF; pat[2] = 8'hA5; pat[3] = 8'h5A;
            for (i = 0; i < 4; i = i + 1)
                for (j = 0; j < 8; j = j + 1) begin
                    up = {rnd(0)} & 32'hFFFF_FF00;
                    if (j == 1) up = 32'hFFFF_FF00;
                    if (j == 2) up = 32'h0000_0000;
                    wr(`SL_CONTROL, up | pat[i]); rd(`SL_CONTROL, v); ckv("CONTROL readback", v, {30'b0, pat[i][1:0]});
                    wr(`SL_BAUD, up | pat[i]);    rd(`SL_BAUD, v);    ckv("BAUD readback", v, pat[i]);
                    wr(4'd0, up | pat[i]);        rd(4'd0, v);        ckv("OUT readback (bits 7, 6, 2, 0; 5:4 read 0)", v & 32'hF5, pat[i] & 32'hC5);
                    wr(4'd3, up | pat[i]);        rd(4'd3, v);        ckv("SPICTL readback", v, {31'b0, pat[i][0]});
                    wr(`SL_STATUS, up | pat[i]);  rd(`SL_STATUS, v);  ckv("STATUS write ignored", v, 32'h3);
                    for (m = 0; m < 16; m = m + 1)
                        if (m != 0 && m != 1 && m != 3 && m != 8 && m != 9 && m != 10 && m != 11 && m != 12) begin
                            wr(m[3:0], up | pat[i]); rd(m[3:0], v); ckv("reserved slot", v, 32'h0);
                        end
                end
            wr(4'd3, 0); wr(4'd0, 32'h89); wr(`SL_CONTROL, 3); wr(`SL_BAUD, 8'hFF);
        end
    endtask

    task t03;
        integer b, md, w_edge, e, g; reg [7:0] txv; reg [31:0] st; reg done;
        begin
            sect("T03 one byte, 4 modes x 7 BAUDs");
            bset[0] = 0; bset[1] = 1; bset[2] = 2; bset[3] = 3; bset[4] = 78; bset[5] = 254; bset[6] = 255;
            for (md = 0; md < 4; md = md + 1)
                for (bi = 0; bi < 7; bi = bi + 1) begin
                    b = bset[bi];
                    wait_txe; cfg(md[1:0], bset[bi]);
                    txv = rnd(0);
                    wr(`SL_TXDATA, txv); w_edge = last_acc_edge;
                    done = 1'b0; g = 0;
                    while (!done && g < 20 * (b + 1) + 100) begin
                        rd(`SL_STATUS, st); e = ecnt; g = g + 1;
                        // TXE rises at w + 1 + 16(B+1): the first read after that edge sees it
                        ckv("TXE timing", st[0], (e > w_edge + 1 + 16 * (b + 1)));
                        if (st[0]) done = 1'b1;
                    end
                    ckv("TXE seen", done, 1);
                end
        end
    endtask

    task t04;
        integer md, g, bsz, nb; reg [7:0] pa;
        begin
            sect("T04 MISO probe");
            probe_force = 1;
            bset[0] = 0; bset[1] = 1; bset[2] = 2; bset[3] = 3; bset[4] = 78;
            for (md = 0; md < 4; md = md + 1)
                for (bi = 0; bi < 5; bi = bi + 1) begin
                    wait_txe; cfg(md[1:0], bset[bi]);
                    for (g = 0; g < 32; g = g + 1) begin          // 32 pairs = 64 bytes
                        wr(`SL_TXDATA, rnd(0)); wr(`SL_TXDATA, rnd(0));
                        wait_txr;
                        rd(`SL_TXDATA, v);  ckv("probe: TXDATA after the back-to-back load = the first RX byte", v, plan_prev);
                        wait_txe;
                        rd(`SL_RXDATA, v);  ckv("probe: RXDATA at TXE = the last RX byte", v, plan);
                        if (g % 8 == 7) begin wr(`SL_TXDATA, rnd(0)); wait_txe; rd(`SL_RXDATA, v); ckv("probe: lone byte", v, plan); end
                    end
                end
            probe_force = 0;
        end
    endtask

    task t05;
        integer len, pth, bb, md;
        begin
            sect("T05 the driver loop");
            rt_out = 0.0; rt_in = 0.0; xwin_en = 1'b1; probe_force = 2;
            for (md = 0; md < 4; md = md + 1) begin
                wr(`SL_CONTROL, md); wr(`SL_BAUD, 1); wr(4'd3, 1);
                for (pth = 0; pth < 3; pth = pth + 1)
                    for (len = 1; len <= 3; len = len + 1) drv_frame(len, pth != 1, pth != 2);
            end
            for (bb = 0; bb < 3; bb = bb + 1) begin
                wr(`SL_CONTROL, 3); wr(`SL_BAUD, (bb == 0) ? 0 : (bb == 1) ? 2 : 3);
                drv_frame(17, 1, 1);
                if (bb != 2) begin drv_frame(512, 1, 1); drv_frame(512, 0, 1); drv_frame(512, 1, 0); end
            end
            // The slow driver: each write finds the engine idle (an IDLE load), TXDATA then reads the
            // previous RX byte, checked against the slave's memory.
            drv_slow = 1'b1;
            for (bb = 0; bb < 2; bb = bb + 1) begin
                drv_B = (bb == 0) ? 0 : 2;
                wr(`SL_CONTROL, 3); wr(`SL_BAUD, drv_B);
                for (pth = 0; pth < 3; pth = pth + 1) begin
                    drv_frame(6, pth != 1, pth != 2);
                    drv_frame(20, pth != 1, pth != 2);
                end
            end
            drv_slow = 1'b0;
            probe_force = 0;
        end
    endtask

    task t06;
        integer p0, bb, lst; reg [31:0] st;
        begin
            sect("T06 back-to-back writes at every clock of a byte");
            cfg(2'b11, 1);
            for (p0 = 0; p0 <= 34; p0 = p0 + 1) begin
                wait_txe; wr(`SL_TXDATA, rnd(0));
                aim(p0);
                acc_now(1'b1, 4'h1, `SL_TXDATA, rnd(0), dummy_r);
                wait_txe; rd(`SL_RXDATA, v);
            end
            for (bi = 0; bi < 3; bi = bi + 1) begin
                bb = (bi == 0) ? 0 : (bi == 1) ? 2 : 78;
                cfg(2'b11, bb);
                for (p0 = -1; p0 <= 1; p0 = p0 + 1) begin
                    wait_txe; wr(`SL_TXDATA, rnd(0));
                    aim(16 * (bb + 1) + p0);
                    acc_now(1'b1, 4'h1, `SL_TXDATA, rnd(0), dummy_r);
                    wait_txe;
                end
            end
        end
    endtask

    task t07;
        integer p0, c, bb; reg [3:0] a;
        begin
            sect("T07 writes while busy");
            cfg(2'b11, 1);
            for (c = 0; c < 6; c = c + 1)
                for (p0 = 0; p0 <= 33; p0 = p0 + 1) begin
                    wait_txe; wr(`SL_TXDATA, rnd(0));
                    aim(p0);
                    case (c)
                        0: acc_now(1'b1, 4'h1, 4'd0, 32'h89, dummy_r);
                        1: acc_now(1'b1, 4'h1, 4'd3, 32'h1, dummy_r);
                        2: acc_now(1'b1, 4'h1, `SL_CONTROL, 32'h3, dummy_r);
                        3: acc_now(1'b1, 4'h1, `SL_BAUD, 32'h1, dummy_r);
                        4: acc_now(1'b1, 4'h1, `SL_STATUS, 32'hFF, dummy_r);
                        5: acc_now(1'b1, 4'h1, 4'd2, 32'hFF, dummy_r);
                    endcase
                end
            cfg(2'b11, 3);
            for (c = 0; c < 6; c = c + 1)
                for (p0 = -1; p0 <= 1; p0 = p0 + 1) begin
                    wait_txe; wr(`SL_TXDATA, rnd(0));
                    aim(64 + p0);
                    case (c)
                        0: acc_now(1'b1, 4'h1, 4'd0, 32'h89, dummy_r);
                        1: acc_now(1'b1, 4'h1, 4'd3, 32'h1, dummy_r);
                        2: acc_now(1'b1, 4'h1, `SL_CONTROL, 32'h3, dummy_r);
                        3: acc_now(1'b1, 4'h1, `SL_BAUD, 32'h3, dummy_r);
                        4: acc_now(1'b1, 4'h1, `SL_STATUS, 32'hFF, dummy_r);
                        5: acc_now(1'b1, 4'h1, 4'd14, 32'hFF, dummy_r);
                    endcase
                end
            wait_txe;
        end
    endtask

    task t08;
        begin
            sect("T08 the TXE race");
            cfg(2'b11, 1);
            for (i = 0; i < 8; i = i + 1) begin
                wait_txe;
                wr(`SL_TXDATA, rnd(0));
                rd(`SL_STATUS, v); ckv("STATUS the clock after the write", v, 32'h0);
                rd(`SL_STATUS, v); ckv("STATUS two clocks after the write", v, 32'h2);
                wait_txe;
            end
        end
    endtask

    task t09;
        integer msk, slot, ph; reg [31:0] d;
        begin
            sect("T09 byte lanes");
            for (ph = 0; ph < 2; ph = ph + 1)
                for (slot = 0; slot < 16; slot = slot + 1)
                    for (msk = 1; msk < 16; msk = msk + 1) begin
                        wait_txe; cfg(2'b11, 1);
                        if (ph) begin wr(`SL_TXDATA, rnd(0)); end
                        d = 32'hA5A5_A501;
                        acc(1'b1, msk[3:0], slot[3:0], d, dummy_r);
                        wait_txe;
                    end
            wr(4'd0, 32'h89);
        end
    endtask

    task t10;
        begin
            sect("T10 EN");
            // (a) a transfer with EN = 0: pins follow OUT, STATUS times the byte
            wait_txe; cfg(2'b11, 1); wr(4'd3, 0);
            wr(4'd0, 32'h0000_0081 | 32'h0A);                       // OUT bit 3 and bit 1 set
            wr(`SL_TXDATA, 8'hA5); wait_txe;
            wr(4'd0, 32'h0000_0081); wr(`SL_TXDATA, 8'h3C); wait_txe;
            // (b) OUT writes to bits 1/3 are ignored with EN = 1, incl. a gpio-mmio style whole word
            wr(4'd3, 1);
            for (i = 0; i < 16; i = i + 1) begin wr(4'd0, {24'b0, i[3:0], 4'b0000} | 32'h89 | (i << 1)); rd(4'd0, v); end
            wr(4'd0, 32'h0000_0081); wr(4'd0, 32'h0000_00FF); wr(4'd0, 32'h89);
            wr(`SL_TXDATA, 8'hC3); wait_txe;
            wr(4'd0, 32'h0000_0001 ^ 32'h0000_008A);                // bits 1/3 inverted vs the pins
            // (c) OUT bit 3 = !CPOL, then EN 0 -> 1: SCK goes to CPOL on that edge
            for (i = 0; i < 4; i = i + 1) begin
                wr(4'd3, 0); wr(`SL_CONTROL, i[1:0]);
                wr(4'd0, {24'b0, 8'h81 | ((i[1] ? 8'h00 : 8'h08))});  // SCK = !CPOL
                wr(4'd3, 1); rd(4'd0, v);
            end
            // (d) EN 1 -> 0: the pins hold
            wr(`SL_CONTROL, 0); wr(4'd3, 1); wr(`SL_TXDATA, 8'hFF); wait_txe; wr(4'd3, 0); rd(4'd0, v);
            // (e) CONTROL write with EN = 1 moves SCK to the new CPOL; with EN = 0 it does not
            wr(4'd3, 1);
            for (i = 0; i < 4; i = i + 1) begin wr(`SL_CONTROL, i[1:0]); rd(4'd0, v); end
            wr(4'd3, 0);
            for (i = 0; i < 4; i = i + 1) begin wr(`SL_CONTROL, i[1:0]); rd(4'd0, v); end
            wr(`SL_CONTROL, 3); wr(4'd0, 32'h89); wr(4'd3, 1); rd(4'd0, v); ckv("SCK at the mode-3 idle level", v, 32'h89);
        end
    endtask

    task t11;
        integer bb, p0, n;
        begin
            sect("T11 reset in the middle of a byte");
            for (bi = 0; bi < 4; bi = bi + 1) begin
                bb = (bi == 0) ? 1 : (bi == 1) ? 0 : (bi == 2) ? 2 : 78;
                n = (bi == 0) ? 35 : 48;
                for (p0 = 0; p0 < n; p0 = p0 + 1) begin
                    wait_txe; cfg(rn(4), bb);
                    wr(`SL_TXDATA, rnd(0));
                    if (p0 > 1 && rn(2)) wr(`SL_TXDATA, rnd(0));   // bba = 1 in some of them
                    aim((bi == 0) ? p0 : 2 + rn(16 * (bb + 1)));
                    rst = 1'b1; @(negedge clk); rst = 1'b0;
                    rd(4'd0, v); ckv("OUT after a mid-byte reset", v, 32'h89);
                    rd(`SL_STATUS, v); ckv("STATUS after a mid-byte reset", v, 32'h3);
                    rd(`SL_BAUD, v); ckv("BAUD after a mid-byte reset", v, 32'hFF);
                end
            end
        end
    endtask

    task t12;
        integer bb, g;
        begin
            sect("T12 RXDATA and TXDATA at every clock of a byte");
            for (bi = 0; bi < 3; bi = bi + 1) begin
                bb = (bi == 0) ? 1 : (bi == 1) ? 0 : 3;
                cfg(2'b11, bb); wait_txe;
                wr(`SL_TXDATA, rnd(0)); wr(`SL_TXDATA, rnd(0));
                for (g = 0; g < 34 * (bb + 1) + 4; g = g + 1) begin
                    rd(`SL_RXDATA, v); rd(`SL_TXDATA, v);
                end
                wait_txe; rd(`SL_RXDATA, v);
            end
        end
    endtask

    task t13;
        begin
            sect("T13 ready only while selected");
            cfg(2'b11, 3);
            wr(`SL_TXDATA, rnd(0)); wr(`SL_TXDATA, rnd(0));
            idle(1500);
            wait_txe;
        end
    endtask

    // Round-trip sweep: transport delays on SCK/MOSI out and DO in, split equally. RX is
    // correct iff rt + t_ODLY < (2B+1) T. Bytes 0xAA so a stale bit is always wrong.
    integer sw_pass [0:100];
    task rt_point(input real rt, output pass_o);
        integer i; reg ok;
        begin
            rt_out = rt / 2.0; rt_in = rt / 2.0; idle(40);
            for (i = 0; i < 8; i = i + 1) sl_mem[i] = 8'hAA;
            wait_txe; wr(4'd0, 32'h0000_0080);                      // OLED CS# low
            drv_xfer(4, 1'b0, 1'b1);
            wr(4'd0, 32'h0000_0081);
            ok = 1'b1;
            for (i = 0; i < 4; i = i + 1) if (rx_buf[i] !== 8'hAA) ok = 1'b0;
            pass_o = ok;
        end
    endtask
    task t14;
        integer b, n, k, lp, ff, bad; real rt, pred; reg ok;
        begin
            sect("T14 round-trip sweep");
            probe_force = 2; xwin_en = 1'b1; x_ok = 1'b1;
            for (b = 0; b < 3; b = b + 1) begin
                wait_txe; cfg(2'b11, b);
                n = (b == 0) ? 11 : 81;
                pred = (2.0 * b + 1.0) * T - `SD_T_ODLY - 0.5;
                lp = -1; ff = -1; bad = 0;
                for (k = 0; k < n; k = k + 1) begin
                    rt = k + 0.5;
                    rt_point(rt, ok);
                    if (ok) lp = k; else if (ff < 0) ff = k;
                    if ((rt <= pred) != ok) bad = bad + 1;
                end
                $display("RTSWEEP baud=%0d last_pass=%0.1f first_fail=%0.1f predicted=%0.1f %0s", b,
                         (lp < 0) ? -1.0 : lp + 0.5, (ff < 0) ? -1.0 : ff + 0.5, pred, bad == 0 ? "OK" : "MISMATCH");
                checks = checks + 1;
                if (bad != 0) fail("RTSWEEP: the passing set is not rt < (2B+1) T - t_ODLY", bad, 0);
            end
            // BAUD 0 at rt = 25 must fail ("never BAUD 0 for receive")
            wait_txe; cfg(2'b11, 0);
            rt_point(25.0, ok);
            checks = checks + 1;
            if (ok) fail("BAUD 0 at rt = 25 ns received correctly (the expected failure is absent)", 1, 0);
            else $display("RTSWEEP baud=0 rt=25.0 expected-fail seen");
            rt_out = 0.0; rt_in = 0.0; idle(40);
            x_ok = 1'b0; probe_force = 0;
            pulse_rst(2);                                          // flush the X the failing points shifted in
            idle(4);
        end
    endtask

    // ── The random phase ────────────────────────────────────────────────────
    reg        rand_rst_en = 1'b0;
    integer    rst_left = 0;
    always @(negedge clk) if (rand_rst_en) begin
        if (rst_left == 0 && rn(5000) == 0) rst_left = 1 + rn(3);
        if (rst_left > 0) begin rst = 1'b1; rst_left = rst_left - 1; end
        else rst = 1'b0;
    end
    always @(negedge clk) in_hi = rnd(0);

    integer slow_last = 0, slow_rr = 0;
    function [7:0] pick_baud(input dummy);
        integer c;
        begin
            c = rn(100);
            if (c < 60) pick_baud = rn(4);
            else if (c < 85) pick_baud = (rn(12) == 0) ? 78 : 4 + rn(74);   // one in 12 is B=78 (the floor of 5 bytes needs about this; seeds 1-4 reach 8, 10, 5, 13)
            else if (ecnt - slow_last > 1500) begin
                slow_last = ecnt; slow_rr = slow_rr + 1;
                case (slow_rr % 4)
                    0: pick_baud = 78;
                    1: pick_baud = 79 + rn(175);
                    2: pick_baud = 254 + rn(2);
                    default: pick_baud = 79 + rn(175);
                endcase
            end else pick_baud = rn(4);
        end
    endfunction

    task rand_phase(input integer ncyc);
        integer end_e, c, p, q, tn, nb0; reg [3:0] b; reg [31:0] d, r;
        begin
            sect("random phase");
            snap;
            probe_force = 0;
            end_e = ecnt + ncyc; nb0 = n_bytes;
            xwin_en = 1'b0;
            wr(`SL_CONTROL, 3); wr(`SL_BAUD, 1); wr(4'd3, 1);
            rand_rst_en = 1'b1;
            while (ecnt < end_e) begin
                if (m_baud >= 8'd78 && rn(100) < 6) rst_left = 1;            // leave a slow BAUD soon
                if (!m_active && !m_bba && m_baud == 8'hFF && ecnt - slow_last > 200 && rn(2))
                    acc(1'b1, 4'h1, `SL_BAUD, rn(4), r);
                c = rn(100);
                b = {rn(8), 1'b1};
                d = rnd(0);
                if (c < 25) idle(1);
                else if (c < 35) begin
                    sel = 1'b0; @(negedge clk);
                    sel = 1'b0; we = rn(2); be = rn(16); addr = rn(16); wdata = rnd(0);
                end else begin
                    p = rn(100);
                    if (p < 35) begin
                        if (m_active && rn(100) < 30 && m_P <= 4) begin
                            tn = 16 * m_P + rn(3) - 1;
                            if (ecnt + 2 - m_L <= tn) aim(tn);
                        end
                        acc(1'b1, b, `SL_TXDATA, d, r);
                    end else if (p < 50) acc(1'b0, 4'hF, `SL_STATUS, 0, r);
                    else if (p < 60) acc(1'b0, 4'hF, rn(2) ? `SL_RXDATA : `SL_TXDATA, 0, r);
                    else if (p < 70) begin
                        q = rn(8);
                        if (q < 5) acc(1'b1, b, `SL_CONTROL, d, r);
                        else if (q < 6) acc(1'b1, b, `SL_BAUD, pick_baud(0), r);
                        else acc(1'b1, b, 4'd3, (rn(3) == 0) ? {31'b0, ~m_en} : {31'b0, m_en | (rn(4) != 0)}, r);
                    end else if (p < 80) acc(1'b1, b, 4'd0, d, r);
                    else if (p < 90) begin
                        if (rn(4) == 0) acc(1'b1, b, (rn(2) ? 4'd2 : (4'd13 + rn(3))) , d, r);
                        else acc(1'b1, {rn(8), 1'b0} & 4'hE, rn(16), d, r);   // no byte lane 0: never stalls
                    end else acc(1'b0, 4'hF, rn(2) ? 4'd0 : `SL_BAUD, 0, r);
                end
            end
            rand_rst_en = 1'b0; rst = 1'b0;
            $display("random phase: %0d bytes", n_bytes - nb0);
            idle(4);
        end
    endtask

    // ── Floors, run and verdict ─────────────────────────────────────────────
    integer seed = 1, ncycles = 300000, floor_bad = 0, f;
    task floor(input string name, input integer got, input integer fl);
        begin
            $display("coverage: %0s=%0d/%0d", name, got, fl);
            if (got < fl) begin floor_bad = floor_bad + 1; $display("FAIL coverage floor missed: %0s", name); end
        end
    endtask

    initial begin
        if (!$value$plusargs("SEED=%d", seed)) seed = 1;
        if (!$value$plusargs("CYCLES=%d", ncycles)) ncycles = 300000;
        rs = 32'h9E3779B9 ^ (seed * 32'h85EBCA6B); if (rs == 0) rs = 1;
        for (i = 0; i < 1024; i = i + 1) begin sl_mem[i] = 8'h00; sl_cap[i] = 8'h00; end
        repeat (4) @(negedge clk);
        rst = 1'b0;
        idle(2);
        t01; t02; t03; t04; t05; t06; t07; t08; t09; t10; t11; t12; t13; t14;
        rand_phase(ncycles);
        sect("end");
        if (errors == 0) begin
            // Random-phase floors: counters minus the snapshot taken when the random phase began.
            floor("bytes mode 0", cov_mode[0] - s_mode[0], 300); floor("bytes mode 1", cov_mode[1] - s_mode[1], 300);
            floor("bytes mode 2", cov_mode[2] - s_mode[2], 300); floor("bytes mode 3", cov_mode[3] - s_mode[3], 300);
            floor("bytes B=0", cov_bin[0] - s_bin[0], 40); floor("bytes B=1", cov_bin[1] - s_bin[1], 40);
            floor("bytes B=2", cov_bin[2] - s_bin[2], 40); floor("bytes B=3", cov_bin[3] - s_bin[3], 40);
            floor("bytes B=4-77", cov_bin[4] - s_bin[4], 20); floor("bytes B=78", cov_bin[5] - s_bin[5], 5);
            floor("bytes B=79-253", cov_bin[6] - s_bin[6], 5); floor("bytes B=254-255", cov_bin[7] - s_bin[7], 2);
            floor("back-to-back loads", n_b2b - s_b2b, 300);
            floor("TXDATA writes stalled", n_txd_stall - s_txd_stall, 200);
            floor("stalled OUT writes", n_stall[0] - s_stall[0], 50); floor("stalled SPICTL writes", n_stall[1] - s_stall[1], 50);
            floor("stalled CONTROL writes", n_stall[2] - s_stall[2], 50); floor("stalled BAUD writes", n_stall[3] - s_stall[3], 50);
            floor("stalled STATUS/reserved writes", n_stall[4] - s_stall[4], 50);
            floor("writes without be0 while busy", n_nobe0_busy - s_nobe0, 100);
            floor("EN 0->1", n_en01 - s_en01, 20); floor("EN 1->0", n_en10 - s_en10, 20);
            floor("resets in A", n_rst_a - s_rst_a, 5); floor("resets in B", n_rst_b - s_rst_b, 5);
            floor("resets with bba=1", n_rst_bba - s_rst_bba, 5);
            for (f = 0; f < 8; f = f + 1) begin
                floor($sformatf("RX bit %0d as 0", f), cov_rx0[f] - s_rx0[f], 200);
                floor($sformatf("RX bit %0d as 1", f), cov_rx1[f] - s_rx1[f], 200);
            end
            floor("mid-byte RXDATA reads", n_rdmid - s_rdmid, 100);
            verdict_extra;
        end
        if (errors == 0 && floor_bad == 0)
            $display("PASS tb_spi (%0d checks, %0d bytes, %0d back-to-back, %0d probe bits, seed %0d)",
                     checks, n_bytes, n_b2b, n_probe, seed);
        else
            $display("FAIL tb_spi: %0d errors, %0d coverage floors missed (seed %0d)", errors, floor_bad, seed);
        $finish;
    end
    task verdict_extra; begin floor("probe bits", n_probe, 10240); floor("TXDATA reads after an idle load", n_idld_rd, 50); end endtask

    initial begin
        #((ncycles + 6_000_000) * T);
        $display("TIMEOUT tb_spi at cycle %0d, section %0s", ecnt, section);
        $finish;
    end
endmodule
