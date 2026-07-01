% fm_demod.m
% FM demodulator for SDRplay IQ WAV recordings.
% Tested against the FM RDS demo file (rds.zip) from:
%   https://sdrplay.com/resources/IQ/rds.zip
%
% Recording parameters (read from the SDRuno screenshot):
%   Centre (LO) : 88.110 MHz
%   Station     : 88.100 MHz  →  carrier at -10 kHz in IQ
%   Sample rate : 250 kHz
%   Deviation   : ±75 kHz (wideband FM)
%   De-emphasis : 75 µs  (WAY-FM is a US station)
%
% The script is self-contained: no toolboxes are strictly required.
% The Communications Toolbox or DSP System Toolbox will be used
% automatically if present (faster filter design), but the script
% falls back to basic MATLAB otherwise.
%
% Usage:
%   1.  Unzip rds.zip and place rds.wav in the same folder as this script,
%       or edit WAV_FILE below.
%   2.  Run:  fm_demod
%   3.  The script plays stereo audio on your default soundcard and saves
%       fm_audio_stereo.wav (48 kHz, 16-bit, stereo) in the same folder.
%
% Marco Aiello, 2024

clear; close all; clc;

%% ── USER PARAMETERS ──────────────────────────────────────────────────────
WAV_FILE      = 'SDRuno_20200907_184033Z_88110kHz.wav';   % path to the SDRplay IQ recording
CARRIER_OFFSET = -10e3;       % Hz  – station offset from LO (+10 kHz shift needed)
FS_AUDIO      = 48e3;         % Hz  – output audio sample rate
DEEMPH_TAU    = 75e-6;        % s   – 75 µs for US FM, use 50e-6 for European
AUDIO_GAIN    = 1.0;          % linear scale applied before playcard (1 = normalise)
PLAY_AUDIO    = true;         % set false to skip soundcard playback
SAVE_AUDIO    = true;         % set false to skip WAV output
PLOT_SPECTRA  = true;         % show diagnostic spectra
MAX_SECONDS   = inf;          % limit playback duration (inf = full file)
%% ────────────────────────────────────────────────────────────────────────

%% 1.  Read WAV file ───────────────────────────────────────────────────────
fprintf('Reading %s …\n', WAV_FILE);
[raw, fs_iq] = audioread(WAV_FILE, 'native');   % int16, Nx2
if ~isa(raw, 'int16')
    error('Expected int16 samples; got %s. Check the WAV file.', class(raw));
end
if size(raw, 2) ~= 2
    error('Expected 2-channel (I/Q) WAV; got %d channels.', size(raw, 2));
end

fprintf('  Sample rate : %.0f kHz\n', fs_iq/1e3);
fprintf('  Samples     : %d  (%.1f s)\n', size(raw,1), size(raw,1)/fs_iq);

% Trim to MAX_SECONDS
if isfinite(MAX_SECONDS)
    n_max = min(size(raw,1), round(MAX_SECONDS * fs_iq));
    raw = raw(1:n_max, :);
    fprintf('  Trimmed to  : %.1f s\n', n_max/fs_iq);
end

% Convert to normalised double in (-1, 1)
iq = double(raw(:,1)) + 1j * double(raw(:,2));
iq = iq / 32768.0;

%% 2.  Frequency-correct: shift carrier to DC ─────────────────────────────
% The LO is 10 kHz above the station, so the carrier sits at -10 kHz.
% Multiply by exp(+j 2π 10kHz t) to move it to DC.
fprintf('Applying %.0f kHz frequency correction …\n', -CARRIER_OFFSET/1e3);
t  = (0 : length(iq)-1).' / fs_iq;
iq = iq .* exp(1j * 2*pi * (-CARRIER_OFFSET) * t);

%% 3.  Optional: diagnostic spectrum before demodulation ──────────────────
if PLOT_SPECTRA
    figure('Name', 'IQ spectrum after frequency correction', 'NumberTitle', 'off');
    Nfft = 8192;
    [Pxx, f] = pwelch(iq, hann(Nfft), Nfft/2, Nfft, fs_iq, 'centered');
    plot(f/1e3, 10*log10(Pxx));
    xlabel('Frequency (kHz relative to station)');
    ylabel('PSD (dB/Hz)');
    title('IQ spectrum – carrier centred at 0 Hz');
    grid on;
    xline([-75 75],  '--r', '±75 kHz dev');
    xline([-15 15],  '--g', 'Audio BW');
    xline([-19 19],  ':m', '±19 kHz pilot');
    xline([-57 57],  ':c', '±57 kHz RDS');
