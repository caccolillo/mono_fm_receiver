#!/bin/bash
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"

vivado -mode batch -source fm_demod_ip.tcl \
       -log de_emph_vivado.log -journal de_emph_vivado.jou

