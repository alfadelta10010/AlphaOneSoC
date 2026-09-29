# t_ctl's LR/SC increment loop under a timer interrupt, at a period the
# SoC's QSPI-speed pipeline keeps up with. t_ctl itself (a 100-clock period)
# is skipped at SoC level: its handler takes longer than the period there.
# Since same-hart stores keep the reservation, the trap clear is all that
# protects an LR/SC sequence from an interrupt handler's stores, so it has
# to be seen working at the SoC's timing too: the MANIFEST line wants the
# loop to finish (x8 = x25 = 100), an interrupt taken (x20 = 1) and an SC
# failed by one (x19 = 1). DUT-only, as t_ctl: the timer counts clocks.
#
# Two nops sit between the LR and the SC (a constrained loop may hold up to
# 16 instructions). Without them no interrupt ever lands inside the pair at
# this speed: an interrupt is injected only on a cycle nothing stalls, and
# through the QSPI memory the instructions straight after an LR never get
# one -- measured, all 22 interrupts of the unpadded loop were taken after
# the SC or the loop branch. With the nops, 6 of 31 land between the LR and
# the SC and 18 SCs fail.
#define PERIOD 2000
#define PAD 2
#include "t_ctl.S"
