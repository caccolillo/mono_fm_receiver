/*
 * main.c - Bare-metal FM demodulator bring-up: SD card WAV I/O
 *
 * ARCHITECTURE REWRITE NOTICE: this is a full rewrite, not a patch. The
 * AXI DMA IP the previous version of this file drove (XAxiDma_*, MM2S/
 * S2MM, per-frame one-shot transfers arm'd and polled from software) no
 * longer exists anywhere in this design -- it was replaced by two
 * custom, free-running HLS ping-pong DMA cores (audio_ppdma_0,
 * iq_ppdma_0) with ap_start tied permanently high in the block design.
 * There is no descriptor to arm and no way to pace transfers from
 * software: the hardware runs continuously regardless of what this
 * program does or doesn't do.
 *
 * NEW architecture, concretely:
 *
 *   iq_ppdma_0 continuously reads packed 32-bit I/Q words from one of
 *   two fixed DDR buffers, IQ_PING_ADDR / IQ_PONG_ADDR, IQ_BUF_SIZE_WORDS
 *   words each (10 ms @ 250 kHz), and reports which one it's currently
 *   reading via axi_gpio_0 channel 1 (GPIO_DATA). Software's job: watch
 *   that bit -- every time it flips, the buffer the core just LEFT is
 *   safe to refill with the next IQ_BUF_SIZE_WORDS samples from the
 *   input WAV.
 *
 *   audio_ppdma_0 writes demodulated audio into its own internal
 *   ping/pong pair, then mirrors each completed AUDIO_SAMPLES_PER_BUFFER
 *   -word block (1 ms, matching the compile-time constant in
 *   audio_ppdma.cpp) into one fixed address, AUDIO_DEST_ADDR, and
 *   reports the event via axi_gpio_0 channel 2 (GPIO2_DATA). Software's
 *   job: watch that bit -- every time it flips, a fresh block is ready
 *   at AUDIO_DEST_ADDR to be read, converted, and written to the output
 *   WAV.
 *
 * FLAGGED ASSUMPTIONS (verify before trusting the output):
 *   1. I/Q packing order: assumes the input WAV stores interleaved
 *      16-bit I,Q pairs (I first) and that {I[31:16], Q[15:0]} is the
 *      correct packed-word convention (matches iq_ppdma.h as written).
 *      If audio comes out garbled, this is the first thing to check --
 *      swap the pack order in refill_iq_buffer() if so.
 *   2. sfix32_En13 -> PCM16 scale factor: assumes +-1.0 real-value full
 *      scale (raw / 8192.0 -> [-1,1] -> * 32767). If audio is clipped
 *      or far too quiet, check the actual signal range against
 *      verify_fm_demod_rtl.m's known-good reference and adjust.
 *   3. AXI_GPIO_0_BASEADDR is a literal, not pulled from an actual
 *      generated xparameters.h -- confirm it matches
 *      XPAR_AXI_GPIO_0_BASEADDR (or equivalent) for your BSP.
 *
 * REAL-TIME CONSTRAINT (new -- did not exist under the old per-frame
 * DMA model): because the hardware never stalls for software, the I/Q
 * refill below must complete within roughly
 * IQ_BUF_SIZE_WORDS / 250000 = 10 ms, or iq_ppdma_0 will wrap back onto
 * a buffer that hasn't been refilled yet and re-read stale data. SD
 * card f_read() latency on real hardware is what to measure and budget
 * against here -- this was flagged as an open risk when
 * IQ_BUF_SIZE_WORDS was chosen and has NOT been verified against real
 * SD card timing on this target.
 *
 * STARTUP NOTE: ap_start being tied high means iq_ppdma_0 starts
 * reading DDR the instant the PL configures -- almost certainly before
 * this program's main() ever runs (bitstream loads via FSBL/boot well
 * before this ELF executes). The first several audio samples will
 * reflect whatever was in DDR at power-on, not real I/Q data, until the
 * first refill below catches up. This is an expected startup
 * transient, not a bug to chase.
 *
 * resample_50k_to_48k.c / resample_coeffs.h are UNCHANGED by any of
 * this -- that module is a pure post-processing file-to-file batch
 * resampler with no DMA dependency at all, and is called exactly as
 * before at the end of main().
 */

