// UART -- a 16550A at 0x1000_0000, for the Linux console (8250 driver, ns16550a, with an interrupt).
//
// Byte-wide registers at consecutive offsets (reg-shift = 0, reg-io-width =
// 1), the layout Spike and QEMU's virt board put at the same address, so one
// kernel and a near-identical device tree run on all three:
//
//   offset  read (DLAB=0)       write (DLAB=0)   DLAB=1
//   0       RBR (pops)          THR              DLL
//   1       IER                 IER              DLM
//   2       IIR                 FCR
//   3       LCR                 LCR              LCR
//   4       MCR                 MCR
//   5       LSR                 ignored
//   6       MSR                 ignored
//   7       SCR                 SCR
//
// The core's data port is word-aligned with byte lanes (src/fyracore.v), so
// offset k is lane k[1:0] of word k[2]: `addr2` picks the word and `be` the
// registers in it. Each register sits on a fixed lane, so the write data
// needs no steering. The 8 bytes alias through the rest of the 64 KB window.
//
// Fixed 8N1. baud = clk / (16 x divisor). The divisor resets to DIV_RESET,
// non-zero, so a THR write can never stall forever before software sets it;
// the default, 34, is 114,890 baud (-0.27% from 115200) at the documented
// 62.5 MHz core clock, so a program in flash can print before it programs
// the divisor. A divisor of 0 counts as 1.
//
// Registers and what is kept of them:
//   IER  bits 3:0 (EDSSI, ELSI, ETBEI, ERBFI); EDSSI is stored, MSI never fires.
//   FCR  [0] FEN, [1] clear RX FIFO (and the timeout), [2] clear the TX holding
//        register (the shifter finishes its frame), [7:6] RX trigger
//        1/2/4/7 (stored; Linux's PORT_16550A writes code 2 = 4 bytes).
//        A write that changes FEN also clears the RX FIFO and THR (16550). A clear
//        beats a push in the same clock.
//   IIR  {FEN, FEN, 2'b00, IID}: 6 RLS (ELSI & (OE | head entry has an
//        unacknowledged error)), 4 RDA (ERBFI & rx_n >= trigger), C character timeout
//        (ERBFI & cti), 2 THRE (ETBEI & THR empty), 1 none. THRE is a
//        LEVEL: reading IIR does not clear it (departure from the 16550;
//        Linux's __stop_tx clears ETBEI when it has nothing to send, and its
//        THRE test needs the interrupt on both IIR reads). `irq` = IID != 1,
//        no OUT2 gating (QEMU and Spike do not gate either).
//   LCR  only DLAB (bit 7) and SBC (bit 6, break control) are stored; the
//        other bits read 0. The frame is fixed, and Linux keeps its own copy
//        of LCR. While SBC is set, TX is held at 0 from the next 16x tick
//        (Linux's break_ctl, tcsendbreak); the transmitter keeps shifting
//        underneath, and the pin follows it again after SBC is cleared.
//   MCR  bits 4:0 {LOOP, OUT2, OUT1, RTS, DTR}. Resets to 0x02 (RTS = 1), a
//        departure from the 16550's 0x00, so RTS# flow control works out of
//        reset. OUT1/OUT2/DTR only feed the loopback MSR.
//   LSR  {FIFOERR, TEMT, THRE, BI, FE, 0, OE, DR}. DR = RX FIFO not empty;
//        OE is sticky (a frame completed with the RX FIFO full: the new
//        character is dropped, the FIFO kept), cleared by an LSR read; BI/FE
//        describe the head entry; an LSR read acknowledges them (and the RLS
//        interrupt, err_ack) and the entry itself leaves with its pop; THRE = THR empty; TEMT = THR empty and the shifter
//        idle; FIFOERR = FEN & any queued entry with an error.
//   MSR  0xB0 (CTS, DSR, DCD asserted, no delta bits). In loopback
//        {OUT2, OUT1, DTR, RTS, 4'b0}.
//   SCR  8-bit scratch, resets 0.
//
// RX FIFO: RX_N (8) x 9 bits {err, data}; err = 1 with data 0 is a break
// (BI), err = 1 with data != 0 a framing error (FE). It buffers whatever
// FEN says (departure: a 16450 would overrun at the second character). RBR
// reads 0x00 when it is empty. The trigger is 1/2/4/7 with FEN, 1 without
// (departures from the 16550A's 1/4/8/14 to fit an 8-entry FIFO; code 2, which
// Linux uses, is 4 bytes and leaves 5 character times, ~435 us at 114,890 baud,
// of slack before an overrun: the 8-deep FIFO takes 4 more after the trigger
// plus the one being shifted in).
// Character timeout: a counter of 16x ticks restarts on every push, pop,
// clear and while the FIFO is empty; at 640 ticks (4 characters) it holds
// and cti is set until the next restart.
//
// TX: one holding register THR in front of the shifter (16450 style, a departure
// from the 16550A's 16-byte TX FIFO; IIR[7:6] still reads 11 so autoconfig sees
// FIFOs). THRE = THR empty, TEMT = THR and shifter empty. A THR write with THR
// full does not complete: `ready` stays low (only while the write is selected)
// until the shifter takes the character, and the write lands one clock after the
// take (ready follows thr_v, which falls on the take edge; push and pop never
// coincide, so no character is lost), so the bus paces the driver at line rate
// (the CPU waits up to one frame, ~87 us at 115200 baud). A word store that writes THR and the other lanes
// while full writes them once, when THR is taken. The Linux device tree gives
// tx-threshold so the driver writes one byte per THRE interrupt anyway.
//
// RTS# (a pinmux feature, the default pin map no longer carries it):
// registered !(MCR.RTS & !LOOP & rx_n <= 6): asserted while two or more
// entries are free (of 8), so a sender that checks CTS before each character
// (the demo board's RP2350) never overruns.
//
// Loopback (MCR.LOOP): the receiver's input is the internal TX serial value
// (SBC included, before the pin flop); the tx pin is held 1 and rts_n 1.
//
// Receive sampling: two-flop synchroniser, 16x oversampling on the same
// divisor as transmit, start bit re-checked at mid-bit (a shorter low pulse
// is ignored), every bit sampled once at its middle. A frame with a stop
// bit of 0 and a data bit of 1 is a framing error and is queued with err.
// A frame whose every bit reads 0 is a break, queued as {1, 0x00}. After a
// framing error the receiver goes back to looking for a start bit as soon
// as the line is high; if instead the line stays low for another whole
// frame, counted from the bad stop bit, that is a break which began inside
// the character, and it is queued as one. After a break the line must be
// high for half a bit before the next start bit counts, so a short high
// glitch inside a long break does not report a second one.
//
// Bus side effects (RBR pop, LSR read clears OE) happen only on a cycle with
// sel && ready, which is how soc_bus drives a transfer; the core holds the
// request for exactly one ready cycle.
//
// Reset: TX idle (1), RTS# deasserted (1) -- both registered, so the pins
// hold those values while rst is high and never glitch. FIFO storage has no
// reset (pointers and counts do); an empty FIFO reads 0.

