##############################################################################
# de_emph_mcp.xdc
#
# Multicycle path constraints for de_emph.vhd's combinational IIR chain
# (x_in*B0 -> saturate -> y_prev*A1 -> saturate -> add -> saturate -> y_out),
# as an ALTERNATIVE to pipelining the RTL itself.
#
# PREREQUISITE: this file assumes de_emph.vhd is back to its ORIGINAL
# single-cycle form (the version before the two-stage pipelining edit).
# The register paths below are taken verbatim from an actual Vivado
# implementation timing report run against that original netlist -- if
# de_emph.vhd is pipelined, these paths won't exist and this file does
# nothing useful. Use ONE of (a) this XDC file with the original VHDL,
# or (b) the pipelined VHDL with no MCP needed -- not both.
#
# WHY THIS IS A LEGITIMATE (not a hack) MCP, specific to this design:
# s_axis_data_tvalid into de_emph only pulses once per real input
# sample -- roughly every 2000 PL clock cycles (50 kHz output vs
# 100 MHz clock), by construction of the whole upstream fixed-rate
# pipeline (NCO -> ... -> audio_lpf), not by chance or by any
# software/CPU-controlled timing. y_prev_reg / m_tdata_r_reg therefore
# genuinely do not need a new value captured every single clock cycle --
# only once every ~2000 cycles -- which is exactly the situation
# set_multicycle_path exists for. This assumption is architectural, not
# incidental: if upstream throughput timing ever changes such that
# s_axis_data_tvalid could pulse faster than every few cycles, THIS
# CONSTRAINT WOULD BECOME UNSAFE (masking a real violation instead of
# correctly relaxing a false one) and must be revisited.
#
# SIZING: worst-case combinational delay measured was 13.239ns. At the
# 10ns (100 MHz) period, that needs ceil(13.239/10) = 2 cycles minimum.
# A setup multiplier of 2 (20ns budget) clears the worst path with
# ~6.7ns of margin -- comfortably covers the other slightly-easier
# failing endpoints too without needing to go any more aggressive.
#
# THE SETUP/HOLD PAIRING RULE (per Xilinx UG903 "Using Constraints",
# Multicycle Paths chapter): setting -setup N alone also shifts the
# hold check, and can silently create a NEW hold violation if you don't
# also specify the companion -hold (N-1) constraint. Both lines below
# are required together -- do not apply the -setup line alone.
##############################################################################

# --------------------------------------------------------------------------
# Sources: TWO distinct registers feed this combinational cloud, matching
# the Direct Form I difference equation y[n] = b0*x[n] + a1*y[n-1] --
# every cycle's computation reads BOTH a fresh input sample and the
# previous output:
#   1. audio_lpf's FIR compiler output register (x[n], the input sample).
#   2. de_emph's own y_prev_reg (y[n-1], the feedback state -- this
#      register is simultaneously part of the DESTINATION set below on
#      the next cycle AND a SOURCE for a1*y[n-1] within the same cycle's
#      combinational path). An earlier version of this file only listed
#      (1), which covered the single worst path from the first timing
#      report but left every y_prev-to-y_prev feedback path
#      unconstrained -- confirmed directly when a later timing run's
#      worst path turned out to be y_prev_reg[8]/C -> y_prev_reg[9]/D,
#      i.e. entirely within (2), with no FIR register in the path at all.
# --------------------------------------------------------------------------
set MCP_SRC [get_pins [list \
    {sdr_fm_receiver_i/fm_demod_0/inst/fm_demod_i/audio_lpf_0/U0/fir_compiler_1_inst/U0/i_synth/g_single_rate.i_single_rate/g_m_data_chan_no_fifo.m_axis_data_tdata_int_reg[*]/C} \
    {sdr_fm_receiver_i/fm_demod_0/inst/fm_demod_i/de_emph_0/U0/y_prev_reg[*]/C} \
]]

# --------------------------------------------------------------------------
# Destinations: de_emph's two output registers driven from the same
# combinational cloud. y_prev_reg is confirmed directly in the timing
# report (bits [4] and [6] shown as the two worst endpoints, but the
# same source/logic fans out to all 32 bits). m_tdata_r_reg is driven
# by the identical y_out value in the same clocked process, so it is
# very likely also among the 86 failing endpoints even though it wasn't
# one of the two paths detailed in the report -- included here on that
# basis; if implementation still shows failing endpoints after applying
# this file, check whether they trace to a THIRD destination register
# not covered by either of the two patterns below.
# --------------------------------------------------------------------------
set MCP_DST [get_pins [list \
    {sdr_fm_receiver_i/fm_demod_0/inst/fm_demod_i/de_emph_0/U0/y_prev_reg[*]/D} \
    {sdr_fm_receiver_i/fm_demod_0/inst/fm_demod_i/de_emph_0/U0/m_tdata_r_reg[*]/D} \
]]

set_multicycle_path 2 -setup -from $MCP_SRC -to $MCP_DST
set_multicycle_path 1 -hold  -from $MCP_SRC -to $MCP_DST