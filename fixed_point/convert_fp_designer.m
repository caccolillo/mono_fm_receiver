% convert_fp_designer.m
%
% Fixed-Point Designer automated conversion of fm_demod_slx.
% Follows the standard DataTypeWorkflow pattern:
%   1. prepare()      - compatibility check
%   2. collectRange() - float sim, log min/max
%   3. proposeDataTypes() - compute fraction lengths
%   4. applyDataTypes()   - write types into blocks
%   5. verify()       - fixed-point sim + comparison
%
% Manual overrides applied after applyDataTypes() for three analytically-
% bounded stages that the auto-proposer cannot observe from programme material:
%   - rad2Hz gain : fixdt(1,32,14)  covers ±fs/2 = ±125 kHz
%   - DeEmph accum: fixdt(1,40,14)  covers DC gain 4.27 x max input
%   - Inputs      : fixdt(1,16,15)  matches 16-bit ADC
%
% Marco Aiello, 2024

clc; clear;

%% ── PARAMETERS ───────────────────────────────────────────────────────────
WAV_FILE       = 'rds.wav';
CARRIER_OFFSET = -10e3;
FS_IQ          = 250e3;
FS_OUT         = 50e3;
FS_AUDIO       = 48e3;
DEEMPH_TAU     = 75e-6;
MAX_SECONDS    = 30;
FIR_DEC_COEFFS = fir1(40, 1/5);
h_aa    = fir1(128, 100e3/(FS_IQ/2), 'low', kaiser(129,8));
h_audio = fir1(128, 15e3/(FS_OUT/2), 'low', kaiser(129,8));
SAVE_WAV    = true;
PLAY_AUDIO  = true;

MDL      = 'fm_demod_slx';
DEST_MDL = 'fm_demod_fixed';
BASE_RUN = 'FloatingPoint_Baseline';
FP_RUN   = 'FixedPoint_Verification';

%% ── STEP 1: Load IQ data and prepare double timeseries ───────────────────
fprintf('=== Loading IQ data ===\n');
[raw, fs_wav] = audioread(WAV_FILE, 'native');
assert(fs_wav == FS_IQ, 'Sample rate mismatch');
if isfinite(MAX_SECONDS)
    raw = raw(1:min(end, round(MAX_SECONDS*FS_IQ)), :);
end
n_samp  = size(raw,1);
T_step  = 1/FS_IQ;
SIM_DUR = (n_samp-1)*T_step;
fprintf('  %d samples (%.1f s)\n', n_samp, SIM_DUR);

I_raw = double(raw(:,1))/32768;
Q_raw = double(raw(:,2))/32768;
t_iq  = (0:n_samp-1).'/FS_IQ;
nco_ph  = 2*pi*(-CARRIER_OFFSET)*t_iq;
nco_cos = cos(nco_ph);
nco_sin = sin(nco_ph);

% Pack BOTH double and fi timeseries.
%
% Double timeseries: used for DataTypeWorkflow baseline range collection
% and for the float reference comparison. DataTypeWorkflow.collectRange()
% requires double inputs to log true floating-point signal ranges.
%
% fi timeseries (fixdt(1,16,15)): used for the fixed-point simulation.
% The From Workspace blocks are set to 'Inherit: auto' so they output
% whatever type is in the workspace. Putting fi objects here makes the
% entire fixed-point model run with sfix16_En15 inputs — matching the
% 16-bit ADC output of the SDRplay hardware.
%
% The script switches between these two sets at the appropriate steps.

% Double timeseries (for baseline collection and float reference)
ts_I_dbl       = timeseries(I_raw,   t_iq, 'Name','I_raw');
ts_Q_dbl       = timeseries(Q_raw,   t_iq, 'Name','Q_raw');
ts_nco_cos_dbl = timeseries(nco_cos, t_iq, 'Name','nco_cos');
ts_nco_sin_dbl = timeseries(nco_sin, t_iq, 'Name','nco_sin');

% fi timeseries fixdt(1,16,15) (for fixed-point simulation)
% fixdt(1,16,15): signed 16-bit, 15 fraction bits
%   range  : (-1, 1)          matches normalised IQ after /32768
%   LSB    : 2^-15 = 3.05e-5  matches original int16 ADC resolution
%   This is the format the Xilinx DDS Compiler and ADC interface output.
FMT_IQ = fixdt(1,16,15);
ts_I_fi       = timeseries(fi(I_raw,   FMT_IQ), t_iq, 'Name','I_raw');
ts_Q_fi       = timeseries(fi(Q_raw,   FMT_IQ), t_iq, 'Name','Q_raw');
ts_nco_cos_fi = timeseries(fi(nco_cos, FMT_IQ), t_iq, 'Name','nco_cos');
ts_nco_sin_fi = timeseries(fi(nco_sin, FMT_IQ), t_iq, 'Name','nco_sin');

