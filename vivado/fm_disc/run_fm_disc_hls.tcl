# run_fm_disc_hls.tcl — FM Discriminator HLS build
open_project -reset fm_disc_prj
set_top fm_disc

add_files fm_disc.cpp
add_files -tb fm_disc_tb.cpp
add_files -tb fm_disc_ic_stimulus.txt
add_files -tb fm_disc_qc_stimulus.txt
add_files -tb fm_disc_golden.txt

open_solution -reset "solution1"
set_part {xc7z020clg400-1}
create_clock -period 10 -name default

puts "--- C Simulation ---"
csim_design

puts "--- RTL Synthesis ---"
csynth_design

puts "--- C/RTL Co-Simulation ---"
cosim_design

puts "--- Export IP ---"
export_design -format ip_catalog \
    -description "FM Discriminator" \
    -vendor "Marco_Aiello" \
    -version "1.0"

exit
