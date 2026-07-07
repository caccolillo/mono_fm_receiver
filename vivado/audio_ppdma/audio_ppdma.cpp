#include "audio_ppdma.h"

/**
 * Ping-pong audio capture + destination mirror ("acts as a DMA block with
 * minimal intervention").
 *
 * fm_demod's m_axis_data_0 (de-emphasis output, sfix32_En13, 50 kHz, NO
 * tready / NO tlast -- confirmed against de_emph.vhd) drives this core
 * directly. Because that producer never stalls for backpressure, this
 * core must always finish servicing one incoming sample well inside the
 * ~2000-cycle gap between samples (100 MHz / 50 kHz).
 *
 * Behaviour, once per invocation (one block-level ap_ctrl_hs execution
 * per incoming audio word -- see control-protocol note below):
 *   1. Accept one audio word and store it into whichever of
 *      ping_base/pong_base is currently "active" (being filled).
 *   2. After SAMPLES_PER_BUFFER (50, i.e. 1 ms) words have landed, the
 *      just-completed buffer is burst-copied to the fixed dest_base
 *      address before the active buffer flips. A consumer that always
 *      reads dest_base therefore only ever sees a complete, stable 1 ms
 *      block -- it never needs to know ping/pong exist.
 *   3. active_buf flips only after the copy finishes (atomic hand-off),
 *      and reports which buffer is now receiving new samples -- i.e. the
 *      OTHER one just finished and was mirrored into dest_base.
 *
 * Control protocol: this uses the DEFAULT ap_ctrl_hs block-level
 * handshake (ap_start/ap_done/ap_idle/ap_ready), not ap_ctrl_none.
 * Two earlier versions of this core used ap_ctrl_none to get a
 * "free-running" block, but Vitis HLS cosim rejects ap_ctrl_none designs
 * whose latency varies per invocation -- and this one legitimately does
 * (fast on 49 out of 50 calls, a ~100-beat burst on the 50th). Spreading
 * the copy into fixed per-invocation chunks avoided the variable-latency
 * problem but ran into a second one: HLS couldn't schedule the sample
 * write plus the mirror word's read+write onto one shared AXI port at
 * II=1 (Fmax dropped to ~68 MHz, cosim still failed). ap_ctrl_hs has no
 * such restriction -- variable latency and bursts are exactly what it's
 * designed for. In the block design, ap_start is tied permanently high
 * (via an xlconstant), so the block re-enters and restarts itself the
 * instant it goes idle, with no CPU/software involvement required --
 * the same "minimal intervention" outcome as ap_ctrl_none, just reached
 * through the control mechanism Vitis actually intends for this shape
 * of design. ap_done/ap_idle/ap_ready can be left unconnected, or wired
 * out to debug ILA probes if useful.
 *
 * Timing note (unchanged from the original version): the two 50-word
 * burst loops are pipelined II=1, so worst case is on the order of a few
 * hundred AXI beats -- comfortably inside the 2000-cycle inter-sample
 * budget on paper, but confirm with cosim/timing closure under real
 * DDR/PS arbitration before relying on it in silicon.
 *
 * Assumption flagged for review: ping/pong are treated as the two
 * capture (write) targets, and dest_base as the single fixed mirror
 * (read-out) address. If your intent was the reverse -- ping/pong
 * already hold valid data from elsewhere and this core only ever reads
 * one of them out to dest_base -- the control logic keeps the same
 * shape; only the fill_base/src_base wiring below needs to swap.
 *
 * Marco Aiello, 2024
 *
 * Reset scope note: Vitis HLS's DEFAULT reset scope only covers control
 * logic (the ap_ctrl_hs FSM, valid/enable signals) -- NOT data-path
 * static variables like cur_buf/widx below, unless explicitly told to.
 * Without the RESET pragmas on those two variables, their registers
 * start as X in simulation and can stay X indefinitely: cur_buf's
 * update is cur_buf = !cur_buf, and !X is X in 4-state logic, so an
 * unreset register never resolves no matter how many times it toggles.
 * On real silicon this isn't a bug (registers power up to a real,
 * if arbitrary, 0/1), but it left active_buf reading X throughout an
 * XSIM cosim run since nothing in the simulated design path ever forced
 * it to a known value. The #pragma HLS RESET lines below put these two
 * variables on the reset network so they deterministically start at
 * their C++ initializer value (0) on ap_rst_n, matching simulation to
 * the same "starts at ping" behaviour real hardware already has in
 * practice, and removing the permanent-X symptom instead of just an
 * initial transient.
 */
void audio_ppdma(sample_t &sample,
                  sample_t *mem,
                  addr_t ping_base,
                  addr_t pong_base,
                  addr_t dest_base,
                  ap_uint<1> &active_buf) {

    // NOTE: 'depth' is a cosim/simulation-only sizing hint for the m_axi
    // transactor model -- it has no effect on the synthesized hardware
    // (real addresses come from ping_base/pong_base/dest_base at
    // runtime, driven by GPIO). Cosim's DUMP_INPUTS phase snapshots
    // 'depth' words directly from the pointer BEFORE RTL sim starts, so
    // depth must be <= the actual size of the buffer the testbench
    // allocates -- NOT >=. Setting it larger than the real buffer (as an
    // earlier revision of this file did, at 1048576, then 256) makes
    // cosim read past the end of the array and segfault during
    // DUMP_INPUTS, before any simulation even runs. 150 matches this
    // testbench's exact ping+pong+dest footprint (3 * 50 words); update
    // this if you extend the testbench to exercise a larger buffer.
    #pragma HLS INTERFACE mode=axis    port=sample
    #pragma HLS INTERFACE mode=m_axi   port=mem offset=off bundle=gmem depth=150
    #pragma HLS INTERFACE mode=ap_none port=ping_base
    #pragma HLS INTERFACE mode=ap_none port=pong_base
    #pragma HLS INTERFACE mode=ap_none port=dest_base
    #pragma HLS INTERFACE mode=ap_none port=active_buf
    // No ap_ctrl_none here -- default ap_ctrl_hs, driven free-running by
    // tying ap_start high in the block design (see comment above).

    static ap_uint<1>  cur_buf = 0;   // 0 = ping, 1 = pong -- buffer being filled
    static ap_uint<16> widx    = 0;   // sample index within the current buffer
    #pragma HLS RESET variable=cur_buf
    #pragma HLS RESET variable=widx

    addr_t fill_base = (cur_buf == 0) ? ping_base : pong_base;
    mem[(fill_base >> 2) + widx] = sample;
    widx++;

    if (widx == SAMPLES_PER_BUFFER) {
        addr_t  src_base = fill_base;
        sample_t stage[SAMPLES_PER_BUFFER];

    read_loop:
        for (int i = 0; i < SAMPLES_PER_BUFFER; i++) {
            #pragma HLS PIPELINE II=1
            stage[i] = mem[(src_base >> 2) + i];
        }

    write_loop:
        for (int i = 0; i < SAMPLES_PER_BUFFER; i++) {
            #pragma HLS PIPELINE II=1
            mem[(dest_base >> 2) + i] = stage[i];
        }

        widx    = 0;
        cur_buf = !cur_buf;
    }

    active_buf = cur_buf;
}
