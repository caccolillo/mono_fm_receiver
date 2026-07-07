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
# Usage: vivado -mode batch -source fm_demod_ip.tcl
#

# Project identifiers and target part (Zybo Z7-10)
set proj_name  fm_demod_axissidechannels_proj
set proj_dir   [pwd]/fm_demod_proj
set part       xc7z010clg400-1
# script_dir: directory containing all source files (passed via -tclargs)
if { [llength $argv] >= 1 } {
    set script_dir [lindex $argv 0]
} else {
    set script_dir [pwd]
}

# Fresh project, overwriting any previous run in the same directory
create_project -force ${proj_name} ${proj_dir} -part ${part}

# Sub-block IPs are VHDL; the full-chain testbench (tb_fm_demod_chain.sv)
# is SystemVerilog. Mixed-language simulation requires this set so xsim
# elaborates both without complaint.
set_property simulator_language Mixed [current_project]

# Add VHDL source files used to build block design
add_files -norecurse iq_splitter.vhd
add_files -norecurse tlast_gen.vhd

# Point Vivado at the local IP repository (one level up) where each
# sub-block's packaged IP lives, then rescan so they appear in the
# IP Catalog and can be instantiated by name in the block design.
set_property  ip_repo_paths  ../ [current_project]
update_ip_catalog

# Add source files needed in the block design
add_files -norecurse {./tlast_gen.vhd ./iq_splitter.vhd}
update_compile_order -fileset sources_1

# bd.tcl contains the actual block design: instantiates each custom IP
# (NCO, FreqCorr, AA LPF x2 for I/Q, FM discriminator, FIR decimator,
# Audio LPF, De-emphasis) and wires the AXI-Stream interfaces between
# them per the FM receiver signal chain. Kept in a separate file so the
# wiring can be edited/regenerated independently of this top-level script.
source bd.tcl

# ── Generate Block Design Wrapper & Set as Top ─────────────────────────────
# Get the block design handle dynamically
set bd_file [get_files ${proj_dir}/${proj_name}.srcs/sources_1/bd/design_1/design_1.bd]

# Generate a synthesizable Verilog wrapper around the block design
make_wrapper -files $bd_file -top

# Target the newly generated file location inside the .gen directory structure
set wrapper_file "${proj_dir}/${proj_name}.gen/sources_1/bd/design_1/hdl/design_1_wrapper.v"
add_files -norecurse $wrapper_file

# Re-evaluate the project structure to include the new file
update_compile_order -fileset sources_1

# Explicitly force the project to use the wrapper as its top file
set_property top design_1_wrapper [current_fileset]
update_compile_order -fileset sources_1

##################################################################
# AXI4-STREAM VIP TESTBENCH -- stall detection
##################################################################
# Adds two AXI4-Stream VIP instances to the block design (one master
# driving s, one slave monitoring m), generates a SystemVerilog testbench
# that injects I/Q beats and checks neither bus stalls for more than
# STALL_TIMEOUT consecutive cycles.

set tb_vip "${script_dir}/tb_fm_demod_axis_vip.sv"
if { [file exists $tb_vip] } {
    # Add VIP IPs to block design
    open_bd_design [get_files design_1.bd]

    # Master VIP: drives s (32-bit slave input)
    create_ip -name axi4stream_vip -vendor xilinx.com -library ip \
              -version 1.1 -module_name axi4stream_vip_0
    set_property -dict [list \
        CONFIG.INTERFACE_MODE  {MASTER} \
        CONFIG.TDATA_NUM_BYTES {4} \
        CONFIG.HAS_TREADY      {1} \
        CONFIG.HAS_TLAST       {1} \
    ] [get_ips axi4stream_vip_0]

    # Slave VIP: monitors m (32-bit master output)
    create_ip -name axi4stream_vip -vendor xilinx.com -library ip \
              -version 1.1 -module_name axi4stream_vip_1
    set_property -dict [list \
        CONFIG.INTERFACE_MODE  {SLAVE} \
        CONFIG.TDATA_NUM_BYTES {4} \
        CONFIG.HAS_TREADY      {1} \
        CONFIG.HAS_TLAST       {1} \
    ] [get_ips axi4stream_vip_1]

    generate_target all [get_ips axi4stream_vip_0]
    generate_target all [get_ips axi4stream_vip_1]

    # Add VIP simulation files to sim_1 so xsim compiles the packages
    # before the testbench (compile order matters -- packages must precede
    # any file that imports them).
    foreach vip_name {axi4stream_vip_0 axi4stream_vip_1} {
        set vip_sim_dir "${proj_dir}/${proj_name}.gen/sources_1/ip/${vip_name}/sim"
        foreach sv_file [glob -nocomplain "${vip_sim_dir}/*.sv"] {
            add_files -fileset sim_1 -norecurse $sv_file
            puts "    Added VIP sim file: [file tail $sv_file]"
        }
    }
    update_compile_order -fileset sim_1

    # Add testbench and set as simulation top
    add_files -fileset sim_1 -norecurse $tb_vip
    set_property file_type {SystemVerilog} [get_files $tb_vip]
    update_compile_order -fileset sim_1
    set_property top     tb_fm_demod_axis_vip [get_filesets sim_1]
    set_property top_lib xil_defaultlib       [get_filesets sim_1]
    set_property -name {xsim.simulate.runtime} -value {all} \
                 -objects [get_filesets sim_1]

    puts "=== VIP testbench added: tb_fm_demod_axis_vip.sv ==="
    puts "    Run simulation from Vivado GUI or via run_batch_sim.sh"
} else {
    puts "INFO: tb_fm_demod_axis_vip.sv not found -- skipping VIP testbench setup"
    puts "INFO: Copy tb_fm_demod_axis_vip.sv to ${script_dir} and re-run to add it"
}


# ── Package FM Demod Block Design As A Vivado IP ───────────────────────────
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

set_property name         fm_demod_axis_with_sidechannels                                    $core
set_property version      1.0                                         $core
set_property display_name "FM Demodulator with side channels(full chain)"               $core
set_property description  "Complete FM mono demodulator: NCO, FreqCorr, AA LPF x2, FM Discriminator, FIR Decimator R=5, Audio LPF, De-emphasis. sfix16_En15 I/Q input, sfix32_En13 audio output, 250 kHz / 50 kHz sample rates, AXI-Stream I/O, Zybo Z7 (xc7z010clg400-1)." $core
set_property company_url  "" $core

ipx::save_core $core

puts "=== FM demodulator IP packaged to: ${proj_dir}/ip_repo ==="
puts "=== Add that path to your top-level project IP repository to use it ==="

exit

