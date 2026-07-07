#ifndef IQ_PPDMA_H_
#define IQ_PPDMA_H_

#include <ap_int.h>

// One 32-bit memory word holds one packed I/Q pair: I in the upper 16
// bits, Q in the lower 16 bits. Matches fm_demod's s_axis_i_0/s_axis_q_0
// input format (sfix16_En15 each) -- this core moves the bit patterns
// verbatim, it never interprets the fixed-point value. Flag for review:
// if your DDR staging layout actually packs {Q,I} instead of {I,Q}, only
// the two bit-slice lines in iq_ppdma.cpp need to swap.
typedef ap_uint<32> packed_iq_t;
typedef ap_uint<16> iq_word_t;
typedef ap_uint<32> addr_t;

// Top-level function prototype: ping-pong I/Q source feed, acting as a
// minimal-intervention "DMA" sitting right in front of fm_demod's
// s_axis_i_0/s_axis_q_0 inputs.
//
//   mem            : single shared AXI4 master to DDR (bundle=gmem,
//                    offset=off). ping_base/pong_base index into it
//                    directly as absolute byte addresses.
//   ping_base,
//   pong_base      : 32-bit absolute DDR byte addresses of the two
//                    source buffers (must be 4-byte aligned). Software
//                    fills whichever buffer active_buf says is NOT
//                    currently being read, then leaves it alone.
//   buf_size_words : number of packed I/Q words (= number of samples)
//                    per buffer. Runtime-configurable rather than a
//                    fixed 1 ms constant, so this can be resized for
//                    different playback/staging strategies without
//                    resynthesizing. Must never be programmed to 0.
//   i_out, q_out   : one unpacked 16-bit word each per invocation,
//                    mode=axis (tdata+tvalid+tready, no tlast/tkeep) --
//                    connect directly to fm_demod's s_axis_i_0 and
//                    s_axis_q_0. Those inputs DO implement tready (unlike
//                    the audio-output side), so this core's throughput
//                    partly depends on fm_demod actually being ready;
//                    worth confirming in cosim that both words really
//                    arrive on the same beat, since fm_demod likely
//                    assumes synchronized I/Q arrival.
//   active_buf     : 0 = ping is currently being read (pong is safe to
//                    refill); 1 = pong is currently being read (ping is
//                    safe to refill). Wire to an AXI GPIO input channel.
//
// Control protocol: ap_ctrl_hs (default), NOT ap_ctrl_none -- tie
// ap_start permanently high in the block design (e.g. via an
// xlconstant), same pattern already proven clean on audio_ppdma. An
// earlier revision of this header predicted ap_ctrl_none + PIPELINE
// II=1 would be a clean fit since there's no burst/variable-latency
// step; csim agreed, but cosim caught a pipelined address-generation
// hazard (cross-iteration state + runtime ap_none config ports don't
// mix safely with true II=1 pipelining here) that csim can't see.
void iq_ppdma(packed_iq_t *mem,
              addr_t ping_base,
              addr_t pong_base,
              addr_t buf_size_words,
              iq_word_t &i_out,
              iq_word_t &q_out,
              ap_uint<1> &active_buf);

#endif
