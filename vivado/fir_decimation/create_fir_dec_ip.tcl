# create_fir_dec_ip.tcl
# Creates FIR Compiler decimator IP, runs synthesis and simulation.
# Run from the project directory containing all source files.
#
# Usage: vivado -mode batch -source create_fir_dec_ip.tcl
#


set proj_name fir_dec_proj
set proj_dir  [pwd]/fir_dec_proj
set part      xc7z010clg400-1
set coe_file  [pwd]/fir_dec.coe

# Verify .coe file exists
if {![file exists $coe_file]} {
    puts "ERROR: fir_dec.coe not found. Run fir_dec_coeffs.m in MATLAB first."
    exit 1
}

# Create project
create_project -force ${proj_name} ${proj_dir} -part ${part}

# Add source files
add_files -norecurse fir_dec.vhd
add_files -fileset sim_1 -norecurse [list \
    fir_dec_tb.vhd \
    fir_dec_stimulus.txt \
    fir_dec_golden.txt \
]
set_property top fir_dec [get_filesets sources_1]
set_property top fir_dec_tb [get_filesets sim_1]

# Add .coe to IP repository so FIR Compiler can find it
add_files -norecurse $coe_file

# Create FIR Compiler v7.2 IP
create_ip \
    -name fir_compiler \
    -vendor xilinx.com \
    -library ip \
    -version 7.2 \
    -module_name fir_compiler_0

# Configure: decimation R=5, fir1(40,1/5), sfix32_En14 I/O
set_property -dict [list \
    CONFIG.Filter_Type              {Decimation} \
    CONFIG.Decimation_Rate          {5} \
    CONFIG.Coefficient_File         $coe_file \
    CONFIG.Coefficient_Width        {32} \
    CONFIG.Coefficient_Fractional_Bits {14} \
    CONFIG.Coefficient_Sets         {1} \
    CONFIG.Coefficient_Reload       {false} \
    CONFIG.Data_Width               {32} \
    CONFIG.Data_Fractional_Bits     {14} \
    CONFIG.Output_Rounding_Mode     {Convergent_Rounding_to_Even} \
    CONFIG.Output_Width             {32} \
    CONFIG.Quantization             {Integer_Coefficients} \
    CONFIG.RateSpecification        {Input_Sample_Period} \
    CONFIG.SamplePeriod             {1} \
    CONFIG.Clock_Frequency          {100} \
    CONFIG.has_aresetn              {true} \
    CONFIG.Number_Channels          {1} \
] [get_ips fir_compiler_0]

# Generate IP output products
generate_target {instantiation_template simulation synthesis} \
    [get_ips fir_compiler_0]

# Run OOC synthesis on IP
synth_ip [get_ips fir_compiler_0]

# Run behavioural simulation
# severity failure in VHDL stops xsim -- catch the Tcl error it raises
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]
if {[catch {launch_simulation -simset sim_1 -mode behavioral} err]} {
    puts "INFO: Simulation ended via severity failure (expected behaviour)"
}
close_sim

puts "=== FIR Decimator simulation complete ==="
puts "=== Check notes above for TESTBENCH PASSED/FAILED ==="

# Package fir_dec.vhd as a custom IP for use in IP Integrator
ipx::package_project -root_dir ${proj_dir}/ip_repo     -vendor Marco_Aiello     -library user     -taxonomy /UserIP     -import_files     -set_current false

set ip_core [ipx::find_open_core Marco_Aiello:user:fir_dec:1.0]
if {$ip_core eq ""} {
    set ip_core [ipx::open_core ${proj_dir}/ip_repo/component.xml]
}

# Set IP metadata
set_property name          fir_dec          $ip_core
set_property version       1.0              $ip_core
set_property display_name  "FIR Decimator R=5 fir1(40,1/5)" $ip_core
set_property description   "FIR decimation filter, R=5, 41 taps, sfix32_En14 I/O" $ip_core
set_property company_url   "" $ip_core

ipx::save_core $ip_core

puts "=== IP packaged to: ${proj_dir}/ip_repo ==="
puts "=== Add this path to Vivado IP repository in IP Integrator ==="
exit
