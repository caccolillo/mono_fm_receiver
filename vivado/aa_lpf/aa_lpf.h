#ifndef AA_LPF_H_
#define AA_LPF_H_

#include <ap_fixed.h>

#define NTAPS 129

// Output: fixdt(1,18,17) -> 18 bits, 1 integer bit, Saturate on Overflow
typedef ap_fixed<18, 1, AP_TRN, AP_SAT> data_t;

// Coefficients: fixdt(1,32,30) -> 32 bits, 2 integer bits
typedef ap_fixed<32, 2> coef_t;

// Accumulator: fixdt(1,40,17) -> 40 bits, 23 integer bits, Saturate on Overflow
typedef ap_fixed<40, 23, AP_TRN, AP_SAT> acc_t;

// Top-level function prototype: single-channel AXI-S FIR filter.
// x and y are exported as native AXI-Stream interfaces (s_axis_x / m_axis_y),
// each with tdata/tvalid/tready. Instantiate twice in the block design --
// once for I, once for Q.
//
// NOTE: x must be passed by reference (data_t &x), not by value. HLS's
// 'axis' interface mode can only bind streaming read/write hardware to
// reference parameters -- a pass-by-value scalar silently falls back to
// 'ap_none' (no tvalid/tready), which is what caused x to come out as a
// plain port instead of AXI-Stream in earlier synthesis runs.
void aa_lpf(data_t &x, data_t &y);

#endif
