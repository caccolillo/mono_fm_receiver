# ==============================================================================
# Vitis HLS 2022.2 Automation Script - Single-Channel AA LPF
# ==============================================================================
# Create project space
open_project -reset aa_lpf_prj
# Set Top Function
set_top aa_lpf
# Core source dependencies setup
add_files aa_lpf.cpp
# Testbench and input stimulus files setup
# I-channel vectors: hardware is identical for I and Q (single-channel,
# instantiated twice in the block design), so this run fully verifies
# the RTL. Swap to the Q-channel files below if you want a second pass.
add_files -tb aa_lpf_tb.cpp
add_files -tb aa_lpf_i_stimulus.txt
add_files -tb aa_lpf_i_golden.txt
# Solution environment initializing
open_solution -reset "solution1"
# Target Definition: Zybo Z7-20 (xc7z020clg400-1)
set_part {xc7z020clg400-1}
create_clock -period 10 -name default
# Processing Commands Flow
puts "--- Launching Functional C Simulation ---"
csim_design
puts "--- Launching High-Level RTL Synthesis ---"
csynth_design
puts "--- Launching C/RTL Logic Co-Simulation ---"
cosim_design
puts "--- Packing Component IP Blocks ---"
export_design -format ip_catalog -description "AA LPF 129-Tap Filter, single-channel AXI-S" -vendor "Marco_Aiello" -version "1.0"
exit
