# run_hls.tcl — I/Q Ping-Pong Feeder HLS build
open_project -reset iq_ppdma_prj
set_top iq_ppdma

add_files iq_ppdma.cpp
add_files -tb iq_ppdma_tb.cpp

open_solution -reset "solution1"
set_part {xc7z010clg400-1}
create_clock -period 10 -name default

puts "--- C Simulation ---"
csim_design

puts "--- RTL Synthesis ---"
csynth_design

puts "--- C/RTL Co-Simulation ---"
cosim_design

puts "--- Export IP ---"
export_design -format ip_catalog \
    -description "I/Q ping-pong feed: reads packed I/Q source buffers from DDR and streams them to fm_demod's s_axis_i_0/s_axis_q_0, GPIO-driven config" \
    -vendor "Marco_Aiello" \
    -version "1.0"

exit
