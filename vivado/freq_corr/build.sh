#!/bin/bash
# run_freq_corr_sim.sh
# Creates the freq_corr Vivado project and opens the GUI.
#
# Usage:
#   chmod +x run_freq_corr_sim.sh
#   ./run_freq_corr_sim.sh
#
# Prerequisites:
#   - Vivado 2022.2 sourced
#   - freq_corr.vhd, tb_freq_corr.vhd in current dir
#   - input_i_stimulus.txt, input_q_stimulus.txt,
#     input_nco_cos_stimulus.txt, input_nco_sin_stimulus.txt,
#     freqcorr_i_golden.txt, freqcorr_q_golden.txt  (from run_and_extract.m)
#
# Marco Aiello, 2024

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="${SCRIPT_DIR}/freq_corr"

echo "=== Freq Corr Simulation ==="
echo "Script dir : ${SCRIPT_DIR}"
echo "Project dir: ${PROJ_DIR}"
echo ""

missing=0
for f in freq_corr.vhd tb_freq_corr.vhd \
          input_i_stimulus.txt input_q_stimulus.txt \
          input_nco_cos_stimulus.txt input_nco_sin_stimulus.txt \
          freqcorr_i_golden.txt freqcorr_q_golden.txt; do
    if [ ! -f "${SCRIPT_DIR}/${f}" ]; then
        echo "MISSING: ${f}"
        missing=1
    else
        echo "OK     : ${f}"
    fi
done
[ $missing -eq 1 ] && { echo "\nFix missing files then retry."; exit 1; }

if ! command -v vivado &>/dev/null; then
    echo "ERROR: vivado not on PATH"
    exit 1
fi

rm -rf "${PROJ_DIR}"
mkdir -p "${PROJ_DIR}"

echo ""
echo "Launching Vivado..."
vivado -mode gui \
       -source "${SCRIPT_DIR}/create_freq_corr_sim.tcl" \
       -tclargs "${PROJ_DIR}" "${SCRIPT_DIR}"