#include "xparameters.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xil_io.h"
#include "xil_types.h"
#include "ff.h"
#include <string.h>
#include <math.h>
#include <stdint.h>

/* ------------------------------------------------------------------ */
/* Fixed DDR addresses -- MUST match the xlconstant values wired to
 * ping_base/pong_base/dest_base/buf_size_words in bd.tcl. These are
 * raw DDR pointers, not AXI-mapped peripherals, so there is no
 * xparameters.h macro for them -- they are hardware constants baked
 * directly into the block design.
 * ------------------------------------------------------------------ */
#define IQ_PING_ADDR              0x3E000000u   /* xlconstant_1 */
#define IQ_PONG_ADDR              0x3E100000u   /* xlconstant_2 */
#define AUDIO_DEST_ADDR           0x3E400000u   /* xlconstant_5 */
#define IQ_BUF_SIZE_WORDS         2500u         /* 10 ms @ 250 kHz -- xlconstant_6 */
#define AUDIO_SAMPLES_PER_BUFFER  50u           /* 1 ms @ 50 kHz -- audio_ppdma.cpp compile-time constant */

/* How many extra 1 ms audio blocks to keep draining after the input
 * WAV is exhausted, to flush whatever real samples are still in
 * flight (fm_demod's own pipeline latency, plus whatever was left
 * un-consumed in the last-filled I/Q buffer). Conservative, round
 * number -- tune once real pipeline latency is characterized on
 * target; err high rather than clip the ending. */
#define AUDIO_EOF_GRACE_BLOCKS    20u

/* AXI GPIO (dual-channel, both inputs), base address per bd.tcl's
 * assign_bd_address on axi_gpio_0/S_AXI/Reg. See FLAGGED ASSUMPTIONS
 * (3) above. */
#define AXI_GPIO_0_BASEADDR       0x40000000u
#define GPIO_DATA_OFFSET          0x00u   /* channel 1 <- iq_ppdma_0/active_buf */
#define GPIO2_DATA_OFFSET         0x08u   /* channel 2 <- audio_ppdma_0/active_buf */

/* 8.3-safe (3-letter) filenames -- xilffs BSP builds are frequently
 * configured WITHOUT long-filename support (_USE_LFN=0), in which case
 * anything past an 8-char base name / 3-char extension either fails
 * outright or gets silently truncated/mangled. rds.wav already fits;
 * the two names below were previously audio_50k.wav / audio_out.wav
 * (9-char bases), which do NOT fit -- renamed to be safe regardless of
 * how LFN is configured on this BSP. */
#define INPUT_WAV_PATH            "0:/rds.wav"
#define INTERMEDIATE_WAV_PATH     "0:/A50.WAV"
#define OUTPUT_WAV_PATH           "0:/A48.WAV"

int resample_wav_50k_to_48k(const char *in_path, const char *out_path);

static FATFS fatfs;

/* ------------------------------------------------------------------ */
/* FRESULT -> human-readable string. Mirrors the standard FatFs FRESULT
 * enum order (Xilinx's xilffs is a fairly direct port of ChaN's FatFs),
 * but ff.h has had minor reorderings across versions historically --
 * if any of these look wrong against your actual ff.h, that enum
 * ordering is the first thing to check.
 * ------------------------------------------------------------------ */
static const char *fresult_str(FRESULT fr)
{
    switch (fr) {
        case FR_OK:                  return "FR_OK";
        case FR_DISK_ERR:            return "FR_DISK_ERR (low-level I/O error)";
        case FR_INT_ERR:             return "FR_INT_ERR (internal FATFS assertion failed)";
        case FR_NOT_READY:           return "FR_NOT_READY (SD card/disk not ready)";
        case FR_NO_FILE:             return "FR_NO_FILE (file not found)";
        case FR_NO_PATH:             return "FR_NO_PATH (path not found)";
        case FR_INVALID_NAME:        return "FR_INVALID_NAME (bad path/filename format)";
        case FR_DENIED:              return "FR_DENIED (access denied / directory full)";
        case FR_EXIST:               return "FR_EXIST (file already exists)";
        case FR_INVALID_OBJECT:      return "FR_INVALID_OBJECT (invalid/stale file object)";
        case FR_WRITE_PROTECTED:     return "FR_WRITE_PROTECTED";
        case FR_INVALID_DRIVE:       return "FR_INVALID_DRIVE";
        case FR_NOT_ENABLED:         return "FR_NOT_ENABLED (volume not mounted)";
        case FR_NO_FILESYSTEM:       return "FR_NO_FILESYSTEM (no valid FAT volume found)";
        case FR_MKFS_ABORTED:        return "FR_MKFS_ABORTED";
        case FR_TIMEOUT:             return "FR_TIMEOUT";
        case FR_LOCKED:              return "FR_LOCKED";
        case FR_NOT_ENOUGH_CORE:     return "FR_NOT_ENOUGH_CORE (out of memory)";
        case FR_TOO_MANY_OPEN_FILES: return "FR_TOO_MANY_OPEN_FILES";
        case FR_INVALID_PARAMETER:   return "FR_INVALID_PARAMETER";
        default:                     return "FR_<unrecognized code>";
    }
}

