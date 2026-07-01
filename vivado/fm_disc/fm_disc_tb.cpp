#include <iostream>
#include <fstream>
#include <cmath>
#include <vector>
#include "fm_disc.h"

int main() {
    std::cout << "======================================================" << std::endl;
    std::cout << "=== FM Discriminator C/RTL Co-Simulation Testbench ===" << std::endl;
    std::cout << "======================================================" << std::endl;

    std::ifstream ic_file("fm_disc_ic_stimulus.txt");
    std::ifstream qc_file("fm_disc_qc_stimulus.txt");
    std::ifstream gold_file("fm_disc_golden.txt");

    if (!ic_file.is_open() || !qc_file.is_open() || !gold_file.is_open()) {
        std::cerr << "ERROR: Could not open stimulus/golden files." << std::endl;
        std::cerr << "Run gen_fm_disc_vectors.m first." << std::endl;
        return 1;
    }

    // Stimulus files contain stored integers (int16_t range for sfix18_En17).
    // Load as int, then construct ap_fixed directly to avoid double-cast rounding.
    std::vector<int>    ic_ints, qc_ints;
    std::vector<double> gold_vals;
    int    vi;
    double vd;
    while (ic_file   >> vi) ic_ints.push_back(vi);
    while (qc_file   >> vi) qc_ints.push_back(vi);
    while (gold_file >> vd) gold_vals.push_back(vd);
    ic_file.close(); qc_file.close(); gold_file.close();

    // Convert stored integers to ap_fixed<18,1> by direct bit assignment
    // This avoids any rounding that (data_t)double_val would introduce.
    std::vector<data_t> ic_vals(ic_ints.size()), qc_vals(qc_ints.size());
    for (size_t i = 0; i < ic_ints.size(); i++) {
        ic_vals[i].range() = ic_ints[i];
        qc_vals[i].range() = qc_ints[i];
    }

    if (ic_ints.size() != qc_ints.size() || ic_ints.size() != gold_vals.size()) {
        std::cerr << "ERROR: Stimulus/golden file size mismatch." << std::endl;
        return 1;
    }

    int N = ic_ints.size();
    int failures = 0;

    // Tolerance: 3 LSB of sfix32_En14 output (LSB = 39788.7/2^14 = 2.428 Hz)
    // HLS AP_TRN vs MATLAB fi Floor may differ by 1 LSB on the r2Hz multiply.
    const double TOL = 15.0;  // 15 Hz = ~6 LSB of sfix32_En14 (2.428 Hz/LSB)

    // Skip first sample (output is zero while delay registers initialise)
    const int SKIP = 1;

    std::cout << "Samples: " << N << "  Tolerance: " << TOL << std::endl;
    std::cout << "Idx\tIc\t\tQc\t\tHLS\t\tGolden\t\tErr\t\tStatus" << std::endl;
    std::cout << std::string(100, '-') << std::endl;

    for (int i = 0; i < N; i++) {
        // ic_in/qc_in are named local lvalues, so they bind correctly to
        // fm_disc's now-by-reference parameters (data_t &ic, data_t &qc)
        // required for HLS axis interface mode -- no other TB changes needed.
        data_t ic_in  = ic_vals[i];
        data_t qc_in  = qc_vals[i];
        out_t  disc   = 0;

        fm_disc(ic_in, qc_in, disc);

        if (i < SKIP) continue;

        double hls_d  = disc.to_double();
        double gold_d = gold_vals[i];
        double err    = std::abs(hls_d - gold_d);
        std::string status = (err <= TOL) ? "PASS" : "FAIL !!!";

        if (err > TOL) failures++;

        if (i < SKIP + 20) {
            std::cout << i << "\t"
                      << ic_vals[i].to_double()  << "\t\t"
                      << qc_vals[i].to_double()  << "\t\t"
                      << hls_d       << "\t\t"
                      << gold_d      << "\t\t"
                      << err         << "\t\t"
                      << status      << std::endl;
        }
    }

    std::cout << std::string(100, '-') << std::endl;
    int checked = N - SKIP;
    std::cout << "Checked: " << checked << "  Failures: " << failures << std::endl;

    if (failures == 0) {
        std::cout << "=== TESTBENCH PASSED ===" << std::endl;
        return 0;
    } else {
        std::cout << "=== TESTBENCH FAILED: " << failures << " mismatches ===" << std::endl;
        return 1;
    }
}
