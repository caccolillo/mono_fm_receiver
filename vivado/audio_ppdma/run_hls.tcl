# run_hls.tcl — Audio Ping-Pong DMA HLS build
open_project -reset audio_ppdma_prj
set_top audio_ppdma

add_files audio_ppdma.cpp
add_files -tb audio_ppdma_tb.cpp

open_solution -reset "solution1"
set_part {xczu3eg-sbva484-1-i}
create_clock -period 10 -name default

puts "--- C Simulation ---"
csim_design

puts "--- RTL Synthesis ---"
csynth_design

puts "--- C/RTL Co-Simulation ---"
cosim_design

puts "--- Export IP ---"
export_design -format ip_catalog \
    -description "Audio ping-pong DMA: fm_demod audio capture into ping/pong DDR buffers with destination mirror, GPIO-driven config" \
    -vendor "Marco_Aiello" \
    -version "1.0"

exit
