/*
 * gpio_rate_test.c
 *
 * Standalone, minimal tool: measures the REAL toggle rate of
 * iq_ppdma_0's active_buf GPIO line, completely independent of
 * fmdemod-rtlsdr's own ring buffer / refill / ALSA / WAV logic.
 *
 * ---------------------------------------------------------------------
 * WHY THIS EXISTS
 * ---------------------------------------------------------------------
 * Eight independent measurements/fixes -- four scheduling
 * configurations, syscall-count reduction (bulk GPIO reads), USB
 * bandwidth reduction (oversampling revert), poll-loop iteration rate
 * (measured ~219,000/s, over 1000x the 200 Hz Nyquist margin needed to
 * reliably catch a 100 Hz toggle), and USB callback timing (measured
 * essentially perfectly uniform: min=32.56ms avg=32.77ms max=33.17ms
 * against a 32.77ms theoretical value) -- have ALL been ruled out as
 * the cause of a remarkably consistent ~5.6% I/Q ring loss during live
 * capture. Every layer of the software and USB stack checks out.
 *
 * The one remaining unverified assumption: that iq_ppdma_0 genuinely
 * toggles its active_buf GPIO at 100 Hz (every 10ms) ON REAL SILICON.
 * This was confirmed via the HLS csynth report (Interval = 400 cycles
 * at 100 MHz, after the LATENCY pragma fix) -- but that is a STATIC
 * analysis of the synthesized design's INTENDED schedule, not a
 * measurement of the actual running hardware. Something between that
 * report and physical silicon (DDR/HP0 bus contention with
 * audio_ppdma's own traffic, a clock-domain subtlety, anything at all)
 * could make the true toggle rate differ from what was predicted --
 * and nothing so far has measured that independent of fmdemod-rtlsdr's
 * own refill accounting, which would just faithfully report symptoms
 * of a hardware problem rather than reveal the cause.
 *
 * This tool does ONE thing: watches the GPIO line and counts real
 * value changes over a fixed wall-clock window, with NO ring buffer,
 * NO RTL-SDR, NO ALSA, NO DDR/PL data path at all -- just the line
 * itself. If it reports ~100 Hz, the hardware is confirmed correct and
 * the cause is something not yet identified. If it reports something
 * meaningfully different, THAT is the root cause, one layer below
 * everything tested so far.
 *
 * IMPORTANT: run this with fmdemod-rtlsdr NOT running -- a GPIO line
 * can only be requested by one process at a time, and this tool needs
 * the PL to be genuinely running (i.e. run fmdemod-rtlsdr first to get
 * the design into its normal operating state, or ensure whatever
 * drives iq_ppdma is active) for the toggle to be happening at all.
 * If nothing is driving the PL, this will correctly report ~0 Hz --
 * that is not a bug, it means there is nothing to measure yet.
 *
 * Usage:
 *   sudo ./gpio_rate_test [seconds]      (default 10s)
 *
 * Build:
 *   gcc -O2 -Wall -Wextra -o gpio_rate_test gpio_rate_test.c -lgpiod
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <time.h>
#include <gpiod.h>

/* Same chip/line as fmdemod-rtlsdr.c -- confirmed earlier this project
 * via /sys/bus/gpio/devices: gpiochip0 -> amba_pl/40000000.gpio (the
 * AXI GPIO, ngpio=2), line 0 = iq_ppdma_0's active_buf. Update these if
 * gpiodetect/gpioinfo ever shows a different mapping (enumeration order
 * is probe-dependent and can change between kernel builds). */
#define GPIOCHIP_NAME   "gpiochip0"
#define IQ_ACTIVE_LINE  0

int main(int argc, char **argv)
{
    int duration_s = 10;
    if (argc > 1) {
        duration_s = atoi(argv[1]);
        if (duration_s <= 0) {
            fprintf(stderr, "usage: %s [seconds > 0]\n", argv[0]);
            return 1;
        }
    }

    struct gpiod_chip *chip = gpiod_chip_open_by_name(GPIOCHIP_NAME);
    if (!chip) {
        fprintf(stderr, "gpiod_chip_open_by_name(%s) failed: %s\n",
                GPIOCHIP_NAME, strerror(errno));
        return 1;
    }

    struct gpiod_line *line = gpiod_chip_get_line(chip, IQ_ACTIVE_LINE);
    if (!line) {
        fprintf(stderr, "gpiod_chip_get_line(%d) failed: %s\n",
                IQ_ACTIVE_LINE, strerror(errno));
        gpiod_chip_close(chip);
        return 1;
    }

    if (gpiod_line_request_input(line, "gpio_rate_test") != 0) {
        fprintf(stderr, "gpiod_line_request_input failed: %s\n", strerror(errno));
        fprintf(stderr, "If fmdemod-rtlsdr is still running, stop it first -- "
                "a GPIO line can only be requested by one process at a time.\n");
        gpiod_chip_close(chip);
        return 1;
    }

    int prev = gpiod_line_get_value(line);
    if (prev < 0) {
        fprintf(stderr, "initial gpiod_line_get_value failed: %s\n", strerror(errno));
        gpiod_line_release(line);
        gpiod_chip_close(chip);
        return 1;
    }

    printf("Watching %s line %d for %d s (Ctrl-C to stop early)...\n",
           GPIOCHIP_NAME, IQ_ACTIVE_LINE, duration_s);
    printf("Initial value: %d\n", prev);
    printf("(fmdemod-rtlsdr should be running in another session, actively "
           "capturing, for there to be anything to measure)\n\n");

    struct timespec t_start, t_now;
    clock_gettime(CLOCK_MONOTONIC, &t_start);

    uint64_t toggle_count = 0;
    uint64_t poll_count   = 0;
    double   elapsed_s    = 0.0;

    /* Report progress once a second -- same style as fmdemod-rtlsdr's
     * own progress line, so the two are easy to compare side by side. */
    time_t next_report = time(NULL) + 1;

    for (;;) {
        int now_val = gpiod_line_get_value(line);
        poll_count++;
        if (now_val < 0) {
            fprintf(stderr, "gpiod_line_get_value failed: %s\n", strerror(errno));
            break;
        }
        if (now_val != prev) {
            toggle_count++;
            prev = now_val;
        }

        clock_gettime(CLOCK_MONOTONIC, &t_now);
        elapsed_s = (double)(t_now.tv_sec - t_start.tv_sec)
                  + (double)(t_now.tv_nsec - t_start.tv_nsec) / 1e9;

        if (time(NULL) >= next_report) {
            next_report = time(NULL) + 1;
            printf("  [%5.1fs] toggles=%llu  (%.1f Hz avg so far)  poll_iters=%llu\n",
                   elapsed_s, (unsigned long long)toggle_count,
                   (double)toggle_count / elapsed_s,
                   (unsigned long long)poll_count);
            fflush(stdout);
        }

        if (elapsed_s >= (double)duration_s) break;
    }

    printf("\n=== Result ===\n");
    printf("  Elapsed:          %.3f s\n", elapsed_s);
    printf("  Toggles observed: %llu\n", (unsigned long long)toggle_count);
    printf("  Measured rate:    %.2f Hz  (expect ~100 Hz if hardware matches "
           "design intent)\n", (double)toggle_count / elapsed_s);
    printf("  Poll iterations:  %llu  (%.0f/s -- this tool's own polling "
           "headroom, for reference)\n",
           (unsigned long long)poll_count, (double)poll_count / elapsed_s);

    gpiod_line_release(line);
    gpiod_chip_close(chip);
    return 0;
}
