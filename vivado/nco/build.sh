#!/bin/bash
# run_nco_sim.sh
# Creates the Vivado project for NCO simulation and opens the GUI.
# Run simulation manually from Flow Navigator inside Vivado.
#
# Usage:
#   chmod +x run_nco_sim.sh
#   ./run_nco_sim.sh
#
# Prerequisites:
#   - Vivado 2022.2 sourced: source /opt/Xilinx/Vivado/2022.2/settings64.sh
#   - input_nco_cos_stimulus.txt in current dir  (from run_and_extract.m)
#   - input_nco_sin_stimulus.txt in current dir  (from run_and_extract.m)
#   - tb_nco.vhd in current dir
#


set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="${SCRIPT_DIR}/nco_sim"
TCL_SCRIPT="${SCRIPT_DIR}/create_nco_sim.tcl"

echo "=== NCO Vivado Project Setup ==="
echo "Script dir  : ${SCRIPT_DIR}"
echo "Project dir : ${PROJ_DIR}"
echo ""

# Check prerequisites
missing=0
for f in tb_nco.vhd input_nco_cos_stimulus.txt input_nco_sin_stimulus.txt; do
    if [ ! -f "${SCRIPT_DIR}/${f}" ]; then
        echo "MISSING: ${f}"
        missing=1
    else
        echo "OK: ${f}"
    fi
done
if [ $missing -eq 1 ]; then
    echo ""
    echo "Generate missing files:"
    echo "  tb_nco.vhd                  : provided alongside this script"
    echo "  input_nco_*_stimulus.txt    : run run_and_extract.m in MATLAB"
    exit 1
fi

# Check Vivado
if ! command -v vivado &> /dev/null; then
    echo ""
    echo "ERROR: vivado not found. Source settings first:"
    echo "  source /opt/Xilinx/Vivado/2022.2/settings64.sh"
    exit 1
fi

# Clean previous project
if [ -d "${PROJ_DIR}" ]; then
    echo ""
    echo "Removing previous project: ${PROJ_DIR}"
    rm -rf "${PROJ_DIR}"
fi
mkdir -p "${PROJ_DIR}"

echo ""
echo "Launching Vivado ..."
echo ""

# Launch Vivado in batch mode, source the setup TCL, then stay open
vivado -mode batch -source "${TCL_SCRIPT}" -tclargs "${PROJ_DIR}"
