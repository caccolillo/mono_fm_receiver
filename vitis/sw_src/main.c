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
#include "xtime_l.h"
#include "ff.h"
#include <string.h>
#include <math.h>
#include <stdint.h>

/* ------------------------------------------------------------------ */
/* Hardware addresses -- MUST match bd.tcl xlconstant values           */
/*                                                                     */
/* Ultra96-V2 (ZU+) port:                                              */
/*   IQ_PING_ADDR / IQ_PONG_ADDR / AUDIO_DEST_ADDR: UNCHANGED. bd.tcl's */
/*   xlconstant_1/2/5 were never edited during the port, and a live    */
/*   build log confirmed HP0_DDR_LOW spans 0x0000_0000-0x7FFF_FFFF     */
/*   (2 GB) on ZU+, which comfortably covers these 0x3Exx_xxxx values  */
/*   -- so they're very likely still correct as-is. Still worth one    */
/*   cross-check against bd.tcl's actual xlconstant CONFIG.CONST_VAL   */
/*   properties before trusting this comment over the hardware.        */
/*                                                                     */
/*   AXI_GPIO_0_BASEADDR: CHANGED. Confirmed from an actual ZU+ build  */
/*   log -- GP0's default PL-peripheral window moved from PS7's        */
/*   0x4000_0000 to 0xA000_0000 on this port.                          */
/* ------------------------------------------------------------------ */
#define IQ_PING_ADDR              0x3E000000u
#define IQ_PONG_ADDR              0x3E100000u
#define AUDIO_DEST_ADDR           0x3E400000u
#define IQ_BUF_SIZE_WORDS         2500u
#define AUDIO_SAMPLES_PER_BUFFER  50u
#define AUDIO_EOF_GRACE_BLOCKS    20u
#define AXI_GPIO_0_BASEADDR       0xA0000000u
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
/* Master switch for ALL per-iteration debug printing (DRAIN#, IQ#,
 * [progress], [STATS]). Set to 0 for a real run -- at -O0 in particular,
 * this printing was costing enough real wall-clock time inside the
 * polling loop to be a material contributor to the audio-block capture
 * shortfall diagnosed on Ultra96-V2 hardware (only ~4163/41440 expected
 * blocks captured even after batching SD writes). Set to 1 to bring
 * back full per-iteration tracing for troubleshooting -- one-shot
 * messages (banner, mount/open status, final statistics, errors) are
 * NOT gated by this and always print regardless, since they cost
 * nothing measurable against the loop's 1 ms cadence. */
#ifndef DEBUG_VERBOSE
#define DEBUG_VERBOSE 0
#endif

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

/* ------------------------------------------------------------------ */
/* Audio SD-write batching                                              */
/*                                                                      */
/* ROOT CAUSE FOUND ON ULTRA96-V2 HARDWARE: the main loop detects a new */
/* audio block via a single-bit active_buf TOGGLE (audio_now != prev). */
/* That can only tell you "did it change since I last looked" -- it    */
/* cannot tell you how many times it changed while this loop was busy. */
/* audio_ppdma_0 swaps buffers roughly every 1 ms and does not wait for */
/* software. The original code called f_write() -- a real SD card       */
/* filesystem write, routinely several ms of latency -- once per        */
/* detected toggle, i.e. up to ~1000 times/sec. Any time that write     */
/* took longer than ~1 ms, the NEXT buffer swap (or several) happened   */
/* invisibly while software was still inside the call, and that audio  */
/* was silently gone -- no error, no counter, just missing. Measured    */
/* on hardware: ~11x fewer audio blocks captured than the fabric        */
/* actually produced, and the resulting WAV was an unlistenable stitched */
/* -together mess of disjoint 1 ms fragments (flat envelope, spurious   */
/* tonal harmonics) rather than real audio.                             */
/*                                                                      */
/* FIX: accumulate PCM blocks into a large in-RAM buffer instead of     */
/* hitting the SD card every ~1 ms, and flush to disk in big, infrequent */
/* batches. This doesn't touch the toggle-detection logic itself (still */
/* a single-bit poll, still capable of missing genuinely simultaneous   */
/* toggles in principle) -- it just makes the per-iteration software    */
/* cost cheap enough (a fast memcpy) that it can comfortably keep pace   */
/* with a 1 ms producer, which the previous full SD write per block     */
/* could not.                                                            */
#define AUDIO_STAGE_BLOCKS  1000u  /* ~1 s of 50kHz audio per SD flush */

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

