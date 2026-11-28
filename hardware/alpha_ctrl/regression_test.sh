#!/usr/bin/env bash
# Regression for alpha_ctrl: the real layer data plus N random seeds.
#
# Usage (from anywhere, with numpy available):
#   hardware/alpha_ctrl/regression_test.sh              # dense: real data + 10 random seeds (as before)
#   hardware/alpha_ctrl/regression_test.sh 25           # dense: real data + 25 random seeds
#   hardware/alpha_ctrl/regression_test.sh 10 nm        # 2:4: 10 seeds --dense on the dense build
#                                                       #      + 10 seeds compressed on the SPARSE_NM=1 build
#   hardware/alpha_ctrl/regression_test.sh 10 all       # dense + nm (core_tb.v, as before)
#   hardware/alpha_ctrl/regression_test.sh 10 tiled     # core_tiled_tb.v, testbench-driven tile loops:
#                                                       #   real data + N seeds x TILED_SHAPES, dense and 2:4
#   hardware/alpha_ctrl/regression_test.sh 10 ctrl      # core_tiled_tb.v -DUSE_CTRL (FSM runs the tile loops):
#                                                       #   real data + N seeds x (CTRL_SHAPES + TILED_SHAPES),
#                                                       #   dense and 2:4;
#                                                       #   each case must also give a cycle trace identical
#                                                       #   to the testbench-driven run
#   hardware/alpha_ctrl/regression_test.sh 10 nm16      # stage 3b: row=16 SPARSE_NM=1 (8x8 compressed array,
#                                                       #   16 channels per input tile): N seeds x NM16_SHAPES,
#                                                       #   testbench-driven and FSM, traces must be identical
#   hardware/alpha_ctrl/regression_test.sh 10 opt       # FSM with cycle-saving options (ctrl.sv OPT bits C1-C7):
#                                                       #   each alone (1 2 4 8 16 32 64), C1-C4 (15), C5+C6 (48), C1-C6 (63), all (127), on the
#                                                       #   real data + N seeds x (CTRL_SHAPES + TILED_SHAPES)
#                                                       #   dense and NM16_SHAPES 2:4. Outputs must match;
#                                                       #   traces differ on purpose. Override with CTRL_OPTS="15"
#   hardware/alpha_ctrl/regression_test.sh 10 full      # everything above
#
# FAST_MUX=1 (environment) simulates with test/sim_fast/fifo_mux_2_1.v, a behavioral stand-in for the
# gate-level fifo_mux_2_1.v (~50x faster overall; the RTL files are unchanged). Default: gate level.
#
# Everything runs in a temporary copy of the RTL, so hardware/sys_data/ and the
# repo are never modified. A case passes only if the testbench prints
# "No error detected". On failure the temporary folder with all logs is kept
# and its path printed.

set -euo pipefail

NSEEDS=${1:-10}
MODE=${2:-dense}                    # dense | nm | all | tiled | ctrl | nm16 | opt | full
RUN_DENSE=0; RUN_NM=0; RUN_TILED=0; RUN_CTRL=0; RUN_NM16=0; RUN_OPT=0
CTRL_OPTS=${CTRL_OPTS:-"1 2 4 8 16 32 64 15 48 63 127"}
case "$MODE" in
  dense) RUN_DENSE=1 ;;
  nm)    RUN_NM=1 ;;
  all)   RUN_DENSE=1; RUN_NM=1 ;;
  tiled) RUN_TILED=1 ;;
  ctrl)  RUN_CTRL=1 ;;
  nm16)  RUN_NM16=1 ;;
  opt)   RUN_OPT=1 ;;
  full)  RUN_DENSE=1; RUN_NM=1; RUN_TILED=1; RUN_CTRL=1; RUN_NM16=1; RUN_OPT=1 ;;
  *) echo "unknown mode '$MODE' (dense | nm | all | tiled | ctrl | nm16 | opt | full)"; exit 2 ;;
