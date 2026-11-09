// Behavioural model of the TinyTapeout QSPI Pmod: a W25Q128JV flash on CS0
// and two 8 MB PSRAMs on CS1 (A) and CS2 (B), sharing one quad bus.
//
// It implements the commands src/qspi_ctrl.v issues, and stops the run on
// anything else, so a protocol mistake in the controller cannot pass
// silently. SPI form = the 8-bit command on IO0; QPI form = the command as
// two nibbles on IO[3:0]. Address and data are always on IO[3:0].
//
//   flash, SPI mode:
//     0xEB  quad I/O read  6 address nibbles, 6 dummy cycles, data. The first
//                          two dummy cycles are the mode byte M7-0, whose
//                          bits M5-4 must not be 10 (that would put a real
//                          W25Q into continuous-read mode; the other bits are
//                          don't-care, so 0x20 enters it as surely as 0xA0).
//     0xFF                 continuous-read mode reset / Exit QPI (ignored).
//   PSRAM, SPI mode:
//     0xEB  quad read      6 address nibbles, 6 wait cycles, data.
//     0x38  quad write     6 address nibbles, data.
//     0x66, 0x99           reset enable / reset (back to SPI mode).
//     0x35                 Enter Quad (QPI) mode.
//   The PSRAM needs a user-issued reset to finish initialising after power-up
//   (APS6404L datasheet section 7), and 99h resets only when it immediately
//   follows 66h (section 12). So every PSRAM starts out waiting for that reset:
//   until 66h then 99h reach it, anything but 66h, 99h and Exit QPI stops the
//   run. The model insists on it whatever state the chip is handed over in,
//   since the controller cannot know that state.
//   PSRAM, QPI mode (all QPI form):
//     0x0B  fast read      6 address nibbles, 4 wait cycles, data.
//     0x38, 0x02  write    6 address nibbles, data.
//     0x66, 0x99           reset enable / reset (back to SPI mode).
//     0xF5                 Exit Quad mode.
//   Both PSRAMs may be selected together for 0x35, 0x66, 0x99 and 0xF5.
//   0x38 is never accepted by the flash: on the W25Q128JV-DTR it is Enter QPI.
//
// Start-up state. The Pmod is shared between designs and not power cycled,
// so it can be handed over in a state the controller does not speak. These
// plusargs start the model in such a state, to check that qspi_ctrl's
// start-up sequence gets it out:
//
//   +PSRAM_QPI=1   both PSRAMs in QPI mode (commands in QPI form only).
//   +FLASH_CRM=1   flash in quad continuous-read mode (EBh with M5-4 = 10): each
//                  chip select window is a quad I/O read without its command --
//                  6 address clocks, the mode byte on clocks 7-8, then 4 dummy
//                  clocks (none in QPI mode, where the mode clocks are the
//                  dummies) -- after which it drives data. Mode bits other than
//                  10 end the mode; undriven ones fail.
//   +FLASH_QPI=1   flash in QPI mode (W25Q128JV-DTR): leaves it on 0xFF in QPI
//                  form, and only when chip select rises straight after those
//                  two clocks. The datasheet draws Exit QPI exactly so (figure
//                  52) and does not say whether more clocks cancel it, so the
//                  model takes the pessimistic reading.
//   +FLASH_DCRM=1  flash in dual I/O continuous-read mode (BBh with mode bits
//                  M5-4 = 10, W25Q128JV-DTR 8.2.11): it takes the first 12
//                  clocks as an address on IO1:0 and the next 4 as mode bits,
//                  then drives dual data. A window that ends before the mode
//                  bits leaves the mode set; mode bits other than 10 end it.
//   In either continuous-read mode, a chip select still low when the flash
//   starts driving data stops the run, and so does one that rises on the very
//   falling SCK edge that starts it: the host's pads and the flash's would
//   overlap for a moment. End such a window with SCK high.
//   +PSRAM_A_QPI=1, +PSRAM_B_QPI=1
//                  only that PSRAM in QPI mode, as a design that used one chip
//                  leaves them. A broadcast then reaches the two chips in
//                  different forms, and each decodes it as its own mode does.
//   Any other traffic to a device in one of these states stops the run.
//
// Also checked: at most one chip selected (bar the PSRAM broadcast above),
// the host driving IO through the command and address phases, the host and
// a device never driving IO at the same time, the PSRAM's maximum
// chip-select-low time (tCEM), every chip's minimum deselect time (tCPH), the
// PSRAM's reset time (tRST: 50 ns from the end of 99h to its next command),
// and SCK against the command in progress: the period (PSRAM 15.1 ns for QPI
// 0Bh, 7.5 ns otherwise; flash 7.5 ns) and the high and low times (45% of
// that minimum period). APS6404L table 10; W25Q128JV-DTR AC characteristics.
//
// Pins. The model takes the host's pins with their output enable
// (host_ctl_oe for SCK and the chip selects) and applies what the Pmod does
// to a released pin: the chip selects are pulled up (10k on the Pmod), SCK
// is not and floats -- X here. A chip select may only fall once SCK has
// been driven low for TSCK_CS_NS (mode 0; the flash's /CS setup times are
// 3 ns), so a host that selects a chip on the same edge it starts driving
// SCK -- a clock edge of unknown level -- stops the run. Testbenches connect
// the raw pins and leave this to the model.
//
// +PSRAM_WRAP=1 makes the PSRAMs wrap a read or write at the end of each 1 KB
// page, as a part without row-boundary crossing does (the -3SQN rather than
// the -3SQR). qspi_ctrl must not depend on crossing.
//
// Data goes out on each falling SCK edge after +QSPI_DELAY ns (default 2),
// which stands in for the device's clock-to-output time plus both pad delays
// (tACLK, tCLQV). The nibble it replaces stays on the pins for +QSPI_HOLD ns
// (default 1, at most QSPI_DELAY), the device's output hold time (tKOH,
// tCLQX) plus the pads' minimum delays, and the pins read X in between. So a
// host that samples outside [hold, delay) after the next falling edge reads
// X. With rd_late = 1 the engine samples one clock after that edge, so its
// runs need a hold of more than one clock: the strap's premise is a round
// trip that long.
// The device lets go of the bus TCHZ_NS after chip select rises, not after
// that whole round trip: contention happens at the pins, and the host's next
// drive and the chip select both reach them through the same output pads.
//
// Setup / hold (datasheet numbers, docs/qspi-memories.md, AC tables). On every
// SCK rise the model checks that each IO line it samples held its value for the
// setup time, and that the line then keeps it for the hold time; and that a chip
// select falls tCSP / tSLCH before the first rise and rises tCHD / tCHSH after
// the last. W25Q128JV: tDVCH 1, tCHDX 2, tSLCH 3, tCHSH 3 ns; APS6404L: tSP 2,
// tHD 2, tCSP 2.5, tCHD 3 ns (the PSRAM numbers apply to a broadcast). The
// times are measured on the pins ($realtime), so a data change on the very
// edge the chip samples reads 0 ns -- the LISA item 34 bug class, which a
// zero-delay run shows as long as nothing orders the two events: a change in
// the time step of the rise, before or after it, is a setup violation. Lines
// are sampled in the command (IO0, or IO[3:0] in QPI form), address, flash mode,
// dual-mode and write-data phases; not in dummy clocks or read data. Each
// device's smallest margins print at the end of the run, with the sample count
// (+QSPI_TCHECK=0 turns the checks off, for diagnosis only).
// Per-edge checks: samp_mask (rise) and samp_mask_fall say which lines an SCK
// edge samples in a phase; r_su / r_h / r_css / r_csh (and TDVCL_NS / TCLDX_NS
// for a fall) give the limits. The hold bookkeeping remembers which edge armed
// it (hold_lim, hold_fall), so a release of the IO lines is checked against that
// edge's limit.
//
// DTR read, flash EDh (W25Q128JV-DTR 8.2.14 Figure 27a, 9.6), SPI mode only (an
// EDh to a flash in QPI mode stops the run like any non-Exit-QPI command):
//   * the command on IO0 on rises 0-7 (falls 0-7 sample nothing, fall 7 is
//     not an address edge); then one nibble per SCK edge, rise then fall, 8
//     nibbles: A23-20 ... A3-0, M7-4, M3-0 (rises 8-11, falls 8-11);
//   * the host releases IO after fall 11 (hold-checked against TCLDX_NS);
//   * +DTR_DUMMY=<n> dummy cycles after fall 11 (default 7, Figure 27a; the
//     text says 4);
//   * data: the first nibble leaves on the falling edge of the last dummy
//     cycle (+DTR_LAUNCH=0, default, Figure 27a) or the rise after it
//     (+DTR_LAUNCH=1); then one nibble per edge, high nibble first, for as
//     long as CS0 is low. The launch machinery is the SDR one (delay, hold, X
//     between nibbles, transport: an eye shorter than QSPI_DELAY-QSPI_HOLD
//     closes).
//   * +QSPI_EYE_RANDOM: the closed-eye window between nibbles carries random
//     bits instead of X, as a real pin would. For gate-level and SDF runs that
//     deliberately sample outside the eye (the DDR capture sweep): there an X
//     spreads through the netlist's gates into the pc, while at RTL it only
//     takes the not-taken arm. RTL runs keep the default X, the stricter check.
// Assumed limits (the datasheet has no falling-edge row): TDVCL_NS 1.0 and
// TCLDX_NS 2.0, the rising-edge numbers. EDh needs a period of at least
// TCLK_DTR_NS (15.15, 66 MHz) from rise 8 on. An open with A1:A0 != 00 stops
// the run (the controller always opens aligned; +QSPI_DTR_UNALIGNED_OK allows
// it). Mode bits M5-4 = 10 (DTR continuous-read mode), undriven or X mode bits
// and a host not driving the address stop the run. DTR continuous-read mode
// itself is not modelled.
// Pauses: SCK may stop at either level, for any length, in a read's data
// phase; nothing on the pins changes, so the last launched nibble stays (with
// DTR_LAUNCH=0 that is the first nibble of the next byte). A resume is an SCK
// edge more than 1.5 times the shortest edge spacing seen so far in the select
// after the edge before it; n_resume counts them for EBh and EDh. n_eb (n_ebh),
// n_edh, n_resume and n_bytes are readable by benches, and print at the end as
// "flash reads: ...". The DTR margins print on a line of their own once an EDh
// was seen.
//
// Host-side pin delays: +QSPI_SCK_DLY_PS, +QSPI_IO_DLY_PS (IO data and its
// output enable) and +QSPI_CS_DLY_PS (chip selects) delay the host's pins on
// their way to the model (default 0), so SCK-versus-IO skew is visible. They
// are transport delays (nonblocking assignment with a delay): a pulse shorter
// than the delay still gets through, which `assign #` would swallow. The model
// decodes, checks and launches from the delayed pins, which are what the flash
// sees; what it drives back is not delayed, so the host sees a round trip of
// its SCK delay plus QSPI_DELAY.

