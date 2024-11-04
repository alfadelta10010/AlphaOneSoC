# To run simulations
```bash
iverilog ./gls_model/primitives.v ./gls_model/sky130_fd_sc_hd.v ./netlists/mux21.v ./tb/tb_mux21.v -o ./post_sim/mux21.out -DFUNCTIONAL -DUNIT_DELAY=#1
./mux21.out
mv dump.vcd mux21.vcd
gtkwave mux21.vcd
```
