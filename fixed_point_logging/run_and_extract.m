% run_and_extract.m
%
% Loads rds.wav, runs fm_demod_fixed.slx with fixed-point inputs,
% plays the demodulated audio, then saves all probe node signals as
% signed integer text files for VHDL testbench use.
%
% Prerequisites:
%   - fm_demod_fixed.slx in the current folder (from convert_fp_designer.m)
%   - rds.wav in the current folder
%   - To Workspace blocks in the model named:
%       ic_out, qc_out, aa_i, aa_q, fm_disc, buf_out,
%       fir_decimation, audio_lpf, audio_50k
%
% Outputs:
%   - fm_audio_fixed.wav          playback audio
%   - <stage>_golden.txt          signed integer vectors for each probe
%   - input_[i|q|cos|sin]_stimulus.txt  input stimulus vectors
%


clc; clear all;
% clear all ensures no stale workspace variables from previous runs.
% ic_out, qc_out etc. must come from the SAME sim as ts_I, ts_Q.
% If they are from different runs the golden vectors will be misaligned.

%% ── PARAMETERS ───────────────────────────────────────────────────────────
WAV_FILE       = 'rds.wav';
CARRIER_OFFSET = -10e3;     % Hz  station at -10 kHz from LO
FS_IQ          = 250e3;     % Hz  IQ sample rate
FS_OUT         = 50e3;      % Hz  post-decimation rate
FS_AUDIO       = 48e3;      % Hz  playback rate
MAX_SECONDS    = 30;        % s   set to inf for full file
SAVE_WAV       = true;
PLAY_AUDIO     = true;
SAVE_VECTORS   = true;      % set false to skip .txt file generation
MDL            = 'fm_demod_fixed';

% Number of samples to write per vector file.
% 30 s at 250 kHz = 7.5M samples = ~44 MB per file -> ISim is very slow.
% 10000 samples = ~60 KB per file -> ISim reads instantly.
% Rule of thumb: max(filter_length, 1/f_min * fs) + startup margin
%   AA LPF:     129 taps startup + 12500 samples (20 Hz at 250 kHz) = 12629
%   FM_Disc:    5 taps startup   + 12500 samples                    = 12505
%   FIR Dec:    41 taps / 5 (decimated) = 9 samples startup + 250 samples (20 Hz at 50 kHz)
%   Audio LPF:  129 taps startup + 250 samples (20 Hz at 50 kHz)    = 379
% Use 10000 at 250 kHz rate and 2000 at 50 kHz rate — comfortable margin.
N_VECTORS_250K = 10000;   % samples for 250 kHz-rate probes
N_VECTORS_50K  = 2000;    % samples for 50 kHz-rate probes

% FIR filter coefficients — must match the coefficients used in fm_demod_fixed
% AA LPF: 129-tap Kaiser-windowed FIR, cutoff 100 kHz at 250 kHz sample rate
h_aa    = fir1(128, 100e3/(250e3/2), 'low', kaiser(129, 8));
% Audio LPF: 129-tap Kaiser-windowed FIR, cutoff 15 kHz at 50 kHz sample rate
h_audio = fir1(128,  15e3/( 50e3/2), 'low', kaiser(129, 8));

% Probe signal definitions: {workspace_var, file_basename, word_bits, frac_bits, rate_kHz}
% Adjust formats if your model uses different word lengths.
% freqcorr_i and freqcorr_q are NOT extracted from model probes.
% The ic_out/qc_out To Workspace blocks log a frame-based signal (every 5
% samples) due to inherited sample time from the FreqCorr subsystem, causing
% duplicate golden values. Instead, we compute them analytically in Step 5b.
% Probes with >0% duplicates due to frame-based signal contamination:
%   ic_out, qc_out  : 22%  -> computed analytically in Step 5b
%   aa_i, aa_q      : 0.02% -> computed analytically in Step 5c
%   fm_disc         : 0.80% -> computed analytically in Step 5d
%   buf_out         : 0.80% -> not needed for VHDL testbench
%
% Only probes with clean 50 kHz outputs are extracted from the model:
%   fir_decimation, audio_lpf, audio_50k : 0.0009% -> acceptable
PROBES = {
    'fir_decimation', 'fir_dec',     32, 14,  50
    'audio_lpf',      'audio_lpf',   32, 14,  50
    'audio_50k',      'audio_50k',   32, 13,  50
};

