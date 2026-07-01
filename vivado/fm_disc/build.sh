#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

for f in fm_disc.cpp fm_disc.h fm_disc_tb.cpp \
          fm_disc_ic_stimulus.txt fm_disc_qc_stimulus.txt fm_disc_golden.txt; do
    [ ! -f "${f}" ] && echo "MISSING: ${f}" && exit 1
    echo "OK: ${f}"
done

echo "=== Building FM Discriminator HLS ==="
vitis_hls -f run_fm_disc_hls.tcl
echo "=== Done ==="
