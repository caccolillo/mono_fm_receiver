#include "iq_ppdma.h"

/**
 * Ping-pong I/Q source feed ("acts as a DMA block with minimal
 * intervention") -- the mirror image of audio_ppdma, sitting in front of
 * fm_demod's s_axis_i_0/s_axis_q_0 inputs instead of behind
 * m_axis_data_0.
 *
 * Unlike audio_ppdma, there is no burst/mirror step here: this core does
 * exactly one thing per invocation -- read one packed 32-bit I/Q word
 * from whichever of ping_base/pong_base is currently active, unpack it,
 * and push both halves out on i_out/q_out. Every invocation does the
 * same, fixed amount of work.
 *
 * Control protocol: ap_ctrl_hs, with ap_start tied high in the block
 * design (see the INTERFACE pragma block below for the full reasoning).
 * An earlier version of this file assumed the fixed, branch-free work
 * here would be a clean fit for ap_ctrl_none + PIPELINE II=1 -- it
 * passed csim but cosim caught a pipelined address-generation hazard
 * that csim structurally cannot see, so it's been reverted to the same
 * ap_ctrl_hs approach already proven clean on audio_ppdma.
 *
 * Rate/timing note: fm_demod's I/Q inputs run at 250 kHz (not the 50 kHz
 * of the audio output side), so the per-sample budget here is ~400
 * cycles at 100 MHz -- tighter than audio_ppdma's ~2000, though still
 * generous for a single random-access read + two stream pushes.
 *
 * New consideration that didn't exist on the write side: fm_demod's
 * s_axis_i_0/s_axis_q_0 DO implement real tready, so this core's actual
 * throughput depends on fm_demod being ready to accept, not purely on
 * its own logic. It also matters that i_out and q_out land on the SAME
 * beat, since fm_demod almost certainly assumes synchronized I/Q
 * arrival -- confirm this in cosim rather than assuming HLS schedules
 * both mode=axis writes together by default.
 *
 * Assumption flagged for review: packed word layout is {I[31:16],
 * Q[15:0]}. If your DDR staging actually packs the other way round,
 * swap the two bit-slice lines below.
 *
 * Marco Aiello, 2024
 *
 * Reset scope note: Vitis HLS's DEFAULT reset scope only covers control
 * logic, not data-path static variables like cur_buf/ridx below, unless
 * explicitly told to. Without the RESET pragmas on those two variables,
 * cur_buf's register starts as X in simulation -- and since its update
 * is cur_buf = !cur_buf, and !X is X in 4-state logic, an unreset
 * register never resolves to a real 0/1 no matter how many times it
 * toggles, even while ap_done keeps pulsing normally. This showed up as
 * active_buf reading a permanent X on the GPIO waveform despite the
 * core visibly executing. Not a bug on real silicon (registers power up
 * to a real, if arbitrary, value there), but worth fixing in simulation
 * rather than treating it as an ignorable initial transient, since
 * without the reset it doesn't actually resolve on its own. The
 * #pragma HLS RESET lines below put cur_buf/ridx on the reset network
 * so they deterministically start at 0 on ap_rst_n.
 */
void iq_ppdma(packed_iq_t *mem,
              addr_t ping_base,
              addr_t pong_base,
              addr_t buf_size_words,
              iq_word_t &i_out,
              iq_word_t &q_out,
              ap_uint<1> &active_buf) {

    #pragma HLS INTERFACE mode=axis         port=i_out
    #pragma HLS INTERFACE mode=axis         port=q_out
    // NOTE: 'depth' is a cosim/simulation-only sizing hint for the m_axi
    // transactor model -- it has no effect on synthesized hardware. It
    // must be <= the actual size of the buffer the testbench allocates,
    // learned the hard way on audio_ppdma: too large causes cosim's
    // DUMP_INPUTS phase to read past the end of the array and segfault
    // before simulation even starts. Match this to iq_ppdma_tb.cpp's
    // real buffer footprint if you change the testbench's buf_size.
    #pragma HLS INTERFACE mode=m_axi        port=mem offset=off bundle=gmem depth=32
    #pragma HLS INTERFACE mode=ap_none      port=ping_base
    #pragma HLS INTERFACE mode=ap_none      port=pong_base
    #pragma HLS INTERFACE mode=ap_none      port=buf_size_words
    #pragma HLS INTERFACE mode=ap_none      port=active_buf
    // Default ap_ctrl_hs (NOT ap_ctrl_none), no PIPELINE pragma. An
    // earlier version of this file used ap_ctrl_none + PIPELINE II=1,
    // reasoning that the fixed, branch-free per-invocation work would be
    // a clean fit -- csim agreed, but cosim caught something csim
    // structurally cannot see: with true II=1 pipelining, the read
    // address for iteration N+1 depends on cur_buf/ridx state carried
    // from iteration N, combined with runtime ap_none scalar inputs
    // (ping_base/pong_base/buf_size_words) sampled fresh each iteration.
    // The generated RTL produced at least one bogus out-of-range read
    // address (33, when the true max valid index was 23) partway through
    // simulation -- a pipelined address-generation hazard that csim's
    // sequential, non-overlapped execution model can't reproduce or
    // catch. ap_ctrl_hs sidesteps it entirely: each invocation is a
    // discrete, non-overlapped start/done transaction, so there's no
    // pipeline overlap for cross-iteration state to race against. Tying
    // ap_start permanently high in the block design (matching
    // audio_ppdma's already cosim-verified approach) still gives
    // free-running operation with zero CPU intervention; it just costs
    // a small amount of throughput headroom this design doesn't need
    // (one AXI read + two stream pushes, comfortably inside the
    // ~400-cycle budget even without pipelining).

    static ap_uint<1>  cur_buf = 0;   // 0 = ping, 1 = pong -- buffer being read
    static ap_uint<32> ridx    = 0;   // sample index within the current buffer
    static ap_uint<1>  active_buf_reg = 0;  // shadow register -- see comment below
    #pragma HLS RESET variable=cur_buf
    #pragma HLS RESET variable=ridx
    #pragma HLS RESET variable=active_buf_reg

    // Output the STABLE value left over from the previous invocation
    // first, before touching cur_buf at all this invocation. This is
    // deliberately NOT the same as the simple "active_buf = cur_buf;"
    // at the end that this file originally used: confirmed by
    // inspecting the generated RTL, HLS bound that end-of-function
    // assignment to a mux gated to a single FSM state (ap_CS_fsm_state10
    // in the generated iq_ppdma.v), explicitly driving 'bx on every
    // other state of the execution -- i.e. the active_buf pin was only
    // ever valid during one narrow window per invocation, X the rest of
    // the time. audio_ppdma.cpp's equivalent mux happened NOT to do
    // this -- it fell back to a genuinely-registered hold value on its
    // other states, likely a scheduling outcome tied to its much longer
    // ~25-state FSM (from its burst-copy loop) -- but that was never
    // something the C++ as written actually guaranteed, so the same
    // shadow-register idiom has now been applied there too rather than
    // leaving it dependent on that scheduling outcome continuing to
    // hold.
    active_buf = active_buf_reg;

    addr_t src_base = (cur_buf == 0) ? ping_base : pong_base;
    packed_iq_t packed = mem[(src_base >> 2) + ridx];

    i_out = packed(31, 16);
    q_out = packed(15, 0);

    ridx++;
    if (ridx == buf_size_words) {
        ridx    = 0;
        cur_buf = !cur_buf;
    }

    active_buf_reg = cur_buf;
}
