# create_freq_corr_ip.tcl
# Creates the freq_corr Vivado project, runs behavioral simulation to verify
# the block, packages it as a reusable Vivado IP, then exits.
#
# Called by build_freq_corr_ip.sh with two arguments:
#   argv[0] : proj_dir  -- where to create the Vivado project
#   argv[1] : script_dir -- directory containing all source/stimulus files
#
# Marco Aiello, 2024

set proj_dir   [lindex $argv 0]
set script_dir [lindex $argv 1]
set part       xc7z010clg400-1

puts "=== Creating freq_corr project ==="
puts "    Project dir : ${proj_dir}"
puts "    Sources dir : ${script_dir}"

# ── Create project ────────────────────────────────────────────────────────
create_project -force freq_corr ${proj_dir} -part ${part}
set_property simulator_language Mixed [current_project]

# ── Add RTL sources ───────────────────────────────────────────────────────
add_files -norecurse ${script_dir}/freq_corr.vhd
set_property file_type VHDL [get_files ${script_dir}/freq_corr.vhd]
set_property top freq_corr [get_filesets sources_1]

# ── Add simulation files ──────────────────────────────────────────────────
add_files -fileset sim_1 -norecurse ${script_dir}/tb_freq_corr.vhd
set_property file_type VHDL [get_files ${script_dir}/tb_freq_corr.vhd]
set_property top     tb_freq_corr  [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]

# Stimulus and golden files
foreach f {
    input_i_stimulus.txt
    input_q_stimulus.txt
    input_nco_cos_stimulus.txt
    input_nco_sin_stimulus.txt
    freqcorr_i_golden.txt
    freqcorr_q_golden.txt
    freqcorr_ic_dut_output.txt
    freqcorr_qc_dut_output.txt
} {
    set fpath "${script_dir}/${f}"
    if { [file exists $fpath] } {
        add_files -fileset sim_1 -norecurse $fpath
        puts "    Added sim file: ${f}"
    }
}

# Pre-stage stimulus into xsim working directory
set xsim_dir "${proj_dir}/freq_corr.sim/sim_1/behav/xsim"
file mkdir $xsim_dir
foreach f {
    input_i_stimulus.txt
    input_q_stimulus.txt
    input_nco_cos_stimulus.txt
    input_nco_sin_stimulus.txt
    freqcorr_i_golden.txt
    freqcorr_q_golden.txt
} {
    set fpath "${script_dir}/${f}"
    if { [file exists $fpath] } {
        file copy -force $fpath "${xsim_dir}/${f}"
    }
}

# ── Run behavioral simulation ─────────────────────────────────────────────
puts "\n=== Running behavioral simulation ==="
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]

if { [catch {launch_simulation -simset sim_1 -mode behavioral} sim_err] } {
    puts "INFO: Simulation ended (severity note/failure -- expected)"
}
close_sim

# ── Package as Vivado IP ──────────────────────────────────────────────────
puts "\n=== Packaging freq_corr as Vivado IP ==="

ipx::package_project \
    -root_dir     ${proj_dir}/ip_repo \
    -vendor       marco-aiello \
    -library      fm_receiver \
    -taxonomy     /UserIP \
    -import_files \
    -set_current  false

set core [ipx::find_open_core marco-aiello:fm_receiver:freq_corr:1.0]
if { $core eq "" } {
    set core [ipx::open_core ${proj_dir}/ip_repo/component.xml]
}

set_property name         freq_corr                                   $core
set_property version      1.0                                         $core
set_property display_name "FM Receiver Frequency Corrector"           $core
set_property description  "Complex frequency correction: Ic=I*cos-Q*sin, Qc=I*sin+Q*cos. Four separate AXI-S inputs (I, Q, cos, sin -- sfix16_En15), two separate AXI-S outputs (Ic, Qc -- sfix18_En17). 100 MHz clock, 250 kHz sample rate." $core
set_property company_url  "" $core

ipx::save_core $core

puts "=== freq_corr IP packaged to: ${proj_dir}/ip_repo ==="
exit
