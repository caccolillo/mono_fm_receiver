
################################################################
# This is a generated script based on design: fm_demod
#
# Though there are limitations about the generated script,
# the main purpose of this utility is to make learning
# IP Integrator Tcl commands easier.
################################################################

namespace eval _tcl {
proc get_script_folder {} {
   set script_path [file normalize [info script]]
   set script_folder [file dirname $script_path]
   return $script_folder
}
}
variable script_folder
set script_folder [_tcl::get_script_folder]

################################################################
# Check if script is running in correct Vivado version.
################################################################
set scripts_vivado_version 2022.2
set current_vivado_version [version -short]

if { [string first $scripts_vivado_version $current_vivado_version] == -1 } {
   puts ""
   catch {common::send_gid_msg -ssname BD::TCL -id 2041 -severity "ERROR" "This script was generated using Vivado <$scripts_vivado_version> and is being run in <$current_vivado_version> of Vivado. Please run the script in Vivado <$scripts_vivado_version> then open the design in Vivado <$current_vivado_version>. Upgrade the design by running \"Tools => Report => Report IP Status...\", then run write_bd_tcl to create an updated script."}

   return 1
}

################################################################
# START
################################################################

# To test this script, run the following commands from Vivado Tcl console:
# source fm_demod_script.tcl

# If there is no project opened, this script will create a
# project, but make sure you do not have an existing project
# <./myproj/project_1.xpr> in the current working folder.

set list_projs [get_projects -quiet]
if { $list_projs eq "" } {
   create_project project_1 myproj -part xc7z020clg400-1
}


# CHANGE DESIGN NAME HERE
variable design_name
set design_name fm_demod

# If you do not already have an existing IP Integrator design open,
# you can create a design using the following command:
#    create_bd_design $design_name

# Creating design if needed
set errMsg ""
set nRet 0

set cur_design [current_bd_design -quiet]
set list_cells [get_bd_cells -quiet]

if { ${design_name} eq "" } {
   # USE CASES:
   #    1) Design_name not set

   set errMsg "Please set the variable <design_name> to a non-empty value."
   set nRet 1

} elseif { ${cur_design} ne "" && ${list_cells} eq "" } {
   # USE CASES:
   #    2): Current design opened AND is empty AND names same.
   #    3): Current design opened AND is empty AND names diff; design_name NOT in project.
   #    4): Current design opened AND is empty AND names diff; design_name exists in project.

   if { $cur_design ne $design_name } {
      common::send_gid_msg -ssname BD::TCL -id 2001 -severity "INFO" "Changing value of <design_name> from <$design_name> to <$cur_design> since current design is empty."
      set design_name [get_property NAME $cur_design]
   }
   common::send_gid_msg -ssname BD::TCL -id 2002 -severity "INFO" "Constructing design in IPI design <$cur_design>..."

} elseif { ${cur_design} ne "" && $list_cells ne "" && $cur_design eq $design_name } {
   # USE CASES:
   #    5) Current design opened AND has components AND same names.

   set errMsg "Design <$design_name> already exists in your project, please set the variable <design_name> to another value."
   set nRet 1
} elseif { [get_files -quiet ${design_name}.bd] ne "" } {
   # USE CASES: 
   #    6) Current opened design, has components, but diff names, design_name exists in project.
   #    7) No opened design, design_name exists in project.

   set errMsg "Design <$design_name> already exists in your project, please set the variable <design_name> to another value."
   set nRet 2

} else {
   # USE CASES:
   #    8) No opened design, design_name not in project.
   #    9) Current opened design, has components, but diff names, design_name not in project.

   common::send_gid_msg -ssname BD::TCL -id 2003 -severity "INFO" "Currently there is no design <$design_name> in project, so creating one..."

   create_bd_design $design_name

   common::send_gid_msg -ssname BD::TCL -id 2004 -severity "INFO" "Making design <$design_name> as current_bd_design."
   current_bd_design $design_name

}

common::send_gid_msg -ssname BD::TCL -id 2005 -severity "INFO" "Currently the variable <design_name> is equal to \"$design_name\"."

if { $nRet != 0 } {
   catch {common::send_gid_msg -ssname BD::TCL -id 2006 -severity "ERROR" $errMsg}
   return $nRet
}

