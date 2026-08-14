#!/usr/bin/env bash
# vivado_build_all.sh
# Sequential build of every sub-block IP, then the top-level end_system project.
#
# WHAT CHANGED vs. the original:
#   - Before running each stage's build.sh, this script verifies that every
#     source/stimulus file that stage needs is actually present on disk.
#     Missing files are reported as a group so you know exactly what to
#     generate (MATLAB scripts) or copy (fixed RTL/HLS files) before retrying.
#   - Before running fm_demod and fm_demod_axis_with_sidechannels, the script
#     confirms that all seven upstream sub-block IPs have been packaged
#     (component.xml present). This is the direct cause of the
#     "VLNV ... not supported for the current part" error: bd.tcl calls
#     update_ip_catalog -rebuild on ../ and then immediately tries to
#     instantiate IPs that aren't there yet.
#   - Each stage prints a clear SKIP / FAIL / PASS status rather than letting
#     Vivado or Vitis HLS emit the first opaque error.
#
# Usage (from vivado/):
#   chmod +x vivado_build_all.sh
#   ./vivado_build_all.sh
#
# To rebuild only from a specific stage onward, comment out the earlier
# entries in SUBFOLDERS below.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Build order ────────────────────────────────────────────────────────────────
# fm_demod and fm_demod_axis_with_sidechannels depend on all seven blocks above
# them being packaged first. audio_ppdma and iq_ppdma are independent HLS
# blocks. end_system depends on fm_demod being packaged.
SUBFOLDERS=(
    aa_lpf
    audio_lpf
    de_emphasis
    fir_decimation
    fm_disc
    freq_corr
    nco
    fm_demod
    fm_demod_axis_with_sidechannels
    audio_ppdma
    iq_ppdma
    end_system
)

# ── Helper: check a list of files exist in a given directory ──────────────────
check_files() {
    local dir="$1"; shift
    local missing=0
    for f in "$@"; do
        if [ ! -f "${dir}/${f}" ]; then
            echo "  MISSING: ${f}"
            missing=1
        fi
    done
    return $missing
}

# ── Helper: check a packaged IP component.xml exists ─────────────────────────
check_ip() {
    local label="$1"
    local xml_path="$2"
    if [ ! -f "${ROOT_DIR}/${xml_path}" ]; then
        echo "  NOT PACKAGED: ${label}"
        echo "  Expected:     ${ROOT_DIR}/${xml_path}"
        return 1
    fi
    return 0
}

# ── Per-stage prerequisite definitions ────────────────────────────────────────
# Each entry is: <folder> <space-separated list of required source files>
# Files are checked relative to the stage's own directory.

prereqs_aa_lpf=(
    aa_lpf.cpp
    aa_lpf.h
    aa_lpf_tb.cpp
    coefficients.h
    aa_lpf_i_stimulus.txt
    aa_lpf_i_golden.txt
)

prereqs_audio_lpf=(
    audio_lpf.vhd
    audio_lpf_tb.vhd
    audio_lpf.coe
    audio_lpf_stimulus.txt
    audio_lpf_golden.txt
)

prereqs_de_emphasis=(
    de_emph.vhd
    de_emph_tb.vhd
    de_emph_stimulus.txt
    de_emph_golden.txt
)

prereqs_fir_decimation=(
    fir_dec.vhd
    fir_dec_tb.vhd
    fir_dec.coe
    fir_dec_stimulus.txt
    fir_dec_golden.txt
)

prereqs_fm_disc=(
    fm_disc.cpp
    fm_disc.h
    fm_disc_tb.cpp
    fm_disc_ic_stimulus.txt
    fm_disc_qc_stimulus.txt
    fm_disc_golden.txt
)

prereqs_freq_corr=(
    freq_corr.vhd
    tb_freq_corr.vhd
    input_i_stimulus.txt
    input_q_stimulus.txt
    input_nco_cos_stimulus.txt
    input_nco_sin_stimulus.txt
    freqcorr_i_golden.txt
    freqcorr_q_golden.txt
)

prereqs_nco=(
    nco_wrapper.vhd
    tb_nco.vhd
    input_nco_cos_stimulus.txt
    input_nco_sin_stimulus.txt
)

# fm_demod and fm_demod_axis_with_sidechannels have no additional source files
# to check here (bd.tcl and fm_demod_ip.tcl are always present in the repo),
# but they need the seven upstream IPs to be packaged first -- checked
# separately below in check_upstream_ips().

prereqs_audio_ppdma=(
    audio_ppdma.cpp
    audio_ppdma.h
    audio_ppdma_tb.cpp
)

prereqs_iq_ppdma=(
    iq_ppdma.cpp
    iq_ppdma.h
    iq_ppdma_tb.cpp
)

prereqs_end_system=(
    prj.tcl
    bd.tcl
    tb_sdr_fm_receiver.sv
)

# ── Packaged IP output locations (relative to ROOT_DIR = vivado/) ─────────────
IP_aa_lpf="aa_lpf/aa_lpf_prj/solution1/impl/ip/component.xml"
IP_audio_lpf="audio_lpf/audio_lpf_proj/ip_repo/component.xml"
IP_de_emphasis="de_emphasis/de_emph_proj/ip_repo/component.xml"
IP_fir_decimation="fir_decimation/fir_dec_proj/ip_repo/component.xml"
IP_fm_disc="fm_disc/fm_disc_prj/solution1/impl/ip/component.xml"
IP_freq_corr="freq_corr/freq_corr_proj/ip_repo/component.xml"
IP_nco="nco/ip_repo/nco_v1_0/component.xml"
IP_fm_demod="fm_demod/fm_demod_proj/ip_repo/component.xml"

