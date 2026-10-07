/*
 * alsa_live.c
 *
 * See alsa_live.h for the overall design rationale (opening at the
 * PL's native rate via ALSA's own plug-layer resampler, rather than
 * retrofitting the file path's polyphase resampler for streaming).
 *
 * ---------------------------------------------------------------------
 * REVISION: moved snd_pcm_writei() onto its own thread
 * ---------------------------------------------------------------------
 * The first version called snd_pcm_writei() directly from
 * alsa_live_feed(), itself called synchronously from the main poll
 * loop. This was flagged as a real risk in that version's own
 * comments ("NOT REAL-TIME SAFE... if it becomes a problem in
 * practice... moving this call onto its own thread would be the next
 * step") -- and it did become a problem: observed on hardware as
 * audio playing in chunks with gaps between them.
 *
 * The mechanism: snd_pcm_writei() blocks if ALSA's own buffer is
 * momentarily full. Called from the SAME thread that also does GPIO
 * polling, I/Q ring draining, and WAV writing, any such block stalls
 * the WHOLE poll loop -- nothing drains the I/Q ring, nothing feeds
 * the next audio block, nothing writes the WAV, until ALSA's buffer
 * frees up. Everything backs up, then bursts once unblocked. That is
 * exactly a "chunks, gap, chunks, gap" pattern, not random noise.
 *
 * Fixed the same way the project's own I/Q path already solves this
 * exact class of problem: a producer/consumer ring buffer with a
 * DEDICATED consumer thread, so the potentially-blocking call is
 * fully decoupled from the poll loop. alsa_live_feed() is now a fast,
 * always-non-blocking producer (a straight memcpy into a ring, worst
 * case a few atomic ops) -- it can no longer stall the poll loop no
 * matter what ALSA is doing. The new alsa_playback_thread is the
 * consumer: it pulls raw native-rate samples off the ring, applies the
 * STATEFUL de-emphasis + HF filter (moved here from alsa_live_feed --
 * same math, same persistent state, just relocated to the thread that
 * now owns the whole playback path), and calls snd_pcm_writei(),
 * blocking freely with zero effect on anything else.
 *
 * Same atomic-ring pattern as g_ring in fmdemod-rtlsdr.c (SPSC,
 * __ATOMIC_ACQUIRE/RELEASE, drop-on-overflow rather than block the
 * producer) -- deliberately reused rather than inventing a different
 * technique for what is structurally the same problem.
 */
#include "alsa_live.h"
#include "pl_rates.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <pthread.h>
#include <sched.h>
#include <errno.h>
#include <unistd.h>
#include <alsa/asoundlib.h>

/* Requested end-to-end ALSA hardware buffer latency, microseconds.
 * This is ALSA's OWN internal buffer, separate from and in addition
 * to the software ring below. Generous on purpose -- FM radio has no
 * meaningful latency requirement. */
#define ALSA_LATENCY_US   200000u

/* Software ring between the poll loop (producer) and the playback
 * thread (consumer), in samples. 50000 = ~1.08 s at 46.2 kHz --
 * generous, matching the philosophy already used for g_ring: cheap in
 * memory, and a large margin against scheduling jitter on EITHER side
 * (the poll loop producing, or the playback thread's own transient
 * delays) is far cheaper than a single audible stall. */
#define AUDIO_RING_SAMPLES   50000u

/* ---------------------------------------------------------------------
 * Stateful de-emphasis + HF low-pass -- same coefficients and math as
 * resample_50k_to_48k.c's deemph_75_to_50() / hf_lowpass_8k(), but with
 * PERSISTENT state, appropriate for a continuous stream rather than a
 * once-per-whole-file reset. See the original module's header comment
 * for why these are duplicated rather than shared: the two call
 * patterns (whole-file vs. continuous-stream) have different state-
 * reset correctness requirements, so keeping them visibly separate
 * avoids either one silently developing an assumption that breaks the
 * other.
 *
 * Runs on the PLAYBACK THREAD now, not in alsa_live_feed() -- moved
 * here as part of decoupling the poll loop from anything that could
 * block or take variable time.
 * ------------------------------------------------------------------ */