esac
# "IC OC K H W" (output H x W); every shape must fit the fixed memory map (gen_random_tiled.py checks)
TILED_SHAPES=("16 16 3 4 4" "16 8 3 4 4" "8 16 3 4 4" "8 8 3 6 6" "16 16 1 4 4" "24 16 1 1 64" "64 64 1 8 8")
NM16_SHAPES=("16 8 3 4 4" "16 16 3 4 4" "32 16 3 4 4" "16 8 3 6 6" "16 16 1 4 4" "48 16 1 1 64" "64 64 1 8 8")   # IC % 16 == 0
CTRL_SHAPES=("8 8 3 4 4" "8 8 3 2 5" "8 8 1 8 8" "8 8 1 1 64" "24 24 3 2 5")   # extra shapes for ctrl mode
HW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$HW_DIR/../.." && pwd)"
GEN="$REPO_DIR/software/gen_random.py"
GEN_NM="$REPO_DIR/software/gen_random_nm.py"
GEN_TILED="$REPO_DIR/software/gen_random_tiled.py"
TRACE="$HW_DIR/test/trace_tools.py"
WORK="$REPO_DIR/regression_tmp"      # scratch folder in the repo root
rm -rf "$WORK"                      # start clean every run
mkdir -p "$WORK"
FAILS=0
TOTAL=0

cp -r "$HW_DIR/verilog" "$HW_DIR/test" "$HW_DIR/filelist" "$HW_DIR/filelist_tiled" "$WORK/"
mkdir "$WORK/sys_data"
cd "$WORK"
if [ "${FAST_MUX:-0}" = 1 ]; then                  # simulation-only behavioral mux (see test/sim_fast/)
  cp test/sim_fast/fifo_mux_2_1.v verilog/fifo_mux_2_1.v
  echo "FAST_MUX=1: simulating with the behavioral fifo_mux_2_1 stand-in"
fi

echo "Compiling..."
if [ "$RUN_DENSE" = 1 ] || [ "$RUN_NM" = 1 ]; then
  iverilog -Wall -g2012 -o compiled -c filelist                              # dense build
fi
if [ "$RUN_NM" = 1 ]; then
  iverilog -Wall -g2012 -Pcore_tb.SPARSE_NM=1 -o compiled_nm -c filelist   # 2:4 compressed build
fi
# core_tiled_tb builds, each with the cycle-trace monitor: <out> <extra iverilog args...>
build_tiled () {
  local out=$1; shift
  local path=core_tiled_tb.dut
  case " $* " in *" -DUSE_CTRL "*) path=core_tiled_tb.dut.core_instance ;; esac
  iverilog -Wall -g2012 -s core_tiled_tb -s core_trace_mon -DTRACE_CORE=$path "$@" \
    -o "$out" -c filelist_tiled test/core_trace_mon.v
}
if [ "$RUN_TILED" = 1 ] || [ "$RUN_CTRL" = 1 ]; then
  build_tiled tiled                                              # stage 1, dense
  build_tiled tiled_nm -Pcore_tiled_tb.SPARSE_NM=1               # stage 1, 2:4
fi
if [ "$RUN_CTRL" = 1 ]; then
  build_tiled ctrl -DUSE_CTRL                                    # stage 2 FSM, dense
  build_tiled ctrl_nm -DUSE_CTRL -Pcore_tiled_tb.SPARSE_NM=1     # stage 2 FSM, 2:4
fi
if [ "$RUN_OPT" = 1 ]; then
  for o in $CTRL_OPTS; do
    build_tiled "ctrl_opt$o" -DUSE_CTRL -Pcore_tiled_tb.CTRL_OPT="$o"
    build_tiled "ctrl_nm16_opt$o" -DUSE_CTRL -Pcore_tiled_tb.CTRL_OPT="$o" -Pcore_tiled_tb.row=16 -Pcore_tiled_tb.SPARSE_NM=1
  done
