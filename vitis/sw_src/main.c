/*
 * main.c - Bare-metal FM demodulator bring-up: SD card WAV I/O
 *
 * DEBUG BUILD: this version adds verbose diagnostic prints at every
 * critical point to isolate why audio output is wrong or silent.
 * Every print is gated on a counter or a one-shot flag so it does
 * NOT execute on every loop iteration (which would destroy timing).
 *
 * ARCHITECTURE: two custom HLS ping-pong DMA cores (audio_ppdma_0,
 * iq_ppdma_0) with ap_start tied permanently HIGH in the block design.
 * Hardware runs continuously. Software polls GPIO active_buf bits and
 * refills/drains the idle buffer.
 *
 * CACHE COHERENCY FIX (the confirmed hardware bug):
 *   audio_ppdma_0 writes AUDIO_DEST_ADDR via HP0 (bypasses ARM cache).
 *   Xil_DCacheInvalidateRange + memcpy (not Xil_In32) is the correct
 *   read pattern. Xil_In32 bypasses cache so the invalidate has no
 *   effect on it -- using memcpy after invalidate forces a cache-line
 *   refill from DDR.
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
/* Hardware addresses -- MUST match bd.tcl xlconstant values           */
/* ------------------------------------------------------------------ */
#define IQ_PING_ADDR              0x3E000000u
#define IQ_PONG_ADDR              0x3E100000u
#define AUDIO_DEST_ADDR           0x3E400000u
#define IQ_BUF_SIZE_WORDS         2500u
#define AUDIO_SAMPLES_PER_BUFFER  50u
#define AUDIO_EOF_GRACE_BLOCKS    20u
#define AXI_GPIO_0_BASEADDR       0x40000000u
#define GPIO_DATA_OFFSET          0x00u
#define GPIO2_DATA_OFFSET         0x08u

/* ------------------------------------------------------------------ */
/* File paths                                                           */
/* ------------------------------------------------------------------ */
#define INPUT_WAV_PATH        "0:/rds.wav"
#define INTERMEDIATE_WAV_PATH "0:/A50.WAV"
#define OUTPUT_WAV_PATH       "0:/A48.WAV"

/* ------------------------------------------------------------------ */
/* Debug verbosity controls                                             */
/* Adjust these without touching the logic below.                      */
/* ------------------------------------------------------------------ */
/* Print raw DDR content for the first N drain calls */
#define DBG_DRAIN_RAW_FIRST_N      5u
/* Print IQ packing sample for the first N refill calls */
#define DBG_IQ_PACK_FIRST_N        3u
/* Print audio stats every N blocks */
#define DBG_AUDIO_STATS_EVERY      50u
/* Print IQ refill progress every N refills */
#define DBG_IQ_PROGRESS_EVERY      10u
/* Print audio progress every N blocks */
#define DBG_AUDIO_PROGRESS_EVERY   50u

int resample_wav_50k_to_48k(const char *in_path, const char *out_path);

static FATFS fatfs;

/* ------------------------------------------------------------------ */
/* FRESULT string                                                       */
/* ------------------------------------------------------------------ */
static const char *fresult_str(FRESULT fr)
{
    switch (fr) {
        case FR_OK:                  return "FR_OK";
        case FR_DISK_ERR:            return "FR_DISK_ERR";
        case FR_INT_ERR:             return "FR_INT_ERR";
        case FR_NOT_READY:           return "FR_NOT_READY";
        case FR_NO_FILE:             return "FR_NO_FILE";
        case FR_NO_PATH:             return "FR_NO_PATH";
        case FR_INVALID_NAME:        return "FR_INVALID_NAME";
        case FR_DENIED:              return "FR_DENIED";
        case FR_EXIST:               return "FR_EXIST";
        case FR_INVALID_OBJECT:      return "FR_INVALID_OBJECT";
        case FR_WRITE_PROTECTED:     return "FR_WRITE_PROTECTED";
        case FR_INVALID_DRIVE:       return "FR_INVALID_DRIVE";
        case FR_NOT_ENABLED:         return "FR_NOT_ENABLED";
        case FR_NO_FILESYSTEM:       return "FR_NO_FILESYSTEM";
        case FR_MKFS_ABORTED:        return "FR_MKFS_ABORTED";
        case FR_TIMEOUT:             return "FR_TIMEOUT";
        case FR_LOCKED:              return "FR_LOCKED";
        case FR_NOT_ENOUGH_CORE:     return "FR_NOT_ENOUGH_CORE";
        case FR_TOO_MANY_OPEN_FILES: return "FR_TOO_MANY_OPEN_FILES";
        case FR_INVALID_PARAMETER:   return "FR_INVALID_PARAMETER";
        default:                     return "FR_<unknown>";
    }
}

