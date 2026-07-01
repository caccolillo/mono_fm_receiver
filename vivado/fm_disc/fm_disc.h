#ifndef FM_DISC_H_
#define FM_DISC_H_

#include <ap_fixed.h>

// Input: sfix18_En17 (matches AA LPF output)
typedef ap_fixed<18, 1, AP_TRN, AP_SAT> data_t;

// Cross-products: sfix18_En14 (Simulink ProductMode SpecifyPrecision 18,14)
typedef ap_fixed<18, 4, AP_TRN, AP_SAT> prod_t;

// CORDIC internal: needs 22 fraction bits for 16-iteration convergence.
// At iteration 15: x * 2^-15 ~ 3.8e-7, needs 2^-22 LSB to represent.
// With 8 integer bits (covers CORDIC gain ~1.65x): ap_fixed<32,8> = 24 frac bits.
typedef ap_fixed<32, 8, AP_TRN, AP_SAT> cordic_t;

// CORDIC output: sfix18_En15 (matches Simulink CORDIC atan2 output)
typedef ap_fixed<18, 3, AP_TRN, AP_SAT> phase_t;

// Output: sfix32_En14 (matches Simulink fm_disc output)
typedef ap_fixed<32, 18, AP_TRN, AP_SAT> out_t;

// Number of CORDIC iterations (matches Simulink default = 16)
#define CORDIC_ITER 16

// Top-level function prototype: FM discriminator with separate AXI-Stream
// interfaces per port (s_axis_ic, s_axis_qc, m_axis_disc_out).
//
// NOTE: ic and qc must be passed by reference (data_t &), not by value.
// HLS's 'axis' interface mode can only bind streaming read/write hardware
// to reference parameters -- a pass-by-value scalar silently falls back
// to 'ap_none' (no tvalid/tready) instead of becoming a proper AXI-S port.
void fm_disc(data_t &ic, data_t &qc, out_t &disc_out);

#endif