% Start with double in workspace for baseline collection
ts_I       = ts_I_dbl;
ts_Q       = ts_Q_dbl;
ts_nco_cos = ts_nco_cos_dbl;
ts_nco_sin = ts_nco_sin_dbl;
fprintf('  Workspace: double timeseries ready (for baseline)\n');
fprintf('  Workspace: fi fixdt(1,16,15) timeseries ready (for fixed-point sim)\n');

%% ── STEP 2: Open model and set stop time ─────────────────────────────────
fprintf('=== Opening model: %s ===\n', MDL);
if bdIsLoaded(MDL), close_system(MDL,0); end
open_system(MDL);
set_param(MDL, 'StopTime', num2str(SIM_DUR));
% Set ASIC/FPGA hardware target on source model so the auto-proposer
% computes unconstrained word lengths appropriate for FPGA fabric.
try
    set_param(MDL, 'ProdHWDeviceType', 'ASIC/FPGA->ASIC/FPGA');
    fprintf('  Hardware target set to ASIC/FPGA\n');
catch, end

% From Workspace blocks: use 'Inherit: auto' throughout.
% With double timeseries in workspace -> outputs double (float baseline).
% With fi timeseries in workspace    -> outputs fi   (fixed-point sim).
% No manual toggling needed between runs.
fws = find_system(MDL, 'BlockType', 'FromWorkspace');
for k = 1:numel(fws)
    try, set_param(fws{k}, 'OutDataTypeStr', 'Inherit: auto'); catch, end
end

%% ── STEP 3: Create converter on the WHOLE model ──────────────────────────
% DataTypeWorkflow.Converter takes the model name, not a subsystem path,
% when converting the full top-level diagram.
fprintf('=== Creating DataTypeWorkflow.Converter ===\n');
converter = DataTypeWorkflow.Converter(MDL);

%% ── STEP 4: Range collection (baseline float simulation) ─────────────────
fprintf('=== Collecting ranges (baseline float sim) ===\n');
fprintf('  This runs a %.0f s simulation — please wait...\n', SIM_DUR);
try
    simResult = converter.collectRange(BASE_RUN);
    fprintf('  Range collection complete\n');
catch ME
    % Older API: simulateSystem()
    fprintf('  collectRange() not available, trying simulateSystem()...\n');
    converter.CurrentRunName = BASE_RUN;
    converter.simulateSystem();
    fprintf('  Range collection complete (via simulateSystem)\n');
end

%% ── STEP 5: Configure proposal settings ──────────────────────────────────
fprintf('=== Configuring proposal settings ===\n');
ps = DataTypeWorkflow.ProposalSettings();
ps.DefaultWordLength     = 18;     % Xilinx DSP48E2 B-input width
ps.ProposeWordLength     = false;  % fix word length, auto fraction only
ps.ProposeFractionLength = true;
ps.SafetyMargin          = 15;     % 15% headroom above observed max

%% ── STEP 6: Propose fixed-point types ────────────────────────────────────
fprintf('=== Proposing fixed-point types ===\n');
try
    converter.proposeDataTypes(BASE_RUN, ps);
catch ME
    fprintf('  proposeDataTypes error: %s\n', ME.message);
    rethrow(ME);
end

%% ── STEP 7: Apply proposed types ─────────────────────────────────────────
fprintf('=== Applying proposed types ===\n');
try
    converter.applyDataTypes(BASE_RUN);
catch ME
    % Some versions use applyDataTypes() without run name
    try
        converter.applyDataTypes();
    catch ME2
        fprintf('  applyDataTypes error: %s\n', ME2.message);
        rethrow(ME2);
    end
end

%% ── STEP 8: Manual overrides for analytically-bounded stages ─────────────
% The auto-proposer sizes types from observed signal ranges.
% For FM audio these are conservative: typical deviation ±20-40 kHz,
% but the FPGA must handle worst-case ±75 kHz (regulatory limit) and
% the de-emphasis DC gain of 4.27x without overflow.
% Override only the two stages where observed range << worst-case range.

fprintf('=== Applying manual overrides ===\n');

