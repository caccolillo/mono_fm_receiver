#include <iostream>
#include <vector>
#include "iq_ppdma.h"

/**
 * Self-checking testbench for the ping-pong I/Q source feed.
 *
 * Control-logic test, not a DSP-accuracy test -- checks that:
 *   1. Words are unpacked correctly (I = upper 16 bits, Q = lower 16).
 *   2. Ping/pong is read in the right order and switches exactly at
 *      buf_size_words boundaries.
 *   3. active_buf always reports the buffer currently being read.
 *
 * Synthetic stimulus: ping is pre-loaded with I=2000+n, Q=3000+n for
 * n=0..buf_size-1; pong is pre-loaded with the same pattern offset by
 * buf_size, so expected values are trivially predictable without an
 * external golden file. Unlike audio_ppdma's testbench, ping/pong here
 * are pre-filled once up front (mimicking software having already
 * staged both buffers before enabling this core) rather than being
 * written by the core itself, since this core only reads.
 */
int main() {
    std::cout << "======================================================" << std::endl;
    std::cout << "=== I/Q Ping-Pong Feeder Self-Checking Test         ===" << std::endl;
    std::cout << "======================================================" << std::endl;

    const addr_t  PING_BASE      = 0x00000000;
    const addr_t  PONG_BASE      = 0x00000040;   // 16 words above ping
    const addr_t  BUF_SIZE_WORDS = 8;
    const int     BUF_SIZE_I     = 8;             // plain-int mirror for host-side arithmetic below
    const int     N_TEST_SAMPLES = 40;           // 5 full buffer switches

    const size_t MEM_WORDS = 32;  // covers ping [0:7] and pong [16:23] with margin
    std::vector<packed_iq_t> mem(MEM_WORDS, 0);

    auto make_word = [](int n) -> packed_iq_t {
        iq_word_t I = (iq_word_t)((2000 + n) & 0xFFFF);
        iq_word_t Q = (iq_word_t)((3000 + n) & 0xFFFF);
        return (packed_iq_t(I) << 16) | packed_iq_t(Q);
    };

    for (unsigned i = 0; i < BUF_SIZE_I; i++) {
        mem[(PING_BASE >> 2) + i] = make_word(i);
        mem[(PONG_BASE >> 2) + i] = make_word(BUF_SIZE_I + i);
    }

    iq_word_t  i_out = 0, q_out = 0;
    ap_uint<1> active_buf = 0;
    int failure_count = 0;

    std::cout << "n\tbuf\tridx\tI\tQ\texpected I\texpected Q\tresult" << std::endl;
    std::cout << "----------------------------------------------------------------------" << std::endl;

    for (int n = 0; n < N_TEST_SAMPLES; n++) {
        iq_ppdma(mem.data(), PING_BASE, PONG_BASE, BUF_SIZE_WORDS, i_out, q_out, active_buf);

        int buf_idx  = n / BUF_SIZE_I;                   // which buffer THIS sample was read from
        bool is_pong = (buf_idx % 2) == 1;
        int ridx     = n % BUF_SIZE_I;
        int expected_n = is_pong ? (BUF_SIZE_I + ridx) : ridx;

        // active_buf now reads a shadow register updated at the END of
        // the PREVIOUS invocation (see iq_ppdma.cpp's active_buf_reg),
        // so it reflects which buffer THIS sample itself came from --
        // no shift needed. This replaces an earlier version of this
        // check that shifted the expectation by one tick to compensate
        // for the old (pre-shadow-register) timing, where active_buf
        // reflected the state AFTER that invocation's own toggle
        // instead of the state going into it.
        iq_word_t expected_I = (iq_word_t)((2000 + expected_n) & 0xFFFF);
        iq_word_t expected_Q = (iq_word_t)((3000 + expected_n) & 0xFFFF);

        bool data_ok   = (i_out == expected_I) && (q_out == expected_Q);
        bool active_ok = (active_buf == (ap_uint<1>)(is_pong ? 1 : 0));
        bool ok = data_ok && active_ok;

        std::cout << n << "\t" << (is_pong ? "pong" : "ping") << "\t" << ridx << "\t"
                  << i_out << "\t" << q_out << "\t" << expected_I << "\t\t" << expected_Q
                  << "\t\t" << (ok ? "PASS" : "FAIL") << std::endl;

        if (!ok) failure_count++;
    }

    std::cout << "----------------------------------------------------------------------" << std::endl;
    std::cout << "Verification Summary: " << (N_TEST_SAMPLES - failure_count)
              << "/" << N_TEST_SAMPLES << " samples passed." << std::endl;

    if (failure_count > 0) {
        std::cout << "=== TEST BENCH FAILED: " << failure_count << " sample(s) mismatched ===" << std::endl;
        return 1;
    }

    std::cout << "=== TEST BENCH PASSED: ping-pong I/Q unpack + sequencing verified ===" << std::endl;
    return 0;
}
