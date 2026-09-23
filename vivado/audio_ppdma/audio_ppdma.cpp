#include "audio_ppdma.h"

/**
 * Ping-pong audio capture + destination mirror ("acts as a DMA block with
 * minimal intervention").
 *
 * ---------------------------------------------------------------------
 * FIX: mirror copy spread across invocations, not bursted on sample 50
 * ---------------------------------------------------------------------
 * fm_demod's m_axis_data_0 (de-emphasis output) has NO m_axis tready
 * port at all -- confirmed directly against de_emph.vhd's entity
 * declaration, not just inferred from a comment. de_emph is a fully
 * transparent, always-ready pass-through (its own s_axis_data_tready is
 * tied to '1' permanently too): whatever rate samples arrive at its
 * input is the rate they leave at, with no ability to ever be told to
 * wait.
 *
 * The ORIGINAL version of this file did the entire 50-word mirror copy
 * (read_loop + write_loop, "a few hundred AXI beats" by its own
 * comment) as part of the SAME ap_ctrl_hs invocation that detected the
 * 50th sample -- meaning that invocation's ap_done, and therefore this
 * block's ability to accept a new incoming sample, was delayed by the
 * full burst. During that window the block is genuinely busy (ap_idle
 * low) and cannot latch a new AXI-S sample -- and because de_emph never
 * waits for tready, any sample that arrives during that window is not
 * queued or stalled, it is simply never captured. Silently gone.
 *
 * This was flagged as a real risk in the original comments
 * ("comfortably inside the 2000-cycle inter-sample budget ON PAPER,
 * but confirm with cosim/timing closure under real DDR/PS arbitration
 * before relying on it in silicon") but never actually verified.
 * Measured behaviour (both in RTL simulation with ap_start tied high,
 * the original unmodified state, and independently on hardware) shows
 * a consistent ~26% shortfall in audio output relative to the number
 * of samples that should have arrived -- exactly consistent with this
 * mechanism, and NOT explained by clock frequency (confirmed exactly
 * 100 MHz from the implemented design's timing report) or by anything
 * upstream failing to deliver samples (I/Q throughput itself was not
 * the shortfall in the relevant tests).
 *
 * THE FIX: never let any single invocation's AXI work grow beyond a
 * small, constant size. Spread the 50-word mirror copy to exactly ONE
 * word per invocation, over the 50 invocations that naturally occur
 * before the next buffer fills (one incoming sample per invocation, by
 * construction). Every invocation now does at most:
 *   - one sample write (always)
 *   - one mirror-word read + one mirror-word write (only while a
 *     mirror is in progress)
 * -- a handful of AXI beats, not a variable-length burst. This removes
 * the mechanism for silent sample loss regardless of exactly how fast
 * upstream is actually delivering samples (which, separately, is also
 * not reliably paced to the nominal 250 kHz/50 kHz design rate -- see
 * the note in iq_ppdma.cpp -- but this fix does not depend on that
 * being resolved; it makes audio_ppdma robust either way).
 *
 * TIMING GUARANTEE PRESERVED: the original contract was "a change in
 * active_buf means dest_base is fully, stably mirrored." Simply
 * spreading the copy would break that -- cur_buf (which buffer NEW
 * samples land in) must flip immediately when a buffer fills, but the
 * EXTERNALLY VISIBLE active_buf must not change until ITS mirror copy
 * has actually finished, or a consumer could read dest_base mid-copy
 * (some old words, some new). This is handled by keeping cur_buf
 * (internal, flips immediately) separate from active_buf_reg (external,
 * flips only once mirror_idx reaches SAMPLES_PER_BUFFER) -- an
 * extension of the shadow-register idiom already used in this file to
 * avoid the earlier active_buf-reads-as-X problem.
 *
 * NOT YET VERIFIED IN COSIM OR ON HARDWARE. This has been reasoned
 * through carefully and the state-machine logic checked by hand, but
 * there is no Vivado/Vitis HLS access available here to actually run
 * csim/cosim. Before trusting this on hardware: re-run csim against
 * audio_ppdma_tb.cpp (the timing assumptions of that testbench may
 * need adjusting, since behaviour is now spread across more cycles
 * total per buffer, even though each individual invocation is faster),
 * then cosim, then re-check with the same rate_monitor-style
 * measurement used to find this problem in the first place (compare
 * audio_ppdma toggle count against iq_ppdma toggle count -- expect the
 * ratio to move meaningfully closer to 10:1 than the previously
 * measured 7.4:1, though a chain that still isn't paced to nominal
 * rate upstream may not hit exactly 10:1 either).
 *
 * Marco Aiello, 2024/2026
 *
 * Reset scope note: unchanged from the original -- Vitis HLS's DEFAULT
 * reset scope only covers control logic, not data-path static
 * variables, unless explicitly told to. All static state below that
 * needs a real, deterministic reset value carries the #pragma HLS
 * RESET line for exactly the reason documented in the original file
 * (unreset X states that never resolve, since e.g. cur_buf = !cur_buf
 * applied to X is still X in 4-state logic).
 */
