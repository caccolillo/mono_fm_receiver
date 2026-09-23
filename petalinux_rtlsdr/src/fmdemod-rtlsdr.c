/*
 * fmdemod-rtlsdr.c
 *
 * Live FM demodulation on Zybo Z7-10: RTL-SDR Blog V3 -> PS USB ->
 * ping-pong DDR buffers -> PL demod chain -> audio back out to DDR ->
 * WAV file.
 *
 * Derived from fmdemod-linux.c. Same DDR map, same GPIO ping-pong
 * handshake, same audio scaling. The ONLY architectural change is the
 * I/Q source: a WAV file read synchronously in the poll loop has been
 * replaced by a live USB stream from the RTL-SDR.
 *
 * ---------------------------------------------------------------------
 * WHY A RING BUFFER AND A SEPARATE THREAD
 * ---------------------------------------------------------------------
 * Reading from a file, the poll loop was in charge: when the fabric
 * flipped the ping-pong flag, we read exactly as many samples as we
 * needed, right then. The file always had data ready and never had an
 * opinion about timing.
 *
 * A live SDR does not work that way. It pushes samples at ITS OWN rate
 * (nominally 250 kHz, actually whatever its 1 ppm TCXO and the USB
 * scheduler produce), while the fabric consumes at ITS OWN rate (the
 * 100 MHz PL clock divided down, free-running with no flow control).
 * These two clocks are independent and will drift apart. There is no
 * arrangement of a single-threaded loop that satisfies both.
 *
 * So: librtlsdr's async reader runs on its own thread and writes into a
 * lock-free-ish SPSC ring buffer; the poll loop reads out of the other
 * end when the fabric asks for a refill. The ring absorbs jitter, and
 * the drift shows up as a slow accumulation that eventually causes an
 * overrun (SDR faster than fabric -> ring fills -> we drop) or an
 * underrun (fabric faster than SDR -> ring empties -> we insert zeros).
 * Both are counted and reported; a few per minute is normal and
 * inaudible, a steady stream of them means the rates are genuinely
 * mismatched and wants investigating rather than ignoring.
 *
 * ---------------------------------------------------------------------
 * SAMPLE FORMAT CONVERSION
 * ---------------------------------------------------------------------
 * RTL-SDR delivers UNSIGNED 8-BIT I/Q, interleaved, offset by 128
 * (i.e. 128 == zero). The PL chain wants sfix16_En15 packed as
 * (I << 16) | Q, matching what the WAV path produced. So:
 *
 *     s16 = ((int16_t)u8 - 128) << 8
 *
 * The << 8 maps the 8-bit range onto the 16-bit one. Note this gives
 * 8 bits of REAL resolution in a 16-bit container -- the low byte is
 * always zero. That is a property of the RTL2832U's ADC, not a defect
 * here. The PL chain carries 18-bit internal precision, so nothing is
 * lost relative to what the SDR can actually deliver, but do not expect
 * 16-bit dynamic range from it.
 *
 * ---------------------------------------------------------------------
 * TUNING AND THE FIXED 10 kHz NCO
 * ---------------------------------------------------------------------
 * The PL's NCO is FIXED at 10 kHz (dds_compiler_0, Phase_Increment
 * Fixed, Output_Frequency1 0.01 MHz). freq_corr computes
 *
 *     Ic = I*cos - Q*sin ,  Qc = I*sin + Q*cos
 *
 * which is a complex multiply by e^(+j*2*pi*10kHz*t) -- it shifts the
 * spectrum UP by 10 kHz. So the station must sit at -10 kHz in the
 * SDR's baseband for it to land at DC, which means tuning the SDR
 * 10 kHz ABOVE the station:
 *
 *     tuner_freq = station_freq + NCO_OFFSET_HZ
 *
 * SIGN NOT VERIFIED ON HARDWARE. If audio comes out distorted or
 * mistuned, try NCO_OFFSET_HZ negative before looking anywhere else --
 * it is one character and the fastest thing to eliminate.
 *
 * Offset tuning is also independently a good idea: the RTL2832U has a
 * strong LO leakage spike at baseband DC. Tuning off-centre moves that
 * spike away from the station rather than straight through the
 * discriminator.
 *
 * ---------------------------------------------------------------------
 * PREREQUISITES ON THE TARGET
 * ---------------------------------------------------------------------
 *   - PS USB0 enabled in the PS7 block design (MIO 28-39) and the
 *     ULPI PHY node present in the device tree. Without this there is
 *     no USB host controller at all and the SDR will not enumerate --
 *     check /sys/bus/usb/devices/ is non-empty before blaming this app.
 *   - librtlsdr in the rootfs.
 *   - The dvb_usb_rtl28xxu kernel module blacklisted, or it will claim
 *     the device first and librtlsdr will fail to open it.
 *
 * ---------------------------------------------------------------------
 * STATE OF THIS FILE
 * ---------------------------------------------------------------------
 * Two changes from the first working version, in order of importance:
 *
 *   1. AUDIO DESTINATION ADDRESS -- fixed, and this was a real bug.
 *      The drain path was selecting between audio_dest and
 *      audio_dest + 50, treating the audio destination as a ping/pong
 *      pair. It is not one: audio_ppdma mirrors every completed block
 *      to a single fixed dest_base and only then flips the flag, so a
 *      consumer must always read the same address. See the long
 *      comment at the drain call site.
 *
 *   2. BLOCKING REFILL -- interim, not a fix. refill_iq_buffer now
 *      waits for a full buffer rather than zero-padding. This exists
 *      only because the fabric currently free-runs at roughly 335 kHz
 *      while the SDR delivers 250 kHz, so the ring drains empty on
 *      every refill. Padding put ~39% zeros into every buffer;
 *      blocking instead lets the fabric re-read the previous buffer.
 *      Measured: 99 spur groups -> 12, and 6.7 dB less artefact level.
 *      But it makes the capture run slower than real time, so the
 *      audio is time-distorted.
 *
 * THE PROPER FIX for (2) is in the PL, not here: gate
 * iq_ppdma_0/ap_start with a 400-cycle counter (100 MHz / 400 =
 * exactly 250 kHz) instead of tying it high with an xlconstant. Then
 * the fabric consumes at the rate the design assumes, the ring never
 * runs dry, and padding-versus-blocking stops mattering. Once that is
 * in, revert this to the simple non-blocking form.
 *
 * Build: gcc -O2 -o fmdemod-rtlsdr fmdemod-rtlsdr.c \
 *            resample_50k_to_48k.c -lgpiod -lrtlsdr -lpthread -lm
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <pthread.h>
#include <sys/mman.h>
#include <sched.h>
#include <math.h>
#include <time.h>
#include <getopt.h>
#include <gpiod.h>
#include <rtl-sdr.h>

/* ------------------------------------------------------------------ */
/* DDR map -- MUST match reserved-memory.dtsi, bd.tcl's xlconstants,   */
/* and vitis main.c. All five agree on 0x1F000000-0x1F4FFFFF.          */
/* ------------------------------------------------------------------ */
#define IQ_PING_ADDR              0x1F000000u
#define IQ_PONG_ADDR              0x1F100000u
#define AUDIO_DEST_ADDR           0x1F400000u
#define IQ_BUF_SIZE_WORDS         2500u
#define AUDIO_SAMPLES_PER_BUFFER  50u
#define MMAP_REGION_SIZE          0x100000u   /* 1 MB per region */

