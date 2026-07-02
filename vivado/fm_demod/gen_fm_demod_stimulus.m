% gen_fm_demod_stimulus.m
%
% Prepares I/Q stimulus for the full-chain RTL behavioral simulation of
% fm_demod_wrapper, using the SAME quantization as convert_fp_designer.m
% so the FPGA testbench input matches what Simulink consumed bit-for-bit.
%
% Source: rds.wav (2ch, 16-bit PCM, 250 kHz -- I on ch1, Q on ch2)
% Output quantization: fixdt(1,16,15), matching FMT_IQ in
%   convert_fp_designer.m (signed 16-bit, 15 fraction bits, range (-1,1),
%   LSB = 2^-15, matching the 16-bit ADC / SDRplay hardware resolution).
%
% Output files (stored 16-bit signed integers, one value per line):
%   s_axis_i_stimulus.txt
%   s_axis_q_stimulus.txt
%
% These feed s_axis_i_0 / s_axis_q_0 on the fm_demod block design wrapper.
% The on-chip nco_0 (DDS Compiler v6.0, +10 kHz) generates its own cos/sin
% internally during simulation -- no NCO stimulus file is needed here.
%


%% ── PARAMETERS (must match convert_fp_designer.m) ───────────────────────
WAV_FILE    = 'rds.wav';
FS_IQ       = 250e3;
SIM_SECONDS = 10;          % length of RTL testbench stimulus to generate

fprintf('=== Generating FM demod full-chain stimulus ===\n');

%% ── Load and slice ────────────────────────────────────────────────────
[raw, fs_wav] = audioread(WAV_FILE, 'native');
assert(fs_wav == FS_IQ, 'Sample rate mismatch: expected %d Hz, got %d Hz', ...
       FS_IQ, fs_wav);

n_samp_full = size(raw, 1);
n_samp      = min(n_samp_full, round(SIM_SECONDS * FS_IQ));
raw         = raw(1:n_samp, :);

fprintf('  Source: %s (%.1f s available)\n', WAV_FILE, n_samp_full/FS_IQ);
fprintf('  Using : %d samples (%.3f s)\n', n_samp, n_samp/FS_IQ);

%% ── Normalise exactly as convert_fp_designer.m does ──────────────────────
I_raw = double(raw(:,1)) / 32768;
Q_raw = double(raw(:,2)) / 32768;

%% ── Quantise to fixdt(1,16,15) -- identical type to the Simulink model ──
FMT_IQ = fixdt(1, 16, 15);
I_fi   = fi(I_raw, FMT_IQ);
Q_fi   = fi(Q_raw, FMT_IQ);

fprintf('  Quantised to fixdt(1,16,15)\n');
fprintf('  I range: [%.6f, %.6f]\n', min(double(I_fi)), max(double(I_fi)));
fprintf('  Q range: [%.6f, %.6f]\n', min(double(Q_fi)), max(double(Q_fi)));

%% ── Write stored integers (16-bit signed, matches s_axis_*_tdata width) ─
I_int = double(storedInteger(I_fi));
Q_int = double(storedInteger(Q_fi));

writematrix(I_int, 's_axis_i_stimulus.txt');
writematrix(Q_int, 's_axis_q_stimulus.txt');

fprintf('  Written: s_axis_i_stimulus.txt (%d samples)\n', n_samp);
fprintf('  Written: s_axis_q_stimulus.txt (%d samples)\n', n_samp);
fprintf('  Stored integer range: [%d, %d] (16-bit signed: [-32768, 32767])\n', ...
        min([min(I_int) min(Q_int)]), max([max(I_int) max(Q_int)]));
fprintf('=== Done ===\n');
