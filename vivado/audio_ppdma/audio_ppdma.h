#ifndef AUDIO_PPDMA_H_
#define AUDIO_PPDMA_H_

#include <ap_int.h>

// Audio sample rate out of fm_demod's m_axis_data_0 (de-emphasis output),
// per tb_fm_demod_chain.sv / verify_fm_demod_rtl.m: 50 kHz, sfix32_En13.
#define AUDIO_SAMPLE_RATE_HZ 50000
#define BUFFER_MS            1
#define SAMPLES_PER_BUFFER   ((AUDIO_SAMPLE_RATE_HZ * BUFFER_MS) / 1000)  // 50
#define SAMPLE_BYTES         4
#define BUFFER_BYTES         (SAMPLES_PER_BUFFER * SAMPLE_BYTES)          // 200

// Raw 32-bit audio word. The core moves the sfix32_En13 bit pattern
// verbatim -- it never interprets the fixed-point value, only relocates
// it, so a plain ap_uint is enough (no ap_fixed needed here).
typedef ap_uint<32> sample_t;
typedef ap_uint<32> addr_t;

// Top-level function prototype: ping-pong capture + destination mirror,
// acting as a minimal-intervention "DMA" sitting right after fm_demod.
//
//   sample     : one incoming audio word per invocation. mode=axis,
//                tdata+tvalid+tready only -- no tlast/tkeep -- matching
//                fm_demod's m_axis_data_0 exactly (see de_emph.vhd).
//                Connect this directly to m_axis_data_0 in the BD; the
//                tready this port generates will simply be left
//                unconnected upstream, since de_emph_0 doesn't drive one.
//   mem        : single shared AXI4 master to DDR (bundle=gmem,
//                offset=off -- see .cpp). ping_base/pong_base/dest_base
//                are absolute byte addresses indexed into it directly;
//                there is no HLS-managed offset register.
//   ping_base,
//   pong_base,
//   dest_base  : 32-bit absolute DDR byte addresses (must be 4-byte
//                aligned). Drive these from AXI GPIO output channels
//                (ap_none -- deliberately NOT axilite), per your request
//                to wire configuration through GPIOs rather than a
//                register map.
//   active_buf : 0 = ping is currently being filled with new samples
//                (pong is stable, already mirrored to dest_base);
//                1 = pong is being filled (ping is stable). Wire this to
//                an AXI GPIO input channel for the CPU to poll.
//
// Control protocol: default ap_ctrl_hs (ap_start/ap_done/ap_idle/
// ap_ready), NOT ap_ctrl_none. Tie ap_start permanently high in the
// block design (e.g. via an xlconstant) so the block restarts itself
// the instant it goes idle -- free-running with zero CPU intervention,
// without hitting Vitis HLS cosim's ap_ctrl_none latency restrictions.
void audio_ppdma(sample_t &sample,
                  sample_t *mem,
                  addr_t ping_base,
                  addr_t pong_base,
                  addr_t dest_base,
                  ap_uint<1> &active_buf);

#endif