set bCheckIPsPassed 1
##################################################################
# CHECK IPs
##################################################################
set bCheckIPs 1
if { $bCheckIPs == 1 } {
   set list_check_ips "\ 
Marco_Aiello:hls:aa_lpf:1.0\
Marco_Aiello:user:audio_lpf:1.0\
Marco_Aiello:user:de_emph:1.0\
Marco_Aiello:user:fir_dec:1.0\
Marco_Aiello:hls:fm_disc:1.0\
marco-aiello:fm_receiver:freq_corr:1.0\
marco-aiello:fm_receiver:nco:1.0\
xilinx.com:ip:xlconcat:2.1\
xilinx.com:ip:xlslice:1.0\
"

   set list_ips_missing ""
   common::send_gid_msg -ssname BD::TCL -id 2011 -severity "INFO" "Checking if the following IPs exist in the project's IP catalog: $list_check_ips ."

   foreach ip_vlnv $list_check_ips {
      set ip_obj [get_ipdefs -all $ip_vlnv]
      if { $ip_obj eq "" } {
         lappend list_ips_missing $ip_vlnv
      }
   }

   if { $list_ips_missing ne "" } {
      catch {common::send_gid_msg -ssname BD::TCL -id 2012 -severity "ERROR" "The following IPs are not found in the IP Catalog:\n  $list_ips_missing\n\nResolution: Please add the repository containing the IP(s) to the project." }
      set bCheckIPsPassed 0
   }

}

if { $bCheckIPsPassed != 1 } {
  common::send_gid_msg -ssname BD::TCL -id 2023 -severity "WARNING" "Will not continue with creation of design due to the error(s) above."
  return 3
}

##################################################################
# DESIGN PROCs
##################################################################


# Hierarchical cell: I_adapter1
proc create_hier_cell_I_adapter1 { parentCell nameHier } {

  variable script_folder

  if { $parentCell eq "" || $nameHier eq "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2092 -severity "ERROR" "create_hier_cell_I_adapter1() - Empty argument(s)!"}
     return
  }

  # Get object for parentCell
  set parentObj [get_bd_cells $parentCell]
  if { $parentObj == "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2090 -severity "ERROR" "Unable to find parent cell <$parentCell>!"}
     return
  }

  # Make sure parentObj is hier blk
  set parentType [get_property TYPE $parentObj]
  if { $parentType ne "hier" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2091 -severity "ERROR" "Parent <$parentObj> has TYPE = <$parentType>. Expected to be <hier>."}
     return
  }

  # Save current instance; Restore later
  set oldCurInst [current_bd_instance .]

  # Set parent object as current
  current_bd_instance $parentObj

  # Create cell and set as current instance
  set hier_obj [create_bd_cell -type hier $nameHier]
  current_bd_instance $hier_obj

  # Create interface pins

  # Create pins
  create_bd_pin -dir I -from 17 -to 0 In0
  create_bd_pin -dir O -from 23 -to 0 dout

  # Create instance: xlconcat_0, and set properties
  set xlconcat_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 xlconcat_0 ]

  # Create instance: xlconcat_sign_0, and set properties
  set xlconcat_sign_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 xlconcat_sign_0 ]
  set_property -dict [list \
    CONFIG.IN0_WIDTH {1} \
    CONFIG.IN1_WIDTH {1} \
    CONFIG.IN2_WIDTH {1} \
    CONFIG.IN3_WIDTH {1} \
    CONFIG.IN4_WIDTH {1} \
    CONFIG.IN5_WIDTH {1} \
    CONFIG.NUM_PORTS {6} \
  ] $xlconcat_sign_0


  # Create instance: xlslice_sign_0, and set properties
  set xlslice_sign_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 xlslice_sign_0 ]
  set_property -dict [list \
    CONFIG.DIN_FROM {17} \
    CONFIG.DIN_TO {17} \
    CONFIG.DIN_WIDTH {18} \
    CONFIG.DOUT_WIDTH {1} \
  ] $xlslice_sign_0


  # Create port connections
  connect_bd_net -net freq_corr_0_m_axis_ic_tdata [get_bd_pins In0] [get_bd_pins xlconcat_0/In0] [get_bd_pins xlslice_sign_0/Din]
  connect_bd_net -net xlconcat_0_dout [get_bd_pins dout] [get_bd_pins xlconcat_0/dout]
  connect_bd_net -net xlconcat_sign_0_dout [get_bd_pins xlconcat_0/In1] [get_bd_pins xlconcat_sign_0/dout]
  connect_bd_net -net xlslice_sign_0_Dout [get_bd_pins xlconcat_sign_0/In0] [get_bd_pins xlconcat_sign_0/In1] [get_bd_pins xlconcat_sign_0/In2] [get_bd_pins xlconcat_sign_0/In3] [get_bd_pins xlconcat_sign_0/In4] [get_bd_pins xlconcat_sign_0/In5] [get_bd_pins xlslice_sign_0/Dout]

  # Restore current instance
  current_bd_instance $oldCurInst
}