%% ── STEP 1: Load WAV and build fi timeseries ─────────────────────────────
fprintf('=== Loading IQ data ===\n');
[raw, fs_wav] = audioread(WAV_FILE, 'native');
assert(fs_wav == FS_IQ, 'Sample rate mismatch: got %d expected %d', fs_wav, FS_IQ);
assert(size(raw,2) == 2, 'Expected 2-channel I/Q WAV');
if isfinite(MAX_SECONDS)
    raw = raw(1 : min(end, round(MAX_SECONDS * FS_IQ)), :);
end
n_samp  = size(raw, 1);
SIM_DUR = (n_samp - 1) / FS_IQ;
fprintf('  %d samples  (%.1f s at %.0f kHz)\n', n_samp, SIM_DUR, FS_IQ/1e3);

I_raw = double(raw(:,1)) / 32768;
Q_raw = double(raw(:,2)) / 32768;
t_iq  = (0:n_samp-1).' / FS_IQ;

nco_ph  = 2*pi*(-CARRIER_OFFSET)*t_iq;
nco_cos = cos(nco_ph);
nco_sin = sin(nco_ph);

% fixdt(1,16,15): matches 16-bit SDRplay ADC and Xilinx DDS Compiler output
FMT_IQ     = fixdt(1, 16, 15);
ts_I       = timeseries(fi(I_raw,   FMT_IQ), t_iq, 'Name', 'I_raw');
ts_Q       = timeseries(fi(Q_raw,   FMT_IQ), t_iq, 'Name', 'Q_raw');
ts_nco_cos = timeseries(fi(nco_cos, FMT_IQ), t_iq, 'Name', 'nco_cos');
ts_nco_sin = timeseries(fi(nco_sin, FMT_IQ), t_iq, 'Name', 'nco_sin');
fprintf('  fi workspace ready: fixdt(1,16,15)  LSB = 2^-15 = %.2e\n', 2^-15);

%% ── STEP 2: Load and configure model ────────────────────────────────────
fprintf('=== Loading model: %s ===\n', MDL);
if isempty(dir([MDL '.slx'])) && ~bdIsLoaded(MDL)
    error('%s.slx not found in %s — run convert_fp_designer.m first.', MDL, pwd);
end
if bdIsLoaded(MDL), close_system(MDL, 0); end
load_system(MDL);

% Force fresh simulation — prevent Simulink from reusing cached results
set_param(MDL, 'SimulationMode', 'normal');
set_param(MDL, 'StopTime',             num2str(SIM_DUR));
set_param(MDL, 'DataTypeOverride',     'UseLocalSettings');
set_param(MDL, 'MinMaxOverflowLogging','UseLocalSettings');
try, set_param(MDL, 'ProdHWDeviceType', 'ASIC/FPGA->ASIC/FPGA'); catch, end
warning('off', 'Simulink:blocks:ParameterPrecisionLoss');
warning('off', 'Simulink:Engine:ParameterPrecisionLoss');
try, set_param(MDL, 'ParameterPrecisionLoss', 'none'); catch, end

%% ── STEP 3: Run simulation ───────────────────────────────────────────────
fprintf('=== Running simulation (%.1f s at %.0f kHz) ===\n', SIM_DUR, FS_IQ/1e3);
out = sim(MDL);
fprintf('=== Simulation complete ===\n\n');

%% ── STEP 4: Extract and play audio ──────────────────────────────────────
fprintf('=== Audio output ===\n');

