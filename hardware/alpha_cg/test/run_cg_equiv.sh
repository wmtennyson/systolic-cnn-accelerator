#!/usr/bin/env bash
# Cycle-by-cycle equivalence: baseline vs alpha_cg on the same stimulus.
# Usage: run_cg_equiv.sh [nseeds]   (real data + nseeds random seeds)
#        CG_RTL=<dir> overrides the alpha_cg verilog dir (used for mutation tests).
set -euo pipefail
NSEEDS=${1:-3}
CG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$CG_DIR/../.." && pwd)"
BASE_DIR="$REPO/hardware/baseline"
CG_RTL=${CG_RTL:-$CG_DIR/verilog}
MON="$CG_DIR/test/cg_trace_mon.v"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/b/sys_data" "$WORK/g/sys_data"
cp -r "$BASE_DIR/verilog" "$BASE_DIR/filelist" "$WORK/b/"
cp -r "$CG_RTL" "$WORK/g/verilog"; cp "$CG_DIR/filelist" "$WORK/g/"
(cd "$WORK/b" && iverilog -g2012 -o c -c filelist "$MON")
(cd "$WORK/g" && iverilog -g2012 -o c -c filelist "$MON")
FAILS=0
run () {  # $1 = case name; sys_data already in place in both dirs
  (cd "$WORK/b" && vvp c > log 2>&1); (cd "$WORK/g" && vvp c > log 2>&1)
  if cmp -s "$WORK/b/cg_trace.txt" "$WORK/g/cg_trace.txt"; then
    echo "SAME  $1  ($(grep -c ' W ' "$WORK/b/cg_trace.txt") ofifo writes, $(wc -l < "$WORK/b/cg_trace.txt") lines)"
  else
    echo "DIFF  $1  first difference:"; diff "$WORK/b/cg_trace.txt" "$WORK/g/cg_trace.txt" | head -4
    FAILS=$((FAILS+1))
  fi
}
for d in b g; do cp "$CG_DIR"/sys_data/*.txt "$WORK/$d/sys_data/"; done
run real
for s in $(seq 1 "$NSEEDS"); do
  python3 "$REPO/software/gen_random.py" "$WORK/b/sys_data" "$s" > /dev/null
  cp "$WORK/b/sys_data"/*.txt "$WORK/g/sys_data/"
  run "seed$s"
done
[ "$FAILS" -eq 0 ] && echo "Cycle-equivalent to baseline on all $((NSEEDS+1)) cases." || { echo "$FAILS case(s) differ"; exit 1; }