/* ------------------------------------------------------------------ */
/* GPIO -- VERIFIED on Zybo Z7-10: /sys/bus/gpio/devices shows         */
/*   gpiochip0 -> amba_pl/40000000.gpio   (AXI GPIO, ngpio=2)          */
/*   gpiochip1 -> axi/e000a000.gpio       (zynq_gpio PS MIO, ngpio=118)*/
/* The PL controller enumerates FIRST here, so gpiochip0 is correct.   */
/* This ordering is probe-dependent -- re-check with gpiodetect if a   */
/* kernel update or a new PL peripheral changes the enumeration.       */
/* ------------------------------------------------------------------ */
#define GPIOCHIP_NAME             "gpiochip0"
#define IQ_ACTIVE_LINE            0
#define AUDIO_ACTIVE_LINE         1

/* ------------------------------------------------------------------ */
/* RTL-SDR defaults (all overridable on the command line)              */
/* ------------------------------------------------------------------ */
#define DEFAULT_STATION_HZ    100000000u  /* 100.0 MHz */
#define NCO_OFFSET_HZ         10000       /* see TUNING note above */
/* OVERSAMPLING FIX -- was 250000u (matching the PL chain exactly).
 *
 * Compared against Gqrx on the same dongle, same antenna, same
 * location: Gqrx runs the RTL2832U at 1.8 Msps and gets a materially
 * cleaner demodulated spectrum than this app captured at 250 kHz.
 * This is a known RTL2832U characteristic, not guesswork -- the chip's
 * own decimation filters ahead of the final output rate are weak, so
 * sampling directly at a rate close to the target channel bandwidth
 * (250 kHz for a ~200 kHz FM channel) gives the decimator very little
 * oversampling margin to filter with, and more out-of-band noise
 * aliases into the passband. At high input rates the decimator has
 * real margin to work with.
 *
 * Fix: sample at SDR_INPUT_RATE (1.0 Msps -- a rate the RTL2832U
 * handles cleanly, chosen as an exact multiple of the PL's 250 kHz so
 * DECIM_FACTOR is a clean integer) and decimate by DECIM_FACTOR in
 * this callback before the samples ever reach the ring buffer or the
 * PL. Everything downstream of the ring -- refill_iq_buffer, the PL
 * chain, the whole rest of this file -- is UNCHANGED and still runs at
 * exactly 250 kHz; only the dongle's own sample rate changed.
 *
 * Decimator: first-order CIC (a running-sum moving-average, decimated).
 * Deliberately NOT a higher-order CIC -- a 3rd-order CIC at this ratio
 * has ~3.7 dB of droop by 75 kHz and ~6.8 dB by 100 kHz, eating into
 * the same treble this fix is trying to recover. First-order droop is
 * under 1.3 dB across the whole +-75 kHz FM channel, and aa_lpf
 * downstream already does the real anti-alias filtering at its 100 kHz
 * cutoff -- this decimator only needs to knock down what would
 * otherwise alias from above the new, still-oversampled Nyquist, not
 * shape the passband. */
#define SDR_INPUT_RATE        1000000u    /* dongle's actual sample rate */
#define DECIM_FACTOR           4u          /* 1.0 Msps / 4 = 250 kHz exactly */
#define SDR_SAMPLE_RATE       (SDR_INPUT_RATE / DECIM_FACTOR)  /* 250000, unchanged downstream */
#define SDR_DEVICE_INDEX      0

/* librtlsdr async parameters. buf_len must be a multiple of 512.
 * Scaled up 4x from the original 250 kHz-era 16384 bytes to hold the
 * same ~32.8 ms of audio at the new 1.0 Msps input rate (4x the byte
 * rate for the same span of time), so USB interrupt rate and latency
 * characteristics are unchanged from before this fix -- only the
 * dongle's sample rate and the decimator are new. */
#define SDR_ASYNC_BUF_NUM     16
#define SDR_ASYNC_BUF_LEN     65536

/* Ring buffer capacity in I/Q pairs. 128 ping-pong buffers = 320000
 * pairs = 1280 ms at 250 kHz.
 *
 * Doubled from the original 64x/640ms after measuring a steady,
 * non-bursty ring overflow on hardware even with the kernel's RT
 * throttling disabled (echo -1 > /proc/sys/kernel/sched_rt_runtime_us).
 * With the iq_ppdma pacing fix in place (see iq_ppdma.cpp), the
 * refill-to-audio-block RATIO was already correct (measured 9.97:1 and
 * 9.99:1 against a 10:1 target across two runs) -- this headroom
 * increase is about absorbing the poll loop's own per-iteration
 * overhead (two GPIO syscalls, periodic time() calls for progress
 * reporting) staying JUST slightly behind the true 250 kHz drain
 * requirement over a sustained run, not a functional correctness bug.
 *
 * The margin was tight before this: priming alone consumes
 * RING_PAIRS/2 (328 ms worth, at the original 640 ms capacity) before
 * the poll loop even starts, leaving only ~312 ms of headroom for any
 * cumulative drain-rate shortfall to be absorbed in. Doubling the
 * capacity roughly doubles that headroom to ~950 ms while keeping the
 * SAME priming FRACTION (RING_PAIRS/2), so priming itself also takes
 * proportionally longer (~656 ms instead of ~328 ms) -- worth knowing
 * if startup latency ever matters here. */
#define RING_PAIRS            (128u * IQ_BUF_SIZE_WORDS)

#define OUTPUT_WAV_PATH_50K   "audio_50k.wav"
#define OUTPUT_WAV_PATH_48K   "audio_out.wav"

/* ------------------------------------------------------------------ */
/* WAV header                                                          */
/* ------------------------------------------------------------------ */
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
    memcpy(hdr.wave_id, "WAVE", 4);
    memcpy(hdr.fmt_id,  "fmt ", 4);
    hdr.fmt_size        = 16;
    hdr.audio_format    = 1;
    hdr.num_channels    = num_channels;
    hdr.sample_rate     = sample_rate;
    hdr.bits_per_sample = bits_per_sample;
    hdr.block_align     = num_channels * (bits_per_sample / 8);
    hdr.byte_rate       = sample_rate * hdr.block_align;
    memcpy(hdr.data_id, "data", 4);
    hdr.data_size       = 0;
    hdr.riff_size       = sizeof(hdr) - 8;
    return (fwrite(&hdr, 1, sizeof(hdr), f) == sizeof(hdr)) ? 0 : -1;
}