/* ------------------------------------------------------------------ */
/* Lists every entry in the SD card's root directory with size, so a
 * "file not found" further down has an immediate, concrete answer for
 * "well what IS actually on the card, and under what exact name/case".
 * Uses the plain fno.fname field (older/simpler FILINFO layout, no
 * separate lfname buffer) -- matches the common Xilinx xilffs FILINFO
 * struct, but this hasn't been verified against your exact ff.h; if it
 * doesn't compile, that struct layout is the first thing to check.
 * ------------------------------------------------------------------ */
static void list_sd_card_root(void)
{
    DIR dir;
    FILINFO fno;
    FRESULT fres;
    int count = 0;

    xil_printf("--- SD card root directory listing (0:/) ---\r\n");

    fres = f_opendir(&dir, "0:/");
    if (fres != FR_OK) {
        xil_printf("f_opendir(0:/) failed: %s (%d)\r\n", fresult_str(fres), fres);
        return;
    }

    for (;;) {
        fres = f_readdir(&dir, &fno);
        if (fres != FR_OK) {
            xil_printf("f_readdir failed: %s (%d)\r\n", fresult_str(fres), fres);
            break;
        }
        if (fno.fname[0] == 0) {
            break; /* end of directory */
        }
        if (fno.fattrib & AM_DIR) {
            xil_printf("  <DIR>       %s\r\n", fno.fname);
        } else {
            xil_printf("  %10lu  %s\r\n", (unsigned long)fno.fsize, fno.fname);
        }
        count++;
    }

    f_closedir(&dir);
    xil_printf("--- end of listing (%d entries) ---\r\n", count);
}

/* ------------------------------------------------------------------ */
/* Minimal canonical 44-byte PCM WAV header (unchanged from before)    */
/* ------------------------------------------------------------------ */
typedef struct __attribute__((packed)) {
    char  riff_id[4];
    u32   riff_size;
    char  wave_id[4];
    char  fmt_id[4];
    u32   fmt_size;
    u16   audio_format;
    u16   num_channels;
    u32   sample_rate;
    u32   byte_rate;
    u16   block_align;
    u16   bits_per_sample;
    char  data_id[4];
    u32   data_size;
} wav_header_t;

static int wav_write_placeholder_header(FIL *f, u32 sample_rate,
                                         u16 num_channels, u16 bits_per_sample)
{
    wav_header_t hdr;
    UINT written;

    memcpy(hdr.riff_id, "RIFF", 4);
    hdr.riff_size = 0; /* patched later */
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
    hdr.data_size = 0; /* patched later */

    return (f_write(f, &hdr, sizeof(hdr), &written) == FR_OK &&
            written == sizeof(hdr)) ? 0 : -1;
}

static int wav_patch_header(FIL *f, u32 data_bytes)
{
    UINT written;
    u32 riff_size = data_bytes + sizeof(wav_header_t) - 8;

    if (f_lseek(f, 4) != FR_OK) return -1;
    if (f_write(f, &riff_size, 4, &written) != FR_OK || written != 4) return -1;

    if (f_lseek(f, 40) != FR_OK) return -1;
    if (f_write(f, &data_bytes, 4, &written) != FR_OK || written != 4) return -1;

    return 0;
}

/* ------------------------------------------------------------------ */
/* GPIO helpers -- direct register access, no DMA involved at all.     */
/* ------------------------------------------------------------------ */
static inline u32 gpio_read_iq_active(void)
{
    return Xil_In32(AXI_GPIO_0_BASEADDR + GPIO_DATA_OFFSET) & 0x1u;
}