fi
if [ "$RUN_NM16" = 1 ]; then
  build_tiled tiled_nm16 -Pcore_tiled_tb.row=16 -Pcore_tiled_tb.SPARSE_NM=1            # stage 3b, testbench loops
  build_tiled ctrl_nm16 -DUSE_CTRL -Pcore_tiled_tb.row=16 -Pcore_tiled_tb.SPARSE_NM=1  # stage 3b, FSM
fi

# run_case <name> <compiled binary>
run_case () {
  TOTAL=$((TOTAL + 1))
  vvp "$2" "${@:3}" > "sim_$1.log" 2>&1 || true   # a $fatal must count as a FAIL, not stop the run
  if grep -q "No error detected" "sim_$1.log"; then
    echo "PASS  $1"
  else
    echo "FAIL  $1   ($(grep -c 'ERROR' "sim_$1.log" || true) error lines, see sim_$1.log)"
    FAILS=$((FAILS + 1))
  fi
}

# run_ctrl_case <name> <tb-driven binary> <FSM binary> [plusargs...]
# Passes only if both runs pass and their compute-phase cycle traces are identical.
run_ctrl_case () {
  TOTAL=$((TOTAL + 1))
  local name=$1 tb=$2 fsm=$3; shift 3
  vvp "$tb"  "$@" +trace="trace_${name}_tb.txt"  > "sim_${name}_tb.log"  2>&1 || true
  vvp "$fsm" "$@" +trace="trace_${name}_fsm.txt" > "sim_${name}.log" 2>&1 || true
  local why=""
  grep -q "No error detected" "sim_${name}_tb.log" || why="$why tb-driven run failed;"
  grep -q "No error detected" "sim_${name}.log"    || why="$why FSM run failed;"
  local d; d=$(python3 "$TRACE" diff "trace_${name}_tb.txt" "trace_${name}_fsm.txt" 2>&1) || why="$why trace differs;"
  if [ -z "$why" ]; then
    echo "PASS  $name   ($d)"
    rm -f "trace_${name}_tb.txt" "trace_${name}_fsm.txt"
  else
    echo "FAIL  $name  ($why see sim_${name}.log)"
    echo "$d" | head -3
    FAILS=$((FAILS + 1))
  fi
}

if [ "$RUN_DENSE" = 1 ]; then
  # 1) Real layer data from the notebook
  cp "$HW_DIR"/sys_data/input.txt "$HW_DIR"/sys_data/weight.txt "$HW_DIR"/sys_data/psum.txt sys_data/
  run_case real compiled

  # 2) Random dense data, every activation non-zero
  for s in $(seq 1 "$NSEEDS"); do
    python3 "$GEN" sys_data "$s" > /dev/null
    run_case "seed$s" compiled
  done
fi

if [ "$RUN_NM" = 1 ]; then
  # 3) Random 2:4 weights in dense format on the dense build (checks the generator)
  for s in $(seq 1 "$NSEEDS"); do
    python3 "$GEN_NM" sys_data "$s" --dense > /dev/null
    run_case "nm_dense_seed$s" compiled
  done

  # 4) Same 2:4 weights, compressed, on the SPARSE_NM=1 build
  for s in $(seq 1 "$NSEEDS"); do
    python3 "$GEN_NM" sys_data "$s" > /dev/null
    run_case "nm_seed$s" compiled_nm
  done
fi

if [ "$RUN_TILED" = 1 ]; then
  # 5) Testbench-driven tile loops: real data (default layer), then random tiled layers
  cp "$HW_DIR"/sys_data/input.txt "$HW_DIR"/sys_data/weight.txt "$HW_DIR"/sys_data/psum.txt sys_data/
  run_case tiled_real tiled
  for s in $(seq 1 "$NSEEDS"); do
    for shape in "${TILED_SHAPES[@]}"; do
      read -r ic oc k h w <<< "$shape"
      for v in dense nm; do
        bin=tiled; flag=""; [ "$v" = nm ] && { bin=tiled_nm; flag=--nm; }
        python3 "$GEN_TILED" sys_data "$s" --ic "$ic" --oc "$oc" --k "$k" --h "$h" --w "$w" $flag > /dev/null
        # shellcheck disable=SC2046
        run_case "tiled_${v}_${ic}x${oc}_k${k}_${h}x${w}_seed$s" "$bin" $(cat sys_data/plusargs.txt)
      done
    done
  done
