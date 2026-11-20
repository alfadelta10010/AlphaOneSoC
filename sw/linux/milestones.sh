#!/bin/bash
# wall-clock stamp for every bench-boot.log line; kernel [seconds] x 62.5e6 = core clocks (mtime counts core clocks)
tail -n +1 -f bench-boot.log | while IFS= read -r l; do echo "$(date +%T) | $l"; done >> milestones.log