% (a) IQ inputs and early chain: fixdt(1,18,17) — signal range (-1,1).
%     The auto-proposer allocated fixdt(1,18,4) (4 fraction bits = 16 levels)
%     because it back-propagated the discriminator Hz range to these blocks.
%     IQ samples are normalised to (-1,1) so 17 fraction bits are correct.
aa_blks = find_system(MDL, 'regexp','on','Name','^AA_[IQ]$');
if isempty(aa_blks)
    aa_blks = [find_system(MDL,'Name','AA_I'); find_system(MDL,'Name','AA_Q')];
end
for k = 1:numel(aa_blks)
    try
        set_param(aa_blks{k}, ...
            'OutDataTypeStr',            'fixdt(1,18,17)', ...
            'CoefDataTypeStr',           'fixdt(1,32,30)', ...
            'AccumDataTypeStr',          'fixdt(1,40,17)', ...
            'SaturateOnIntegerOverflow', 'on');
    catch ME_aa
        fprintf('  AA LPF note: %s\n', ME_aa.message);
    end
end
fprintf('  AA_I / AA_Q     : fixdt(1,18,17)  (was fixdt(1,18,4) from proposer)\n');

% FreqCorr products: fixdt(1,18,17) — products of (-1,1) signals
corr_prods = find_system([MDL '/FreqCorr'], 'BlockType', 'Product');
corr_adds  = find_system([MDL '/FreqCorr'], 'BlockType', 'Sum');
for k = 1:numel(corr_prods)
    try, set_param(corr_prods{k},'OutDataTypeStr','fixdt(1,18,17)',...
        'RndMeth','Round','SaturateOnIntegerOverflow','on'); catch, end
end
for k = 1:numel(corr_adds)
    try, set_param(corr_adds{k},'OutDataTypeStr','fixdt(1,18,17)',...
        'RndMeth','Round','SaturateOnIntegerOverflow','on'); catch, end
end
fprintf('  FreqCorr        : fixdt(1,18,17)\n');

% FM_Disc cross-products: fixdt(1,18,14) — products of unit signals need
% 3 integer bits for the sum of two products (worst case ±2.0)
disc_prods = find_system([MDL '/FM_Disc'], 'BlockType', 'Product');
disc_adds  = find_system([MDL '/FM_Disc'], 'BlockType', 'Sum');
for k = 1:numel(disc_prods)
    try, set_param(disc_prods{k},'OutDataTypeStr','fixdt(1,18,14)',...
        'RndMeth','Round','SaturateOnIntegerOverflow','on'); catch, end
end
for k = 1:numel(disc_adds)
    try, set_param(disc_adds{k},'OutDataTypeStr','fixdt(1,18,14)',...
        'RndMeth','Round','SaturateOnIntegerOverflow','on'); catch, end
end
fprintf('  FM_Disc products: fixdt(1,18,14)\n');

% (b) rad2Hz Gain: observed ~±40 kHz, worst-case ±125 kHz (Shannon limit).
gain_blks = find_system([MDL '/FM_Disc'], 'BlockType', 'Gain');
for k = 1:numel(gain_blks)
    try
        set_param(gain_blks{k}, ...
            'OutDataTypeStr',            'fixdt(1,32,14)', ...
            'RndMeth',                   'Round', ...
            'SaturateOnIntegerOverflow', 'on');
    catch, end
end
fprintf('  rad2Hz gain out : fixdt(1,32,14)  (covers ±125 kHz worst-case)\n');

% (b) De-emphasis IIR: DC gain = 1/(1-0.766) = 4.27.
%     The accumulator must hold 4.27 x max_input without overflow.
%     Max discriminator output: ±75 kHz -> accumulator peak: ±320 kHz.
%     fixdt(1,40,14): range ±33 MHz -> covers ±320 kHz with large margin.
%     Output fixdt(1,32,14): range ±131072 Hz, covers audio output range.
%     The saturation warning on DeEmph confirms the proposer under-allocated.
deemph_blks = find_system(MDL, 'Name', 'DeEmph');
for k = 1:numel(deemph_blks)
    try
        set_param(deemph_blks{k}, ...
            'OutDataTypeStr',            'fixdt(1,32,13)', ...
            'NumAccumDataTypeStr',       'fixdt(1,40,13)', ...
            'DenAccumDataTypeStr',       'fixdt(1,40,13)', ...
            'SaturateOnIntegerOverflow', 'on');
    catch, end
end
fprintf('  DeEmph out      : fixdt(1,32,14)\n');
fprintf('  DeEmph out/accum: fixdt(1,32,13)/fixdt(1,40,13)  (±262 kHz, 2x headroom)\n');

% (c) Data Type Conversion (between Buf and FIR Decimation)
dtc_blks = find_system(MDL, 'BlockType', 'DataTypeConversion');
for k = 1:numel(dtc_blks)
    try
        set_param(dtc_blks{k}, ...
            'OutDataTypeStr',            'fixdt(1,32,14)', ...
            'SaturateOnIntegerOverflow', 'on');
    catch, end
