#!/usr/bin/env bash
# Runs core_tb on the real layer data with cg_duty_mon and prints each gated clock's duty cycle.
set -euo pipefail
HW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
cp -r "$HW_DIR/verilog" "$HW_DIR/filelist" "$HW_DIR/sys_data" "$WORK/"
cd "$WORK"
iverilog -g2012 -o compiled -c filelist "$HW_DIR/test/cg_duty_mon.v"
vvp compiled | grep -E "No error|ERROR|CG duty|^  (l0|array|ofifo|sfu)" | sort -u
rm -rf "$WORK"
