#!/usr/bin/env bash
# Regression for core_tb.v: the real layer data plus N random seeds.
#
# Usage (from anywhere, with numpy available):
#   hardware/alpha_nm/regression_test.sh              # dense: real data + 10 random seeds (as before)
#   hardware/alpha_nm/regression_test.sh 25           # dense: real data + 25 random seeds
#   hardware/alpha_nm/regression_test.sh 10 nm        # 2:4: 10 seeds --dense on the dense build
#                                                     #      + 10 seeds compressed on the SPARSE_NM=1 build
#   hardware/alpha_nm/regression_test.sh 10 all       # both of the above
#
# Everything runs in a temporary copy of the RTL, so hardware/sys_data/ and the
# repo are never modified. A case passes only if core_tb.v prints
# "No error detected". On failure the temporary folder with all logs is kept
# and its path printed.

set -euo pipefail

NSEEDS=${1:-10}
MODE=${2:-dense}                    # dense | nm | all
case "$MODE" in dense|nm|all) ;; *) echo "unknown mode '$MODE' (dense | nm | all)"; exit 2 ;; esac
HW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$HW_DIR/../.." && pwd)"
GEN="$REPO_DIR/software/gen_random.py"
GEN_NM="$REPO_DIR/software/gen_random_nm.py"
WORK="$REPO_DIR/regression_tmp"      # scratch folder in the repo root
rm -rf "$WORK"                      # start clean every run
mkdir -p "$WORK"
FAILS=0
TOTAL=0

cp -r "$HW_DIR/verilog" "$HW_DIR/filelist" "$WORK/"
mkdir "$WORK/sys_data"
cd "$WORK"

echo "Compiling..."
iverilog -Wall -g2012 -o compiled -c filelist                              # dense build
if [ "$MODE" != dense ]; then
  iverilog -Wall -g2012 -Pcore_tb.SPARSE_NM=1 -o compiled_nm -c filelist   # 2:4 compressed build
fi

# run_case <name> <compiled binary>
run_case () {
  TOTAL=$((TOTAL + 1))
  vvp "$2" > "sim_$1.log" 2>&1
  if grep -q "No error detected" "sim_$1.log"; then
    echo "PASS  $1"
  else
    echo "FAIL  $1   ($(grep -c 'ERROR' "sim_$1.log" || true) error lines, see sim_$1.log)"
    FAILS=$((FAILS + 1))
  fi
}

if [ "$MODE" != nm ]; then
  # 1) Real layer data from the notebook
  cp "$HW_DIR"/sys_data/input.txt "$HW_DIR"/sys_data/weight.txt "$HW_DIR"/sys_data/psum.txt sys_data/
  run_case real compiled

  # 2) Random dense data, every activation non-zero
  for s in $(seq 1 "$NSEEDS"); do
    python3 "$GEN" sys_data "$s" > /dev/null
    run_case "seed$s" compiled
  done
fi

if [ "$MODE" != dense ]; then
  # 3) Real 2:4 layer data from software/alpha_nm, dense weight format on the dense build
  cp "$HW_DIR"/sys_data_nm/input.txt "$HW_DIR"/sys_data_nm/weight.txt "$HW_DIR"/sys_data_nm/psum.txt sys_data/
  run_case real_nm_dense compiled

  # 4) Same data, compressed weights, on the SPARSE_NM=1 build
  cp "$HW_DIR"/sys_data_nm/weight_nm.txt sys_data/weight.txt
  run_case real_nm compiled_nm

  # 5) Random 2:4 weights in dense format on the dense build (checks the generator)
  for s in $(seq 1 "$NSEEDS"); do
    ...                                     (existing loop, unchanged)
  done

  # 6) Same 2:4 weights, compressed, on the SPARSE_NM=1 build
  for s in $(seq 1 "$NSEEDS"); do
    ...                                     (existing loop, unchanged)
  done
fi

echo "--------------------------------"
if [ "$FAILS" -eq 0 ]; then
  echo "All $TOTAL cases passed."
  rm -rf "$WORK"
else
  echo "$FAILS of $TOTAL cases FAILED. Logs kept in: $WORK"
  exit 1
fi
