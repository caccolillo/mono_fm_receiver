#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

for f in fir_dec.vhd fir_dec_tb.vhd fir_dec.coe \
          fir_dec_stimulus.txt fir_dec_golden.txt; do
    [ ! -f "${f}" ] && echo "MISSING: ${f}" && exit 1
    echo "OK: ${f}"
done

echo "=== Building FIR Decimator (Vivado FIR Compiler) ==="
vivado -mode batch -source create_fir_dec_ip.tcl \
       -log fir_dec_vivado.log -journal fir_dec_vivado.jou
echo "=== Done ==="