/* RATE FIX (2026-10-07): DEEMPH_* and HF_LPF_* now come from
 * pl_rates.h, shared with resample_50k_to_48k.c and recomputed for
 * the PL's MEASURED 46,333 Hz audio rate. The filter STATE stays
 * separate per module, for the reason above; only the constants are
 * shared, so the two paths can no longer drift apart numerically. */

static double g_deemph_x_prev = 0.0;
static double g_deemph_y_prev = 0.0;
static double g_hf_w1 = 0.0;
static double g_hf_w2 = 0.0;

static void stream_filter_block(int16_t *buf, int n)
{
    for (int i = 0; i < n; i++) {
        double x = (double)buf[i];
        double y = DEEMPH_G * (x - DEEMPH_A75 * g_deemph_x_prev)
                   + DEEMPH_A50 * g_deemph_y_prev;
        g_deemph_x_prev = x;
        g_deemph_y_prev = y;

        double w0 = y - HF_LPF_A1 * g_hf_w1 - HF_LPF_A2 * g_hf_w2;
        double out = HF_LPF_B0 * w0 + HF_LPF_B1 * g_hf_w1 + HF_LPF_B2 * g_hf_w2;
        g_hf_w2 = g_hf_w1;
        g_hf_w1 = w0;

        if (out >  32767.0) out =  32767.0;
        if (out < -32768.0) out = -32768.0;
        buf[i] = (int16_t)lround(out);
    }
}

/* ---------------------------------------------------------------------
 * SPSC ring: poll loop (producer) -> playback thread (consumer).
 * Same pattern as g_ring in fmdemod-rtlsdr.c -- see there for the
 * full rationale of the atomic ordering used.
 * ------------------------------------------------------------------ */
static int16_t          *g_audio_ring;
static volatile uint32_t g_ring_head;   /* poll loop writes */
static volatile uint32_t g_ring_tail;   /* playback thread writes */
static volatile uint64_t g_stat_dropped;   /* ring-full: producer dropped samples */

static inline uint32_t audio_ring_count(void)
{
    uint32_t h = __atomic_load_n(&g_ring_head, __ATOMIC_ACQUIRE);
    uint32_t t = __atomic_load_n(&g_ring_tail, __ATOMIC_ACQUIRE);
    return h - t;   /* unsigned wraparound intentional, same as g_ring */
}

/* ---------------------------------------------------------------------
 * ALSA device + playback thread state
 * ------------------------------------------------------------------ */
static snd_pcm_t     *g_pcm = NULL;
static pthread_t       g_playback_thread;
static volatile int    g_playback_running = 0;
static unsigned         g_underrun_count = 0;

