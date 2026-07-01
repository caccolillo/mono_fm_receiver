% gen_de_emph_test.m
% Generates stimulus and golden for the de-emphasis IIR testbench.
% Uses a step input (easiest to verify IIR steady state) and impulse.
%
% Marco Aiello, 2024

fprintf('=== Generating De-emphasis test vectors ===\n');

% Filter parameters (from Simulink block)
b0 = 0.234071661635351;
a1 = 0.765928338364649;

% Fixed-point types
T_in  = numerictype(1, 32, 14);   % sfix32_En14 input
T_out = numerictype(1, 32, 13);   % sfix32_En13 output
T_acc = numerictype(1, 40, 13);   % sfix40_En13 accumulator
T_c   = numerictype(1, 32, 14);   % sfix32_En14 coefficients (inherit from input)

fm_round = fimath('RoundingMethod','Round','OverflowAction','Saturate', ...
    'ProductMode','SpecifyPrecision','ProductWordLength',40,'ProductFractionLength',13, ...
    'SumMode','SpecifyPrecision','SumWordLength',40,'SumFractionLength',13);

% Quantise coefficients
b0_fi = fi(b0, T_c, fm_round);
a1_fi = fi(a1, T_c, fm_round);
fprintf('b0_q = %.10f (stored int: %d)\n', double(b0_fi), double(storedInteger(b0_fi)));
fprintf('a1_q = %.10f (stored int: %d)\n', double(a1_fi), double(storedInteger(a1_fi)));

% Generate test: 500-sample sinewave at 1 kHz, then step to check steady state
N   = 500;
t   = (0:N-1)' / 50e3;
x   = sin(2*pi*1e3*t) * 5000;   % 1 kHz, 5000 Hz amplitude, sfix32_En14
x_fi = fi(x, T_in, fm_round);

% Compute golden: Direct Form I IIR
% y[n] = b0*x[n] + a1*y[n-1]
y_prev = fi(0, T_out, fm_round);
outputs = zeros(N, 1);
for k = 1:N
    xk     = fi(double(x_fi(k)), T_in, fm_round);
    % Numerator product: b0 * x[n] -> En28, truncate to En13 (Round, Sat)
    np     = fi(double(b0_fi) * double(xk), T_acc, fm_round);
    % Denominator product: a1 * y[n-1] -> En27, truncate to En13 (Round, Sat)
    dp     = fi(double(a1_fi) * double(y_prev), T_acc, fm_round);
    % Accumulate and saturate to sfix40_En13
    acc    = fi(double(np) + double(dp), T_acc, fm_round);
    % Truncate to output sfix32_En13
    y_out  = fi(double(acc), T_out, fm_round);
    outputs(k) = double(y_out);
    y_prev = y_out;
end

% Write stimulus and golden
x_int = double(storedInteger(x_fi));
writematrix(x_int,    'de_emph_stimulus.txt');
writematrix(outputs,  'de_emph_golden.txt');
fprintf('Written: de_emph_stimulus.txt (%d samples)\n', N);
fprintf('Written: de_emph_golden.txt (%d samples)\n', N);
fprintf('Output range: [%.2f, %.2f]\n', min(outputs), max(outputs));
fprintf('=== Done ===\n');
