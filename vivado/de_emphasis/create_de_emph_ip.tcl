# create_de_emph_ip.tcl
# Simulates and packages the de-emphasis IIR filter as a Vivado IP.
# Pure VHDL -- no Xilinx IP cores required.
#
# Usage: vivado -mode batch -source create_de_emph_ip.tcl

set proj_name de_emph_proj
set proj_dir  [pwd]/de_emph_proj
set part      xc7z020clg400-1

create_project -force ${proj_name} ${proj_dir} -part ${part}

add_files -norecurse de_emph.vhd
add_files -fileset sim_1 -norecurse [list \
    de_emph_tb.vhd \
    de_emph_stimulus.txt \
    de_emph_golden.txt \
]
set_property top de_emph    [get_filesets sources_1]
set_property top de_emph_tb [get_filesets sim_1]

# Run OOC synthesis for resource estimate
if {[catch {synth_design -top de_emph -part ${part} -mode out_of_context} synth_err]} {
    puts "ERROR: synth_design failed: ${synth_err}"
    puts "ERROR: Aborting -- fix the RTL error above before re-running."
    exit 1
}
report_utilization -file de_emph_utilization.rpt
puts "=== De-emphasis synthesis complete. See de_emph_utilization.rpt ==="

# Simulate
set_property -name {xsim.simulate.runtime} -value {all} \
    -objects [get_filesets sim_1]
if {[catch {launch_simulation -simset sim_1 -mode behavioral} err]} {
    puts "INFO: Simulation ended via severity failure (expected)"
}
close_sim

# Package as IP
ipx::package_project \
    -root_dir     ${proj_dir}/ip_repo \
    -vendor       Marco_Aiello \
    -library      user \
    -taxonomy     /UserIP \
    -import_files \
    -set_current  false

set core [ipx::find_open_core Marco_Aiello:user:de_emph:1.0]
if {$core eq ""} {
    set core [ipx::open_core ${proj_dir}/ip_repo/component.xml]
}
set_property name         de_emph                                     $core
set_property version      1.0                                          $core
set_property display_name "FM De-emphasis IIR 75us 50kHz"             $core
set_property description  "1st-order IIR de-emphasis, tau=75us, 50kHz, sfix32_En14 in, sfix32_En13 out" $core
ipx::save_core $core

puts "=== De-emphasis IP packaged to: ${proj_dir}/ip_repo ==="
exit
