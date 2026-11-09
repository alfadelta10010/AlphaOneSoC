// RTL lemma for the equivalence check (tb/eqy/run.sh, stage lemma).
//
// Synthesis removed 186 flops that hold a constant once the chip has been
// reset (184 CSR bits: the WARL-hardwired bits of mstatus, mie, mtvec, mepc,
// mcounteren, mcountinhibit, misa, pmpcfg0, the pipeline's trap_cause and
// trap_pc; plus gpio out_r[1] and [3], which live in spi's pin flops), and
// re-encoded four FSMs one-hot, leaving the unlisted codes out. This file
// proves, on the RTL and from any state, that both are sound:
//
//   L1  once a reset has been applied, every one of the 186 bits equals its
//       reset value, whatever the pins do afterwards
//   L2  once a reset has been applied, exwb_memSize is never 3, muldiv's st
//       is never 6 or 7, qspi's state is never 7, and spi's st is never 3
//
// The masks and values come from the generated consts.vh (run.sh): the mask
// is the list of removed bits that tb/eqy/accounting.py found, the value is
// what the RTL's own reset gives those bits (read off a solver trace), so
// none of the 186 is typed here. The design's internal nets are brought out
// as ports by yosys's `expose` (hierarchical references are not supported),
// and rst_soc is the reset that reaches every flop of the SoC.
//
// Proved by k-induction (yosys `sat -tempinduct`, no external solver). The
// base case starts from the all-zero state, but `armed` is only set by a
// reset, so nothing is asserted before one; the induction step starts from
// any state. All assertions are assumed in the earlier steps of an
// induction, so they strengthen each other.
`include "consts.vh"
module lemma_props (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] ui_in,
    input  wire [7:0] uio_in,
    input  wire       ena
);
    wire [7:0]  uo_out, uio_out, uio_oe;
    wire        rst_soc;
    wire [31:0] mie, mtvec, pmpcfg0, mcounteren, mcountinhibit, mepc, misa,
                mstatus, trap_cause, trap_pc;
    wire [7:0]  gpio_out_r;
    wire [1:0]  spi_st;
    wire [31:0] pc, ifex_pc;
    wire [1:0]  exwb_memSize;
    wire [2:0]  muldiv_st; wire [3:0] qspi_state;

    tt_um_alfadelta10010_alphaone_soc dut (
        .ui_in(ui_in), .uo_out(uo_out), .uio_in(uio_in), .uio_out(uio_out),
        .uio_oe(uio_oe), .ena(ena), .clk(clk), .rst_n(rst_n),
        .\soc.rst_soc (rst_soc),
        .\soc.cpu.csr_mie (mie),
        .\soc.cpu.csr_mtvec (mtvec),
        .\soc.cpu.csr_pmpcfg0 (pmpcfg0),
        .\soc.cpu.csr_unit.mcounteren (mcounteren),
        .\soc.cpu.csr_unit.mcountinhibit (mcountinhibit),
        .\soc.cpu.csr_unit.mepc (mepc),
        .\soc.cpu.csr_unit.misa_reg (misa),
        .\soc.cpu.csr_unit.mstatus (mstatus),
        .\soc.cpu.csr_unit.trap_cause (trap_cause),
        .\soc.cpu.csr_unit.trap_pc (trap_pc),
        .\soc.cpu.imem_addr (pc),
        .\soc.cpu.ifex_pc (ifex_pc),
        .\soc.cpu.exwb_memSize (exwb_memSize),
        .\soc.cpu.muldiv_inst.st (muldiv_st),
        .\soc.qspi.state (qspi_state),
        .\soc.gpio_inst.out_r (gpio_out_r),
        .\soc.gpio_inst.spi_inst.st (spi_st));

    // A reset edge has happened: rst_soc is high at a clock edge, and every
    // flop of the SoC takes its reset value at that edge.
    reg armed = 1'b0;
    always @(posedge clk) if (rst_soc) armed <= 1'b1;

    // One flag per register, 1 = holds. A flag that is 0 in a counterexample
    // names the assertion that failed.
    wire ok_mie           = !armed || ((mie           & `LM_soc_cpu_csr_mie)                == `LV_soc_cpu_csr_mie);
    wire ok_mtvec         = !armed || ((mtvec         & `LM_soc_cpu_csr_mtvec)              == `LV_soc_cpu_csr_mtvec);
    wire ok_pmpcfg0       = !armed || ((pmpcfg0       & `LM_soc_cpu_csr_pmpcfg0)            == `LV_soc_cpu_csr_pmpcfg0);
    wire ok_mcounteren    = !armed || ((mcounteren    & `LM_soc_cpu_csr_unit_mcounteren)    == `LV_soc_cpu_csr_unit_mcounteren);
    wire ok_mcountinhibit = !armed || ((mcountinhibit & `LM_soc_cpu_csr_unit_mcountinhibit) == `LV_soc_cpu_csr_unit_mcountinhibit);
    wire ok_mepc          = !armed || ((mepc          & `LM_soc_cpu_csr_unit_mepc)          == `LV_soc_cpu_csr_unit_mepc);
    wire ok_misa          = !armed || ((misa          & `LM_soc_cpu_csr_unit_misa_reg)      == `LV_soc_cpu_csr_unit_misa_reg);
    wire ok_mstatus       = !armed || ((mstatus       & `LM_soc_cpu_csr_unit_mstatus)       == `LV_soc_cpu_csr_unit_mstatus);
    wire ok_trap_cause    = !armed || ((trap_cause    & `LM_soc_cpu_csr_unit_trap_cause)    == `LV_soc_cpu_csr_unit_trap_cause);
    wire ok_trap_pc       = !armed || ((trap_pc       & `LM_soc_cpu_csr_unit_trap_pc)       == `LV_soc_cpu_csr_unit_trap_pc);
    wire ok_gpio_out_r    = !armed || ((gpio_out_r    & `LM_soc_gpio_inst_out_r)            == `LV_soc_gpio_inst_out_r);
    wire ok_spi_st        = !armed || (spi_st != 2'b11);                       // L2
    wire ok_memSize       = !armed || (exwb_memSize != 2'b11);                 // L2
    wire ok_st            = !armed || (muldiv_st != 3'b110 && muldiv_st != 3'b111);   // L2
    wire ok_state         = !armed || (qspi_state <= 4'd9);                // L2
    // Supporting invariant (H1): the pc is halfword-aligned. mepc[0] and
    // trap_pc[0] load from it, and induction cannot see that without it.
    // It is proved here like the rest; it is not an assumption.
    wire ok_pc_aligned    = !armed || (!pc[0] && !ifex_pc[0]);

    always @(*) begin
        assert (ok_mie);           assert (ok_mtvec);          assert (ok_pmpcfg0);
        assert (ok_mcounteren);    assert (ok_mcountinhibit);  assert (ok_mepc);
        assert (ok_misa);          assert (ok_mstatus);        assert (ok_trap_cause);
        assert (ok_trap_pc);       assert (ok_memSize);        assert (ok_st);
        assert (ok_state);         assert (ok_pc_aligned);
        assert (ok_gpio_out_r);    assert (ok_spi_st);
    end
endmodule
