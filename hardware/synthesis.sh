#!/usr/bin/env bash
#
# Usage (UCSD LinuxCloud):
#   hardware/synthesis.sh                          # same as: hardware/synthesis.sh baseline
#   hardware/synthesis.sh baseline                 # dense 8x8 design in hardware/baseline/
#   hardware/synthesis.sh alpha_nm                 # alpha_nm RTL, dense build (SPARSE_NM=0)
#   SPARSE_NM=1 hardware/synthesis.sh alpha_nm     # alpha_nm RTL, 2:4 build (4x8 array)

set -euo pipefail

# Load Quartus on UCSD LinuxCloud
module load quartus-19.1

# Select hardware implementation
VARIANT="${1:-baseline}"
HW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VARIANT_DIR="$HW_DIR/$VARIANT"

# Create synthesis directory
mkdir -p "$VARIANT_DIR/quartus_reports"
cd "$VARIANT_DIR/quartus_reports"

# Remove leftovers from a previous (possibly failed) run
rm -rf db incremental_db output_files
rm -f corelet.qpf corelet.qsf corelet.sdc setup.tcl

# Generate Quartus project configuration
cat > setup.tcl <<'EOF'
package require ::quartus::project

project_new corelet -overwrite

# FPGA device
set_global_assignment -name FAMILY "Cyclone IV GX"
set_global_assignment -name DEVICE EP4CGX150DF31I7AD
set_global_assignment -name TOP_LEVEL_ENTITY corelet
set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files

# Add synthesizable RTL files
foreach f [glob -nocomplain ../verilog/*.v ../verilog/*.sv] {

    set name [file rootname [file tail $f]]

    # Exclude testbench, external SRAMs and core
    if {[string match "*tb*" $name] ||
        [string match "sram*" $name] ||
        $name eq "core"} {
        continue
    }

    if {[file extension $f] eq ".sv"} {
        set_global_assignment -name SYSTEMVERILOG_FILE $f
    } else {
        set_global_assignment -name VERILOG_FILE $f
    }
}

# Timing constraints
set_global_assignment -name SDC_FILE corelet.sdc

# 2:4 build when run as SPARSE_NM=1 hardware/synthesis.sh alpha_nm
if {[info exists ::env(SPARSE_NM)] && $::env(SPARSE_NM) == 1} {
    set_parameter -name SPARSE_NM 1
}

export_assignments
project_close
EOF

# Generate clock constraints (100 MHz target)
cat > corelet.sdc <<'EOF'
create_clock -name clk -period 10.000 [get_ports {clk}]
derive_clock_uncertainty
EOF

# Create project
quartus_sh -t setup.tcl

# Synthesis, placement, routing and timing analysis
quartus_sh --flow compile corelet

# Power analysis with 20% input activity
quartus_pow corelet --no_input_file \
    --default_input_io_toggle_rate=20%

# Copy required Quartus reports
for report in fit flow map pow sta; do
    cp "output_files/corelet.$report.rpt" .
done

# Remove generated compilation files
rm -rf db incremental_db output_files

# Remove generated project configuration
rm -f corelet.qpf corelet.qsf corelet.sdc setup.tcl
rm -f corelet.asm.rpt

echo "Quartus reports generated for $VARIANT"

echo "Quartus reports generated for $VARIANT"
