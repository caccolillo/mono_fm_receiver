/*
 * fmdemod-linux.c - Linux userspace port of the bare-metal FM demod
 * bring-up app (main.c). Same job: refill iq_ppdma_0's ping/pong DDR
 * buffers from a WAV file, drain audio_ppdma_0's mirrored output block
 * by block, convert to PCM16, write a WAV, then resample 50k -> 48k.
 *
 * WHAT CHANGED FROM THE BARE-METAL VERSION, AND WHY:
 *
 *   File I/O: FATFS -> plain POSIX (fopen/fread/fwrite). This is a
 *   real filesystem now -- the 8.3 / 3-letter filename constraint from
 *   the bare-metal version no longer applies at all. Filenames below
 *   are back to descriptive names.
 *
 *   Register/DDR access: Xil_In32/Xil_Out32/Xil_DCache* -> mmap() over
 *   /dev/mem. See the CACHE COHERENCY note below -- this is the single
 *   biggest unverified risk in this port.
 *
 *   GPIO: direct AXI GPIO register peeking -> libgpiod v1.x character-
 *   device API. See GPIO CHIP/LINE NUMBERING note below -- also
 *   unverified without running gpiodetect/gpioinfo on real hardware.
 *
 *   Real-time behavior: WORSE than bare-metal, not better. Bare-metal
 *   ran a fully deterministic single superloop; this runs under a
 *   general-purpose (non-RT, unless you've patched in PREEMPT_RT,
 *   which nothing here assumes) Linux scheduler, subject to arbitrary
 *   preemption, page faults, and other processes. The already-tight
 *   ~10ms I/Q refill budget is now running in a materially less
 *   deterministic environment. This code requests SCHED_FIFO + mlockall
 *   as standard best-effort mitigations, but that is NOT a hard
 *   real-time guarantee on a stock kernel.
 *
 * ----------------------------------------------------------------------
 * CACHE COHERENCY (the biggest open risk in this file):
 *
 * The Zynq-7000's S_AXI_HP ports (which audio_ppdma_0/iq_ppdma_0 use
 * per bd.tcl) are NOT cache-coherent with the ARM cores by default --
 * unlike the ACP port, HP-port PL masters can read/write DDR without
 * the ARM cores' data caches being snooped or updated. Bare-metal
 * handled this explicitly with Xil_DCacheFlushRange/InvalidateRange.
 * Plain Linux userspace has no equivalent portable syscall to flush/
 * invalidate an arbitrary physical range mapped via /dev/mem.
 *
 * Mitigation used here: opening /dev/mem with O_SYNC before mmap()
 * produces an UNCACHED mapping on ARM Linux -- this is a real,
 * long-established technique (used by tools like devmem2 and referenced
 * throughout embedded-Linux/Xilinx documentation for exactly this
 * "userspace sharing a DMA buffer with non-coherent PL hardware"
 * scenario), and is what this file relies on for all three DDR
 * mappings below. Buffers here are tiny (10 KB / 200 B) and accessed
 * infrequently (every ~1-10 ms), so the performance cost of uncached
 * access is a non-issue. This has NOT been verified on real hardware
 * from this side -- worth confirming with a simple read-back test
 * during bring-up before trusting long unattended runs.
 * ----------------------------------------------------------------------
 * GPIO CHIP/LINE NUMBERING (unverified assumption):
 *
 * axi_gpio_0's two 1-bit channels (iq_ppdma_0/active_buf on channel 1,
 * audio_ppdma_0/active_buf on channel 2) will appear as GPIO lines on
 * whatever gpiochip Linux's gpio-xilinx driver registers for this
 * instance. This file assumes ONE gpiochip with line 0 = channel 1,
 * line 1 = channel 2 -- a reasonable default guess, but exact
 * numbering depends on kernel probe order and the generated device
 * tree, not something derivable from bd.tcl alone. CONFIRM with
 * `gpiodetect` and `gpioinfo` on the actual running target before
 * trusting GPIOCHIP_NAME/IQ_ACTIVE_LINE/AUDIO_ACTIVE_LINE below, and
 * adjust if they don't match.
 * ----------------------------------------------------------------------
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sched.h>
#include <math.h>
#include <gpiod.h>

/* ------------------------------------------------------------------ */
/* Fixed DDR physical addresses -- MUST match bd.tcl's xlconstant
 * values, and MUST be covered by the reserved-memory/no-map nodes in
 * system-user.dtsi (delivered alongside this file). */