static int wav_patch_header(FILE *f, uint32_t data_bytes)
{
    uint32_t riff_size = data_bytes + sizeof(wav_header_t) - 8;
    if (fseek(f, 4, SEEK_SET) != 0) return -1;
    if (fwrite(&riff_size, 4, 1, f) != 1) return -1;
    if (fseek(f, (long)offsetof(wav_header_t, data_size), SEEK_SET) != 0) return -1;
    if (fwrite(&data_bytes, 4, 1, f) != 1) return -1;
    return 0;
}

/* ------------------------------------------------------------------ */
/* /dev/mem mapping                                                    */
/* ------------------------------------------------------------------ */
static volatile void *map_phys_region(int devmem_fd, uint32_t phys_addr, size_t size)
{
    void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED,
                   devmem_fd, (off_t)phys_addr);
    if (p == MAP_FAILED) {
        fprintf(stderr, "mmap(0x%08X, %zu) failed: %s\n",
                phys_addr, size, strerror(errno));
        return NULL;
    }
    return (volatile void *)p;
}

static void try_enable_realtime_scheduling(void)
{
    struct sched_param sp;
    sp.sched_priority = sched_get_priority_max(SCHED_FIFO);
    if (sched_setscheduler(0, SCHED_FIFO, &sp) == 0) {
        printf("SCHED_FIFO priority %d enabled.\n", sp.sched_priority);
    } else {
        fprintf(stderr, "Warning: SCHED_FIFO not available (%s) -- "
                "running at normal priority. Expect more ring underruns.\n",
                strerror(errno));
    }
}

/* ------------------------------------------------------------------ */
/* GPIO ping-pong flags                                                */
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
        fprintf(stderr, "Run 'gpiodetect' and 'gpioinfo', then update "
                "GPIOCHIP_NAME/IQ_ACTIVE_LINE/AUDIO_ACTIVE_LINE.\n");
        return -1;
    }
    g_iq_line    = gpiod_chip_get_line(g_chip, IQ_ACTIVE_LINE);
    g_audio_line = gpiod_chip_get_line(g_chip, AUDIO_ACTIVE_LINE);
    if (!g_iq_line || !g_audio_line) {
        fprintf(stderr, "gpiod_chip_get_line(%d/%d) failed: %s\n",
                IQ_ACTIVE_LINE, AUDIO_ACTIVE_LINE, strerror(errno));
        return -1;
    }
    if (gpiod_line_request_input(g_iq_line, "fmdemod-iq") != 0 ||
        gpiod_line_request_input(g_audio_line, "fmdemod-audio") != 0) {
        fprintf(stderr, "gpiod_line_request_input failed: %s\n", strerror(errno));
        fprintf(stderr, "If a previous run left sysfs exports behind, clear "
                "them: echo N > /sys/class/gpio/unexport\n");
        return -1;
    }
    return 0;
}

static void gpio_cleanup(void)
{
    if (g_iq_line)    gpiod_line_release(g_iq_line);
    if (g_audio_line) gpiod_line_release(g_audio_line);
    if (g_chip)       gpiod_chip_close(g_chip);
}

static inline int gpio_read_iq_active(void)    { return gpiod_line_get_value(g_iq_line); }
static inline int gpio_read_audio_active(void) { return gpiod_line_get_value(g_audio_line); }

/* ------------------------------------------------------------------ */
/* SPSC ring buffer: rtlsdr callback thread -> poll loop               */
/*                                                                     */
/* Single producer, single consumer, so head and tail each have        */
/* exactly one writer. The atomics are for visibility across cores      */
/* (this is a 2-core A9), not for mutual exclusion -- there is none     */
/* needed. Stores are release, loads acquire, which is enough to        */
/* guarantee the data written before a head update is visible to the    */
/* consumer that observes that head.                                    */
/*                                                                     */
/* Stored pre-packed as (I<<16)|Q so the callback does the conversion   */
/* work on its own thread and the poll loop's refill is a straight      */
/* memcpy. That keeps the latency-critical side as short as possible.   */
/* ------------------------------------------------------------------ */
static uint32_t     *g_ring;           /* RING_PAIRS entries */
static volatile uint32_t g_ring_head;  /* producer writes */
static volatile uint32_t g_ring_tail;  /* consumer writes */

static volatile uint64_t g_stat_overruns;   /* SDR faster: samples dropped */
static volatile uint64_t g_stat_underruns;  /* fabric faster: zeros inserted */
static volatile uint64_t g_stat_rx_pairs;   /* total received from SDR */

static inline uint32_t ring_count(void)
{
    uint32_t h = __atomic_load_n(&g_ring_head, __ATOMIC_ACQUIRE);
    uint32_t t = __atomic_load_n(&g_ring_tail, __ATOMIC_ACQUIRE);
    return h - t;   /* unsigned wraparound is intentional and correct */
}

/* ------------------------------------------------------------------ */
/* librtlsdr async callback -- runs on the reader thread               */
/* ------------------------------------------------------------------ */
/* Decimator state -- persists across callback invocations, since a
 * CIC's accumulator carries samples between USB buffer boundaries.
 * Single producer (this callback, always on the reader thread), so no
 * atomics needed on these -- they are never touched by the poll-loop
 * thread. */
static int32_t g_cic_i_acc = 0;
static int32_t g_cic_q_acc = 0;
static uint32_t g_cic_phase = 0;   /* counts 0..DECIM_FACTOR-1 */

