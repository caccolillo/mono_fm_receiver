
################################################################
# This is a generated script based on design: sdr_fm_receiver
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
# source sdr_fm_receiver_script.tcl

# If there is no project opened, this script will create a
# project, but make sure you do not have an existing project
# <./myproj/project_1.xpr> in the current working folder.

set list_projs [get_projects -quiet]
if { $list_projs eq "" } {
   create_project project_1 myproj -part xczu3eg-sbva484-1-i
   set_property BOARD_PART avnet.com:ultra96v2:part0:1.2 [current_project]
}


# CHANGE DESIGN NAME HERE
variable design_name
set design_name sdr_fm_receiver

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
   # NOTE: zynq_ultra_ps_e version pinned to 3.4 (typical for 2022.2). If the
   # IP catalog check below fails, run `get_ipdefs -all *zynq_ultra_ps_e*`
   # in the Tcl console and correct the version string here to match.
   set list_check_ips "\ 
Marco_Aiello:hls:audio_ppdma:1.0\
xilinx.com:ip:axi_gpio:2.0\
Marco_Aiello:user:fm_demod:1.0\
Marco_Aiello:hls:iq_ppdma:1.0\
xilinx.com:ip:zynq_ultra_ps_e:3.4\
xilinx.com:ip:proc_sys_reset:5.0\
xilinx.com:ip:xlconstant:1.1\
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


  # NOTE: zynq_ultra_ps_e's DDR is normally NOT exposed as a top-level BD
  # port -- once the Ultra96-V2 board preset is applied (below), the DDR
  # interface is fixed/internal to the PS and routed straight to the
  # package DDR pins via the board file. These two ports (and the DDR/
  # FIXED_IO connect_bd_intf_net lines further down) should be DELETED,
  # not translated. Left here commented as a reminder -- do not create them.
  # set DDR [ create_bd_intf_port ... ]
  # set FIXED_IO [ create_bd_intf_port ... ]

  # Create ports

  # Create instance: audio_ppdma_0, and set properties
  set audio_ppdma_0 [ create_bd_cell -type ip -vlnv Marco_Aiello:hls:audio_ppdma:1.0 audio_ppdma_0 ]

  # Create instance: axi_gpio_0, and set properties
  set axi_gpio_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_0 ]
  set_property -dict [list \
    CONFIG.C_ALL_INPUTS {1} \
    CONFIG.C_ALL_INPUTS_2 {1} \
    CONFIG.C_GPIO2_WIDTH {1} \
    CONFIG.C_GPIO_WIDTH {1} \
    CONFIG.C_IS_DUAL {1} \
  ] $axi_gpio_0


  # Create instance: axi_mem_intercon, and set properties
  set axi_mem_intercon [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_mem_intercon ]
  set_property -dict [list \
    CONFIG.NUM_MI {1} \
    CONFIG.NUM_SI {2} \
  ] $axi_mem_intercon


  # Create instance: fm_demod_0, and set properties
  set fm_demod_0 [ create_bd_cell -type ip -vlnv Marco_Aiello:user:fm_demod:1.0 fm_demod_0 ]

  # Create instance: iq_ppdma_0, and set properties
  set iq_ppdma_0 [ create_bd_cell -type ip -vlnv Marco_Aiello:hls:iq_ppdma:1.0 iq_ppdma_0 ]

  # Create instance: zynq_ultra_ps_e_0, and set properties
  #
  # Replaces PS7. The Zybo Z7-10 script hand-specified ~300 lines of
  # PCW_UIPARAM_DDR_* board-trace-length/calibration properties for that
  # board's specific DDR3L part -- those numbers are meaningless for the
  # Ultra96-V2's DDR part and are NOT reproduced here. Instead we apply
  # the board preset (requires Avnet Ultra96-V2 board files installed)
  # to pull in the correct DDR/clocking config, then explicitly enable
  # only the AXI interfaces and PL clock this design actually uses.
  set zynq_ultra_ps_e_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.4 zynq_ultra_ps_e_0 ]

  apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset "1"} [get_bd_cells zynq_ultra_ps_e_0]

  set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0 {1} \
    CONFIG.PSU__USE__M_AXI_GP1 {0} \
    CONFIG.PSU__USE__S_AXI_GP2 {1} \
    CONFIG.PSU__FPGA_PL0_ENABLE {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100} \
    CONFIG.PSU__SAXIGP2__DATA_WIDTH {64} \
  ] $zynq_ultra_ps_e_0

  # VERIFY IN GUI: after apply_bd_automation runs, double-click the PS
  # cell and confirm under "PS-PL Configuration" that:
  #   - AXI Interfaces > Master Interface > AXI HPM0 FPD is ticked (32-bit),
  #     AXI HPM1 FPD is UNticked
  #   - AXI Interfaces > Slave Interface > AXI HP0 FPD is ticked
  #   - Clock Configuration > PL Fabric Clocks > PL0 = 100 MHz
  # These are the ZU+ equivalents of the old PCW_USE_M_AXI_GP0,
  # PCW_USE_S_AXI_HP0 and PCW_FPGA0_PERIPHERAL_FREQMHZ {100} properties.
  # Note the HP slave ports don't get their own PSU__USE__S_AXI_HP0FPD-style
  # property (that was my first guess and Vivado rejected it) -- ZU+
  # numbers them internally as GP2-GP5 (GP0/1 being the two M_AXI_HPM
  # master ports), so S_AXI_HP0_FPD is enabled via PSU__USE__S_AXI_GP2.
  # This matches the "SAXIGP2" name already used for set_slave_profile in
  # the testbench and for the DATA_WIDTH property above.
  #
  # Also: the Ultra96-V2 board preset turns M_AXI_HPM1_FPD (GP1) ON by
  # default -- PS7's board preset never did this for GP1, so it wasn't
  # anticipated the first time through. This design only wires up GP0,
  # so GP1 is explicitly disabled above; leaving it enabled-but-unwired
  # fails validate_bd_design with "clock pins not connected to a valid
  # clock source" on maxihpm1_fpd_aclk. If a future revision of this
  # design DOES want a second GP master, wire its aclk to pl_clk0 in the
  # net below and connect its interface pin to something, rather than
  # just flipping this property back to 1.


  # Create instance: ps7_0_axi_periph, and set properties
  set ps7_0_axi_periph [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 ps7_0_axi_periph ]
  set_property CONFIG.NUM_MI {1} $ps7_0_axi_periph


  # Create instance: rst_ps7_0_50M, and set properties
  set rst_ps7_0_50M [ create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_ps7_0_50M ]

  # Create instance: xlconstant_0, and set properties
  set xlconstant_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 xlconstant_0 ]

  # Create instance: xlconstant_1, and set properties
  set xlconstant_1 [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 xlconstant_1 ]
  set_property -dict [list \
    CONFIG.CONST_VAL {0x3E000000} \
    CONFIG.CONST_WIDTH {32} \
  ] $xlconstant_1


  # Create instance: xlconstant_2, and set properties
  set xlconstant_2 [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 xlconstant_2 ]
  set_property -dict [list \
    CONFIG.CONST_VAL {0x3E100000} \
    CONFIG.CONST_WIDTH {32} \
  ] $xlconstant_2


  # Create instance: xlconstant_3, and set properties
  set xlconstant_3 [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 xlconstant_3 ]
  set_property -dict [list \
    CONFIG.CONST_VAL {0x3E200000} \
    CONFIG.CONST_WIDTH {32} \
  ] $xlconstant_3


  # Create instance: xlconstant_4, and set properties
  set xlconstant_4 [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 xlconstant_4 ]
  set_property -dict [list \
    CONFIG.CONST_VAL {0x3E300000} \
    CONFIG.CONST_WIDTH {32} \
  ] $xlconstant_4


  # Create instance: xlconstant_5, and set properties
  set xlconstant_5 [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 xlconstant_5 ]
  set_property -dict [list \
    CONFIG.CONST_VAL {0x3E400000} \
    CONFIG.CONST_WIDTH {32} \
  ] $xlconstant_5


  # Create instance: xlconstant_6, and set properties
  set xlconstant_6 [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 xlconstant_6 ]
  set_property -dict [list \
    CONFIG.CONST_VAL {2500} \
    CONFIG.CONST_WIDTH {32} \
  ] $xlconstant_6


  # Create interface connections
  connect_bd_intf_net -intf_net audio_ppdma_0_m_axi_gmem [get_bd_intf_pins audio_ppdma_0/m_axi_gmem] [get_bd_intf_pins axi_mem_intercon/S00_AXI]
  connect_bd_intf_net -intf_net axi_mem_intercon_M00_AXI [get_bd_intf_pins axi_mem_intercon/M00_AXI] [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP0_FPD]
  connect_bd_intf_net -intf_net fm_demod_0_m_axis_data_0 [get_bd_intf_pins audio_ppdma_0/sample] [get_bd_intf_pins fm_demod_0/m_axis_data_0]
  connect_bd_intf_net -intf_net iq_ppdma_0_i_out [get_bd_intf_pins fm_demod_0/s_axis_i_0] [get_bd_intf_pins iq_ppdma_0/i_out]
  connect_bd_intf_net -intf_net iq_ppdma_0_m_axi_gmem [get_bd_intf_pins axi_mem_intercon/S01_AXI] [get_bd_intf_pins iq_ppdma_0/m_axi_gmem]
  connect_bd_intf_net -intf_net iq_ppdma_0_q_out [get_bd_intf_pins fm_demod_0/s_axis_q_0] [get_bd_intf_pins iq_ppdma_0/q_out]
  # DDR/FIXED_IO: intentionally not connected -- ZU+ DDR is fixed/internal
  # once the board preset is applied, there's no top-level port to wire.
  connect_bd_intf_net -intf_net zynq_ultra_ps_e_0_M_AXI_HPM0_FPD [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM0_FPD] [get_bd_intf_pins ps7_0_axi_periph/S00_AXI]
  connect_bd_intf_net -intf_net ps7_0_axi_periph_M00_AXI [get_bd_intf_pins axi_gpio_0/S_AXI] [get_bd_intf_pins ps7_0_axi_periph/M00_AXI]

  # Create port connections
  connect_bd_net -net audio_ppdma_0_active_buf [get_bd_pins audio_ppdma_0/active_buf] [get_bd_pins axi_gpio_0/gpio2_io_i]
  connect_bd_net -net iq_ppdma_0_active_buf [get_bd_pins axi_gpio_0/gpio_io_i] [get_bd_pins iq_ppdma_0/active_buf]
  # VERIFY IN GUI: pin names maxihpm0_fpd_aclk / saxihp0_fpd_aclk / pl_clk0 /
  # pl_resetn0 are correct for zynq_ultra_ps_e 3.4 as of 2022.2, but IP pin
  # names have shifted across ZU+ PS versions before -- if connect_bd_net
  # errors on any of these, open the PS cell in the diagram and read the
  # actual pin names off it directly.
  connect_bd_net -net zynq_ultra_ps_e_0_pl_clk0 [get_bd_pins audio_ppdma_0/ap_clk] [get_bd_pins axi_gpio_0/s_axi_aclk] [get_bd_pins axi_mem_intercon/ACLK] [get_bd_pins axi_mem_intercon/M00_ACLK] [get_bd_pins axi_mem_intercon/S00_ACLK] [get_bd_pins axi_mem_intercon/S01_ACLK] [get_bd_pins fm_demod_0/aclk_0] [get_bd_pins iq_ppdma_0/ap_clk] [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins zynq_ultra_ps_e_0/maxihpm0_fpd_aclk] [get_bd_pins zynq_ultra_ps_e_0/saxihp0_fpd_aclk] [get_bd_pins ps7_0_axi_periph/ACLK] [get_bd_pins ps7_0_axi_periph/M00_ACLK] [get_bd_pins ps7_0_axi_periph/S00_ACLK] [get_bd_pins rst_ps7_0_50M/slowest_sync_clk]
  connect_bd_net -net zynq_ultra_ps_e_0_pl_resetn0 [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] [get_bd_pins rst_ps7_0_50M/ext_reset_in]
  connect_bd_net -net rst_ps7_0_50M_peripheral_aresetn [get_bd_pins audio_ppdma_0/ap_rst_n] [get_bd_pins axi_gpio_0/s_axi_aresetn] [get_bd_pins axi_mem_intercon/ARESETN] [get_bd_pins axi_mem_intercon/M00_ARESETN] [get_bd_pins axi_mem_intercon/S00_ARESETN] [get_bd_pins axi_mem_intercon/S01_ARESETN] [get_bd_pins fm_demod_0/aresetn_0] [get_bd_pins iq_ppdma_0/ap_rst_n] [get_bd_pins ps7_0_axi_periph/ARESETN] [get_bd_pins ps7_0_axi_periph/M00_ARESETN] [get_bd_pins ps7_0_axi_periph/S00_ARESETN] [get_bd_pins rst_ps7_0_50M/peripheral_aresetn]
  connect_bd_net -net xlconstant_0_dout [get_bd_pins audio_ppdma_0/ap_start] [get_bd_pins iq_ppdma_0/ap_start] [get_bd_pins xlconstant_0/dout]
  connect_bd_net -net xlconstant_1_dout [get_bd_pins iq_ppdma_0/ping_base] [get_bd_pins xlconstant_1/dout]
  connect_bd_net -net xlconstant_2_dout [get_bd_pins iq_ppdma_0/pong_base] [get_bd_pins xlconstant_2/dout]
  connect_bd_net -net xlconstant_3_dout [get_bd_pins audio_ppdma_0/ping_base] [get_bd_pins xlconstant_3/dout]
  connect_bd_net -net xlconstant_4_dout [get_bd_pins audio_ppdma_0/pong_base] [get_bd_pins xlconstant_4/dout]
  connect_bd_net -net xlconstant_5_dout [get_bd_pins audio_ppdma_0/dest_base] [get_bd_pins xlconstant_5/dout]
  connect_bd_net -net xlconstant_6_dout [get_bd_pins iq_ppdma_0/buf_size_words] [get_bd_pins xlconstant_6/dout]

  # Create address segments
  # The old script hardcoded PS7's fixed DDR/register offsets (0x0, 0x4000_0000)
  # -- those are specific to the PS7 address map and are WRONG for ZU+
  # (different DDR base/range, different HP0 segment name, e.g.
  # zynq_ultra_ps_e_0/SAXIGP2/HP0_DDR_LOW rather than S_AXI_HP0/HP0_DDR_LOWOCM).
  # Rather than guess the exact segment name, let Vivado's address editor
  # auto-resolve each target space against whatever segment it overlaps --
  # there's only one sane candidate for each of these three, so 'assign_bd_address'
  # with no explicit -offset/-range/-target_address_segs is the safe move here.
  # IMPORTANT: main.c / fmdemod-linux.c hardcode the PS7 DDR offsets your
  # software reads/writes (ping/pong buffer base addresses, AUDIO_DEST_ADDR,
  # the xlconstant_1..5 base-address constants below) -- once Vivado assigns
  # the real ZU+ offsets, open the Address Editor, read back the actual
  # values, and update BOTH the xlconstant CONFIG.CONST_VAL properties below
  # AND the corresponding #defines in software to match. This is a
  # cross-cutting change outside "vivado design files" scope -- flagging it
  # so it isn't missed when you get to the software side.
  assign_bd_address -target_address_space [get_bd_addr_spaces audio_ppdma_0/Data_m_axi_gmem]
  assign_bd_address -target_address_space [get_bd_addr_spaces iq_ppdma_0/Data_m_axi_gmem]
  assign_bd_address -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data]


  # Restore current instance
  current_bd_instance $oldCurInst

  validate_bd_design
  save_bd_design
}
# End of create_root_design()


##################################################################
# MAIN FLOW
##################################################################

create_root_design ""