/* Staging buffer for batched SD writes -- see AUDIO_STAGE_BLOCKS above.
 * ~97.7 KB at the default 1000-block setting; comfortably inside DDR,
 * nowhere close to the 256 KB OCM if the linker script happens to place
 * .bss there instead -- worth a glance at the map file if this ever
 * moves to a much larger AUDIO_STAGE_BLOCKS value. */
static int16_t audio_stage_buf[AUDIO_STAGE_BLOCKS * AUDIO_SAMPLES_PER_BUFFER] __attribute__((aligned(64)));
static u32     audio_stage_count = 0;  /* blocks currently held in audio_stage_buf */

/* ------------------------------------------------------------------ */
/* Input RAM preload -- the other half of the batching fix              */
/*                                                                      */
/* Fixing the AUDIO side alone (AUDIO_STAGE_BLOCKS) barely moved the    */
/* audio_block_count needle on hardware (stayed ~1:1 with iq_refill_    */
/* count instead of the expected ~10:1). Root cause traced to the OTHER */
/* branch of the main loop: refill_iq_buffer() was calling f_read() --  */
/* a real, synchronous SD card read of 10 KB -- once per ~10 ms iq_now  */
/* toggle. iq_now is checked FIRST in the loop, every iteration, so     */
/* while that read was in flight the loop was not polling audio_now at  */
/* all -- starving the audio side regardless of how fast audio's own    */
/* handling had become. iq_refill_count itself was rock-solid correct   */
/* in every run; it was never the one missing data, it was the one      */
/* CAUSING the audio side to miss data by blocking the loop.            */
/*                                                                      */
/* Fix: preload the whole input file into RAM once, up front, before    */
/* the main loop starts (SD latency here doesn't matter -- nothing is   */
/* time-critical yet). refill_iq_buffer() then does a fast memcpy from  */
/* this buffer instead of a live f_read(), removing SD latency from the */
/* loop entirely on the input side, same as AUDIO_STAGE_BLOCKS already  */
/* did for the output side.                                             */
/*                                                                      */
/* IQ_INPUT_STAGE_MAX_BYTES is sized generously above rds.wav's actual  */
/* ~41.4 MB (per this project's test recording) -- DDR is 2 GB on the   */
/* Ultra96-V2, so a fixed-size static buffer well above what's needed   */
/* costs nothing meaningful. If a longer recording is ever used, bump   */
/* this constant rather than switching to malloc -- the current 2 MB    */
/* heap (sized for the resampler's two buffers) isn't remotely large    */
/* enough for this, and there's no need to fight the heap when a static */
/* BSS array works and DDR has room to spare.                           */
#define IQ_INPUT_STAGE_MAX_BYTES  (48u * 1024u * 1024u)  /* 48 MB */

static uint8_t iq_input_stage[IQ_INPUT_STAGE_MAX_BYTES] __attribute__((aligned(64)));
static u32     iq_input_stage_len = 0;  /* actual bytes loaded from SD */
static u32     iq_input_stage_pos = 0;  /* read cursor into the staged buffer */

/* Preload the remainder of an already-open, already-seeked-past-header
 * FIL into iq_input_stage. Called once, before the main loop. Returns
 * 0 on success (even if the file is larger than IQ_INPUT_STAGE_MAX_BYTES
 * -- in that case it loads as much as fits and the rest is simply never
 * read, same practical effect as a shorter recording), -1 on a real
 * f_read failure. */