/* ------------------------------------------------------------------ */
#define IQ_PING_ADDR              0x3E000000u
#define IQ_PONG_ADDR              0x3E100000u
#define AUDIO_DEST_ADDR           0x3E400000u
#define IQ_BUF_SIZE_WORDS         2500u
#define AUDIO_SAMPLES_PER_BUFFER  50u
#define MMAP_REGION_SIZE          0x100000u   /* 1 MB per region, matches dtsi */

#define AUDIO_EOF_GRACE_BLOCKS    20u

/* GPIO chip/line -- see GPIO CHIP/LINE NUMBERING note above. */
#define GPIOCHIP_NAME             "gpiochip0"
#define IQ_ACTIVE_LINE            0
#define AUDIO_ACTIVE_LINE         1

#define INPUT_WAV_PATH            "rds.wav"
#define INTERMEDIATE_WAV_PATH     "audio_50k.wav"
#define OUTPUT_WAV_PATH           "audio_out.wav"

int resample_wav_50k_to_48k(const char *in_path, const char *out_path);

typedef struct __attribute__((packed)) {
    char     riff_id[4];
    uint32_t riff_size;
    char     wave_id[4];
    char     fmt_id[4];
    uint32_t fmt_size;
    uint16_t audio_format;
    uint16_t num_channels;
    uint32_t sample_rate;
    uint32_t byte_rate;
    uint16_t block_align;
    uint16_t bits_per_sample;
    char     data_id[4];
    uint32_t data_size;
} wav_header_t;

static int wav_write_placeholder_header(FILE *f, uint32_t sample_rate,
                                         uint16_t num_channels,
                                         uint16_t bits_per_sample)
{
    wav_header_t hdr;

    memcpy(hdr.riff_id, "RIFF", 4);
    hdr.riff_size = 0;
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
    hdr.data_size = 0;

    return (fwrite(&hdr, 1, sizeof(hdr), f) == sizeof(hdr)) ? 0 : -1;
}

static int wav_patch_header(FILE *f, uint32_t data_bytes)
{
    uint32_t riff_size = data_bytes + (uint32_t)sizeof(wav_header_t) - 8;

    if (fseek(f, 4, SEEK_SET) != 0) return -1;
    if (fwrite(&riff_size, 4, 1, f) != 1) return -1;

    if (fseek(f, 40, SEEK_SET) != 0) return -1;
    if (fwrite(&data_bytes, 4, 1, f) != 1) return -1;

    fflush(f);
    return 0;
}

/* ------------------------------------------------------------------ */
/* /dev/mem mapping helper. O_SYNC on the fd is what makes the
 * resulting mapping uncached on ARM Linux -- see CACHE COHERENCY note
 * at the top of this file. */
/* ------------------------------------------------------------------ */
static volatile void *map_phys_region(int devmem_fd, uint32_t phys_addr, size_t size)
{
    void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED,
                   devmem_fd, (off_t)phys_addr);
    if (p == MAP_FAILED) {
        fprintf(stderr, "mmap failed for phys 0x%08x (size 0x%zx): %s\n",
                phys_addr, size, strerror(errno));
        return NULL;
    }
    return p;
}

/* ------------------------------------------------------------------ */
/* Best-effort real-time scheduling. See the top-of-file note: this is
 * NOT a hard real-time guarantee on a stock (non-PREEMPT_RT) kernel,
 * just the standard mitigations available without one. */