// Memory: ram[] is the two PSRAMs back to back (A at 0, B at 8 MB).
// flash[] is the whole 16 MB flash. Neither array is zero-filled -- that loop
// would add about 6 s to every run -- so a byte never loaded is X in the array
// and reads 0 (flash_rd, ram_rd), the same as Spike's zero-filled RAM model of
// the flash window. ram_w[] marks the bytes a PSRAM write stored, so an X the
// DUT drove on the data pins stays X on read-back instead of passing as 0; a
// byte loaded by hierarchical reference or $readmemh reads as loaded (a loaded
// X reads 0).
// Load flash by hierarchical reference or with +FLASH_FILE=, a path of up to
// 1023 characters; a longer one, or a file that cannot be opened, stops the run.

`timescale 1ns / 1ps

module qspi_pmod_model #(
    parameter FLASH_SIZE = 16777216,
    parameter RAM_SIZE   = 16777216,
    parameter TCEM_NS    = 8000,       // PSRAM maximum CS-low time
    parameter TCPH_NS    = 18,         // minimum deselect time
    parameter TCHZ_NS    = 7,          // chip select high to output released
    parameter TSCK_CS_NS = 3,          // SCK driven low before chip select falls
    parameter TRST_NS    = 50,         // PSRAM: end of 99h to the next command
    parameter real TCLK_0B_NS = 15.1,  // PSRAM QPI 0Bh minimum SCK period (66 MHz)
    parameter real TCLK_NS    = 7.5,   // every other command, both devices (133 MHz)
    parameter real TDVCH_NS   = 1.0,   // flash data-in setup before SCK rise
    parameter real TCHDX_NS   = 2.0,   // flash data-in hold after SCK rise
    parameter real TSLCH_NS   = 3.0,   // flash CS active setup to the first SCK rise
    parameter real TCHSH_NS   = 3.0,   // flash CS active hold after the last SCK rise
    parameter real TDVCL_NS   = 1.0,   // flash DTR data-in setup before SCK fall (assumed)
    parameter real TCLDX_NS   = 2.0,   // flash DTR data-in hold after SCK fall (assumed)
    parameter real TCLK_DTR_NS = 15.15, // flash EDh minimum SCK period from the address on (66 MHz)
    parameter real TSP_NS     = 2.0,   // PSRAM input setup (tSP)
    parameter real THD_NS     = 2.0,   // PSRAM input hold (tHD)
    parameter real TCSP_NS    = 2.5,   // PSRAM CE# setup to the first SCK rise
    parameter real TCHD_NS    = 3.0    // PSRAM CE# hold after the last SCK rise
)(
    input  wire       host_sck,
    input  wire [2:0] host_cs_n,
    input  wire       host_ctl_oe,  // host drives SCK and the chip selects
    input  wire [3:0] host_io,
    input  wire       host_oe,
    output reg  [3:0] dev_io,
    output reg        dev_oe
);
    // Host-side pin delays (see "Host-side pin delays" in the header): what the
    // flash pins see is the host's pins a fixed time later. Transport delays
    // (a nonblocking assignment with a delay), never `assign #`, which is
    // inertial and swallows pulses shorter than the delay. A zero delay uses
    // the undelayed wire: `<= #0` would move the update into the NBA region.
    real    sck_dly, io_dly, cs_dly;   // ns
    integer dly_ps;
    initial begin
        sck_dly = 0.0; io_dly = 0.0; cs_dly = 0.0;
        if ($value$plusargs("QSPI_SCK_DLY_PS=%d", dly_ps)) sck_dly = dly_ps / 1000.0;
        if ($value$plusargs("QSPI_IO_DLY_PS=%d",  dly_ps)) io_dly  = dly_ps / 1000.0;
        if ($value$plusargs("QSPI_CS_DLY_PS=%d",  dly_ps)) cs_dly  = dly_ps / 1000.0;
    end
    reg       sck_d = 1'bx, coe_sd = 1'b0, coe_cd = 1'b0, oe_d = 1'b0;
    reg [2:0] cs_d  = 3'b111;
    reg [3:0] io_d  = 4'b0000;
    // A pin that never changes would never be copied: start from the host's values.
    initial if (sck_dly != 0.0 || io_dly != 0.0 || cs_dly != 0.0) begin
        #0.001;
        sck_d = host_sck; coe_sd = host_ctl_oe; coe_cd = host_ctl_oe;
        cs_d = host_cs_n; io_d = host_io; oe_d = host_oe;
    end
    always @(host_sck)    sck_d  <= #(sck_dly) host_sck;
    always @(host_ctl_oe) coe_sd <= #(sck_dly) host_ctl_oe;
    always @(host_ctl_oe) coe_cd <= #(cs_dly)  host_ctl_oe;
    always @(host_cs_n)   cs_d   <= #(cs_dly)  host_cs_n;
    always @(host_io)     io_d   <= #(io_dly)  host_io;
    always @(host_oe)     oe_d   <= #(io_dly)  host_oe;
    wire       h_sck   = (sck_dly == 0.0) ? host_sck    : sck_d;
    wire       h_coe_s = (sck_dly == 0.0) ? host_ctl_oe : coe_sd;
    wire       h_coe_c = (cs_dly  == 0.0) ? host_ctl_oe : coe_cd;
    wire [2:0] h_cs    = (cs_dly  == 0.0) ? host_cs_n   : cs_d;
    wire [3:0] h_io    = (io_dly  == 0.0) ? host_io     : io_d;
    wire       h_oe    = (io_dly  == 0.0) ? host_oe     : oe_d;
    // The pins as the devices see them (see Pins above).
    wire [2:0] cs_n = h_coe_c ? h_cs : 3'b111;
    wire       sck  = h_coe_s ? h_sck : 1'bx;

    reg [7:0] flash [0:FLASH_SIZE-1];
    reg [7:0] ram   [0:RAM_SIZE-1];
    reg [31:0] ram_w [0:RAM_SIZE/32-1];   // bit set: a PSRAM write stored ram[] byte

    localparam [3:0] P_IDLE = 0, P_CMD = 1, P_ADDR = 2, P_DUMMY = 3, P_RDATA = 4,
                     P_WDATA = 5, P_IGNORE = 6, P_MODE = 7,
                     P_DCRM = 8,    // flash in dual continuous-read: address + mode
                     P_DDATA = 9,   // flash in continuous read: its data is next
                     P_DTR_AD = 10, // flash EDh: address and mode nibbles, both edges
                     P_DTR_DUM = 11; // flash EDh: dummy cycles

    reg  [3:0]  phase;
    integer delay_ns;
    // 1024 characters, as tb_rivercore's INIT_FILE: $value$plusargs cuts a
    // longer path short without a word, and $readmemh of the stub only warns.
    reg [8191:0] flash_file;
    integer      flash_fd;
    reg     psram_wrap, flash_crm, flash_qpi, flash_dcrm;
    integer hold_ns;
    integer dtr_dummy, dtr_launch;   // EDh: dummy cycles; first nibble on fall (0) or the next rise (1)
    reg     dtr_unal_ok;
    reg     eye_rand;      // +QSPI_EYE_RANDOM
    // Per PSRAM, bit 0 = A (CS1), bit 1 = B (CS2).
    reg [1:0] psram_qpi;    // in QPI mode
    reg [1:0] psram_rst;    // reset since power-up: reads, writes and 35h allowed
    reg [1:0] psram_rsten;  // the last command was Reset Enable (66h)
    reg [1:0] rsten_q;      // psram_rsten as it was when this transaction began
    initial begin
        delay_ns = 2;
        if ($value$plusargs("QSPI_DELAY=%d", delay_ns)) ;
        hold_ns = 1;
        if ($value$plusargs("QSPI_HOLD=%d", hold_ns)) ;
        if (hold_ns > delay_ns) hold_ns = delay_ns;
        dtr_dummy = 7;
        if ($value$plusargs("DTR_DUMMY=%d", dtr_dummy)) ;
        if (dtr_dummy < 1) dtr_dummy = 1;
        dtr_launch = 0;
        if ($value$plusargs("DTR_LAUNCH=%d", dtr_launch)) ;
        dtr_unal_ok = $test$plusargs("QSPI_DTR_UNALIGNED_OK");
        eye_rand    = $test$plusargs("QSPI_EYE_RANDOM");
        psram_wrap = $test$plusargs("PSRAM_WRAP");
        psram_qpi  = {$test$plusargs("PSRAM_QPI") || $test$plusargs("PSRAM_B_QPI"),
                      $test$plusargs("PSRAM_QPI") || $test$plusargs("PSRAM_A_QPI")};
        psram_rst  = 2'b00;
        psram_rsten = 2'b00;
        flash_crm  = $test$plusargs("FLASH_CRM");
        flash_qpi  = $test$plusargs("FLASH_QPI");
        flash_dcrm = $test$plusargs("FLASH_DCRM");
        if ($value$plusargs("FLASH_FILE=%s", flash_file)) begin
            // A path that fills the buffer may have been cut short.
            if (flash_file[8191:8184] != 8'h00) begin
                $display("ERROR: qspi_pmod_model: FLASH_FILE path longer than 1023 characters");
                $fatal(1);
            end
            flash_fd = $fopen(flash_file, "r");
            if (flash_fd == 0) begin
                $display("ERROR: qspi_pmod_model: cannot open FLASH_FILE=%0s", flash_file);
                $fatal(1);
            end
            $fclose(flash_fd);
            $readmemh(flash_file, flash);
        end
        dev_io = 4'b0000;
        dev_oe = 1'b0;
        phase  = P_IDLE;
    end

    reg  [4:0]  n;          // bits / nibbles / cycles seen in the phase
    reg  [7:0]  cmd;
    reg  [23:0] addr;
    reg  [7:0]  mode;
    reg  [7:0]  wbyte;
    reg         hi;         // next data nibble is the high half of a byte
    reg  [1:0]  chip;       // 0 flash, 1 PSRAM A, 2 PSRAM B
    reg         both;       // both PSRAMs selected (reset broadcast)
    reg         qpi_exit;   // flash: Exit QPI received, pending chip select rising
    reg         first_nib;  // the next nibble out is the first of the read
    reg  [3:0]  wait_n;     // dummy / wait cycles before read data
    reg         mixed;      // broadcast to PSRAMs in different modes
    reg  [1:0]  qpi_sel;    // psram_qpi when this transaction began
    reg  [7:0]  cmd_q;      // mixed broadcast: the QPI chip's command
    reg  [1:0]  rst_now;    // PSRAMs reset in this transaction
    integer     sel_gen;    // counts deselects: cancels a pending output enable
    integer     launch;     // counts read nibbles launched (see below)
    integer     x_from;     // the launch whose X is on the pins
    integer     nib_k;      // the launch being scheduled, and its nibble
    reg  [3:0]  nib_v;
    realtime    t_sel, t_desel, t_sck, t_rise, t_fall;
    realtime    t_rst [0:1];
    initial begin
        t_desel  = -1000.0;
        t_rst[0] = -1000.0;
        t_rst[1] = -1000.0;
        sel_gen  = 0;
        launch   = 0;
    end

    // SCK driven low before a chip select falls (see Pins above). Checked
    // 1 ps after the select, once every update of that time step has landed:
    // SCK and the chip selects change on the same clock edge, and the order
    // the simulator runs their blocks in is not defined.
    event selected;
    always @(sck) t_sck = $realtime;
    always @(selected) begin
        #0.001;
        if (sck !== 1'b0 || (t_sel - t_sck) < TSCK_CS_NS)
            fail("chip select fell before SCK was driven low");
    end

    wire any_sel = (cs_n != 3'b111);

    function [1:0] which(input [2:0] c);
        which = !c[0] ? 2'd0 : !c[1] ? 2'd1 : 2'd2;
    endfunction

    function [23:0] ram_index(input [1:0] c, input [23:0] a);
        ram_index = {c == 2'd2, a[22:0]};
    endfunction

    // A flash byte as the chip returns it: 0 where nothing was loaded.
    function [7:0] flash_rd(input [23:0] a);
        flash_rd = (a >= FLASH_SIZE || ^flash[a] === 1'bx) ? 8'h00 : flash[a];
    endfunction

    // A RAM byte as the chip returns it: as written by the DUT (X included),
    // else 0 where nothing was loaded.
    function [7:0] ram_rd(input [23:0] i);
        ram_rd = ram_w[i >> 5][i[4:0]] === 1'b1 ? ram[i] :
                 (^ram[i] === 1'bx) ? 8'h00 : ram[i];
    endfunction

    function [7:0] rd(input [1:0] c, input [23:0] a);
        if (c == 2'd0) rd = flash_rd(a);
        else           rd = ram_rd(ram_index(c, a));
    endfunction

    // Next byte address: the PSRAMs wrap at a 1 KB page in wrap mode.
    function [23:0] next_addr(input [1:0] c, input [23:0] a);
        next_addr = (c != 2'd0 && psram_wrap) ? {a[23:10], a[9:0] + 10'd1} : a + 24'd1;
    endfunction

    task fail(input [8*128-1:0] msg);
        begin
            $display("ERROR: qspi_pmod_model: %0s (cs_n=%b cmd=%02h addr=%06h t=%0t)",
                     msg, cs_n, cmd, addr, $time);
            $fatal(1);
        end
    endtask

    // The PSRAMs selected, as a psram_* mask.
    wire [1:0] psel = both ? 2'b11 : (chip == 2'd1) ? 2'b01 : (chip == 2'd2) ? 2'b10 : 2'b00;

    // Is the selected device in a state where it only reads nibbles? (A
    // broadcast to PSRAMs in different modes is decoded per chip: `mixed`.)
    wire in_qpi = (chip == 2'd0) ? flash_qpi : |(psram_qpi & psel);

    // A PSRAM command other than 66h, 99h and Exit QPI: the chip must have
    // had its power-up reset.
    task need_reset(input [1:0] m);
        if ((psram_rst & m) != m)
            fail("PSRAM command before its power-up reset (66h, 99h)");
    endtask

    // 66h: reset enable, for the next command only. 99h right after it:
    // reset, which also returns the chip to SPI mode. A 99h not preceded by
    // 66h is ignored, as on the chip.
    task psram_reset_cmd(input [7:0] c, input [1:0] m);
        if (c == 8'h66)
            psram_rsten = psram_rsten | m;
        else begin
            psram_qpi = psram_qpi & ~(rsten_q & m);
            psram_rst = psram_rst |  (rsten_q & m);
            rst_now   = rst_now   |  (rsten_q & m);
        end
    endtask

    // A command broadcast to both PSRAMs, as the chips in mask m decode it:
    // Exit QPI (a QPI-form command), reset enable, reset, Enter QPI (an
    // SPI-form command). Anything else would make both drive the bus.
    task broadcast_cmd(input [7:0] c, input [1:0] m, input qpi);
        if (qpi && c == 8'hF5)
            psram_qpi = psram_qpi & ~m;
        else if (c == 8'h66 || c == 8'h99)
            psram_reset_cmd(c, m);
        else if (!qpi && c == 8'h35) begin
            need_reset(m);
            psram_qpi = psram_qpi | m;
        end else
            fail("both PSRAMs selected for a read or write");
    endtask

    // Minimum SCK period for the command in progress (see the header).
    function real tclk_min;
        tclk_min = (chip != 2'd0 && cmd == 8'h0B && phase != P_CMD) ? TCLK_0B_NS :
                   (chip == 2'd0 && cmd == 8'hED && phase != P_CMD) ? TCLK_DTR_NS : TCLK_NS;
    endfunction

    // Select / deselect
    always @(cs_n) begin
        if (cs_n != 3'b111 && cs_n != 3'b110 && cs_n != 3'b101 && cs_n != 3'b011 &&
            cs_n != 3'b001)
            fail("chip selects in an impossible combination");
        if (any_sel && phase == P_IDLE) begin
            if (($realtime - t_desel) < TCPH_NS)
                fail("chip select high for less than tCPH");
            -> selected;
            phase   = P_CMD;
            n       = 0;
            cmd     = 8'h00;
            chip    = which(cs_n);
            both    = (cs_n == 3'b001);
            qpi_exit = 1'b0;
            t_sel   = $realtime;
            t_edge  = -1.0;
            min_sp  = 1.0e9;
            t_rise  = -1.0;
            t_fall  = -1.0;
            qpi_sel = psram_qpi;
            mixed   = both && psram_qpi[0] != psram_qpi[1];
            rst_now = 2'b00;
            if ((!cs_n[1] && ($realtime - t_rst[0]) < TRST_NS) ||
                (!cs_n[2] && ($realtime - t_rst[1]) < TRST_NS))
                fail("PSRAM selected within tRST of its reset");
            // Any command ends a reset enable; 66h sets it again. (From cs_n:
            // psel, a wire, may not have caught up with chip and both yet.)
            rsten_q     = psram_rsten;
            psram_rsten = psram_rsten & cs_n[2:1];
            if (chip == 2'd0 && flash_crm) begin
                phase = P_MODE;
                mode  = 8'h00;
            end
            if (chip == 2'd0 && flash_dcrm) begin
                phase = P_DCRM;
                mode  = 8'h00;
            end
        end else if (cs_n == 3'b001 && !both && phase == P_CMD && n == 0 && t_rise < 0.0) begin
            // The other PSRAM's select fell after the first one, before any SCK
            // edge: a broadcast. Each chip sees its own select, so this is the same
            // transaction for both. In a zero-delay simulation the two fall on one
            // event; with real delays they fall picoseconds apart.
            chip  = which(cs_n);
            both  = 1'b1;
            mixed = psram_qpi[0] != psram_qpi[1];
            if ((!cs_n[1] && ($realtime - t_rst[0]) < TRST_NS) ||
                (!cs_n[2] && ($realtime - t_rst[1]) < TRST_NS))
                fail("PSRAM selected within tRST of its reset");
            psram_rsten = rsten_q & cs_n[2:1];
        end else if (!any_sel && phase != P_IDLE) begin
            if (chip != 2'd0 && ($realtime - t_sel) > TCEM_NS)
                fail("PSRAM chip select held low longer than tCEM");
            if (rst_now[0]) t_rst[0] = $realtime;
            if (rst_now[1]) t_rst[1] = $realtime;
            if (chip == 2'd0 && qpi_exit) flash_qpi = 1'b0;
            if (chip == 2'd0 && phase == P_DDATA)
                fork desel_edge_check($realtime); join_none
            phase   = P_IDLE;
            t_desel = $realtime;
            sel_gen = sel_gen + 1;
            dev_oe <= #(TCHZ_NS) 1'b0;
        end
    end

    // SCK period and high / low times, within a transaction.
    always @(posedge sck) if (any_sel) begin
        if (t_rise >= 0.0 && ($realtime - t_rise) < tclk_min() - 0.001)
            fail("SCK period below the minimum for this command");
        if (t_fall >= 0.0 && ($realtime - t_fall) < 0.45 * tclk_min() - 0.001)
            fail("SCK low time below 45% of the minimum period");
        t_rise = $realtime;
    end
    always @(negedge sck) if (any_sel) begin
        if (t_rise >= 0.0 && ($realtime - t_rise) < 0.45 * tclk_min() - 0.001)
            fail("SCK high time below 45% of the minimum period");
        t_fall = $realtime;
    end

    // Flash in continuous read, once its address, mode and dummy clocks are
    // in: the falling edge after them starts data. Checked 1 ps later, once
    // every update of that time step has landed; a chip select rising on
    // that same edge is caught by desel_edge_check instead.
    always @(negedge sck) if (phase == P_DDATA) begin
        #0.001;
        if (any_sel && phase == P_DDATA)
            fail("flash in continuous-read mode drove read data into the window");
    end
    task automatic desel_edge_check(input realtime td);
        begin
            #0.001;
            if (sck === 1'b0 && t_sck == td)
                fail("flash in continuous-read mode deselected on the SCK edge that starts its data");
        end
    endtask

    // ---- Setup / hold checks (see the header) ------------------------------
    reg      tcheck;
    integer  chk_v;
    integer  chk_n, chk_viol, chk_abort;
    real     mgd [0:3];       // EDh address phase: rise setup, rise hold, fall setup, fall hold
    real     mg [0:9];        // smallest margin: {flash, PSRAM} x {setup, hold, CS setup, CS hold}, then 8/9: output-enable release hold
    realtime t_oe_off;        // last time the host stopped driving the IO lines
    realtime t_chg [0:3];     // last change of each IO line
    realtime t_rs, t_rise_any, t_cs_fall;
    real      hold_lim;       // hold needed by the edge that armed hold_pend
    reg       hold_fall;      // ... and which edge it was
    reg       hold_dtr;       // ... and whether it sampled an EDh address nibble
    reg [3:0] hold_pend;      // lines sampled at the last rise, not yet changed
    reg [3:0] host_io_q;
    reg       host_oe_q, cs_first, prev_sel;
    integer   rises;
    reg [8*128-1:0] cmsg;
    integer ci;
    initial begin
        tcheck = 1'b1;
        if ($value$plusargs("QSPI_TCHECK=%d", chk_v)) tcheck = (chk_v != 0);
        chk_n = 0; chk_viol = 0; chk_abort = 0; rises = 0;
        for (ci = 0; ci < 10; ci = ci + 1) mg[ci] = 1.0e9;
        for (ci = 0; ci < 4; ci = ci + 1) mgd[ci] = 1.0e9;
        hold_lim = 0.0; hold_fall = 1'b0; hold_dtr = 1'b0;
        t_oe_off = -1000.0;
        for (ci = 0; ci < 4; ci = ci + 1) t_chg[ci] = -1000.0;
        t_rs = -1000.0; t_rise_any = -1000.0; t_cs_fall = -1000.0;
        hold_pend = 4'b0; host_io_q = 4'bxxxx; host_oe_q = 1'bx;
        cs_first = 1'b0; prev_sel = 1'b0;
    end

    // Device index and requirements: flash (chip 0) or PSRAM (also a broadcast).
    function integer dv; dv = (chip == 2'd0) ? 0 : 1; endfunction
    function real r_su;  r_su  = (chip == 2'd0) ? TDVCH_NS : TSP_NS;  endfunction
    function real r_h;   r_h   = (chip == 2'd0) ? TCHDX_NS : THD_NS;  endfunction
    function real r_css; r_css = (chip == 2'd0) ? TSLCH_NS : TCSP_NS; endfunction
    function real r_csh; r_csh = (chip == 2'd0) ? TCHSH_NS : TCHD_NS; endfunction
    function [8*6-1:0] pname(input [3:0] p);
        case (p)
            P_CMD: pname = "CMD";   P_ADDR: pname = "ADDR";  P_DUMMY: pname = "DUMMY";
            P_WDATA: pname = "WDATA"; P_MODE: pname = "MODE"; P_DCRM: pname = "DCRM";
            P_DTR_AD: pname = "DTR_AD";
            default: pname = "other";
        endcase
    endfunction

    // The IO lines the chip samples on a rise in this phase (posedge only today;
    // the single function of the phase to extend for a DTR phase).
    function [3:0] samp_mask;
        case (phase)
            P_CMD:   samp_mask = (mixed && n >= 2) ? 4'h1 : (mixed || in_qpi) ? 4'hF : 4'h1;
            P_ADDR, P_WDATA: samp_mask = 4'hF;
            P_DUMMY: samp_mask = (chip == 2'd0 && n < 2) ? 4'hF : 4'h0;   // flash mode byte
            P_MODE:  samp_mask = (n < 8) ? 4'hF : 4'h0;                   // address, mode byte
            P_DCRM:  samp_mask = (n < 16) ? 4'h3 : 4'h0;
            P_DTR_AD: samp_mask = n[0] ? 4'h0 : 4'hF;                     // EDh: the rise nibbles
            default: samp_mask = 4'h0;
        endcase
    endfunction

    // The lines sampled on a falling SCK: the EDh fall nibbles (fall 8 to fall
    // 11); the fall right after the command (fall 7) samples nothing.
    function [3:0] samp_mask_fall;
        samp_mask_fall = (phase == P_DTR_AD && n[0]) ? 4'hF : 4'h0;
    endfunction

    // d = measured time, need = required; kind 0 data setup, 1 data hold,
    // 2 CS setup, 3 CS hold. Margins are d - need.
    task chk_note(input integer kind, input real d, input real need);
        integer k;
        begin
            k = dv() * 4 + kind;
            chk_n = chk_n + 1;
            if (d - need < mg[k]) mg[k] = d - need;
        end
    endtask

    task chk_fail_data(input integer line, input real d, input real need, input hold,
                       input fall, input rel);
        begin
            chk_viol = chk_viol + 1;
            if (rel)
                $sformat(cmsg, "%0s %0s: IO release hold violated on IO%0d: output enable released %0.3f ns after SCK fall (needs %0.1f ns)",
                         chip == 2'd0 ? "flash" : "PSRAM", pname(phase), line, d, need);
            else if (hold)
                $sformat(cmsg, "%0s %0s: data-in hold violated on IO%0d: %0.3f ns after SCK %0s (needs %0.1f ns)",
                         chip == 2'd0 ? "flash" : "PSRAM", pname(phase), line, d, fall ? "fall" : "rise", need);
            else
                $sformat(cmsg, "%0s %0s: data-in setup violated on IO%0d: %0.3f ns before SCK %0s (needs %0.1f ns)",
                         chip == 2'd0 ? "flash" : "PSRAM", pname(phase), line, d, fall ? "fall" : "rise", need);
            fail(cmsg);
        end
    endtask

    // On an SCK edge of the transaction, before the phase moves on: fall = 0 a
    // rise, 1 a fall (only the EDh address nibbles are sampled on a fall).
    task chk_edge(input fall);
        reg [3:0] m;
        integer i;
        real d, need;
        begin
            m = fall ? samp_mask_fall() : samp_mask();
            need = fall ? TDVCL_NS : r_su();
            t_rs = $realtime;
            hold_fall = fall;
            hold_lim  = fall ? TCLDX_NS : r_h();
            hold_dtr  = (phase == P_DTR_AD);
            if (cs_first && !fall) begin
                cs_first = 1'b0;
                d = $realtime - t_cs_fall;
                chk_note(2, d, r_css());
                if (d < r_css() - 0.0005) begin
                    chk_viol = chk_viol + 1;
                    $sformat(cmsg, "%0s: chip select setup violated: %0.3f ns before the first SCK rise (needs %0.1f ns)",
                             chip == 2'd0 ? "flash" : "PSRAM", d, r_css());
                    fail(cmsg);
                end
            end
            if (!fall) rises = rises + 1;
            hold_pend = 4'b0;
            if (h_oe === 1'b1) begin
                for (i = 0; i < 4; i = i + 1)
                    if (m[i]) begin
                        d = $realtime - t_chg[i];
                        chk_note(0, d, need);
                        if (hold_dtr && d - need < mgd[fall ? 2 : 0]) mgd[fall ? 2 : 0] = d - need;
                        if (d < need - 0.0005) chk_fail_data(i, d, need, 1'b0, fall, 1'b0);
                        hold_pend[i] = 1'b1;
                    end
            end else if (m != 4'b0 && ($realtime - t_oe_off) < need - 0.0005)
                // The host stopped driving just before this edge: the lines
                // were not held for the setup time.
                for (i = 0; i < 4; i = i + 1)
                    if (m[i]) chk_fail_data(i, $realtime - t_oe_off, need, 1'b0, fall, 1'b0);
        end
    endtask
    task chk_rise; chk_edge(1'b0); endtask
    task chk_fall; chk_edge(1'b1); endtask

    // A host line changes: setup bookkeeping, and the hold of a sampled one.
    // A change in the time step of the rise, whichever block ran first, is a
    // setup violation (0 ns), not a hold one.
    always @(h_io or h_oe) if (tcheck) begin : io_chg
        integer i;
        real d;
        for (i = 0; i < 4; i = i + 1) begin
            if (h_oe === 1'b1 && (host_oe_q !== 1'b1 || h_io[i] !== host_io_q[i])) begin
                t_chg[i] = $realtime;
                if (host_oe_q === 1'b1 && hold_pend[i]) begin
                    hold_pend[i] = 1'b0;
                    d = $realtime - t_rs;
                    chk_note(1, d, hold_lim);
                    if (hold_dtr && d - hold_lim < mgd[hold_fall ? 3 : 1]) mgd[hold_fall ? 3 : 1] = d - hold_lim;
                    if (d < hold_lim - 0.0005) chk_fail_data(i, d, hold_lim, d >= 0.0005, hold_fall, 1'b0);
                end
            end
        end
        if (host_oe_q === 1'b1 && h_oe !== 1'b1) begin
            // A release changes every sampled line: hold-check the pending ones.
            t_oe_off = $realtime;
            for (i = 0; i < 4; i = i + 1)
                if (hold_pend[i]) begin
                    d = $realtime - t_rs;
                    if (d - hold_lim < mg[8 + dv()]) mg[8 + dv()] = d - hold_lim;
                    chk_n = chk_n + 1;
                    if (d < hold_lim - 0.0005)
                        chk_fail_data(i, d, hold_lim, d >= 0.0005, hold_fall, hold_dtr && hold_fall && d >= 0.0005);
                end
        end
        if (h_oe !== 1'b1) hold_pend = 4'b0;
        host_io_q = h_io;
        host_oe_q = h_oe;
    end

    // A real rise: SCK going 0 -> 1, not the 0 -> X of the host releasing the pin.
    reg sck_q = 1'bx;
    always @(sck) begin
        if (sck === 1'b1 && sck_q === 1'b0) t_rise_any = $realtime;
        sck_q = sck;
    end
    always @(cs_n) if (tcheck) begin
        if (cs_n != 3'b111) begin
            if (!prev_sel) begin cs_first = 1'b1; rises = 0; end
            t_cs_fall = $realtime;     // the later of a broadcast's two selects
            prev_sel  = 1'b1;
        end else if (prev_sel) begin
            prev_sel = 1'b0;
            fork chk_cs_hold($realtime); join_none
        end
    end
    // Chip select rose at td: the last SCK rise must be tCHD / tCHSH before it.
    // Looked at 1 ps later, once a rise in the same time step has landed. A
    // select that rises because the host let go of its pins (a reset in the
    // middle of a transaction: the select is pulled up) is not a controller's
    // end of transaction and is only counted.
    task automatic chk_cs_hold(input realtime td);
        real d;
        begin
            #0.001;
            if (rises > 0 && h_coe_c !== 1'b1) chk_abort = chk_abort + 1;
            else if (rises > 0) begin
                d = td - t_rise_any;
                chk_note(3, d, r_csh());
                if (d < r_csh() - 0.0005) begin
                    chk_viol = chk_viol + 1;
                    $sformat(cmsg, "%0s: chip select hold violated: %0.3f ns after the last SCK rise (needs %0.1f ns)",
                             chip == 2'd0 ? "flash" : "PSRAM", d, r_csh());
                    fail(cmsg);
                end
            end
        end
    endtask

    final if (tcheck) begin
        $display("qspi_pmod_model: setup/hold checks: %0d samples checked, %0d violations", chk_n, chk_viol);
        $write("qspi_pmod_model: min margins ns (flash/PSRAM):");
        for (ci = 0; ci < 4; ci = ci + 1) begin
            case (ci)
                0: $write(" data setup ");  1: $write(", data hold ");
                2: $write(", CS setup ");   default: $write(", CS hold ");
            endcase
            if (mg[ci] > 1.0e8)     $write("-/");
            else                    $write("%0.3f/", mg[ci]);
            if (mg[ci+4] > 1.0e8)   $write("-");
            else                    $write("%0.3f", mg[ci+4]);
        end
        $write(", IO release hold ");
        if (mg[8] > 1.0e8)      $write("-/");
        else                    $write("%0.3f/", mg[8]);
        if (mg[9] > 1.0e8)      $write("-");
        else                    $write("%0.3f", mg[9]);
        $write(" (%0d selects released by a pin release, not checked)\n", chk_abort);
        if (n_edh > 0) begin
            $write("qspi_pmod_model: DTR min margins ns:");
            for (ci = 0; ci < 4; ci = ci + 1) begin
                case (ci)
                    0: $write(" rise setup ");  1: $write(", rise hold ");
                    2: $write(", fall setup "); default: $write(", fall hold ");
                endcase
                if (mgd[ci] > 1.0e8) $write("-");
                else                 $write("%0.3f", mgd[ci]);
            end
            $write("\n");
        end
    end

    // Host -> device, on rising SCK
    always @(posedge sck) if (any_sel) begin
        if (tcheck && sck === 1'b1) chk_rise;
        case (phase)
            P_DCRM: begin
                // Dual continuous-read: 12 address clocks, then M7-0 two bits
                // a clock. Undriven mode bits are unknown, so they fail.
                n = n + 1;
                if (n > 12)
                    mode = {mode[5:0], h_oe ? h_io[1:0] : 2'bxx};
                if (n == 16) begin
                    if (^mode[5:4] === 1'bx)
                        fail("flash in dual continuous-read mode got undriven mode bits");
                    if (mode[5:4] != 2'b10) flash_dcrm = 1'b0;
                    phase = P_DDATA;
                end
            end
            P_MODE: begin
                // Quad continuous read: 6 address clocks, the mode byte on
                // clocks 7-8, then the dummy clocks (see the header).
                n = n + 1;
                if (n > 6 && n <= 8)
                    mode = {mode[3:0], h_oe ? h_io : 4'bxxxx};
                if (n == 8) begin
                    if (^mode[5:4] === 1'bx)
                        fail("flash in continuous-read mode got undriven mode bits");
                    if (mode[5:4] != 2'b10) flash_crm = 1'b0;
                end
                if (n == (flash_qpi ? 8 : 12)) phase = P_DDATA;
            end
            P_DTR_AD: if (sck === 1'b1 && !n[0]) dtr_nib;
            P_DTR_DUM: if (sck === 1'b1) n = n + 1;
            P_RDATA: if (sck === 1'b1 && dtr_rd) launch_nib;
            P_IGNORE: if (chip == 2'd0) qpi_exit = 1'b0;   // Exit QPI cancelled
            P_CMD: begin
                if (!h_oe) fail("host not driving IO during the command");
                if (mixed) begin
                    // Broadcast to PSRAMs in different modes: the QPI chip
                    // takes two nibbles, the SPI chip eight bits on IO0.
                    cmd_q = {cmd_q[3:0], h_io};
                    cmd   = {cmd[6:0], h_io[0]};
                    n     = n + 1;
                    if (n == 2) broadcast_cmd(cmd_q, qpi_sel, 1'b1);
                    if (n == 8) begin
                        broadcast_cmd(cmd, ~qpi_sel, 1'b0);
                        phase = P_IGNORE;
                    end
                end else if (in_qpi) begin
                    // Two nibbles make the command.
                    cmd = {cmd[3:0], h_io};
                    n   = n + 1;
                    if (n == 2) begin
                        n     = 0;
                        phase = P_IGNORE;
                        if (chip == 2'd0) begin
                            if (cmd == 8'hFF) qpi_exit = 1'b1;   // at chip select rising
                            else fail("flash in QPI mode got something other than its Exit QPI");
                        end else if (cmd == 8'hF5)
                            psram_qpi = psram_qpi & ~psel;   // Exit QPI
                        else if (cmd == 8'h66 || cmd == 8'h99)
                            psram_reset_cmd(cmd, psel);
                        else if (both)
                            fail("both PSRAMs selected for a read or write");
                        else if (cmd == 8'h0B || cmd == 8'h38 || cmd == 8'h02) begin
                            need_reset(psel);
                            phase = P_ADDR;
                        end else
                            fail("unsupported QPI command for the PSRAM");
                    end
                end else begin
                    cmd = {cmd[6:0], h_io[0]};
                    n   = n + 1;
                    if (n == 8) begin
                        n = 0;
                        if (chip != 2'd0 && (cmd == 8'h66 || cmd == 8'h99)) begin
                            psram_reset_cmd(cmd, psel); // PSRAM reset enable / reset
                            phase = P_IGNORE;
                        end else if (chip != 2'd0 && cmd == 8'h35) begin
                            need_reset(psel);
                            psram_qpi = psram_qpi | psel;   // PSRAM Enter Quad mode
                            phase = P_IGNORE;
                        end
                        else if (chip == 2'd0 && cmd == 8'hFF && !both)
                            phase = P_IGNORE;          // flash CRM reset / Exit QPI
                        else if (both)
                            fail("both PSRAMs selected for a read or write");
                        else if (chip == 2'd0 && cmd == 8'hED) begin
                            n_edh = n_edh + 1;          // DTR read: address on both edges
                            phase = P_DTR_AD;
                        end
                        else if (cmd == 8'hEB || (cmd == 8'h38 && chip != 2'd0)) begin
                            if (chip != 2'd0) need_reset(psel);
                            if (chip == 2'd0) n_eb = n_eb + 1;
                            phase = P_ADDR;
                        end
                        else
                            fail("unsupported command for this chip");
                    end
                end
            end
            P_ADDR: begin
                if (!h_oe) fail("host not driving IO during the address");
                addr = {addr[19:0], h_io};
                n    = n + 1;
                if (n == 6) begin
                    phase  = (cmd == 8'h38 || cmd == 8'h02) ? P_WDATA : P_DUMMY;
                    // Wait cycles: 4 for the PSRAM's QPI 0x0B, 6 for 0xEB.
                    wait_n = (cmd == 8'h0B) ? 4'd4 : 4'd6;
                    n      = 0;
                    hi     = 1'b1;
                end
            end
            P_DUMMY: begin
                if (n < 2) begin
                    if (chip == 2'd0 && !h_oe) fail("host not driving the flash mode byte");
                    mode = {mode[3:0], h_io};
                end
                n = n + 1;
                if (n == 2 && chip == 2'd0 && mode[5:4] == 2'b10)
                    fail("mode bits M5-4 = 10 would enter continuous-read mode");
                if (n == wait_n) begin
                    phase     = P_RDATA;
                    hi        = 1'b1;
                    first_nib = 1'b1;
                end
            end
            P_WDATA: begin
                if (!h_oe) fail("host not driving IO during write data");
                if (hi) wbyte[7:4] = h_io;
                else begin
                    wbyte[3:0] = h_io;
                    ram[ram_index(chip, addr)] = wbyte;
                    ram_w[ram_index(chip, addr) >> 5][ram_index(chip, addr) & 31] = 1'b1;
                    addr = next_addr(chip, addr);
                end
                hi = !hi;
            end
            default: ;
        endcase
    end

    // The timed parts of a launch, as automatic tasks so that overlapping
    // launches (delay_ns above the SCK period) keep their own arguments.
    task automatic output_on(input integer g);
        begin
            #(delay_ns);
            if (sel_gen == g) dev_oe = 1'b1;
        end
    endtask
    task automatic nibble_x(input integer k);
        begin
            #(hold_ns);
            dev_io = eye_rand ? $random : 4'bxxxx;
            x_from = k;
        end
    endtask
    task automatic nibble_land(input integer k, input [3:0] v);
        begin
            #(delay_ns);
            if (x_from == k) dev_io = v;
        end
    endtask

    // Device -> host, on falling SCK. The first data nibble goes out after the
    // falling edge that ends the last dummy cycle.
    // Each nibble lands delay_ns later, after hold_ns of X (see Timing). A
    // nibble lands only if no later launch has started its X by then: with
    // delay_ns - hold_ns above the SCK period the data eye is closed, and
    // the pins stay X.
    // Only the first of a read turns the device's output on, unless the chip
    // is deselected first; chip select rising turns it off after TCHZ_NS. So
    // the nibble launched by the falling edge that deselects the chip -- which
    // lands after the release -- changes dev_io but never drives the pins.
    // EDh: a flash in the DTR read (see the header).
    wire dtr_rd = (chip == 2'd0 && cmd == 8'hED);

    // One address or mode nibble of the EDh open, from the edge that sampled it.
    task dtr_nib;
        begin
            if (n < 6) begin
                if (!h_oe) fail("host not driving IO during the DTR address");
                addr = {addr[19:0], h_io};
            end else
                mode = {mode[3:0], h_oe ? h_io : 4'bxxxx};
            n = n + 1;
            if (n == 8) begin
                if (^mode === 1'bx)
                    fail("undriven or X mode bits in the DTR open");
                if (mode[5:4] == 2'b10)
                    fail("mode bits M5-4 = 10 would enter DTR continuous-read mode");
                if (addr[1:0] != 2'b00 && !dtr_unal_ok)
                    fail("DTR open with A1:A0 != 00 (unaligned address)");
                phase = P_DTR_DUM;
                n     = 0;
            end
        end
    endtask

    // EDh on falling SCK: the odd address / mode nibbles, the end of the dummy
    // cycles, and the data launches. The fall right after the command (n = 0)
    // is not an address edge.
    always @(negedge sck) if (any_sel && sck === 1'b0 && dtr_rd) begin
        case (phase)
            P_DTR_AD: if (n[0]) begin
                if (tcheck) chk_fall;
                dtr_nib;
            end
            P_DTR_DUM: if (n == dtr_dummy) begin
                phase     = P_RDATA;
                hi        = 1'b1;
                first_nib = 1'b1;
                if (dtr_launch == 0) launch_nib;
            end
            P_RDATA: launch_nib;
            default: ;
        endcase
    end

    task launch_nib;
        begin
            if (first_nib)
                fork output_on(sel_gen); join_none
            // A forked task reads its arguments when it starts, after this block
            // has moved hi and addr on, so they go through nib_k and nib_v, which
            // hold until the next launch.
            launch = launch + 1;
            nib_k  = launch;
            nib_v  = hi ? rd(chip, addr) >> 4 : rd(chip, addr) & 8'h0F;
            fork
                nibble_x(nib_k);
                nibble_land(nib_k, nib_v);
            join_none
            if (!hi) begin
                addr = next_addr(chip, addr);
                if (chip == 2'd0) n_bytes = n_bytes + 1;
            end
            hi = !hi;
            first_nib = 1'b0;
        end
    endtask
    always @(negedge sck) if (any_sel && phase == P_RDATA && !dtr_rd) launch_nib;

    // Bus contention
    always @(*) if (h_oe && dev_oe) fail("host and device both driving IO");

    // Flash read counters, for benches (hierarchical) and the line printed at
    // the end: n_eb (alias n_ebh) / n_edh = EBh / EDh commands (a stream of
    // sequential reads shows one), n_resume = SCK edges after a pause in a
    // flash read's data phase, n_bytes = flash bytes launched (both nibbles).
    integer n_eb = 0, n_edh = 0, n_resume = 0, n_bytes = 0;
    wire [31:0] n_ebh = n_eb;

    // A resume is an SCK edge, in the data phase of a flash EBh / EDh, more
    // than 1.5 times the shortest edge spacing seen so far in this select
    // after the edge before it. SCK may stop at either level.
    reg      sck_p = 1'bx;
    realtime t_edge, min_sp, sp;
    initial begin t_edge = -1.0; min_sp = 1.0e9; end
    always @(sck) begin
        if ((sck === 1'b0 || sck === 1'b1) && (sck_p === 1'b0 || sck_p === 1'b1) && any_sel) begin
            if (t_edge >= 0.0) begin
                sp = $realtime - t_edge;
                if (phase == P_RDATA && chip == 2'd0 && (cmd == 8'hEB || cmd == 8'hED) &&
                    sp > 1.5 * min_sp)
                    n_resume = n_resume + 1;
                if (sp < min_sp) min_sp = sp;
            end
            t_edge = $realtime;
        end
        sck_p = sck;
    end

    final $display("qspi_pmod_model: flash reads: EBh %0d, EDh %0d, resumes %0d, bytes %0d",
                   n_eb, n_edh, n_resume, n_bytes);

endmodule

// Pin invariants of the QSPI engine, checked on every clock (sampled just
// before the edge, so the pins as the last edge left them):
//   * CS0 is never low together with CS1 or CS2;
//   * chip select is high for at least two clocks between two low periods;
//   * `quiet` (the engine holds a stream open and is between transfers): CS0
//     is low, SCK is low and the bus is released.
module qspi_pin_inv (
    input wire       clk,
    input wire       ctl_oe,
    input wire [2:0] cs_n,
    input wire       sck,
    input wire       io_oe,
    input wire       quiet
);
    integer errs = 0;
    integer hi_run = 0;
    always @(posedge clk) begin
        if (!ctl_oe) hi_run = 0;
        else begin
            if (!cs_n[0] && cs_n[2:1] != 2'b11) begin
                $display("FAIL pins: CS0 low together with CS1/CS2 (cs_n=%b) t=%0t", cs_n, $time);
                errs = errs + 1;
            end
            if (cs_n == 3'b111) hi_run = hi_run + 1;
            else begin
                if (hi_run > 0 && hi_run < 2) begin
                    $display("FAIL pins: chip select high for %0d clock between transactions t=%0t", hi_run, $time);
                    errs = errs + 1;
                end
                hi_run = 0;
            end
            if (quiet && (cs_n[0] !== 1'b0 || sck !== 1'b0 || io_oe !== 1'b0)) begin
                $display("FAIL pins: open stream not quiet (cs_n=%b sck=%b io_oe=%b) t=%0t", cs_n, sck, io_oe, $time);
                errs = errs + 1;
            end
        end
    end
endmodule
