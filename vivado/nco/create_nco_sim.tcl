# create_nco_sim.tcl
# Vivado 2022.2 project setup for NCO (DDS Compiler v6.0) simulation.
#
# This script creates the project, configures the IP, and adds the
# testbench. It then opens the Vivado GUI. From there:
#   1. Flow Navigator -> Simulation -> Run Simulation -> Run Behavioural Simulation
#   2. Check the Tcl console for PASS/FAIL verdict
#   3. DUT output files appear in the xsim working directory
#
# Usage:
#   vivado -mode gui -source create_nco_sim.tcl \
#          -tclargs <proj_dir> <script_dir>
#
# or from within a running Vivado Tcl console:
#   source create_nco_sim.tcl
#   (set proj_dir and script_dir at the top first)
#


# ── Arguments ─────────────────────────────────────────────────────────────
# When called with -tclargs these are populated automatically.
# When sourced interactively, set them here:
if {[llength $argv] >= 2} {
    set proj_dir   [lindex $argv 0]
    set script_dir [lindex $argv 1]
} else {
    # Edit these for interactive use
    set proj_dir   "/home/caccolillo/FM_RECEIVER/vivado/nco"
    set script_dir "/home/caccolillo/FM_RECEIVER/vivado"
}

set proj_name "nco_sim"
set part      "xc7z010clg400-1"   ;# Zybo Z7-10
                                   ;# Arty A7-100T : xc7a100tcsg324-1
                                   ;# Ultra96-V2   : xczu3eg-sbva484-1-i

puts "=== NCO Project Setup ==="
puts "Project dir : ${proj_dir}"
puts "Script dir  : ${script_dir}"
puts "Part        : ${part}"

# ── 1. Create project ──────────────────────────────────────────────────────
create_project ${proj_name} ${proj_dir} -part ${part} -force
set_property target_language    VHDL [current_project]
set_property simulator_language VHDL [current_project]

# ── 2. DDS Compiler v6.0 ──────────────────────────────────────────────────
puts "\n--- Instantiating DDS Compiler v6.0 ---"

create_ip \
    -name        dds_compiler \
    -vendor      xilinx.com \
    -library     ip \
    -version     6.0 \
    -module_name dds_compiler_0

# Parameters set individually in dependency order (confirmed in Vivado 2022.2)
# Step 1: entry mode and clock
set_property CONFIG.Parameter_Entry {System_Parameters} [get_ips dds_compiler_0]
set_property CONFIG.PartsPresent    {Phase_Generator_and_SIN_COS_LUT} [get_ips dds_compiler_0]
set_property CONFIG.DDS_Clock_Rate  {100} [get_ips dds_compiler_0]

# Step 2: output type and target frequency
# Output_Frequency1 in MHz: 0.01 = 10 kHz
set_property CONFIG.Output_Selection  {Sine_and_Cosine} [get_ips dds_compiler_0]
set_property CONFIG.Output_Frequency1 {0.01}            [get_ips dds_compiler_0]
set_property CONFIG.Phase_Increment   {Fixed}           [get_ips dds_compiler_0]

# Step 3: quality — SFDR=96 dB drives Phase_Width=24, Output_Width=16
set_property CONFIG.Spurious_Free_Dynamic_Range {96}        [get_ips dds_compiler_0]
set_property CONFIG.Amplitude_Mode              {Full_Range} [get_ips dds_compiler_0]
set_property CONFIG.Noise_Shaping               {None}       [get_ips dds_compiler_0]
set_property CONFIG.Memory_Type                 {Auto}       [get_ips dds_compiler_0]
set_property CONFIG.DSP48_Use                   {Maximal}    [get_ips dds_compiler_0]

# Step 4: optional ports
# No S_AXIS_CONFIG (fixed frequency — no dynamic retuning)
# No Has_Phase_Out  (phase output not needed)
set_property CONFIG.Has_Phase_Out  {false}        [get_ips dds_compiler_0]
set_property CONFIG.Has_ARESETn    {true}         [get_ips dds_compiler_0]
set_property CONFIG.DATA_Has_TLAST {Not_Required} [get_ips dds_compiler_0]

# Step 5: latency
set_property CONFIG.Latency_Configuration {Configurable} [get_ips dds_compiler_0]
set_property CONFIG.Latency               {8}            [get_ips dds_compiler_0]

