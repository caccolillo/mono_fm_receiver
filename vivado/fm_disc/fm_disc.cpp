#include "fm_disc.h"

/**
 * FM Discriminator with fixed-point CORDIC atan2.
 * Matches the Simulink block diagram exactly:
 *
 *   Id = Ic[n-1],  Qd = Qc[n-1]
 *   Idiff = Ic*Id + Qc*Qd   sfix18_En14
 *   Qdiff = Qc*Id - Ic*Qd   sfix18_En14
 *   phase = cordic_atan2(Qdiff, Idiff)   -> sfix18_En15
 *   out   = phase * r2Hz                  -> sfix32_En14
 *
 * Fixed-point CORDIC (16 iterations, vectoring mode):
 *   Rotates vector (x,y) toward y=0, accumulating angle z.
 *   atan lookup table in sfix18_En15: atan(2^-i) for i=0..15
 *   CORDIC gain = 1.6468 (not compensated -- matches Simulink behaviour)
 *
 * Synthesis: pure fixed-point, no floating-point units.
 * II=1, depth ~ 20 cycles.
 *
 * Marco Aiello, 2024
 */

// CORDIC atan2 lookup table: atan(2^-i) in sfix18_En15 format
// atan(2^-i) * 2^15 rounded to nearest integer
// i=0: atan(1)    = pi/4    = 0.7854 -> 25736
// i=1: atan(0.5)  = 0.4636  -> 15192
// i=2: atan(0.25) = 0.2450  ->  8027
// etc.
static const phase_t ATAN_LUT[CORDIC_ITER] = {
    phase_t(0.7853981634),   // atan(2^0)  = pi/4
    phase_t(0.4636476090),   // atan(2^-1)
    phase_t(0.2449786631),   // atan(2^-2)
    phase_t(0.1243549945),   // atan(2^-3)
    phase_t(0.0624188100),   // atan(2^-4)
    phase_t(0.0312398334),   // atan(2^-5)
    phase_t(0.0156237286),   // atan(2^-6)
    phase_t(0.0078123767),   // atan(2^-7)
    phase_t(0.0039062301),   // atan(2^-8)
    phase_t(0.0019531225),   // atan(2^-9)
    phase_t(0.0009765622),   // atan(2^-10)
    phase_t(0.0004882812),   // atan(2^-11)
    phase_t(0.0002441406),   // atan(2^-12)
    phase_t(0.0001220703),   // atan(2^-13)
    phase_t(0.0000610352),   // atan(2^-14)
    phase_t(0.0000305176),   // atan(2^-15)
};

// Fixed-point CORDIC atan2 (vectoring mode)
// Inputs: x, y in cordic_t (sfix22_En14)
// Output: angle in phase_t (sfix18_En15)
static phase_t cordic_atan2(cordic_t x_in, cordic_t y_in) {
    #pragma HLS INLINE

    cordic_t x = x_in;
    cordic_t y = y_in;
    phase_t  z = 0;

    // Initial rotation to put vector in right half-plane (|angle| <= pi/2)
    // If x < 0, rotate by +/-pi to get into quadrant I or IV
    if (x < 0) {
        if (y >= 0) {
            x = -x_in;
            y = -y_in;
            z =  phase_t(3.14159265359);   // +pi (will saturate to max)
        } else {
            x = -x_in;
            y = -y_in;
            z = -phase_t(3.14159265359);   // -pi
        }
    }

    // 16 CORDIC iterations.
    // Use explicit shift factors rather than >> operator to ensure
    // ap_fixed arithmetic matches MATLAB fi shift exactly.
    // Factor array: 2^-i for i=0..15, represented as cordic_t constants.
    static const cordic_t SHIFT[CORDIC_ITER] = {
        cordic_t(1.0),          // 2^0
        cordic_t(0.5),          // 2^-1
        cordic_t(0.25),         // 2^-2
        cordic_t(0.125),        // 2^-3
        cordic_t(0.0625),       // 2^-4
        cordic_t(0.03125),      // 2^-5
        cordic_t(0.015625),     // 2^-6
        cordic_t(0.0078125),    // 2^-7
        cordic_t(0.00390625),   // 2^-8
        cordic_t(0.001953125),  // 2^-9
        cordic_t(0.0009765625), // 2^-10
        cordic_t(0.00048828125),// 2^-11
        cordic_t(0.000244140625),// 2^-12
        cordic_t(0.0001220703125),// 2^-13
        cordic_t(0.00006103515625),// 2^-14
        cordic_t(0.000030517578125),// 2^-15
    };

    CORDIC_LOOP:
    for (int i = 0; i < CORDIC_ITER; i++) {
        #pragma HLS UNROLL
        cordic_t x_new, y_new;
        cordic_t xs = x * SHIFT[i];
        cordic_t ys = y * SHIFT[i];
        if (y >= 0) {
            x_new = x + ys;
            y_new = y - xs;
            z     = z + ATAN_LUT[i];
        } else {
            x_new = x - ys;
            y_new = y + xs;
            z     = z - ATAN_LUT[i];
        }
        x = x_new;
        y = y_new;
    }
    return z;
}

void fm_disc(data_t &ic, data_t &qc, out_t &disc_out) {

    #pragma HLS INTERFACE mode=axis port=ic
    #pragma HLS INTERFACE mode=axis port=qc
    #pragma HLS INTERFACE mode=axis port=disc_out
    #pragma HLS INTERFACE mode=ap_ctrl_none port=return
    #pragma HLS PIPELINE II=1

    // 1-sample delay registers
    static data_t id = 0;
    static data_t qd = 0;

    // Cross-products -> sfix18_En14
    prod_t ixid = ic * id;
    prod_t qxqd = qc * qd;
    prod_t qxid = qc * id;
    prod_t ixqd = ic * qd;

    // Complex multiply components
    prod_t x_diff = ixid + qxqd;   // Idiff (real part)
    prod_t y_diff = qxid - ixqd;   // Qdiff (imaginary part)

    // Fixed-point CORDIC atan2 -> sfix18_En15
    cordic_t x_c = cordic_t(x_diff);
    cordic_t y_c = cordic_t(y_diff);
    phase_t phase = cordic_atan2(x_c, y_c);

    // Scale by r2Hz = fs/(2*pi) = 39788.7358 -> sfix32_En14
    const out_t r2hz = 39788.7358;
    disc_out = out_t(phase * r2hz);

    // Update delay registers
    id = ic;
    qd = qc;
}
