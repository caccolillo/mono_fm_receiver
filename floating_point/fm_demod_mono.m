% fm_demod_mono.m
%
% Standalone FM mono demodulator for SDRplay IQ WAV recordings.
% Matches exactly the signal chain used in the Simulink golden model:
%
%   WAV (250 kHz, I16/Q16)
%     -> frequency correction (+10 kHz shift)
%     -> anti-alias LPF (FIR, ±100 kHz)
%     -> FM discriminator (differential phase + atan2)
%     -> CIC decimator (R=5, N=3 integrators + comb)
%     -> audio LPF (FIR, 15 kHz cutoff at 50 kHz rate)
%     -> de-emphasis IIR (75 us, US FM)
%     -> resample 50 kHz -> 48 kHz (ratio 24/25)
%     -> normalise -> audiowrite + sound()
%
% No toolboxes required beyond base MATLAB.
%
% Usage:
%   Place rds.wav in the current folder, then run:  fm_demod_mono
%
% Marco Aiello, 2024

clear; close all; clc;

%% ── PARAMETERS ───────────────────────────────────────────────────────────
WAV_FILE       = 'rds.wav';
CARRIER_OFFSET = -10e3;     % Hz   station sits at -10 kHz from LO
FS_IQ          = 250e3;     % Hz   IQ sample rate
CIC_R          = 5;         % CIC decimation ratio  (250k -> 50k)
CIC_N          = 3;         % CIC number of stages
FS_OUT         = FS_IQ / CIC_R;   % 50 kHz post-CIC rate
FS_AUDIO       = 48e3;      % Hz   output audio rate
DEEMPH_TAU     = 75e-6;     % s    75 us for US FM, 50e-6 for European
MAX_SECONDS    = 30;        % s    set to inf to process full file
SAVE_WAV       = true;
PLAY_AUDIO     = true;
PLOT_ON        = true;
%% ────────────────────────────────────────────────────────────────────────

%% 1.  Read WAV ────────────────────────────────────────────────────────────
fprintf('[1] Reading %s\n', WAV_FILE);
[raw, fs_wav] = audioread(WAV_FILE, 'native');
assert(fs_wav == FS_IQ,   'SR mismatch: got %d, expected %d', fs_wav, FS_IQ);
assert(size(raw,2) == 2,  'Expected 2-channel (I/Q) WAV');

if isfinite(MAX_SECONDS)
    raw = raw(1 : min(end, round(MAX_SECONDS * FS_IQ)), :);
end
n_samp = size(raw, 1);
fprintf('    %d samples  (%.1f s)\n', n_samp, n_samp/FS_IQ);

% Normalise int16 -> double (-1, 1)
I = double(raw(:,1)) / 32768;
Q = double(raw(:,2)) / 32768;

%% 2.  Frequency correction ────────────────────────────────────────────────
% Carrier is at CARRIER_OFFSET = -10 kHz from DC.
% Multiply by exp(+j*2*pi*10e3*t) to shift it to DC.
fprintf('[2] Frequency correction  (%.0f kHz shift)\n', -CARRIER_OFFSET/1e3);
t  = (0 : n_samp-1).' / FS_IQ;
ph = 2*pi*(-CARRIER_OFFSET)*t;
Ic = I.*cos(ph) - Q.*sin(ph);
Qc = I.*sin(ph) + Q.*cos(ph);

%% 3.  Anti-alias LPF  (FIR, ±100 kHz, Kaiser b=8) ───────────────────────
% Prevents FM Carson bandwidth (~180 kHz) from aliasing when we later
% run the discriminator at 250 kHz.
fprintf('[3] Anti-alias LPF\n');
N_aa = 128;
h_aa = fir1(N_aa, 100e3/(FS_IQ/2), 'low', kaiser(N_aa+1, 8));
Ic   = filter(h_aa, 1, Ic);
Qc   = filter(h_aa, 1, Qc);

%% 4.  FM discriminator  (differential phase) ─────────────────────────────
% phi[n] = angle( z[n] * conj(z[n-1]) )
%        = atan2( Q[n]*I[n-1] - I[n]*Q[n-1],
%                 I[n]*I[n-1] + Q[n]*Q[n-1] )
% Output in Hz: multiply angle (rad) by fs/(2*pi)
fprintf('[4] FM discriminator\n');
Ic_d = [0; Ic(1:end-1)];    % z^-1
Qc_d = [0; Qc(1:end-1)];

y_num = Qc.*Ic_d - Ic.*Qc_d;   % Q_diff
y_den = Ic.*Ic_d + Qc.*Qc_d;   % I_diff
demod = atan2(y_num, y_den) * (FS_IQ / (2*pi));   % Hz at 250 kHz rate

