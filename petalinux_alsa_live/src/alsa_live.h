/*
 * alsa_live.h
 *
 * Live ALSA playback for fmdemod-rtlsdr, alongside (not instead of)
 * the existing WAV-file output. Entirely separate module -- disabled
 * by default, opt-in via -A, and every function is a safe no-op if
 * alsa_live_init() was never called (so a caller that never enables
 * -A pays zero cost and takes zero risk from this code).
 */
#ifndef ALSA_LIVE_H
#define ALSA_LIVE_H

#include <stdint.h>

/* Opens the ALSA PCM device for playback at the PL's NATIVE 50 kHz
 * rate. Deliberately does NOT reuse the file path's 50k->48k
 * polyphase resampler -- that resampler resets its internal state
 * once per WHOLE FILE (correct there) and has no mechanism to carry
 * state across the 50-sample blocks a live stream actually arrives
 * in; retrofitting that correctly would need real history-buffer
 * bookkeeping across call boundaries, which is a nontrivial change to
 * a delicate polyphase filter with no way to test it here. Opening
 * the device via ALSA's "plug" layer (plughw:X,Y, or "default" on
 * most setups) instead hands the final rate conversion to ALSA's own
 * mature, already-streaming-safe software resampler -- avoiding that
 * whole class of risk entirely.
 *
 * device_name: an ALSA PCM device string, e.g. "plughw:0,0" or
 * "default". NULL defaults to "default".
 *
 * Returns 0 on success, -1 on failure (device not found, format not
 * supported, etc. -- reported to stderr with the ALSA error string).
 * On failure the caller should proceed WITHOUT live playback rather
 * than aborting the whole capture -- see the call site in main().
 */
int alsa_live_init(const char *device_name);

/* Feed one AUDIO_SAMPLES_PER_BUFFER (50-sample) block of native
 * 50 kHz PCM16 audio -- the SAME data just written to the WAV file,
 * unmodified by this call (a local copy is filtered internally; the
 * caller's buffer, and therefore the WAV file output, is never
 * touched). Applies the same 75us->50us de-emphasis correction and
 * 8 kHz HF low-pass as the file path, but with PERSISTENT filter
 * state carried across calls -- appropriate for a continuous stream,
 * where the file path's per-call reset would put an audible
 * discontinuity at every single 1 ms block boundary (i.e. 1000 times
 * a second) if reused here unmodified.
 *
 * A no-op returning 0 immediately if alsa_live_init() was never
 * called or failed -- safe to call unconditionally from the poll loop
 * without an extra "is live playback enabled" check at every call
 * site.
 *
 * NOT REAL-TIME SAFE in the strict sense: snd_pcm_writei() can block
 * if the ALSA ring buffer is full, which happens if playback
 * underruns and needs recovery. This is acceptable here because nothing
 * else in the poll loop has a harder real-time deadline than "keep
 * the I/Q ring from overflowing", and alsa_live_init() sizes ALSA's
 * own buffer generously (see the .c file) specifically to make that
 * blocking rare. If it becomes a problem in practice (visible as I/Q
 * ring overruns correlating with audio underrun messages on stderr),
 * moving this call onto -- its own thread, decoupled from the poll
 * loop entirely, would be the next step; not done here to keep this
 * change small and easy to verify in isolation first.
 */
int alsa_live_feed(const int16_t *block, int n);

/* Reports whether live playback is currently active (initialised and
 * not yet closed) -- for the closing stats printout, to distinguish
 * "no underruns because it's working" from "no underruns because
 * live playback was never enabled". */
int alsa_live_active(void);

/* Reports the running count of ALSA underrun/xrun recoveries since
 * alsa_live_init() -- 0 if never enabled. */
unsigned alsa_live_underrun_count(void);

/* Closes the PCM device. Safe to call even if alsa_live_init() was
 * never called or failed (no-op in that case). */
void alsa_live_close(void);

#endif /* ALSA_LIVE_H */
