#!/usr/bin/env bash
# Regression for core_tb.v: the real layer data plus N random seeds.
#
# Usage (from anywhere, with numpy available):
#   hardware/run_regression.sh            # real data + 10 random seeds
#   hardware/run_regression.sh 25         # real data + 25 random seeds
#
# Everything runs in a temporary copy of the RTL, so hardware/sys_data/ and the
# repo are never modified. A case passes only if core_tb.v prints
# "No error detected". On failure the temporary folder with all logs is kept
# and its path printed.

set -euo pipefail

NSEEDS=${1:-10}
HW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$HW_DIR/../.." && pwd)"
GEN="$REPO_DIR/software/gen_random.py"
WORK="$REPO_DIR/regression_tmp"      # scratch folder in the repo root
rm -rf "$WORK"                      # start clean every run
mkdir -p "$WORK"
FAILS=0

cp -r "$HW_DIR/verilog" "$HW_DIR/filelist" "$WORK/"
mkdir "$WORK/sys_data"
cd "$WORK"

echo "Compiling..."
iverilog -g2012 -o compiled -c filelist

run_case () {
  vvp compiled > "sim_$1.log" 2>&1
  if grep -q "No error detected" "sim_$1.log"; then
    echo "PASS  $1"
  else
    echo "FAIL  $1   ($(grep -c 'ERROR' "sim_$1.log" || true) error lines, see sim_$1.log)"
    FAILS=$((FAILS + 1))
  fi
}

# 1) Real layer data from the notebook
cp "$HW_DIR"/sys_data/input.txt "$HW_DIR"/sys_data/weight.txt "$HW_DIR"/sys_data/psum.txt sys_data/
run_case real

# 2) Random data, every activation non-zero
for s in $(seq 1 "$NSEEDS"); do
  python3 "$GEN" sys_data "$s" > /dev/null
  run_case "seed$s"
done

echo "--------------------------------"
if [ "$FAILS" -eq 0 ]; then
  echo "All $((NSEEDS + 1)) cases passed."
  rm -rf "$WORK"
else
  echo "$FAILS of $((NSEEDS + 1)) cases FAILED. Logs kept in: $WORK"
  exit 1
fi
