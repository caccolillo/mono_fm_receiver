#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

for f in audio_ppdma.cpp audio_ppdma.h audio_ppdma_tb.cpp; do
    [ ! -f "${f}" ] && echo "MISSING: ${f}" && exit 1
    echo "OK: ${f}"
done

echo "=== Building Audio Ping-Pong DMA HLS ==="
vitis_hls -f run_hls.tcl
echo "=== Done ==="
