// UART -- a 16550-compatible subset at 0x1000_0000, for the Linux console.
//
// Byte-wide registers at consecutive offsets (reg-shift = 0, reg-io-width =
// 1), the layout Spike and QEMU's virt board put at the same address, so one
// kernel and a near-identical device tree run on all three:
//
//   offset  read (DLAB=0)       write (DLAB=0)   DLAB=1
//   0       RBR (pops)          THR              DLL
//   1       IER                 IER              DLM
//   2       IIR                 FCR (ignored)
//   3       LCR                 LCR              LCR
//   4       MCR (reads 0)       ignored
//   5       LSR                 ignored
//   6       MSR (0xB0)          ignored
//   7       SCR (reads 0)       ignored
//
// The core's data port is word-aligned with byte lanes (src/fyracore.v), so
// offset k is lane k[1:0] of word k[2]: `addr2` picks the word and `be` the
// registers in it. Each register sits on a fixed lane, so the write data
// needs no steering. The 8 bytes alias through the rest of the 64 KB window.
//
// Fixed 8N1. baud = clk / (16 x divisor). The divisor resets to DIV_RESET,
// non-zero, so a THR write can never stall forever before software sets it;
// the default, 27, is 115200 baud (+0.5%) at a 50 MHz core clock, so a
// program in flash can print before it programs the divisor. A divisor of 0
// counts as 1.
//
// What is kept of each register:
//   IER  bits 0 (ERBFI) and 1 (ETBEI); the rest read 0.
//   LCR  only DLAB (bit 7) and SBC (bit 6, break control) are stored; the
//        other bits read 0. The frame is fixed, and Linux keeps its own copy
//        of LCR, so it never reads the word-length bits back. (Its
//        read-modify-writes of LCR only clear bits.) While SBC is set, TX is
//        held at 0 from the next 16x tick, as a 16550 forces its serial
//        output to spacing (Linux's break_ctl, tcsendbreak); the transmitter
//        keeps shifting underneath, and the pin follows it again from the
//        first tick after SBC is cleared.
//   LSR  0 DR, 1 OE, 4 BI, 5 THRE, 6 TEMT. Reading LSR clears OE and BI.
//   IIR  0x04 when ERBFI && DR, else 0x02 when ETBEI && THRE, else 0x01.
//        No interrupt line leaves the UART (no PLIC), but Linux's 8250
//        driver polls by calling its interrupt handler from a timer, and the
//        handler reads IIR first and returns at once if bit 0 is set, so IIR
//        has to be right anyway.
//   MSR  0xB0: CTS, DSR and DCD always asserted.
//
// No FIFOs. The device tree says ns16550a (16-byte FIFO), so each poll the
// driver writes up to 16 bytes to THR back to back; instead of a FIFO:
//
// * Transmit back-pressure. A THR write while the transmitter is busy does
//   not complete: `ready` stays low until the frame in flight has gone,
//   and the write lands on the cycle it does. The bus paces the driver, so
//   a poll sends 16 characters, not one (a FIFO-less 16550 polled by Linux
//   moves one character per timer tick). There is no separate holding
//   register: the byte goes straight into the shift register, so THRE and
//   TEMT are the same bit. Every register write waits for `ready`, so the
//   other lanes of a stalled word store are written once, when it completes.
//
// * Receive flow control. RTS# (active low) is asserted only while the
//   receiver is idle and RBR is empty. A sender that checks CTS before each
//   character (the demo board's RP2350, with flow control on) therefore has
//   at most one character in flight, and nothing is lost: input runs at one
//   character per driver poll. The received byte is shifted straight into
//   RBR -- a frame only starts while RBR is empty, so there is nothing in it
//   to overwrite. A frame that starts while RBR is still full (a sender
//   ignoring CTS) is not shifted in; at its stop bit it sets OE and is
//   dropped, and RBR keeps the older byte. A frame whose stop bit reads 0
//   with a data bit of 1 (a framing error) is dropped and sets nothing. One
//   whose every bit, stop bit included, reads 0 is a break: it sets BI and,
//   as a 16550 loads one zero character, DR with RBR = 0 (or OE, if RBR was
//   full). Linux reads BI to count breaks and for the magic SysRq key.
//   After a framing error the receiver goes back to looking for a start bit
//   as soon as the line is high; if instead the line stays low for another
//   whole frame, counted from the bad stop bit, that is a break which began
//   inside the character, and it is reported as one. After a break the
//   line must be high for half a bit before the next start bit counts, as
//   on a 16550, so a short high glitch inside a long break does not report
//   a second one.
//
// Receive sampling: two-flop synchroniser, 16x oversampling on the same
// divisor as transmit, start bit re-checked at mid-bit (a shorter low pulse
// is ignored), every bit sampled once at its middle.
//
// Bus side effects happen only on the cycle a transfer completes (sel with
// ready): a load that selects offset 0 with DLAB=0 pops RBR (clears DR), a
// load that selects offset 5 clears OE. The core raises its request only
// for real loads, and holds it for exactly one ready cycle.
//
// Reset: TX idle (1), RTS# deasserted (1) -- both registered, so the pins
// hold those values while rst is high and never glitch. RBR resets to 0.