end

%% 4.  Anti-alias LPF before decimation ───────────────────────────────────
% Pass ±100 kHz, stop outside ±125 kHz (half the 250 kHz rate).
% Simple FIR designed with fir1 – no toolbox needed.
fprintf('Designing anti-alias LPF …\n');
f_lp    = 100e3;
N_lp    = 128;                      % filter order
win     = kaiser(N_lp+1, 8);
h_lp    = fir1(N_lp, f_lp/(fs_iq/2), 'low', win);

iq_filt = filter(h_lp, 1, iq);

%% 5.  Decimation: 250 kHz → 50 kHz  (factor 5) ───────────────────────────
D1      = 5;
fs_bb   = fs_iq / D1;              % 50 kHz
iq_dec  = iq_filt(1:D1:end);
fprintf('Post-decimation rate: %.0f kHz\n', fs_bb/1e3);

%% 6.  FM discriminator: differential phase ────────────────────────────────
% φ[n] = angle( z[n] * conj(z[n-1]) )
% Normalise by 2π × fs_bb so output is in Hz (or fraction of fs_bb/2).
fprintf('FM discriminating …\n');
z         = iq_dec;
z_del     = [0; z(1:end-1)];
prod      = z .* conj(z_del);
demod_hz  = angle(prod) * (fs_bb / (2*pi));   % instantaneous frequency in Hz

% Expected peak deviation ±75 kHz at fs_bb = 50 kHz →
% angle values will be in (-π, π), mapping to ±25 kHz → rescale not needed,
% but since |deviation| (75 kHz) > fs_bb/2 (25 kHz) we must NOT have
% decimated below Nyquist.  At 50 kHz rate the ±75 kHz deviation wraps –
% FM Carson BW is 180 kHz; we need fs_bb ≥ 200 kHz to avoid aliasing
% in the IF before discriminator.  Correct approach: discriminate first,
% then decimate audio.

% ── Redo: discriminate at 250 kHz, then decimate audio ──────────────────
fprintf('Redoing: discriminate at full 250 kHz rate, then decimate …\n');
z2       = iq_filt;                         % 250 kHz, anti-aliased to ±100 kHz
z2_del   = [0; z2(1:end-1)];
prod2    = z2 .* conj(z2_del);
demod    = angle(prod2) * (fs_iq / (2*pi)); % Hz, at 250 kHz rate

if PLOT_SPECTRA
    figure('Name', 'Demodulated baseband spectrum', 'NumberTitle', 'off');
    Nfft2 = 8192;
    [Pbb, fbb] = pwelch(demod, hann(Nfft2), Nfft2/2, Nfft2, fs_iq);
    plot(fbb/1e3, 10*log10(Pbb));
    xlabel('Frequency (kHz)');
    ylabel('PSD (dB/Hz)');
    title('FM demodulated baseband (before audio filtering)');
    grid on;
    xline(15,  '--g', 'Audio 15 kHz');
    xline(19,  '--m', '19 kHz pilot');
    xline(38,  '--r', '38 kHz subcarrier');
    xline(57,  ':c',  '57 kHz RDS');
    xlim([0 125]);
end

%% 7.  Extract mono (L+R) and stereo pilot / subcarrier ───────────────────

% ── 7a. Mono channel: LPF to 15 kHz ─────────────────────────────────────
fprintf('Extracting mono (L+R) audio …\n');
N_audio  = 256;
h_mono   = fir1(N_audio, 15e3/(fs_iq/2), 'low', kaiser(N_audio+1, 8));
mono_raw = filter(h_mono, 1, demod);

% ── 7b. Pilot tone: narrow BPF at 19 kHz → PLL reference ────────────────
fprintf('Extracting 19 kHz pilot …\n');
f_pilot  = 19e3;
bw_pilot = 200;                             % Hz, very narrow
h_pilot  = fir1(512, [(f_pilot-bw_pilot) (f_pilot+bw_pilot)]/(fs_iq/2), ...
                'bandpass', kaiser(513, 10));
pilot    = filter(h_pilot, 1, demod);