/* ------------------------------------------------------------------ */
/* SD card directory listing                                            */
/* ------------------------------------------------------------------ */
static void list_sd_card_root(void)
{
    DIR dir; FILINFO fno; FRESULT fres; int count = 0;
    xil_printf("--- SD card root (0:/) ---\r\n");
    fres = f_opendir(&dir, "0:/");
    if (fres != FR_OK) {
        xil_printf("  f_opendir failed: %s (%d)\r\n", fresult_str(fres), fres);
        return;
    }
    for (;;) {
        fres = f_readdir(&dir, &fno);
        if (fres != FR_OK || fno.fname[0] == 0) break;
        if (fno.fattrib & AM_DIR)
            xil_printf("  <DIR>  %s\r\n", fno.fname);
        else
            xil_printf("  %10lu  %s\r\n", (unsigned long)fno.fsize, fno.fname);
        count++;
    }
    f_closedir(&dir);
    xil_printf("--- %d entries ---\r\n", count);
}

/* ------------------------------------------------------------------ */
/* WAV header helpers                                                   */
/* ------------------------------------------------------------------ */
typedef struct __attribute__((packed)) {
    char  riff_id[4]; u32 riff_size; char wave_id[4];
    char  fmt_id[4];  u32 fmt_size;  u16 audio_format;
    u16   num_channels; u32 sample_rate; u32 byte_rate;
    u16   block_align;  u16 bits_per_sample;
    char  data_id[4]; u32 data_size;
} wav_header_t;

static int wav_write_placeholder_header(FIL *f, u32 rate, u16 ch, u16 bps)
{
    wav_header_t h; UINT w;
    memcpy(h.riff_id,"RIFF",4); h.riff_size=0;
    memcpy(h.wave_id,"WAVE",4); memcpy(h.fmt_id,"fmt ",4);
    h.fmt_size=16; h.audio_format=1; h.num_channels=ch;
    h.sample_rate=rate; h.bits_per_sample=bps;
    h.block_align=ch*(bps/8); h.byte_rate=rate*h.block_align;
    memcpy(h.data_id,"data",4); h.data_size=0;
    return (f_write(f,&h,sizeof(h),&w)==FR_OK && w==sizeof(h)) ? 0 : -1;
}

static int wav_patch_header(FIL *f, u32 data_bytes)
{
    UINT w;
    u32 riff_size = data_bytes + sizeof(wav_header_t) - 8;
    if (f_lseek(f,4)!=FR_OK) return -1;
    if (f_write(f,&riff_size,4,&w)!=FR_OK||w!=4) return -1;
    if (f_lseek(f,40)!=FR_OK) return -1;
    if (f_write(f,&data_bytes,4,&w)!=FR_OK||w!=4) return -1;
    return 0;
}

/* ------------------------------------------------------------------ */
/* GPIO helpers                                                         */
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
/* Static buffers (not on stack -- too large)                          */
/* ------------------------------------------------------------------ */
static int16_t iq_stage[2 * IQ_BUF_SIZE_WORDS] __attribute__((aligned(64)));
static u32     iq_packed[IQ_BUF_SIZE_WORDS]    __attribute__((aligned(64)));
static int16_t audio_pcm_block[AUDIO_SAMPLES_PER_BUFFER] __attribute__((aligned(64)));
static u32     audio_dest_raw[AUDIO_SAMPLES_PER_BUFFER]  __attribute__((aligned(64)));

/* ------------------------------------------------------------------ */
/* refill_iq_buffer                                                     */
/* ------------------------------------------------------------------ */
static u32 dbg_iq_call = 0;

