#!/bin/bash
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
for f in audio_lpf.vhd audio_lpf_tb.vhd audio_lpf.coe \
          audio_lpf_stimulus.txt audio_lpf_golden.txt; do
    [ ! -f "$f" ] && echo "MISSING: $f" && exit 1
    echo "OK: $f"
done
echo "=== Building Audio LPF (Vivado FIR Compiler) ==="
vivado -mode batch -source create_audio_lpf_ip.tcl \
       -log audio_lpf_vivado.log -journal audio_lpf_vivado.jou
echo "=== Done ==="
