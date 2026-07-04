/*
 * resample_50k_to_48k.c
 *
 * Rational-ratio (24/25) polyphase FIR resampler, 50 kHz -> 48 kHz,
 * for the FM demodulator's audio output. This is a direct C port of
 * the same algorithm MATLAB's resample(24,25) used in the golden-model
 * MATLAB work (Kaiser-windowed FIR anti-alias filter + polyphase
 * implementation) - not an approximation of it.
 *
 * Derivation (for reference):
 *   Zero-stuff x[] by L, convolve with prototype lowpass h[] (length
 *   numtaps, numtaps a multiple of L), then decimate by M. Because the
 *   zero-stuffed signal is only nonzero at multiples of L, for output
 *   sample m (virtual upsampled position t = m*M):
 *     phase = t mod L
 *     i     = t div L
 *     y[m]  = sum_{k=0}^{taps_per_phase-1} h_poly[phase][k] * x[i-k]
 *   where h_poly[p][k] = h[p + k*L]  (the standard polyphase
 *   decomposition). x[idx] for idx < 0 is treated as 0 (filter
 *   startup transient, same as any FIR).
 *
 * This implementation buffers the whole input signal in RAM, which is
 * the simplest correct approach for a batch WAV-to-WAV conversion (a
 * few minutes of 50 kHz mono 16-bit audio is a few MB - trivial on a
 * Zybo Z7-20's DDR). For very long recordings where that's no longer
 * true, this would need to become a streaming version with a small
 * (taps_per_phase-sample) history ring buffer instead - the per-sample
 * math is identical, only the buffering strategy changes.
 *
 * Uses the Cortex-A9's hardware FPU (VFPv3) via plain float math - no
 * fixed-point needed for a non-real-time batch job like this.
 */

#include "resample_coeffs.h"
#include "ff.h"
#include "xil_printf.h"
#include <stdint.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>

/* --- core sample-rate-conversion math ------------------------------- */

/*
 * Resamples `in[0..n_in-1]` (50 kHz) into `out` (48 kHz), writing at
 * most `max_out` samples. Returns the number of samples actually
 * written. `out` must be pre-allocated by the caller with at least
 * ceil(n_in * RESAMP_L / RESAMP_M) + 1 entries.
 */
static int resample_core(const int16_t *in, int n_in,
                          int16_t *out, int max_out)
{
    int64_t t = 0;
    int m = 0;

    while (m < max_out) {
        int64_t i     = t / RESAMP_L;
        int     phase = (int)(t % RESAMP_L);

        if (i - (RESAMP_TAPS_PER_PHASE - 1) >= n_in) {
            break; /* fully past the end of valid input, including tail */
        }
        if (i < 0) {
            /* shouldn't happen from t=0, kept for safety */
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

        /* stop once we've consumed all real input and are only
         * producing samples from the zero-padded tail */
        if (i >= n_in) break;
    }

    return m;
}

/* --- minimal WAV header, matches the one used in main.c ------------- */

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

static int wav_write_header(FIL *f, uint32_t sample_rate,
                             uint16_t num_channels, uint16_t bits_per_sample,
                             uint32_t data_bytes)
{
    wav_header_t hdr;
    UINT written;

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

    return (f_write(f, &hdr, sizeof(hdr), &written) == FR_OK &&
            written == sizeof(hdr)) ? 0 : -1;
}

/*
 * File-level driver: reads a mono 16-bit PCM WAV at 50 kHz from
 * `in_path`, resamples to 48 kHz, writes it to `out_path`.
 * Returns 0 on success, -1 on failure.
 */
int resample_wav_50k_to_48k(const char *in_path, const char *out_path)
{
    FIL fin, fout;
    FRESULT fres;
    wav_header_t in_hdr;
    UINT br, bw;
    int16_t *in_buf = NULL, *out_buf = NULL;
    int n_in, max_out, n_out;
    int ret = -1;

    fres = f_open(&fin, in_path, FA_READ);
    if (fres != FR_OK) {
        xil_printf("resample: failed to open %s: %d\r\n", in_path, fres);
        return -1;
    }

    if (f_read(&fin, &in_hdr, sizeof(in_hdr), &br) != FR_OK ||
        br != sizeof(in_hdr)) {
        xil_printf("resample: failed to read input WAV header\r\n");
        goto cleanup_fin;
    }
    if (in_hdr.sample_rate != 50000 || in_hdr.bits_per_sample != 16 ||
        in_hdr.num_channels != 1) {
        xil_printf("resample: unexpected input format "
                    "(rate=%lu bits=%u ch=%u), expected 50000/16/1\r\n",
                    (unsigned long)in_hdr.sample_rate,
                    in_hdr.bits_per_sample, in_hdr.num_channels);
        goto cleanup_fin;
    }

    n_in = in_hdr.data_size / sizeof(int16_t);
    in_buf = (int16_t *)malloc(in_hdr.data_size);
    if (!in_buf) {
        xil_printf("resample: malloc(%lu) failed for input buffer\r\n",
                    (unsigned long)in_hdr.data_size);
        goto cleanup_fin;
    }

    fres = f_read(&fin, in_buf, in_hdr.data_size, &br);
    if (fres != FR_OK || br != in_hdr.data_size) {
        xil_printf("resample: failed to read input samples: %d "
                    "(got %u of %lu bytes)\r\n", fres, br,
                    (unsigned long)in_hdr.data_size);
        goto cleanup_in_buf;
    }
    f_close(&fin);

    /* n_out ~= n_in * L / M, allocate with a small safety margin */
    max_out = (int)(((int64_t)n_in * RESAMP_L) / RESAMP_M) + 4;
    out_buf = (int16_t *)malloc((size_t)max_out * sizeof(int16_t));
    if (!out_buf) {
        xil_printf("resample: malloc failed for output buffer (%d samples)\r\n",
                    max_out);
        goto cleanup_in_buf_only;
    }

    n_out = resample_core(in_buf, n_in, out_buf, max_out);
    xil_printf("resample: %d input samples (50k) -> %d output samples (48k)\r\n",
                n_in, n_out);

    fres = f_open(&fout, out_path, FA_WRITE | FA_CREATE_ALWAYS);
    if (fres != FR_OK) {
        xil_printf("resample: failed to open %s: %d\r\n", out_path, fres);
        goto cleanup_both;
    }

    if (wav_write_header(&fout, 48000, 1, 16,
                          (uint32_t)n_out * sizeof(int16_t)) != 0) {
        xil_printf("resample: failed to write output header\r\n");
        goto cleanup_fout;
    }

    fres = f_write(&fout, out_buf, (UINT)n_out * sizeof(int16_t), &bw);
    if (fres != FR_OK || bw != n_out * sizeof(int16_t)) {
        xil_printf("resample: failed to write output samples: %d\r\n", fres);
        goto cleanup_fout;
    }

    ret = 0;
    xil_printf("resample: wrote %s (%lu bytes audio)\r\n", out_path,
                (unsigned long)(n_out * sizeof(int16_t)));

cleanup_fout:
    f_close(&fout);
cleanup_both:
    free(out_buf);
cleanup_in_buf_only:
    free(in_buf);
    return ret;
cleanup_in_buf:
    free(in_buf);
cleanup_fin:
    f_close(&fin);
    return ret;
}