static inline u32 gpio_read_audio_active(void)
{
    return Xil_In32(AXI_GPIO_0_BASEADDR + GPIO2_DATA_OFFSET) & 0x1u;
}

/* ------------------------------------------------------------------ */
/* Static scratch buffers -- deliberately NOT stack-allocated. 2 *
 * IQ_BUF_SIZE_WORDS int16 samples is 10000 bytes; on a typical
 * bare-metal Cortex-A9 stack (often just a few KB by default) that
 * would risk a silent stack overflow if put on the stack instead. */
/* ------------------------------------------------------------------ */
static int16_t iq_stage[2 * IQ_BUF_SIZE_WORDS] __attribute__((aligned(64)));
static u32     iq_packed[IQ_BUF_SIZE_WORDS]    __attribute__((aligned(64)));
static int16_t audio_pcm_block[AUDIO_SAMPLES_PER_BUFFER] __attribute__((aligned(64)));

/*
 * Refills one ping/pong I/Q buffer with the next IQ_BUF_SIZE_WORDS
 * sample pairs from the input WAV, packing each pair into the 32-bit
 * word format iq_ppdma_0 expects (see FLAGGED ASSUMPTION 1 above).
 * Zero-pads the tail if fewer real samples remain. Sets *eof_hit if
 * this call reached the end of the input file.
 */
static void refill_iq_buffer(FIL *fin, u32 dest_addr, int *eof_hit)
{
    UINT bytes_read;
    FRESULT fres;
    u32 pairs_read;

    fres = f_read(fin, iq_stage, sizeof(iq_stage), &bytes_read);
    if (fres != FR_OK) {
        xil_printf("refill_iq_buffer: f_read(%s) failed: %s (%d) [dest_addr=0x%08lx]\r\n",
                   INPUT_WAV_PATH, fresult_str(fres), fres, (unsigned long)dest_addr);
        *eof_hit = 1;
        return;
    }

    pairs_read = bytes_read / (2 * sizeof(int16_t));
    if (pairs_read < IQ_BUF_SIZE_WORDS) {
        *eof_hit = 1;
    }

    for (u32 i = 0; i < IQ_BUF_SIZE_WORDS; i++) {
        if (i < pairs_read) {
            int16_t I = iq_stage[2 * i];
            int16_t Q = iq_stage[2 * i + 1];
            iq_packed[i] = ((u32)(u16)I << 16) | (u32)(u16)Q;
        } else {
            iq_packed[i] = 0; /* zero-pad the tail */
        }
    }

    memcpy((void *)(uintptr_t)dest_addr, iq_packed, sizeof(iq_packed));
    Xil_DCacheFlushRange((INTPTR)dest_addr, sizeof(iq_packed));
}

/*
 * Reads one completed AUDIO_SAMPLES_PER_BUFFER-word block from
 * AUDIO_DEST_ADDR, converts each sfix32_En13 sample to 16-bit PCM (see
 * FLAGGED ASSUMPTION 2 above), and writes it to the output WAV.
 * Returns 0 on success.
 */
