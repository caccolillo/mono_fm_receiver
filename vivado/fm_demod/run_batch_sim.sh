#!/bin/bash
################################################################################
# run_batch_sim.sh
#
# Launches the headless batch-mode simulation of the full FM demodulator
# chain (run_fm_demod_chain_batch.tcl) in the background, detached from the
# current shell, with all Vivado/xsim console output redirected to a log
# file. Use this for long runs so the simulation survives a closed terminal
# or SSH session.
#
# Uses 'stdbuf -oL -eL' to force line-buffered (rather than fully-buffered)
# stdout/stderr from the vivado process -- without this, output can appear
# to "go nowhere" with tail -f since a backgrounded, non-interactive process
# typically buffers in large chunks instead of flushing per line.
#
# Usage:
#   ./run_batch_sim.sh
#
# Prerequisites (must already be done before running this):
#   1. fm_demod_ip.tcl has been run (project + block design + wrapper built,
#      testbench + stimulus staged in the sim_1 fileset).
#   2. gen_fm_demod_stimulus.m has been run in MATLAB (stimulus files exist).
#
# After launching, monitor progress with:
#   tail -f batch_run.log
#
# Marco Aiello, 2024
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

TCL_SCRIPT="run_fm_demod_chain_batch.tcl"
LOG_FILE="batch_run.log"

if [ ! -f "${TCL_SCRIPT}" ]; then
    echo "ERROR: ${TCL_SCRIPT} not found in ${SCRIPT_DIR}"
    exit 1
fi

if [ ! -d "fm_demod_proj" ]; then
    echo "ERROR: fm_demod_proj not found in ${SCRIPT_DIR}"
    echo "ERROR: Run fm_demod_ip.tcl first to build the project."
    exit 1
fi

echo "=== Launching batch simulation in the background ==="
echo "    Tcl script : ${TCL_SCRIPT}"
echo "    Log file   : ${LOG_FILE}"
echo ""
echo "Monitor progress with:"
echo "    tail -f ${LOG_FILE}"
echo ""

nohup stdbuf -oL -eL vivado -mode batch -source "${TCL_SCRIPT}" > "${LOG_FILE}" 2>&1 &
disown

echo "=== Launched (PID $!) ==="
echo "=== This will take a substantial amount of time to complete ==="
