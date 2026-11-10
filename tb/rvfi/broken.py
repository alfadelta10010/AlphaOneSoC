# Faults on the RVFI port / other src lines for tb/rvfi/mutants.sh (WO-38).
# Same tuple format as tb/mutate/mutants.py: (id, file, find, replace, intent).
# `find` must occur exactly once. A file named "rvfi/<x>" is a copy of tb/rvfi/<x>
# (wrapper side), any other name is a file of the copied src/.
B = []
def b(mid, f, find, rep, why):
    B.append((mid, f, find, rep, why))

b("BC-PC1", "fyracore.v",
  "else if (stall || ex_nofetch)\n            next_pc = pc;       // a not-taken branch: pc already is the fall-through",
  "else if (stall || ex_nofetch)\n            next_pc = (ex_nofetch && !stall) ? pc + 32'd2 : pc;",
  "a not-taken branch skips 2 bytes; the port still reports pc, so only pc_fwd/pc_bwd can fail")
b("BC-ORD-DOWN", "fyracore.v", "assign rvfi_order = fv_order;", "assign rvfi_order = ~fv_order;",
  "rvfi_order reported as ~count (counts down)")
b("BC-ORD-TRAP", "fyracore.v", "fv_order     <= fv_order + 64'd1;",
  "fv_order     <= exwb_trap ? fv_order : fv_order + 64'd1;",
  "rvfi_order not incremented after a trap retire (duplicate order)")
b("BC-ILL", "compressed_decoder.v", "if (instr_in[12:5] == 8'b0)", "if (1'b0)",
  "16'h0000 (C.ADDI4SPN, nzuimm 0) treated as legal")
b("BC-ALTMUL", "fyracore.v", "(alu_d1 + alu_d2) ^ 32'h5876063e; // MUL",
  "(alu_d1 + alu_d2) ^ 32'h5876063f; // MUL", "ALTOPS mask bit flipped for MUL: insn_mul must FAIL at a real-latency retire")
b("BC-ALTDIV", "fyracore.v", "(alu_d1 - alu_d2) ^ 32'h7f8529ec; // DIV",
  "(alu_d1 - alu_d2) ^ 32'h7f8529ed; // DIV", "ALTOPS mask bit flipped for DIV: insn_div must FAIL at a real-latency retire")
b("BC-COV", "rvfi/wrapper.sv", "assume (fv_misa_c);", "assume (fv_misa_c);\n\t\t\tassume (!rvfi_valid);",
  "wrapper copy with assume(!rvfi_valid): nothing can retire, every cover is unreached")
