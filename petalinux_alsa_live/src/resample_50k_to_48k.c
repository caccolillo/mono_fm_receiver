/*
 * resample_50k_to_48k.c (Linux port)
 *
 * Identical resampling MATH to the bare-metal version -- same
 * resample_coeffs.h, same resample_core() algorithm, completely
 * unchanged. Only the FILE I/O primitives changed: FATFS (FIL/f_open/
 * f_read/f_write/FRESULT) -> plain POSIX (FILE *, fopen/fread/fwrite).
 * No FATFS/xilffs dependency remains in this file at all.
 *
 * RATE FIX (2026-10-07): the input is no longer 50 kHz. The PL really
 * produces audio at PL_AUDIO_RATE_HZ (46,333 Hz, measured -- see
 * pl_rates.h), so the resampler is now 107/103 (upsampling) instead of
 * 24/25, and the de-emphasis and HF filter coefficients come from
 * pl_rates.h, recomputed for the real rate. The file and function keep
 * their old "50k" names so nothing calling them has to change; read
 * "50k" below as "the PL's native rate".
 */

#include "resample_coeffs.h"
#include "pl_rates.h"
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>

/* ---------------------------------------------------------------------
 * De-emphasis time-constant correction: 75 us -> 50 us
 * ---------------------------------------------------------------------
 * The PL's de_emph block is built for tau = 75 us (North America):
 *
 *     de_emph.vhd:  b0 = 0.234071661635351
 *                   a1 = 0.765928338364649   = exp(-1/(50000*75e-6))
 *
 * UK/European FM broadcasts use tau = 50 us. Applying a 75 us
 * de-emphasis to a 50 us pre-emphasised signal over-attenuates the
 * treble -- about 3.3 dB down by 10 kHz, rising to 3.5 dB at Nyquist.
 * Audibly dull and bass-heavy.
 *
 * Rather than rebuilding the PL, correct it here. Both filters are
 * first order, so the ratio is also first order and the correction is
 * EXACT, not an approximation:
 *
 *     H_corr(z) = H_50(z) / H_75(z)
 *               = (1-a50)/(1-a50*z^-1) * (1-a75*z^-1)/(1-a75)
 *
 *     y[n] = g*(x[n] - a75*x[n-1]) + a50*y[n-1]
 *
 * The zero at a75 cancels the PL's pole; the pole at a50 applies the
 * correct one. Verified numerically: |H75 * Hcorr - H50| < 1e-14 dB
 * across 0-25 kHz.
 *
 *     a75 = exp(-1/(fs*75e-6)) = 0.765928338364649
 *     a50 = exp(-1/(fs*50e-6)) = 0.670320046035639
 *     g   = (1-a50)/(1-a75)    = 1.408457357294079
 *
 * Applied at the PL's native rate, BEFORE resampling, because that is
 * the rate the PL filter actually runs at and the rate these
 * coefficients are computed for. Doing it after resampling to 48 kHz would need different
 * coefficients and would be correcting a signal that had already been
 * band-limited.
 *
 * NOTE ON WHAT THIS DOES AND DOES NOT FIX: it recovers 3.5 dB of
 * treble, which is real but modest. It does NOT explain a large
 * measured roll-off above a few kHz -- if the audio is still dull
 * after this, the audio LPF cutoff is the next thing to check, and
 * that one does need an RTL change. Boosting treble also boosts
 * whatever noise sits under it, so if the top end is buried in the
 * noise floor this will surface hiss rather than detail.
 *
 * Set DEEMPH_CORRECT to 0 to disable and compare directly.
 * ------------------------------------------------------------------ */
#define DEEMPH_CORRECT 1

/* DEEMPH_A75 / DEEMPH_A50 / DEEMPH_G now come from pl_rates.h. The
 * values quoted above are the original 50 kHz ones; at the PL's real
 * 46.207 kHz rate a50 = 0.6487 and g = 1.5010, and the PL's own pole is
 * an effective 80.9 us rather than 75 us. The cancellation is still
 * exact -- see pl_rates.h. */

static void deemph_75_to_50(int16_t *buf, int n)
{
    double x_prev = 0.0;   /* x[n-1] */
    double y_prev = 0.0;   /* y[n-1] */

    for (int i = 0; i < n; i++) {
        double x = (double)buf[i];
        double y = DEEMPH_G * (x - DEEMPH_A75 * x_prev) + DEEMPH_A50 * y_prev;
        x_prev = x;
        y_prev = y;

        /* Saturate. The correction has up to +4.1 dB of gain at the real rate, so a
         * signal already near full scale can clip here. Wrapping would
         * be far worse than clipping -- a wrap is a full-scale
         * discontinuity that clicks. */
        if (y >  32767.0) y =  32767.0;
        if (y < -32768.0) y = -32768.0;
        buf[i] = (int16_t)lround(y);
    }
}