static void refill_iq_buffer(FIL *fin, u32 dest_addr, int *eof_hit)
{
    UINT bytes_read; FRESULT fres; u32 pairs_read;

    fres = f_read(fin, iq_stage, sizeof(iq_stage), &bytes_read);
    if (fres != FR_OK) {
        xil_printf("[IQ] f_read FAILED: %s (%d) dest=0x%08lX\r\n",
                   fresult_str(fres), fres, (unsigned long)dest_addr);
        *eof_hit = 1; return;
    }

    pairs_read = bytes_read / (2 * sizeof(int16_t));
    if (pairs_read < IQ_BUF_SIZE_WORDS) {
        xil_printf("[IQ] EOF: got %lu/%lu pairs on refill #%lu\r\n",
                   (unsigned long)pairs_read,
                   (unsigned long)IQ_BUF_SIZE_WORDS,
                   (unsigned long)dbg_iq_call);
        *eof_hit = 1;
    }

    for (u32 i = 0; i < IQ_BUF_SIZE_WORDS; i++) {
        if (i < pairs_read) {
            int16_t I = iq_stage[2*i];
            int16_t Q = iq_stage[2*i+1];
            iq_packed[i] = ((u32)(u16)I << 16) | (u32)(u16)Q;
        } else {
            iq_packed[i] = 0;
        }
    }

    /* DEBUG: print first sample of first few refills to verify packing */
    if (dbg_iq_call < DBG_IQ_PACK_FIRST_N) {
        int16_t I0 = iq_stage[0];
        int16_t Q0 = iq_stage[1];
        xil_printf("[IQ#%lu] dest=0x%08lX  I[0]=%d Q[0]=%d  packed[0]=0x%08lX\r\n",
                   (unsigned long)dbg_iq_call,
                   (unsigned long)dest_addr,
                   (int)I0, (int)Q0,
                   (unsigned long)iq_packed[0]);
    }

    memcpy((void*)(uintptr_t)dest_addr, iq_packed, sizeof(iq_packed));

    /* Flush so iq_ppdma_0 sees fresh data via HP0 (not stale cache) */
    Xil_DCacheFlushRange((INTPTR)dest_addr, sizeof(iq_packed));

    dbg_iq_call++;
}

/* ------------------------------------------------------------------ */
/* drain_audio_block                                                    */
/* ------------------------------------------------------------------ */
static u32 dbg_drain_call  = 0;
static u32 dbg_nonzero_tot = 0;
static u32 dbg_max_raw     = 0;
static u32 dbg_min_raw     = 0xFFFFFFFFu;
static s32 dbg_sum_raw     = 0;

