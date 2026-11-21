#!/usr/bin/env bash
# Local, light (git only): regenerate pin.sums = sha256 of every pin file the build uses, straight
# from `git show $PIN:path`. `--check` diffs the committed pin.sums against git instead of writing.
set -eu
cd "$(dirname "$0")/.."
PIN=$(cat PIN)
out=$(for f in $(grep -hv '^#' srclist.txt pin_extra.txt); do
        printf '%s  %s\n' "$(git show "$PIN:$f" | sha256sum | cut -d' ' -f1)" "$f"
      done)
if [ "${1:-}" = "--check" ]; then
    printf '%s\n' "$out" | diff - pin.sums && echo "pin.sums matches git $PIN"
else
    printf '%s\n' "$out" > pin.sums
fi