static int drain_audio_block(FIL *fout, u32 *total_audio_bytes)
{
    FRESULT fres;
    UINT bytes_written;
    u32 i;

    /* Cache coherency: audio_ppdma_0 writes AUDIO_DEST_ADDR via the
     * HP0 port, which bypasses the ARM L1/L2 data cache. Without an
     * explicit invalidate the CPU may read stale cached content from a
     * previous read of the same address rather than the fresh data the
     * PL just wrote to DDR.
     *
     * The invalidate MUST come before ANY CPU read of this region --
     * including the memcpy below. Calling it after the reads (or
     * omitting it) leaves the cache holding stale data and the PCM
     * output will be silence or garbage from power-on DDR content.
     *
     * Size: AUDIO_SAMPLES_PER_BUFFER * 4 bytes, aligned to cache line
     * (audio_dest_raw is 64-byte aligned, so this is always correct). */
    static u32 audio_dest_raw[AUDIO_SAMPLES_PER_BUFFER]
        __attribute__((aligned(64)));

    Xil_DCacheInvalidateRange((INTPTR)audio_dest_raw,
                               sizeof(audio_dest_raw));

    /* Copy from DDR into a local aligned buffer AFTER invalidate, so
     * the CPU fetches fresh lines from DDR into cache, not stale ones.
     * Using memcpy (not Xil_In32) means the CPU uses its cached data
     * path after the invalidate, which is what we want. */
    memcpy(audio_dest_raw,
           (const void *)(uintptr_t)AUDIO_DEST_ADDR,
           sizeof(audio_dest_raw));

    for (i = 0; i < AUDIO_SAMPLES_PER_BUFFER; i++) {
        int32_t raw = (int32_t)audio_dest_raw[i];

        /* sfix32_En13 -> real value, ASSUMED +-1.0 full scale.
         * Divide by 2^13 = 8192 to get real value in [-1, +1),
         * then scale to int16 range. */
        float val    = (float)raw / 8192.0f;
        float scaled = val * 32767.0f;
        if (scaled > 32767.0f)  scaled = 32767.0f;
        if (scaled < -32768.0f) scaled = -32768.0f;
        audio_pcm_block[i] = (int16_t)lroundf(scaled);
    }

    fres = f_write(fout, audio_pcm_block, sizeof(audio_pcm_block), &bytes_written);
    if (fres != FR_OK || bytes_written != sizeof(audio_pcm_block)) {
        xil_printf("drain_audio_block: f_write(%s) failed: %s (%d)\r\n",
                   INTERMEDIATE_WAV_PATH, fresult_str(fres), fres);
        return -1;
    }

    *total_audio_bytes += bytes_written;
    return 0;
}

