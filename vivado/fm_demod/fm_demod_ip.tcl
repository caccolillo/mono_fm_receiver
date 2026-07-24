# fm_demod_ip.tcl
# Top-level project build for the complete FM demodulator.
# Creates a Vivado project, registers the locally-packaged custom IP
# repository (NCO, FreqCorr, AA LPF x2, FM discriminator, FIR decimator,
# Audio LPF, De-emphasis -- everything built and packaged in sibling
# directories), sources the block design that wires them together, then
# generates the HDL wrapper for the block design so it can be added to a
# synthesis run or a top-level project.
#
# Prerequisite: each sub-block's create_*_ip.tcl script must already have
# been run so its packaged IP (component.xml + ip_repo) exists on disk --
# this script only consumes those packaged IPs, it does not build them.
#
# ALSO stages the sim_1 fileset (tb_fm_demod_chain.sv + stimulus files),
# so a single run of this script leaves the project genuinely ready for
# run_fm_demod_chain_batch.tcl / run_batch_sim.sh -- no separate manual
# step to forget. This used to be a standalone stage_sim_fileset.tcl that
# had to be remembered and run afterward; folded in here after that gap
# caused a stale-project mixup during Ultra96-V2 bring-up (a fresh
# rebuild's project had no sim_1 configured yet, so the "next" batch sim
# run silently did nothing new and left old .txt output files looking
# like a fresh, still-broken result).
#
# If s_axis_i_stimulus.txt / s_axis_q_stimulus.txt don't exist yet (i.e.
# gen_fm_demod_stimulus.m hasn't been run), the IP build/package still
# completes normally -- only the sim staging step is skipped, with a
# clear message explaining why and what to run to fix it.
#
# Usage: vivado -mode batch -source fm_demod_ip.tcl
#


# Project identifiers and target part Ultra96 v2
set proj_name fm_demod_proj
set proj_dir  [pwd]/fm_demod_proj
set part      xczu3eg-sbva484-1-i

# Fresh project, overwriting any previous run in the same directory
create_project -force ${proj_name} ${proj_dir} -part ${part}

# Sub-block IPs are VHDL; the full-chain testbench (tb_fm_demod_chain.sv)
# is SystemVerilog. Mixed-language simulation requires this set so xsim
# elaborates both without complaint.
set_property simulator_language Mixed [current_project]

# Point Vivado at the local IP repository (one level up) where each
# sub-block's packaged IP lives, then rescan so they appear in the
# IP Catalog and can be instantiated by name in the block design.
set_property  ip_repo_paths  ../ [current_project]
# -rebuild, not a bare refresh: without it, Vivado can silently keep
# serving a cached IP definition for an unchanged VLNV (e.g. aa_lpf:1.0)
# even after the underlying packaged IP genuinely changed on disk --
# confirmed as the cause of one stale-result mixup during Ultra96-V2
# bring-up.
update_ip_catalog -rebuild

# bd.tcl contains the actual block design: instantiates each custom IP
# (NCO, FreqCorr, AA LPF x2 for I/Q, FM discriminator, FIR decimator,
# Audio LPF, De-emphasis) and wires the AXI-Stream interfaces between
# them per the FM receiver signal chain. Kept in a separate file so the
# wiring can be edited/regenerated independently of this top-level script.
source bd.tcl

# Generate a synthesizable Verilog wrapper around the block design so it
# can be used as (or instantiated within) a top-level design for
# synthesis and bitstream generation.
make_wrapper -files [get_files ./fm_demod_proj/fm_demod_proj.srcs/sources_1/bd/fm_demod/fm_demod.bd] -top

# Add the generated wrapper to the project sources.
add_files -norecurse ./fm_demod_proj/fm_demod_proj.gen/sources_1/bd/fm_demod/hdl/fm_demod_wrapper.v


##################################################################
# PACKAGE FM DEMOD BLOCK DESIGN AS A VIVADO IP
##################################################################
# Packages the fm_demod block design (wrapper + BD sources) as a reusable
# Vivado IP so it can be instantiated in a top-level design alongside the
# Zynq PS block, AXI DMA, and supporting infrastructure.
#
# The packaged IP lands in ${proj_dir}/ip_repo/ and can be added to any
# Vivado IP repository via:
#   set_property ip_repo_paths <path_to_ip_repo> [current_project]
#   update_ip_catalog

puts "\n=== Packaging FM demodulator block design as Vivado IP ==="

ipx::package_project \
    -root_dir     ${proj_dir}/ip_repo \
    -vendor       Marco_Aiello \
    -library      user \
    -taxonomy     /UserIP \
    -import_files \
    -set_current  false

# Open the freshly packaged core and set metadata
set core [ipx::find_open_core Marco_Aiello:user:fm_demod:1.0]
if { $core eq "" } {
    set core [ipx::open_core ${proj_dir}/ip_repo/component.xml]
}

set_property name         fm_demod                                    $core
set_property version      1.0                                         $core
set_property display_name "FM Demodulator (full chain)"               $core
set_property description  "Complete FM mono demodulator: NCO, FreqCorr, AA LPF x2, FM Discriminator, FIR Decimator R=5, Audio LPF, De-emphasis. sfix16_En15 I/Q input, sfix32_En13 audio output, 250 kHz / 50 kHz sample rates, AXI-Stream I/O, Ultra96-V2 (xczu3eg-sbva484-1-i)." $core
set_property company_url  "" $core

ipx::save_core $core

puts "=== FM demodulator IP packaged to: ${proj_dir}/ip_repo ==="
puts "=== Add that path to your top-level project IP repository to use it ==="


##################################################################
# STAGE sim_1 FOR tb_fm_demod_chain.sv
##################################################################
# Folded in from what used to be a standalone stage_sim_fileset.tcl --
# see the header comment at the top of this file for why. Skips cleanly
# (IP build above still stands) if the stimulus files don't exist yet.

set stim_i "s_axis_i_stimulus.txt"
set stim_q "s_axis_q_stimulus.txt"

if { ![file exists $stim_i] || ![file exists $stim_q] } {
    puts "\n=== Skipping sim_1 staging: $stim_i / $stim_q not found in [pwd] ==="
    puts "=== Run gen_fm_demod_stimulus.m in MATLAB first, then re-run this script ==="
    puts "=== (the IP build above is unaffected and already complete) ==="
} else {
    puts "\n=== Staging sim_1 fileset (tb_fm_demod_chain.sv + stimulus) ==="

    if { [string equal [get_filesets -quiet sim_1] ""] } {
        create_fileset -simset sim_1
    }

    add_files -fileset sim_1 -norecurse ./tb_fm_demod_chain.sv

    # xsim reads the stimulus/output .txt files via plain $fopen with a
    # relative path, resolved against xsim's working directory at run
    # time -- NOT the project directory. Copy the stimulus files in next
    # to where the sim actually runs rather than hardcoding that path
    # (it moves depending on Vivado version / project structure).
    set xsim_dir "${proj_dir}/${proj_name}.sim/sim_1/behav/xsim"
    file mkdir $xsim_dir
    foreach f [list $stim_i $stim_q] {
        file copy -force $f "${xsim_dir}/$f"
    }
    puts "=== Copied stimulus files into ${xsim_dir} ==="

    set_property top tb_fm_demod_chain [get_filesets sim_1]
    set_property top_lib xil_defaultlib [get_filesets sim_1]

    update_compile_order -fileset sim_1

    puts "=== sim_1 fileset staged. Ready for run_fm_demod_chain_batch.tcl / run_batch_sim.sh ==="
}

exit
