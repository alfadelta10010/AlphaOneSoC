#!/bin/bash
# check-nuttx.sh <run.log>: the nsh session output must contain each expected line, and the bench must say PASS.
L=$1; rc=0
chk() { if grep -aq -- "$1" "$L"; then echo "ok   $1"; else echo "FAIL $1"; rc=1; fi; }
chk 'NuttShell (NSH) NuttX-12.11.0'
chk 'help usage:  help \[-v\]'
chk '^ dev/'
chk '^ proc/'
chk '^hello'
chk 'PID  PPID GROUP PRI POLICY'
chk 'Idle_Task'
chk 'total.*used.*free'
chk '^NuttX 12.11.0 .* risc-v rv-virt'
chk 'Hello, World!!'
chk 'SW-RESULT: PASS'
exit $rc
