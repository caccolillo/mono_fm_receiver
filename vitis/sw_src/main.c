/*
 * main.c - Bare-metal FM demodulator bring-up: SD card WAV I/O
 *
 * Reads an I/Q WAV file from the SD card, feeds it through the FM
 * demodulator's AXI DMA pipeline (MM2S = I/Q in, S2MM = audio out),
 * and writes the demodulated audio back to the SD card as a WAV file.
 *
 * This mirrors the register-level sequence already validated in
 * tb_sdr_fm_receiver.sv - same DMA arm/poll pattern, same FRAME_BYTES
 * chunking - just replacing the PS7 BFM calls with real xaxidma calls
 * and the hp0_write/hp0_read DDR pokes with real buffers + cache
 * maintenance.
 *
 * TODO before this compiles against your BSP:
 *   - Replace XPAR_AXIDMA_0_DEVICE_ID with the actual macro from
 *     xparameters.h for your AXI DMA instance.
 *   - Confirm xilffs is configured in the BSP with fs_interface = 1
 *     (SD card via XSdPs), and that xaxidma is included.
 *   - Confirm the WAV sample format below (16-bit interleaved I/Q)
 *     actually matches your rds.wav capture format - adjust the WAV
 *     header struct / assumptions if not.
 */

#include "xparameters.h"
#include "xaxidma.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "ff.h"
#include <string.h>

/* ------------------------------------------------------------------ */
/* Config - mirrors tb_sdr_fm_receiver.sv parameters                   */
/* ------------------------------------------------------------------ */
#define AXIDMA_DEVICE_ID   XPAR_AXIDMA_0_DEVICE_ID   /* TODO: confirm */
#define FRAME_SAMPLES      4095
#define FRAME_BYTES        16380U   /* FRAME_SAMPLES * 4 bytes/sample */
#define AUDIO_FRAME_BYTES  16380U   /* adjust if audio word width differs */

#define INPUT_WAV_PATH       "0:/rds.wav"
#define INTERMEDIATE_WAV_PATH "0:/audio_50k.wav"  /* native DMA output rate */
#define OUTPUT_WAV_PATH      "0:/audio_out.wav"    /* final 48kHz WAV */

/* implemented in resample_50k_to_48k.c */
int resample_wav_50k_to_48k(const char *in_path, const char *out_path);

/* Buffers must be cache-line aligned (Cortex-A9 = 32B) for safe
 * flush/invalidate on exact address ranges without touching neighbours. */
static u8 iq_buf[FRAME_BYTES]        __attribute__((aligned(64)));
static u8 audio_buf[AUDIO_FRAME_BYTES] __attribute__((aligned(64)));

static XAxiDma AxiDma;
static FATFS   fatfs;
static FIL     fin, fout;

/* ------------------------------------------------------------------ */
/* Minimal canonical 44-byte PCM WAV header                            */
/* ------------------------------------------------------------------ */
typedef struct __attribute__((packed)) {
    char  riff_id[4];      /* "RIFF" */
    u32   riff_size;       /* file size - 8, patched at the end */
    char  wave_id[4];      /* "WAVE" */
    char  fmt_id[4];       /* "fmt " */
    u32   fmt_size;        /* 16 for PCM */
    u16   audio_format;    /* 1 = PCM */
    u16   num_channels;
    u32   sample_rate;
    u32   byte_rate;
    u16   block_align;
    u16   bits_per_sample;
    char  data_id[4];      /* "data" */
    u32   data_size;       /* patched at the end */
} wav_header_t;

