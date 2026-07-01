# create_freq_corr_sim.tcl
# Vivado 2022.2 project setup for freq_corr simulation and IP packaging.
#
# Usage:
#   vivado -mode gui -source create_freq_corr_sim.tcl \
#          -tclargs <proj_dir> <script_dir>
#
# Marco Aiello, 2024

if {[llength $argv] >= 2} {
    set proj_dir   [lindex $argv 0]
    set script_dir [lindex $argv 1]
} else {
    set proj_dir   "/home/caccolillo/FM_RECEIVER/vivado/freq_corr"
    set script_dir "/home/caccolillo/FM_RECEIVER/vivado"
}

set proj_name "freq_corr"
set part      "xc7z020clg400-1"

puts "=== Freq Corr Project Setup ==="
puts "Project : ${proj_dir}/${proj_name}"
puts "Sources : ${script_dir}"

# ── 1. Create project ──────────────────────────────────────────────────────
create_project ${proj_name} ${proj_dir} -part ${part} -force
set_property target_language    VHDL [current_project]
set_property simulator_language VHDL [current_project]

# ── 2. Add freq_corr source ───────────────────────────────────────────────
set src_file "${script_dir}/freq_corr.vhd"
if {![file exists ${src_file}]} {
    error "Source not found: ${src_file}"
}
add_files -norecurse ${src_file}
set_property file_type {VHDL} [get_files ${src_file}]
set_property FILE_TYPE {VHDL 2008} [get_files ${src_file}]
update_compile_order -fileset sources_1
puts "--- Added: freq_corr.vhd ---"

# ── 3. Add testbench ──────────────────────────────────────────────────────
set tb_file "${script_dir}/tb_freq_corr.vhd"
if {![file exists ${tb_file}]} {
    error "Testbench not found: ${tb_file}"
}
add_files -fileset sim_1 -norecurse ${tb_file}
set_property file_type {VHDL} [get_files ${tb_file}]
set_property FILE_TYPE {VHDL 2008} [get_files ${tb_file}]
update_compile_order -fileset sim_1
set_property top     tb_freq_corr   [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]

# Runtime: 10000 samples × 400 cycles × 10 ns + margin = 41 ms
set_property -name {xsim.simulate.runtime}         -value {41ms}  -objects [get_filesets sim_1]
set_property -name {xsim.simulate.log_all_signals} -value {false} -objects [get_filesets sim_1]
puts "--- Added: tb_freq_corr.vhd ---"

# ── 4. Copy golden vectors ────────────────────────────────────────────────
set xsim_dir "${proj_dir}/${proj_name}.sim/sim_1/behav/xsim"
file mkdir ${xsim_dir}

foreach vec_file {
    input_i_stimulus.txt
    input_q_stimulus.txt
    input_nco_cos_stimulus.txt
    input_nco_sin_stimulus.txt
    freqcorr_i_golden.txt
    freqcorr_q_golden.txt
} {
    set src "${script_dir}/${vec_file}"
    if {[file exists ${src}]} {
        file copy -force ${src} "${xsim_dir}/${vec_file}"
        puts "--- Copied ${vec_file} ---"
    } else {
        puts "WARNING: ${src} not found — run run_and_extract.m in MATLAB"
    }
}

# ── 5. Package as IP core ─────────────────────────────────────────────────
set ip_repo "${script_dir}/ip_repo/freq_corr_v1_0"
file mkdir ${ip_repo}
puts "\n--- Packaging freq_corr IP ---"

ipx::package_project \
    -root_dir     ${ip_repo} \
    -vendor       "marco-aiello" \
    -library      "fm_receiver" \
    -taxonomy     "/UserIP" \
    -import_files \
    -set_current  false

set ip [ipx::open_core "${ip_repo}/component.xml"]
set_property name            {freq_corr}                      $ip
set_property version         {1.0}                            $ip
set_property display_name    {FM Receiver Frequency Corrector} $ip
set_property description     {Multiplies IQ input by NCO cos/sin to shift carrier to DC. Ic=I*cos-Q*sin, Qc=I*sin+Q*cos. Inputs sfix16_En15, outputs sfix18_En17. 2-cycle pipeline latency.} $ip

ipx::infer_bus_interfaces xilinx.com:interface:axis_rtl:1.0 $ip

foreach intf_name {S_AXIS_IQ S_AXIS_NCO M_AXIS_IC M_AXIS_QC} {
    set intf [ipx::get_bus_interfaces $intf_name -of_objects $ip]
    if {$intf ne ""} {
        ipx::add_bus_parameter ASSOCIATED_CLOCKS $intf
        set_property value aclk \
            [ipx::get_bus_parameters ASSOCIATED_CLOCKS -of_objects $intf]
    }
}

ipx::create_xgui_files  $ip
ipx::update_checksums    $ip
ipx::check_integrity -quiet $ip
ipx::save_core           $ip

set_property ip_repo_paths ${script_dir}/ip_repo [current_project]
update_ip_catalog -rebuild
puts "--- freq_corr IP packaged: ${ip_repo} ---"

# ── 6. Report ─────────────────────────────────────────────────────────────
puts "\n=== Project ready ==="
puts "To simulate:"
puts "  Flow Navigator -> Simulation -> Run Simulation -> Run Behavioural Simulation"
puts "  Check Tcl console for IC: PASS / QC: PASS"
puts ""
puts "IP location : ${ip_repo}"
puts "Add to other projects: Tools->Settings->IP->Repository->${script_dir}/ip_repo"
