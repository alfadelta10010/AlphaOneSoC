# Linux (NOMMU, M-mode, RV32IMAC) on AlphaOneSoC - rung 8 notes

Build: `recipe/build.sh ~/linux-work` (cnlohr/buildroot 851edd24, Linux 6.8-rc1, uClibc-ng, busybox 1.36.1 static FLAT,
elf2flt), then `recipe/pack.sh` (stub + DTB + Image -> blob-*.bin, linux-spike.elf, flash-linux.hex/.bin via sw/tools/mkflash.py).
A host `unzip` is needed: build.sh installs `recipe/unzip` (a python shim) on PATH when the host has none.
Outputs: Image (1.95 MB, initramfs inside, 284 KB cpio), rootfs.cpio, alpha.dtb (SoC), spike.dtb, System.map, vmlinux,
kernel.config, busybox.built.config. The build tree br/ is 7.5 GB.

## Config choices (recipe/linux.config = KianV minimal config plus)
- RISCV_ISA_C=y (KianV's config has it off, the first build had it off: rebuilt), RISCV_M_MODE=y (implied by !MMU), ARCH_RV32I,
  MMU off, BINFMT_FLAT, CLINT_TIMER, 8250 + OF platform, POWER_RESET_SYSCON(+_POWEROFF).
- HZ=30 via a new Kconfig choice HZ_30 (recipe/patches/0003-Add-HZ_30-timer-frequency.patch). Buildroot: RVM+RVA+RVC, -Os, no LTO, no host QEMU.
- At boot: "14080K/16384K available".
- Command line (in the DTB): `rw console=ttyS0,115200 earlycon=uart8250,mmio,0x10000000 loglevel=7`. No baud on earlycon (it would reprogram
  the divisor from a 1.8 MHz default clock); console 115200 with clock-frequency 62.5 MHz rounds to divisor 34, the reset value.
- initramfs: busybox init; inittab mounts /proc and /sys, runs /etc/init.d/rcS (uname -a, cat /proc/cpuinfo, echo ok), then `-/bin/sh` (hush).
  `poweroff` goes through syscon-poweroff (0x5555).

## Bench run
`run-bench.sh` boots `flash-linux.hex` on the bench and types `session.txt` (`uname -a`, `echo shell-ok`, `poweroff`) one
character per echo. The SoC UART's receiver is one byte deep (uart.v gives it RTS# flow control, which the bench sender
ignores) and the 8250 driver is polled, so input is limited to one character per poll, about 30 a second at HZ 30.

## Device tree (recipe/alpha.dts is the template, build.sh writes deliver/alpha.dts; spike.dts differs as listed)
memory 0x80000000 size 0x00ff0000 (loader limit); cpu riscv,isa rv32imac_zicsr_zifencei, mmu-type riscv,none, riscv,pmpregions 4;
timebase 62.5 MHz; riscv,clint0 @0x02000000 (interrupts-extended 3, 7); ns16550a @0x10000000 reg-shift 0, reg-io-width 1, no interrupts;
syscon @0x10020000 + syscon-poweroff 0x5555 + syscon-reboot 0x7777. GPIO/SPI/SD are not described.
Spike variant: timebase 14535 Hz (Spike's mtime ticks once per 100 instructions; 14535 gives a 30 Hz jiffy the same number of
instructions as the SoC at 43 clocks/instruction), a PLIC node + uart `interrupts` (Spike builds its ns16550 only with a PLIC), no mmu-type,
and the syscon on the HTIF tohost word 0x80ff0000 (extra reserved-memory node): a write of 0x5555 ends Spike (exit code 0x2AAA, printed as "FAILED").

## Image layout
The NOMMU kernel is linked at 0x80000000 and cannot move (an offset load crashed on the first trap), so the payload (load 0x80000000,
2,106,912 B) is: Image at +0x0, stub at +0x201000 (the page behind _end 0x802003e8), DTB at +0x202000.
Entry = stub (a0=0, a1=DTB, jump to 0x80000000). Flash image 2,172,472 B.

## Problems met
1. Sandbox has no unzip (shim). 2. KianV config has RISCV_ISA_C off (rebuilt). 3. Kernel is not relocatable (layout above).
4. Spike needs: mmu-type removed, a PLIC for its ns16550, riscv,pmpregions in the DTB (else no PMP CSRs: the kernel's pmpaddr0 write
   traps, which it tolerates), --dtb-discovery, and no sifive-test device exists (HTIF tohost trick).
5. Verilator bench stdout is fully buffered into a file: run under `stdbuf -oL` or the log stays empty.
6. Sandbox ssh sessions drop on idle commands over ~2 minutes.
No RTL or loader defect found so far.