static int drain_audio_block(FIL *fout, u32 *total_audio_bytes)
{
    FRESULT fres; UINT bytes_written; u32 i;
    u32 nonzero_this = 0;

    /* ---- STEP 1: Cache coherency ----
     * Invalidate audio_dest_raw BEFORE memcpy so the CPU fetches
     * fresh cache lines from DDR (written by audio_ppdma_0 via HP0).
     * Xil_In32 must NOT be used here -- it bypasses cache entirely
     * so the invalidate would have no effect on it. */
    Xil_DCacheInvalidateRange((INTPTR)audio_dest_raw,
                               sizeof(audio_dest_raw));

    /* ---- STEP 2: Read DDR into local buffer via cached path ---- */
    memcpy(audio_dest_raw,
           (const void*)(uintptr_t)AUDIO_DEST_ADDR,
           sizeof(audio_dest_raw));

    /* ---- STEP 3: Debug -- print raw DDR content for first N drains ---- */
    if (dbg_drain_call < DBG_DRAIN_RAW_FIRST_N) {
        xil_printf("[DRAIN#%lu] raw DDR[0..7]: "
                   "%08lX %08lX %08lX %08lX  %08lX %08lX %08lX %08lX\r\n",
                   (unsigned long)dbg_drain_call,
                   (unsigned long)audio_dest_raw[0],
                   (unsigned long)audio_dest_raw[1],
                   (unsigned long)audio_dest_raw[2],
                   (unsigned long)audio_dest_raw[3],
                   (unsigned long)audio_dest_raw[4],
                   (unsigned long)audio_dest_raw[5],
                   (unsigned long)audio_dest_raw[6],
                   (unsigned long)audio_dest_raw[7]);

        /* Also read DIRECTLY via Xil_In32 for comparison -- this shows
         * whether the cache fix is making a difference.
         * If Xil_In32 and audio_dest_raw disagree -> cache confirmed active.
         * If they agree and are zero -> DMA not writing DDR at all.
         * If they agree and non-zero -> data good, check WAV conversion. */
        xil_printf("[DRAIN#%lu] Xil_In32[0..3]: "
                   "%08lX %08lX %08lX %08lX\r\n",
                   (unsigned long)dbg_drain_call,
                   (unsigned long)Xil_In32(AUDIO_DEST_ADDR + 0),
                   (unsigned long)Xil_In32(AUDIO_DEST_ADDR + 4),
                   (unsigned long)Xil_In32(AUDIO_DEST_ADDR + 8),
                   (unsigned long)Xil_In32(AUDIO_DEST_ADDR + 12));
    }

    /* ---- STEP 4: Convert sfix32_En13 -> PCM16 and accumulate stats ----
     *
     * The de-emphasis output is in Hz units (instantaneous audio-frequency
     * deviation after FM demodulation). It is NOT a normalised [-1,+1]
     * amplitude signal. Typical FM broadcast audio peaks at ~+-75 kHz
     * deviation; after de-emphasis and audio LPF the audio content sits
     * in the range approximately +-15000 Hz.
     *
     * Correct conversion:
     *   sfix32_En13 / 8192  -> frequency in Hz  (e.g. +-17000 Hz)
     *   / FM_MAX_DEV_HZ     -> normalised [-1,+1]
     *   * 32767             -> PCM16
     *
     * The previous code divided by 8192 then multiplied by 32767 directly,
     * treating it as a +-1 amplitude -- this clips massively because a
     * 17000 Hz value becomes 17000*32767 = 557M, hard-clipped to 32767
     * on every sample, producing a square wave at the output.            */
#define FM_MAX_DEV_HZ  75000.0f   /* ITU-R max FM deviation */

    for (i = 0; i < AUDIO_SAMPLES_PER_BUFFER; i++) {
        u32 raw_u = audio_dest_raw[i];
        s32 raw   = (s32)raw_u;

        /* sfix32_En13 -> Hz -> normalised -> PCM16 */
        float val_hz   = (float)raw / 8192.0f;
        float val_norm = val_hz / FM_MAX_DEV_HZ;
        float scaled   = val_norm * 32767.0f;
        if (scaled >  32767.0f) scaled =  32767.0f;
        if (scaled < -32768.0f) scaled = -32768.0f;
        audio_pcm_block[i] = (int16_t)lroundf(scaled);

        /* Accumulate stats for non-zero diagnostic */
        if (raw_u != 0u) {
            nonzero_this++;
            dbg_nonzero_tot++;
        }
        if (raw_u > dbg_max_raw) dbg_max_raw = raw_u;
        if (raw_u < dbg_min_raw) dbg_min_raw = raw_u;
        dbg_sum_raw += raw;  /* running sum for mean check */
    }

    /* ---- STEP 5: Per-drain summary for first N drains ---- */
    if (dbg_drain_call < DBG_DRAIN_RAW_FIRST_N) {
        xil_printf("[DRAIN#%lu] non-zero=%lu/%lu  pcm[0..3]: %d %d %d %d\r\n",
                   (unsigned long)dbg_drain_call,
                   (unsigned long)nonzero_this,
                   (unsigned long)AUDIO_SAMPLES_PER_BUFFER,
                   (int)audio_pcm_block[0], (int)audio_pcm_block[1],
                   (int)audio_pcm_block[2], (int)audio_pcm_block[3]);

        if (nonzero_this == 0) {
            xil_printf("[DRAIN#%lu] *** ALL ZEROS ***\r\n"
                       "  If Xil_In32 also zero: DMA not writing DDR\r\n"
                       "  If Xil_In32 non-zero:  cache coherency bug\r\n"
                       "  (the fix should have caught this -- check ELF is rebuilt)\r\n",
                       (unsigned long)dbg_drain_call);
        }
    }

    /* ---- STEP 6: Periodic statistics ---- */
    if ((dbg_drain_call > 0) &&
        ((dbg_drain_call % DBG_AUDIO_STATS_EVERY) == 0)) {
        u32 total_samples = dbg_drain_call * AUDIO_SAMPLES_PER_BUFFER;
        xil_printf("[STATS] blocks=%lu  total_nonzero=%lu/%lu (%.1f%%)\r\n"
                   "        raw max=0x%08lX  min=0x%08lX  sum=%ld\r\n",
                   (unsigned long)dbg_drain_call,
                   (unsigned long)dbg_nonzero_tot,
                   (unsigned long)total_samples,
                   (total_samples > 0) ?
                       (100.0f * dbg_nonzero_tot / total_samples) : 0.0f,
                   (unsigned long)dbg_max_raw,
                   (unsigned long)dbg_min_raw,
                   (long)dbg_sum_raw);
    }

    /* ---- STEP 7: Write PCM16 to WAV ---- */
    fres = f_write(fout, audio_pcm_block, sizeof(audio_pcm_block),
                   &bytes_written);
    if (fres != FR_OK || bytes_written != sizeof(audio_pcm_block)) {
        xil_printf("[DRAIN] f_write FAILED: %s (%d)\r\n",
                   fresult_str(fres), fres);
        return -1;
    }

    *total_audio_bytes += bytes_written;
    dbg_drain_call++;
    return 0;
}

