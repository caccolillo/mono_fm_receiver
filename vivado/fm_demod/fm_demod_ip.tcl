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
# Marco Aiello, 2024

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
# FULL-CHAIN VERIFICATION
##################################################################
# Adds the SystemVerilog testbench (tb_fm_demod_chain.sv) plus the real
# I/Q stimulus generated from rds.wav, then runs a 10 s behavioral
# simulation of the complete demodulator and captures the de-emphasis
# audio output for MATLAB to play back / compare against the Simulink
# reference (verify_fm_demod_rtl.m).
#
# Prerequisite: gen_fm_demod_stimulus.m has been run in MATLAB so
# s_axis_i_stimulus.txt / s_axis_q_stimulus.txt exist in this directory.

set script_dir [pwd]

# ── Verify stimulus files exist before going any further ──────────────────
set bStimMissing 0
foreach f {s_axis_i_stimulus.txt s_axis_q_stimulus.txt} {
    if { ![file exists "${script_dir}/${f}"] } {
        puts "ERROR: ${script_dir}/${f} not found."
        puts "ERROR: Run gen_fm_demod_stimulus.m in MATLAB first."
        set bStimMissing 1
    }
}

set tb_file "${script_dir}/tb_fm_demod_chain.sv"
if { ![file exists $tb_file] } {
    puts "ERROR: Testbench not found: ${tb_file}"
    set bStimMissing 1
}

if { $bStimMissing == 1 } {
    puts "WARNING: Skipping full-chain simulation due to missing file(s) above."
    puts "WARNING: Project and block design are still built; rerun this script"
    puts "WARNING: after generating the missing file(s) to perform verification."
} else {

    # ── Add the SystemVerilog testbench to the simulation fileset ──────────
    add_files -fileset sim_1 -norecurse $tb_file
    set_property file_type {SystemVerilog} [get_files $tb_file]

    # ── Register stimulus files as simulation data files ───────────────────
    # add_files alone does NOT copy non-HDL data files into the xsim
    # working directory at launch_simulation time -- they must be added
    # to the sim_1 fileset and explicitly marked USED_IN simulation so
    # Vivado's fileset machinery copies them alongside the snapshot. A
    # manual 'file copy' into the xsim dir runs at the wrong point in the
    # flow (before launch_simulation (re)creates that directory) and is
    # not reliable -- this is the correct mechanism.
    add_files -fileset sim_1 -norecurse [list \
        "${script_dir}/s_axis_i_stimulus.txt" \
        "${script_dir}/s_axis_q_stimulus.txt" \
    ]
    set_property USED_IN_SIMULATION true \
        [get_files -all "${script_dir}/s_axis_i_stimulus.txt"]
    set_property USED_IN_SIMULATION true \
        [get_files -all "${script_dir}/s_axis_q_stimulus.txt"]

    update_compile_order -fileset sim_1
    set_property top     tb_fm_demod_chain [get_filesets sim_1]
    set_property top_lib xil_defaultlib    [get_filesets sim_1]

    # ── Register the saved waveform configuration ───────────────────────────
    # tb_fm_demod_chain_behav.wcfg captures signal groupings/dividers (e.g.
    # "FREQ CORR") and zoom/cursor state from a previous interactive xsim
    # session, so the GUI reopens the same waveform view automatically on
    # future simulation runs instead of requiring signals to be re-added by
    # hand each time.
    #
    # SOURCE_SET must be set on the sim_1 fileset before add_files for a
    # .wcfg to register correctly -- this mirrors what Vivado itself emits
    # to a project Tcl when a waveform config is added via the GUI. The
    # sources_1 compile order must be up to date first, or SOURCE_SET
    # silently fails to take effect.
    set wcfg_file "${script_dir}/tb_fm_demod_chain_behav.wcfg"
    if { [file exists $wcfg_file] } {
        update_compile_order -fileset sources_1
        set_property SOURCE_SET sources_1 [get_filesets sim_1]
        add_files -fileset sim_1 -norecurse $wcfg_file
        puts "--- Waveform config added: ${wcfg_file} ---"
    } else {
        puts "INFO: ${wcfg_file} not found -- skipping waveform config registration."
    }

    # Testbench self-terminates via $finish once stimulus is exhausted and
    # the pipeline has flushed, so 'all' here is a safety ceiling, not the
    # actual run duration.
    set_property -name {xsim.simulate.runtime}         -value {all}  -objects [get_filesets sim_1]
    set_property -name {xsim.simulate.log_all_signals} -value {false} -objects [get_filesets sim_1]

    puts "--- Testbench added: ${tb_file} ---"
    puts "    Top entity : tb_fm_demod_chain"
    puts "    Stimulus   : 10 s of I/Q (2,500,000 samples) -- this will take a"
    puts "                 substantial amount of wall-clock time to simulate."

    # ── Pre-stage the xsim working directory ────────────────────────────────
    # add_files + USED_IN_SIMULATION registers the data files with the
    # project so Vivado's GUI-driven 'Run Simulation' flow will stage them
    # correctly, but to guarantee the files are present even if that
    # propagation doesn't trigger on first launch, also pre-create the
    # expected xsim working directory and copy them in directly. This is
    # safe to do ahead of time since it does not depend on launch_simulation
    # having run yet.
    set xsim_dir "${proj_dir}/${proj_name}.sim/sim_1/behav/xsim"
    file mkdir $xsim_dir
    foreach f {s_axis_i_stimulus.txt s_axis_q_stimulus.txt} {
        file copy -force "${script_dir}/${f}" "${xsim_dir}/${f}"
        puts "--- Staged ${f} -> ${xsim_dir} ---"
    }

    puts "\n=== Project ready ==="
    puts "Simulation is NOT launched by this script."
    puts "To run it: open ${proj_dir}/${proj_name}.xpr in the Vivado GUI, then"
    puts "  Flow Navigator -> Simulation -> Run Simulation -> Run Behavioral Simulation"
    puts ""
    puts "If the stimulus files are not found at simulation runtime, re-run the"
    puts "staging step above (or re-source this script) -- launch_simulation can"
    puts "reset the xsim working directory contents on some Vivado versions."
    puts ""
    puts "After the simulation completes, the testbench will have written:"
    puts "  ${xsim_dir}/m_axis_data_dut_output.txt"
    puts "Copy that file to ${script_dir}/ and run verify_fm_demod_rtl.m in MATLAB."
}