% Find audio_50k from sim output or base workspace
sig = [];
if isobject(out) && isprop(out,'audio_50k'),      sig = out.audio_50k;
elseif isstruct(out) && isfield(out,'audio_50k'), sig = out.audio_50k;
elseif exist('audio_50k','var'),                   sig = audio_50k; %#ok<NODEF>
end

if isempty(sig)
    fprintf('  audio_50k not found — check To Workspace block name.\n');
else
    if isstruct(sig) && isfield(sig,'signals'), sig = sig.signals.values; end
    sig = double(squeeze(sig)); if size(sig,2)>size(sig,1), sig=sig.'; end
    sig = sig(:);
    fprintf('  Raw: %d samples  range [%.0f, %.0f] Hz\n', ...
            length(sig), min(sig), max(sig));

    sig   = sig(51:end);                           % trim 1 ms startup
    [p,q] = rat(FS_AUDIO/FS_OUT, 1e-9);
    audio = resample(sig, p, q);
    audio = audio / (max(abs(audio))+eps) * 0.95;
    audio = max(min(audio,1),-1);

    if SAVE_WAV
        audiowrite('fm_audio_fixed.wav', audio, FS_AUDIO, 'BitsPerSample',16);
        fprintf('  Saved: fm_audio_fixed.wav\n');
    end
    if PLAY_AUDIO
        sound(audio, FS_AUDIO);
        fprintf('  Playing %.1f s ...\n', length(audio)/FS_AUDIO);
    end
end

%% ── STEP 5: Save probe vectors for VHDL testbenches ─────────────────────
if ~SAVE_VECTORS
    fprintf('\nVector save skipped (SAVE_VECTORS=false).\n');
    fprintf('=== Done ===\n');
    return;
end

fprintf('\n=== Saving probe vectors ===\n');
fprintf('%-20s  %-15s  %-15s  %s\n','Variable','Format','Rate','File');
fprintf('%s\n', repmat('-',75,1));

n_saved = 0;
for p = 1:size(PROBES,1)
    vname  = PROBES{p,1};
    bname  = PROBES{p,2};
    wl     = PROBES{p,3};
    fl     = PROBES{p,4};
    rate   = PROBES{p,5};
    fname  = sprintf('%s_golden.txt', bname);

    % Extract from out object first, then base workspace
    raw_sig = [];
    try
        if isobject(out) && isprop(out,vname),      raw_sig = out.(vname);
        elseif isstruct(out) && isfield(out,vname), raw_sig = out.(vname);
        elseif evalin('base',sprintf('exist(''%s'',''var'')',vname))
            raw_sig = evalin('base', vname);
        end
    catch, end

    if isempty(raw_sig)
        fprintf('  %-20s  [not found — add To Workspace block named ''%s'']\n', vname, vname);
        continue;
    end

    % Unwrap struct/timeseries, flatten to column vector
    if isstruct(raw_sig) && isfield(raw_sig,'signals'), raw_sig=raw_sig.signals.values; end
    raw_sig = double(squeeze(raw_sig));
    if size(raw_sig,2)>size(raw_sig,1), raw_sig=raw_sig.'; end
    raw_sig = raw_sig(:);

    % Trim to N_VECTORS based on signal rate
    if rate >= 200   % 250 kHz domain
        n_vec = min(N_VECTORS_250K, length(raw_sig));
    else             % 50 kHz domain
        n_vec = min(N_VECTORS_50K,  length(raw_sig));
    end
    raw_sig = raw_sig(1:n_vec);

    % Quantise to target format and write stored integers
    fm = fimath('RoundingMethod','Round','OverflowAction','Saturate');
    sig_fi   = fi(raw_sig, 1, wl, fl, fm);
    int_vals = storedInteger(sig_fi);
    fid = fopen(fname,'w');
    for k = 1:numel(int_vals)
        if k < numel(int_vals)
            fprintf(fid,'%d\n', int_vals(k));
        else
            fprintf(fid,'%d', int_vals(k));   % no trailing newline on last line
        end
    end
    fclose(fid);

    fprintf('  %-20s  fixdt(1,%2d,%2d)  %3.0f kHz  ->  %s  (%d samples)\n', ...
            vname, wl, fl, rate, fname, numel(int_vals));
    n_saved = n_saved + 1;