/* ------------------------------------------------------------------ */
static void try_enable_realtime_scheduling(void)
{
    struct sched_param sp;
    sp.sched_priority = sched_get_priority_max(SCHED_FIFO);

    if (sched_setscheduler(0, SCHED_FIFO, &sp) != 0) {
        fprintf(stderr, "Warning: sched_setscheduler(SCHED_FIFO) failed: %s "
                "(need root/CAP_SYS_NICE -- continuing under the default "
                "scheduler, timing will be less deterministic)\n",
                strerror(errno));
    } else {
        printf("SCHED_FIFO priority %d enabled.\n", sp.sched_priority);
    }

    if (mlockall(MCL_CURRENT | MCL_FUTURE) != 0) {
        fprintf(stderr, "Warning: mlockall failed: %s (pages may still be "
                "swapped/faulted during the run)\n", strerror(errno));
    }
}

/* ------------------------------------------------------------------ */
/* GPIO helpers via libgpiod v1.x. See GPIO CHIP/LINE NUMBERING note. */
/* ------------------------------------------------------------------ */
static struct gpiod_chip *g_chip;
static struct gpiod_line *g_iq_line;
static struct gpiod_line *g_audio_line;

static int gpio_init(void)
{
    g_chip = gpiod_chip_open_by_name(GPIOCHIP_NAME);
    if (!g_chip) {
        fprintf(stderr, "gpiod_chip_open_by_name(%s) failed: %s\n",
                GPIOCHIP_NAME, strerror(errno));
        fprintf(stderr, "Run `gpiodetect` and `gpioinfo` on target to find "
                "the correct chip name and line offsets for axi_gpio_0, "
                "then update GPIOCHIP_NAME/IQ_ACTIVE_LINE/AUDIO_ACTIVE_LINE "
                "at the top of this file.\n");
        return -1;
    }

    g_iq_line = gpiod_chip_get_line(g_chip, IQ_ACTIVE_LINE);
    g_audio_line = gpiod_chip_get_line(g_chip, AUDIO_ACTIVE_LINE);
    if (!g_iq_line || !g_audio_line) {
        fprintf(stderr, "gpiod_chip_get_line failed (iq line=%d, audio line=%d): %s\n",
                IQ_ACTIVE_LINE, AUDIO_ACTIVE_LINE, strerror(errno));
        return -1;
    }

    if (gpiod_line_request_input(g_iq_line, "fmdemod-linux") != 0 ||
        gpiod_line_request_input(g_audio_line, "fmdemod-linux") != 0) {
        fprintf(stderr, "gpiod_line_request_input failed: %s\n", strerror(errno));
        return -1;
    }

    return 0;
}

static void gpio_cleanup(void)
{
    if (g_iq_line) gpiod_line_release(g_iq_line);
    if (g_audio_line) gpiod_line_release(g_audio_line);
    if (g_chip) gpiod_chip_close(g_chip);
}

static inline int gpio_read_iq_active(void)
{
    return gpiod_line_get_value(g_iq_line);
}

static inline int gpio_read_audio_active(void)
{
    return gpiod_line_get_value(g_audio_line);
}

/* ------------------------------------------------------------------ */
/* I/Q refill + audio drain -- same logic as the bare-metal version,
 * ported onto mmap()'d /dev/mem pointers instead of Xil_In32/Out32. */
/* ------------------------------------------------------------------ */
static int16_t iq_stage[2 * IQ_BUF_SIZE_WORDS];
static uint32_t iq_packed[IQ_BUF_SIZE_WORDS];
static int16_t audio_pcm_block[AUDIO_SAMPLES_PER_BUFFER];

static void refill_iq_buffer(FILE *fin, volatile uint32_t *dest, int *eof_hit)
{
    size_t bytes_read = fread(iq_stage, 1, sizeof(iq_stage), fin);
    uint32_t pairs_read = (uint32_t)(bytes_read / (2 * sizeof(int16_t)));

    if (pairs_read < IQ_BUF_SIZE_WORDS) {
        *eof_hit = 1;
    }

    for (uint32_t i = 0; i < IQ_BUF_SIZE_WORDS; i++) {
        if (i < pairs_read) {
            int16_t I = iq_stage[2 * i];
            int16_t Q = iq_stage[2 * i + 1];
            iq_packed[i] = ((uint32_t)(uint16_t)I << 16) | (uint32_t)(uint16_t)Q;
        } else {
            iq_packed[i] = 0;
        }
    }

    memcpy((void *)dest, iq_packed, sizeof(iq_packed));
}

