% verify_fm_demod_rtl.m
%
% Loads the RTL behavioral simulation output (m_axis_data_dut_output.txt,
% captured by tb_fm_demod_chain.vhd), converts it from sfix32_En13 stored
% integers back to real Hz-deviation values, resamples to 48 kHz, plays
% it on the audio device, and compares it against the Simulink float
% reference produced by convert_fp_designer.m (audio_50k_fl / the saved
% fm_audio_fixed.wav), using the same correlation/SNR methodology.
%
% Run convert_fp_designer.m first if audio_50k_fl is not already in the
% base workspace -- this script will attempt to load it, falling back to
% fm_audio_fixed.wav if needed.
%
% Marco Aiello, 2024

clc; clear;

%% ── PARAMETERS (must match convert_fp_designer.m / the RTL testbench) ──
FS_OUT          = 50e3;     % de-emphasis output rate (matches AudioLPF/DeEmph)
FS_AUDIO        = 48e3;     % playback rate
RTL_OUTPUT_FILE = 'm_axis_data_dut_output.txt';
DEEMPH_FRAC_BITS = 13;      % sfix32_En13 -- de_emph_0 output format
SAVE_WAV   = true;
PLAY_AUDIO = true;

fprintf('=== Loading RTL full-chain output ===\n');

%% ── Load captured RTL output ──────────────────────────────────────────
if ~isfile(RTL_OUTPUT_FILE)
    error(['RTL output file not found: %s\n' ...
           'Run the xsim behavioral simulation of tb_fm_demod_chain first.'], ...
          RTL_OUTPUT_FILE);
end

raw_int = readmatrix(RTL_OUTPUT_FILE);
fprintf('  Loaded %d samples from %s\n', numel(raw_int), RTL_OUTPUT_FILE);

% Convert sfix32_En13 stored integers back to real values.
% De-emphasis output represents frequency deviation in Hz (same units as
% the FM discriminator / FIR decimator / Audio LPF stages upstream).
sig_rtl = double(raw_int) / 2^DEEMPH_FRAC_BITS;
fprintf('  Range: [%.1f, %.1f] Hz\n', min(sig_rtl), max(sig_rtl));

%% ── Trim startup transient (matches Step 11 of convert_fp_designer.m) ──
startup = 50;
if numel(sig_rtl) > startup
    sig_rtl = sig_rtl(startup+1:end);
end

%% ── Resample 50 kHz -> 48 kHz and normalise for playback ───────────────
[p, q] = rat(FS_AUDIO / FS_OUT, 1e-9);
audio_rtl = resample(sig_rtl, p, q);
audio_rtl = audio_rtl / (max(abs(audio_rtl)) + eps) * 0.95;
audio_rtl = max(min(audio_rtl, 1), -1);

if SAVE_WAV
    audiowrite('fm_audio_rtl.wav', audio_rtl, FS_AUDIO, 'BitsPerSample', 16);
    fprintf('  Saved: fm_audio_rtl.wav\n');
end

if PLAY_AUDIO
    fprintf('  Playing RTL output: %.1f s ...\n', numel(audio_rtl)/FS_AUDIO);
    sound(audio_rtl, FS_AUDIO);
    pause(numel(audio_rtl)/FS_AUDIO + 0.5);
end

%% ── Compare against Simulink reference ──────────────────────────────────
% Mirrors the comparison block in convert_fp_designer.m Step 12, but
% comparing RTL output against the float baseline (and, if available,
% against the fixed-point Simulink output too) instead of fixed-point vs
% float only.
fprintf('\n=== Comparing RTL output against Simulink reference(s) ===\n');

ref_signals = struct('name', {}, 'data', {});

% Float reference, if present in base workspace from convert_fp_designer.m
if evalin('base', 'exist(''audio_50k_fl'',''var'')')
    sig_fl = evalin('base', 'audio_50k_fl');
    sig_fl = double(squeeze(sig_fl)); sig_fl = sig_fl(:);
    n_bad = find(abs(sig_fl) > 125e3, 1, 'last');
    if ~isempty(n_bad), sig_fl = sig_fl(n_bad+1:end); end
    ref_signals(end+1) = struct('name', 'Simulink float', 'data', sig_fl);
end

% Simulink fixed-point reference, if the saved WAV exists
if isfile('fm_audio_fixed.wav')
    [sig_fx, fs_fx] = audioread('fm_audio_fixed.wav');
    if fs_fx ~= FS_AUDIO
        [p2, q2] = rat(FS_AUDIO / fs_fx, 1e-9);
        sig_fx = resample(sig_fx, p2, q2);
    end
    ref_signals(end+1) = struct('name', 'Simulink fixed-point (fm_audio_fixed.wav)', ...
                                 'data', sig_fx);
end

if isempty(ref_signals)
    fprintf('  No Simulink reference found in workspace or on disk.\n');
    fprintf('  Run convert_fp_designer.m first to generate a comparison baseline.\n');
    fprintf('  RTL audio has been saved/played for a standalone listening check.\n');
    fprintf('=== Done ===\n');
    return;
end

for r = 1:numel(ref_signals)
    name = ref_signals(r).name;
    ref_raw = ref_signals(r).data;

    fprintf('\n  --- vs %s ---\n', name);

    % Align lengths
    n_al   = min(numel(audio_rtl), numel(ref_raw));
    tst    = audio_rtl(1:n_al);
    ref    = ref_raw(1:n_al);

    % Cross-correlate to check/fix alignment (search +-200 samples)
    [xc, lags] = xcorr(tst(1:min(end,50000)), ref(1:min(end,50000)), 200, 'normalized');
    [~, idx]    = max(abs(xc));
    lag         = lags(idx);
    fprintf('    Lag: %d samples (%.2f ms)\n', lag, lag/FS_AUDIO*1e3);
    if lag > 0
        tst = tst(lag+1:end);
        ref = ref(1:end-lag);
    elseif lag < 0
        ref = ref(-lag+1:end);
        tst = tst(1:end+lag);
    end
    n_al = min(numel(tst), numel(ref));
    tst  = tst(1:n_al);
    ref  = ref(1:n_al);

    % Normalise both to the reference peak (scale-invariant comparison)
    ref_peak = max(abs(ref)) + eps;
    ref_n = ref / ref_peak;
    tst_n = tst / ref_peak;

    % Optimal scale correction
    alpha = (ref_n' * tst_n) / (ref_n' * ref_n + eps);
    err   = tst_n - alpha * ref_n;

    corr_mat = corrcoef(ref_n, tst_n);
    corr     = corr_mat(1,2);
    SNR      = 10*log10(mean(ref_n.^2) / (mean(err.^2) + eps));
    ENOB     = (SNR - 1.76) / 6.02;
    gain_dB  = 20*log10(abs(alpha) + eps);

    fprintf('    Correlation : %.6f\n', corr);
    fprintf('    Gain error  : %+.2f dB  (alpha=%.4f)\n', gain_dB, alpha);
    fprintf('    SNR         : %.1f dB\n', SNR);
    fprintf('    ENOB        : %.1f bits\n', ENOB);

    snr_from_corr = 10*log10(corr^2 / (1 - corr^2 + eps));
    fprintf('    SNR from correlation: %.1f dB  (reference value)\n', snr_from_corr);

    if snr_from_corr > 40
        fprintf('    [PASS] RTL chain matches %s (corr=%.4f)\n', name, corr);
    elseif snr_from_corr > 25
        fprintf('    [ACCEPTABLE] Audible quality vs %s\n', name);
    else
        fprintf('    [FAIL] RTL output diverges from %s -- investigate\n', name);
    end
end

fprintf('\n=== Done ===\n');
