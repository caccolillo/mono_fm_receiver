% run_fm_demod_slx.m
%
% Runs fm_demod_fixed.slx — Simulink FM mono demodulator.
% Loads IQ data, populates workspace variables, runs sim, plays audio.
%
% Target device: Xilinx Zynq xc7z010clg400-1 (Zybo Z7-10)
%
% PREREQUISITES — changes that must be made manually in the model before
% running this script or the HDL Workflow Advisor:
%
%   1. Delete 'Buf' block from FM_DEMOD.
%   2. Delete 'Data Type Conversion' (first DTC, between Buf and FIR Dec1).
%   3. Wire FM_Disc output directly to FIR Decimation1 input.
%   4. FIR Decimation1 block mask:
%        InputProcessing = Elements as channels (sample based)
%        framing         = Allow multirate processing
%   5. AudioLPF block mask:
%        InputProcessing = Elements as channels (sample based)
%   6. Replace DeEmph (DiscreteFilter — not supported by HDL Coder) with
%      a Direct Form I IIR built from primitives:
%        y[n] = b0*x[n] + a1*y[n-1]
%        b0 = 0.234071661635351,  a1 = 0.765928338364649
%        Blocks: Gain(b0) -> Sum(++) <- Gain(a1) <- Unit Delay <- Sum output
%      All fixed-point types as per original DeEmph block (fixdt(1,32,13)).
%
% Signal chain after fixes:
%   From Workspace (I, Q, cos, sin at 250 kHz)
%     -> FreqCorr subsystem (complex multiply)
%     -> AA_I / AA_Q (Discrete FIR Filter, 128-tap anti-alias LPF)
%     -> FM_Disc subsystem (CORDIC atan2 differential phase)
%     -> FIR Decimation1 (fir1(40,1/5), D=5, 250kHz->50kHz, sample-based)
%     -> Data Type Conversion1 (fixdt(1,32,14), SampleTime=2e-5)
%     -> AudioLPF (Discrete FIR Filter, 128-tap 15 kHz LPF, sample-based)
%     -> DeEmph IIR primitive (Gain + UnitDelay + Sum, sample-based)
%     -> To Workspace -> audio_50k  (SampleTime = 2e-5, 50 kHz)
%
% Post-sim: detect actual output rate, correct if needed,
%           resample to 48 kHz, normalise, sound() + audiowrite()

clear; clc;
mdl = 'fm_demod_fixed';

%% ── PARAMETERS ───────────────────────────────────────────────────────────
WAV_FILE       = 'rds.wav';
CARRIER_OFFSET = -10e3;     % Hz  station at -10 kHz from LO
FS_IQ          = 250e3;     % Hz  IQ sample rate
FS_OUT_NOM     = 50e3;      % Hz  intended post-decimation rate (250k/5)
FS_AUDIO       = 48e3;      % Hz  final audio rate
MAX_SECONDS    = 30;
FIR_DEC_COEFFS = fir1(40, 1/5);   % must match FIR Decimation1 block coefficients
SAVE_WAV       = true;
PLAY_AUDIO     = true;
%% ────────────────────────────────────────────────────────────────────────

%% 1.  Load model and apply settings ──────────────────────────────────────
if bdIsLoaded(mdl)
    close_system(mdl, 0);
elseif ~exist([mdl '.slx'], 'file')
    error('Model %s not found. Add fm_demod_fixed.slx to the MATLAB path.', mdl);
end
load_system(mdl);
fprintf('Loaded: %s.slx (clean state)\n', mdl);

fprintf('=== Applying model and HDL Coder settings (Z7-10) ===\n');

% ── Solver and tasking ────────────────────────────────────────────────────
set_param(mdl, 'SolverType',             'Fixed-step');
set_param(mdl, 'Solver',                 'FixedStepDiscrete');
set_param(mdl, 'FixedStep',              num2str(1/FS_IQ));
set_param(mdl, 'MultiTaskRateTransMsg',  'error');
set_param(mdl, 'SingleTaskRateTransMsg', 'error');
fprintf('  Solver: fixed-step discrete @ %.0f kHz, multirate error checks on.\n', ...
        FS_IQ/1e3);