static int drain_audio_block(volatile uint32_t *src, FILE *fout,
                              uint32_t *total_audio_bytes)
{
    for (uint32_t i = 0; i < AUDIO_SAMPLES_PER_BUFFER; i++) {
        int32_t raw = (int32_t)src[i];

        /* sfix32_En13 -> real value, ASSUMED +-1.0 full scale -- same
         * flagged assumption as the bare-metal version; verify against
         * verify_fm_demod_rtl.m if audio is clipped or too quiet. */
        float val    = (float)raw / 8192.0f;
        float scaled = val * 32767.0f;
        if (scaled > 32767.0f)  scaled = 32767.0f;
        if (scaled < -32768.0f) scaled = -32768.0f;
        audio_pcm_block[i] = (int16_t)lroundf(scaled);
    }

    size_t written = fwrite(audio_pcm_block, 1, sizeof(audio_pcm_block), fout);
    if (written != sizeof(audio_pcm_block)) {
        fprintf(stderr, "drain_audio_block: fwrite failed (%zu of %zu bytes)\n",
                written, sizeof(audio_pcm_block));
        return -1;
    }

    *total_audio_bytes += (uint32_t)written;
    return 0;
}

int main(void)
{
    int devmem_fd;
    volatile uint32_t *iq_ping, *iq_pong, *audio_dest;
    FILE *fin = NULL, *fout = NULL;
    uint32_t total_audio_bytes = 0;
    int input_eof = 0, draining_grace = 0;
    uint32_t grace_blocks_remaining = 0;
    int iq_prev, audio_prev;
    uint32_t iq_refill_count = 0, audio_block_count = 0;
    int ret = 1;

    printf("=== FM Demod Linux bring-up (WAV I/O, ping-pong ppdma) ===\n");

    try_enable_realtime_scheduling();

    /* O_SYNC is load-bearing here -- see CACHE COHERENCY note. */
    devmem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (devmem_fd < 0) {
        perror("open(/dev/mem) -- are you running as root?");
        return 1;
    }

    iq_ping    = (volatile uint32_t *)map_phys_region(devmem_fd, IQ_PING_ADDR, MMAP_REGION_SIZE);
    iq_pong    = (volatile uint32_t *)map_phys_region(devmem_fd, IQ_PONG_ADDR, MMAP_REGION_SIZE);
    audio_dest = (volatile uint32_t *)map_phys_region(devmem_fd, AUDIO_DEST_ADDR, MMAP_REGION_SIZE);
    if (!iq_ping || !iq_pong || !audio_dest) {
        goto cleanup_maps;
    }

    if (gpio_init() != 0) {
        goto cleanup_gpio;
    }

    fin = fopen(INPUT_WAV_PATH, "rb");
    if (!fin) {
        perror("fopen(INPUT_WAV_PATH)");
        fprintf(stderr, "Failed to open %s (cwd matters -- run from the "
                "directory containing your WAV files, or use an absolute "
                "path)\n", INPUT_WAV_PATH);
        goto cleanup_gpio;
    }
    fseek(fin, 0, SEEK_END);
    printf("Opened %s (%ld bytes)\n", INPUT_WAV_PATH, ftell(fin));
    fseek(fin, (long)sizeof(wav_header_t), SEEK_SET);

    fout = fopen(INTERMEDIATE_WAV_PATH, "wb");
    if (!fout) {
        perror("fopen(INTERMEDIATE_WAV_PATH)");
        goto cleanup_fin;
    }
    if (wav_write_placeholder_header(fout, 50000, 1, 16) != 0) {
        fprintf(stderr, "Failed to write placeholder WAV header to %s\n",
                INTERMEDIATE_WAV_PATH);
        goto cleanup_fout;
    }

    /* Prime both buffers before entering the poll loop -- same
     * STARTUP NOTE as bare-metal: ap_start is tied high, so
     * iq_ppdma_0 is very likely already running against whatever was
     * in DDR before we got here. This just gets real data in ASAP. */
    {
        int eof_tmp = 0;
        refill_iq_buffer(fin, iq_ping, &eof_tmp);
        if (eof_tmp) input_eof = 1;
        refill_iq_buffer(fin, iq_pong, &eof_tmp);
        if (eof_tmp) input_eof = 1;
    }

    iq_prev    = gpio_read_iq_active();
    audio_prev = gpio_read_audio_active();
    if (iq_prev < 0 || audio_prev < 0) {
        fprintf(stderr, "Initial gpiod_line_get_value failed\n");
        goto cleanup_fout;
    }

    printf("Entering poll loop...\n");

    for (;;) {
        int iq_now = gpio_read_iq_active();
        if (iq_now < 0) {
            fprintf(stderr, "gpiod_line_get_value(iq) failed: %s\n", strerror(errno));
            break;
        }
        if (iq_now != iq_prev) {
            volatile uint32_t *free_buf = (iq_now == 0) ? iq_pong : iq_ping;
            if (!input_eof) {
                int eof_tmp = 0;
                refill_iq_buffer(fin, free_buf, &eof_tmp);
                iq_refill_count++;
                if ((iq_refill_count % 10) == 0) {
                    printf("  [progress] iq refills=%u\n", iq_refill_count);
                }
                if (eof_tmp) {
                    input_eof = 1;
                    draining_grace = 1;
                    grace_blocks_remaining = AUDIO_EOF_GRACE_BLOCKS;
                    printf("Input WAV exhausted after %u refills, "
                           "draining pipeline (%u more blocks)...\n",
                           iq_refill_count, grace_blocks_remaining);
                }
            }
            iq_prev = iq_now;
        }

        int audio_now = gpio_read_audio_active();
        if (audio_now < 0) {
            fprintf(stderr, "gpiod_line_get_value(audio) failed: %s\n", strerror(errno));
            break;
        }
        if (audio_now != audio_prev) {
            if (drain_audio_block(audio_dest, fout, &total_audio_bytes) != 0) {
                break;
            }
            audio_block_count++;
            if ((audio_block_count % 100) == 0) {
                printf("  [progress] audio blocks=%u (%u bytes)\n",
                       audio_block_count, total_audio_bytes);
            }

            if (draining_grace) {
                if (grace_blocks_remaining == 0) {
                    printf("Pipeline drain complete after %u total audio blocks\n",
                           audio_block_count);
                    ret = 0;
                    break;
                }
                grace_blocks_remaining--;
            }

            audio_prev = audio_now;
        }
    }

    if (wav_patch_header(fout, total_audio_bytes) != 0) {
        fprintf(stderr, "Warning: failed to patch %s's header\n", INTERMEDIATE_WAV_PATH);
    }

    printf("Native-rate pass done: %u bytes at 50kHz written to %s\n",
           total_audio_bytes, INTERMEDIATE_WAV_PATH);

    fclose(fin);  fin = NULL;
    fclose(fout); fout = NULL;

    if (ret == 0) {
        if (resample_wav_50k_to_48k(INTERMEDIATE_WAV_PATH, OUTPUT_WAV_PATH) != 0) {
            fprintf(stderr, "Resample pass failed\n");
            ret = 1;
        } else {
            printf("Done. Final 48kHz audio written to %s\n", OUTPUT_WAV_PATH);
        }
    }

cleanup_fout:
    if (fout) fclose(fout);
cleanup_fin:
    if (fin) fclose(fin);
cleanup_gpio:
    gpio_cleanup();
cleanup_maps:
    if (iq_ping)    munmap((void *)iq_ping, MMAP_REGION_SIZE);
    if (iq_pong)    munmap((void *)iq_pong, MMAP_REGION_SIZE);
    if (audio_dest) munmap((void *)audio_dest, MMAP_REGION_SIZE);
cleanup_devmem:
    close(devmem_fd);

    return ret;
}