static void rtlsdr_cb(unsigned char *buf, uint32_t len, void *ctx)
{
    (void)ctx;

    uint32_t raw_pairs = len / 2;   /* interleaved I,Q bytes at SDR_INPUT_RATE */

    /* Decimate first, into a small local buffer, THEN take the ring
     * lock/space check. This keeps the ring's accounting (RING_PAIRS,
     * overrun stats, refill_iq_buffer's expectations) entirely in
     * terms of the FINAL 250 kHz rate, exactly as it was before this
     * fix -- nothing downstream needs to know the dongle is now
     * oversampling and decimating. */
    static uint32_t decimated[SDR_ASYNC_BUF_LEN / 2];   /* worst case: DECIM_FACTOR=1 */
    uint32_t n_decimated = 0;

    for (uint32_t i = 0; i < raw_pairs; i++) {
        /* unsigned 8-bit offset-128 -> signed, BEFORE the <<8 scale.
         * Accumulate at this smaller scale so DECIM_FACTOR samples
         * summed still fits comfortably in int32_t; the <<8 to reach
         * sfix16_En15 is applied once, after decimation, below. */
        int32_t Iu = (int32_t)buf[2 * i]     - 128;
        int32_t Qu = (int32_t)buf[2 * i + 1] - 128;

        g_cic_i_acc += Iu;
        g_cic_q_acc += Qu;
        g_cic_phase++;

        if (g_cic_phase >= DECIM_FACTOR) {
            /* First-order CIC = boxcar average, decimated: divide the
             * sum of DECIM_FACTOR samples by DECIM_FACTOR, then apply
             * the same <<8 scale rtlsdr_cb always used to map the
             * 8-bit range into sfix16_En15. */
            int16_t I = (int16_t)((g_cic_i_acc / (int32_t)DECIM_FACTOR) << 8);
            int16_t Q = (int16_t)((g_cic_q_acc / (int32_t)DECIM_FACTOR) << 8);

            decimated[n_decimated++] =
                ((uint32_t)(uint16_t)I << 16) | (uint32_t)(uint16_t)Q;

            g_cic_i_acc = 0;
            g_cic_q_acc = 0;
            g_cic_phase = 0;
        }
    }

    if (n_decimated == 0) {
        return;   /* can happen on a very short buffer; nothing to push yet */
    }

    uint32_t h = __atomic_load_n(&g_ring_head, __ATOMIC_RELAXED);
    uint32_t t = __atomic_load_n(&g_ring_tail, __ATOMIC_ACQUIRE);
    uint32_t free_space = RING_PAIRS - (h - t);

    uint32_t pairs = n_decimated;
    if (pairs > free_space) {
        /* Ring full: the fabric is not keeping up, or the poll loop is
         * blocked (an SD-card write stall will do it). Drop the excess
         * rather than overwrite unread data -- a gap is recoverable,
         * torn buffers are not. */
        __atomic_fetch_add(&g_stat_overruns, pairs - free_space, __ATOMIC_RELAXED);
        pairs = free_space;
    }

    for (uint32_t i = 0; i < pairs; i++) {
        g_ring[(h + i) % RING_PAIRS] = decimated[i];
    }

    __atomic_store_n(&g_ring_head, h + pairs, __ATOMIC_RELEASE);
    __atomic_fetch_add(&g_stat_rx_pairs, pairs, __ATOMIC_RELAXED);
}

/* ------------------------------------------------------------------ */
/* Reader thread(s)                                                    */
/* ------------------------------------------------------------------ */
static rtlsdr_dev_t *g_dev;
static volatile int   g_running = 1;

/* File-replay mode global -- set by main() before the reader thread
 * starts if -I <path> was given. NULL means "use the live dongle". */
static const char *g_replay_path = NULL;

static void *reader_thread(void *arg)
{
    (void)arg;
    /* Blocks until rtlsdr_cancel_async() is called from the main thread. */
    int r = rtlsdr_read_async(g_dev, rtlsdr_cb, NULL,
                              SDR_ASYNC_BUF_NUM, SDR_ASYNC_BUF_LEN);
    if (r != 0 && g_running) {
        fprintf(stderr, "rtlsdr_read_async returned %d unexpectedly\n", r);
    }
    g_running = 0;
    return NULL;
}

/* ---------------------------------------------------------------------
 * File-replay reader thread.
 * ---------------------------------------------------------------------
 * Reads raw u8 I/Q from a file captured with:
 *     rtl_sdr -f <freq> -s <SDR_INPUT_RATE> -n <count> capture.iq
 * and feeds it through rtlsdr_cb() in SDR_ASYNC_BUF_LEN-sized chunks --
 * the SAME function the live dongle path calls, so the decimator, the
 * ring buffer, and everything downstream (refill_iq_buffer, the GPIO
 * handshake with the PL, drain_audio_block, the WAV writer, the
 * resampler) are IDENTICAL code paths to the live-capture run. Only
 * the source of I/Q bytes differs.
 *
 * This exists to answer one specific question cheaply: if this app and
 * ref_fm_demod.py (a separate, independent Python implementation) are
 * given the EXACT SAME capture.iq file, do they produce comparable
 * audio? If yes, the demodulator chain is validated and any remaining
 * difference between a live Zybo run and a live Gqrx run is about the
 * RF environment or the live capture path, not the demod math. If no,
 * this isolates the disagreement to something in fmdemod-rtlsdr.c
 * itself, independent of antenna, timing, or signal strength on the
 * day.
 *
 * PACING: paced to real time, matching how a live dongle would have
 * delivered these same bytes.
 *
 * AN EARLIER VERSION OF THIS FUNCTION HAD NO PACING -- it read and
 * pushed the whole file as fast as disk I/O allowed. The ring buffer
 * only holds RING_PAIRS pairs (a few hundred ms at SDR_INPUT_RATE), so
 * a 10 second file arriving in a few tens of milliseconds overflowed
 * it almost immediately: measured result was 2,187,500 of 2,500,000
 * decimated pairs DROPPED as overruns, and the resulting WAV was only
 * the first ~1.2 seconds of a 10 second capture -- silently truncated,
 * not obviously wrong from the file just looking "kind of short". Any
 * spectral comparison against ref_fm_demod.py's output (which DOES
 * process the entire file) would have been comparing different spans
 * of audio, not a fair test.
 *
 * Fixed by sleeping between chunks for the same span of time that
 * chunk represents at SDR_INPUT_RATE -- i.e. behaving like a real
 * 1 Msps source rather than a firehose. This makes a 10 second
 * capture take ~10 seconds to replay, same as it would live, and the
 * ring buffer never sees a burst larger than a live dongle could ever
 * produce. -d/--duration is still ignored (the whole file is always
 * processed, once, then the thread exits) -- pacing makes THAT
 * meaningful too, since duration is now determined by the file's own
 * length rather than being irrelevant.
 * ------------------------------------------------------------------ */
