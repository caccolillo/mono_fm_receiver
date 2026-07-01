% gen_aa_lpf_coe.m
% Generates the .coe coefficient file for the Xilinx FIR Compiler v7.2
% and all necessary artifacts for a bit-accurate Vitis HLS implementation.
%
% Filter spec:
%   Type        : Low-pass FIR, linear phase
%   Taps        : 129  (even symmetry, odd number of taps)
%   Cutoff      : 100 kHz  (= fs/2.5, passes ±100 kHz of the 250 kHz band)
%   Window      : Kaiser, beta=8
%   Sample rate : 250 kHz
%   Data width  : 18 bits  (fixdt(1,18,17), matches FreqCorr output)
%   Coef width  : 32 bits  (fixdt(1,32,30), matches Simulink precision)
%
% The same coefficients are used for AA_I and AA_Q. The HLS filter is now
% SINGLE-CHANNEL (one instance per channel, no internal multiplexing), so
% this script writes SEPARATE stimulus/golden files per channel rather
% than an interleaved pair.
%
% Output: aa_lpf.coe                  (Xilinx coefficient file format)
%         coefficients.h              (Auto-generated HLS C++ header)
%         aa_lpf_i_stimulus.txt       (I-channel HLS testbench stimulus)
%         aa_lpf_i_golden.txt         (I-channel HLS testbench golden)
%         aa_lpf_q_stimulus.txt       (Q-channel HLS testbench stimulus)
%         aa_lpf_q_golden.txt         (Q-channel HLS testbench golden)
%


fprintf('=== Generating AA LPF coefficient file and HLS assets ===\n');

FS     = 250e3;    % sample rate Hz
FC     = 100e3;    % cutoff Hz
NTAPS  = 129;      % number of taps
BETA   = 8;        % Kaiser window beta
COEF_W = 18;       % COE coefficient word width (bits)

% Design filter
h = fir1(NTAPS-1, FC/(FS/2), 'low', kaiser(NTAPS, BETA));

% Verify response
[H, f] = freqz(h, 1, 4096, FS);
H_dB = 20*log10(abs(H));
fprintf('  Passband ripple (0-90 kHz):  %.2f dB\n', max(H_dB(f < 90e3)) - 0);
fprintf('  Stopband atten  (110+ kHz):  %.1f dB\n', max(H_dB(f > 110e3)));
fprintf('  Group delay: %d samples\n', (NTAPS-1)/2);

% Quantise to COEF_W-bit signed integer using fixdt(1,COEF_W,COEF_W-1).
MAX_COEF = 2^(COEF_W-1) - 1;   % 131071 for 18-bit
h_int    = round(h * MAX_COEF); % direct quantisation, no normalisation

% Verify quantisation error
h_q    = h_int / MAX_COEF;
max_err = max(abs(h - h_q * max(abs(h))));
fprintf('  Max coefficient quantisation error: %.2e\n', max_err);
fprintf('  Smallest coefficient: %.4e -> %d LSBs\n', ...
        min(abs(h(abs(h)>0))), min(abs(h_int(h_int~=0))));

% Write .coe file
coe_file = 'aa_lpf.coe';
fid = fopen(coe_file, 'w');
fprintf(fid, '; AA LPF coefficient file for Xilinx FIR Compiler v7.2\n');
fprintf(fid, '; Filter: %d-tap Kaiser (beta=%.0f), fc=%.0f kHz, fs=%.0f kHz\n', ...
        NTAPS, BETA, FC/1e3, FS/1e3);
fprintf(fid, '; Coefficient width: %d bits signed\n', COEF_W);
fprintf(fid, '; Scale: peak coefficient = %d (= 2^%d - 1)\n', ...
        MAX_COEF, COEF_W-1);
fprintf(fid, ';\n');
fprintf(fid, 'radix=10;\n');
fprintf(fid, 'coefdata=\n');
for k = 1:NTAPS
    if k < NTAPS
        fprintf(fid, '%d,\n', h_int(k));
    else
        fprintf(fid, '%d;\n', h_int(k));
    end
end
fclose(fid);
fprintf('  Written: %s  (%d coefficients)\n', coe_file, NTAPS);

% Also save coefficients as MATLAB variable for use in run_and_extract
h_aa_coe = h_int;
save('aa_lpf_coeffs.mat', 'h_aa_coe', 'h', 'NTAPS', 'COEF_W', 'MAX_COEF');
fprintf('  Saved: aa_lpf_coeffs.mat\n');

%% ==============================================================================
%% Generate coefficients.h for Vitis HLS
%% ==============================================================================
hls_h_file = 'coefficients.h';
fid_hls = fopen(hls_h_file, 'w');

