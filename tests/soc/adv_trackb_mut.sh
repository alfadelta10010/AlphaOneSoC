#!/bin/bash
# Non-vacuity batch for the Track B adversarial programs: for each mutant ID, build a broken copy of <tree>
# (tests/soc/adv_mkmut.py) and run tests/soc/adv_trackb.sh on it. A mutant is KILLED when the program's
# VERDICT is FAIL (a check fired, a signature differs between cache modes or from the reference, or a hang).
# usage: tests/soc/adv_trackb_mut.sh <tree> <outdir> "<prog[:flags] ...>" ID...
set -u
T=$(cd "$1" && pwd); O=$2; P=$3; shift 3
mkdir -p "$O"
for id in "$@"; do
  python3 $T/tests/soc/adv_mkmut.py $T $O/$id.tree $id || { echo "MUT $id ERROR (mkmut)"; continue; }
  cp $T/tests/soc/adv_*.{S,h,py,sh} $O/$id.tree/tests/soc/ 2>/dev/null
  ADV_PLUS=${ADV_PLUS:-+MAX_CYCLES=4000000} bash $T/tests/soc/adv_trackb.sh $O/$id.tree $O/$id.out $P > $O/$id.txt 2>&1
  v=$(grep '^VERDICT' $O/$id.txt | tr '\n' ' ')
  if grep -q '^VERDICT .* FAIL' $O/$id.txt; then echo "MUT $id KILLED  $v"; else echo "MUT $id SURVIVED  $v"; fi
  rm -rf $O/$id.tree $O/$id.out/sim
done