static void *file_replay_thread(void *arg)
{
    (void)arg;

    FILE *fin = fopen(g_replay_path, "rb");
    if (!fin) {
        fprintf(stderr, "file_replay: fopen(%s) failed: %s\n",
                g_replay_path, strerror(errno));
        g_running = 0;
        return NULL;
    }

    unsigned char *chunk = malloc(SDR_ASYNC_BUF_LEN);
    if (!chunk) {
        fprintf(stderr, "file_replay: malloc(%u) failed\n", SDR_ASYNC_BUF_LEN);
        fclose(fin);
        g_running = 0;
        return NULL;
    }

    /* Time one full SDR_ASYNC_BUF_LEN chunk represents at the dongle's
     * real sample rate: SDR_ASYNC_BUF_LEN bytes = SDR_ASYNC_BUF_LEN/2
     * I/Q pairs, at SDR_INPUT_RATE pairs/sec. usleep() takes
     * microseconds, hence the 1e6 factor. A short final chunk sleeps
     * proportionally less, computed from its own actual byte count
     * rather than always sleeping the full-chunk duration. */
    const double us_per_full_chunk =
        1e6 * (double)(SDR_ASYNC_BUF_LEN / 2) / (double)SDR_INPUT_RATE;

    struct timespec t_start_ts;
    clock_gettime(CLOCK_MONOTONIC, &t_start_ts);
    uint64_t chunks_sent = 0;

    uint64_t total_bytes = 0;
    size_t n;
    while (g_running && (n = fread(chunk, 1, SDR_ASYNC_BUF_LEN, fin)) > 0) {
        /* rtlsdr_cb expects an even byte count (interleaved I,Q pairs).
         * A short final read from the file could leave a dangling
         * single byte; drop it rather than feed a half-sample in. */
        if (n & 1) n -= 1;
        if (n == 0) break;

        rtlsdr_cb(chunk, (uint32_t)n, NULL);
        total_bytes += n;
        chunks_sent++;

        /* Pace to real time: sleep until this chunk's own slice of
         * elapsed wall-clock time has actually passed, measured against
         * a single fixed start time rather than accumulating per-chunk
         * sleep durations -- the latter drifts under scheduling jitter
         * (each chunk's sleep error adds to the next), the former
         * self-corrects every iteration. */
        double target_us = us_per_full_chunk * (double)chunks_sent
                            * ((double)n / (double)SDR_ASYNC_BUF_LEN);
        struct timespec now_ts;
        clock_gettime(CLOCK_MONOTONIC, &now_ts);
        double elapsed_us = 1e6 * (double)(now_ts.tv_sec - t_start_ts.tv_sec)
                           + 1e-3 * (double)(now_ts.tv_nsec - t_start_ts.tv_nsec);
        double sleep_us = target_us - elapsed_us;
        if (sleep_us > 0) {
            usleep((useconds_t)sleep_us);
        }
        /* sleep_us <= 0 means this chunk's processing already took
         * longer than its real-time slice -- fall behind rather than
         * try to catch up by bursting, which would just recreate the
         * overrun problem this pacing exists to avoid. */
    }

    free(chunk);
    fclose(fin);

    printf("file_replay: consumed %llu bytes (%llu I/Q pairs) from %s "
           "over %.2f s (paced to real time)\n",
           (unsigned long long)total_bytes,
           (unsigned long long)(total_bytes / 2), g_replay_path,
           us_per_full_chunk * (double)chunks_sent / 1e6);

    g_running = 0;   /* signals main's poll loop and priming wait to stop */
    return NULL;
}

/* ------------------------------------------------------------------ */
/* Refill one ping-pong buffer from the ring                           */
/* ------------------------------------------------------------------ */
static uint32_t iq_packed[IQ_BUF_SIZE_WORDS];

/* DIAGNOSTIC BUILD -- blocks for a full buffer instead of zero-padding.
 *
 * WHY: the fabric free-runs at roughly 335 kHz while the SDR delivers
 * 250 kHz, so the ring drains empty on every refill and ~39% of every
 * buffer was being filled with zeros. That is a hard step from real
 * samples to silence and back at EVERY buffer boundary. The buffer
 * period is 2500 pairs at 250 kHz = 10 ms on the input side, which
 * after R=5 decimation and 50-sample audio blocks lands as a 1 kHz
 * comb through the whole audio band -- measured at ~+20 dB above the
 * local noise floor at 500 Hz, 1500 Hz, 2500 Hz and every 1 kHz step
 * up to 19.5 kHz. That comb IS the periodic sound, and it was present
 * at full strength with the antenna DISCONNECTED, which is what proves
 * it is generated here rather than received.
 *
 * WHAT THIS BUILD DOES: waits for a complete buffer rather than
 * padding. The capture then runs SLOWER THAN REAL TIME and the audio
 * is time-distorted -- the fabric still consumes faster than the SDR
 * supplies, so this fixes nothing. It only answers one question:
 *
 *   comb GONE     -> zero-padding was the sole cause. The PL rate
 *                    limiter (gate iq_ppdma_0/ap_start with a
 *                    400-cycle counter for exactly 250 kHz) is then
 *                    the complete fix.
 *   comb SURVIVES -> something else produces a per-block
 *                    discontinuity, most likely the ping-pong
 *                    handshake: drain_audio_block() reads whichever
 *                    buffer the GPIO flag says is inactive, with no
 *                    protection against that flag changing mid-read.
 *                    Worth fixing BEFORE spending a Vivado rebuild.
 *
 * NOT FOR NORMAL USE -- revert to the padding version, or better to a
 * rate-limited fabric, once the question is answered.
 */
static void refill_iq_buffer(volatile uint32_t *dest)
{
    /* Block until a whole buffer is available. g_running is checked so
     * Ctrl-C still works rather than hanging here indefinitely if the
     * SDR stops delivering. */
    while (ring_count() < IQ_BUF_SIZE_WORDS && g_running) {
        usleep(100);
    }

    uint32_t t         = __atomic_load_n(&g_ring_tail, __ATOMIC_RELAXED);
    uint32_t available = ring_count();
    uint32_t n         = (available < IQ_BUF_SIZE_WORDS)
                             ? available : IQ_BUF_SIZE_WORDS;

    for (uint32_t i = 0; i < n; i++) {
        iq_packed[i] = g_ring[(t + i) % RING_PAIRS];
    }
    /* Only reachable now if g_running went false during the wait above
     * (i.e. shutdown). Kept so the shutdown path cannot push an
     * uninitialised buffer tail at the fabric. */
    if (n < IQ_BUF_SIZE_WORDS) {
        memset(&iq_packed[n], 0, (IQ_BUF_SIZE_WORDS - n) * sizeof(uint32_t));
        __atomic_fetch_add(&g_stat_underruns, IQ_BUF_SIZE_WORDS - n,
                           __ATOMIC_RELAXED);
    }

    __atomic_store_n(&g_ring_tail, t + n, __ATOMIC_RELEASE);
    memcpy((void *)dest, iq_packed, sizeof(iq_packed));
}

/* ------------------------------------------------------------------ */
/* Audio scaling -- IDENTICAL to fmdemod-linux.c and vitis main.c.     */
/*                                                                     */
/* The DDR word is sfix32_En13 representing FREQUENCY DEVIATION IN HZ, */
/* not a normalised [-1,+1] amplitude:                                 */
/*     / 8192           -> deviation in Hz (~+-15 kHz after de-emph)   */
/*     / FM_MAX_DEV_HZ  -> normalised [-1,+1]                          */
/*     * 32767          -> PCM16                                       */
/* Combined into one 64-bit integer scale-and-round: raw*32767 exceeds  */
/* 32 bits, and a float divide plus lroundf() is real per-sample cost   */
/* inside a thin buffer-swap margin.                                    */
/* ------------------------------------------------------------------ */
#define FM_MAX_DEV_HZ  75000L
#define PCM_SCALE_NUM  32767LL
#define PCM_SCALE_DEN  ((int64_t)8192 * (int64_t)FM_MAX_DEV_HZ)

