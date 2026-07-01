#include <iostream>
#include <fstream>
#include <cmath>
#include <vector>
#include "aa_lpf.h"

/**
 * Self-checking testbench for the single-channel AA LPF.
 *
 * Since aa_lpf is instantiated once per channel (I and Q) in the block
 * design, this testbench verifies ONE channel per run, reading a single
 * non-interleaved stimulus/golden pair. Run it once with I-channel vectors
 * and once with Q-channel vectors (same coefficients, same filter -- only
 * the stimulus differs, so a single-channel test fully covers both since
 * the hardware is identical for either channel).
 *
 * Stimulus / golden files (non-interleaved, one value per line):
 *   matlab_input_stimulus.txt
 *   matlab_golden_output.txt
 */
int main() {
    std::cout << "======================================================" << std::endl;
    std::cout << "=== AA LPF Single-Channel Self-Checking Test       ===" << std::endl;
    std::cout << "======================================================" << std::endl;

    // Single-channel filter is identical hardware for I and Q -- this
    // testbench verifies against the I-channel vectors. Swap the two
    // filenames below (or copy the Q-channel files over these names) to
    // verify the Q-channel path as well; the RTL is the same either way.
    std::ifstream input_file("aa_lpf_i_stimulus.txt");
    std::ifstream golden_file("aa_lpf_i_golden.txt");

    if (!input_file.is_open() || !golden_file.is_open()) {
        std::cerr << "CRITICAL ERROR: Could not open test vector files!" << std::endl;
        std::cerr << "Ensure aa_lpf_i_stimulus.txt and aa_lpf_i_golden.txt are in this folder." << std::endl;
        return 1;
    }

    double in_val, golden_val;
    std::vector<double> inputs;
    std::vector<double> goldens;

    while (input_file >> in_val)      { inputs.push_back(in_val); }
    while (golden_file >> golden_val) { goldens.push_back(golden_val); }

    input_file.close();
    golden_file.close();

    if (inputs.size() != goldens.size() || inputs.empty()) {
        std::cerr << "ERROR: Vector file data sizes mismatch or are empty!" << std::endl;
        return 1;
    }

    int total_samples = inputs.size();
    int failure_count = 0;

    // Acceptable precision tolerance for fixdt(1,18,17) is 2^-17 = 7.62e-6.
    // 1e-5 accommodates standard floating-to-fixed string truncation.
    const double TOLERANCE = 1e-5;

    std::cout << "Processing " << total_samples << " samples (single channel)..." << std::endl;
    std::cout << "Index\tInput\t\tHLS Hardware\tMATLAB Golden\tStatus" << std::endl;
    std::cout << "----------------------------------------------------------------------" << std::endl;

    for (int t = 0; t < total_samples; t++) {
        data_t input_sample  = (data_t)inputs[t];
        data_t output_sample = 0;

        // Single-channel call: no interleaving, no channel_select state.
        aa_lpf(input_sample, output_sample);

        double hls_double = output_sample.to_double();
        double mat_double = goldens[t];
        double error      = std::abs(hls_double - mat_double);

        std::string match_status = "PASS";
        if (error > TOLERANCE) {
            match_status = "FAIL !!!";
            failure_count++;
        }

        if (t < 20) {
            std::cout << t << "\t"
                      << inputs[t]   << "\t\t"
                      << hls_double  << "\t\t"
                      << mat_double  << "\t\t"
                      << match_status << std::endl;
        }
    }

    std::cout << "----------------------------------------------------------------------" << std::endl;
    std::cout << "Verification Summary: " << (total_samples - failure_count)
              << "/" << total_samples << " samples passed." << std::endl;

    if (failure_count > 0) {
        std::cout << "=== TEST BENCH FAILED: " << failure_count << " discrepancies found ===" << std::endl;
        return 1;
    }

    std::cout << "=== TEST BENCH PASSED: Hardware perfectly matches Simulink logic! ===" << std::endl;
    return 0;
}