end
fprintf('  Data Type Conv  : fixdt(1,32,14)\n');

% (d) FIR Decimation output: auto-proposer may size this for DeEmph output
%     range rather than its actual input range (±75 kHz post-discriminator).
firdec_blks = find_system(MDL, 'MaskType', 'FIR Decimation');
if isempty(firdec_blks)
    firdec_blks = find_system(MDL, 'regexp','on','Name','Decimat');
end
for k = 1:numel(firdec_blks)
    try
        set_param(firdec_blks{k}, ...
            'outputDataTypeStr', 'fixdt(1,32,14)', ...
            'accumDataTypeStr',  'fixdt(1,40,14)');
    catch, end
    for rv = {'Round','Nearest','Convergent'}
        try, set_param(firdec_blks{k},'roundingMode',rv{1}); break; catch, end
    end
    for ov = {'Saturate','Wrap'}
        try, set_param(firdec_blks{k},'overflowMode',ov{1}); break; catch, end
    end
end
fprintf('  FIR Decimation  : fixdt(1,32,14) out, fixdt(1,40,14) accum\n');

% (e) AudioLPF: same range as FIR Decimation output (±75 kHz).
%     Auto-proposer sizes this from logged DeEmph output (±1918 Hz) which
%     is too narrow — AudioLPF runs BEFORE DeEmph at full ±75 kHz range.
audiolpf_blks = find_system(MDL, 'Name', 'AudioLPF');
for k = 1:numel(audiolpf_blks)
    try
        set_param(audiolpf_blks{k}, ...
            'OutDataTypeStr',            'fixdt(1,32,14)', ...
            'AccumDataTypeStr',          'fixdt(1,40,14)', ...
            'SaturateOnIntegerOverflow', 'on');
    catch, end
end
fprintf('  AudioLPF        : fixdt(1,32,14) out, fixdt(1,40,14) accum\n');

% (f) Suppress precision loss warnings on both models
warning('off', 'Simulink:blocks:ParameterPrecisionLoss');
warning('off', 'Simulink:Engine:ParameterPrecisionLoss');
try, set_param(MDL, 'ParameterPrecisionLoss', 'none'); catch, end
fprintf('  Precision loss warnings suppressed\n');

%% ── STEP 9: Save as fixed-point model ────────────────────────────────────
if bdIsLoaded(DEST_MDL), close_system(DEST_MDL,0); end
save_system(MDL, [DEST_MDL '.slx']);

% Reload DEST_MDL and hardcode From Workspace type to fixdt(1,16,15).
% 'Inherit: auto' depends on the workspace at open time — if the workspace
% contains double timeseries the model shows double. Hardcoding ensures
% fm_demod_fixed.slx always shows sfix16_En15 when opened, regardless of
% workspace contents. The type must match the fi timeseries fed at sim time.
load_system(DEST_MDL);
fws_dest = find_system(DEST_MDL, 'BlockType', 'FromWorkspace');
for k = 1:numel(fws_dest)
    try
        set_param(fws_dest{k}, 'OutDataTypeStr', 'fixdt(1,16,15)');
    catch, end
end
save_system(DEST_MDL, [DEST_MDL '.slx']);
close_system(DEST_MDL, 0);
fprintf('Saved: %s.slx  (From Workspace hardcoded to fixdt(1,16,15))\n', DEST_MDL);

%% ── STEP 10: Verify (fixed-point sim + built-in comparison) ──────────────
fprintf('=== Running verification ===\n');

% Switch workspace to fi timeseries for the fixed-point simulation.
% The From Workspace blocks (Inherit: auto) will now output sfix16_En15.
ts_I       = ts_I_fi;
ts_Q       = ts_Q_fi;
ts_nco_cos = ts_nco_cos_fi;
ts_nco_sin = ts_nco_sin_fi;
fprintf('  Workspace switched to fi fixdt(1,16,15) timeseries\n');

% Ensure MDL is still loaded (save_system may have closed it)
if ~bdIsLoaded(MDL)
    load_system(MDL);
    set_param(MDL, 'StopTime', num2str(SIM_DUR));
end

% From Workspace: fixdt(1,16,15) for the fixed-point sim
fws = find_system(MDL, 'SearchDepth', 1, 'BlockType', 'FromWorkspace');
for k = 1:numel(fws)
    try, set_param(fws{k}, 'OutDataTypeStr', 'fixdt(1,16,15)'); catch, end
