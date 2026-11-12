/*
 * pl_rates.h
 *
 * Single source of truth for every sample rate, and every
 * rate-dependent coefficient, in the software half of the FM receiver.
 * Included by fmdemod-rtlsdr.c, resample_50k_to_48k.c and alsa_live.c,
 * so the three can no longer disagree about what rate the PL runs at.
 *
 * ---------------------------------------------------------------------
 * WHY THE PL DOES NOT RUN AT 250 kHz
 * ---------------------------------------------------------------------
 * The design intent was 250 kHz into iq_ppdma (100 MHz / 400 cycles,
 * enforced by #pragma HLS LATENCY min=400). That pragma is only a
 * floor: it pads a schedule that would otherwise finish early, but
 * cannot make iq_ppdma's AXI read through HP0 finish any faster than
 * it really does. On silicon the read is the binding constraint.
 *
 * The real rate is also LOAD-DEPENDENT, because AXI read latency
 * through HP0 depends on what else is using DDR. Measured 2026-10-07:
 *
 *     gpio_rate_test alone (no ALSA)   231,667 S/s  (92.67 Hz toggle)
 *     live capture with -A playback    231,035 S/s  (92.41 Hz toggle)
 *       (ring-fill slope and refill rate, two independent 60 s runs:
 *        231,028 / 231,041 / 231,034 -- agreement within ~55 ppm)
 *     / 5 (fir_dec, fixed ratio)       =  46,207 Hz audio
 *
 * THESE CONSTANTS ARE TUNED FOR LIVE PLAYBACK (-A). That is the use
 * case that has to run uninterrupted. Run WITHOUT -A, the PL runs about
 * 0.27% faster than the dongle, the ring drains by ~630 pairs/s, and
 * underruns start after roughly 4 minutes. Short WAV-only captures are
 * unaffected; for long ones, add -A or re-tune.
 *
 * (Simulation predicted 456 cycles via the PS7 VIP's DDR model. The
 * mechanism is the same, but the model is pessimistic, so only the
 * hardware number is used here.)
 *
 * Rather than fight the PL, the software now runs the whole chain at
 * the rate the PL actually achieves: the dongle samples at
 * PL_IQ_RATE_HZ so the I/Q ring neither fills nor drains, and every
 * downstream stage is told the true audio rate.
 *
 * Residual error is about +-50 ppm. That is inaudible as pitch, and
 * about 12 I/Q pairs/s of ring drift (half-ring headroom lasts hours)
 * and about 2.3 audio samples/s against ALSA's 200 ms buffer (lasts
 * over an hour). Watch "ring=" on a long run; if it trends steadily,
 * re-measure from the ring slope and re-run gen_rate_coeffs.py.
 *
 * (A servo trimming the DONGLE rate was considered and rejected: on
 * the R820T, rtlsdr_set_sample_rate() re-tunes the PLL and soft-resets
 * the demodulator, so every correction would be an audible dropout.)
 *
 * ---------------------------------------------------------------------
 * IF THE PL OR ITS RATE EVER CHANGES
 * ---------------------------------------------------------------------
 * Re-measure UNDER THE SAME LOAD as real use (live capture with -A;
 * the ring slope in the progress line is the easiest measure: PL rate
 * = dongle rate - slope), update IQ_RATE in gen_rate_coeffs.py, re-run
 * it (it rewrites resample_coeffs.h and prints the filter defines
 * below), and update the two rate defines here. Nothing else should
 * need touching.
 */
#ifndef PL_RATES_H
#define PL_RATES_H

/* ---- Rates -------------------------------------------------------- */

/* Measured iq_ppdma consumption rate during live -A capture. The
 * RTL2832U can hit this to within 0.01 ppm (librtlsdr's 28-bit
 * resampler divider), well inside the measurement's own +-50 ppm. */
#define PL_IQ_RATE_HZ         231035u

/* Audio rate out of fir_dec: PL_IQ_RATE_HZ / 5 = 46207 exactly.
 * resample_coeffs.h uses L/M = 107/103 to reach 48 kHz (+30 ppm,
 * inaudible, and inside the measurement error anyway). */
#define PL_AUDIO_RATE_HZ      46207u

/* Rate the PL's fixed-coefficient blocks were DESIGNED for. Kept only
 * for scaling things that are fixed numbers in the PL (see below). */
#define PL_DESIGN_IQ_RATE_HZ  250000u

/* ---- The NCO ------------------------------------------------------ *
 * dds_compiler_0 has a FIXED phase increment, set for 10 kHz at
 * 250 kHz. A fixed increment is a fixed fraction of the sample rate,
 * so at the real rate the shift is 10000 * 231035/250000 = 9241.4 Hz.
 * The tuner offset must follow it, or the station lands ~759 Hz off
 * DC (a DC offset in the discriminator output rather than distortion,
 * but there is no reason to leave it). */
#define PL_NCO_SHIFT_HZ \
    ((int)((10000LL * PL_IQ_RATE_HZ + PL_DESIGN_IQ_RATE_HZ / 2) / PL_DESIGN_IQ_RATE_HZ))

/* ---- De-emphasis correction, 75 us (PL) -> 50 us (UK) ------------- *
 * The PL's de_emph pole is the fixed NUMBER a75 = 0.765928338364649
 * (chosen as exp(-1/(50000*75e-6))). At 46.207 kHz that same number
 * is an effective tau of 81.16 us, not 75 us. The correction
 *
 *     y[n] = g*(x[n] - a75*x[n-1]) + a50*y[n-1]
 *
 * still cancels the PL's pole EXACTLY, because its zero uses the same
 * number; only the replacement 50 us pole has to be recomputed for
 * the true rate. So the net response is a correct 50 us de-emphasis at
 * the real rate, better than "about right".
 *
 * Generated by gen_rate_coeffs.py. */
#define DEEMPH_A75  0.765928338364649   /* PL coefficient, unchanged */
#define DEEMPH_A50  0.648667609207278   /* exp(-1/(46207*50e-6)) */
#define DEEMPH_G    1.500960809771351   /* (1-a50)/(1-a75) */

/* ---- 8 kHz HF low-pass (Gqrx-matched) ----------------------------- *
 * scipy.signal.butter(2, 8000, fs=46207). Generated by
 * gen_rate_coeffs.py. */
#define HF_LPF_B0   0.1646735676
#define HF_LPF_B1   0.3293471351
#define HF_LPF_B2   0.1646735676
#define HF_LPF_A1  -0.5711443359
#define HF_LPF_A2   0.2298386062

#endif /* PL_RATES_H */