# Verify computed widths
set pw [get_property CONFIG.Phase_Width  [get_ips dds_compiler_0]]
set ow [get_property CONFIG.Output_Width [get_ips dds_compiler_0]]
puts "--- DDS configured ---"
puts "    Phase_Width  : ${pw}  (expected 24)"
puts "    Output_Width : ${ow}  (expected 16)"
if {$ow != 16} {
    puts "WARNING: Output_Width=${ow} != 16."
    puts "         tb_nco.vhd expects 16-bit output — adjust SFDR if needed."
}

# Generate simulation model
generate_target {instantiation_template simulation} [get_ips dds_compiler_0]
generate_target simulation [get_ips dds_compiler_0]
export_ip_user_files -of_objects [get_ips dds_compiler_0] -no_script -quiet -force
puts "--- IP generation complete ---"

# ── 3. Add wrapper and testbench ─────────────────────────────────────────
# nco_wrapper.vhd: synthesisable wrapper (goes into sources_1)
set wrapper_file "${script_dir}/nco_wrapper.vhd"
if {![file exists ${wrapper_file}]} {
    error "Wrapper not found: ${wrapper_file}"
}
add_files -norecurse ${wrapper_file}
set_property file_type {VHDL} [get_files ${wrapper_file}]
update_compile_order -fileset sources_1

# tb_nco.vhd: simulation only (goes into sim_1)
set tb_file "${script_dir}/tb_nco.vhd"
if {![file exists ${tb_file}]} {
    error "Testbench not found: ${tb_file}"
}
add_files -fileset sim_1 -norecurse ${tb_file}
set_property file_type {VHDL} [get_files ${tb_file}]
update_compile_order -fileset sim_1
set_property top     tb_nco         [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]

# Simulation runtime: 10000 samples × 400 cycles × 10 ns + margin = 41 ms
set_property -name {xsim.simulate.runtime}          -value {41ms}  -objects [get_filesets sim_1]
set_property -name {xsim.simulate.log_all_signals}  -value {false} -objects [get_filesets sim_1]

puts "--- Testbench added: ${tb_file} ---"
puts "    Top entity : tb_nco"
puts "    Runtime    : 41 ms"

# ── 4. Copy golden vectors to xsim working directory ─────────────────────
# xsim looks for files relative to its working directory:
# <proj>/<proj>.sim/sim_1/behav/xsim/
set xsim_dir "${proj_dir}/${proj_name}.sim/sim_1/behav/xsim"
file mkdir ${xsim_dir}

foreach vec_file {
    input_nco_cos_stimulus.txt
    input_nco_sin_stimulus.txt
} {
    set src "${script_dir}/${vec_file}"
    if {[file exists ${src}]} {
        file copy -force ${src} "${xsim_dir}/${vec_file}"
        puts "--- Copied ${vec_file} -> xsim dir ---"
    } else {
        puts "WARNING: ${src} not found."
        puts "         Run run_and_extract.m in MATLAB to generate vectors."
    }
}

# ── 5. Package nco_wrapper as IP core ────────────────────────────────────
set ip_repo "${script_dir}/ip_repo/nco_v1_0"
file mkdir ${ip_repo}
puts "\n--- Packaging NCO IP ---"
puts "    Output: ${ip_repo}"

ipx::package_project \
    -root_dir      ${ip_repo} \
    -vendor        "marco-aiello" \
    -library       "fm_receiver" \
    -taxonomy      "/UserIP" \
    -import_files \
    -set_current   false

set ip [ipx::open_core "${ip_repo}/component.xml"]
set_property name            {nco}             $ip
set_property version         {1.0}             $ip
set_property display_name    {FM Receiver NCO} $ip
set_property description     {Fixed 10 kHz NCO. Wraps DDS Compiler v6.0. Separate M_AXIS_COS and M_AXIS_SIN AXI4-Stream outputs.} $ip

ipx::infer_bus_interfaces xilinx.com:interface:axis_rtl:1.0 $ip

foreach intf_name {M_AXIS_COS M_AXIS_SIN} {
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
# ipx::close_core is not valid in Vivado 2022.2 — core stays open until
# the project is closed or another core is opened. This is harmless.

set_property ip_repo_paths ${script_dir}/ip_repo [current_project]
update_ip_catalog -rebuild
puts "--- IP packaged and added to catalogue ---"
# Close the project and exit cleanly
close_project