static int wav_write_placeholder_header(FIL *f, u32 sample_rate,
                                         u16 num_channels, u16 bits_per_sample)
{
    wav_header_t hdr;
    UINT written;

    memcpy(hdr.riff_id, "RIFF", 4);
    hdr.riff_size = 0; /* patched later */
    memcpy(hdr.wave_id, "WAVE", 4);
    memcpy(hdr.fmt_id, "fmt ", 4);
    hdr.fmt_size = 16;
    hdr.audio_format = 1;
    hdr.num_channels = num_channels;
    hdr.sample_rate = sample_rate;
    hdr.bits_per_sample = bits_per_sample;
    hdr.block_align = num_channels * (bits_per_sample / 8);
    hdr.byte_rate = sample_rate * hdr.block_align;
    memcpy(hdr.data_id, "data", 4);
    hdr.data_size = 0; /* patched later */

    return (f_write(f, &hdr, sizeof(hdr), &written) == FR_OK &&
            written == sizeof(hdr)) ? 0 : -1;
}

static int wav_patch_header(FIL *f, u32 data_bytes)
{
    UINT written;
    u32 riff_size = data_bytes + sizeof(wav_header_t) - 8;

    /* riff_size lives at byte offset 4, data_size at offset 40 */
    if (f_lseek(f, 4) != FR_OK) return -1;
    if (f_write(f, &riff_size, 4, &written) != FR_OK || written != 4) return -1;

    if (f_lseek(f, 40) != FR_OK) return -1;
    if (f_write(f, &data_bytes, 4, &written) != FR_OK || written != 4) return -1;

    return 0;
}

/* ------------------------------------------------------------------ */
/* DMA: arm MM2S + S2MM for one frame, poll both to completion         */
/* Same polling pattern as tb_sdr_fm_receiver.sv's mm2s_loop/s2mm_loop */
/* ------------------------------------------------------------------ */
#define POLL_MAX 100000

static int run_dma_frame(u32 iq_len, u32 audio_len)
{
    int status;
    int poll_cnt;

    /* CPU wrote iq_buf - push it out of cache before the PL reads it */
    Xil_DCacheFlushRange((INTPTR)iq_buf, iq_len);
    /* PL is about to write audio_buf - invalidate any stale cached
     * copy now so we don't accidentally keep old data after the read-back */
    Xil_DCacheInvalidateRange((INTPTR)audio_buf, audio_len);

    status = XAxiDma_SimpleTransfer(&AxiDma, (UINTPTR)audio_buf, audio_len,
                                     XAXIDMA_DEVICE_TO_DMA);
    if (status != XST_SUCCESS) {
        xil_printf("S2MM SimpleTransfer failed: %d\r\n", status);
        return -1;
    }

    status = XAxiDma_SimpleTransfer(&AxiDma, (UINTPTR)iq_buf, iq_len,
                                     XAXIDMA_DMA_TO_DEVICE);
    if (status != XST_SUCCESS) {
        xil_printf("MM2S SimpleTransfer failed: %d\r\n", status);
        return -1;
    }

    poll_cnt = 0;
    while (XAxiDma_Busy(&AxiDma, XAXIDMA_DMA_TO_DEVICE)) {
        if (++poll_cnt > POLL_MAX) {
            xil_printf("MM2S timed out\r\n");
            return -1;
        }
    }

    poll_cnt = 0;
    while (XAxiDma_Busy(&AxiDma, XAXIDMA_DEVICE_TO_DMA)) {
        if (++poll_cnt > POLL_MAX) {
            xil_printf("S2MM timed out\r\n");
            return -1;
        }
    }

    /* PL just wrote audio_buf via DMA - invalidate again so the CPU's
     * subsequent read doesn't see a stale cached copy */
    Xil_DCacheInvalidateRange((INTPTR)audio_buf, audio_len);

    return 0;
}

