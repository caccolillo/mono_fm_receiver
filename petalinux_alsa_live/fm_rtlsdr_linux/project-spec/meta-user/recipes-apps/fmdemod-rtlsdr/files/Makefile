# Three translation units: the capture/demod driver, the resampler,
# and the optional live-ALSA-playback module (-A flag; a safe no-op
# throughout if never enabled).
#   -lgpiod    ping-pong handshake lines
#   -lrtlsdr   the dongle
#   -lpthread  the librtlsdr async reader runs on its own thread
#   -lm        lround() in the resampler and in alsa_live's filters
#   -lasound   ALSA playback (alsa_live.c) -- requires alsa-lib in
#              DEPENDS below so the cross-compile sysroot has the
#              headers; requires CONFIG_alsa-lib in rootfs_config so
#              libasound.so.2 is actually present on the target at
#              runtime (dev headers are NOT needed on the target --
#              nothing compiles code on the board itself).
CFLAGS  += -O2 -Wall -Wextra
LDLIBS  += -lgpiod -lrtlsdr -lpthread -lm -lasound

OBJS = fmdemod-rtlsdr.o resample_50k_to_48k.o alsa_live.o

all: fmdemod-rtlsdr gpio_rate_test

fmdemod-rtlsdr: $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $(OBJS) $(LDLIBS)

# Standalone diagnostic -- shares no object files with fmdemod-rtlsdr,
# links only against libgpiod. See gpio_rate_test.c's own header for
# why this exists: measuring the REAL iq_ppdma active_buf toggle rate
# independent of the main app's own ring/refill accounting, to check
# an assumption (100 Hz on real silicon) that was previously only
# confirmed via a static HLS synthesis report, never measured directly.
gpio_rate_test: gpio_rate_test.o
	$(CC) $(LDFLAGS) -o $@ $< -lgpiod

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f $(OBJS) gpio_rate_test.o fmdemod-rtlsdr gpio_rate_test

.PHONY: all clean