/* ------------------------------------------------------------------ */
/* main                                                                 */
/* ------------------------------------------------------------------ */
int main(void)
{
    FRESULT fres; FIL fin, fout;
    u32 total_audio_bytes = 0;
    int input_eof = 0, draining_grace = 0;
    u32 grace_blocks_remaining = 0;
    u32 iq_prev, audio_prev;
    u32 iq_refill_count = 0, audio_block_count = 0;

    Xil_DCacheEnable();
    Xil_ICacheEnable();

    xil_printf("\r\n=== FM Demod bare-metal DEBUG BUILD ===\r\n");
    xil_printf("Build: %s %s\r\n", __DATE__, __TIME__);

    /* ---- Print hardware config so we can verify addresses ---- */
    xil_printf("IQ_PING=0x%08lX  IQ_PONG=0x%08lX\r\n",
               (unsigned long)IQ_PING_ADDR, (unsigned long)IQ_PONG_ADDR);
    xil_printf("AUDIO_DEST=0x%08lX  GPIO_BASE=0x%08lX\r\n",
               (unsigned long)AUDIO_DEST_ADDR,
               (unsigned long)AXI_GPIO_0_BASEADDR);
    xil_printf("IQ_BUF_SIZE_WORDS=%lu  AUDIO_SAMPLES_PER_BUF=%lu\r\n",
               (unsigned long)IQ_BUF_SIZE_WORDS,
               (unsigned long)AUDIO_SAMPLES_PER_BUFFER);

    /* ---- Confirm GPIO is readable ---- */
    {
        u32 gp1 = Xil_In32(AXI_GPIO_0_BASEADDR + GPIO_DATA_OFFSET);
        u32 gp2 = Xil_In32(AXI_GPIO_0_BASEADDR + GPIO2_DATA_OFFSET);
        xil_printf("Initial GPIO: ch1(iq)=0x%08lX  ch2(audio)=0x%08lX\r\n",
                   (unsigned long)gp1, (unsigned long)gp2);
        if (gp1 == 0xDEADBEEF || gp1 == 0xFFFFFFFF) {
            xil_printf("*** WARNING: GPIO may not be responding -- "
                       "check AXI interconnect and bitstream\r\n");
        }
    }

    /* ---- Confirm AUDIO_DEST_ADDR DDR before we do anything ---- */
    xil_printf("DDR pre-DMA check at AUDIO_DEST (first 4 words):\r\n"
               "  [0]=0x%08lX [1]=0x%08lX [2]=0x%08lX [3]=0x%08lX\r\n",
               (unsigned long)Xil_In32(AUDIO_DEST_ADDR+0),
               (unsigned long)Xil_In32(AUDIO_DEST_ADDR+4),
               (unsigned long)Xil_In32(AUDIO_DEST_ADDR+8),
               (unsigned long)Xil_In32(AUDIO_DEST_ADDR+12));

    /* ---- Mount SD card ---- */
    fres = f_mount(&fatfs, "0:/", 1);
    if (fres != FR_OK) {
        xil_printf("f_mount failed: %s (%d)\r\n", fresult_str(fres), fres);
        return -1;
    }
    xil_printf("SD card mounted OK\r\n");
    list_sd_card_root();

    /* ---- Open input WAV ---- */
    fres = f_open(&fin, INPUT_WAV_PATH, FA_READ);
    if (fres != FR_OK) {
        xil_printf("f_open(%s) failed: %s (%d)\r\n",
                   INPUT_WAV_PATH, fresult_str(fres), fres);
        return -1;
    }
    xil_printf("Opened %s  size=%lu bytes\r\n",
               INPUT_WAV_PATH, (unsigned long)f_size(&fin));

    /* ---- Print WAV header for verification ---- */
    {
        wav_header_t hdr; UINT rb;
        if (f_read(&fin, &hdr, sizeof(hdr), &rb) == FR_OK && rb == sizeof(hdr)) {
            xil_printf("WAV header: %.4s  riff_size=%lu  ch=%u  rate=%lu  bps=%u  data_size=%lu\r\n",
                       hdr.riff_id,
                       (unsigned long)hdr.riff_size,
                       (unsigned)hdr.num_channels,
                       (unsigned long)hdr.sample_rate,
                       (unsigned)hdr.bits_per_sample,
                       (unsigned long)hdr.data_size);
            if (hdr.num_channels != 2) {
                xil_printf("*** WARNING: expected stereo (ch=2), got ch=%u  "
                           "-- I/Q must be stereo interleaved\r\n",
                           (unsigned)hdr.num_channels);
            }
            if (hdr.sample_rate != 250000) {
                xil_printf("*** WARNING: expected 250000 Hz, got %lu Hz\r\n",
                           (unsigned long)hdr.sample_rate);
            }
        } else {
            xil_printf("*** Could not read WAV header\r\n");
            /* Seek back to byte 44 anyway */
        }
        /* Seek to audio data (skip the 44-byte header) */
        if (f_lseek(&fin, sizeof(wav_header_t)) != FR_OK) {
            xil_printf("f_lseek to audio data failed\r\n");
            return -1;
        }
        xil_printf("Seeked to audio data at offset %lu\r\n",
                   (unsigned long)sizeof(wav_header_t));
    }

    /* ---- Open output WAV ---- */
    fres = f_open(&fout, INTERMEDIATE_WAV_PATH, FA_WRITE | FA_CREATE_ALWAYS);
    if (fres != FR_OK) {
        xil_printf("f_open(%s) failed: %s (%d)\r\n",
                   INTERMEDIATE_WAV_PATH, fresult_str(fres), fres);
        return -1;
    }
    if (wav_write_placeholder_header(&fout, 50000, 1, 16) != 0) {
        xil_printf("Failed to write placeholder WAV header\r\n");
        return -1;
    }
    xil_printf("Opened %s for writing\r\n", INTERMEDIATE_WAV_PATH);

    /* ---- Prime both IQ buffers ---- */
    xil_printf("Priming IQ_PING ...\r\n");
    { int e=0; refill_iq_buffer(&fin, IQ_PING_ADDR, &e); if(e) input_eof=1; }
    xil_printf("Priming IQ_PONG ...\r\n");
    { int e=0; refill_iq_buffer(&fin, IQ_PONG_ADDR, &e); if(e) input_eof=1; }

    iq_prev    = gpio_read_iq_active();
    audio_prev = gpio_read_audio_active();
    xil_printf("Initial GPIO state: iq_prev=%lu  audio_prev=%lu\r\n",
               (unsigned long)iq_prev, (unsigned long)audio_prev);
    xil_printf("Entering main loop...\r\n");

    /* ---- Main loop ---- */
    for (;;) {
        u32 iq_now = gpio_read_iq_active();
        if (iq_now != iq_prev) {
            u32 free_addr = (iq_now == 0) ? IQ_PONG_ADDR : IQ_PING_ADDR;
            if (!input_eof) {
                int eof_tmp = 0;
                refill_iq_buffer(&fin, free_addr, &eof_tmp);
                iq_refill_count++;
                if ((iq_refill_count % DBG_IQ_PROGRESS_EVERY) == 0) {
                    xil_printf("[progress] iq refills=%lu  iq_now=%lu\r\n",
                               (unsigned long)iq_refill_count,
                               (unsigned long)iq_now);
                }
                if (eof_tmp) {
                    input_eof = 1; draining_grace = 1;
                    grace_blocks_remaining = AUDIO_EOF_GRACE_BLOCKS;
                    xil_printf("[EOF] Input exhausted after %lu refills. "
                               "Grace drain: %lu blocks\r\n",
                               (unsigned long)iq_refill_count,
                               (unsigned long)grace_blocks_remaining);
                }
            }
            iq_prev = iq_now;
        }

        u32 audio_now = gpio_read_audio_active();
        if (audio_now != audio_prev) {
            if (drain_audio_block(&fout, &total_audio_bytes) != 0) {
                xil_printf("[ABORT] drain_audio_block failed at block %lu\r\n",
                           (unsigned long)audio_block_count);
                break;
            }
            audio_block_count++;
            if ((audio_block_count % DBG_AUDIO_PROGRESS_EVERY) == 0) {
                xil_printf("[progress] audio blocks=%lu  bytes=%lu\r\n",
                           (unsigned long)audio_block_count,
                           (unsigned long)total_audio_bytes);
            }
            if (draining_grace) {
                if (grace_blocks_remaining == 0) {
                    xil_printf("[DONE] Pipeline drain complete. "
                               "%lu blocks  %lu bytes\r\n",
                               (unsigned long)audio_block_count,
                               (unsigned long)total_audio_bytes);
                    break;
                }
                grace_blocks_remaining--;
            }
            audio_prev = audio_now;
        }
    }

    /* ---- Final statistics ---- */
    xil_printf("\r\n=== Final statistics ===\r\n");
    xil_printf("  IQ refills:          %lu\r\n", (unsigned long)iq_refill_count);
    xil_printf("  Audio blocks:        %lu\r\n", (unsigned long)audio_block_count);
    xil_printf("  Audio bytes written: %lu\r\n", (unsigned long)total_audio_bytes);
    xil_printf("  Non-zero audio words: %lu / %lu (%.1f%%)\r\n",
               (unsigned long)dbg_nonzero_tot,
               (unsigned long)(audio_block_count * AUDIO_SAMPLES_PER_BUFFER),
               (audio_block_count * AUDIO_SAMPLES_PER_BUFFER > 0) ?
               (100.0f * dbg_nonzero_tot /
                (audio_block_count * AUDIO_SAMPLES_PER_BUFFER)) : 0.0f);
    xil_printf("  Raw DDR max:         0x%08lX (%ld)\r\n",
               (unsigned long)dbg_max_raw, (long)(s32)dbg_max_raw);
    xil_printf("  Raw DDR min:         0x%08lX (%ld)\r\n",
               (unsigned long)dbg_min_raw, (long)(s32)dbg_min_raw);
    xil_printf("  Raw DDR sum:         %ld\r\n", (long)dbg_sum_raw);

    if (dbg_nonzero_tot == 0) {
        xil_printf("\r\n*** DIAGNOSIS: all audio data is zero.\r\n"
                   "*** Check [DRAIN#0] Xil_In32 values above:\r\n"
                   "***   If Xil_In32 also zero:  audio_ppdma_0 not writing DDR\r\n"
                   "***                            Check: ap_start? aresetn?\r\n"
                   "***   If Xil_In32 non-zero:   cache coherency bug still present\r\n"
                   "***                            Check: ELF was rebuilt after fix?\r\n");
    } else {
        xil_printf("\r\n*** Audio data is NON-ZERO. Signal chain is working.\r\n"
                   "*** If WAV sounds wrong: check IQ packing order in\r\n"
                   "***   refill_iq_buffer() -- try swapping (I<<16)|Q to (Q<<16)|I\r\n"
                   "*** If WAV is correct level but inaudible: check WAV header\r\n"
                   "***   (sample_rate, num_channels, bits_per_sample above)\r\n");
    }

    /* ---- Patch WAV header and close ---- */
    if (wav_patch_header(&fout, total_audio_bytes) != 0)
        xil_printf("Warning: failed to patch WAV header\r\n");
    else
        xil_printf("WAV header patched: data_size=%lu\r\n",
                   (unsigned long)total_audio_bytes);

    f_close(&fin);
    f_close(&fout);
    xil_printf("50kHz WAV: %s (%lu bytes)\r\n",
               INTERMEDIATE_WAV_PATH, (unsigned long)total_audio_bytes);

    /* ---- Resample 50k -> 48k ---- */
    xil_printf("Resampling %s -> %s ...\r\n",
               INTERMEDIATE_WAV_PATH, OUTPUT_WAV_PATH);
    if (resample_wav_50k_to_48k(INTERMEDIATE_WAV_PATH, OUTPUT_WAV_PATH) != 0) {
        xil_printf("Resample FAILED\r\n");
        f_mount(NULL, "0:/", 1);
        return -1;
    }

    f_mount(NULL, "0:/", 1);
    xil_printf("Done. Output: %s\r\n", OUTPUT_WAV_PATH);
    return 0;
}
