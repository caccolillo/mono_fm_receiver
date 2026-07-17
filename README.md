# Mono FM Receiver — FPGA SoC on Zynq-7010

> End-to-end software-defined FM radio receiver: RTL-SDR I/Q capture → MATLAB/Simulink fixed-point model → Vitis HLS + hand-written VHDL → Zynq-7010 SoC → PCM WAV output. Hardware verified.

![Platform](https://img.shields.io/badge/Platform-Zynq--7010-red)
![Toolchain](https://img.shields.io/badge/Toolchain-Vivado%20%2F%20Vitis%20HLS%20%2F%20PetaLinux%202022.2-orange)
![Language](https://img.shields.io/badge/Language-VHDL%20%7C%20HLS%20C%2B%2B%20%7C%20SystemVerilog%20%7C%20C-blue)
![Status](https://img.shields.io/badge/Status-Hardware%20Verified-brightgreen)

---

## What It Does

Takes a 250 kHz I/Q baseband recording of an FM broadcast (`rds.wav`, captured with an RTL-SDR dongle) and produces a decoded 48 kHz mono WAV file, entirely in FPGA programmable logic running at 100 MHz on a Digilent Zybo Z7-10.

```
rds.wav  →  [FPGA signal chain @ 100 MHz]  →  audio_out.wav
(250 kHz I/Q)    NCO + FreqCorr                (48 kHz PCM)
                 AA LPF × 2 (129 tap FIR)
                 FM Discriminator (CORDIC atan2)
                 FIR Decimator R=5 → 50 kHz
                 Audio LPF (127 tap FIR)
                 De-emphasis IIR (75 µs)
                 Ping-pong DMA → DDR
```

The SDR was tuned +10 kHz above the station (88.110 vs 88.100 MHz) to avoid the RTL-SDR's DC spike. The FPGA corrects this digitally with a DDS NCO at the first processing stage.

---

## Signal Chain

| Stage | Implementation | Format in | Format out | Rate |
|---|---|---|---|---|
| NCO | Xilinx DDS Compiler v6.0 | — | `sfix16_En15` | 250 kHz |
| Freq Corrector | Hand-written VHDL | `sfix16_En15` | `sfix18_En17` | 250 kHz |
| Anti-alias LPF ×2 | Vitis HLS (129-tap FIR) | `sfix18_En17` | `sfix18_En17` | 250 kHz |
| FM Discriminator | Vitis HLS (16-iter CORDIC) | `sfix18_En17` | `sfix32_En14` | 250 kHz |
| FIR Decimator | Xilinx FIR Compiler, R=5 | `sfix32_En14` | `sfix32_En14` | 50 kHz |
| Audio LPF | Xilinx FIR Compiler (127-tap) | `sfix32_En14` | `sfix32_En14` | 50 kHz |
| De-emphasis | Hand-written VHDL (IIR) | `sfix32_En14` | `sfix32_En13` | 50 kHz |
| IQ ppdma | Vitis HLS (DDR → AXI-S) | DDR packed IQ | AXI-Stream | 250 kHz |
| Audio ppdma | Vitis HLS (AXI-S → DDR) | AXI-Stream | DDR | 50 kHz |

**Resource utilisation (xc7z010clg400-1):** ~27% LUT · ~18% FF · **~35% DSP48** · ~13% BRAM · WNS +0.432 ns @ 100 MHz

---

## Repository Structure

```
├── vivado/
│   ├── gen_coeffs_testvectors.m          # Master test vector orchestrator
│   ├── aa_lpf/                           # Anti-alias LPF (Vitis HLS)
│   │   ├── aa_lpf.h / aa_lpf.cpp        # ap_fixed<18,1>, 129 taps, AP_TRN/AP_SAT
│   │   ├── aa_lpf_tb.cpp                # C simulation testbench
│   │   └── gen_aa_lpf_coe.m             # Generates coefficients + test vectors
│   ├── fm_disc/                          # FM discriminator (Vitis HLS)
│   │   ├── fm_disc.h / fm_disc.cpp      # 16-iteration unrolled CORDIC atan2
│   │   └── gen_fm_disc_vectors.m        # Loads ic_qc_gold.mat → HLS stimulus
│   ├── audio_ppdma/                      # Audio ping-pong DMA (Vitis HLS)
│   ├── iq_ppdma/                         # I/Q ping-pong DMA (Vitis HLS)
│   ├── freq_corr/                        # Frequency corrector (VHDL)
│   │   └── freq_corr.vhd                # 4-stream all-valid gating, 2-cycle pipeline
│   ├── nco/                              # NCO wrapper (VHDL + DDS Compiler IP)
│   │   └── nco_wrapper.vhd              # Splits DDS {sin[31:16],cos[15:0]} tdata
│   ├── de_emphasis/                      # De-emphasis IIR (VHDL)
│   │   ├── de_emph.vhd                  # 2-stage pipeline, sfix40_En13 accumulator
│   │   └── de_emph_mcp.xdc             # Multicycle path constraint
│   ├── fir_decimation/                   # FIR decimator wrapper (VHDL)
│   ├── audio_lpf/                        # Audio LPF wrapper (VHDL)
│   ├── fm_demod_axis_with_sidechannels/
│   │   ├── iq_splitter.vhd              # 32-bit packed → two 16-bit AXI-S streams
│   │   ├── tlast_gen.vhd               # Inserts tlast every N valid samples
│   │   └── tb_fm_demod_axis_vip.sv     # AXI-Stream stall testbench (Level 2.5)
│   ├── fm_demod/                         # fm_demod composite IP + chain testbench
│   │   ├── bd.tcl                       # Inner block design (signal chain only)
│   │   ├── tb_fm_demod_chain.sv         # Level 3: full chain, file stimulus, PSNR
│   │   └── verify_fm_demod_rtl.m        # MATLAB PSNR gate: >40 dB = PASS
│   └── end_system/                       # Top-level SoC
│       ├── bd.tcl                        # Full block design (PS7 + DMAs + fm_demod)
│       ├── prj.tcl                       # Headless build → bitstream + XSA
│       ├── tb_sdr_fm_receiver_liveness.sv        # Level 4: DMA watchdog
│       └── tb_sdr_fm_receiver_audio_check.sv     # Level 4+: audio content + diagnosis
│
├── bare_metal/
│   ├── main.c                            # SD card WAV I/O, GPIO polling, cache fix
│   ├── resample_50k_to_48k.c            # Polyphase FIR resampler L=24, M=25
│   └── resample_coeffs.h                # 2208-tap Kaiser-windowed FIR
│
└── petalinux/
    ├── build_petalinux.sh               # Full automated PetaLinux build
    ├── reserved-memory.dtsi             # no-map DT overlay for ppdma DDR regions
    ├── create_sd.sh                     # SD card preparation script
    └── app/
        ├── fmdemod-linux.c              # Linux port: O_SYNC mmap, libgpiod, SCHED_FIFO
        └── resample_50k_to_48k.c        # POSIX port of resampler
```

---

## Design Methodology

This project follows the MathWorks Model-Based Design pipeline strictly:

```
MATLAB          Simulink           Fixed-Point        HLS / VHDL
floating-pt  →  fixed-pt model  →  Designer        →  implementation
  |                  |                  |                  |
"does the       "does the          "how many         "build it"
algorithm       system work?"      bits needed?"
work?"
```

**`run_and_extract.m`** is the entry point: loads `rds.wav`, quantises to `fixdt(1,16,15)`, feeds a Simulink fixed-point model of the complete demodulator chain, extracts intermediate node vectors (`ic_gold`, `qc_gold`), and saves them to `ic_qc_gold.mat`. These become the golden reference for all downstream RTL verification.

**`gen_coeffs_testvectors.m`** orchestrates six steps of test vector generation — steps 1–4 are independent of the Simulink model and enable RTL development to begin before the model is complete. Step 5 depends on `ic_qc_gold.mat`; step 6 reads `rds.wav` directly.

---

## Verification

Four-level hierarchy. Every level catches a class of bug the others cannot.

| Level | Test | Scope | What it catches |
|---|---|---|---|
| 1 | HLS `csim_design` | One block in C | Wrong `ap_fixed<>` types, algorithmic errors |
| 2 | HLS `cosim_design` | One block RTL vs C | Pragma hazards, missing RESET, `m_axi depth` |
| 2.5 | `tb_fm_demod_axis_vip.sv` | Full fm_demod IP | AXI-Stream stalls under pacing |
| 3 | `tb_fm_demod_chain.sv` + `verify_fm_demod_rtl.m` | Full signal chain | Boundary format errors (sign extension), latency |
| 4 | `tb_sdr_fm_receiver_liveness.sv` | Full SoC | DMA hang conditions |
| 4+ | `tb_sdr_fm_receiver_audio_check.sv` | Full SoC | Audio content, cache coherency diagnosis |

The Level 4+ testbench loads the same `s_axis_i_stimulus.txt` / `s_axis_q_stimulus.txt` vectors into IQ_PING/IQ_PONG via PS7 VIP HP0 `write_mem`, polls `audio active_buf`, reads back `AUDIO_DEST_ADDR`, and writes to `m_axis_data_dut_output.txt` in the same format as the Level 3 testbench — so `verify_fm_demod_rtl.m` can compare them directly. **Result: 250/250 non-zero audio words**, confirming the signal chain was correct and isolating the hardware bug to cache coherency.

---

## Key Engineering Decisions

<details>
<summary><strong>Why FIR decimator instead of CIC in the fixed-point model</strong></summary>

The MATLAB prototype uses a CIC decimator (no multipliers, fast to prototype). The Simulink model uses a FIR decimator because:
- CIC with R=5, N=3 has sinc³ passband droop: ~0.6 dB at 15 kHz — audible
- CIC adds `ceil(3 × log₂5) = 7` bits of word growth, creating an additional fixed-point boundary
- The Simulink HDL Optimized CIC block doesn't match a bare RTL CIC one-to-one, causing `verify_fm_demod_rtl.m` to be harder to interpret

</details>

<details>
<summary><strong>Why the AA LPF is lowpass (not bandpass)</strong></summary>

The frequency corrector (`freq_corr.vhd`) is the **first** stage — it removes the −10 kHz carrier offset before the AA LPF sees the signal. The AA LPF's job is to limit the I/Q bandwidth to ±100 kHz before the discriminator, suppressing adjacent channels and noise from the full ±125 kHz SDR capture window. The 100 kHz cutoff (not 75 kHz) provides a 25 kHz transition band that preserves outermost FM sidebands.

</details>

<details>
<summary><strong>Fixed-point word-length overrides (four cases)</strong></summary>

Fixed-Point Designer's auto-proposer was overridden in four places — the tool's empirical range collection gives wrong answers for signals with known analytical bounds:

| Signal | Auto-proposed | Correct | Reason |
|---|---|---|---|
| I/Q input | `sfix16_En4` | `sfix16_En15` | ADC range is (−1,+1), not ±2048 |
| Discriminator output | `sfix18_En15` | `sfix32_En14` | ×39788 gain needs 31+ bits |
| IIR accumulator | narrow | `sfix40_En13` | Limit cycle prevention; a1≈0.766 close to 1 |
| Product block default | Inherited (truncated 18-bit) | Explicit `sfix32` | Default drops half the 36-bit product |

</details>

<details>
<summary><strong>The sign-extension bug (caught at Level 3)</strong></summary>

`iq_splitter.vhd` initially used an `xlconstant` (constant zero) to zero-pad 18-bit `sfix18_En17` values to 24-bit AXI-Stream `tdata`. Zero-padding is correct for positive values but wrong for negative ones — it reinterprets a negative value as a large positive number. Level 3 simulation showed catastrophic corruption on the discriminator output. Fixed in `bd.tcl` using `xlslice` (extract sign bit 17) + `xlconcat` (replicate ×6) for proper two's-complement sign extension.

</details>

<details>
<summary><strong>The cache coherency bug (diagnosed by simulation)</strong></summary>

The hardware WAV was wrong but simulation showed 250/250 non-zero audio words. The difference: in simulation HP0 and GP0 share the same DDR model with no cache. On hardware, `audio_ppdma_0` writes via HP0 (non-coherent) while the CPU reads via the cached path.

The bug: `Xil_DCacheInvalidateRange(AUDIO_DEST_ADDR, N)` followed by `Xil_In32(AUDIO_DEST_ADDR + i*4)`. `Xil_In32` **bypasses the cache entirely** — the invalidate has no effect on reads that don't use the cache.

Fix: after `Xil_DCacheInvalidateRange`, read via `memcpy` through a normal pointer so the CPU's cached load path fetches fresh lines from DDR.

</details>

<details>
<summary><strong>ap_ctrl_none limitations in Vitis HLS cosim</strong></summary>

Both `audio_ppdma` and `iq_ppdma` were initially designed with `ap_ctrl_none`. HLS cosim rejected `audio_ppdma` because the burst-copy path (50 reads + 50 writes every 50th invocation) gives variable latency — cosim only supports `ap_ctrl_none` for constant-latency or II=1 pipelined designs.

`iq_ppdma` passed csim with `ap_ctrl_none + PIPELINE II=1` but cosim caught a pipelined address-generation hazard — cross-iteration state combined with runtime `ap_none` scalar config ports produced an out-of-range read address.

Fix for both: `ap_ctrl_hs` with `ap_start` tied permanently high via `xlconstant` in the block design.

All static state variables in both cores carry `#pragma HLS RESET` — without it, HLS only resets the control FSM, leaving data registers as X in simulation (`!X = X`, never resolves to valid 0/1).

</details>

<details>
<summary><strong>Block design naming — the design_1 collision</strong></summary>

An earlier version of the top-level block design used Vivado's default name `design_1`, which collided with the inner `fm_demod` composite IP's block design (also defaulting to `design_1`). Both generated `design_1_wrapper`. XSim elaborated without error but instantiated the inner wrapper instead of the outer, producing complete silence on all AXI buses — indistinguishable from an undriven reset until the elaboration log's "already exists in library work" warning was found. Fixed by renaming the top-level BD to `sdr_fm_receiver`.

</details>

---

## Building

### Prerequisites

- Vivado / Vitis HLS / PetaLinux 2022.2
- MATLAB R2022b with DSP System Toolbox and Fixed-Point Designer
- Digilent board files for Vivado

### Generate test vectors (MATLAB)

```matlab
run_and_extract.m        % Simulink simulation, saves ic_qc_gold.mat
gen_coeffs_testvectors.m % All HLS testbench vectors + .coe files
```

### Build HLS IPs

```bash
for d in aa_lpf fm_disc audio_ppdma iq_ppdma; do
    cd vivado/$d && bash build.sh && cd ../..
done
```

Each `build.sh` runs csim → csynth → cosim → export_design. Cosim must pass before proceeding.

### Build the SoC (headless)

```bash
cd vivado/end_system
stdbuf -oL -eL vivado -mode batch -source prj.tcl 2>&1 | tee build.log
```

Produces `sdr_fm_receiver.xsa` for Vitis / PetaLinux.

### Run Level 3 simulation

```bash
cd vivado/fm_demod && bash run_batch_sim.sh
# Then in MATLAB:
verify_fm_demod_rtl   % PSNR > 40 dB = PASS
```

### Bare-metal application

Build in Vitis using the XSA. Add `bare_metal/main.c`, `resample_50k_to_48k.c`, `resample_coeffs.h`. Enable `xilffs` and `xilcache` BSP libraries.

### PetaLinux image

```bash
cd petalinux
# Copy fmdemod-linux.c, resample_50k_to_48k.c, resample_coeffs.h into app/
bash build_petalinux.sh
sudo bash create_sd.sh /dev/sdX /path/to/rds.wav
```

### Boot checklist

1. Set Zybo Z7 JP5 to SD boot (pins 1–2)
2. Connect USB-UART: `minicom -D /dev/ttyUSB0 -b 115200`
3. Power on — Linux boots in ~30 s, login as root
4. Run `gpiodetect` and `gpioinfo` — verify `GPIOCHIP_NAME` and line offsets in `fmdemod-linux.c`
5. Copy `rds.wav` to the board: `scp rds.wav root@<ip>:/home/root/`
6. Run `fmdemod-linux`

---

## Notes on the Input Recording

`rds.wav` carries a full stereo/RDS MPX signal (verified by SDRuno RDS decode: station WAY-FM, PI 22301, PTY Top 40). This implementation demodulates the mono L+R sum only. The 19 kHz pilot tone detector, 38 kHz subcarrier regenerator, and L−R decoder required for stereo are left as a natural extension.

---

*Marco Aiello · Principal FPGA Design & Verification Engineer · Huntingdon, UK*
