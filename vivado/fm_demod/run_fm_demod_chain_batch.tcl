################################################################################
# run_fm_demod_chain_batch.tcl
#
# Headless batch-mode run of the full-chain testbench (tb_fm_demod_chain.sv)
# against an already-built fm_demod_proj project. No GUI, no waveform
# rendering -- runs to completion (testbench self-terminates via $finish)
# and exits. Faster than GUI mode for long runs since there's no live
# signal display overhead.
#
# Usage:
#   vivado -mode batch -source run_fm_demod_chain_batch.tcl
#
# Run this from the same directory as fm_demod_ip.tcl was run from (i.e.
# the directory containing fm_demod_proj/), with the project already built
# and the sim_1 fileset already configured (testbench + stimulus added).
#
# Marco Aiello, 2024
################################################################################

set proj_dir [pwd]/fm_demod_proj
set proj_xpr "${proj_dir}/fm_demod_proj.xpr"

if { ![file exists $proj_xpr] } {
    puts "ERROR: Project not found at ${proj_xpr}"
    puts "ERROR: Run fm_demod_ip.tcl first to build the project."
    exit 1
}

puts "=== Opening project: ${proj_xpr} ==="
open_project $proj_xpr

# Headless run: no waveform GUI, just compile/elaborate/simulate/exit.
# 'all' lets the testbench's own $finish (after stim_done + capture
# complete) determine when the run actually ends.
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]

puts "\n=== Launching BATCH (headless) behavioral simulation ==="
puts "=== This will run to completion with no GUI / no waveform display ==="

if { [catch {launch_simulation -simset sim_1 -mode behavioral} sim_err] } {
    puts "INFO: Simulation ended via \$finish (expected termination path)"
}

close_sim
puts "\n=== Batch simulation complete. Check the .txt log files for output. ==="
exit