void audio_ppdma(sample_t &sample,
                  sample_t *mem,
                  addr_t ping_base,
                  addr_t pong_base,
                  addr_t dest_base,
                  ap_uint<1> &active_buf) {

    // NOTE: 'depth' is a cosim/simulation-only sizing hint for the m_axi
    // transactor model -- it has no effect on synthesized hardware.
    // Matches audio_ppdma_tb.cpp's ping+pong+dest footprint (3 * 50
    // words) as in the original file -- update if the testbench's
    // buffer layout changes.
    #pragma HLS INTERFACE mode=axis    port=sample
    #pragma HLS INTERFACE mode=m_axi   port=mem offset=off bundle=gmem depth=150
    #pragma HLS INTERFACE mode=ap_none port=ping_base
    #pragma HLS INTERFACE mode=ap_none port=pong_base
    #pragma HLS INTERFACE mode=ap_none port=dest_base
    #pragma HLS INTERFACE mode=ap_none port=active_buf
    // No ap_ctrl_none here -- default ap_ctrl_hs, driven free-running by
    // tying ap_start high in the block design, unchanged from the
    // original file's approach (that part was not the problem).

    static ap_uint<1>  cur_buf        = 0;  // which buffer NEW samples land in -- flips immediately on buffer-full
    static ap_uint<16> widx           = 0;  // sample index within the buffer currently being filled
    static ap_uint<1>  active_buf_reg = 0;  // EXTERNALLY VISIBLE: which buffer is stable+fully mirrored
    static bool        mirror_pending = false; // background mirror copy in progress
    static addr_t      mirror_src     = 0;     // which buffer is being copied to dest_base right now
    static ap_uint<16> mirror_idx     = 0;     // words of the current mirror copied so far

    #pragma HLS RESET variable=cur_buf
    #pragma HLS RESET variable=widx
    #pragma HLS RESET variable=active_buf_reg
    #pragma HLS RESET variable=mirror_pending
    #pragma HLS RESET variable=mirror_src
    #pragma HLS RESET variable=mirror_idx

    // ---- 1. Accept the incoming sample. Always exactly one AXI write,
    // regardless of anything else happening this invocation. This is
    // the part that must never be delayed by mirror-copy work, and now
    // isn't. ----
    addr_t fill_base = (cur_buf == 0) ? ping_base : pong_base;
    mem[(fill_base >> 2) + widx] = sample;
    widx++;

    if (widx == SAMPLES_PER_BUFFER) {
        // Buffer just filled. Flip which buffer takes the NEXT sample
        // immediately -- this must not wait for mirroring, or the very
        // next incoming sample would have nowhere correct to go.
        // active_buf_reg (the externally visible one) is deliberately
        // NOT updated here -- see the header comment.
        mirror_src     = fill_base;
        mirror_pending = true;
        mirror_idx     = 0;
        widx           = 0;
        cur_buf         = (ap_uint<1>)(!cur_buf);
    }

    // ---- 2. Spread the mirror copy: at most ONE word this invocation.
    // Combined with step 1, worst case per invocation is now one
    // sample write + one mirror read + one mirror write -- a small,
    // constant amount of AXI traffic, never the multi-hundred-beat
    // burst the original version could produce on the 50th sample. ----
    if (mirror_pending) {
        sample_t word = mem[(mirror_src >> 2) + mirror_idx];
        mem[(dest_base >> 2) + mirror_idx] = word;
        mirror_idx++;

        if (mirror_idx == SAMPLES_PER_BUFFER) {
            mirror_pending = false;
            active_buf_reg = cur_buf;
        }
    }

    // ---- 3. Report the CURRENT, fully up-to-date state, at the end
    // of the function, not a deliberately stale one from the start.
    //
    // BUG FOUND AND FIXED HERE: an earlier version of this file read
    // active_buf_reg at the TOP of the function (before any of this
    // invocation's own writes), intending that as a "report last
    // invocation's committed value" shadow-register pattern. That adds
    // an extra one-invocation reporting delay on top of the mirror's
    // own completion -- and that delay lands on EXACTLY the invocation
    // where the NEXT block's own mirror starts overwriting dest_base
    // (not by chance: the spread mirror always finishes one invocation
    // before the block boundary, by construction, and the stale-read
    // pattern always reports one invocation late -- those two
    // off-by-ones cancel out and collide on the same invocation every
    // single time). The result: there was no caller-visible moment
    // where active_buf correctly reported "block N ready" AND
    // dest_base still genuinely held block N's data -- verified by
    // running the corresponding testbench in plain C++ against stub
    // HLS types, which reproduced the failure directly (dest mirror
    // FAIL on every block, despite the active_buf timing itself being
    // correct).
    //
    // The original shadow-register idiom (elsewhere in this project,
    // e.g. iq_ppdma.cpp) exists to avoid a genuinely different problem
    // -- a signal that HLS's generated FSM only drives during one
    // narrow state, reading as X outside it in cosim. active_buf_reg
    // here does not have that problem: it is a plain static variable,
    // properly reset (#pragma HLS RESET above), assigned exactly once
    // per relevant invocation. Reporting its current value directly
    // needs no extra shadow delay.
    active_buf = active_buf_reg;
}
