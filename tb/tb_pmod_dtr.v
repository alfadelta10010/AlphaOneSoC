// Unit bench for the DTR (EDh) support of tb/qspi_pmod_model.v: no RTL, no clk. The host is
// a behavioural, time-based BFM that drives the model's pins and reads what it returns.
// tb/pmod_dtr_run.sh builds it and runs the case list.
//
// Flash content: byte a = a[7:0] ^ a[15:8] ^ a[23:16] ^ 5Ah, loaded for 000000-0007FF and
// FFF000-FFFFFF. The host checks every nibble it captures (value, not X, device driving).
//
// Plusargs (times in ps, hex without prefix):
//   +SEQ=open|stream|p12   what to run (default open)
//   +OPEN_A=<hex> +OPEN_N=<bytes>      the EDh open (default 000100, 4)
//   +MODE_HEX=<hex>        the mode byte (default FF)
//   +SCK_PS (40000)        SCK period
//   +SU_PS                 how long before a sampled edge the host changes data (default SCK/4)
//   +SU_R_PS, +SU_F_PS     the same for the address / mode nibbles sampled on a rise / a fall
//   +SU_C_PS               the same for command, SDR address and mode bits (default 3/8 SCK)
//   +CS_SU_PS (20000)      CS falls this long before the first rise
//   +CS_H_PS (5000)        CS rises this long after the last SCK edge (not before the last capture)
//   +REL_PS (10000)        IO released this long after fall 11; +NO_REL never releases
//   +CAP_PS (8000)         the host samples a nibble this long after the edge it believes
//                          launched it; +SWEEP samples at every 500 ps from 0 to 60 ns and
//                          prints the offsets at which every nibble was right
//   +HOST_LAUNCH=0|1       the edge the host believes launches nibble 1 (fall 18 / rise 19)
//   +DROP_K=<k> +DROP_PS=<ps>   the host releases IO this long before the edge of address
//                          or mode nibble k (0..7; even k is a rise) instead of driving it
//   +FLASH_QPI             send EDh in QPI form (the model is told the same plusarg)
// The model's own plusargs (+QSPI_DELAY, +QSPI_HOLD, +DTR_LAUNCH, +DTR_DUMMY, +QSPI_*_DLY_PS,
// +QSPI_DTR_UNALIGNED_OK) pass straight through.
//
// Output: "tb_pmod_dtr: PASS|FAIL", "tb_pmod_dtr: SCK cycles <n>", "tb_pmod_dtr: sweep pass
// ps: ...", plus the model's own lines.
`timescale 1ns / 1ps

module tb_pmod_dtr #(
    parameter real TDVCH_NS    = 1.0,
    parameter real TCHDX_NS    = 2.0,
    parameter real TDVCL_NS    = 1.0,
    parameter real TCLDX_NS    = 2.0,
    parameter real TSLCH_NS    = 3.0,
    parameter real TCHSH_NS    = 3.0,
    parameter real TCLK_DTR_NS = 15.15
);
    reg       sck = 1'b0, ctl_oe = 1'b1, io_oe = 1'b0;
    reg [2:0] cs_n = 3'b111;
    reg [3:0] io_out = 4'h0;
    wire [3:0] dev_io;
    wire       dev_oe;

    qspi_pmod_model #(.TDVCH_NS(TDVCH_NS), .TCHDX_NS(TCHDX_NS), .TDVCL_NS(TDVCL_NS),
                      .TCLDX_NS(TCLDX_NS), .TSLCH_NS(TSLCH_NS), .TCHSH_NS(TCHSH_NS),
                      .TCLK_DTR_NS(TCLK_DTR_NS)) pmod (
        .host_sck(sck), .host_cs_n(cs_n), .host_ctl_oe(ctl_oe),
        .host_io(io_out), .host_oe(io_oe), .dev_io(dev_io), .dev_oe(dev_oe));

    // ---- configuration -------------------------------------------------------------------
    integer pa;
    realtime P, H, SU_R, SU_F, SU_C, CS_SU, CS_H, REL, CAP;
    reg [23:0] open_a;
    reg [7:0]  mode_hex;
    integer    open_n, host_launch, drop_k;
    realtime   drop_t;
    reg        no_rel, sweep, qpi_form;
    reg [8*16-1:0] seq;

    initial begin
        pa = 40000; if ($value$plusargs("SCK_PS=%d", pa)) ;
        P = pa / 1000.0; H = P / 2.0;
        pa = pa / 4;  if ($value$plusargs("SU_PS=%d", pa)) ;
        SU_R = pa / 1000.0; SU_F = pa / 1000.0;
        if ($value$plusargs("SU_R_PS=%d", pa)) SU_R = pa / 1000.0;
        if ($value$plusargs("SU_F_PS=%d", pa)) SU_F = pa / 1000.0;
        SU_C = P * 3.0 / 8.0;
        if ($value$plusargs("SU_C_PS=%d", pa)) SU_C = pa / 1000.0;
        CS_SU = 20.0; if ($value$plusargs("CS_SU_PS=%d", pa)) CS_SU = pa / 1000.0;
        CS_H  = 5.0;  if ($value$plusargs("CS_H_PS=%d", pa))  CS_H  = pa / 1000.0;
        REL   = 10.0; if ($value$plusargs("REL_PS=%d", pa))   REL   = pa / 1000.0;
        CAP   = 8.0;  if ($value$plusargs("CAP_PS=%d", pa))   CAP   = pa / 1000.0;
        open_a = 24'h000100; if ($value$plusargs("OPEN_A=%h", open_a)) ;
        open_n = 4;          if ($value$plusargs("OPEN_N=%d", open_n)) ;
        mode_hex = 8'hFF;    if ($value$plusargs("MODE_HEX=%h", mode_hex)) ;
        host_launch = 0;     if ($value$plusargs("HOST_LAUNCH=%d", host_launch)) ;
        drop_k = -1;         if ($value$plusargs("DROP_K=%d", drop_k)) ;
        pa = 500;            if ($value$plusargs("DROP_PS=%d", pa)) ;
        drop_t = pa / 1000.0;
        no_rel = $test$plusargs("NO_REL");
        sweep  = $test$plusargs("SWEEP");
        qpi_form = $test$plusargs("FLASH_QPI");
        seq = "open";        if ($value$plusargs("SEQ=%s", seq)) ;
    end

    // ---- flash content and the host's view of it -------------------------------------------
    function [7:0] fb(input [23:0] a);
        fb = a[7:0] ^ a[15:8] ^ a[23:16] ^ 8'h5A;
    endfunction
    integer fi;
    initial begin
        for (fi = 0; fi < 2048; fi = fi + 1) pmod.flash[fi] = fb(fi);
        for (fi = 24'hFFF000; fi < 32'h1000000; fi = fi + 1) pmod.flash[fi] = fb(fi);
    end

    reg [23:0] s_a0;           // address of the stream's first byte
    integer    ni;             // nibbles the host believes launched so far
    realtime   t_last;         // time of the last SCK edge the host made
    reg [3:0]  last_exp;       // the last launched nibble
    function [3:0] nib_at(input integer idx);
        reg [23:0] a;
        reg [7:0]  b;
        begin
            a = s_a0 + (idx >> 1);
            b = fb(a);
            nib_at = idx[0] ? b[3:0] : b[7:4];
        end
    endfunction

    // ---- timing helpers --------------------------------------------------------------------
    task automatic at(input realtime t);
        begin
            if (t > $realtime) #(t - $realtime);
        end
    endtask

    integer cap_n = 0, cap_bad = 0, errs = 0, sck_cycles = 0, exp_resume = 0, total_nibs = 0;
    integer last_launch_idx = -1;
    reg [120:0] sw_ok = {121{1'b1}};     // offsets 0, 0.5 ... 60 ns that were right every time

    // Captures run in module-level processes, one slot per launch (iverilog 12 cannot fork an
    // automatic task from an automatic task). A slot is reused after 64 launches.
    reg [63:0] trig = 64'b0;
    realtime   sl_te [0:63];
    reg [3:0]  sl_ex [0:63];
    integer    sl_idx[0:63];
    integer    slot = 0;
    genvar g;
    generate for (g = 0; g < 64; g = g + 1) begin : cs
        integer c;
        always @(trig[g]) begin
            if (sweep) begin
                for (c = 0; c <= 120; c = c + 1) begin
                    at(sl_te[g] + c * 0.5);
                    if (!(dev_oe === 1'b1 && dev_io === sl_ex[g])) sw_ok[c] = 1'b0;
                end
            end else begin
                at(sl_te[g] + CAP);
                cap_n = cap_n + 1;
                if (!(dev_oe === 1'b1 && dev_io === sl_ex[g])) begin
                    cap_bad = cap_bad + 1;
                    if (cap_bad <= 6)
                        $display("tb_pmod_dtr: capture of nibble %0d at %0t: oe=%b io=%b, want %h",
                                 sl_idx[g], $time, dev_oe, dev_io, sl_ex[g]);
                end
            end
        end
    end endgenerate

    // The host believes this edge launched the next nibble: capture it.
    reg skip_sw = 1'b0;      // sweep: the next launch is a held nibble, not a sweep point
    integer sel_nibs = 0, exp_bytes = 0;
    task launch_seen(input realtime te);
        reg [3:0] ex;
        begin
            ex = nib_at(ni);
            last_exp = ex;
            total_nibs = total_nibs + 1;
            sel_nibs = sel_nibs + 1;
            if (!(sweep && skip_sw)) begin
                sl_te[slot] = te; sl_ex[slot] = ex; sl_idx[slot] = ni;
                trig[slot] = ~trig[slot];
                slot = (slot + 1) % 64;
            end
            skip_sw = 1'b0;
            ni = ni + 1;
        end
    endtask

    // One SCK edge, gap after the last one; if have, the host first changes IO su before it.
    task half(input realtime su, input have, input [3:0] nib, input launch, input realtime gap);
        realtime te;
        begin
            te = t_last + gap;
            if (have) begin
                at(te - su);
                io_out = nib;
                io_oe  = 1'b1;
            end
            at(te);
            sck = ~sck;
            if (sck) sck_cycles = sck_cycles + 1;
            t_last = te;
            if (launch) launch_seen(te);
        end
    endtask

    task cs_begin;
        begin
            ni = 0; sck_cycles = 0; sel_nibs = 0;
            cs_n   = 3'b110;
            t_last = $realtime + CS_SU - H;
        end
    endtask
    task cs_end;
        begin
            // CS stays low until the last capture is done (a release would end it).
            at(t_last + ((sweep ? 61.0 : CAP + 1.0) > CS_H ? (sweep ? 61.0 : CAP + 1.0) : CS_H));
            cs_n  = 3'b111;
            io_oe = 1'b0;
            exp_bytes = exp_bytes + sel_nibs / 2;
            #60;
        end
    endtask

    // Pins in a pause hold the last launched nibble.
    task pause_check(input realtime gap);
        begin
            at(t_last + gap - 1.0);
            cap_n = cap_n + 1;
            if (!(dev_oe === 1'b1 && dev_io === last_exp)) begin
                cap_bad = cap_bad + 1;
                $display("tb_pmod_dtr: pins in a pause at %0t: oe=%b io=%b, want %h",
                         $time, dev_oe, dev_io, last_exp);
            end
        end
    endtask

    // ---- EDh -------------------------------------------------------------------------------
    reg [7:0] ed = 8'hED;
    integer i, k;
    task open_dtr(input [23:0] a, input integer nbytes);
        reg [31:0] nibs;
        begin
            s_a0 = a;
            cs_begin;
            if (qpi_form) begin
                half(SU_C, 1, 4'hE, 0, H); half(0, 0, 4'h0, 0, H);
                half(SU_C, 1, 4'hD, 0, H); half(0, 0, 4'h0, 0, H);
            end else
                for (i = 0; i < 8; i = i + 1) begin
                    half(SU_C, 1, {3'b111, ed[7 - i]}, 0, H);
                    half(0, 0, 4'h0, 0, H);
                end
            // address and mode: one nibble per edge, rise first (fall 7 was the fall above)
            nibs = {a, mode_hex};
            for (k = 0; k < 8; k = k + 1)
                if (k == drop_k) begin
                    at(t_last + H - drop_t);
                    io_oe = 1'b0;
                    half(0, 0, 4'h0, 0, H);
                end else
                    half((k % 2 == 0) ? SU_R : SU_F, 1, nibs[31 - 4 * k -: 4], 0, H);
            at(t_last + REL);
            if (!no_rel) io_oe = 1'b0;
            // dummy cycles (7), the last fall launches nibble 1 (host_launch 0)
            for (k = 0; k < 7; k = k + 1) begin
                half(0, 0, 4'h0, 0, H);
                half(0, 0, 4'h0, (k == 6) && host_launch == 0, H);
            end
            // 2N more launching edges: with the fall launching nibble 1 they are nibbles 2..2N+1,
            // the last one the held nibble; with the rise launching it, nibbles 1..2N.
            for (k = 0; k < 2 * nbytes; k = k + 1) begin
                if (k == 2 * nbytes - 1 && host_launch == 0) skip_sw = 1'b1;
                half(0, 0, 4'h0, 1, H);
            end
        end
    endtask

    // The output hold: just after the resume edge, the nibble from before the pause is
    // still on the pins (QSPI_HOLD is 1 ns by default).
    task resume_hold_check(input [3:0] prev);
        begin
            at(t_last + 0.5);
            cap_n = cap_n + 1;
            if (!sweep && !(dev_oe === 1'b1 && dev_io === prev)) begin
                cap_bad = cap_bad + 1;
                $display("tb_pmod_dtr: pins 0.5 ns after a resume at %0t: oe=%b io=%b, want %h",
                         $time, dev_oe, dev_io, prev);
            end
        end
    endtask

    // Continue the read by nbytes, the first edge gap after the last (0: no pause).
    reg [3:0] prev_nib;
    task cont_dtr(input realtime gap, input integer nbytes);
        begin
            if (gap > 0.0) begin
                pause_check(gap);
                if (gap > 1.5 * H) exp_resume = exp_resume + 1;
            end
            for (k = 0; k < 2 * nbytes; k = k + 1) begin
                prev_nib = last_exp;
                half(0, 0, 4'h0, 1, (k == 0 && gap > 0.0) ? gap : H);
                if (k == 0 && gap > 0.0) resume_hold_check(prev_nib);
            end
        end
    endtask

    // ---- EBh (SDR), for the same-run SDR check ------------------------------------------------
    reg [7:0] eb = 8'hEB;
    task open_eb(input [23:0] a, input integer nbytes);
        reg [23:0] aa;
        begin
            s_a0 = a;
            cs_begin;
            for (i = 0; i < 8; i = i + 1) begin
                half(SU_C, 1, {3'b111, eb[7 - i]}, 0, H);
                half(0, 0, 4'h0, 0, H);
            end
            aa = a;
            for (i = 0; i < 6; i = i + 1) begin
                half(SU_C, 1, aa[23:20], 0, H);
                half(0, 0, 4'h0, 0, H);
                aa = {aa[19:0], 4'h0};
            end
            for (i = 0; i < 2; i = i + 1) begin      // mode byte FFh
                half(SU_C, 1, 4'hF, 0, H);
                half(0, 0, 4'h0, 0, H);
            end
            at(t_last + 1.0);
            io_oe = 1'b0;
            for (i = 0; i < 4; i = i + 1) begin      // dummies; the last fall launches nibble 0
                half(0, 0, 4'h0, 0, H);
                half(0, 0, 4'h0, i == 3, H);
            end
            for (i = 1; i < 2 * nbytes; i = i + 1) begin
                half(0, 0, 4'h0, 0, H);
                half(0, 0, 4'h0, 1, H);
            end
        end
    endtask
    task cont_eb(input realtime gap, input integer nbytes);
        begin
            pause_check(gap);
            if (gap > 1.5 * H) exp_resume = exp_resume + 1;
            for (i = 0; i < 2 * nbytes; i = i + 1) begin
                prev_nib = last_exp;
                half(0, 0, 4'h0, 0, (i == 0) ? gap : H);
                if (i == 0) resume_hold_check(prev_nib);
                half(0, 0, 4'h0, 1, H);
            end
        end
    endtask

    // ---- the run ---------------------------------------------------------------------------
    integer exp_edh = 0, exp_ebh = 0;
    integer jj, nn;
    initial begin
        #100;
        case (seq)
            "open": begin
                open_dtr(open_a, open_n);
                exp_edh = 1;
                cs_end;
            end
            "stream": begin
                open_dtr(24'h000400, 4);
                cont_dtr(1000.0, 4);
                cont_dtr(37.0, 2);
                cont_dtr(0.0, 4);
                cont_dtr(20000.0, 4);
                exp_edh = 1;
                cs_end;
            end
            "p12": begin
                open_dtr(24'h000100, 4);
                exp_edh = 1;
                cs_end;
                open_eb(24'h000300, 4);
                cont_eb(1000.0, 4);
                cont_eb(100.0, 2);
                exp_ebh = 1;
                cs_end;
            end
            default: begin
                $display("tb_pmod_dtr: unknown SEQ");
                $finish;
            end
        endcase
        #300;
        $display("tb_pmod_dtr: SCK cycles %0d", sck_cycles);
        if (sweep) begin
            $write("tb_pmod_dtr: sweep pass ps:");
            for (jj = 0; jj <= 120; jj = jj + 1)
                if (sw_ok[jj]) $write(" %0d", jj * 500);
            $write("\n");
        end else begin
            // Counters the model keeps, against what this run did (a seq runs one DTR launch
            // count: each nibble the host believes launched is one the model launched).
            if (pmod.n_edh !== exp_edh) begin
                errs = errs + 1; $display("tb_pmod_dtr: n_edh %0d, want %0d", pmod.n_edh, exp_edh);
            end
            if (pmod.n_ebh !== exp_ebh) begin
                errs = errs + 1; $display("tb_pmod_dtr: n_ebh %0d, want %0d", pmod.n_ebh, exp_ebh);
            end
            if (pmod.n_resume !== exp_resume) begin
                errs = errs + 1; $display("tb_pmod_dtr: n_resume %0d, want %0d", pmod.n_resume, exp_resume);
            end
            if (pmod.n_bytes !== exp_bytes) begin
                errs = errs + 1; $display("tb_pmod_dtr: n_bytes %0d, want %0d", pmod.n_bytes, exp_bytes);
            end
            $display("tb_pmod_dtr: %0d nibbles captured, %0d wrong, counters: EDh %0d EBh %0d resumes %0d bytes %0d",
                     cap_n, cap_bad, pmod.n_edh, pmod.n_ebh, pmod.n_resume, pmod.n_bytes);
            if (cap_bad == 0 && errs == 0) $display("tb_pmod_dtr: PASS");
            else                           $display("tb_pmod_dtr: FAIL");
        end
        $finish;
    end
endmodule
