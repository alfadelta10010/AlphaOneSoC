#!/usr/bin/env python3
"""Proves the yosys/liberty cell functions equal the PDK's own Verilog models, for every cell type a netlist uses.

  cell_check.py LOGIC_CELLS=<file with one cell name per line> OUT=<dir> [PDKLIB=<dir>] [LIB=<liberty>]

For each cell: its function is written out by yosys (read_liberty, write_verilog of that module alone, renamed conv_<cell>)
and compared in Icarus with the PDK model (primitives.v + sky130_fd_sc_hd.v, -DFUNCTIONAL): all 2^n input vectors for a
combinational cell (n <= 8), clocked random sequences for a flop (async set/reset pulsed at random, compared after every
event; Q is compared once both models have left X). A mismatch anywhere is printed and exits 1.
"""
import os, re, subprocess, sys

args = dict(a.split("=", 1) for a in sys.argv[1:])
out = os.path.abspath(args["OUT"]); os.makedirs(out, exist_ok=True)
pdkv = "8afc8346a57fe1ab7934ba5a6056ea8b43078e71"
pdk = args.get("PDKLIB", f"/home/mempool/tt/pdk/ciel/sky130/versions/{pdkv}/sky130A/libs.ref/sky130_fd_sc_hd")
lib = args.get("LIB", f"{pdk}/lib/sky130_fd_sc_hd__tt_025C_1v80.lib")
cells = [l.strip() for l in open(args["LOGIC_CELLS"]) if l.strip()]
yosys = os.environ.get("YOSYS", "yosys"); iverilog = os.environ.get("IVERILOG", "iverilog"); vvp = os.environ.get("VVP", "vvp")

# 1. the converted cells, one yosys run for all of them
ys = [f"read_liberty -overwrite -ignore_miss_func -ignore_miss_dir {lib}"]
ys.append("proc")
for c in cells:
    ys += [f"select -module {c}", f"write_verilog -noattr -selected {out}/{c}.raw.v"]
open(f"{out}/cells.ys", "w").write("\n".join(ys) + "\n")
subprocess.run([yosys, "-q", "-l", f"{out}/cells.log", f"{out}/cells.ys"], check=True)

bad = 0
for c in cells:
    raw = open(f"{out}/{c}.raw.v").read()
    conv = raw.replace(f"module {c}(", f"module conv_{c}(").replace(f"module {c} (", f"module conv_{c} (")
    # keep only the cell's own module (yosys may also dump helper modules)
    m = re.search(rf"module conv_{c}\s*\((.*?)\);", conv, re.S)
    if not m:
        print(f"FAIL {c}: no converted module"); bad += 1; continue
    open(f"{out}/{c}.conv.v", "w").write(conv)
    ports = [p.strip() for p in m.group(1).split(",")]
    ins = re.findall(r"^\s*input\s+(?:\[[^\]]*\]\s*)?(\w+);", conv, re.S | re.M)
    outs = re.findall(r"^\s*output\s+(?:\[[^\]]*\]\s*)?(\w+);", conv, re.M)
    if len(ins) + len(outs) != len(ports):          # a port the regexes missed would float: X == X passes
        print(f"FAIL {c}: ports {ports}: parsed {len(ins)} inputs + {len(outs)} outputs"); bad += 1; continue
    seq = "CLK" in ins or "GATE" in ins or "GATE_N" in ins or "CLK_N" in ins
    tb = ["`timescale 1ns/1ps", "module t;", "  integer i, err = 0, n = 0;"]
    for p in ins: tb.append(f"  reg {p};")
    for p in outs: tb.append(f"  wire {p}_g, {p}_c;")
    pm = lambda s: ", ".join([f".{p}({p})" for p in ins] + [f".{p}({p}_{s})" for p in outs])
    tb.append(f"  {c} g ({pm('g')});")
    tb.append(f"  conv_{c} cv ({pm('c')});")
    # a flop's compare only counts once the PDK model has left X (Q is X until the first clock / reset)
    cnt = f"if ({outs[0]}_g !== 1'bx) n = n + 1;" if seq else "n = n + 1;"
    chk = f"  task chk; begin {cnt} " + " ".join(
        f"if ({p}_g !== {p}_c" + (f" && {p}_g !== 1'bx" if seq else "") + f") begin err = err + 1; if (err < 5) $display(\"MISMATCH {c} {p}: pdk=%b conv=%b t=%0t\", {p}_g, {p}_c, $time); end"
        for p in outs) + " end endtask"
    tb.append(chk)
    if not seq:
        if len(ins) > 8:
            print(f"FAIL {c}: {len(ins)} inputs, not exhaustive"); bad += 1; continue
        tb.append("  initial begin")
        tb.append(f"    for (i = 0; i < {1 << len(ins)}; i = i + 1) begin")
        off = 0
        for p in ins:
            tb.append(f"      {p} = i[{off}]; ")
            off += 1
        tb.append("      #1; chk; end")
    else:
        clk = "CLK" if "CLK" in ins else None
        if not clk:
            print(f"FAIL {c}: sequential cell not supported by the checker"); bad += 1; continue
        tb.append("  initial begin")
        for p in ins: tb.append(f"    {p} = 1'b0;")
        for p in ("RESET_B", "SET_B"):
            if p in ins: tb.append(f"    {p} = 1'b0; #3; {p} = 1'b1;")
        tb.append("    for (i = 0; i < 4000; i = i + 1) begin")
        for p in ins:
            if p == "CLK": continue
            if p in ("RESET_B", "SET_B"):
                tb.append(f"      {p} = ($random % 8 != 0);")      # mostly deasserted, sometimes low
            else:
                tb.append(f"      {p} = $random;")
        tb.append("      #1; chk; CLK = 1; #1; chk; #1; chk; CLK = 0; #1; chk; end")
    tb += ["    $display(\"CELL %s vectors=%0d errors=%0d\", \"" + c + "\", n, err);", "    $finish;", "  end", "endmodule"]
    open(f"{out}/{c}.tb.v", "w").write("\n".join(tb) + "\n")
    r = subprocess.run([iverilog, "-g2012", "-DFUNCTIONAL", "-DSIM", "-DUNIT_DELAY=#0", "-o", f"{out}/{c}.vvp",
                        f"{pdk}/verilog/primitives.v", f"{pdk}/verilog/sky130_fd_sc_hd.v", f"{out}/{c}.conv.v", f"{out}/{c}.tb.v"],
                       capture_output=True, text=True)
    if r.returncode:
        print(f"FAIL {c}: compile: {r.stderr[:400]}"); bad += 1; continue
    r = subprocess.run([vvp, "-n", f"{out}/{c}.vvp"], capture_output=True, text=True)
    last = [l for l in r.stdout.splitlines() if l.startswith(("CELL", "MISMATCH"))]
    res = [l for l in last if l.startswith("CELL")]
    if res and seq:
        nv = int(re.search(r"vectors=(\d+)", res[0]).group(1))
        if nv < 3000:
            print(f"FAIL {c}: only {nv} non-X compares (need 3000)"); bad += 1; continue
    if not res or "errors=0" not in res[0]:
        print(f"FAIL {c}: " + " | ".join(last[:4])); bad += 1
    else:
        print(res[0])
print(f"cell_check: {len(cells)} cell types, {bad} failed")
sys.exit(1 if bad else 0)