%% 5.  CIC decimator  (R=5, N=3) ──────────────────────────────────────────
% N cascaded integrators: y[n] = y[n-1] + x[n]    (at 250 kHz)
% Downsample by R=5                                (250 kHz -> 50 kHz)
% N cascaded combs:     y[n] = x[n] - x[n-M]  M=1 (at 50 kHz)
% DC gain = R^N = 125; divide out at the end.
fprintf('[5] CIC decimator  R=%d N=%d  (%.0f kHz -> %.0f kHz)\n', ...
        CIC_R, CIC_N, FS_IQ/1e3, FS_OUT/1e3);

% Integrators at 250 kHz
x = demod;
for k = 1:CIC_N
    x = cumsum(x);      % integrator: running sum = causal IIR 1/(1-z^-1)
end

% Downsample
x = x(1:CIC_R:end);

% Combs at 50 kHz  (M=1 differential: y[n] = x[n] - x[n-1])
for k = 1:CIC_N
    x = diff([0; x]);
end

% Normalise gain
cic_gain = CIC_R ^ CIC_N;   % 125
x = x / cic_gain;

%% 6.  Audio LPF  (FIR, 15 kHz, at 50 kHz rate) ──────────────────────────
fprintf('[6] Audio LPF  (15 kHz at %.0f kHz)\n', FS_OUT/1e3);
N_alf   = 128;
h_audio = fir1(N_alf, 15e3/(FS_OUT/2), 'low', kaiser(N_alf+1, 8));
x       = filter(h_audio, 1, x);

%% 7.  De-emphasis  (single-pole IIR, tau = 75 us) ────────────────────────
% H(z) = (1-a) / (1 - a*z^-1),   a = exp(-1/(tau*fs))
fprintf('[7] De-emphasis  (tau=%.0f us at %.0f kHz)\n', ...
        DEEMPH_TAU*1e6, FS_OUT/1e3);
a_de = exp(-1 / (DEEMPH_TAU * FS_OUT));
x    = filter(1-a_de, [1, -a_de], x);

%% 8.  Resample  50 kHz -> 48 kHz  (ratio 24/25) ─────────────────────────
fprintf('[8] Resample  %.0f kHz -> %.0f kHz\n', FS_OUT/1e3, FS_AUDIO/1e3);
[rs_p, rs_q] = rat(FS_AUDIO / FS_OUT, 1e-9);
fprintf('    Rational ratio: %d/%d\n', rs_p, rs_q);
audio = resample(x, rs_p, rs_q);

%% 9.  Normalise ──────────────────────────────────────────────────────────
audio = audio / (max(abs(audio)) + eps) * 0.95;
audio = max(min(audio, 1), -1);

%% 10. Output ─────────────────────────────────────────────────────────────
if SAVE_WAV
    audiowrite('fm_audio_mono.wav', audio, FS_AUDIO, 'BitsPerSample', 16);
    fprintf('[9] Saved: fm_audio_mono.wav\n');
end

if PLAY_AUDIO
    fprintf('[10] Playing %.1f s ...\n', length(audio)/FS_AUDIO);
    sound(audio, FS_AUDIO);
end

%% 11. Diagnostic plots ───────────────────────────────────────────────────
if PLOT_ON
    Nfft = 8192;
    win  = hann(Nfft);

    figure('Name','FM demod diagnostics','NumberTitle','off');

    % IQ spectrum after frequency correction
    subplot(3,1,1);
    iq_fc = Ic + 1j*Qc;
    [P,f] = pwelch(iq_fc, win, Nfft/2, Nfft, FS_IQ, 'centered');
    plot(f/1e3, 10*log10(P));
    xlabel('kHz'); ylabel('dB/Hz');
    title('IQ spectrum after frequency correction');
    xline([-75 75],'--r','±75 kHz'); grid on;

    % Demodulated baseband at 250 kHz
    subplot(3,1,2);
    [P,f] = pwelch(demod, win, Nfft/2, Nfft, FS_IQ);
    plot(f/1e3, 10*log10(P));
    xlabel('kHz'); ylabel('dB/Hz');
    title('Demodulated baseband (250 kHz)');
    xline(15,'--g','15 kHz audio');
    xline(19,'--m','19 kHz pilot');
    xline(57,':c','57 kHz RDS');
    xlim([0 125]); grid on;

    % Final audio spectrum
    subplot(3,1,3);
    [P,f] = pwelch(audio, hann(2048), 1024, 2048, FS_AUDIO);
    plot(f/1e3, 10*log10(P));
    xlabel('kHz'); ylabel('dB/Hz');
    title('Audio output spectrum (48 kHz)');
    xlim([0 16]); grid on;
end