module uart #(
    parameter [15:0] DIV_RESET = 16'd34,   // 114,890 baud at 62.5 MHz
    parameter        RX_AW     = 3         // RX FIFO 2^RX_AW entries (trigger table and RTS# assume 3)
)(
    input  wire        clk,
    input  wire        rst,
    // Bus: the core's request/ready handshake (soc_bus)
    input  wire        sel,        // request for this target
    input  wire        we,
    input  wire [3:0]  be,
    input  wire        addr2,      // dmem_addr[2]: 0 = offsets 0-3, 1 = offsets 4-7
    input  wire [31:0] wdata,
    output wire [31:0] rdata,
    output wire        ready,      // low only while a THR write waits on a full THR
    // Pins
    input  wire        rx,         // asynchronous
    output reg         tx,
    output reg         rts_n,
    output wire        irq         // level, = (IIR[0] == 0)
);
    localparam RX_N = 1 << RX_AW;

    // ── Registers ───────────────────────────────────────────────────────────
    reg        dlab;
    reg        sbc;                  // LCR bit 6: send break
    reg        erbfi, etbei, elsi, edssi;
    reg        fen;
    reg [1:0]  rtrig;
    reg [4:0]  mcr;
    reg [7:0]  scr;
    reg [7:0]  dll, dlm;
    reg        oe;

    // ── FIFOs ───────────────────────────────────────────────────────────────
    reg [7:0]       rx_mem [0:RX_N-1];   // data
    reg [RX_N-1:0]  rx_err;              // per-entry error flag (break/framing)
    reg [RX_AW-1:0] rx_wp, rx_rp;
    reg [RX_AW:0]   rx_n, err_n;
    reg [7:0]       thr_d;               // the TX holding register
    reg             thr_v;               // ... holds a character the shifter has not taken

    wire rx_full = (rx_n == RX_N);
    wire tx_full = thr_v;
    wire rx_emp  = (rx_n == 0);
    wire tx_emp  = !thr_v;

    // ── Transmitter ─────────────────────────────────────────────────────────
    // tx_sh holds the frame still to send, LSB first: {stop, data, start}
    // taken from the holding register, shifted right with 0 fill once per bit.
    // The stop bit is the last 1 in it, so the frame is done when the register
    // is all zeros: idle is tx_sh == 0 and needs no bit counter.
    //
    // The baud generator free-runs (it is shared with the receiver), so a
    // load lands anywhere inside a 16x tick. The pin therefore changes only
    // on ticks: the start bit begins at the first tick after the load and
    // every bit, the first included, is exactly 16 ticks long.
    reg [9:0]  tx_sh;
    reg [3:0]  tx_ph;               // 16x ticks into the current bit
    wire       tx_idle = (tx_sh == 10'd0);
    wire       tx_ser  = (tx_idle || tx_sh[0]) && !sbc;   // serial value before the pin flop

    // ── Bus decode ──────────────────────────────────────────────────────────
    wire thr_sel = sel && we && be[0] && !addr2 && !dlab;
    assign ready = !(thr_sel && tx_full);
    wire wr      = sel && we && ready;
    wire rd      = sel && !we && ready;
    wire wr_thr  = wr && be[0] && !addr2 && !dlab;
    wire wr_dll  = wr && be[0] && !addr2 &&  dlab;
    wire wr_ier  = wr && be[1] && !addr2 && !dlab;
    wire wr_dlm  = wr && be[1] && !addr2 &&  dlab;
    wire wr_fcr  = wr && be[2] && !addr2;
    wire wr_lcr  = wr && be[3] && !addr2;
    wire wr_mcr  = wr && be[0] &&  addr2;
    wire wr_scr  = wr && be[3] &&  addr2;
    wire rd_rbr  = rd && be[0] && !addr2 && !dlab;
    wire rd_lsr  = rd && be[1] &&  addr2;

    wire fcr_clr_rx = wr_fcr && (wdata[17] || (wdata[16] != fen));
    wire fcr_clr_tx = wr_fcr && (wdata[18] || (wdata[16] != fen));

    // ── Status and interrupt ────────────────────────────────────────────────
    wire [8:0] rx_head = rx_emp ? 9'd0 : {rx_err[rx_rp], rx_mem[rx_rp]};
    wire       h_err   = rx_head[8];
    // 16550A: an LSR read acknowledges the line-status condition (BI/FE and the RLS interrupt) of the head character;
    // the entry itself stays queued until the RBR pop; FIFOERR (LSR[7]) drops it from its count (PC16550D: cleared by an
    // LSR read when no later entry has an error).
    reg        err_ack;
    wire       h_err_u = h_err && !err_ack;
    wire       bi      = h_err_u && (rx_head[7:0] == 8'h00);
    wire       fe      = h_err_u && (rx_head[7:0] != 8'h00);
    wire       temt    = tx_emp && tx_idle;
    wire [7:0] lsr     = {fen && (err_n > err_ack), temt, tx_emp, bi, fe, 1'b0, oe, !rx_emp};

    wire [4:0] trig = !fen ? 5'd1 : (rtrig == 2'd0) ? 5'd1 : (rtrig == 2'd1) ? 5'd2 :
                                    (rtrig == 2'd2) ? 5'd4 : 5'd7;
    wire       i_rls  = elsi  && (oe || h_err_u);
    wire       i_rda  = erbfi && (rx_n >= trig);
    reg  [9:0] cti_cnt;
    wire       cti    = (cti_cnt == 10'd640);
    wire       i_cti  = erbfi && cti;
    wire       i_thre = etbei && tx_emp;
    wire [3:0] iid    = i_rls ? 4'h6 : i_rda ? 4'h4 : i_cti ? 4'hC : i_thre ? 4'h2 : 4'h1;
    assign irq = (iid != 4'h1);

    wire [7:0] msr = mcr[4] ? {mcr[3], mcr[2], mcr[0], mcr[1], 4'b0} : 8'hB0;
    wire [7:0] ier = {4'b0, edssi, elsi, etbei, erbfi};

    assign rdata = addr2 ? {scr, msr, lsr, 3'b0, mcr}
                         : {dlab, sbc, 6'b0, {fen, fen, 2'b00, iid}, dlab ? dlm : ier,
                            dlab ? dll : rx_head[7:0]};

    // ── Baud generator: one 16x tick every divisor clocks ───────────────────
    // A write to DLL or DLM restarts the count, as on a 16550 ("Upon loading
    // either of the Divisor Latches, a 16-bit baud counter is immediately
    // loaded"): brg goes to 0, so the next cycle ticks and reloads from the
    // new divisor.
    reg [15:0] brg;
    wire       tick = (brg[15:1] == 15'd0);   // brg is 1 (or 0, for divisor 0)

    always @(posedge clk) begin
        if (rst || wr_dll || wr_dlm) brg <= 16'd0;
        else                         brg <= tick ? {dlm, dll} : brg - 16'd1;
    end

    // ── Register writes ─────────────────────────────────────────────────────
    always @(posedge clk) begin
        if (rst) begin
            dlab  <= 1'b0;
            sbc   <= 1'b0;
            erbfi <= 1'b0;
            etbei <= 1'b0;
            elsi  <= 1'b0;
            edssi <= 1'b0;
            fen   <= 1'b0;
            rtrig <= 2'b00;
            mcr   <= 5'b00010;
            scr   <= 8'h00;
            dll   <= DIV_RESET[7:0];
            dlm   <= DIV_RESET[15:8];
        end else begin
            if (wr_lcr) begin
                dlab <= wdata[31];
                sbc  <= wdata[30];
            end
            if (wr_ier) begin
                erbfi <= wdata[8];
                etbei <= wdata[9];
                elsi  <= wdata[10];
                edssi <= wdata[11];
            end
            if (wr_fcr) begin
                fen   <= wdata[16];
                rtrig <= wdata[23:22];
            end
            if (wr_mcr) mcr <= wdata[4:0];
            if (wr_scr) scr <= wdata[31:24];
            if (wr_dll) dll <= wdata[7:0];
            if (wr_dlm) dlm <= wdata[15:8];
        end
    end

    // ── TX holding register and shifter ─────────────────────────────────────
    wire tx_pop  = tx_idle && thr_v && !fcr_clr_tx;
    wire tx_push = wr_thr && !fcr_clr_tx;      // wr_thr implies !thr_v (ready)

    always @(posedge clk) begin
        if (tx_push) thr_d <= wdata[7:0];
        if (rst) begin
            thr_v <= 1'b0;
            tx_sh <= 10'd0;
            tx_ph <= 4'd0;
            tx    <= 1'b1;
        end else begin
            if (fcr_clr_tx || tx_pop) thr_v <= 1'b0;
            else if (tx_push)         thr_v <= 1'b1;
            if (tx_pop) begin
                tx_sh <= {1'b1, thr_d, 1'b0};
                tx_ph <= 4'd0;
            end else if (tick && !tx_idle) begin
                tx_ph <= tx_ph + 4'd1;
                if (tx_ph == 4'd15)
                    tx_sh <= {1'b0, tx_sh[9:1]};
            end
            if (mcr[4])    tx <= 1'b1;            // loopback: the pin marks
            else if (tick) tx <= tx_ser;
        end
    end

    // ── Receive ─────────────────────────────────────────────────────────────
    // rx_bit: 0 start, 1-8 data, 9 stop, 10 after a break, waiting for half
    // a bit of high line (rx_ph counts its ticks). rx_chk: after a framing
    // error, bits 1-9 count one more frame of low line, the bad stop bit
    // standing in for its start bit; a high line ends it at once.
    reg [1:0]  rx_sync;
    wire       rx_s = rx_sync[1];
    reg        rx_busy;
    reg [3:0]  rx_bit;
    reg [3:0]  rx_ph;
    reg        rx_zero;             // every bit of the frame so far read 0
    reg        rx_chk;              // counting a framing error's low line
    reg [7:0]  rx_sh;               // receive shift register, LSB first
    wire       rx_in  = mcr[4] ? tx_ser : rx;
    wire       rx_mid = tick && (rx_ph == 4'd7);
    wire       rx_stop = rx_mid && rx_busy && rx_bit == 4'd9;
    // A frame to queue: a good stop bit, a break, or a framing error. While
    // rx_chk only a break counts (a high line has already ended it).
    wire       rx_good = rx_stop && rx_s && !rx_chk;
    wire       rx_brk  = rx_stop && !rx_s && rx_zero;
    wire       rx_fe   = rx_stop && !rx_s && !rx_zero;
    wire       rx_end  = rx_good || rx_brk || rx_fe;

    wire       rx_pop  = rd_rbr && !rx_emp;
    wire       rx_push = rx_end && !rx_full && !fcr_clr_rx;
    wire [8:0] rx_ent  = {rx_brk || rx_fe, rx_brk ? 8'h00 : rx_sh};
    wire       pop_err = rx_pop && h_err;

    always @(posedge clk) begin
        if (rx_push) begin
            rx_mem[rx_wp] <= rx_ent[7:0];
            rx_err[rx_wp] <= rx_ent[8];
        end
        if (rst) begin
            rx_sync <= 2'b11;
            rx_busy <= 1'b0;
            rx_bit  <= 4'd0;
            rx_ph   <= 4'd0;
            rx_zero <= 1'b0;
            rx_chk  <= 1'b0;
            oe      <= 1'b0;
            err_ack <= 1'b0;
            rts_n   <= 1'b1;
            rx_wp   <= {RX_AW{1'b0}};
            rx_rp   <= {RX_AW{1'b0}};
            rx_n    <= {(RX_AW+1){1'b0}};
            err_n   <= {(RX_AW+1){1'b0}};
            cti_cnt <= 10'd0;
        end else begin
            rx_sync <= {rx_sync[0], rx_in};

            if (!rx_busy) begin
                if (tick && !rx_s) begin               // start bit seen
                    rx_busy <= 1'b1;
                    rx_bit  <= 4'd0;
                    rx_ph   <= 4'd0;
                    rx_zero <= 1'b1;
                end
            end else if (rx_bit == 4'd10) begin        // after a break
                if (!rx_s)
                    rx_ph <= 4'd0;
                else if (tick) begin
                    rx_ph <= rx_ph + 4'd1;
                    if (rx_ph == 4'd7) rx_busy <= 1'b0;   // half a bit of high line
                end
            end else if (rx_chk && rx_s) begin
                rx_busy <= 1'b0;                       // not a break: line idle
                rx_chk  <= 1'b0;
            end else if (tick) begin
                rx_ph <= rx_ph + 4'd1;
                if (rx_ph == 4'd7) begin               // middle of the bit
                    rx_bit <= rx_bit + 4'd1;
                    if (rx_s) rx_zero <= 1'b0;
                    if (rx_bit == 4'd0 && rx_s)
                        rx_busy <= 1'b0;               // glitch, not a start bit
                    if (rx_bit == 4'd9) begin
                        if (rx_s)
                            rx_busy <= 1'b0;           // good stop bit
                        else if (rx_zero) begin        // break
                            rx_bit <= 4'd10;
                            rx_ph  <= 4'd0;
                            rx_chk <= 1'b0;
                        end else begin                 // framing error:
                            rx_bit  <= 4'd1;           //   count a frame of
                            rx_zero <= 1'b1;           //   low line from here
                            rx_chk  <= 1'b1;
                        end
                    end
                end
            end

            // OE: a frame to queue found the FIFO full (the FIFO is kept).
            if (rx_end && rx_full)
                oe <= 1'b1;
            else if (rd_lsr)
                oe <= 1'b0;

            // err_ack: set by an LSR read over an erroneous head, dropped with the pop (new head) or a clear
            if (rx_pop || fcr_clr_rx)
                err_ack <= 1'b0;
            else if (rd_lsr && h_err)
                err_ack <= 1'b1;

            // RX FIFO. A clear beats a push; a pop and a push together keep rx_n.
            if (fcr_clr_rx) begin
                rx_wp <= {RX_AW{1'b0}};
                rx_rp <= {RX_AW{1'b0}};
                rx_n  <= {(RX_AW+1){1'b0}};
                err_n <= {(RX_AW+1){1'b0}};
            end else begin
                if (rx_push) rx_wp <= rx_wp + 1'b1;
                if (rx_pop)  rx_rp <= rx_rp + 1'b1;
                rx_n  <= rx_n  + {{RX_AW{1'b0}}, rx_push} - {{RX_AW{1'b0}}, rx_pop};
                err_n <= err_n + {{RX_AW{1'b0}}, rx_push && rx_ent[8]} - {{RX_AW{1'b0}}, pop_err};
            end

            // Character timeout counter: holds at 640 until a restart.
            if (rx_push || rd_rbr || fcr_clr_rx || rx_emp)
                cti_cnt <= 10'd0;
            else if (tick && !cti)
                cti_cnt <= cti_cnt + 10'd1;

            // RTS#: two or more entries free, RTS set, not in loopback.
            rts_n <= !(mcr[1] && !mcr[4] && (rx_n <= 4'd6));
        end
    end

    always @(posedge clk) begin
        if (rst)
            rx_sh <= 8'h00;
        else if (rx_mid && rx_busy && rx_bit >= 4'd1 && rx_bit <= 4'd8)
            rx_sh <= {rx_s, rx_sh[7:1]};
    end

endmodule
