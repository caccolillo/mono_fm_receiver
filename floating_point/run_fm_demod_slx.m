% run_fm_demod_slx.m
%
% Runs the pre-built fm_demod_slx.slx Simulink FM mono demodulator.
% Loads IQ data, populates workspace variables, runs sim, plays audio.
%
% Signal chain in the model:
%   From Workspace (I, Q, cos, sin at 250 kHz)
%     -> FreqCorr subsystem (complex multiply)
%     -> AA_I / AA_Q (Discrete FIR Filter, anti-alias LPF)
%     -> FM_Disc subsystem (CORDIC differential phase)
%     -> Buffer (5 samples -> frame)
%     -> Data Type Conversion
%     -> FIR Decimation (fir1(40,1/5), factor=5, 250kHz->50kHz)
%     -> AudioLPF (Discrete FIR Filter, 15 kHz)
%     -> DeEmph (Discrete Filter, 75 us)
%     -> To Workspace -> audio_50k
%
% Post-sim: resample 50k->48k, normalise, sound() + audiowrite()
%


clear; clc;
mdl = 'fm_demod_slx';

%% ── PARAMETERS ───────────────────────────────────────────────────────────
WAV_FILE       = 'rds.wav';
CARRIER_OFFSET = -10e3;     % Hz  station at -10 kHz from LO
FS_IQ          = 250e3;     % Hz  IQ sample rate
FS_OUT         = 50e3;      % Hz  post-decimation rate (250k/5)
FS_AUDIO       = 48e3;      % Hz  final audio rate
DEEMPH_TAU     = 75e-6;     % s   75 us US FM
MAX_SECONDS    = 30;
FIR_DEC_COEFFS = fir1(40, 1/5);   % must match FIR Decimation block coefficients
SAVE_WAV       = true;
PLAY_AUDIO     = true;
%% ────────────────────────────────────────────────────────────────────────

%% 1.  Check model is loaded ───────────────────────────────────────────────
assert(bdIsLoaded(mdl) || exist([mdl '.slx'], 'file'), ...
    'Model %s not found. Open fm_demod_slx.slx first.', mdl);
if ~bdIsLoaded(mdl)
    load_system(mdl);
    fprintf('Loaded: %s.slx\n', mdl);
end

%% 2.  Load and prepare IQ data ───────────────────────────────────────────
fprintf('=== Loading IQ data ===\n');
[raw, fs_wav] = audioread(WAV_FILE, 'native');
assert(fs_wav == FS_IQ, 'SR mismatch: got %d expected %d', fs_wav, FS_IQ);
assert(size(raw,2) == 2, 'Expected 2-channel I/Q WAV');
if isfinite(MAX_SECONDS)
    raw = raw(1 : min(end, round(MAX_SECONDS*FS_IQ)), :);
end
n_samp  = size(raw, 1);
T_step  = 1 / FS_IQ;
SIM_DUR = (n_samp-1) * T_step;
fprintf('  %d samples  (%.1f s)\n', n_samp, SIM_DUR);

% Normalise int16 -> double
I_raw = double(raw(:,1)) / 32768;
Q_raw = double(raw(:,2)) / 32768;

% NCO: pre-compute cos/sin for +10 kHz frequency correction
t_iq    = (0:n_samp-1).' / FS_IQ;
nco_ph  = 2*pi*(-CARRIER_OFFSET)*t_iq;
nco_cos = cos(nco_ph);
nco_sin = sin(nco_ph);

% Pack as timeseries (Simulink From Workspace format)
t_col      = t_iq;
ts_I       = timeseries(I_raw,    t_col, 'Name', 'I_raw');
ts_Q       = timeseries(Q_raw,    t_col, 'Name', 'Q_raw');
ts_nco_cos = timeseries(nco_cos,  t_col, 'Name', 'nco_cos');
ts_nco_sin = timeseries(nco_sin,  t_col, 'Name', 'nco_sin');
fprintf('  Workspace variables ready.\n');

%% 3.  Update model stop time to match loaded data ────────────────────────
set_param(mdl, 'StopTime', num2str(SIM_DUR));

%% 4.  Run simulation ─────────────────────────────────────────────────────
fprintf('=== Running simulation (%.1f s at %.0f kHz = %d steps) ===\n', ...
        SIM_DUR, FS_IQ/1e3, n_samp);
out = sim(mdl);

%% 5.  Extract output ─────────────────────────────────────────────────────
fprintf('=== Post-processing ===\n');

% Handle both modern (out struct) and legacy (base workspace) output
if exist('out','var') && isobject(out) && isprop(out,'audio_50k')
    sig = out.audio_50k;
elseif exist('out','var') && isstruct(out) && isfield(out,'audio_50k')
    sig = out.audio_50k;
elseif exist('audio_50k','var')
    sig = audio_50k; %#ok<NODEF>
else
    error('audio_50k not found in sim output or workspace. Check To Workspace block name.');
end

if isstruct(sig) && isfield(sig,'signals')
    sig = sig.signals.values;
end
sig = double(sig(:));
fprintf('  Raw output: %d samples at %.0f kHz\n', length(sig), FS_OUT/1e3);

%% 6.  Trim FIR Decimation group delay ────────────────────────────────────
% Group delay of a linear-phase FIR with N taps = (N-1)/2 samples
% at the OUTPUT rate (post-decimation).
n_taps      = length(FIR_DEC_COEFFS);          % 41
group_delay = (n_taps - 1) / 2 / 5;            % (40/2)/5 = 4 output samples
trim        = ceil(group_delay);
if length(sig) > trim
    sig = sig(trim+1 : end);
end
fprintf('  FIR group delay trim: %d output samples\n', trim);

%% 7.  Resample 50 kHz -> 48 kHz ──────────────────────────────────────────
[rs_p, rs_q] = rat(FS_AUDIO / FS_OUT, 1e-9);   % 24/25
fprintf('  Resample %d/%d  (%.0f kHz -> %.0f kHz)\n', ...
        rs_p, rs_q, FS_OUT/1e3, FS_AUDIO/1e3);
audio = resample(sig, rs_p, rs_q);

%% 8.  Normalise and clip ─────────────────────────────────────────────────
audio = audio / (max(abs(audio)) + eps) * 0.95;
audio = max(min(audio, 1), -1);

%% 9.  Output ─────────────────────────────────────────────────────────────
if SAVE_WAV
    audiowrite('fm_audio_simulink.wav', audio, FS_AUDIO, 'BitsPerSample', 16);
    fprintf('  Saved: fm_audio_simulink.wav\n');
end
if PLAY_AUDIO
    fprintf('  Playing %.1f s ...\n', length(audio)/FS_AUDIO);
    sound(audio, FS_AUDIO);
end
fprintf('=== Done ===\n');
