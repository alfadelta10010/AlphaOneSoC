#!/usr/bin/env bash
# Local -> sandbox: the pin's src/ and tb/ (from git archive, never the working tree) and fpga/up5k/.
# Light work only (tar + rsync). Everything heavy then runs on the sandbox in $W.
set -eu
cd "$(dirname "$0")/../../.."
PIN=$(cat fpga/up5k/PIN)
W=${W:-regr/fpga-up5k/wo-f1}
SSH_OPTS="-o HostKeyAlias=mempool.lan -o IdentitiesOnly=yes -i $HOME/.ssh/id_sandbox -p 22181"
HOST=mempool@49.207.248.15
ssh -n $SSH_OPTS $HOST "mkdir -p $W/up5k $W/pin && rm -rf $W/pin/src $W/pin/tb"
git archive "$PIN" src tb | ssh $SSH_OPTS $HOST "tar -x -C $W/pin"
rsync -a --delete --exclude build/ -e "ssh $SSH_OPTS" fpga/up5k/ $HOST:$W/up5k/
echo "synced pin $PIN and fpga/up5k to $HOST:~/$W"