% ── HDL Coder target ──────────────────────────────────────────────────────
hdlset_param(mdl, 'SynthesisTool',            'Xilinx Vivado');
hdlset_param(mdl, 'SynthesisToolChipFamily',  'Zynq');
hdlset_param(mdl, 'SynthesisToolDeviceName',  'xc7z010clg400-1');
hdlset_param(mdl, 'SynthesisToolPackageName', 'clg400');
hdlset_param(mdl, 'SynthesisToolSpeedValue',  '-1');
hdlset_param(mdl, 'TargetFrequency',          125);
hdlset_param(mdl, 'HDLSubsystem', [mdl '/FM_DEMOD']);
fprintf('  Device : xc7z010clg400-1  125 MHz\n');
fprintf('  DUT    : %s/FM_DEMOD\n', mdl);

% ── SerialPartition for FIR blocks ───────────────────────────────────────
% SerialPartition is an HDL Coder block property (hdlset_param only) —
% it does not affect simulation.
%
% AA_I / AA_Q: effective length 105 (129 taps, 24 zeros).
%   Folding factor 7, 15 multipliers: ones(1,15)*7
%
% AudioLPF: effective length 99 (129 taps, 30 zeros — differs from AA
%   because CoefDataTypeStr was changed to fixdt(1,32,14) which causes
%   HDL Coder to recount zeros at the new precision).
%   Folding factor 7, 15 multipliers: [ones(1,14)*7, 1]
%
% Total DSP48E1s: 15+15+15 = 45, within Z7-10 budget of 80.
SP_AA    = ones(1,15)*7;
SP_AUDIO = [ones(1,14)*7, 1];
for blk = {[mdl '/FM_DEMOD/AA_I'], [mdl '/FM_DEMOD/AA_Q']}
    hdlset_param(blk{1}, 'SerialPartition', SP_AA);
end
hdlset_param([mdl '/FM_DEMOD/AudioLPF'], 'SerialPartition', SP_AUDIO);
fprintf('  AA_I/AA_Q  : SerialPartition=ones(1,15)*7    (15 DSP48E1s each).\n');
fprintf('  AudioLPF   : SerialPartition=[ones(1,14)*7,1] (15 DSP48E1s).\n');
fprintf('  Total DSP48E1s: 45 of 80 available.\n');

% ── Accumulator types for simulation ─────────────────────────────────────
% AA_I/AA_Q: use inherit so HDL Coder can apply full precision automatically
% (avoids the precision-loss message). For simulation Simulink computes
% a suitable width from the input type.
for blk = {[mdl '/FM_DEMOD/AA_I'], [mdl '/FM_DEMOD/AA_Q']}
    set_param(blk{1}, 'AccumDataTypeStr', 'Inherit: Inherit via internal rule');
end
% AudioLPF: explicit type required to stay within 128-bit limit given the
% wider fixdt(1,32,14) input introduced after model restructuring.
set_param([mdl '/FM_DEMOD/AudioLPF'], 'AccumDataTypeStr', 'fixdt(1,40,14)');
fprintf('  AA_I/AA_Q AccumDataTypeStr: Inherit via internal rule.\n');
fprintf('  AudioLPF  AccumDataTypeStr: fixdt(1,40,14).\n');

% ── Sample times for post-decimation blocks ───────────────────────────────
T_OUT = num2str(1/FS_OUT_NOM);   % '2e-05'
try
    set_param([mdl '/FM_DEMOD/Data Type Conversion1'], 'SampleTime', T_OUT);
    fprintf('  Data Type Conversion1 sample time: %s s (%.0f kHz).\n', T_OUT, FS_OUT_NOM/1e3);
catch
    fprintf('  Data Type Conversion1: not found — OK.\n');
end
set_param([mdl '/FM_DEMOD/AudioLPF'], 'SampleTime', T_OUT);
fprintf('  AudioLPF sample time: %s s (%.0f kHz).\n', T_OUT, FS_OUT_NOM/1e3);

