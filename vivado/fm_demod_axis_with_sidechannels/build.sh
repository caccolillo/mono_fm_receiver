#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo "=== FM Demod IP Build ==="
echo "Directory: ${SCRIPT_DIR}"

stdbuf -oL -eL vivado -mode batch \
    -source fm_demod_ip.tcl \
    -tclargs "${SCRIPT_DIR}" \
    -log fm_demod_vivado.log \
    -journal fm_demod_vivado.jou

echo "=== Done ==="
