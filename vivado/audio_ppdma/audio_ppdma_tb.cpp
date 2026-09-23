#include <iostream>
#include <vector>
#include "audio_ppdma.h"

/**
 * Self-checking testbench for the ping-pong capture + destination mirror.
 *
 * ---------------------------------------------------------------------
 * UPDATED FOR THE SPREAD-MIRROR FIX -- checks trigger on the active_buf
 * EDGE, not on a fixed sample-count offset
 * ---------------------------------------------------------------------
 * The ORIGINAL testbench checked dest_base/active_buf at a FIXED point
 * -- the moment a block's 50th sample was accepted -- because the
 * ORIGINAL audio_ppdma.cpp did the mirror copy synchronously, so that
 * fixed point was always safe.
 *
 * The fix spreads the mirror copy across the NEXT block's invocations
 * instead, to close a silent-sample-loss window against de_emph (which
 * has no tready and never waits -- see audio_ppdma.cpp's header for the
 * full mechanism). An earlier version of this file checked at a fixed
 * "one block later" offset and found the design ALSO had a genuine bug
 * at that point: active_buf's report was delayed by an extra
 * invocation beyond the mirror's actual completion, and that extra
 * delay landed on exactly the same invocation where the next mirror
 * starts overwriting dest_base -- no safe window existed. That bug is
 * fixed in audio_ppdma.cpp (active_buf now reports the CURRENT,
 * up-to-date state, not a deliberately stale one).
 *
 * With that fixed, the mirror completes and active_buf becomes visibly
 * correct on the SAME invocation, ONE INVOCATION BEFORE the next
 * block's own sample-count boundary -- not aligned with a fixed
 * sample-count offset at all. Rather than hard-code that specific
 * offset (fragile -- it depends on exact internal timing that could
 * shift if the design changes again), this testbench detects the
 * active_buf EDGE directly, the same way real software actually
 * consumes this signal (polling a GPIO for a toggle), and checks
 * dest_base at that exact, empirically-safe moment.
 */
int main() {
    std::cout << "======================================================" << std::endl;
    std::cout << "=== Audio Ping-Pong DMA Self-Checking Test         ===" << std::endl;
    std::cout << "=== (spread-mirror version -- edge-triggered checks) ===" << std::endl;
    std::cout << "======================================================" << std::endl;

    const int N_REAL_BLOCKS  = 10;
    const int N_TEST_SAMPLES = (N_REAL_BLOCKS + 1) * SAMPLES_PER_BUFFER;  // +1 flush block

    const addr_t PING_BASE = 0x00000000;
    const addr_t PONG_BASE = (addr_t)BUFFER_BYTES;
    const addr_t DEST_BASE = (addr_t)(2 * BUFFER_BYTES);

    const size_t MEM_WORDS = (3 * BUFFER_BYTES) / SAMPLE_BYTES;
    std::vector<sample_t> mem(MEM_WORDS, 0);

    ap_uint<1> active_buf     = 0;
    ap_uint<1> last_active_buf = 0;
    bool       first_call      = true;

    int failure_count  = 0;
    int blocks_checked = 0;

    // Each completed block's expected info, captured at ITS OWN
    // sample-count boundary (unchanged from the original testbench --
    // this part of the timing did not change), held until the
    // active_buf edge confirms it is safe to check.
    bool has_pending          = false;
    int  pending_block_first  = 0;
    int  pending_block_last   = 0;
    bool pending_filled_pong  = false;

    std::cout << "Block\t\tExpected buffer\tdest mirror\tactive_buf after" << std::endl;
    std::cout << "----------------------------------------------------------------------" << std::endl;

    for (int n = 0; n < N_TEST_SAMPLES; n++) {
        sample_t in_sample = 1000 + n;

        audio_ppdma(in_sample, mem.data(), PING_BASE, PONG_BASE, DEST_BASE, active_buf);

        // Capture each block's expected info at its own sample-count
        // boundary -- this is just bookkeeping, not a safety-critical
        // timing assumption; it only needs to happen BEFORE the
        // corresponding active_buf edge, which it always does (the
        // edge cannot occur before the block that causes it has even
        // finished being counted).
        if ((n + 1) % SAMPLES_PER_BUFFER == 0) {
            int  block_first  = n - SAMPLES_PER_BUFFER + 1;
            int  block_index  = (n + 1) / SAMPLES_PER_BUFFER - 1;
            bool filled_pong  = (block_index % 2) == 1;

            if (block_index < N_REAL_BLOCKS) {
                has_pending         = true;
                pending_block_first = block_first;
                pending_block_last  = n;
                pending_filled_pong = filled_pong;
            }
        }

        // Check at the ACTUAL active_buf edge -- the empirically
        // confirmed safe moment, not an assumed fixed offset.
        bool edge = (!first_call) && (active_buf != last_active_buf);
        if (edge && has_pending) {
            bool block_ok = true;
            for (int i = 0; i < SAMPLES_PER_BUFFER; i++) {
                sample_t expected = 1000 + pending_block_first + i;
                sample_t got      = mem[(DEST_BASE >> 2) + i];
                if (got != expected) { block_ok = false; }
            }
            bool active_ok = (active_buf == (pending_filled_pong ? 0 : 1));

            std::cout << "[" << pending_block_first << ":" << pending_block_last << "]\t"
                      << (pending_filled_pong ? "pong" : "ping") << "\t\t"
                      << (block_ok ? "PASS" : "FAIL") << "\t\t"
                      << active_buf << (active_ok ? "" : " (WRONG)") << std::endl;

            blocks_checked++;
            if (!block_ok || !active_ok) failure_count++;
            has_pending = false;
        }

        last_active_buf = active_buf;
        first_call = false;
    }

    std::cout << "----------------------------------------------------------------------" << std::endl;
    std::cout << "Verification Summary: " << (blocks_checked - failure_count)
              << "/" << blocks_checked << " blocks passed." << std::endl;

    if (failure_count > 0) {
        std::cout << "=== TEST BENCH FAILED: " << failure_count << " block(s) mismatched ===" << std::endl;
        return 1;
    }

    if (blocks_checked != N_REAL_BLOCKS) {
        std::cout << "=== TEST BENCH FAILED: expected " << N_REAL_BLOCKS
                  << " blocks checked, got " << blocks_checked << " ===" << std::endl;
        return 1;
    }

    std::cout << "=== TEST BENCH PASSED: ping-pong capture + dest mirror verified (edge-triggered) ===" << std::endl;
    return 0;
}
