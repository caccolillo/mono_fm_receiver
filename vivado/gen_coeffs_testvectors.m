% gen_all_vectors.m
% Master script to regenerate all coefficient files and test vectors for the
% complete FM demodulator FPGA implementation.
%
% Run this script from the project root (mono_fm_receiver/vivado/) after
% running run_and_extract.m to generate ic_qc_gold.mat. It visits each
% sub-block directory in signal-chain order, generates the required assets,
% then returns to the root directory.
%
% Signal chain order:
%   AA LPF (x2, I and Q) -> FM Discriminator -> FIR Decimator ->
%   Audio LPF -> De-emphasis -> Full-chain stimulus
%
% Prerequisites:
%   - rds.wav must be on the MATLAB path or in the fm_demod/ directory
%   - run_and_extract.m must have been run at least once to generate
%     ic_qc_gold.mat in fixed_point_logging/
%
clc
fprintf('\n');
fprintf('================================================================\n');
fprintf('  FM Demodulator -- regenerating all coefficients and vectors  \n');
fprintf('================================================================\n\n');

root_dir = pwd;

%% Helper: run a script in a sub-directory, always returning to root_dir
run_in_dir = @(subdir, fn) ...
    evalin('caller', sprintf([ ...
        'try;' ...
        '  cd(fullfile(root_dir, ''%s''));' ...
        '  %s;' ...
        '  cd(root_dir);' ...
        'catch ME;' ...
        '  cd(root_dir);' ...
        '  warning(''Step failed: %%s'', ME.message);' ...
        'end'], subdir, fn));

%% ── 1. AA LPF ────────────────────────────────────────────────────────────
fprintf('--- [1/6] AA LPF: coefficients + impulse test vectors ---\n');
try
    cd(fullfile(root_dir, 'aa_lpf'));
    gen_aa_lpf_coe;
    fprintf('    AA LPF done.\n\n');
catch ME
    warning('    AA LPF FAILED: %s\n', ME.message);
end
cd(root_dir);

%% ── 2. Audio LPF ─────────────────────────────────────────────────────────
fprintf('--- [2/6] Audio LPF: coefficients + impulse test vectors ---\n');
try
    cd(fullfile(root_dir, 'audio_lpf'));
    audio_lpf_coeffs;
    gen_audio_lpf_impulse_test;
    fprintf('    Audio LPF done.\n\n');
catch ME
    warning('    Audio LPF FAILED: %s\n', ME.message);
end
cd(root_dir);

%% ── 3. De-emphasis ───────────────────────────────────────────────────────
fprintf('--- [3/6] De-emphasis IIR: test vectors ---\n');
try
    cd(fullfile(root_dir, 'de_emphasis'));
    gen_de_emph_test;
    fprintf('    De-emphasis done.\n\n');
catch ME
    warning('    De-emphasis FAILED: %s\n', ME.message);
end
cd(root_dir);

%% ── 4. FIR Decimator ─────────────────────────────────────────────────────
fprintf('--- [4/6] FIR Decimator: coefficients + impulse test vectors ---\n');
try
    cd(fullfile(root_dir, 'fir_decimation'));
    fir_dec_coeffs;
    gen_fir_dec_impulse_test;
    fprintf('    FIR Decimator done.\n\n');
catch ME
    warning('    FIR Decimator FAILED: %s\n', ME.message);
end
cd(root_dir);

%% ── 5. FM Discriminator ──────────────────────────────────────────────────
fprintf('--- [5/6] FM Discriminator: test vectors ---\n');
fprintf('    (loads ic_gold/qc_gold from ic_qc_gold.mat if not in workspace)\n');
try
    cd(fullfile(root_dir, 'fm_disc'));
    gen_fm_disc_vectors;
    fprintf('    FM Discriminator done.\n\n');
catch ME
    warning('    FM Discriminator FAILED: %s\n', ME.message);
end
cd(root_dir);

%% ── 6. Full-chain RTL stimulus ───────────────────────────────────────────
fprintf('--- [6/6] Full-chain RTL stimulus from rds.wav ---\n');
try
    cd(fullfile(root_dir, 'fm_demod'));
    gen_fm_demod_stimulus;
    fprintf('    Full-chain stimulus done.\n\n');
catch ME
    warning('    Full-chain stimulus FAILED: %s\n', ME.message);
end
cd(root_dir);

%% ── End ──────────────────────────────────────────────────────────────
close all;