static void *alsa_playback_thread_fn(void *arg)
{
    (void)arg;

    /* THIRD REVISION to this thread's scheduling -- see alsa_live_init()
     * below for attempts 1 and 2 and why each failed. This attempt
     * abandons pthread_attr_t-based creation-time scheduling entirely
     * (two different pthread_attr approaches failed with two different
     * symptoms on this target -- inherited SCHED_FIFO 99 causing I/Q
     * overrun, then an explicit SCHED_RR pthread_attr_t rejected
     * outright with EINVAL at pthread_create -- suggesting something
     * about pthread_attr-based RT scheduling is unreliable on this
     * platform's libc, not that the specific priority value chosen was
     * wrong). Uses sched_setscheduler() instead, called by the thread
     * on ITSELF, as its first action after starting -- the EXACT same
     * API fmdemod-rtlsdr.c's own try_enable_realtime_scheduling()
     * already uses successfully for the poll loop every single run
     * ("SCHED_FIFO priority 99 enabled." prints cleanly every time).
     * Reusing a mechanism already proven working on this exact target,
     * rather than a third variation of an approach that has now failed
     * twice in ways this project has not been able to fully explain
     * without direct hardware access to debug further.
     *
     * pid=0 in sched_setscheduler() means "the calling thread" on
     * Linux -- each thread has its own scheduling attributes
     * independent of the process, so this correctly sets THIS
     * thread's policy/priority only, not the whole process's. */
    {
        struct sched_param sp;
        int prio_min = sched_get_priority_min(SCHED_RR);
        int prio_max = sched_get_priority_max(SCHED_RR);
        int prio = prio_min + 2;
        if (prio > prio_max) prio = prio_max;
        sp.sched_priority = prio;

        if (sched_setscheduler(0, SCHED_RR, &sp) == 0) {
            printf("alsa_live: playback thread SCHED_RR priority %d "
                   "(range %d..%d, poll loop is SCHED_FIFO 99 -- "
                   "always strictly subordinate to it)\n",
                   prio, prio_min, prio_max);
        } else {
            fprintf(stderr, "alsa_live: playback thread could not set "
                    "SCHED_RR (%s) -- running at default (inherited) "
                    "scheduling instead. If this inherited SCHED_FIFO "
                    "99 from the poll loop, I/Q ring overrun under load "
                    "is possible again; if it inherited plain "
                    "SCHED_OTHER, this thread could be starved under "
                    "heavy real-time load instead (silence, no audio) "
                    "-- watch for either symptom.\n", strerror(errno));
        }
    }

    /* Pulled off the ring in modest chunks -- small enough to keep
     * latency low and to notice g_playback_running going false
     * promptly on shutdown, large enough to keep the per-call ALSA
     * and filtering overhead sensible. Not tied to
     * AUDIO_SAMPLES_PER_BUFFER (50) -- this thread does not need to
     * know or care how the producer chose to batch its writes. */
    enum { CHUNK = 256 };
    int16_t chunk[CHUNK];

    while (g_playback_running) {
        uint32_t avail = audio_ring_count();
        if (avail == 0) {
            /* Nothing queued -- short sleep rather than a hot spin.
             * 5ms is short enough not to add perceptible latency on
             * top of ALSA's own 200ms hardware buffer, long enough
             * not to waste CPU busy-polling. */
            usleep(5000);
            continue;
        }

        uint32_t n = avail < CHUNK ? avail : CHUNK;
        uint32_t t = __atomic_load_n(&g_ring_tail, __ATOMIC_RELAXED);
        for (uint32_t i = 0; i < n; i++) {
            chunk[i] = g_audio_ring[(t + i) % AUDIO_RING_SAMPLES];
        }
        __atomic_store_n(&g_ring_tail, t + n, __ATOMIC_RELEASE);

        stream_filter_block(chunk, (int)n);

        snd_pcm_sframes_t written = snd_pcm_writei(g_pcm, chunk, n);
        if (written < 0) {
            int rec = snd_pcm_recover(g_pcm, (int)written, 1);
            if (rec < 0) {
                fprintf(stderr, "alsa_playback_thread: snd_pcm_writei "
                        "failed and could not recover: %s\n",
                        snd_strerror(rec));
                /* Keep the thread alive rather than exiting -- a
                 * transient device issue recovering on a LATER write
                 * is preferable to permanently silencing playback for
                 * the rest of the capture. */
            } else {
                g_underrun_count++;
            }
        }
    }

    return NULL;
}