static int preload_iq_input(FIL *fin)
{
    FRESULT fres;
    UINT bytes_read = 0;

    xil_printf("Preloading input WAV into RAM (up to %lu MB)...\r\n",
               (unsigned long)(IQ_INPUT_STAGE_MAX_BYTES / (1024u * 1024u)));

    fres = f_read(fin, iq_input_stage, IQ_INPUT_STAGE_MAX_BYTES, &bytes_read);
    if (fres != FR_OK) {
        xil_printf("[PRELOAD] f_read FAILED: %s (%d)\r\n",
                   fresult_str(fres), fres);
        return -1;
    }

    iq_input_stage_len = bytes_read;
    iq_input_stage_pos = 0;
    xil_printf("Preload complete: %lu bytes staged in RAM.\r\n",
               (unsigned long)iq_input_stage_len);
    return 0;
}

/* ------------------------------------------------------------------ */
/* refill_iq_buffer                                                     */
/* ------------------------------------------------------------------ */
static u32 dbg_iq_call = 0;

static void refill_iq_buffer(FIL *fin, u32 dest_addr, int *eof_hit)
{
    u32 pairs_read;
    u32 bytes_available = iq_input_stage_len - iq_input_stage_pos;
    u32 bytes_to_copy = (bytes_available < sizeof(iq_stage))
                             ? bytes_available : (u32)sizeof(iq_stage);

    (void)fin;  /* no longer used -- input is preloaded, see preload_iq_input() */

    memcpy(iq_stage, &iq_input_stage[iq_input_stage_pos], bytes_to_copy);
    if (bytes_to_copy < sizeof(iq_stage)) {
        /* Zero-pad any leftover tail so the packing loop below behaves
         * identically to the old short-f_read-at-EOF case. */
        memset((uint8_t *)iq_stage + bytes_to_copy, 0,
               sizeof(iq_stage) - bytes_to_copy);
    }
    iq_input_stage_pos += bytes_to_copy;

    pairs_read = bytes_to_copy / (2 * sizeof(int16_t));
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
            // SWAPPED per this project's own diagnostic hint (printed at
            // the end of every run: "check IQ packing order... try
            // swapping (I<<16)|Q to (Q<<16)|I"). Tried now specifically
            // because the entire datapath (aa_lpf/freq_corr/nco/fm_disc/
            // fir_dec/audio_lpf/de_emph/audio_ppdma) has just been
            // independently confirmed correct at the RTL level -- 744
            // real samples cleanly handshaked end to end, audio_ppdma's
            // active_buf genuinely toggling on schedule. With throughput
            // and data-loss ruled out, a wrong tone with the datapath
            // otherwise healthy points at a content/ordering bug like
            // this one, not a stall.
            iq_packed[i] = ((u32)(u16)Q << 16) | (u32)(u16)I;
        } else {
            iq_packed[i] = 0;
        }
    }

    /* DEBUG: print first sample of first few refills to verify packing */
#if DEBUG_VERBOSE
    if (dbg_iq_call < DBG_IQ_PACK_FIRST_N) {
        int16_t I0 = iq_stage[0];
        int16_t Q0 = iq_stage[1];
        xil_printf("[IQ#%lu] dest=0x%08lX  I[0]=%d Q[0]=%d  packed[0]=0x%08lX\r\n",
                   (unsigned long)dbg_iq_call,
                   (unsigned long)dest_addr,
                   (int)I0, (int)Q0,
                   (unsigned long)iq_packed[0]);
    }
#endif /* DEBUG_VERBOSE */

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

/* ------------------------------------------------------------------ */
/* SD write/readback cross-check checksum                              */
/*                                                                      */
/* Added to directly test whether the SD card's write-then-reopen-and-  */
/* read round trip could be corrupting data -- ruled everything else    */
/* out first (RTL/hardware confirmed correct via isolated simulation,   */
/* I/Q packing-order swap made no measurable difference), so this is    */
/* the one remaining untested link: main.c writes A50.WAV, then         */
/* resample_50k_to_48k() reopens and reads that same file back. A       */
/* checksum computed on each side, over the exact same sample sequence, */
/* either matches (SD round-trip is clean, look elsewhere) or doesn't   */
/* (proves corruption right here, independent of anything upstream).    */
/*                                                                      */
/* Order-sensitive by design (rotate + add, not a plain sum) -- a swap  */
/* or duplication of samples changes the result, not just a dropped/    */
/* corrupted value would.                                               */
/*                                                                      */
/* MUST STAY IDENTICAL to the copy of this function in                  */
/* resample_50k_to_48k.c -- that's the whole point of the cross-check.  */
/* ------------------------------------------------------------------ */
static u32 sd_checksum_update(u32 crc, int16_t sample)
{
    return ((crc << 1) | (crc >> 31)) + (u32)(u16)sample;
}