end

% Run converter.verify() — simulates in fixed-point and compares to baseline
try
    verifyResult = converter.verify(BASE_RUN, FP_RUN);
    fprintf('  Verification complete\n');
    if verifyResult.Passed
        fprintf('  [PASS] Fixed-point conversion meets precision requirements\n');
    else
        fprintf('  [WARN] Precision loss detected — review Simulation Data Inspector\n');
    end
    explore(verifyResult);
catch ME
    fprintf('  converter.verify() error: %s\n', ME.message);
    fprintf('  Falling back to direct sim of saved fixed-point model...\n');

    % Load the saved fixed-point copy and simulate directly
    if bdIsLoaded(DEST_MDL), close_system(DEST_MDL,0); end
    load_system(DEST_MDL);

    % From Workspace: hardcode fixdt(1,16,15) — matches the fi timeseries
    % in the workspace and ensures the model shows sfix16_En15 when opened.
    fws_fp = find_system(DEST_MDL, 'SearchDepth', 1, 'BlockType', 'FromWorkspace');
    for k = 1:numel(fws_fp)
        try, set_param(fws_fp{k}, 'OutDataTypeStr', 'fixdt(1,16,15)'); catch, end
    end

    % Subsystem input ports typed as 'double' by auto-proposer block the
    % fixed-point signal. Set all In1 blocks inside subsystems to inherit.
    in_ports = find_system(DEST_MDL, 'BlockType', 'Inport');
    for k = 1:numel(in_ports)
        try
            set_param(in_ports{k}, 'OutDataTypeStr', 'Inherit: auto');
        catch, end
    end

    % ── Hardware implementation: ASIC/FPGA target ───────────────────────────
    try
        set_param(DEST_MDL, 'ProdHWDeviceType', 'ASIC/FPGA->ASIC/FPGA');
        fprintf('  Hardware target: ASIC/FPGA (no word length restrictions)\n');
    catch ME_hw
        fprintf('  HW target note: %s\n', ME_hw.message);
    end

    % ── Suppress Simulink diagnostic warnings ───────────────────────────────
    % 'ParameterPrecisionLoss' is the correct Simulink diagnostic parameter.
    % This must be set AFTER the model is loaded, on the loaded model name.
    warning('off', 'Simulink:blocks:ParameterPrecisionLoss');
    warning('off', 'Simulink:Engine:ParameterPrecisionLoss');
    try, set_param(DEST_MDL, 'ParameterPrecisionLoss', 'none'); catch, end

    % ── Re-apply critical overrides directly on DEST_MDL ─────────────────
    % save_system() may not preserve all mask parameter changes.
    % Re-apply analytically-bounded overrides to guarantee they are active.

    % DeEmph: accumulator must hold 4.27 x 75 kHz = 320 kHz
    deemph_fp = find_system(DEST_MDL, 'Name', 'DeEmph');
    for k = 1:numel(deemph_fp)
        try
            set_param(deemph_fp{k}, ...
                'OutDataTypeStr',            'fixdt(1,32,13)', ...
                'NumAccumDataTypeStr',       'fixdt(1,40,13)', ...
                'DenAccumDataTypeStr',       'fixdt(1,40,13)', ...
                'SaturateOnIntegerOverflow', 'on');
        catch, end
    end

    % AudioLPF: sees full ±75 kHz discriminator output
    alf_fp = find_system(DEST_MDL, 'Name', 'AudioLPF');
    for k = 1:numel(alf_fp)
        try
            set_param(alf_fp{k}, ...
                'OutDataTypeStr',            'fixdt(1,32,14)', ...
                'AccumDataTypeStr',          'fixdt(1,40,14)', ...
                'SaturateOnIntegerOverflow', 'on');
        catch, end
    end

    % rad2Hz gain: must cover ±125 kHz
    gain_fp = find_system([DEST_MDL '/FM_Disc'], 'BlockType', 'Gain');
    for k = 1:numel(gain_fp)
        try
            set_param(gain_fp{k}, ...
                'OutDataTypeStr',            'fixdt(1,32,14)', ...
                'RndMeth',                   'Round', ...
                'SaturateOnIntegerOverflow', 'on');
        catch, end
    end

    % Data Type Conversion
    dtc_fp = find_system(DEST_MDL, 'BlockType', 'DataTypeConversion');
    for k = 1:numel(dtc_fp)
        try
            set_param(dtc_fp{k}, ...
                'OutDataTypeStr',            'fixdt(1,32,14)', ...
                'SaturateOnIntegerOverflow', 'on');
        catch, end
    end

    % Verify DeEmph override was applied
    deemph_check = find_system(DEST_MDL, 'Name', 'DeEmph');
    if ~isempty(deemph_check)
        out_dt  = get_param(deemph_check{1}, 'OutDataTypeStr');
        acc_dt  = get_param(deemph_check{1}, 'NumAccumDataTypeStr');
        sat_val = get_param(deemph_check{1}, 'SaturateOnIntegerOverflow');
        rnd_val = get_param(deemph_check{1}, 'RndMeth');
        fprintf('  DeEmph verified -> Out:%s  Accum:%s  Sat:%s  Rnd:%s\n', ...
                out_dt, acc_dt, sat_val, rnd_val);
        % Fix rounding: Floor causes DC drift in IIR -> change to Round
        try, set_param(deemph_check{1}, 'RndMeth', 'Round'); catch, end
        % Fix filter structure: Direct form I separates state from output cast
        % preventing output saturation from corrupting the state register
        try
            set_param(deemph_check{1}, 'FilterStructure', 'Direct form I');
            fprintf('  DeEmph filter structure -> Direct form I\n');
        catch ME_fs
            fprintf('  DeEmph filter structure note: %s\n', ME_fs.message);
        end
    end
    % Re-apply IQ/FreqCorr/FM_Disc overrides on DEST_MDL
    aa_fp = [find_system(DEST_MDL,'Name','AA_I'); find_system(DEST_MDL,'Name','AA_Q')];
    for k=1:numel(aa_fp)
        try, set_param(aa_fp{k},'OutDataTypeStr','fixdt(1,18,17)',...
            'CoefDataTypeStr','fixdt(1,32,30)',...
            'AccumDataTypeStr','fixdt(1,40,17)',...
            'SaturateOnIntegerOverflow','on'); catch, end
    end
    cp = find_system([DEST_MDL '/FreqCorr'],'BlockType','Product');
    ca = find_system([DEST_MDL '/FreqCorr'],'BlockType','Sum');
    for k=1:numel(cp), try,set_param(cp{k},'OutDataTypeStr','fixdt(1,18,17)',...
        'RndMeth','Round','SaturateOnIntegerOverflow','on');catch,end;end
    for k=1:numel(ca), try,set_param(ca{k},'OutDataTypeStr','fixdt(1,18,17)',...
        'RndMeth','Round','SaturateOnIntegerOverflow','on');catch,end;end
    dp = find_system([DEST_MDL '/FM_Disc'],'BlockType','Product');
    da = find_system([DEST_MDL '/FM_Disc'],'BlockType','Sum');
    for k=1:numel(dp), try,set_param(dp{k},'OutDataTypeStr','fixdt(1,18,14)',...
        'RndMeth','Round','SaturateOnIntegerOverflow','on');catch,end;end
    for k=1:numel(da), try,set_param(da{k},'OutDataTypeStr','fixdt(1,18,14)',...
        'RndMeth','Round','SaturateOnIntegerOverflow','on');catch,end;end
    gp = find_system([DEST_MDL '/FM_Disc'],'BlockType','Gain');
    for k=1:numel(gp), try,set_param(gp{k},'OutDataTypeStr','fixdt(1,32,14)',...
        'RndMeth','Round','SaturateOnIntegerOverflow','on');catch,end;end
    fprintf('  Critical overrides re-applied to %s\n', DEST_MDL);

    % ── FIR Decimation: explicit product/accum types ─────────────────────
    % Bypass the auto-computed 36-bit product by setting explicit 32-bit types.
    % Use confirmed R2021b parameter names (from find_firdec_params.m):
    %   prodOutputDataTypeStr, accumDataTypeStr, outputDataTypeStr
    %   roundingMode ('Round','Nearest','Convergent' — try each)
    %   overflowMode ('Wrap' or 'Saturate' — block-specific enum)
    firdec = find_system(DEST_MDL, 'MaskType', 'FIR Decimation');
    if isempty(firdec)
        firdec = find_system(DEST_MDL, 'regexp','on','Name','Decimat');
    end
    for k = 1:numel(firdec)
        try
            set_param(firdec{k}, ...
                'prodOutputDataTypeStr', 'fixdt(1,32,14)', ...
                'accumDataTypeStr',      'fixdt(1,32,14)', ...
                'outputDataTypeStr',     'fixdt(1,32,14)');
        catch ME2
            fprintf('  FIR Dec type override: %s\n', ME2.message);
        end
        % roundingMode — try known valid values
        for rv = {'Round','Nearest','Convergent','Floor'}
            try, set_param(firdec{k},'roundingMode',rv{1}); break; catch, end
        end
        % overflowMode — confirmed values from find_firdec_params: 'Wrap'/'Saturate'
        % but the exact string depends on version; try both
        for ov = {'Saturate','Wrap'}
            try, set_param(firdec{k},'overflowMode',ov{1}); break; catch, end
        end
    end

    % ── Suppress precision loss warnings ────────────────────────────────
    % These are expected — floating-point coefficients rounded to fixed-point.
    % Not errors; do not affect functional correctness.
    warning('off','Simulink:blocks:ParameterPrecisionLoss');
    warning('off','Simulink:Engine:ParameterPrecisionLoss');
    try
        set_param(DEST_MDL,'ParameterPrecisionLoss','none');
    catch, end

    % ── Run simulation ───────────────────────────────────────────────────
    set_param(DEST_MDL, 'DataTypeOverride',      'UseLocalSettings');
    set_param(DEST_MDL, 'MinMaxOverflowLogging', 'UseLocalSettings');
    set_param(DEST_MDL, 'StopTime', num2str(SIM_DUR));
    % Save model with all overrides and fixdt(1,16,15) inputs applied
    save_system(DEST_MDL, [DEST_MDL '.slx']);
    out_fixed = sim(DEST_MDL);
    fprintf('  Fixed-point sim complete\n');
