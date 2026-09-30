# t_ctl's LR/SC increment loop under a timer interrupt, at a period the
# SoC's QSPI-speed pipeline keeps up with. t_ctl itself (a 100-clock period)
# is skipped at SoC level: its handler takes longer than the period there.
# The MANIFEST line wants the loop to finish (x8 = x25 = 100) with timer
# interrupts taken (x20 = 1): LR/SC keeps making progress under interrupts
# at the SoC's timing. DUT-only, as t_ctl: the timer counts clocks.
# lrsc_trap_clear checks, by construction, that an interrupt between an LR
# and its SC fails the SC; here where interrupts land depends on pipeline
# timing, so an SC failure (x19) is reported but not required.
#
# Two nops sit between the LR and the SC (a constrained loop may hold up to
# 16 instructions). Without them no interrupt lands inside the pair at this
# speed: an interrupt is injected only on a cycle nothing stalls, and
# through the QSPI memory the instructions straight after an LR never get
# one -- measured, all 22 interrupts of the unpadded loop were taken after
# the SC or the loop branch. With the nops, 6 of 31 land between the LR and
# the SC and 18 SCs fail, so the trap clear is exercised here as well.
#define PERIOD 2000
#define PAD 2
#include "t_ctl.S"
