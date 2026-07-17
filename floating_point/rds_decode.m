% rds_decode.m
% Fast, Vectorized RDS Demodulator

clear; close all; clc;

%% ── PARAMETERS ───────────────────────────────────────────────────────────
WAV_FILE       = 'rds.wav';
CARRIER_OFFSET = -10e3;     % Hz   Station offset (-10 kHz)
FS_IQ          = 250e3;     % Hz   IQ sample rate
MAX_SECONDS    = 30;        % s    Reduced duration for speed
RDS_BITRATE    = 1187.5;    % bps  RDS bit rate
%% ────────────────────────────────────────────────────────────────────────

%% 1. Read WAV & Extract Baseband MPX Signal ──────────────────────────────
fprintf('[1] Reading %s and extracting MPX signal...\n', WAV_FILE);
[raw, fs_wav] = audioread(WAV_FILE, 'native');
assert(fs_wav == FS_IQ, 'Sample rate mismatch!');

if isfinite(MAX_SECONDS)
    raw = raw(1 : min(end, round(MAX_SECONDS * FS_IQ)), :);
end

I = double(raw(:,1)) / 32768;
Q = double(raw(:,2)) / 32768;

t  = (0 : length(I)-1).' / FS_IQ;
ph = 2*pi*(-CARRIER_OFFSET)*t;
Ic = I.*cos(ph) - Q.*sin(ph);
Qc = I.*sin(ph) + Q.*cos(ph);

% Anti-alias filter
h_aa = fir1(128, 100e3/(FS_IQ/2), 'low', kaiser(129, 8));
Ic   = filtfilt(h_aa, 1, Ic);
Qc   = filtfilt(h_aa, 1, Qc);

% MPX Baseband
Ic_d = [0; Ic(1:end-1)];
Qc_d = [0; Qc(1:end-1)];
mpx  = atan2(Qc.*Ic_d - Ic.*Qc_d, Ic.*Ic_d + Qc.*Qc_d) * (FS_IQ / (2*pi));

%% 2 & 3. 57 kHz Carrier Recovery & Demodulation ─────────────────────────
fprintf('[2/3] Extracting 57 kHz carrier & Phase-Aligning BPSK...\n');

h_19    = fir1(256, [18.8e3 19.2e3]/(FS_IQ/2), 'bandpass');
pilot19 = filtfilt(h_19, 1, mpx);   % kept for reference/diagnostics, not used for carrier recovery below