check_upstream_ips() {
    # Called before fm_demod and fm_demod_axis_with_sidechannels.
    # Returns non-zero and prints a clear message if any upstream IP is missing.
    local missing=0
    echo "  Checking upstream packaged IPs..."
    check_ip "aa_lpf"        "$IP_aa_lpf"        || missing=1
    check_ip "audio_lpf"     "$IP_audio_lpf"     || missing=1
    check_ip "de_emphasis"   "$IP_de_emphasis"   || missing=1
    check_ip "fir_decimation" "$IP_fir_decimation" || missing=1
    check_ip "fm_disc"       "$IP_fm_disc"       || missing=1
    check_ip "freq_corr"     "$IP_freq_corr"     || missing=1
    check_ip "nco"           "$IP_nco"           || missing=1
    if [ $missing -ne 0 ]; then
        echo ""
        echo "  One or more upstream IPs are not packaged yet."
        echo "  Run the missing block's build.sh individually, then retry."
        return 1
    fi
    echo "  All upstream IPs present."
    return 0
}

check_fm_demod_ip() {
    # Called before fm_demod_axis_with_sidechannels and end_system.
    local missing=0
    echo "  Checking fm_demod packaged IP..."
    check_ip "fm_demod" "$IP_fm_demod" || missing=1
    if [ $missing -ne 0 ]; then
        echo ""
        echo "  fm_demod IP not packaged yet -- run fm_demod/build.sh first."
        return 1
    fi
    echo "  fm_demod IP present."
    return 0
}

# ── Main loop ─────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  vivado_build_all.sh -- sequential build with prereq checks"
echo "  Root: ${ROOT_DIR}"
echo "============================================================"

FAILED=()

for folder in "${SUBFOLDERS[@]}"; do
    echo ""
    echo "===================================================="
    echo "  Stage: ${folder}"
    echo "===================================================="

    stage_dir="${ROOT_DIR}/${folder}"

    if [ ! -d "${stage_dir}" ]; then
        echo "  ERROR: directory not found: ${stage_dir}"
        FAILED+=("${folder}")
        break
    fi

    if [ ! -f "${stage_dir}/build.sh" ]; then
        echo "  ERROR: build.sh not found in ${stage_dir}"
        FAILED+=("${folder}")
        break
    fi

    # ── Prerequisite checks ───────────────────────────────────────────────────
    prereq_ok=0

    case "${folder}" in
        aa_lpf)
            echo "  Checking source and stimulus files..."
            check_files "${stage_dir}" "${prereqs_aa_lpf[@]}" || prereq_ok=1
            ;;
        audio_lpf)
            echo "  Checking source and stimulus files..."
            check_files "${stage_dir}" "${prereqs_audio_lpf[@]}" || prereq_ok=1
            ;;
        de_emphasis)
            echo "  Checking source and stimulus files..."
            check_files "${stage_dir}" "${prereqs_de_emphasis[@]}" || prereq_ok=1
            ;;
        fir_decimation)
            echo "  Checking source and stimulus files..."
            check_files "${stage_dir}" "${prereqs_fir_decimation[@]}" || prereq_ok=1
            ;;
        fm_disc)
            echo "  Checking source and stimulus files..."
            check_files "${stage_dir}" "${prereqs_fm_disc[@]}" || prereq_ok=1
            ;;
        freq_corr)
            echo "  Checking source and stimulus files..."
            check_files "${stage_dir}" "${prereqs_freq_corr[@]}" || prereq_ok=1
            ;;
        nco)
            echo "  Checking source and stimulus files..."
            check_files "${stage_dir}" "${prereqs_nco[@]}" || prereq_ok=1
            ;;
        fm_demod)
            check_upstream_ips || prereq_ok=1
            ;;
        fm_demod_axis_with_sidechannels)
            check_upstream_ips || prereq_ok=1
            check_fm_demod_ip  || prereq_ok=1
            ;;
        audio_ppdma)
            echo "  Checking source files..."
            check_files "${stage_dir}" "${prereqs_audio_ppdma[@]}" || prereq_ok=1
            ;;
        iq_ppdma)
            echo "  Checking source files..."
            check_files "${stage_dir}" "${prereqs_iq_ppdma[@]}" || prereq_ok=1
            ;;
        end_system)
            echo "  Checking source files..."
            check_files "${stage_dir}" "${prereqs_end_system[@]}" || prereq_ok=1
            check_fm_demod_ip || prereq_ok=1
            ;;
    esac

    if [ $prereq_ok -ne 0 ]; then
        echo ""
        echo "  PREREQUISITE CHECK FAILED for stage: ${folder}"
        echo "  Generate the missing files (run the relevant MATLAB script or"
        echo "  copy the fixed RTL/HLS file from the ultra96 branch), then"
        echo "  rerun this script or run ${folder}/build.sh directly."
        FAILED+=("${folder}")
        break
    fi

    # ── Run the stage ─────────────────────────────────────────────────────────
    echo "  Prerequisites satisfied -- running build.sh..."
    chmod +x "${stage_dir}/build.sh"

    if ! (cd "${stage_dir}" && ./build.sh); then
        echo ""
        echo "  BUILD FAILED for stage: ${folder}"
        echo "  Check the log file in ${stage_dir}/ for details."
        FAILED+=("${folder}")
        break
    fi

    echo "  Stage complete: ${folder}"
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "===================================================="
if [ ${#FAILED[@]} -eq 0 ]; then
    echo "  All stages completed successfully."
else
    echo "  BUILD STOPPED at stage: ${FAILED[*]}"
    echo "  Fix the issue above and rerun."
    exit 1
fi
echo "===================================================="