end

%% ── STEP 5b: Compute FreqCorr golden vectors analytically ───────────────
% Bypasses the ic_out/qc_out model probes which log at frame rate (every 5
% samples) due to inherited sample time, causing duplicate golden values.
% Correct golden: Ic = I*cos - Q*sin, Qc = I*sin + Q*cos computed from
% the same input timeseries used as stimulus.
fprintf('\n=== Computing FreqCorr golden vectors analytically ===\n');
N_fc  = N_VECTORS_250K;
I_fc  = double(ts_I.Data(1:N_fc));
Q_fc  = double(ts_Q.Data(1:N_fc));
C_fc  = double(ts_nco_cos.Data(1:N_fc));
S_fc  = double(ts_nco_sin.Data(1:N_fc));

ic_gold = I_fc .* C_fc - Q_fc .* S_fc;   % Ic = I*cos - Q*sin
qc_gold = I_fc .* S_fc + Q_fc .* C_fc;   % Qc = I*sin + Q*cos

% Save ic_gold and qc_gold to the same directory as this script so
% gen_fm_disc_vectors can find them regardless of MATLAB's current pwd.
run_and_extract_dir = fileparts(mfilename('fullpath'));
mat_save_path = fullfile(run_and_extract_dir, 'ic_qc_gold.mat');
save(mat_save_path, 'ic_gold', 'qc_gold');
fprintf('Saved: %s (ic_gold, qc_gold, %d samples)\n', mat_save_path, length(ic_gold));

fm_fc = fimath('RoundingMethod','Round','OverflowAction','Saturate');
ic_fi = double(storedInteger(fi(ic_gold, 1, 18, 17, fm_fc)));
qc_fi = double(storedInteger(fi(qc_gold, 1, 18, 17, fm_fc)));

fid = fopen('freqcorr_i_golden.txt','w');
for k = 1:N_fc
    if k < N_fc, fprintf(fid,'%d\n',ic_fi(k));
    else,         fprintf(fid,'%d',   ic_fi(k)); end
end
fclose(fid);
fid = fopen('freqcorr_q_golden.txt','w');
for k = 1:N_fc
    if k < N_fc, fprintf(fid,'%d\n',qc_fi(k));
    else,         fprintf(fid,'%d',   qc_fi(k)); end
end
fclose(fid);
fprintf('  freqcorr_i_golden.txt: %d samples\n', N_fc);
fprintf('  freqcorr_q_golden.txt: %d samples\n', N_fc);

%% ── STEP 5c: Compute AA LPF golden vectors analytically ─────────────────
% aa_i and aa_q have 0.02% duplicate rate from frame-based signal timing.
% For a 10000-sample test this causes ~2 failures. Recompute analytically
% using MATLAB filter() with the same coefficients as the Simulink model.
fprintf('\n=== Computing AA LPF golden vectors analytically ===\n');
N_aa = N_VECTORS_250K;

% AA LPF coefficients: same as used in the model
h_aa_q = double(fi(h_aa, fixdt(1,18,17)));  % quantised to sfix18_En17

% Input: FreqCorr output = Ic and Qc (already computed analytically)
% Use the analytical FreqCorr output as AA LPF input
I_fc2  = double(ts_I.Data(1:N_aa));
Q_fc2  = double(ts_Q.Data(1:N_aa));
C_fc2  = double(ts_nco_cos.Data(1:N_aa));
S_fc2  = double(ts_nco_sin.Data(1:N_aa));
ic_in  = I_fc2 .* C_fc2 - Q_fc2 .* S_fc2;
qc_in  = I_fc2 .* S_fc2 + Q_fc2 .* C_fc2;