int main(void)
{
    FRESULT fres;
    FIL fin, fout;
    u32 total_audio_bytes = 0;
    int input_eof = 0;
    int draining_grace = 0;
    u32 grace_blocks_remaining = 0;
    u32 iq_prev, audio_prev;

    Xil_DCacheEnable();
    Xil_ICacheEnable();

    xil_printf("=== FM Demod bare-metal bring-up (SD card WAV I/O, ping-pong ppdma) ===\r\n");

    fres = f_mount(&fatfs, "0:/", 1);
    if (fres != FR_OK) {
        xil_printf("f_mount(\"0:/\") failed: %s (%d)\r\n", fresult_str(fres), fres);
        return -1;
    }

    /* Show what's actually on the card before trying to open anything --
     * if INPUT_WAV_PATH is misnamed, wrong-case, or just not there, this
     * makes that immediately obvious instead of a bare FR_NO_FILE. */
    list_sd_card_root();

    fres = f_open(&fin, INPUT_WAV_PATH, FA_READ);
    if (fres != FR_OK) {
        xil_printf("Failed to open %s: %s (%d) -- check the directory "
                   "listing above for the exact filename/case\r\n",
                   INPUT_WAV_PATH, fresult_str(fres), fres);
        return -1;
    }
    xil_printf("Opened %s (%lu bytes)\r\n", INPUT_WAV_PATH, (unsigned long)f_size(&fin));

    if (f_lseek(&fin, sizeof(wav_header_t)) != FR_OK) {
        xil_printf("Failed to skip %s's WAV header (%lu bytes)\r\n",
                   INPUT_WAV_PATH, (unsigned long)sizeof(wav_header_t));
        return -1;
    }

    fres = f_open(&fout, INTERMEDIATE_WAV_PATH, FA_WRITE | FA_CREATE_ALWAYS);
    if (fres != FR_OK) {
        xil_printf("Failed to open %s: %s (%d)\r\n",
                   INTERMEDIATE_WAV_PATH, fresult_str(fres), fres);
        return -1;
    }
    if (wav_write_placeholder_header(&fout, 50000, 1, 16) != 0) {
        xil_printf("Failed to write placeholder WAV header to %s\r\n",
                   INTERMEDIATE_WAV_PATH);
        return -1;
    }

    /* Prime BOTH I/Q buffers immediately -- see STARTUP NOTE above:
     * iq_ppdma_0 is very likely already running against whatever
     * garbage was in DDR at power-on by the time we get here. This
     * doesn't eliminate that startup transient (not achievable from
     * software given ap_start is hardwired high), it just gets real
     * data in as fast as possible. */
    {
        int eof_tmp = 0;
        refill_iq_buffer(&fin, IQ_PING_ADDR, &eof_tmp);
        if (eof_tmp) input_eof = 1;
        refill_iq_buffer(&fin, IQ_PONG_ADDR, &eof_tmp);
        if (eof_tmp) input_eof = 1;
    }

    iq_prev    = gpio_read_iq_active();
    audio_prev = gpio_read_audio_active();

    /* Progress counters, printed only every PROGRESS_PRINT_EVERY_*
     * events -- deliberately throttled. Printing on every single
     * refill/drain (every ~10 ms / ~1 ms respectively) would put real
     * UART transmission time inside the same hot loop whose timing
     * budget we've already flagged as tight; that would make the very
     * problem we're trying to debug worse. */
    u32 iq_refill_count = 0;
    u32 audio_block_count = 0;
    #define PROGRESS_PRINT_EVERY_IQ_REFILLS    10u  /* ~100 ms */
    #define PROGRESS_PRINT_EVERY_AUDIO_BLOCKS 100u  /* ~100 ms */

    for (;;) {
        u32 iq_now = gpio_read_iq_active();
        if (iq_now != iq_prev) {
            /* Core just switched TO iq_now, i.e. it just finished
             * reading the OTHER buffer -- that one is now free. */
            u32 free_addr = (iq_now == 0) ? IQ_PONG_ADDR : IQ_PING_ADDR;
            if (!input_eof) {
                int eof_tmp = 0;
                refill_iq_buffer(&fin, free_addr, &eof_tmp);
                iq_refill_count++;
                if ((iq_refill_count % PROGRESS_PRINT_EVERY_IQ_REFILLS) == 0) {
                    xil_printf("  [progress] iq refills=%lu\r\n",
                               (unsigned long)iq_refill_count);
                }
                if (eof_tmp) {
                    input_eof = 1;
                    draining_grace = 1;
                    grace_blocks_remaining = AUDIO_EOF_GRACE_BLOCKS;
                    xil_printf("Input WAV %s exhausted after %lu refills, "
                               "draining pipeline (%lu more blocks)...\r\n",
                               INPUT_WAV_PATH, (unsigned long)iq_refill_count,
                               (unsigned long)grace_blocks_remaining);
                }
            }
            iq_prev = iq_now;
        }

        u32 audio_now = gpio_read_audio_active();
        if (audio_now != audio_prev) {
            if (drain_audio_block(&fout, &total_audio_bytes) != 0) {
                xil_printf("Aborting main loop after %lu audio blocks "
                           "(%lu bytes written to %s)\r\n",
                           (unsigned long)audio_block_count,
                           (unsigned long)total_audio_bytes,
                           INTERMEDIATE_WAV_PATH);
                break;
            }
            audio_block_count++;
            if ((audio_block_count % PROGRESS_PRINT_EVERY_AUDIO_BLOCKS) == 0) {
                xil_printf("  [progress] audio blocks=%lu (%lu bytes)\r\n",
                           (unsigned long)audio_block_count,
                           (unsigned long)total_audio_bytes);
            }

            if (draining_grace) {
                if (grace_blocks_remaining == 0) {
                    xil_printf("Pipeline drain complete after %lu total "
                               "audio blocks\r\n",
                               (unsigned long)audio_block_count);
                    break; /* pipeline flushed, done */
                }
                grace_blocks_remaining--;
            }

            audio_prev = audio_now;
        }
    }

    if (wav_patch_header(&fout, total_audio_bytes) != 0) {
        xil_printf("Warning: failed to patch output WAV header\r\n");
    }

    f_close(&fin);
    f_close(&fout);

    xil_printf("Native-rate pass done: %lu bytes at 50kHz written to %s\r\n",
               (unsigned long)total_audio_bytes, INTERMEDIATE_WAV_PATH);

    /* Second pass: resample the intermediate 50kHz audio down to the
     * standard 48kHz rate -- unchanged, no DMA dependency. */
    if (resample_wav_50k_to_48k(INTERMEDIATE_WAV_PATH, OUTPUT_WAV_PATH) != 0) {
        xil_printf("Resample pass failed\r\n");
        f_mount(NULL, "0:/", 1);
        return -1;
    }

    f_mount(NULL, "0:/", 1);

    xil_printf("Done. Final 48kHz audio written to %s\r\n", OUTPUT_WAV_PATH);

    return 0;
}
