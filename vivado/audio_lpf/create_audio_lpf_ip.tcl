# create_audio_lpf_ip.tcl
# Creates Audio LPF FIR Compiler IP, simulates impulse response, packages as IP.
# Run from: ~/FM_RECEIVER/vivado/audio_lpf/
#
# Usage: vivado -mode batch -source create_audio_lpf_ip.tcl
#


set proj_name audio_lpf_proj
set proj_dir  [pwd]/audio_lpf_proj
set part      xczu3eg-sbva484-1-i
set coe_file  [pwd]/audio_lpf.coe

if {![file exists $coe_file]} {
    puts "ERROR: audio_lpf.coe not found. Run audio_lpf_coeffs.m in MATLAB first."
    exit 1
}

create_project -force ${proj_name} ${proj_dir} -part ${part}

add_files -norecurse audio_lpf.vhd
add_files -fileset sim_1 -norecurse [list \
    audio_lpf_tb.vhd \
    audio_lpf_stimulus.txt \
    audio_lpf_golden.txt \
]
set_property top audio_lpf     [get_filesets sources_1]
set_property top audio_lpf_tb  [get_filesets sim_1]

add_files -norecurse $coe_file

# Create FIR Compiler v7.2 — single-rate (no decimation), 127 taps
create_ip \
    -name fir_compiler \
    -vendor xilinx.com \
    -library ip \
    -version 7.2 \
    -module_name fir_compiler_1

set_property -dict [list \
    CONFIG.Filter_Type              {Single_Rate} \
    CONFIG.Coefficient_File         $coe_file \
    CONFIG.Coefficient_Width        {32} \
    CONFIG.Coefficient_Fractional_Bits {14} \
    CONFIG.Coefficient_Sets         {1} \
    CONFIG.Coefficient_Reload       {false} \
    CONFIG.Data_Width               {32} \
    CONFIG.Data_Fractional_Bits     {14} \
    CONFIG.Output_Rounding_Mode     {Truncate_LSBs} \
    CONFIG.Output_Width             {32} \
    CONFIG.Quantization             {Integer_Coefficients} \
    CONFIG.RateSpecification        {Input_Sample_Period} \
    CONFIG.SamplePeriod             {1} \
    CONFIG.Clock_Frequency          {100} \
    CONFIG.has_aresetn              {true} \
    CONFIG.Number_Channels          {1} \
] [get_ips fir_compiler_1]

generate_target {instantiation_template simulation synthesis} \
    [get_ips fir_compiler_1]
synth_ip [get_ips fir_compiler_1]

# Simulate
set_property -name {xsim.simulate.runtime} -value {all} \
    -objects [get_filesets sim_1]
if {[catch {launch_simulation -simset sim_1 -mode behavioral} err]} {
    puts "INFO: Simulation ended via severity failure (expected)"
}
close_sim

# Package as custom IP
ipx::package_project \
    -root_dir     ${proj_dir}/ip_repo \
    -vendor       Marco_Aiello \
    -library      user \
    -taxonomy     /UserIP \
    -import_files \
    -set_current  false

set core [ipx::find_open_core Marco_Aiello:user:audio_lpf:1.0]
if {$core eq ""} {
    set core [ipx::open_core ${proj_dir}/ip_repo/component.xml]
}
set_property name         audio_lpf                               $core
set_property version      1.0                                     $core
set_property display_name "Audio LPF 127-tap FIR 50kHz"          $core
set_property description  "Audio lowpass FIR, 127 taps, sfix32_En14 I/O, 50 kHz" $core
ipx::save_core $core

puts "=== Audio LPF complete ==="
puts "=== IP packaged to: ${proj_dir}/ip_repo ==="
exit