% Apply AA LPF using quantised coefficients
aa_i_gold = filter(h_aa_q, 1, ic_in);
aa_q_gold = filter(h_aa_q, 1, qc_in);

% Write as sfix18_En17
% Cast to double before fprintf — storedInteger returns int32 which
% fprintf('%d',...) may mishandle as a fi object scalar.
fm_aa = fimath('RoundingMethod','Round','OverflowAction','Saturate');
aa_i_fi = double(storedInteger(fi(aa_i_gold, 1, 18, 17, fm_aa)));
aa_q_fi = double(storedInteger(fi(aa_q_gold, 1, 18, 17, fm_aa)));

fid = fopen('aa_lpf_i_golden.txt','w');
for k = 1:N_aa
    if k < N_aa, fprintf(fid,'%d\n',aa_i_fi(k));
    else,         fprintf(fid,'%d',   aa_i_fi(k)); end
end
fclose(fid);
fid = fopen('aa_lpf_q_golden.txt','w');
for k = 1:N_aa
    if k < N_aa, fprintf(fid,'%d\n',aa_q_fi(k));
    else,         fprintf(fid,'%d',   aa_q_fi(k)); end
end
fclose(fid);
fprintf('  aa_lpf_i_golden.txt: %d samples (analytical)\n', N_aa);
fprintf('  aa_lpf_q_golden.txt: %d samples (analytical)\n', N_aa);

%% ── STEP 5d: Compute FM discriminator golden vector analytically ──────────
% fm_disc has 0.80% duplicate rate. Compute from AA LPF output using
% the delay-and-multiply discriminator formula.
fprintf('\n=== Computing FM discriminator golden vector analytically ===\n');
N_fd = N_VECTORS_250K;

% Discriminator: atan2(Ic[n]*Qc[n-1] - Qc[n]*Ic[n-1],
%                      Ic[n]*Ic[n-1] + Qc[n]*Qc[n-1]) * fs/(2*pi)
% BUT: Simulink uses pi-normalised output (range -1 to 1) then scales
% by fs/2 = 125000. We use true atan2 (range -pi to pi) then scale
% by fs/(2*pi) = 39789. Result is in Hz.
% Note: Xilinx CORDIC v6.0 uses pi-normalised output, so on FPGA
% the gain is fs/2 = 125000 instead.

Ic = aa_i_gold;
Qc = aa_q_gold;
Ic_d = [0; Ic(1:end-1)];  % delayed by 1 sample
Qc_d = [0; Qc(1:end-1)];

num = Ic .* Qc_d - Qc .* Ic_d;  % cross product (numerator of atan2)
den = Ic .* Ic_d + Qc .* Qc_d;  % dot product   (denominator of atan2)

% atan2 output in radians, scale to Hz
% Simulink uses true radians (not pi-normalised) so gain = Fs/(2*pi)
FS_IQ = 250e3;
disc_gold = atan2(double(num), double(den)) * FS_IQ / (2*pi);

% Write as sfix32_En14 (range ±131072 Hz)
fm_fd = fimath('RoundingMethod','Round','OverflowAction','Saturate');
disc_fi = double(storedInteger(fi(disc_gold, 1, 32, 14, fm_fd)));

fid = fopen('fm_disc_golden.txt','w');
for k = 1:N_fd
    if k < N_fd, fprintf(fid,'%d\n',disc_fi(k));
    else,         fprintf(fid,'%d',   disc_fi(k)); end
end
fclose(fid);
fprintf('  fm_disc_golden.txt: %d samples (analytical)\n', N_fd);

%% ── STEP 6: Save input stimulus vectors ──────────────────────────────────
fprintf('\n=== Saving input stimulus vectors ===\n');

inputs = {
    ts_I,       'input_i',       16, 15, 250
    ts_Q,       'input_q',       16, 15, 250
    ts_nco_cos, 'input_nco_cos', 16, 15, 250
    ts_nco_sin, 'input_nco_sin', 16, 15, 250
};

