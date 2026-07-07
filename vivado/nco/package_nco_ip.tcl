# package_nco_ip.tcl
# Packages nco_wrapper.vhd + dds_compiler_0 as a reusable IP core
# for import into the Vivado IP catalogue.
#
# After running this script, add the output directory to your IP
# repository in Vivado: Tools -> Settings -> IP -> Repository
#
# Usage (in Vivado Tcl console, with nco_sim project open):
#   source package_nco_ip.tcl
#
# Output: ./ip_repo/nco_v1_0/
#


set script_dir [file dirname [file normalize [info script]]]
set ip_repo    "${script_dir}/ip_repo/nco_v1_0"

puts "=== Packaging NCO IP Core ==="
puts "Output: ${ip_repo}"

# ── 1. Create packaging project ───────────────────────────────────────────
set pkg_proj "${script_dir}/nco_pkg_tmp"
file mkdir ${pkg_proj}

create_project nco_pkg ${pkg_proj} \
    -part [get_property PART [current_project]] -force

set_property target_language    VHDL [current_project]
set_property simulator_language VHDL [current_project]

# ── 2. Add source files ───────────────────────────────────────────────────
# Copy DDS Compiler generated files into packaging project
set dds_src [get_files -of_objects [get_ips dds_compiler_0]]
foreach f $dds_src {
    add_files -norecurse $f
}

# Add wrapper
add_files -norecurse "${script_dir}/nco_wrapper.vhd"
set_property top nco_wrapper [current_fileset]
update_compile_order -fileset sources_1

# ── 3. Package IP ─────────────────────────────────────────────────────────
ipx::package_project \
    -root_dir    ${ip_repo} \
    -vendor      "marco-aiello" \
    -library     "fm_receiver" \
    -taxonomy    "/UserIP" \
    -import_files \
    -set_current false

set ip [ipx::open_core "${ip_repo}/component.xml"]

# ── 4. Set IP metadata ────────────────────────────────────────────────────
set_property name            {nco}            $ip
set_property version         {1.0}            $ip
set_property display_name    {NCO (DDS Compiler wrapper)} $ip
set_property description     {10 kHz NCO with separate M_AXIS_COS and M_AXIS_SIN AXI4-Stream outputs. Wraps Xilinx DDS Compiler v6.0. Supports runtime retuning via S_AXIS_CONFIG.} $ip
set_property company_url     {}               $ip
set_property supported_families { \
    zynq    Production \
    artix7  Production \
    kintex7 Production \
} $ip

# ── 5. Infer AXI-Stream interfaces ────────────────────────────────────────
# Vivado auto-detects AXI-Stream from port naming convention.
# Verify the three interfaces are found:
puts "\n--- Inferred interfaces ---"
foreach intf [ipx::get_bus_interfaces -of_objects $ip] {
    puts "  [get_property NAME $intf] : [get_property BUSTYPE_VLNV $intf]"
}

# ── 6. Set clock association for both master ports ────────────────────────
# Associate M_AXIS_COS and M_AXIS_SIN with aclk
foreach intf_name {M_AXIS_COS M_AXIS_SIN S_AXIS_CONFIG} {
    set intf [ipx::get_bus_interfaces $intf_name -of_objects $ip]
    if {$intf ne ""} {
        ipx::add_bus_parameter ASSOCIATED_CLOCKS $intf
        set_property value aclk \
            [ipx::get_bus_parameters ASSOCIATED_CLOCKS -of_objects $intf]
    }
}

# ── 7. Save and close ─────────────────────────────────────────────────────
ipx::create_xgui_files $ip
ipx::update_checksums   $ip
ipx::save_core          $ip
ipx::close_core         $ip

close_project
file delete -force ${pkg_proj}

puts "\n=== IP packaged successfully ==="
puts "Location: ${ip_repo}"
puts ""
puts "To add to IP catalogue:"
puts "  Tools -> Settings -> IP -> Repository -> Add"
puts "  Browse to: ${script_dir}/ip_repo"
puts ""
puts "The NCO IP will appear as 'nco v1.0' under UserIP."
