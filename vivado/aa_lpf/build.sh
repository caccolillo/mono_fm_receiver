#!/bin/bash
set -e

echo "===================================================="
echo "=== Sourcing Vitis HLS 2022.2 Environment Paths  ==="
echo "===================================================="


echo "=== Executing HLS Compilation Tasks ==="
vitis_hls -f run_hls.tcl

echo "===================================================="
echo "=== Build Actions Completed. IP Generated!        ==="
echo "===================================================="

