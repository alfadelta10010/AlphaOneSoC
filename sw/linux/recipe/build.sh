#!/bin/bash
# Reproducible build: buildroot (cnlohr fork, Linux 6.8-rc1 NOMMU RV32) -> Image, rootfs.cpio, DTBs.
# Usage: build.sh [workdir]   (default: dir of this script's parent)
set -euo pipefail
R=$(cd "$(dirname "$0")" && pwd)           # recipe dir
W=${1:-$R/..}
BR_COMMIT=851edd24                          # cnlohr/buildroot master used
[ -d "$W/br" ] || { git clone https://github.com/cnlohr/buildroot.git "$W/br"; git -C "$W/br" checkout $BR_COMMIT; }
B=$W/br
mkdir -p $B/board/alpha
cp -a $R/overlay $B/board/alpha/
cp $R/linux.config $R/busybox.config $B/board/alpha/
cp $R/patches/*.patch $B/board/qemu/riscv32-virt/nommu/patches/linux/6.8-rc1/
cp $R/defconfig $B/configs/alpha_defconfig
make -C $B alpha_defconfig
nice -n 19 make -C $B -j2
OUT=${DELIVER:-$W/deliver}; mkdir -p $OUT
cp $B/output/images/Image $B/output/images/rootfs.cpio $OUT/
cp $B/output/build/linux-6.8-rc1/System.map $OUT/
# device trees: SoC and Spike variants. Spike builds its ns16550 only with a PLIC in the tree,
# so the Spike variant adds a PLIC and a uart `interrupts` (the kernel has no PLIC driver, so
# Spike has no syscon: its variant puts the syscon on the HTIF tohost word (0x80ff0000, reserved), a write of 0x5555 ends the run.
# the uart still falls back to polling, as on the SoC); it also drops mmu-type (Spike rejects "riscv,none").
python3 - $R/alpha.dts $OUT <<PY
import sys
s=open(sys.argv[1]).read(); o=sys.argv[2]
extra="\tmemory@80ff0000 {\n\t\tdevice_type = \"memory\";\n\t\treg = <0x80ff0000 0x10000>;\n\t};\n\n\treserved-memory {\n\t\t#address-cells = <1>;\n\t\t#size-cells = <1>;\n\t\tranges;\n\t\thtif@80ff0000 {\n\t\t\treg = <0x80ff0000 0x10000>;\n\t\t\tno-map;\n\t\t};\n\t};\n\n"
soc=s.replace("@TIMEBASE@","62500000").replace("@SYSCON@","10020000").replace("@UARTIRQ@","").replace("@PLIC@","").replace("@EXTRAMEM@","")
plic="\t\tplic: interrupt-controller@c000000 {\n\t\t\tcompatible = \"sifive,plic-1.0.0\";\n\t\t\treg = <0x0c000000 0x4000000>;\n\t\t\triscv,ndev = <10>;\n\t\t\tinterrupt-controller;\n\t\t\t#interrupt-cells = <1>;\n\t\t\t#address-cells = <0>;\n\t\t\tinterrupts-extended = <&cpu0_intc 11>;\n\t\t};\n\n"
sp=s.replace("@TIMEBASE@","14535").replace("@SYSCON@","80ff0000").replace("@EXTRAMEM@",extra).replace("@UARTIRQ@","\t\t\tinterrupt-parent = <&plic>;\n\t\t\tinterrupts = <1>;\n").replace("@PLIC@",plic)
sp="\n".join(l for l in sp.split("\n") if "mmu-type" not in l)
open(o+"/alpha.dts","w").write(soc); open(o+"/spike.dts","w").write(sp)
PY
dtc -I dts -O dtb -o $OUT/alpha.dtb $OUT/alpha.dts
dtc -I dts -O dtb -o $OUT/spike.dtb $OUT/spike.dts