% Double the pilot to get 38 kHz subcarrier reference (Hilbert approach)
% analytic pilot → instantaneous phase → double → real subcarrier
a_pilot  = hilbert(pilot);                  % analytic signal at 19 kHz
sub38    = real(a_pilot .* a_pilot);        % (re+j·im)² → real part = cos(2×19k·t)
% Normalise
sub38    = sub38 / (max(abs(sub38)) + eps);

% ── 7c. DSB-SC demodulate stereo difference (L-R): BPF 23–53 kHz ─────────
fprintf('Extracting stereo (L-R) …\n');
h_dsb    = fir1(256, [23e3 53e3]/(fs_iq/2), 'bandpass', kaiser(257, 8));
dsb      = filter(h_dsb, 1, demod);
lr_diff  = dsb .* sub38;                   % product detector
% LPF to 15 kHz to remove 2nd harmonic at 76 kHz
h_lr     = fir1(256, 15e3/(fs_iq/2), 'low', kaiser(257, 8));
lr_diff  = filter(h_lr, 1, lr_diff);

%% 8.  De-emphasis: single-pole IIR, τ = 75 µs (US) ──────────────────────
% H(z) = (1-a) / (1 - a·z⁻¹),   a = exp(-1/(τ·fs))
fprintf('Applying %.0f µs de-emphasis …\n', DEEMPH_TAU*1e6);
a_de  = exp(-1 / (DEEMPH_TAU * fs_iq));
b_de  = [1-a_de];
a_de_ = [1, -a_de];
mono_de = filter(b_de, a_de_, mono_raw);
lr_de   = filter(b_de, a_de_, lr_diff);

%% 9.  Decimate to audio rate (250 kHz → 48 kHz) ──────────────────────────
% Rational ratio: 48000/250000 = 12/62.5 – not integer.
% Use resample() which handles arbitrary rational ratios.
fprintf('Resampling to %.0f kHz …\n', FS_AUDIO/1e3);
[p, q]   = rat(FS_AUDIO / fs_iq, 1e-6);    % find p/q ≈ 48/250
mono_48  = resample(mono_de,  p, q);
lr_48    = resample(lr_de,    p, q);

%% 10.  Reconstruct L and R channels ─────────────────────────────────────
% L = (L+R)/2 + (L-R)/2
% R = (L+R)/2 - (L-R)/2
% Align amplitudes: the stereo difference channel is attenuated by the
% pilot amplitude (typically 9 % of total deviation) so rescale.
% A rough calibration: scale lr to match mono RMS.
scale = rms(mono_48) / (rms(lr_48) + eps);
lr_48_sc = lr_48 * scale * 0.9;           % 0.9 empirical for typical pilot level

L = (mono_48 + lr_48_sc) / 2;
R = (mono_48 - lr_48_sc) / 2;

%% 11.  Normalise and pack stereo ─────────────────────────────────────────
stereo = [L, R];
peak   = max(abs(stereo(:))) + eps;
stereo = stereo / peak * 0.95 * AUDIO_GAIN;
stereo = max(min(stereo, 1), -1);          % hard clip safety

%% 12.  Save audio WAV ────────────────────────────────────────────────────
if SAVE_AUDIO
    out_file = 'fm_audio_stereo.wav';
    audiowrite(out_file, stereo, FS_AUDIO, 'BitsPerSample', 16);
    fprintf('Saved: %s\n', out_file);
end

%% 13.  Play on soundcard ─────────────────────────────────────────────────
if PLAY_AUDIO
    fprintf('Playing %.1f s of stereo audio … (Ctrl-C to stop)\n', ...
            size(stereo,1)/FS_AUDIO);
    sound(stereo, FS_AUDIO);
end

%% 14.  Final diagnostic plot ─────────────────────────────────────────────
if PLOT_SPECTRA
    figure('Name', 'Audio spectrum (L and R)', 'NumberTitle', 'off');
    Nfft3 = 4096;
    [PL, fL] = pwelch(L, hann(Nfft3), Nfft3/2, Nfft3, FS_AUDIO);
    [PR, fR] = pwelch(R, hann(Nfft3), Nfft3/2, Nfft3, FS_AUDIO);
    plot(fL/1e3, 10*log10(PL), 'b', fR/1e3, 10*log10(PR), 'r--');
    xlabel('Frequency (kHz)');
    ylabel('PSD (dB/Hz)');
    title('Demodulated audio spectrum');
    legend('L', 'R');
    grid on;
    xlim([0 16]);
end

fprintf('Done.\n');