int main(void)
{
    FRESULT fres;
    UINT bytes_read, bytes_written;
    u32 total_audio_bytes = 0;
    XAxiDma_Config *dma_cfg;
    int status;

    Xil_DCacheEnable();
    Xil_ICacheEnable();

    xil_printf("=== FM Demod bare-metal bring-up (SD card WAV I/O) ===\r\n");

    /* --- AXI DMA init --- */
    dma_cfg = XAxiDma_LookupConfig(AXIDMA_DEVICE_ID);
    if (!dma_cfg) {
        xil_printf("No AXI DMA config found for device ID %d\r\n", AXIDMA_DEVICE_ID);
        return -1;
    }
    status = XAxiDma_CfgInitialize(&AxiDma, dma_cfg);
    if (status != XST_SUCCESS) {
        xil_printf("AXI DMA CfgInitialize failed: %d\r\n", status);
        return -1;
    }
    /* Simple DMA mode only - matches this design, no scatter-gather */
    XAxiDma_IntrDisable(&AxiDma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrDisable(&AxiDma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);

    /* --- SD card mount --- */
    fres = f_mount(&fatfs, "0:/", 1);
    if (fres != FR_OK) {
        xil_printf("f_mount failed: %d\r\n", fres);
        return -1;
    }

    /* --- Open input WAV, skip its 44-byte header --- */
    fres = f_open(&fin, INPUT_WAV_PATH, FA_READ);
    if (fres != FR_OK) {
        xil_printf("Failed to open %s: %d\r\n", INPUT_WAV_PATH, fres);
        return -1;
    }
    if (f_lseek(&fin, sizeof(wav_header_t)) != FR_OK) {
        xil_printf("Failed to skip input WAV header\r\n");
        return -1;
    }

    /* --- Open output WAV, write placeholder header ---
     * TODO: sample_rate/bits_per_sample here should match your actual
     * audio output format from the FM demod chain (the memory notes
     * mention 50 kHz audio output rate for this design - adjust). */
    fres = f_open(&fout, INTERMEDIATE_WAV_PATH, FA_WRITE | FA_CREATE_ALWAYS);
    if (fres != FR_OK) {
        xil_printf("Failed to open %s: %d\r\n", INTERMEDIATE_WAV_PATH, fres);
        return -1;
    }
    if (wav_write_placeholder_header(&fout, 50000, 1, 16) != 0) {
        xil_printf("Failed to write output WAV header\r\n");
        return -1;
    }

    /* --- Main frame loop --- */
    for (;;) {
        fres = f_read(&fin, iq_buf, FRAME_BYTES, &bytes_read);
        if (fres != FR_OK) {
            xil_printf("f_read failed: %d\r\n", fres);
            break;
        }
        if (bytes_read == 0) {
            break; /* EOF */
        }
        if (bytes_read < FRAME_BYTES) {
            /* zero-pad the final short frame */
            memset(iq_buf + bytes_read, 0, FRAME_BYTES - bytes_read);
        }

        if (run_dma_frame(FRAME_BYTES, AUDIO_FRAME_BYTES) != 0) {
            xil_printf("DMA frame failed, aborting\r\n");
            break;
        }

        fres = f_write(&fout, audio_buf, AUDIO_FRAME_BYTES, &bytes_written);
        if (fres != FR_OK || bytes_written != AUDIO_FRAME_BYTES) {
            xil_printf("f_write failed: %d\r\n", fres);
            break;
        }
        total_audio_bytes += bytes_written;

        if (bytes_read < FRAME_BYTES) {
            break; /* that was the last (short) frame */
        }
    }

    /* --- Patch the output WAV header with real sizes --- */
    if (wav_patch_header(&fout, total_audio_bytes) != 0) {
        xil_printf("Warning: failed to patch output WAV header\r\n");
    }

    f_close(&fin);
    f_close(&fout);

    xil_printf("Native-rate pass done: %lu bytes at 50kHz written to %s\r\n",
               (unsigned long)total_audio_bytes, INTERMEDIATE_WAV_PATH);

    /* Second pass: resample the intermediate 50kHz audio down to the
     * standard 48kHz rate. This is the C port of the same 24/25
     * Kaiser-windowed resample() step the MATLAB golden model did
     * post-simulation - here it runs on-target instead. */
    if (resample_wav_50k_to_48k(INTERMEDIATE_WAV_PATH, OUTPUT_WAV_PATH) != 0) {
        xil_printf("Resample pass failed\r\n");
        f_mount(NULL, "0:/", 1);
        return -1;
    }

    f_mount(NULL, "0:/", 1);

    xil_printf("Done. Final 48kHz audio written to %s\r\n", OUTPUT_WAV_PATH);

    return 0;
}