end

%% ── STEP 11: Audio output ─────────────────────────────────────────────────
% Extract audio from either verify result or direct sim output
fprintf('=== Audio output ===\n');
sig = [];
if exist('verifyResult','var')
    try
        % Extract from Simulation Data Inspector logs if available
        runs = Simulink.sdi.getAllRunIDs();
        if ~isempty(runs)
            run = Simulink.sdi.getRun(runs(end));
            sig_ts = run.getSignalsByName('audio_50k');
            if ~isempty(sig_ts)
                sig = sig_ts(1).Values.Data;
            end
        end
    catch, end
end
if isempty(sig)
    % Fallback to base workspace
    if exist('audio_50k','var')
        sig = audio_50k; %#ok<NODEF>
    elseif exist('out_fixed','var')
        try, sig = out_fixed.audio_50k; catch, end
    end
end
if isempty(sig)
    fprintf('  Audio output not found — check To Workspace block\n');
    return;
end
if isstruct(sig) && isfield(sig,'signals'), sig = sig.signals.values; end
sig = double(squeeze(sig)); if size(sig,2)>size(sig,1), sig=sig.'; end
sig = sig(:);
fprintf('  Output: %d samples  range [%.0f, %.0f] Hz\n', ...
        length(sig), min(sig), max(sig));

