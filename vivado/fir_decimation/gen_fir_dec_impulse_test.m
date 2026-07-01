% gen_fir_dec_impulse_test.m
% Generates impulse stimulus and expected golden for FIR Compiler decimator.
% With decimation R=5, the impulse response gives filter coefficients at
% positions 4, 9, 14, 19, 24, 29, 34, 39 (every 5th, starting at R-1=4).
%
% Marco Aiello, 2024

fprintf('=== Generating FIR Decimator impulse test ===\n');

h = fir1(40, 1/5);  % 41 taps, indices 0..40
N_in  = 250;        % enough inputs for all non-zero outputs (41 taps / R=5 = ~9 outputs)
N_out = N_in / 5;   % 90 decimated outputs

T_data = numerictype(1, 32, 14);
fm = fimath('RoundingMethod','Convergent','OverflowAction','Wrap', ...
    'ProductMode','SpecifyPrecision','ProductWordLength',48,'ProductFractionLength',28, ...
    'SumMode','SpecifyPrecision','SumWordLength',48,'SumFractionLength',28);
h_fi = fi(h, T_data, fm);

%% Stimulus: impulse at sample 1 (stored int = 2^14 = 16384), zeros elsewhere
x = zeros(N_in, 1);
x(1) = 1.0;  % 1.0 Hz in sfix32_En14
x_fi  = fi(x, T_data, fm);
x_int = double(storedInteger(x_fi));

writematrix(x_int, 'fir_dec_stimulus.txt');
fprintf('Written: fir_dec_stimulus.txt (%d samples)\n', N_in);
fprintf('Impulse stored int: %d (= 2^14 = %.0f)\n', x_int(1), 2^14);

%% Expected output: h[R-1+k*R] for k=0,1,2,...
% With direct form decimator, output k = h[R-1 + k*R] * impulse_amplitude
% R=5, so: h[4], h[9], h[14], h[19], h[24], h[29], h[34], h[39], then 0s
R = 5;
expected = zeros(N_out, 1);
for k = 0:N_out-1
    idx = R - 1 + k * R;  % 0-indexed coefficient index
    if idx <= 40
        expected(k+1) = double(h_fi(idx+1));  % MATLAB 1-indexed
    end
end

fprintf('\nExpected impulse response outputs:\n');
fprintf('  k=0: h[4]  = %.8f\n', expected(1));
fprintf('  k=1: h[9]  = %.8f\n', expected(2));
fprintf('  k=2: h[14] = %.8f\n', expected(3));
fprintf('  k=3: h[19] = %.8f\n', expected(4));
fprintf('  k=4: h[24] = %.8f (peak, symmetric centre)\n', expected(5));
fprintf('  k=5: h[29] = %.8f\n', expected(6));
fprintf('  k=6: h[34] = %.8f\n', expected(7));
fprintf('  k=7: h[39] = %.8f\n', expected(8));
fprintf('  k>=8: 0 (beyond filter length)\n');

%% Write golden with latency zeros prepended
% The FIR Compiler v7.2 has additional pipeline latency beyond the group delay.
% From simulation: the first valid impulse response output appears after
% some startup outputs. Prepend N_LAT zeros to absorb IP startup latency.
% Adjust N_LAT based on observed simulation output until outputs align.
N_LAT = 0;   % set to 0 first: observe raw output to find actual IP latency
expected_padded = [zeros(N_LAT, 1); expected; zeros(N_out - N_LAT, 1)];
% Keep total length = N_out
expected_padded = expected_padded(1:N_out);
writematrix(expected_padded, 'fir_dec_golden.txt');
fprintf('\nWritten: fir_dec_golden.txt (%d entries, %d leading zeros)\n', N_out, N_LAT);

%% Cross-check: run the filter manually
fprintf('\nManual cross-check (direct form):\n');
shift = zeros(1, 41);
out_idx = 0;
for k = 1:N_in
    shift = [double(x_fi(k)), shift(1:end-1)];
    if mod(k-1, R) == R-1  % output every R samples
        acc = 0;
        for i = 1:41
            acc = acc + shift(i) * double(h_fi(i));
        end
        out_idx = out_idx + 1;
        if out_idx <= 10
            fprintf('  Output %d = %.8f (expected %.8f)\n', ...
                out_idx-1, acc, expected(out_idx));
        end
    end
end

fprintf('\n=== Done ===\n');
fprintf('SKIP=0 in testbench (impulse response, no group delay to skip)\n');
fprintf('TOL=0.001 Hz (should match coefficients exactly)\n');