int alsa_live_init(const char *device_name)
{
    const char *dev = device_name ? device_name : "default";
    int err;

    if (g_pcm) {
        alsa_live_close();
    }

    g_audio_ring = calloc(AUDIO_RING_SAMPLES, sizeof(int16_t));
    if (!g_audio_ring) {
        fprintf(stderr, "alsa_live_init: calloc for audio ring failed\n");
        return -1;
    }
    g_ring_head = 0;
    g_ring_tail = 0;
    g_stat_dropped = 0;

    err = snd_pcm_open(&g_pcm, dev, SND_PCM_STREAM_PLAYBACK, 0);
    if (err < 0) {
        fprintf(stderr, "alsa_live_init: snd_pcm_open(%s) failed: %s\n",
                dev, snd_strerror(err));
        fprintf(stderr, "alsa_live_init: use a PLUG-wrapped device name "
                "(\"default\" or \"plughw:X,Y\"), not a raw \"hw:X,Y\" -- "
                "the PL's native audio rate is not one "
                "of the dongle's supported hardware rates, and only the "
                "plug layer does the software rate conversion.\n");
        free(g_audio_ring);
        g_audio_ring = NULL;
        g_pcm = NULL;
        return -1;
    }

    err = snd_pcm_set_params(g_pcm,
                              SND_PCM_FORMAT_S16_LE,
                              SND_PCM_ACCESS_RW_INTERLEAVED,
                              1,           /* mono */
                              PL_AUDIO_RATE_HZ,  /* PL's MEASURED native rate */
                              1,           /* soft_resample */
                              ALSA_LATENCY_US);
    if (err < 0) {
        fprintf(stderr, "alsa_live_init: snd_pcm_set_params failed: %s\n",
                snd_strerror(err));
        snd_pcm_close(g_pcm);
        free(g_audio_ring);
        g_audio_ring = NULL;
        g_pcm = NULL;
        return -1;
    }

    g_underrun_count = 0;
    g_deemph_x_prev = 0.0;
    g_deemph_y_prev = 0.0;
    g_hf_w1 = 0.0;
    g_hf_w2 = 0.0;

    g_playback_running = 1;

    /* Created with default (inherited) scheduling -- the thread sets
     * its OWN policy/priority as its first action once running, via
     * sched_setscheduler(). See the long comment at the top of
     * alsa_playback_thread_fn() for the two pthread_attr_t-based
     * creation-time approaches that were tried first and why each
     * failed differently on this target, and why sched_setscheduler()
     * (an already-proven-working API here, not a new one) was used
     * instead. */
    if (pthread_create(&g_playback_thread, NULL, alsa_playback_thread_fn, NULL) != 0) {
        fprintf(stderr, "alsa_live_init: pthread_create failed: %s\n",
                strerror(errno));
        g_playback_running = 0;
        snd_pcm_close(g_pcm);
        free(g_audio_ring);
        g_audio_ring = NULL;
        g_pcm = NULL;
        return -1;
    }

    printf("alsa_live: opened %s for playback at %u Hz mono "
           "(ALSA converts to the hardware's native rate), playback "
           "thread started\n", dev, PL_AUDIO_RATE_HZ);

    return 0;
}

int alsa_live_feed(const int16_t *block, int n)
{
    /* Fast, always-non-blocking producer: a straight memcpy into the
     * ring plus a couple of atomic ops. No filtering, no ALSA calls,
     * nothing that can stall -- see the file header for why that
     * matters. */
    if (!g_pcm || !block || n <= 0) {
        return 0;   /* not enabled -- silent no-op */
    }

    uint32_t h = __atomic_load_n(&g_ring_head, __ATOMIC_RELAXED);
    uint32_t t = __atomic_load_n(&g_ring_tail, __ATOMIC_ACQUIRE);
    uint32_t free_space = AUDIO_RING_SAMPLES - (h - t);

    uint32_t to_write = (uint32_t)n;
    if (to_write > free_space) {
        /* Ring full -- the playback thread has fallen behind (a
         * genuinely stalled/misbehaving ALSA device, most likely).
         * Drop rather than block the poll loop, same policy as
         * rtlsdr_cb uses for the I/Q ring, for the same reason: a
         * dropped sample is far cheaper than stalling everything
         * else this thread is responsible for. */
        __atomic_fetch_add(&g_stat_dropped, to_write - free_space, __ATOMIC_RELAXED);
        to_write = free_space;
    }

    for (uint32_t i = 0; i < to_write; i++) {
        g_audio_ring[(h + i) % AUDIO_RING_SAMPLES] = block[i];
    }
    __atomic_store_n(&g_ring_head, h + to_write, __ATOMIC_RELEASE);

    return 0;
}

int alsa_live_active(void)
{
    return g_pcm != NULL;
}

unsigned alsa_live_underrun_count(void)
{
    return g_underrun_count;
}

void alsa_live_close(void)
{
    if (g_playback_running) {
        g_playback_running = 0;
        pthread_join(g_playback_thread, NULL);
    }
    if (g_pcm) {
        snd_pcm_drain(g_pcm);
        snd_pcm_close(g_pcm);
        g_pcm = NULL;
    }
    if (g_audio_ring) {
        free(g_audio_ring);
        g_audio_ring = NULL;
    }
}