static int16_t audio_pcm_block[AUDIO_SAMPLES_PER_BUFFER];

static int drain_audio_block(volatile uint32_t *src, FILE *fout,
                              uint32_t *total_audio_bytes)
{
    for (uint32_t i = 0; i < AUDIO_SAMPLES_PER_BUFFER; i++) {
        int32_t raw = (int32_t)src[i];
        int64_t num = (int64_t)raw * PCM_SCALE_NUM;
        int64_t scaled;

        if (num >= 0) {
            scaled = (num + PCM_SCALE_DEN / 2) / PCM_SCALE_DEN;
        } else {
            int64_t neg = -num;
            scaled = -((neg + PCM_SCALE_DEN / 2) / PCM_SCALE_DEN);
        }
        if (scaled >  32767) scaled =  32767;
        if (scaled < -32768) scaled = -32768;
        audio_pcm_block[i] = (int16_t)scaled;
    }

    size_t written = fwrite(audio_pcm_block, 1, sizeof(audio_pcm_block), fout);
    if (written != sizeof(audio_pcm_block)) {
        fprintf(stderr, "drain_audio_block: fwrite failed (%zu of %zu)\n",
                written, sizeof(audio_pcm_block));
        return -1;
    }
    *total_audio_bytes += (uint32_t)written;
    return 0;
}

/* Provided by resample_50k_to_48k.c -- unchanged from the file path. */
extern int resample_wav_50k_to_48k(const char *in_path, const char *out_path);

/* ------------------------------------------------------------------ */
/* Signal handling -- Ctrl-C must stop cleanly so the WAV header gets   */
/* patched with the real length, otherwise the file is unplayable.      */
/* ------------------------------------------------------------------ */
static void sigint_handler(int sig)
{
    (void)sig;
    g_running = 0;
    if (g_dev) rtlsdr_cancel_async(g_dev);
}

/* ------------------------------------------------------------------ */
static void usage(const char *argv0)
{
    fprintf(stderr,
        "Usage: %s [options]\n"
        "  -f <Hz>   station centre frequency   (default %u = %.1f MHz)\n"
        "  -g <dB>   tuner gain in dB, or -1 for AGC   (default -1)\n"
        "  -d <sec>  capture duration, 0 = until Ctrl-C  (default 30,\n"
        "            ignored in -I file-replay mode -- see below)\n"
        "  -i <n>    RTL-SDR device index       (default %d)\n"
        "  -p <ppm>  frequency correction in ppm (default 0)\n"
        "  -I <path> FILE-REPLAY MODE: read raw u8 I/Q from a file\n"
        "            instead of opening a live dongle. -f, -g, -p, -d\n"
        "            and device selection are all ignored -- the file\n"
        "            is assumed to already be at the tuned/decimated\n"
        "            frequency and rate (SDR_INPUT_RATE, currently\n"
        "            %u Hz) that a live run would have produced.\n"
        "            Runs through the IDENTICAL decimator/ring-buffer/\n"
        "            PL/WAV path as a live capture; only the source of\n"
        "            bytes differs. Exists to compare this app's output\n"
        "            against an independent reference demodulator (e.g.\n"
        "            ref_fm_demod.py) on byte-for-byte identical input,\n"
        "            eliminating the RF environment as a variable.\n"
        "            Capture a compatible file with:\n"
        "              rtl_sdr -f <freq+10kHz> -s %u -n <count> capture.iq\n"
        "  -h        this help\n"
        "\n"
        "The tuner is set to (station + %d Hz) to place the signal at\n"
        "-%d Hz in baseband, where the PL's fixed 10 kHz NCO moves it to\n"
        "DC. If audio is mistuned, try flipping the sign of NCO_OFFSET_HZ.\n"
        "(In -I mode, the file must already be captured with this same\n"
        "+10 kHz offset for the PL's fixed NCO to work correctly.)\n",
        argv0, DEFAULT_STATION_HZ, DEFAULT_STATION_HZ / 1e6,
        SDR_DEVICE_INDEX, SDR_INPUT_RATE, SDR_INPUT_RATE,
        NCO_OFFSET_HZ, NCO_OFFSET_HZ);
}