# Hierarchical cell: I_adapter
proc create_hier_cell_I_adapter { parentCell nameHier } {

  variable script_folder

  if { $parentCell eq "" || $nameHier eq "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2092 -severity "ERROR" "create_hier_cell_I_adapter() - Empty argument(s)!"}
     return
  }

  # Get object for parentCell
  set parentObj [get_bd_cells $parentCell]
  if { $parentObj == "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2090 -severity "ERROR" "Unable to find parent cell <$parentCell>!"}
     return
  }

  # Make sure parentObj is hier blk
  set parentType [get_property TYPE $parentObj]
  if { $parentType ne "hier" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2091 -severity "ERROR" "Parent <$parentObj> has TYPE = <$parentType>. Expected to be <hier>."}
     return
  }

  # Save current instance; Restore later
  set oldCurInst [current_bd_instance .]

  # Set parent object as current
  current_bd_instance $parentObj

  # Create cell and set as current instance
  set hier_obj [create_bd_cell -type hier $nameHier]
  current_bd_instance $hier_obj

  # Create interface pins

  # Create pins
  create_bd_pin -dir I -from 17 -to 0 In0
  create_bd_pin -dir O -from 23 -to 0 dout

  # Create instance: xlconcat_0, and set properties
  set xlconcat_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 xlconcat_0 ]

  # Create instance: xlconcat_sign_0, and set properties
  set xlconcat_sign_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 xlconcat_sign_0 ]
  set_property -dict [list \
    CONFIG.IN0_WIDTH {1} \
    CONFIG.IN1_WIDTH {1} \
    CONFIG.IN2_WIDTH {1} \
    CONFIG.IN3_WIDTH {1} \
    CONFIG.IN4_WIDTH {1} \
    CONFIG.IN5_WIDTH {1} \
    CONFIG.NUM_PORTS {6} \
  ] $xlconcat_sign_0


  # Create instance: xlslice_sign_0, and set properties
  set xlslice_sign_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 xlslice_sign_0 ]
  set_property -dict [list \
    CONFIG.DIN_FROM {17} \
    CONFIG.DIN_TO {17} \
    CONFIG.DIN_WIDTH {18} \
    CONFIG.DOUT_WIDTH {1} \
  ] $xlslice_sign_0


  # Create port connections
  connect_bd_net -net freq_corr_0_m_axis_ic_tdata [get_bd_pins In0] [get_bd_pins xlconcat_0/In0] [get_bd_pins xlslice_sign_0/Din]
  connect_bd_net -net xlconcat_0_dout [get_bd_pins dout] [get_bd_pins xlconcat_0/dout]
  connect_bd_net -net xlconcat_sign_0_dout [get_bd_pins xlconcat_0/In1] [get_bd_pins xlconcat_sign_0/dout]
  connect_bd_net -net xlslice_sign_0_Dout [get_bd_pins xlconcat_sign_0/In0] [get_bd_pins xlconcat_sign_0/In1] [get_bd_pins xlconcat_sign_0/In2] [get_bd_pins xlconcat_sign_0/In3] [get_bd_pins xlconcat_sign_0/In4] [get_bd_pins xlconcat_sign_0/In5] [get_bd_pins xlslice_sign_0/Dout]

  # Restore current instance
  current_bd_instance $oldCurInst
}