% ── AudioLPF InputProcessing and data types ──────────────────────────────
set_param([mdl '/FM_DEMOD/AudioLPF'], 'InputProcessing', ...
    'Elements as channels (sample based)');
% AudioLPF was designed with fixdt(1,18,17) input (from AA_I/AA_Q).
% After model changes, its input is fixdt(1,32,14) from the discriminator.
% With a wider input Simulink recomputes the accumulator beyond 128 bits.
% Fix: set CoefDataTypeStr to match accumulator precision, and explicitly
% set AccumDataTypeStr wide enough for fixdt(1,32,14) input + 128 taps:
%   headroom = ceil(log2(105)) = 7 bits -> accum = 32+7 = 39 -> use 40.
%   fractional bits match input: 14.
set_param([mdl '/FM_DEMOD/AudioLPF'], 'CoefDataTypeStr',  'fixdt(1,32,14)');
set_param([mdl '/FM_DEMOD/AudioLPF'], 'AccumDataTypeStr', 'fixdt(1,40,14)');
set_param([mdl '/FM_DEMOD/AudioLPF'], 'OutDataTypeStr',   'fixdt(1,32,14)');
fprintf('  AudioLPF: sample-based, Accum=fixdt(1,40,14), Coef/Out=fixdt(1,32,14).\n');

% ── DeEmph (simulation only — replace with IIR primitives for HDL Coder) ─
try
    set_param([mdl '/FM_DEMOD/DeEmph'], 'InputProcessing', ...
        'Elements as channels (sample based)');
    set_param([mdl '/FM_DEMOD/DeEmph'], 'SampleTime', T_OUT);
    fprintf('  DeEmph: sample-based, %.0f kHz (replace with IIR primitives for HDL Coder).\n', ...
            FS_OUT_NOM/1e3);
catch
    fprintf('  DeEmph: not found or already replaced — OK.\n');
end

% ── ToWorkspace sample time ───────────────────────────────────────────────
set_param([mdl '/audio_50k'], 'SampleTime', T_OUT);
fprintf('  ToWorkspace: %s s (%.0f kHz).\n', T_OUT, FS_OUT_NOM/1e3);

% ── Suppress coefficient precision loss warning ───────────────────────────
warning('off', 'SimulinkFixedPoint:util:fxpParameterPrecisionLoss');

%% 2.  Load and prepare IQ data ───────────────────────────────────────────
fprintf('=== Loading IQ data ===\n');
[raw, fs_wav] = audioread(WAV_FILE, 'native');
assert(fs_wav == FS_IQ, 'SR mismatch: got %d Hz, expected %d Hz', fs_wav, FS_IQ);
assert(size(raw,2) == 2, 'Expected 2-channel (I/Q) WAV, got %d channels', size(raw,2));
if isfinite(MAX_SECONDS)
    raw = raw(1 : min(end, round(MAX_SECONDS * FS_IQ)), :);
end
n_samp  = size(raw, 1);
T_step  = 1 / FS_IQ;
SIM_DUR = (n_samp - 1) * T_step;
fprintf('  %d samples  (%.1f s)\n', n_samp, SIM_DUR);

% Normalise int16 -> double [-1, 1)
I_raw = double(raw(:,1)) / 32768;
Q_raw = double(raw(:,2)) / 32768;

% NCO: pre-compute cos/sin for carrier offset correction
t_iq    = (0 : n_samp-1).' / FS_IQ;
nco_ph  = 2 * pi * (-CARRIER_OFFSET) * t_iq;
nco_cos = cos(nco_ph);
nco_sin = sin(nco_ph);

% Cast to sfix16_En15 fi objects to match FromWorkspace OutDataTypeStr.
I_fi   = fi(I_raw,   1, 16, 15);
Q_fi   = fi(Q_raw,   1, 16, 15);
cos_fi = fi(nco_cos, 1, 16, 15);
sin_fi = fi(nco_sin, 1, 16, 15);

