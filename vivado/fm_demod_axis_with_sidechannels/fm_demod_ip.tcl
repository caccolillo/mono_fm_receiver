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
set proj_name fm_demod_proj
set proj_dir  [pwd]/fm_demod_proj
set part      xc7z010clg400-1

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

# Generate a synthesizable Verilog wrapper around the block design so it
# can be used as (or instantiated within) a top-level design for
# synthesis and bitstream generation.
make_wrapper -files [get_files ./fm_demod_proj/fm_demod_proj.srcs/sources_1/bd/fm_demod/fm_demod.bd] -top

# Add the generated wrapper to the project sources.
add_files -norecurse ./fm_demod_proj/fm_demod_proj.gen/sources_1/bd/fm_demod/hdl/fm_demod_wrapper.v


