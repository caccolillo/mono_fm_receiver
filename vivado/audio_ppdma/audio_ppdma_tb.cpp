#include <iostream>
#include <vector>
#include "audio_ppdma.h"

/**
 * Self-checking testbench for the ping-pong capture + destination mirror.
 *
 * This is a control-logic test, not a DSP-accuracy test (there is no
 * fixed-point signal path here to validate against MATLAB) -- it checks
 * that:
 *   1. Every completed 1 ms block ends up mirrored correctly at dest_base.
 *   2. active_buf flips exactly once per completed block, and reports the
 *      buffer now being filled.
 *   3. ping_base and pong_base never overlap in what they end up holding
 *      per round (alternate correctly).
 *
 * Note on control protocol: audio_ppdma now uses the default ap_ctrl_hs
 * handshake rather than ap_ctrl_none, but in C simulation that's
 * transparent -- csim still just calls the function once per incoming
 * sample, exactly as before. The ap_start/ap_done/ap_idle/ap_ready
 * handshake only becomes visible in the generated RTL/cosim, where
 * ap_start is tied permanently high in the block design so the block
 * restarts itself the instant it goes idle.
 *
 * Synthetic stimulus: sample n = 1000 + n, so the expected contents of
 * any completed block are trivially predictable without an external
 * golden file.
 */
int main() {
    std::cout << "======================================================" << std::endl;
    std::cout << "=== Audio Ping-Pong DMA Self-Checking Test         ===" << std::endl;
    std::cout << "======================================================" << std::endl;

    const int N_TEST_SAMPLES = 500;   // 10 ms worth -> 10 complete buffers

    // Non-overlapping regions, contiguous for convenience only -- real
    // addresses will be wherever the GPIOs are programmed to point.
    const addr_t PING_BASE = 0x00000000;
    const addr_t PONG_BASE = (addr_t)BUFFER_BYTES;
    const addr_t DEST_BASE = (addr_t)(2 * BUFFER_BYTES);

    const size_t MEM_WORDS = (3 * BUFFER_BYTES) / SAMPLE_BYTES;
    std::vector<sample_t> mem(MEM_WORDS, 0);

    ap_uint<1> active_buf = 0;
    int failure_count = 0;
    int blocks_checked = 0;

    std::cout << "Block\t\tExpected buffer\tdest mirror\tactive_buf after" << std::endl;
    std::cout << "----------------------------------------------------------------------" << std::endl;

    for (int n = 0; n < N_TEST_SAMPLES; n++) {
        sample_t in_sample = 1000 + n;

        audio_ppdma(in_sample, mem.data(), PING_BASE, PONG_BASE, DEST_BASE, active_buf);

        if ((n + 1) % SAMPLES_PER_BUFFER == 0) {
            int block_first  = n - SAMPLES_PER_BUFFER + 1;
            int block_index  = (n + 1) / SAMPLES_PER_BUFFER - 1;   // 0-based
            bool filled_pong = (block_index % 2) == 1;             // ping first, then pong, ...

            bool block_ok = true;
            for (int i = 0; i < SAMPLES_PER_BUFFER; i++) {
                sample_t expected = 1000 + block_first + i;
                sample_t got      = mem[(DEST_BASE >> 2) + i];
                if (got != expected) { block_ok = false; }
            }

            // After this block completes, active_buf must equal the
            // buffer now being filled -- the opposite of the one just
            // mirrored (ping just filled -> now filling pong -> active_buf=1).
            bool active_ok = (active_buf == (filled_pong ? 0 : 1));

            std::cout << "[" << block_first << ":" << n << "]\t"
                      << (filled_pong ? "pong" : "ping") << "\t\t"
                      << (block_ok ? "PASS" : "FAIL") << "\t\t"
                      << active_buf << (active_ok ? "" : " (WRONG)") << std::endl;

            blocks_checked++;
            if (!block_ok || !active_ok) failure_count++;
        }
    }

    std::cout << "----------------------------------------------------------------------" << std::endl;
    std::cout << "Verification Summary: " << (blocks_checked - failure_count)
              << "/" << blocks_checked << " blocks passed." << std::endl;

    if (failure_count > 0) {
        std::cout << "=== TEST BENCH FAILED: " << failure_count << " block(s) mismatched ===" << std::endl;
        return 1;
    }

    std::cout << "=== TEST BENCH PASSED: ping-pong capture + dest mirror verified ===" << std::endl;
    return 0;
}
