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
set proj_name fm_demod_axissidechannels_proj
set proj_dir  [pwd]/fm_demod_proj
set part      xc7z010clg400-1

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

