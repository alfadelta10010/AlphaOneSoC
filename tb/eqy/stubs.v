// Empty stand-ins for the sky130_fd_sc_hd cells that the Liberty file does
// not define and that the hardened netlist instantiates without any pin:
// the physical filler and tap cells (4,136 fill_1, 3,090 fill_2, 3,325
// tapvpwrvgnd_1). They have no function, so equivalence checking ignores them.
// decap_3 and diode_2 are in the Liberty file; they have no output.
module sky130_fd_sc_hd__fill_1 ();
endmodule
module sky130_fd_sc_hd__fill_2 ();
endmodule
module sky130_fd_sc_hd__tapvpwrvgnd_1 ();
endmodule