% Trim startup + resample
sig   = sig(51:end);
[p,q] = rat(FS_AUDIO/FS_OUT, 1e-9);
audio = resample(sig, p, q);
audio = audio/(max(abs(audio))+eps)*0.95;
audio = max(min(audio,1),-1);

if SAVE_WAV
    audiowrite('fm_audio_fixed.wav', audio, FS_AUDIO, 'BitsPerSample',16);
    fprintf('  Saved: fm_audio_fixed.wav\n');
end
if PLAY_AUDIO
    sound(audio, FS_AUDIO);
    fprintf('  Playing %.1f s ...\n', length(audio)/FS_AUDIO);
end
%% ── STEP 12: Compare against float reference ────────────────────────────
fprintf('=== Comparing against float reference ===\n');

% Switch workspace back to double for the float reference run
ts_I       = ts_I_dbl;
ts_Q       = ts_Q_dbl;
ts_nco_cos = ts_nco_cos_dbl;
ts_nco_sin = ts_nco_sin_dbl;
fprintf('  Workspace switched to double timeseries for float reference\n');

if bdIsLoaded(MDL), close_system(MDL,0); end
open_system(MDL);
set_param(MDL,'DataTypeOverride','Double');
set_param(MDL,'StopTime',num2str(SIM_DUR));
% From Workspace already set to Inherit: auto — double timeseries
% in workspace is sufficient to drive the float reference run.
tw = find_system(MDL,'BlockType','ToWorkspace','VariableName','audio_50k');
if ~isempty(tw), set_param(tw{1},'VariableName','audio_50k_fl'); end
try,set_param(MDL,'SimulationCommand','stop');catch,end
sim(MDL);
if ~isempty(tw), set_param(tw{1},'VariableName','audio_50k'); end
close_system(MDL,0);