fi

if [ "$RUN_CTRL" = 1 ]; then
  # 6) FSM controller (tile loops in RTL) vs the testbench-driven flow
  cp "$HW_DIR"/sys_data/input.txt "$HW_DIR"/sys_data/weight.txt "$HW_DIR"/sys_data/psum.txt sys_data/
  run_ctrl_case ctrl_real tiled ctrl
  for s in $(seq 1 "$NSEEDS"); do
    for shape in "${CTRL_SHAPES[@]}" "${TILED_SHAPES[@]}"; do
      read -r ic oc k h w <<< "$shape"
      for v in dense nm; do
        tb=tiled; fsm=ctrl; flag=""; [ "$v" = nm ] && { tb=tiled_nm; fsm=ctrl_nm; flag=--nm; }
        python3 "$GEN_TILED" sys_data "$s" --ic "$ic" --oc "$oc" --k "$k" --h "$h" --w "$w" $flag > /dev/null
        # shellcheck disable=SC2046
        run_ctrl_case "ctrl_${v}_${ic}x${oc}_k${k}_${h}x${w}_seed$s" "$tb" "$fsm" $(cat sys_data/plusargs.txt)
      done
    done
  done
fi

if [ "$RUN_NM16" = 1 ]; then
  # 7) row=16 2:4 compressed array (16 channels per input tile), testbench-driven vs FSM
  for s in $(seq 1 "$NSEEDS"); do
    for shape in "${NM16_SHAPES[@]}"; do
      read -r ic oc k h w <<< "$shape"
      python3 "$GEN_TILED" sys_data "$s" --row 16 --nm --ic "$ic" --oc "$oc" --k "$k" --h "$h" --w "$w" > /dev/null
      # shellcheck disable=SC2046
      run_ctrl_case "nm16_${ic}x${oc}_k${k}_${h}x${w}_seed$s" tiled_nm16 ctrl_nm16 $(cat sys_data/plusargs.txt)
    done
  done
fi

if [ "$RUN_OPT" = 1 ]; then
  # 8) FSM with cycle-saving options: outputs must still match (cycle traces differ on purpose)
  for o in $CTRL_OPTS; do
    cp "$HW_DIR"/sys_data/input.txt "$HW_DIR"/sys_data/weight.txt "$HW_DIR"/sys_data/psum.txt sys_data/
    run_case "opt${o}_real" "ctrl_opt$o"
    for s in $(seq 1 "$NSEEDS"); do
      for shape in "${CTRL_SHAPES[@]}" "${TILED_SHAPES[@]}"; do
        read -r ic oc k h w <<< "$shape"
        python3 "$GEN_TILED" sys_data "$s" --ic "$ic" --oc "$oc" --k "$k" --h "$h" --w "$w" > /dev/null
        # shellcheck disable=SC2046
        run_case "opt${o}_dense_${ic}x${oc}_k${k}_${h}x${w}_seed$s" "ctrl_opt$o" $(cat sys_data/plusargs.txt)
      done
      for shape in "${NM16_SHAPES[@]}"; do
        read -r ic oc k h w <<< "$shape"
        python3 "$GEN_TILED" sys_data "$s" --row 16 --nm --ic "$ic" --oc "$oc" --k "$k" --h "$h" --w "$w" > /dev/null
        # shellcheck disable=SC2046
        run_case "opt${o}_nm16_${ic}x${oc}_k${k}_${h}x${w}_seed$s" "ctrl_nm16_opt$o" $(cat sys_data/plusargs.txt)
      done
    done
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
