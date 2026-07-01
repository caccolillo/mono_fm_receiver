% gen_fm_disc_vectors.m
% Generates stimulus and golden vectors for the HLS FM discriminator testbench.
% Matches the Simulink fixed-point block diagram exactly:
%
%   Idiff = Ic*Id + Qc*Qd         (complex multiply real part)
%   Qdiff = Qc*Id - Ic*Qd         (complex multiply imaginary part)
%   phase = atan2(Qdiff, Idiff)   [sfix18_En15]
%   out   = phase * r2Hz           [sfix32_En14]
%   r2Hz  = 250000 / (2*pi) = 39788.7358
%


fprintf('=== Generating FM Discriminator test vectors ===\n');

% Use FreqCorr output from run_and_extract workspace
% ic_gold and qc_gold are the AA LPF inputs (FreqCorr outputs)
if ~exist('ic_gold','var') || ~exist('qc_gold','var')
    error('Run run_and_extract.m first to populate ic_gold and qc_gold.');
end

N = min(500, length(ic_gold));  % 500 samples is plenty for verification

% Fixed-point types matching Simulink diagram
T_in   = numerictype(1, 18, 17);  % sfix18_En17
T_prod = numerictype(1, 18, 14);  % sfix18_En14
T_atan = numerictype(1, 18, 15);  % sfix18_En15
T_out  = numerictype(1, 32, 14);  % sfix32_En14

fm_prod = fimath('RoundingMethod','Floor','OverflowAction','Saturate', ...
                 'ProductMode','SpecifyPrecision', ...
                 'ProductWordLength',18,'ProductFractionLength',14, ...
                 'SumMode','SpecifyPrecision', ...
                 'SumWordLength',18,'SumFractionLength',14);

r2hz = 250e3 / (2*pi);  % 39788.7358

% Quantise inputs to sfix18_En17
ic_fi = fi(ic_gold(1:N), T_in, fm_prod);
qc_fi = fi(qc_gold(1:N), T_in, fm_prod);

% Compute golden output sample by sample (matching hardware delay register)
gold = zeros(N, 1);
id = fi(0, T_in, fm_prod);
qd = fi(0, T_in, fm_prod);

for k = 1:N
    ic = ic_fi(k);
    qc = qc_fi(k);

    % Cross products -> sfix18_En14
    % Use fi() arithmetic with fimath (NOT double cast) to match HLS ap_fixed
    ixid = ic * id;   % fimath controls product precision -> sfix18_En14
    qxqd = qc * qd;
    qxid = qc * id;
    ixqd = ic * qd;

    % Combine (fimath controls sum precision -> sfix18_En14)
    x_diff = ixid + qxqd;   % Idiff
    y_diff = qxid - ixqd;   % Qdiff

    % Fixed-point CORDIC atan2 matching HLS fm_disc.cpp implementation.
    % 16 iterations, vectoring mode, sfix22_En14 internal, sfix18_En15 output.
    T_ci = numerictype(1, 32, 24);  % cordic internal (cordic_t = ap_fixed<32,8>)
    T_ph = numerictype(1, 18, 15);  % phase output (phase_t = sfix18_En15)
    atan_lut = zeros(1,16);
    for ii = 0:15
        atan_lut(ii+1) = double(fi(atan(2^(-ii)), T_ph, fm_prod));
    end
    xc = double(fi(double(x_diff), T_ci, fm_prod));
    yc = double(fi(double(y_diff), T_ci, fm_prod));
    zc = 0;
    if xc < 0
        if yc >= 0
            xc = -xc; yc = -yc;
            zc = double(fi(pi, T_ph, fm_prod));
        else
            xc = -xc; yc = -yc;
            zc = double(fi(-pi, T_ph, fm_prod));
        end
    end
    for ii = 0:15
        sh = 2^(-ii);
        if yc >= 0
            xn = double(fi(xc + yc*sh, T_ci, fm_prod));
            yn = double(fi(yc - xc*sh, T_ci, fm_prod));
            zc = double(fi(zc + atan_lut(ii+1), T_ph, fm_prod));
        else
            xn = double(fi(xc - yc*sh, T_ci, fm_prod));
            yn = double(fi(yc + xc*sh, T_ci, fm_prod));
            zc = double(fi(zc - atan_lut(ii+1), T_ph, fm_prod));
        end
        xc = xn; yc = yn;
    end
    phase_q = double(fi(zc, T_ph, fm_prod));
    % Use same r2hz quantisation as HLS out_t = ap_fixed<32,18,AP_TRN>
    % and same product truncation to sfix32_En14
    fm_out = fimath('RoundingMethod','Floor','OverflowAction','Saturate', ...
                    'ProductMode','SpecifyPrecision', ...
                    'ProductWordLength',32,'ProductFractionLength',14, ...
                    'SumMode','SpecifyPrecision', ...
                    'SumWordLength',32,'SumFractionLength',14);
    r2hz_q = double(fi(r2hz, 1, 32, 14, fm_out));   % quantise r2hz to out_t
    gold(k) = double(fi(phase_q * r2hz_q, 1, 32, 14, fm_out));

    % Update delays
    id = ic;
    qd = qc;
end

fprintf('Golden vector range: [%.4f, %.4f] Hz\n', min(gold), max(gold));
fprintf('Sample 2 (first valid): %.6f Hz\n', gold(2));

% Write stimulus files (real-valued doubles for testbench)
% Write stimulus as stored integers to avoid AP_TRN vs Round mismatch.
% Testbench reads integers and loads them directly into ap_fixed via reinterpret.
ic_int = double(storedInteger(ic_fi));
qc_int = double(storedInteger(qc_fi));
writematrix(ic_int, 'fm_disc_ic_stimulus.txt');
writematrix(qc_int, 'fm_disc_qc_stimulus.txt');
writematrix(gold,   'fm_disc_golden.txt');
fprintf('Written: fm_disc_ic_stimulus.txt (%d samples, stored ints)\n', N);
fprintf('Written: fm_disc_qc_stimulus.txt (%d samples, stored ints)\n', N);
fprintf('Written: fm_disc_golden.txt (%d samples)\n', N);
fprintf('=== Done ===\n');