module uart #(
    parameter [15:0] DIV_RESET = 16'd27    // 115200 baud at 50 MHz
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
    output wire        ready,      // low only while a THR write waits
    // Pins
    input  wire        rx,         // asynchronous
    output reg         tx,
    output reg         rts_n
);

    // ── Registers ───────────────────────────────────────────────────────────
    reg        dlab;
    reg        sbc;                  // LCR bit 6: send break
    reg        erbfi, etbei;
    reg [7:0]  dll, dlm;
    reg [7:0]  rbr;
    reg        dr, oe, bi;

    // ── Transmitter ─────────────────────────────────────────────────────────
    // tx_sh holds the frame still to send, LSB first: {stop, data, start} on
    // a THR write, shifted right with 0 fill once per bit. The stop bit is
    // the last 1 in it, so the frame is done when the register is all zeros:
    // idle is tx_sh == 0 and needs no bit counter.
    //
    // The baud generator free-runs (it is shared with the receiver), so a
    // THR write lands anywhere inside a 16x tick. The pin therefore changes
    // only on ticks: the start bit begins at the first tick after the write
    // and every bit, the first included, is exactly 16 ticks long. (Driving
    // the pin straight from tx_sh made the first start bit up to one divisor
    // period short.) The pin lags tx_sh by up to one tick, so THRE/TEMT rise
    // up to 1/16 bit before the stop bit ends; a write in that window still
    // starts its start bit after a full stop bit.
    reg [9:0]  tx_sh;
    reg [3:0]  tx_ph;               // 16x ticks into the current bit
    wire       tx_idle = (tx_sh == 10'd0);

    // ── Bus decode ──────────────────────────────────────────────────────────
    wire thr_sel = sel && we && be[0] && !addr2 && !dlab;
    assign ready = !(thr_sel && !tx_idle);
    wire wr      = sel && we && ready;
    wire rd      = sel && !we;      // reads always complete at once
    wire wr_thr  = wr && be[0] && !addr2 && !dlab;
    wire wr_dll  = wr && be[0] && !addr2 &&  dlab;
    wire wr_ier  = wr && be[1] && !addr2 && !dlab;
    wire wr_dlm  = wr && be[1] && !addr2 &&  dlab;
    wire wr_lcr  = wr && be[3] && !addr2;
    wire rd_rbr  = rd && be[0] && !addr2 && !dlab;
    wire rd_lsr  = rd && be[1] &&  addr2;

    wire [7:0] lsr = {1'b0, tx_idle, tx_idle, bi, 2'b00, oe, dr};
    wire [7:0] iir = (erbfi && dr)      ? 8'h04 :
                     (etbei && tx_idle) ? 8'h02 : 8'h01;
    wire [7:0] ier = {6'b0, etbei, erbfi};

    assign rdata = addr2 ? {8'h00, 8'hB0, lsr, 8'h00}
                         : {dlab, sbc, 6'b0, iir, dlab ? dlm : ier, dlab ? dll : rbr};

    // ── Baud generator: one 16x tick every divisor clocks ───────────────────
    // A write to DLL or DLM restarts the count, as on a 16550 ("Upon loading
    // either of the Divisor Latches, a 16-bit baud counter is immediately
    // loaded. This prevents long counts on initial load."): brg goes to 0,
    // so the next cycle ticks and reloads from the new divisor. Otherwise a
    // switch from a slow rate to a fast one keeps the old period for up to
    // 65,536 clocks, and a character sent at the new rate meanwhile is lost.
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
            end
            if (wr_dll) dll <= wdata[7:0];
            if (wr_dlm) dlm <= wdata[15:8];
        end
    end

    // ── Transmit ────────────────────────────────────────────────────────────
    always @(posedge clk) begin
        if (rst) begin
            tx_sh <= 10'd0;
            tx_ph <= 4'd0;
            tx    <= 1'b1;
        end else begin
            if (wr_thr) begin
                tx_sh <= {1'b1, wdata[7:0], 1'b0};
                tx_ph <= 4'd0;
            end else if (tick && !tx_idle) begin
                tx_ph <= tx_ph + 4'd1;
                if (tx_ph == 4'd15)
                    tx_sh <= {1'b0, tx_sh[9:1]};
            end
            if (tick)
                tx <= (tx_idle || tx_sh[0]) && !sbc;
        end
    end

    // ── Receive ─────────────────────────────────────────────────────────────
    // rx_bit: 0 start, 1-8 data, 9 stop, 10 after a break, waiting for half
    // a bit of high line (rx_ph counts its ticks). rx_keep: RBR was empty
    // when the frame started, so its bits go into RBR. rx_chk: after a
    // framing error, bits 1-9 count one more frame of low line, the bad stop
    // bit standing in for its start bit; a high line ends it at once.
    reg [1:0]  rx_sync;
    wire       rx_s = rx_sync[1];
    reg        rx_busy;
    reg [3:0]  rx_bit;
    reg [3:0]  rx_ph;
    reg        rx_keep;
    reg        rx_zero;             // every bit of the frame so far read 0
    reg        rx_chk;              // counting a framing error's low line
    wire       rx_mid = tick && (rx_ph == 4'd7);
    // The stop bit's sample: a frame to keep or drop (a good stop bit, or a
    // break), and whether it is a break. While rx_chk, only a break counts.
    wire       rx_end = rx_mid && rx_busy && rx_bit == 4'd9 && (rx_s ? !rx_chk : rx_zero);
    wire       rx_brk = rx_end && !rx_s;

    always @(posedge clk) begin
        if (rst) begin
            rx_sync <= 2'b11;
            rx_busy <= 1'b0;
            rx_bit  <= 4'd0;
            rx_ph   <= 4'd0;
            rx_keep <= 1'b0;
            rx_zero <= 1'b0;
            rx_chk  <= 1'b0;
            dr      <= 1'b0;
            oe      <= 1'b0;
            bi      <= 1'b0;
            rts_n   <= 1'b1;
        end else begin
            rx_sync <= {rx_sync[0], rx};

            if (!rx_busy) begin
                if (tick && !rx_s) begin               // start bit seen
                    rx_busy <= 1'b1;
                    rx_bit  <= 4'd0;
                    rx_ph   <= 4'd0;
                    rx_keep <= !dr;
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

            // DR: set by a good frame or a break that was kept, cleared by an
            // RBR pop. A kept frame only starts while DR is 0, so the two
            // never meet.
            if (rx_end && rx_keep)
                dr <= 1'b1;
            else if (rd_rbr)
                dr <= 1'b0;

            if (rx_end && !rx_keep)
                oe <= 1'b1;
            else if (rd_lsr)
                oe <= 1'b0;

            if (rx_brk)
                bi <= 1'b1;
            else if (rd_lsr)
                bi <= 1'b0;

            rts_n <= !(!rx_busy && !dr);
        end
    end

    // RBR is the receive shift register: data bits arrive LSB first and
    // shift in at the top. It resets to 0: Linux's startup reads RX before
    // any byte has arrived (serial8250_clear_interrupts), and an unreset
    // register would carry X into an X-accurate simulation from there.
    always @(posedge clk) begin
        if (rst)
            rbr <= 8'h00;
        else if (rx_mid && rx_busy && rx_keep && rx_bit >= 4'd1 && rx_bit <= 4'd8)
            rbr <= {rx_s, rbr[7:1]};
    end

endmodule