% --- 57 kHz carrier recovery via squaring loop (Costas-style) --------
% Tripling the 19 kHz pilot's phase is the textbook approach and should
% work in theory (RDS subcarrier is spec'd as phase-locked to 3x pilot),
% but empirically on real captures it can fail to track coherently
% (verified: per-second phase estimates from pilot-tripling on this
% class of signal were essentially uncorrelated noise, I/Q energy ratio
% ~1.0 = no lock). Squaring the RDS band directly is the standard BPSK
% carrier-recovery technique: for a suppressed-carrier BPSK signal at
% fc, squaring strips the +-1 data modulation and leaves a pure tone at
% 2*fc, which can be tracked far more robustly.
h_rds   = fir1(256, [53.5e3 60.5e3]/(FS_IQ/2), 'bandpass');
rds_bp  = filtfilt(h_rds, 1, mpx);

sq       = rds_bp.^2;
h_2fc    = fir1(512, [113e3 115e3]/(FS_IQ/2), 'bandpass');
sq_filt  = filtfilt(h_2fc, 1, sq);
phase2fc = unwrap(angle(hilbert(sq_filt)));   % safe here: sq_filt is a very
                                               % high-SNR near-pure tone
carrier57  = exp(1j * phase2fc / 2);          % halve phase: 2*fc -> fc
rds_raw_bb = rds_bp .* conj(carrier57);

% Resolve residual BPSK phase ambiguity (mod pi) via 2nd-power averaging,
% then keep the real part as the demodulated symbol stream.
theta      = 0.5*angle(mean(rds_raw_bb.^2));
rds_raw_bb = real(rds_raw_bb .* exp(-1j*theta));

h_lp   = fir1(128, 2.4e3/(FS_IQ/2), 'low');
rds_bb = filtfilt(h_lp, 1, rds_raw_bb);

%% 4 & 5. Timing Recovery & Sequence Decoding ─────────────────────────────
fprintf('[4/5] Open-loop timing recovery & sequence decoding...\n');

FS_INTERM = RDS_BITRATE * 8;
[p1, q1]  = rat(FS_INTERM / FS_IQ);
rds_8x    = resample(rds_bb, p1, q1);

% Re-estimate timing phase every CHUNK_SEC seconds instead of once for the
% whole file. A single global phase estimate can't track sample-clock
% drift between the transmitter and receiver, which over tens of seconds
% is enough to walk the sampling point off the eye and lose bit lock.
CHUNK_SEC = 1.0;
chunk_len = round(CHUNK_SEC * FS_INTERM);
n_chunks  = floor(length(rds_8x) / chunk_len);
rds_aligned = [];

for c = 1:n_chunks
    idx0  = (c-1)*chunk_len + 1;
    idx1  = c*chunk_len;
    chunk = rds_8x(idx0:idx1);

    sq_sig  = chunk.^2;
    N_fft   = length(sq_sig);
    fft_sig = fft(sq_sig);
    freqs   = (0:N_fft-1) * (FS_INTERM / N_fft);

    [~, idx]  = min(abs(freqs - RDS_BITRATE));
    opt_phase = angle(fft_sig(idx));

    sample_shift = mod(round((-opt_phase / (2*pi)) * 8), 8) + 1;
    rds_aligned  = [rds_aligned; chunk(sample_shift:4:end)]; %#ok<AGROW>
end

half_sym_1 = rds_aligned(1:2:end-1);
half_sym_2 = rds_aligned(2:2:end);
min_len    = min(length(half_sym_1), length(half_sym_2));

m_bits1 = (half_sym_1(1:min_len) - half_sym_2(1:min_len)) > 0;
m_bits2 = (half_sym_2(1:min_len-1) - half_sym_1(2:min_len)) > 0;

d1 = xor(m_bits1(2:end), m_bits1(1:end-1));
d2 = ~d1;
d3 = xor(m_bits2(2:end), m_bits2(1:end-1));
d4 = ~d3;

candidates = {d1, d2, d3, d4, ~d1, ~d2, ~d3, ~d4};

% Build Parity Generator Matrix H for fast vector syndrome calculation
% RDS check polynomial: g(x) = x^10 + x^8 + x^7 + x^5 + x^4 + x^3 + 1
%
% NOTE: the original shift-register implementation here (feedback =
% xor(bit, reg(1)); shift; conditionally xor in poly(2:end)) does NOT
% correctly implement division by this polynomial -- verified against an
% independent from-scratch GF(2) long-division reference implementation,
% it computes a different linear function of the input entirely, for any
% polynomial value. This was the root cause of the decoder never
% syncing: it wasn't a wrong-constant bug, it was a wrong-algorithm bug,
% so no amount of correcting the poly/offset *values* could fix it.
% Replaced with a standard schoolbook GF(2) polynomial long division,
% which was verified to correctly reproduce each offset word for
% synthetic valid codewords.
poly = [1 0 1 1 0 1 1 1 0 0 1];
H = zeros(26, 10);
for col = 1:26
    reg = zeros(1, 26); reg(col) = 1;
    for i = 1:16
        if reg(i) == 1
            reg(i:i+10) = xor(reg(i:i+10), poly);
        end
    end
    H(col, :) = reg(17:26);
end

offsets = [ ...
    0 0 1 1 1 1 1 1 0 0; ... % A
    0 1 1 0 0 1 1 0 0 0; ... % B
    0 1 0 1 1 0 1 0 0 0; ... % C
    1 1 0 1 0 1 0 0 0 0; ... % C'
    0 1 1 0 1 1 0 1 0 0  ... % D
];

best_res.sync = -1;
best_res.ps   = repmat(' ', 1, 8);
best_res.rt   = repmat(' ', 1, 64);
best_res.pi   = '----';
best_res.hist = zeros(1,16);

% Iterate candidate streams
for c_idx = 1:length(candidates)
    stream = candidates{c_idx}(:).';
    [ps, rt, pi_c, sync_cnt, grp_hist] = decode_rds_stream_fast(stream, H, offsets);
    
    if sync_cnt > best_res.sync
        best_res.ps   = ps;
        best_res.rt   = rt;
        best_res.pi   = pi_c;
        best_res.sync = sync_cnt;
        best_res.hist = grp_hist;
    end
end

ps_text       = best_res.ps;
rt_text       = best_res.rt;
pi_code       = best_res.pi;
synced_blocks = best_res.sync;

fprintf(' Group types seen (0-15)   : ');
for g = 0:15
    if best_res.hist(g+1) > 0
        fprintf('%dx type%d  ', best_res.hist(g+1), g);
    end
end
fprintf('\n');

%% 6. Display Results ──────────────────────────────────────────────────────
fprintf('\n==================================================\n');
fprintf('                RDS DECODE RESULTS                \n');
fprintf('==================================================\n');
fprintf(' Valid RDS Blocks Synced  : %d\n', synced_blocks);
fprintf(' Program ID (PI Code)      : 0x%s\n', pi_code);
fprintf(' Station Name (PS)         : [%s]\n', ps_text);
fprintf(' RadioText (RT)            : [%s]\n', strtrim(rt_text));
fprintf('==================================================\n\n');

%% Vectorized Fast Decoder
function [ps_text, rt_text, pi_code, valid_syncs, grp_hist] = decode_rds_stream_fast(bit_stream, H, offsets)
    N = length(bit_stream);
    ps_buf = repmat(' ', 1, 8);
    rt_buf = repmat(' ', 1, 64);
    pi_code = '----';
    valid_syncs = 0;
    grp_hist = zeros(1,16);
    
    if N < 26
        ps_text = ps_buf; rt_text = rt_buf; return;
    end
    
    synced = false;
    block_expected = 1;
    miss_cnt = 0;
    
    curr_group   = -1;
    curr_version = -1;
    ps_seg_addr  = -1;
    rt_seg_addr  = -1;
    
    % Majority-vote tallies: rows = character position, cols = ASCII code.
    % Real-world receptions include occasional bit-error corrupted blocks
    % even when correctly block-synced (a valid syndrome match only tells
    % you the block landed on offset boundaries correctly, not that every
    % data bit inside it is error-free). Last-write-wins lets one bad
    % reception clobber many good ones; voting across all receptions of
    % each character position is far more robust once you have more than
    % a handful of samples per position.
    ps_votes = zeros(8, 128);
    rt_votes = zeros(64, 128);
    
    i = 1;
    while i <= N - 25
        word = bit_stream(i : i+25);
        
        % Vectorized Syndrome Check
        synd = mod(word * H, 2);
        
        detected_block = 0;
        for b = 1:5
            if all(xor(synd, offsets(b, :)) == 0)
                detected_block = b;
                break;
            end
        end
        
        if ~synced
            if detected_block == 1
                synced = true;
                block_expected = 1;
                miss_cnt = 0;
            else
                i = i + 1;
                continue;
            end
        end
        
        % Synced block verification
        is_valid = false;
        if detected_block > 0
            if block_expected == 1 && detected_block == 1, is_valid = true; end
            if block_expected == 2 && detected_block == 2, is_valid = true; end
            if block_expected == 3 && (detected_block == 3 || detected_block == 4), is_valid = true; end
            if block_expected == 4 && detected_block == 5, is_valid = true; end
        end
        
        if is_valid
            valid_syncs = valid_syncs + 1;
            miss_cnt = 0;
            
            info_val = sum(word(1:16) .* (2.^(15:-1:0)));
            
            switch block_expected
                case 1 % Block A
                    pi_code = sprintf('%04X', info_val);
                    
                case 2 % Block B
                    curr_group   = bitshift(info_val, -12);
                    curr_version = bitand(bitshift(info_val, -11), 1);
                    grp_hist(curr_group+1) = grp_hist(curr_group+1) + 1;
                    
                    if curr_group == 0
                        ps_seg_addr = bitand(info_val, 3);
                    elseif curr_group == 2
                        rt_seg_addr = bitand(info_val, 15);
                    end
                    
                case 3 % Block C / C'
                    c1 = bitshift(info_val, -8);
                    c2 = bitand(info_val, 255);
                    if curr_group == 2 && curr_version == 0 && rt_seg_addr >= 0 && rt_seg_addr <= 15
                        idx = rt_seg_addr * 4 + 1;
                        if c1 >= 32 && c1 <= 126, rt_votes(idx,   c1+1) = rt_votes(idx,   c1+1) + 1; end
                        if c2 >= 32 && c2 <= 126, rt_votes(idx+1, c2+1) = rt_votes(idx+1, c2+1) + 1; end
                    end
                    
                case 4 % Block D
                    c1 = bitshift(info_val, -8);
                    c2 = bitand(info_val, 255);
                    if curr_group == 0 && ps_seg_addr >= 0 && ps_seg_addr <= 3
                        idx = ps_seg_addr * 2 + 1;
                        if c1 >= 32 && c1 <= 126, ps_votes(idx,   c1+1) = ps_votes(idx,   c1+1) + 1; end
                        if c2 >= 32 && c2 <= 126, ps_votes(idx+1, c2+1) = ps_votes(idx+1, c2+1) + 1; end
                    elseif curr_group == 2 && rt_seg_addr >= 0 && rt_seg_addr <= 15
                        idx = ternary(curr_version == 0, rt_seg_addr * 4 + 3, rt_seg_addr * 2 + 1);
                        if c1 >= 32 && c1 <= 126, rt_votes(idx,   c1+1) = rt_votes(idx,   c1+1) + 1; end
                        if c2 >= 32 && c2 <= 126, rt_votes(idx+1, c2+1) = rt_votes(idx+1, c2+1) + 1; end
                    end
            end
            
            i = i + 26;
            block_expected = mod(block_expected, 4) + 1;
        else
            miss_cnt = miss_cnt + 1;
            if miss_cnt >= 4
                synced = false;
                i = i + 1;
            else
                i = i + 26;
                block_expected = mod(block_expected, 4) + 1;
            end
        end
    end
    
    for p = 1:8
        if any(ps_votes(p,:) > 0)
            [~, best] = max(ps_votes(p,:));
            ps_buf(p) = char(best-1);
        end
    end
    for p = 1:64
        if any(rt_votes(p,:) > 0)
            [~, best] = max(rt_votes(p,:));
            rt_buf(p) = char(best-1);
        end
    end
    
    ps_text = ps_buf;
    rt_text = rt_buf;
end

function out = ternary(cond, val_true, val_false)
    if cond, out = val_true; else, out = val_false; end
end