t_col      = t_iq;
ts_I       = timeseries(I_fi,    t_col, 'Name', 'I_raw');
ts_Q       = timeseries(Q_fi,    t_col, 'Name', 'Q_raw');
ts_nco_cos = timeseries(cos_fi,  t_col, 'Name', 'nco_cos');
ts_nco_sin = timeseries(sin_fi,  t_col, 'Name', 'nco_sin');
fprintf('  Workspace variables ready (fi sfix16_En15).\n');

%% 3.  Update model stop time ─────────────────────────────────────────────
set_param(mdl, 'StopTime', num2str(SIM_DUR));

%% 4.  Run simulation ─────────────────────────────────────────────────────
fprintf('=== Running simulation (%.1f s at %.0f kHz = %d steps) ===\n', ...
        SIM_DUR, FS_IQ/1e3, n_samp);
out = sim(mdl);
warning('on', 'SimulinkFixedPoint:util:fxpParameterPrecisionLoss');

%% 5.  Extract output ─────────────────────────────────────────────────────
fprintf('=== Post-processing ===\n');

if exist('out','var') && isobject(out) && isprop(out,'audio_50k')
    sig = out.audio_50k;
elseif exist('out','var') && isstruct(out) && isfield(out,'audio_50k')
    sig = out.audio_50k;
elseif exist('audio_50k','var')
    sig = audio_50k; %#ok<NODEF>
else
    error('audio_50k not found in sim output or workspace.');
end

if isstruct(sig) && isfield(sig,'signals')
    sig = sig.signals.values;
end
sig = double(sig(:));
expected_50k = round(SIM_DUR * FS_OUT_NOM);
actual_ratio = length(sig) / expected_50k;
fprintf('  Raw output: %d samples (expected ~%d at 50 kHz, ratio %.2fx)\n', ...
        length(sig), expected_50k, actual_ratio);

% Rate correction: if FIR Decimation1 bypassed decimation the output will
% be at 250 kHz (ratio ~5). Correct with FIR-based decimate() to avoid aliasing.
if actual_ratio > 1.5
    ds_factor = round(actual_ratio);
    fprintf('  Rate correction: decimating by %d (actual Fs ~%.0f kHz -> 50 kHz)\n', ...
            ds_factor, FS_OUT_NOM * ds_factor / 1e3);
    sig = decimate(sig, ds_factor, 'fir');
    fprintf('  After correction: %d samples\n', length(sig));
else
    fprintf('  Rate correct — no correction needed.\n');
end

%% 6.  Trim FIR Decimation1 group delay ───────────────────────────────────
% 41-tap linear-phase FIR, D=5: group delay = (41-1)/2 / 5 = 4 output samples.
n_taps      = length(FIR_DEC_COEFFS);   % 41
group_delay = (n_taps - 1) / 2 / 5;    % 4 output samples
trim        = ceil(group_delay);        % 4
if length(sig) > trim
    sig = sig(trim+1 : end);
end
fprintf('  FIR group delay trim: %d output samples\n', trim);

%% 7.  Resample 50 kHz -> 48 kHz ──────────────────────────────────────────
[rs_p, rs_q] = rat(FS_AUDIO / FS_OUT_NOM, 1e-9);   % 24/25
fprintf('  Resample %d/%d  (%.0f kHz -> %.0f kHz)\n', ...
        rs_p, rs_q, FS_OUT_NOM/1e3, FS_AUDIO/1e3);
audio = resample(sig, rs_p, rs_q);

%% 8.  Normalise and clip ─────────────────────────────────────────────────
audio = audio / (max(abs(audio)) + eps) * 0.95;
audio = max(min(audio, 1), -1);

%% 9.  Output ─────────────────────────────────────────────────────────────
if SAVE_WAV
    out_wav = 'fm_audio_z7_10_simulink.wav';
    audiowrite(out_wav, audio, FS_AUDIO, 'BitsPerSample', 16);
    fprintf('  Saved: %s\n', out_wav);
end
if PLAY_AUDIO
    fprintf('  Playing %.1f s ...\n', length(audio)/FS_AUDIO);
    sound(audio, FS_AUDIO);
end
fprintf('=== Done ===\n');