# Procedure to create entire design; Provide argument to make
# procedure reusable. If parentCell is "", will use root.
proc create_root_design { parentCell } {

  variable script_folder
  variable design_name

  if { $parentCell eq "" } {
     set parentCell [get_bd_cells /]
  }

  # Get object for parentCell
  set parentObj [get_bd_cells $parentCell]
  if { $parentObj == "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2090 -severity "ERROR" "Unable to find parent cell <$parentCell>!"}
     return
  }

  # Make sure parentObj is hier blk
  set parentType [get_property TYPE $parentObj]
  if { $parentType ne "hier" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2091 -severity "ERROR" "Parent <$parentObj> has TYPE = <$parentType>. Expected to be <hier>."}
     return
  }

  # Save current instance; Restore later
  set oldCurInst [current_bd_instance .]

  # Set parent object as current
  current_bd_instance $parentObj


  # Create interface ports
  set m_axis_data_0 [ create_bd_intf_port -mode Master -vlnv xilinx.com:interface:axis_rtl:1.0 m_axis_data_0 ]

  set s_axis_i_0 [ create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:axis_rtl:1.0 s_axis_i_0 ]
  set_property -dict [ list \
   CONFIG.HAS_TKEEP {0} \
   CONFIG.HAS_TLAST {0} \
   CONFIG.HAS_TREADY {1} \
   CONFIG.HAS_TSTRB {0} \
   CONFIG.LAYERED_METADATA {undef} \
   CONFIG.TDATA_NUM_BYTES {2} \
   CONFIG.TDEST_WIDTH {0} \
   CONFIG.TID_WIDTH {0} \
   CONFIG.TUSER_WIDTH {0} \
   ] $s_axis_i_0

  set s_axis_q_0 [ create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:axis_rtl:1.0 s_axis_q_0 ]
  set_property -dict [ list \
   CONFIG.HAS_TKEEP {0} \
   CONFIG.HAS_TLAST {0} \
   CONFIG.HAS_TREADY {1} \
   CONFIG.HAS_TSTRB {0} \
   CONFIG.LAYERED_METADATA {undef} \
   CONFIG.TDATA_NUM_BYTES {2} \
   CONFIG.TDEST_WIDTH {0} \
   CONFIG.TID_WIDTH {0} \
   CONFIG.TUSER_WIDTH {0} \
   ] $s_axis_q_0


  # Create ports
  set aclk_0 [ create_bd_port -dir I -type clk aclk_0 ]
  set aresetn_0 [ create_bd_port -dir I -type rst aresetn_0 ]

  # Create instance: I_adapter
  create_hier_cell_I_adapter [current_bd_instance .] I_adapter

  # Create instance: I_adapter1
  create_hier_cell_I_adapter1 [current_bd_instance .] I_adapter1

  # Create instance: aa_lpf_I, and set properties
  set aa_lpf_I [ create_bd_cell -type ip -vlnv Marco_Aiello:hls:aa_lpf:1.0 aa_lpf_I ]

  # Create instance: aa_lpf_Q, and set properties
  set aa_lpf_Q [ create_bd_cell -type ip -vlnv Marco_Aiello:hls:aa_lpf:1.0 aa_lpf_Q ]

  # Create instance: audio_lpf_0, and set properties
  set audio_lpf_0 [ create_bd_cell -type ip -vlnv Marco_Aiello:user:audio_lpf:1.0 audio_lpf_0 ]

  # Create instance: de_emph_0, and set properties
  set de_emph_0 [ create_bd_cell -type ip -vlnv Marco_Aiello:user:de_emph:1.0 de_emph_0 ]

  # Create instance: fir_dec_0, and set properties
  set fir_dec_0 [ create_bd_cell -type ip -vlnv Marco_Aiello:user:fir_dec:1.0 fir_dec_0 ]

  # Create instance: fm_disc_0, and set properties
  set fm_disc_0 [ create_bd_cell -type ip -vlnv Marco_Aiello:hls:fm_disc:1.0 fm_disc_0 ]

  # Create instance: freq_corr_0, and set properties
  set freq_corr_0 [ create_bd_cell -type ip -vlnv marco-aiello:fm_receiver:freq_corr:1.0 freq_corr_0 ]

  # Create instance: nco_0, and set properties
  set nco_0 [ create_bd_cell -type ip -vlnv marco-aiello:fm_receiver:nco:1.0 nco_0 ]

  # Create interface connections
  connect_bd_intf_net -intf_net aa_lpf_0_y [get_bd_intf_pins aa_lpf_I/y] [get_bd_intf_pins fm_disc_0/ic]
  connect_bd_intf_net -intf_net aa_lpf_1_y [get_bd_intf_pins aa_lpf_Q/y] [get_bd_intf_pins fm_disc_0/qc]
  connect_bd_intf_net -intf_net audio_lpf_0_m_axis_data [get_bd_intf_pins audio_lpf_0/m_axis_data] [get_bd_intf_pins de_emph_0/s_axis_data]
  connect_bd_intf_net -intf_net de_emph_0_m_axis_data [get_bd_intf_ports m_axis_data_0] [get_bd_intf_pins de_emph_0/m_axis_data]
  connect_bd_intf_net -intf_net fir_dec_0_m_axis_data [get_bd_intf_pins audio_lpf_0/s_axis_data] [get_bd_intf_pins fir_dec_0/m_axis_data]
  connect_bd_intf_net -intf_net fm_disc_0_disc_out [get_bd_intf_pins fir_dec_0/s_axis_data] [get_bd_intf_pins fm_disc_0/disc_out]
  connect_bd_intf_net -intf_net nco_0_m_axis_cos [get_bd_intf_pins freq_corr_0/s_axis_cos] [get_bd_intf_pins nco_0/m_axis_cos]
  connect_bd_intf_net -intf_net nco_0_m_axis_sin [get_bd_intf_pins freq_corr_0/s_axis_sin] [get_bd_intf_pins nco_0/m_axis_sin]
  connect_bd_intf_net -intf_net s_axis_i_0_1 [get_bd_intf_ports s_axis_i_0] [get_bd_intf_pins freq_corr_0/s_axis_i]
  connect_bd_intf_net -intf_net s_axis_q_0_1 [get_bd_intf_ports s_axis_q_0] [get_bd_intf_pins freq_corr_0/s_axis_q]

  # Create port connections
  connect_bd_net -net I_adapter1_dout [get_bd_pins I_adapter1/dout] [get_bd_pins aa_lpf_Q/x_TDATA]
  connect_bd_net -net In0_1 [get_bd_pins I_adapter1/In0] [get_bd_pins freq_corr_0/m_axis_qc_tdata]
  connect_bd_net -net aa_lpf_0_x_TREADY [get_bd_pins aa_lpf_I/x_TREADY] [get_bd_pins freq_corr_0/m_axis_ic_tready]
  connect_bd_net -net aa_lpf_1_x_TREADY [get_bd_pins aa_lpf_Q/x_TREADY] [get_bd_pins freq_corr_0/m_axis_qc_tready]
  connect_bd_net -net aclk_0_1 [get_bd_ports aclk_0] [get_bd_pins aa_lpf_I/ap_clk] [get_bd_pins aa_lpf_Q/ap_clk] [get_bd_pins audio_lpf_0/aclk] [get_bd_pins de_emph_0/aclk] [get_bd_pins fir_dec_0/aclk] [get_bd_pins fm_disc_0/ap_clk] [get_bd_pins freq_corr_0/aclk] [get_bd_pins nco_0/aclk]
  connect_bd_net -net aresetn_0_1 [get_bd_ports aresetn_0] [get_bd_pins aa_lpf_I/ap_rst_n] [get_bd_pins aa_lpf_Q/ap_rst_n] [get_bd_pins audio_lpf_0/aresetn] [get_bd_pins de_emph_0/aresetn] [get_bd_pins fir_dec_0/aresetn] [get_bd_pins fm_disc_0/ap_rst_n] [get_bd_pins freq_corr_0/aresetn] [get_bd_pins nco_0/aresetn]
  connect_bd_net -net freq_corr_0_m_axis_ic_tdata [get_bd_pins I_adapter/In0] [get_bd_pins freq_corr_0/m_axis_ic_tdata]
  connect_bd_net -net freq_corr_0_m_axis_ic_tvalid [get_bd_pins aa_lpf_I/x_TVALID] [get_bd_pins freq_corr_0/m_axis_ic_tvalid]
  connect_bd_net -net freq_corr_0_m_axis_qc_tvalid [get_bd_pins aa_lpf_Q/x_TVALID] [get_bd_pins freq_corr_0/m_axis_qc_tvalid]
  connect_bd_net -net xlconcat_0_dout [get_bd_pins I_adapter/dout] [get_bd_pins aa_lpf_I/x_TDATA]

  # Create address segments


  # Restore current instance
  current_bd_instance $oldCurInst

  save_bd_design
}
# End of create_root_design()


##################################################################
# MAIN FLOW
##################################################################

create_root_design ""


common::send_gid_msg -ssname BD::TCL -id 2053 -severity "WARNING" "This Tcl script was generated from a block design that has not been validated. It is possible that design <$design_name> may result in errors during validation."