for p = 1:size(inputs,1)
    ts_var = inputs{p,1};
    bname  = inputs{p,2};
    wl     = inputs{p,3};
    fl     = inputs{p,4};
    rate   = inputs{p,5};
    fname  = sprintf('%s_stimulus.txt', bname);

    if isa(ts_var,'timeseries'), raw_in = ts_var.Data;
    else,                         raw_in = ts_var;
    end
    raw_in = double(squeeze(raw_in(:)));
    raw_in = raw_in(1:min(N_VECTORS_250K, length(raw_in)));  % trim to N_VECTORS

    fm = fimath('RoundingMethod','Round','OverflowAction','Saturate');
    sig_fi   = fi(raw_in, 1, wl, fl, fm);
    int_vals = storedInteger(sig_fi);
    fid = fopen(fname,'w');
    for k = 1:numel(int_vals)
        if k < numel(int_vals)
            fprintf(fid,'%d\n', int_vals(k));
        else
            fprintf(fid,'%d', int_vals(k));   % no trailing newline on last line
        end
    end
    fclose(fid);

    fprintf('  %-20s  fixdt(1,%2d,%2d)  %3.0f kHz  ->  %s  (%d samples)\n', ...
            bname, wl, fl, rate, fname, numel(int_vals));
    n_saved = n_saved + 1;
end

%% ── STEP 7: Print VHDL constant block ───────────────────────────────────
fprintf('\n=== VHDL testbench constants ===\n');
fprintf('-- Paste into your testbench package or architecture declarative region\n\n');

all_sigs = [
    PROBES
    {'input_i',       'input_i',       16, 15, 250}
    {'input_q',       'input_q',       16, 15, 250}
    {'input_nco_cos', 'input_nco_cos', 16, 15, 250}
    {'input_nco_sin', 'input_nco_sin', 16, 15, 250}
];
for p = 1:size(all_sigs,1)
    bname = all_sigs{p,2};
    wl    = all_sigs{p,3};
    fl    = all_sigs{p,4};
    cname = upper(strrep(bname, '_', '_'));
    fprintf('constant C_%s_WL : integer := %d;  -- word length\n', cname, wl);
    fprintf('constant C_%s_FL : integer := %d;  -- fraction length\n', cname, fl);
end

fprintf('\n-- Usage in testbench:\n');
fprintf('--   file f_stim : text open read_mode  is "input_i_stimulus.txt";\n');
fprintf('--   file f_gold : text open read_mode  is "aa_lpf_i_golden.txt";\n');
fprintf('--   file f_dut  : text open write_mode is "aa_lpf_i_dut.txt";\n');

fprintf('\n=== Saved %d vectors ===\n', n_saved);
fprintf('=== Done ===\n');

%% ── STEP 8: Copy vector files to Vivado project directories ──────────────
vivado_dirs = {
    '../vivado/aa_lpf/'
    '../vivado/freq_corr/'
    '../vivado/nco/'
};
all_vecs = {
    'freqcorr_i_golden.txt', 'freqcorr_q_golden.txt', ...
    'aa_lpf_i_golden.txt',   'aa_lpf_q_golden.txt', ...
    'fm_disc_golden.txt', ...
    'fir_dec_golden.txt',    'audio_lpf_golden.txt',  'audio_50k_golden.txt', ...
    'input_i_stimulus.txt',  'input_q_stimulus.txt', ...
    'input_nco_cos_stimulus.txt', 'input_nco_sin_stimulus.txt'
};
fprintf('\n=== Copying vector files to Vivado directories ===\n');
for d = 1:numel(vivado_dirs)
    vdir = vivado_dirs{d};
    if exist(vdir, 'dir')
        for f = 1:numel(all_vecs)
            if exist(all_vecs{f}, 'file')
                copyfile(all_vecs{f}, vdir);
            end
        end
        fprintf('  Copied to: %s\n', vdir);
    else
        fprintf('  Skipped (not found): %s\n', vdir);
    end
end