/* ---------------------------------------------------------------------
 * High-frequency low-pass: match what Gqrx does for mono broadcast FM
 * ---------------------------------------------------------------------
 * Measured directly: an audio recording made in Gqrx (WFM mono, same
 * dongle, same antenna, same station, same location) shows a sharp
 * corner around 8-9 kHz -- flat below 5 kHz, then a real knee, down to
 * -110 dB or lower by 9-10 kHz. This app's audio LPF (127-tap FIR in
 * the PL, -3 dB at 14.8 kHz) is flat well past that point, so weak,
 * noisy high-frequency content that Gqrx simply discards is passed
 * through here and heard as excess hiss/roughness compared to Gqrx.
 *
 * This is NOT correcting an error -- the PL's audio LPF was measured
 * and confirmed correct for a receiver meant to pass close to the full
 * 15 kHz FM audio bandwidth. This filter is a DELIBERATE choice to
 * trade bandwidth for perceived cleanliness on a weak signal, matching
 * Gqrx's behaviour. Set HF_LPF_ENABLE to 0 to disable and get the full
 * 15 kHz bandwidth back.
 *
 * 2nd-order Butterworth, fc = 8000 Hz, fs = 50000 Hz (same rate as the
 * de-emphasis correction, applied before resampling for the same
 * reason: these coefficients are only valid at 50 kHz). Chosen over a
 * 1-pole design because a 1-pole filter at this cutoff is far too
 * gentle to match what was measured (-3dB at fc but only -5dB by
 * 15kHz); the 2nd-order response matches the sharper knee actually
 * observed in the Gqrx reference recording.
 *
 * Implemented as a Direct Form II biquad -- the standard, numerically
 * well-behaved structure for a 2nd-order IIR section.
 * ------------------------------------------------------------------ */
#define HF_LPF_ENABLE 1

/* HF_LPF_* coefficients now come from pl_rates.h:
 * scipy.signal.butter(2, 8000, fs=46207), i.e. recomputed for the
 * PL's measured rate rather than the nominal 50 kHz quoted above. */

static void hf_lowpass_8k(int16_t *buf, int n)
{
    /* Direct Form II: single delay line w[], shared between the
     * feedback (a) and feedforward (b) halves. */
    double w1 = 0.0, w2 = 0.0;

    for (int i = 0; i < n; i++) {
        double x = (double)buf[i];
        double w0 = x - HF_LPF_A1 * w1 - HF_LPF_A2 * w2;
        double y  = HF_LPF_B0 * w0 + HF_LPF_B1 * w1 + HF_LPF_B2 * w2;

        w2 = w1;
        w1 = w0;

        if (y >  32767.0) y =  32767.0;
        if (y < -32768.0) y = -32768.0;
        buf[i] = (int16_t)lround(y);
    }
}

static int resample_core(const int16_t *in, int n_in,
                          int16_t *out, int max_out)
{
    int64_t t = 0;
    int m = 0;

    while (m < max_out) {
        int64_t i     = t / RESAMP_L;
        int     phase = (int)(t % RESAMP_L);

        if (i - (RESAMP_TAPS_PER_PHASE - 1) >= n_in) {
            break;
        }
        if (i < 0) {
            t += RESAMP_M;
            continue;
        }

        double acc = 0.0;
        const float *hp = h_poly[phase];
        for (int k = 0; k < RESAMP_TAPS_PER_PHASE; k++) {
            int64_t idx = i - k;
            int16_t xv = (idx >= 0 && idx < n_in) ? in[idx] : 0;
            acc += (double)hp[k] * (double)xv;
        }

        if (acc > 32767.0)  acc = 32767.0;
        if (acc < -32768.0) acc = -32768.0;
        out[m++] = (int16_t)lround(acc);

        t += RESAMP_M;
        if (i >= n_in) break;
    }

    return m;
}

typedef struct __attribute__((packed)) {
    char  riff_id[4];
    uint32_t riff_size;
    char  wave_id[4];
    char  fmt_id[4];
    uint32_t fmt_size;
    uint16_t audio_format;
    uint16_t num_channels;
    uint32_t sample_rate;
    uint32_t byte_rate;
    uint16_t block_align;
    uint16_t bits_per_sample;
    char  data_id[4];
    uint32_t data_size;
} wav_header_t;

static int wav_write_header(FILE *f, uint32_t sample_rate,
                             uint16_t num_channels, uint16_t bits_per_sample,
                             uint32_t data_bytes)
{
    wav_header_t hdr;

    memcpy(hdr.riff_id, "RIFF", 4);
    memcpy(hdr.wave_id, "WAVE", 4);
    memcpy(hdr.fmt_id, "fmt ", 4);
    hdr.fmt_size = 16;
    hdr.audio_format = 1;
    hdr.num_channels = num_channels;
    hdr.sample_rate = sample_rate;
    hdr.bits_per_sample = bits_per_sample;
    hdr.block_align = num_channels * (bits_per_sample / 8);
    hdr.byte_rate = sample_rate * hdr.block_align;
    memcpy(hdr.data_id, "data", 4);
    hdr.data_size = data_bytes;
    hdr.riff_size = data_bytes + sizeof(hdr) - 8;

    return (fwrite(&hdr, 1, sizeof(hdr), f) == sizeof(hdr)) ? 0 : -1;
}

