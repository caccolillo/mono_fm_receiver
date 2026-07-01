% fir_dec_coeffs.m
% Generates the FIR Compiler coefficient file for the decimation filter.
% fir1(40, 1/5), quantised to sfix32_En14 (same as input/output).
%


h = fir1(40, 1/5);

% Quantise to sfix32_En14 (same word length as input)
T = numerictype(1, 32, 14);
fm = fimath('RoundingMethod','Round','OverflowAction','Saturate');
h_fi = fi(h, T, fm);

fprintf('Filter: fir1(40, 1/5), %d taps\n', length(h));
fprintf('Coeff range: [%.6f, %.6f]\n', min(double(h_fi)), max(double(h_fi)));
fprintf('Peak stored int: %d\n', max(abs(double(storedInteger(h_fi)))));

% Write .coe file for FIR Compiler
fid = fopen('fir_dec.coe', 'w');
fprintf(fid, '; FIR Decimator coefficients: fir1(40, 1/5)\n');
fprintf(fid, '; Quantised to sfix32_En14 (stored integers)\n');
fprintf(fid, 'radix=10;\n');
fprintf(fid, 'coefdata=\n');
for k = 1:length(h_fi)
    si = double(storedInteger(h_fi(k)));
    if k < length(h_fi)
        fprintf(fid, '%d,\n', si);
    else
        fprintf(fid, '%d;\n', si);
    end
end
fclose(fid);
fprintf('Written: fir_dec.coe\n');