int main(int argc, char **argv)
{
    uint32_t station_hz  = DEFAULT_STATION_HZ;
    int      gain_db     = -1;      /* -1 == AGC */
    int      duration_s  = 30;
    int      dev_index   = SDR_DEVICE_INDEX;
    int      ppm         = 0;
    const char *replay_path = NULL;   /* -I <path>: file-replay mode */

    int devmem_fd = -1;
    volatile uint32_t *iq_ping = NULL, *iq_pong = NULL, *audio_dest = NULL;
    FILE *fout = NULL;
    pthread_t reader;
    int reader_started = 0;
    uint32_t total_audio_bytes = 0;
    uint32_t iq_refill_count = 0, audio_block_count = 0;
    int iq_prev, audio_prev;
    int ret = 1;
    int opt;

    while ((opt = getopt(argc, argv, "f:g:d:i:p:I:h")) != -1) {
        switch (opt) {
        case 'f': station_hz = (uint32_t)strtoul(optarg, NULL, 10); break;
        case 'g': gain_db    = atoi(optarg); break;
        case 'd': duration_s = atoi(optarg); break;
        case 'i': dev_index  = atoi(optarg); break;
        case 'p': ppm        = atoi(optarg); break;
        case 'I': replay_path = optarg; break;
        case 'h': usage(argv[0]); return 0;
        default:  usage(argv[0]); return 1;
        }
    }
    g_replay_path = replay_path;   /* visible to file_replay_thread() */

    printf("=== FM Demod live (RTL-SDR -> PL chain -> WAV) ===\n");

    signal(SIGINT,  sigint_handler);
    signal(SIGTERM, sigint_handler);

    try_enable_realtime_scheduling();

    /* ---- Ring buffer ---- */
    g_ring = calloc(RING_PAIRS, sizeof(uint32_t));
    if (!g_ring) {
        fprintf(stderr, "calloc(%u pairs) for ring buffer failed\n", RING_PAIRS);
        return 1;
    }

    /* ---- DDR mappings ---- */
    devmem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (devmem_fd < 0) {
        perror("open(/dev/mem)");
        fprintf(stderr, "This needs root.\n");
        goto cleanup_ring;
    }
    iq_ping    = (volatile uint32_t *)map_phys_region(devmem_fd, IQ_PING_ADDR,    MMAP_REGION_SIZE);
    iq_pong    = (volatile uint32_t *)map_phys_region(devmem_fd, IQ_PONG_ADDR,    MMAP_REGION_SIZE);
    audio_dest = (volatile uint32_t *)map_phys_region(devmem_fd, AUDIO_DEST_ADDR, MMAP_REGION_SIZE);
    if (!iq_ping || !iq_pong || !audio_dest) goto cleanup_maps;

    if (gpio_init() != 0) goto cleanup_gpio;

    if (g_replay_path) {
        /* ---- File-replay mode: skip the dongle entirely ---- */
        printf("=== FILE-REPLAY MODE ===\n");
        printf("Reading: %s\n", g_replay_path);
        printf("Assumed input rate: %u Hz (must match how the file was\n"
               "captured -- e.g. rtl_sdr -s %u)\n", SDR_INPUT_RATE, SDR_INPUT_RATE);
        printf("Decimated by %u -> %u Hz to the PL, same as a live run.\n",
               DECIM_FACTOR, SDR_SAMPLE_RATE);
        printf("-f/-g/-p/-d/-i are all ignored in this mode.\n");
        /* g_dev stays NULL. Every place downstream that guards on
         * "if (g_dev)" before touching the dongle (cleanup, signal
         * handler, rtlsdr_cancel_async calls) is therefore naturally a
         * no-op in replay mode -- no separate cleanup path needed. */
    } else {
        /* ---- RTL-SDR open and configure (live dongle) ---- */
        {
            int count = rtlsdr_get_device_count();
            if (count <= 0) {
                fprintf(stderr, "No RTL-SDR devices found.\n");
                fprintf(stderr, "Check: (1) /sys/bus/usb/devices/ is non-empty "
                        "(if empty, PS USB0 is not enabled in the PS7 config);\n"
                        "       (2) dvb_usb_rtl28xxu is blacklisted;\n"
                        "       (3) lsusb shows 0bda:2838.\n");
                goto cleanup_gpio;
            }
            printf("Found %d RTL-SDR device(s); using index %d: %s\n",
                   count, dev_index, rtlsdr_get_device_name(dev_index));

            if (rtlsdr_open(&g_dev, dev_index) != 0) {
                fprintf(stderr, "rtlsdr_open(%d) failed: %s\n", dev_index, strerror(errno));
                goto cleanup_gpio;
            }
        }

        /* Set the DONGLE to SDR_INPUT_RATE (oversampled), not
         * SDR_SAMPLE_RATE (the PL's rate) -- the decimator in rtlsdr_cb
         * brings it down to SDR_SAMPLE_RATE before anything else sees it. */
        if (rtlsdr_set_sample_rate(g_dev, SDR_INPUT_RATE) != 0) {
            fprintf(stderr, "rtlsdr_set_sample_rate(%u) failed\n", SDR_INPUT_RATE);
            goto cleanup_sdr;
        }
        printf("Sample rate: %u Hz dongle input (actual %u Hz), decimated by %u -> %u Hz to the PL\n",
               SDR_INPUT_RATE, rtlsdr_get_sample_rate(g_dev), DECIM_FACTOR, SDR_SAMPLE_RATE);

        if (ppm != 0 && rtlsdr_set_freq_correction(g_dev, ppm) < 0) {
            fprintf(stderr, "Warning: rtlsdr_set_freq_correction(%d) failed\n", ppm);
        }

        {
            uint32_t tuner_hz = (uint32_t)((int64_t)station_hz + NCO_OFFSET_HZ);
            if (rtlsdr_set_center_freq(g_dev, tuner_hz) != 0) {
                fprintf(stderr, "rtlsdr_set_center_freq(%u) failed\n", tuner_hz);
                goto cleanup_sdr;
            }
            printf("Station:     %.4f MHz\n", station_hz / 1e6);
            printf("Tuner:       %.4f MHz  (station %+d Hz, for the fixed 10 kHz NCO)\n",
                   rtlsdr_get_center_freq(g_dev) / 1e6, NCO_OFFSET_HZ);
        }

        if (gain_db < 0) {
            rtlsdr_set_tuner_gain_mode(g_dev, 0);   /* 0 == automatic */
            printf("Tuner gain:  AGC\n");
        } else {
            int gains[64];
            int n = rtlsdr_get_tuner_gains(g_dev, gains);
            int best = 0, i;
            for (i = 0; i < n && i < 64; i++) {
                if (abs(gains[i] - gain_db * 10) < abs(gains[best] - gain_db * 10)) {
                    best = i;
                }
            }
            rtlsdr_set_tuner_gain_mode(g_dev, 1);   /* 1 == manual */
            if (n > 0) rtlsdr_set_tuner_gain(g_dev, gains[best]);
            printf("Tuner gain:  %.1f dB (nearest supported to %d dB)\n",
                   (n > 0 ? gains[best] : 0) / 10.0, gain_db);
        }

        if (rtlsdr_reset_buffer(g_dev) != 0) {
            fprintf(stderr, "Warning: rtlsdr_reset_buffer failed\n");
        }
    }

    /* ---- Output WAV ---- */
    fout = fopen(OUTPUT_WAV_PATH_50K, "wb");
    if (!fout) {
        perror("fopen(" OUTPUT_WAV_PATH_50K ")");
        goto cleanup_sdr;
    }
    if (wav_write_placeholder_header(fout, 50000, 1, 16) != 0) {
        fprintf(stderr, "Failed to write placeholder WAV header\n");
        goto cleanup_fout;
    }

    /* ---- Start the reader, then wait for the ring to prime ----
     * Entering the poll loop with an empty ring would produce a burst of
     * underruns and a click at the start of every capture. Half full is
     * an arbitrary but comfortable starting point: enough cushion to
     * absorb early USB jitter without adding noticeable latency.
     *
     * file_replay_thread() fills the ring the same way rtlsdr_cb() does
     * (it calls the same function), just from a file instead of USB, so
     * this priming logic is unchanged for replay mode -- it will simply
     * fill much faster since there's no USB scheduling to wait on. */
    if (pthread_create(&reader, NULL,
                        g_replay_path ? file_replay_thread : reader_thread,
                        NULL) != 0) {
        fprintf(stderr, "pthread_create(reader) failed: %s\n", strerror(errno));
        goto cleanup_fout;
    }
    reader_started = 1;

    printf("Priming ring buffer...\n");
    {
        int waited_ms = 0;
        while (g_running && ring_count() < RING_PAIRS / 2 && waited_ms < 3000) {
            usleep(10000);
            waited_ms += 10;
        }
        if (ring_count() < IQ_BUF_SIZE_WORDS) {
            fprintf(stderr, "No samples arriving %s after %d ms. %s\n",
                    g_replay_path ? "from the file" : "from the SDR", waited_ms,
                    g_replay_path
                        ? "Check the file path and that it isn't empty/truncated."
                        : "Check the USB link and the antenna.");
            goto cleanup_thread;
        }
        printf("Ring primed: %u pairs (%.0f ms)\n",
               ring_count(), 1000.0 * ring_count() / SDR_SAMPLE_RATE);
    }

    refill_iq_buffer(iq_ping);
    refill_iq_buffer(iq_pong);

    iq_prev    = gpio_read_iq_active();
    audio_prev = gpio_read_audio_active();
    if (iq_prev < 0 || audio_prev < 0) {
        fprintf(stderr, "Initial gpiod_line_get_value failed\n");
        goto cleanup_thread;
    }

    if (g_replay_path) {
        printf("Processing file (runs until the file is exhausted; "
               "-d is ignored in replay mode)...\n");
    } else if (duration_s > 0) {
        printf("Capturing for %d s (Ctrl-C to stop early)...\n", duration_s);
    } else {
        printf("Capturing until Ctrl-C...\n");
    }

    /* ---- Poll loop ---- */
    {
        time_t t_start = time(NULL);
        time_t t_last_report = t_start;

        while (g_running) {
            int iq_now = gpio_read_iq_active();
            if (iq_now < 0) {
                fprintf(stderr, "gpiod_line_get_value(iq) failed: %s\n",
                        strerror(errno));
                break;
            }
            if (iq_now != iq_prev) {
                refill_iq_buffer((iq_now == 0) ? iq_pong : iq_ping);
                iq_refill_count++;
                iq_prev = iq_now;
            }

            int audio_now = gpio_read_audio_active();
            if (audio_now < 0) {
                fprintf(stderr, "gpiod_line_get_value(audio) failed: %s\n",
                        strerror(errno));
                break;
            }
            if (audio_now != audio_prev) {
                /* BUG FIX: always read the SAME address.
                 *
                 * This previously selected between audio_dest and
                 * audio_dest + AUDIO_SAMPLES_PER_BUFFER, carrying over
                 * the ping/pong pattern from the I/Q side. The audio
                 * side does not work that way. From audio_ppdma.cpp:
                 *
                 *   "the just-completed buffer is burst-copied to the
                 *    fixed dest_base address before the active buffer
                 *    flips. A consumer that always reads dest_base
                 *    therefore only ever sees a complete, stable 1 ms
                 *    block -- it never needs to know ping/pong exist."
                 *   "active_buf flips only after the copy finishes
                 *    (atomic hand-off)"
                 *
                 * So audio_ppdma mirrors EVERY completed block to one
                 * fixed address and only then toggles the flag. The
                 * offset version therefore read 50 words PAST the
                 * mirror on alternate blocks -- memory the DMA never
                 * writes -- giving stale or uninitialised data every
                 * other block. That is a discontinuity at exactly the
                 * block period (50 samples at 50 kHz = 1 ms), which is
                 * a 1 kHz comb through the whole audio band.
                 *
                 * The bare-metal main.c, whose audio was correct, reads
                 * AUDIO_DEST_ADDR unconditionally everywhere -- no
                 * offset, no selection. Matching that here.
                 *
                 * active_buf is still used purely as a "new block
                 * ready" edge; its VALUE says which buffer is now
                 * receiving, which the consumer does not care about. */
                if (drain_audio_block(audio_dest, fout, &total_audio_bytes) != 0) break;
                audio_block_count++;
                audio_prev = audio_now;
            }

            time_t now = time(NULL);
            if (now != t_last_report) {
                t_last_report = now;
                printf("  [%3ds] refills=%u blocks=%u ring=%u/%u "
                       "under=%llu over=%llu\n",
                       (int)(now - t_start), iq_refill_count, audio_block_count,
                       ring_count(), RING_PAIRS,
                       (unsigned long long)g_stat_underruns,
                       (unsigned long long)g_stat_overruns);
                fflush(stdout);
            }
            /* In replay mode duration_s is ignored -- the loop exits
             * because g_running goes false when file_replay_thread()
             * runs out of file, checked at the top of this while(). */
            if (!g_replay_path && duration_s > 0 && (now - t_start) >= duration_s) {
                printf("Duration reached.\n");
                break;
            }
        }
    }

    g_running = 0;
    if (g_dev) rtlsdr_cancel_async(g_dev);

    printf("\n=== Capture statistics ===\n");
    printf("  I/Q refills:       %u\n", iq_refill_count);
    printf("  Audio blocks:      %u\n", audio_block_count);
    printf("  Audio bytes:       %u\n", total_audio_bytes);
    printf("  Pairs from SDR:    %llu\n", (unsigned long long)g_stat_rx_pairs);
    printf("  Ring underruns:    %llu pairs\n", (unsigned long long)g_stat_underruns);
    printf("  Ring overruns:     %llu pairs\n", (unsigned long long)g_stat_overruns);
    if (g_stat_rx_pairs > 0) {
        double bad = 100.0 * (double)(g_stat_underruns + g_stat_overruns)
                           / (double)g_stat_rx_pairs;
        printf("  Loss:              %.4f%%\n", bad);
        if (bad > 1.0) {
            printf("  NOTE: >1%% loss. A steady rate of under- or overruns "
                   "means the SDR and fabric sample rates genuinely differ, "
                   "not just jitter -- worth measuring rather than ignoring.\n");
        }
    }

    if (wav_patch_header(fout, total_audio_bytes) != 0) {
        fprintf(stderr, "Warning: failed to patch %s header\n", OUTPUT_WAV_PATH_50K);
    }
    fclose(fout);
    fout = NULL;
    printf("\n50 kHz WAV: %s (%u bytes)\n", OUTPUT_WAV_PATH_50K, total_audio_bytes);

    printf("Resampling %s -> %s ...\n", OUTPUT_WAV_PATH_50K, OUTPUT_WAV_PATH_48K);
    if (resample_wav_50k_to_48k(OUTPUT_WAV_PATH_50K, OUTPUT_WAV_PATH_48K) == 0) {
        printf("Done. Final 48 kHz audio: %s\n", OUTPUT_WAV_PATH_48K);
        ret = 0;
    } else {
        fprintf(stderr, "Resample FAILED\n");
    }

cleanup_thread:
    if (reader_started) {
        g_running = 0;
        if (g_dev) rtlsdr_cancel_async(g_dev);
        pthread_join(reader, NULL);
    }
cleanup_fout:
    if (fout) {
        wav_patch_header(fout, total_audio_bytes);
        fclose(fout);
    }
cleanup_sdr:
    if (g_dev) rtlsdr_close(g_dev);
cleanup_gpio:
    gpio_cleanup();
cleanup_maps:
    if (iq_ping)    munmap((void *)iq_ping,    MMAP_REGION_SIZE);
    if (iq_pong)    munmap((void *)iq_pong,    MMAP_REGION_SIZE);
    if (audio_dest) munmap((void *)audio_dest, MMAP_REGION_SIZE);
    if (devmem_fd >= 0) close(devmem_fd);
cleanup_ring:
    free(g_ring);
    return ret;
}