fprintf(fid_hls, '#ifndef COEFFICIENTS_H_\n');
fprintf(fid_hls, '#define COEFFICIENTS_H_\n\n');
fprintf(fid_hls, '// Auto-generated array containing 129 filter taps\n');
fprintf(fid_hls, '// Extracted directly at maximum 15-digit double-precision floating scale\n');
fprintf(fid_hls, 'const coef_t c[NTAPS] = {\n    ');

for k = 1:NTAPS
    fprintf(fid_hls, '%.15e', h(k));
    if k < NTAPS
        fprintf(fid_hls, ', ');
        if mod(k, 4) == 0
            fprintf(fid_hls, '\n    ');
        end
    else
        fprintf(fid_hls, '\n};\n\n');
    end
end
fprintf(fid_hls, '#endif // COEFFICIENTS_H_\n');

fclose(fid_hls);
fprintf('  Generated C++ Header: %s\n', hls_h_file);

%% ==============================================================================
%% Generate SEPARATE (non-interleaved) Verification Vectors per channel
%% ==============================================================================
% The HLS filter is now single-channel (instantiated once per I/Q).
% Each channel's stimulus is filtered independently, matching the
% Simulink/original interleaved-hardware behaviour where each channel's
% shift register only ever sees that channel's own sample history.
rng(42);        % Lock random seed for deterministic hardware tests
NUM_SAMPLES = 50;

% Generate random signal paths bounded safely below saturation points
raw_i = (rand(1, NUM_SAMPLES)*2 - 1) * 0.4;
raw_q = (rand(1, NUM_SAMPLES)*2 - 1) * 0.4;

% Enforce Input Data Type: fixdt(1,18,17)
input_i = double(fi(raw_i, 1, 18, 17));
input_q = double(fi(raw_q, 1, 18, 17));

% Fixed-point arithmetic rules matching the HLS accumulator/coefficient types.
% Product intermediate space: 40 bits total, 17 fractional.
% Accumulator intermediate space: 40 bits total, 17 fractional.
F_sim = fimath(...
    'RoundingMethod', 'Floor', ...
    'OverflowAction', 'Saturate', ...
    'ProductMode', 'SpecifyPrecision', ...
    'ProductWordLength', 40, ...
    'ProductFractionLength', 17, ...
    'SumMode', 'SpecifyPrecision', ...
    'SumWordLength', 40, ...
    'SumFractionLength', 17);

fi_h       = fi(h, 1, 32, 30, F_sim);
input_i_fi = fi(input_i, 1, 18, 17, F_sim);
input_q_fi = fi(input_q, 1, 18, 17, F_sim);

% Run filtering core independently per channel (each channel's own history).
filt_i = filter(fi_h, 1, input_i_fi);
filt_q = filter(fi_h, 1, input_q_fi);

% Extract and cast results cleanly to output metrics: fixdt(1,18,17)
T_out = numerictype(1, 18, 17);
out_i_fixed = double(fi(filt_i, T_out, F_sim));
out_q_fixed = double(fi(filt_q, T_out, F_sim));

% Write SEPARATE per-channel files (no interleaving)
writematrix(input_i',   'aa_lpf_i_stimulus.txt');
writematrix(out_i_fixed','aa_lpf_i_golden.txt');
writematrix(input_q',   'aa_lpf_q_stimulus.txt');
writematrix(out_q_fixed','aa_lpf_q_golden.txt');

fprintf('  Generated I-channel vectors: aa_lpf_i_stimulus.txt / aa_lpf_i_golden.txt\n');
fprintf('  Generated Q-channel vectors: aa_lpf_q_stimulus.txt / aa_lpf_q_golden.txt\n');
fprintf('  (%d samples each, single-channel non-interleaved)\n', NUM_SAMPLES);

% Plot response
figure('Name', 'AA LPF Frequency Response', 'Position', [100 100 800 400]);
subplot(1,2,1);
plot(f/1e3, H_dB, 'b', 'LineWidth', 1.5);
xlabel('Frequency (kHz)'); ylabel('Magnitude (dB)');
title('AA LPF Frequency Response');
grid on; xlim([0 FS/2/1e3]);
yline(-3,  '--r', '-3 dB');
yline(-60, '--g', '-60 dB');

subplot(1,2,2);
stem(h_int, 'b.', 'MarkerSize', 4);
xlabel('Tap index'); ylabel('Coefficient value');
title(sprintf('Quantised coefficients (%d-bit)', COEF_W));
grid on;
saveas(gcf, 'aa_lpf_response.png');
fprintf('  Saved: aa_lpf_response.png\n');
fprintf('=== Done ===\n');