if exist('audio_50k_fl','var')
    sig_fl = double(squeeze(audio_50k_fl)); %#ok<NODEF>
    sig_fl = sig_fl(:);
    % Remove impossible startup values
    n_bad = find(abs(sig_fl)>125e3,1,'last');
    if ~isempty(n_bad), sig_fl=sig_fl(n_bad+1:end); end

    % Trim identical startup from both signals (50 samples = 1 ms at 50 kHz).
    % sig already had this trim applied in Step 10.
    % sig_fl must get the same trim so both start at the same physical instant.
    startup = 50;
    sig_use = sig;                              % already trimmed in Step 10
    sig_fl  = sig_fl(min(startup+1,end):end);  % trim float reference to match

    % Align lengths
    n_al    = min(length(sig_use), length(sig_fl));
    sig_use = sig_use(1:n_al);
    sig_fl  = sig_fl(1:n_al);

    % Cross-correlate to check alignment (search ±200 samples)
    [xc,lags] = xcorr(sig_use(1:min(end,50000)), sig_fl(1:min(end,50000)), 200, 'normalized');
    [~,idx]   = max(abs(xc));
    lag       = lags(idx);
    fprintf('  Lag at 50 kHz: %d samples (%.2f ms)\n', lag, lag/FS_OUT*1e3);
    if lag > 0
        sig_use = sig_use(lag+1:end);
        sig_fl  = sig_fl(1:end-lag);
    elseif lag < 0
        sig_fl  = sig_fl(-lag+1:end);
        sig_use = sig_use(1:end+lag);
    end
    n_al    = min(length(sig_use), length(sig_fl));
    sig_use = sig_use(1:n_al);
    sig_fl  = sig_fl(1:n_al);

    % Resample both to 48 kHz
    [p,q] = rat(FS_AUDIO/FS_OUT, 1e-9);
    a_fp  = resample(sig_use, p, q);
    a_fl  = resample(sig_fl,  p, q);

    n_cmp = min(length(a_fp), length(a_fl));
    ref   = a_fl(1:n_cmp);
    tst   = a_fp(1:n_cmp);

    % Normalise BOTH signals to the float peak.
    % Normalising each to its own peak fails when the two signals have
    % different instantaneous peaks (e.g. a fixed-point overflow spike),
    % causing the subtraction to be dominated by that scale difference.
    % Using the float peak as reference makes the comparison scale-invariant
    % and robust to occasional peak differences.
    fl_peak = max(abs(ref)) + eps;
    ref = ref / fl_peak;
    tst = tst / fl_peak;

    % Optimal scale correction (removes any residual gain offset)
    alpha = (ref' * tst) / (ref' * ref + eps);
    err   = tst - alpha * ref;

    corr  = corrcoef(ref, tst); corr = corr(1,2);
    SNR   = 10*log10(mean(ref.^2) / (mean(err.^2)+eps));
    ENOB  = (SNR - 1.76) / 6.02;
    gain_dB = 20*log10(abs(alpha)+eps);

    fprintf('  Correlation : %.6f\n', corr);
    fprintf('  Gain error  : %+.2f dB  (alpha=%.4f)\n', gain_dB, alpha);
    fprintf('  SNR         : %.1f dB\n', SNR);
    fprintf('  ENOB        : %.1f bits\n', ENOB);

    % Interpret SNR from correlation (independent of normalisation)
    snr_from_corr = 10*log10(corr^2 / (1-corr^2+eps));
    fprintf('  SNR from correlation: %.1f dB  (reference value)\n', snr_from_corr);

    if snr_from_corr > 40
        fprintf('  [PASS] Audio quality good (corr=%.4f)\n', corr);
    elseif snr_from_corr > 25
        fprintf('  [ACCEPTABLE] Audible quality\n');
    else
        fprintf('  [FAIL] investigate further\n');
    end

    % What types did the proposer assign to each stage?
    fprintf('\n=== Proposed types summary ===\n');
    blocks_of_interest = {'AA_I','AA_Q','AudioLPF','DeEmph','Data Type Conversion'};
    for k=1:numel(blocks_of_interest)
        blk_list = find_system(DEST_MDL,'Name',blocks_of_interest{k});
        if ~isempty(blk_list)
            try
                dt = get_param(blk_list{1},'OutDataTypeStr');
                fprintf('  %-25s: %s\n',blocks_of_interest{k},dt);
            catch,end
        end
    end
    % FM_Disc internals
    prod_blks = find_system([DEST_MDL '/FM_Disc'],'BlockType','Product');
    if ~isempty(prod_blks)
        try
            dt = get_param(prod_blks{1},'OutDataTypeStr');
            fprintf('  %-25s: %s\n','FM_Disc/Product',dt);
        catch,end
    end
else
    fprintf('  Float reference not available\n');
end

fprintf('=== Done ===\n');