static u32 sd_write_checksum = 0;

/* ------------------------------------------------------------------ */
/* flush_audio_stage -- one real SD card write for whatever's          */
/* currently sitting in audio_stage_buf, then reset the count. Called   */
/* automatically when the stage buffer fills (from drain_audio_block)   */
/* and once more explicitly after the main loop ends, to flush a final  */
/* partial batch that never reached AUDIO_STAGE_BLOCKS.                 */
/* ------------------------------------------------------------------ */
static int flush_audio_stage(FIL *fout, u32 *total_audio_bytes)
{
    FRESULT fres; UINT bytes_written;
    UINT bytes_to_write;

    if (audio_stage_count == 0)
        return 0;  /* nothing staged -- not an error, just a no-op */

    bytes_to_write = audio_stage_count * AUDIO_SAMPLES_PER_BUFFER * sizeof(int16_t);

    fres = f_write(fout, audio_stage_buf, bytes_to_write, &bytes_written);
    if (fres != FR_OK || bytes_written != bytes_to_write) {
        xil_printf("[FLUSH] f_write FAILED: %s (%d)  requested=%u got=%u\r\n",
                   fresult_str(fres), fres,
                   (unsigned)bytes_to_write, (unsigned)bytes_written);
        return -1;
    }

    *total_audio_bytes += bytes_written;
    audio_stage_count = 0;
    return 0;
}

/* __attribute__((noinline)): at -O2, GCC's inliner combined with its
 * interprocedural array-bounds analysis produced a warning claiming
 * audio_dest_raw's bounds are [0,0] -- inconsistent with its actual
 * 200-byte static declaration just above, and the memcpy below is
 * correct C (copies exactly sizeof(audio_dest_raw)). That mismatch is
 * the signature of a known GCC false-positive class tied to inlining,
 * not a real bug -- forcing this to stay a real call rather than being
 * inlined into main() removes the ambiguity rather than just trusting
 * that theory. If the warning persists with this attribute in place,
 * that would mean the false-positive theory was wrong and this needs
 * a closer look, not a suppression. */
