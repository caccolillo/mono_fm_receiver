/*
 * resample_50k_to_48k.c (Linux port)
 *
 * Identical resampling MATH to the bare-metal version -- same
 * resample_coeffs.h, same resample_core() algorithm, completely
 * unchanged. Only the FILE I/O primitives changed: FATFS (FIL/f_open/
 * f_read/f_write/FRESULT) -> plain POSIX (FILE*/fopen/fread/fwrite).
 * No FATFS/xilffs dependency remains in this file at all.
 */

#include "resample_coeffs.h"
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>

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
 * File-level driver: reads a mono 16-bit PCM WAV at 50 kHz from
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
    if (in_hdr.sample_rate != 50000 || in_hdr.bits_per_sample != 16 ||
        in_hdr.num_channels != 1) {
        fprintf(stderr, "resample: unexpected input format "
                "(rate=%u bits=%u ch=%u), expected 50000/16/1\n",
                in_hdr.sample_rate, in_hdr.bits_per_sample, in_hdr.num_channels);
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

    max_out = (int)(((int64_t)n_in * RESAMP_L) / RESAMP_M) + 4;
    out_buf = (int16_t *)malloc((size_t)max_out * sizeof(int16_t));
    if (!out_buf) {
        fprintf(stderr, "resample: malloc failed for output buffer (%d samples)\n",
                max_out);
        goto cleanup_in_buf_only;
    }

    n_out = resample_core(in_buf, n_in, out_buf, max_out);
    printf("resample: %d input samples (50k) -> %d output samples (48k)\n",
           n_in, n_out);

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
