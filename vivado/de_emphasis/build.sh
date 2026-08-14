#!/bin/bash
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
for f in de_emph.vhd de_emph_tb.vhd \
          de_emph_stimulus.txt de_emph_golden.txt; do
    [ ! -f "$f" ] && echo "MISSING: $f" && exit 1
    echo "OK: $f"
done
echo "=== Building De-emphasis IIR (pure VHDL) ==="
vivado -mode batch -source create_de_emph_ip.tcl \
       -log de_emph_vivado.log -journal de_emph_vivado.jou
echo "=== Done ==="