static int __attribute__((noinline)) drain_audio_block(FIL *fout, u32 *total_audio_bytes)
{
    u32 i;
    u32 nonzero_this = 0;

    /* ---- STEP 1: Cache coherency ----
     * Invalidate AUDIO_DEST_ADDR (the real DDR location audio_ppdma_0
     * writes fresh samples to via HP0) BEFORE reading it, so the CPU
     * fetches current data instead of serving a stale cache line.
     *
     * BUG FOUND (Ultra96-V2, after exhaustively verifying the entire
     * RTL datapath correct via simulation): this previously invalidated
     * audio_dest_raw -- the LOCAL destination buffer the memcpy below
     * writes INTO -- instead of AUDIO_DEST_ADDR, the actual DMA target
     * the cache could actually be stale for. Invalidating the
     * destination of a memcpy accomplishes nothing; the CPU kept
     * serving whichever cache line first got fetched for that address,
     * confirmed directly on hardware as five consecutive DRAIN# calls
     * reading byte-for-byte identical "fresh" DDR content, and an
     * impossible >100% non-zero stat from the same stale sample being
     * counted repeatedly. This explains the flat-envelope tone that
     * persisted through this entire session regardless of any RTL fix,
     * since software was never actually seeing the real, correctly-
     * produced data in the first place.
     *
     * Xil_In32 must NOT be used here -- it bypasses cache entirely so
     * the invalidate would have no effect on it. */
    Xil_DCacheInvalidateRange((INTPTR)AUDIO_DEST_ADDR,
                               sizeof(audio_dest_raw));

    /* ---- STEP 2: Read DDR into local buffer via cached path ---- */
    memcpy(audio_dest_raw,
           (const void*)(uintptr_t)AUDIO_DEST_ADDR,
           sizeof(audio_dest_raw));

    /* ---- STEP 3: Debug -- print raw DDR content for first N drains ---- */
#if DEBUG_VERBOSE
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
#endif /* DEBUG_VERBOSE */

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
     * INTEGER FIXED-POINT, not float: the loop timing breakdown measured
     * on Ultra96-V2 hardware showed drain_audio_block averaging 64us/call
     * against an audio buffer-swap period averaging only ~67us -- razor
     * thin margin against a free-running, unthrottled fabric with no flow
     * control on this interface. The float divide/multiply and especially
     * the lroundf() library call in the old version of this loop were
     * real, avoidable per-sample cost sitting inside that margin. This
     * does the exact same math as one combined integer scale-and-round:
     *   scaled = round( raw * 32767 / (8192 * FM_MAX_DEV_HZ) )
     *          = round( raw * 32767 / 614400000 )
     * in 64-bit integer arithmetic (raw*32767 can exceed 32 bits), with
     * manual round-to-nearest (add half the divisor before dividing,
     * handling sign so negative values round correctly) replacing
     * lroundf(). Clipping logic is unchanged. */
#define FM_MAX_DEV_HZ  75000L   /* ITU-R max FM deviation */
#define PCM_SCALE_NUM  32767LL
#define PCM_SCALE_DEN  ((int64_t)8192 * (int64_t)FM_MAX_DEV_HZ)  /* 614400000 */

    for (i = 0; i < AUDIO_SAMPLES_PER_BUFFER; i++) {
        u32 raw_u = audio_dest_raw[i];
        s32 raw   = (s32)raw_u;
        int64_t num = (int64_t)raw * PCM_SCALE_NUM;
        int64_t scaled;

        if (num >= 0) {
            scaled = (num + PCM_SCALE_DEN / 2) / PCM_SCALE_DEN;
        } else {
            int64_t neg_num = -num;
            scaled = -((neg_num + PCM_SCALE_DEN / 2) / PCM_SCALE_DEN);
        }
        if (scaled >  32767) scaled =  32767;
        if (scaled < -32768) scaled = -32768;
        audio_pcm_block[i] = (int16_t)scaled;
        sd_write_checksum = sd_checksum_update(sd_write_checksum, audio_pcm_block[i]);

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
#if DEBUG_VERBOSE
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
#endif /* DEBUG_VERBOSE */

    /* ---- STEP 6: Periodic statistics ---- */
#if DEBUG_VERBOSE
    if ((dbg_drain_call > 0) &&
        ((dbg_drain_call % DBG_AUDIO_STATS_EVERY) == 0)) {
        u32 total_samples = dbg_drain_call * AUDIO_SAMPLES_PER_BUFFER;
        u32 pct_x10 = (total_samples > 0)
                          ? (u32)(((u64)dbg_nonzero_tot * 1000ULL) / total_samples) : 0;
        xil_printf("[STATS] blocks=%lu  total_nonzero=%lu/%lu (%lu.%lu%%)\r\n"
                   "        raw max=0x%08lX  min=0x%08lX  sum=%ld\r\n",
                   (unsigned long)dbg_drain_call,
                   (unsigned long)dbg_nonzero_tot,
                   (unsigned long)total_samples,
                   (unsigned long)(pct_x10 / 10u), (unsigned long)(pct_x10 % 10u),
                   (unsigned long)dbg_max_raw,
                   (unsigned long)dbg_min_raw,
                   (long)dbg_sum_raw);
    }
#endif /* DEBUG_VERBOSE */

    /* ---- STEP 7: Append to RAM staging buffer -- NOT a direct SD write ----
     * See AUDIO_STAGE_BLOCKS comment near the top of the file for why:
     * this is the fix for the ~11x audio-block loss measured on Ultra96-V2
     * hardware. A real f_write() only happens once every AUDIO_STAGE_BLOCKS
     * blocks (flush_audio_stage below), not once per ~1 ms toggle. */
    memcpy(&audio_stage_buf[audio_stage_count * AUDIO_SAMPLES_PER_BUFFER],
           audio_pcm_block, sizeof(audio_pcm_block));
    audio_stage_count++;

    if (audio_stage_count >= AUDIO_STAGE_BLOCKS) {
        if (flush_audio_stage(fout, total_audio_bytes) != 0)
            return -1;
    }

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
    XTime loop_start_tick = 0, loop_end_tick = 0;
    XTime iq_branch_ticks = 0, audio_branch_ticks = 0;
    XTime t0, t1;

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

    /* ---- Preload the rest of the input file into RAM ----
     * See the big comment above preload_iq_input()'s definition for why:
     * this takes SD read latency out of the main loop's iq_now branch,
     * which was starving audio_now polling and was the real cause of
     * the persistent ~1:1 (instead of ~10:1) audio_block:iq_refill
     * ratio measured on hardware even after the audio side was fixed. */
    if (preload_iq_input(&fin) != 0) {
        xil_printf("*** Preload failed -- cannot continue\r\n");
        return -1;
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
    XTime_GetTime(&loop_start_tick);
    for (;;) {
        u32 iq_now = gpio_read_iq_active();
        if (iq_now != iq_prev) {
            u32 free_addr = (iq_now == 0) ? IQ_PONG_ADDR : IQ_PING_ADDR;
            if (!input_eof) {
                int eof_tmp = 0;
                XTime_GetTime(&t0);
                refill_iq_buffer(&fin, free_addr, &eof_tmp);
                XTime_GetTime(&t1);
                iq_branch_ticks += (t1 - t0);
                iq_refill_count++;
#if DEBUG_VERBOSE
                if ((iq_refill_count % DBG_IQ_PROGRESS_EVERY) == 0) {
                    xil_printf("[progress] iq refills=%lu  iq_now=%lu\r\n",
                               (unsigned long)iq_refill_count,
                               (unsigned long)iq_now);
                }
#endif /* DEBUG_VERBOSE */
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
            XTime_GetTime(&t0);
            int drain_rc = drain_audio_block(&fout, &total_audio_bytes);
            XTime_GetTime(&t1);
            audio_branch_ticks += (t1 - t0);
            if (drain_rc != 0) {
                xil_printf("[ABORT] drain_audio_block failed at block %lu\r\n",
                           (unsigned long)audio_block_count);
                break;
            }
            audio_block_count++;
#if DEBUG_VERBOSE
            if ((audio_block_count % DBG_AUDIO_PROGRESS_EVERY) == 0) {
                xil_printf("[progress] audio blocks=%lu  bytes=%lu\r\n",
                           (unsigned long)audio_block_count,
                           (unsigned long)total_audio_bytes);
            }
#endif /* DEBUG_VERBOSE */
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
    XTime_GetTime(&loop_end_tick);

    /* ---- Flush whatever's left in the staging buffer ----
     * The main loop only flushes when the batch is exactly full
     * (audio_stage_count >= AUDIO_STAGE_BLOCKS); EOF/grace-drain almost
     * never lines up on that exact boundary, so there's essentially
     * always a partial batch left over here. Without this, the last
     * few hundred ms to ~1 s of audio would silently never reach the
     * SD card at all. */
    if (flush_audio_stage(&fout, &total_audio_bytes) != 0) {
        xil_printf("[FLUSH] final flush failed -- output WAV is missing "
                   "its last partial batch\r\n");
    }

    /* ---- Final statistics ---- */
    xil_printf("\r\n=== Final statistics ===\r\n");
    xil_printf("  IQ refills:          %lu\r\n", (unsigned long)iq_refill_count);
    xil_printf("  Audio blocks:        %lu\r\n", (unsigned long)audio_block_count);
    xil_printf("  Audio bytes written: %lu\r\n", (unsigned long)total_audio_bytes);

    /* ---- Loop timing breakdown ----
     * Measures where the main loop's wall-clock time actually went, so
     * the remaining audio_block_count shortfall (still ~5.5x short of
     * the ~10:1 audio:iq ratio a lossless capture would show, even after
     * fixing both SD-touching hot spots) can be diagnosed by MEASURING
     * rather than guessing at another candidate. XTime_GetTime() reads
     * the ARM generic timer -- a single register read, not a UART call --
     * so this adds negligible overhead of its own.
     *
     * INTEGER MATH ONLY: confirmed on real hardware that this xil_printf
     * silently drops %f entirely (produces no output at all rather than
     * an error -- the pre-existing "Non-zero audio words ... (%)" line a
     * few lines below this block has been printing blank for every run
     * so far, we just never had reason to notice until this timing block
     * came up empty too). Everything here is computed in whole
     * microseconds / tenths-of-a-percent and printed with %lu instead. */
    {
        XTime total_ticks = loop_end_tick - loop_start_tick;
        u32 total_us = (u32)((total_ticks * 1000000ULL) / (u64)COUNTS_PER_SECOND);
        u32 iq_us    = (u32)((iq_branch_ticks * 1000000ULL) / (u64)COUNTS_PER_SECOND);
        u32 audio_us = (u32)((audio_branch_ticks * 1000000ULL) / (u64)COUNTS_PER_SECOND);
        u32 known_us = iq_us + audio_us;
        u32 other_us = (total_us > known_us) ? (total_us - known_us) : 0;
        u32 iq_avg_us    = (iq_refill_count   > 0) ? (iq_us    / iq_refill_count)   : 0;
        u32 audio_avg_us = (audio_block_count > 0) ? (audio_us / audio_block_count) : 0;
        u32 other_pct_x10 = (total_us > 0)
                                 ? (u32)(((u64)other_us * 1000ULL) / total_us) : 0;

        xil_printf("\r\n  --- Loop timing breakdown ---\r\n");
        xil_printf("  Total loop wall time: %lu us (%lu ms)\r\n",
                   (unsigned long)total_us, (unsigned long)(total_us / 1000u));
        xil_printf("  Time in refill_iq_buffer:   %lu us total, %lu calls, %lu us/call avg\r\n",
                   (unsigned long)iq_us, (unsigned long)iq_refill_count,
                   (unsigned long)iq_avg_us);
        xil_printf("  Time in drain_audio_block:  %lu us total, %lu calls, %lu us/call avg\r\n",
                   (unsigned long)audio_us, (unsigned long)audio_block_count,
                   (unsigned long)audio_avg_us);
        xil_printf("  Unaccounted (GPIO polling + everything else): %lu us (%lu.%lu%% of loop time)\r\n",
                   (unsigned long)other_us,
                   (unsigned long)(other_pct_x10 / 10u), (unsigned long)(other_pct_x10 % 10u));
        xil_printf("  --- end timing breakdown ---\r\n\r\n");
    }

    {
        u32 total_words = audio_block_count * AUDIO_SAMPLES_PER_BUFFER;
        u32 nz_pct_x10 = (total_words > 0)
                             ? (u32)(((u64)dbg_nonzero_tot * 1000ULL) / total_words) : 0;
        xil_printf("  Non-zero audio words: %lu / %lu (%lu.%lu%%)\r\n",
                   (unsigned long)dbg_nonzero_tot,
                   (unsigned long)total_words,
                   (unsigned long)(nz_pct_x10 / 10u), (unsigned long)(nz_pct_x10 % 10u));
    }
    xil_printf("  Raw DDR max:         0x%08lX (%ld)\r\n",
               (unsigned long)dbg_max_raw, (long)(s32)dbg_max_raw);
    xil_printf("  Raw DDR min:         0x%08lX (%ld)\r\n",
               (unsigned long)dbg_min_raw, (long)(s32)dbg_min_raw);
    xil_printf("  Raw DDR sum:         %ld\r\n", (long)dbg_sum_raw);
    xil_printf("  SD write checksum:   0x%08lX  (compare against resample's \"SD readback checksum\" below -- match = SD round-trip clean, mismatch = corruption confirmed right here)\r\n",
               (unsigned long)sd_write_checksum);

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