/*
 * File-level driver: reads a mono 16-bit PCM WAV at PL_AUDIO_RATE_HZ from
 * `in_path`, resamples to 48 kHz, writes it to `out_path`.
 * Returns 0 on success, -1 on failure.
 */
int resample_wav_50k_to_48k(const char *in_path, const char *out_path)
{
    FILE *fin = NULL, *fout = NULL;
    wav_header_t in_hdr;
    int16_t *in_buf = NULL, *out_buf = NULL;
    int n_in, max_out, n_out;
    int ret = -1;

    fin = fopen(in_path, "rb");
    if (!fin) {
        perror("resample: fopen(in_path)");
        fprintf(stderr, "resample: failed to open %s\n", in_path);
        return -1;
    }

    if (fread(&in_hdr, 1, sizeof(in_hdr), fin) != sizeof(in_hdr)) {
        fprintf(stderr, "resample: failed to read %s's WAV header\n", in_path);
        goto cleanup_fin;
    }
    /* Rejecting anything but PL_AUDIO_RATE_HZ is deliberate: an old
     * 50000 Hz file would be resampled with the wrong ratio and come
     * out 7.9% fast. Failing loudly beats silently wrong pitch. */
    if (in_hdr.sample_rate != PL_AUDIO_RATE_HZ || in_hdr.bits_per_sample != 16 ||
        in_hdr.num_channels != 1) {
        fprintf(stderr, "resample: unexpected input format "
                "(rate=%u bits=%u ch=%u), expected %u/16/1\n",
                in_hdr.sample_rate, in_hdr.bits_per_sample, in_hdr.num_channels,
                PL_AUDIO_RATE_HZ);
        goto cleanup_fin;
    }

    n_in = in_hdr.data_size / sizeof(int16_t);
    in_buf = (int16_t *)malloc(in_hdr.data_size);
    if (!in_buf) {
        fprintf(stderr, "resample: malloc(%u) failed for input buffer\n",
                in_hdr.data_size);
        goto cleanup_fin;
    }

    if (fread(in_buf, 1, in_hdr.data_size, fin) != in_hdr.data_size) {
        fprintf(stderr, "resample: failed to read %s's samples\n", in_path);
        goto cleanup_in_buf;
    }
    fclose(fin);
    fin = NULL;

#if DEEMPH_CORRECT
    /* Correct 75 us -> 50 us de-emphasis at the PL's native rate,
     * before any resampling. See the long comment above the function. */
    deemph_75_to_50(in_buf, n_in);
    printf("resample: applied 75us -> 50us de-emphasis correction "
           "(+4.1 dB max treble at the PL rate)\n");
#endif

#if HF_LPF_ENABLE
    /* Applied AFTER de-emphasis correction and BEFORE resampling, same
     * rate (PL_AUDIO_RATE_HZ) the coefficients were computed for. See the
     * long comment above hf_lowpass_8k() for why this exists. */
    hf_lowpass_8k(in_buf, n_in);
    printf("resample: applied 8 kHz HF low-pass (matches Gqrx mono FM "
           "bandwidth)\n");
#endif

    max_out = (int)(((int64_t)n_in * RESAMP_L) / RESAMP_M) + 4;
    out_buf = (int16_t *)malloc((size_t)max_out * sizeof(int16_t));
    if (!out_buf) {
        fprintf(stderr, "resample: malloc failed for output buffer (%d samples)\n",
                max_out);
        goto cleanup_in_buf_only;
    }

    n_out = resample_core(in_buf, n_in, out_buf, max_out);
    printf("resample: %d input samples (%u Hz) -> %d output samples (48k), "
           "L/M = %d/%d\n", n_in, PL_AUDIO_RATE_HZ, n_out, RESAMP_L, RESAMP_M);

    fout = fopen(out_path, "wb");
    if (!fout) {
        perror("resample: fopen(out_path)");
        fprintf(stderr, "resample: failed to open %s\n", out_path);
        goto cleanup_both;
    }

    if (wav_write_header(fout, 48000, 1, 16,
                          (uint32_t)n_out * sizeof(int16_t)) != 0) {
        fprintf(stderr, "resample: failed to write %s's WAV header\n", out_path);
        goto cleanup_fout;
    }

    if (fwrite(out_buf, sizeof(int16_t), (size_t)n_out, fout) != (size_t)n_out) {
        fprintf(stderr, "resample: failed to write %s's samples\n", out_path);
        goto cleanup_fout;
    }

    ret = 0;
    printf("resample: wrote %s (%zu bytes audio)\n", out_path,
           (size_t)n_out * sizeof(int16_t));

cleanup_fout:
    if (fout) fclose(fout);
cleanup_both:
    free(out_buf);
cleanup_in_buf_only:
    free(in_buf);
    return ret;
cleanup_in_buf:
    free(in_buf);
    if (fin) fclose(fin);
    return ret;
cleanup_fin:
    if (fin) fclose(fin);
    return ret;
}
