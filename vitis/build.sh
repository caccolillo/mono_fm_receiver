#!/usr/bin/env bash
#
# build.sh - runs the Vitis stage only (vitis_create.tcl): platform +
# application build via xsct.
#
# Usage:
#   ./build.sh              # run it
#   ./build.sh -h           # help
#
# IMPORTANT: run this directly (./build.sh), do NOT `source` it. Sourcing
# runs it in your current shell, and this script calls `exit` on failure -
# with `set -e` active that would end your interactive shell session, not
# just the script.
#
# Assumes vitis_create.tcl lives alongside this script. Override with
# --vitis-dir <path> or the VITIS_DIR environment variable if not.

# Guard against being sourced - refuse rather than risk `exit` killing
# the caller's interactive shell.
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    echo "ERROR: don't 'source' this script - run it directly instead:" >&2
    echo "         ./build.sh" >&2
    return 1 2>/dev/null || exit 1
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VITIS_TCL="vitis_create.tcl"
LOG_DIR="$SCRIPT_DIR/logs"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
VITIS_DIR="${VITIS_DIR:-$SCRIPT_DIR}"

usage() {
    cat << USAGE_EOF
Usage: $0 [options]

  --vitis-dir <path>   Directory containing vitis_create.tcl (default: .)
  -h, --help           Show this help
USAGE_EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --vitis-dir) VITIS_DIR="$2"; shift 2 ;;
        -h|--help)   usage; exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

VITIS_DIR="$(cd "$VITIS_DIR" && pwd)"

mkdir -p "$LOG_DIR"

if ! command -v xsct >/dev/null 2>&1; then
    echo "ERROR: 'xsct' not found in PATH." >&2
    echo "       Source the Vitis settings script first, e.g.:" >&2
    echo "         source /tools/Xilinx/Vitis/2022.2/settings64.sh" >&2
    exit 1
fi

if [ ! -f "$VITIS_DIR/$VITIS_TCL" ]; then
    echo "ERROR: $VITIS_TCL not found in $VITIS_DIR" >&2
    echo "       (pass --vitis-dir <path> if it lives somewhere else)" >&2
    exit 1
fi

LOGFILE="$LOG_DIR/vitis_${TIMESTAMP}.log"
echo "=== Starting Vitis (vitis_create.tcl) in $VITIS_DIR ==="
echo "    Log: $LOGFILE"

if (cd "$VITIS_DIR" && xsct "$VITIS_TCL") > "$LOGFILE" 2>&1; then
    echo "=== Vitis build succeeded ==="
    echo "  ELF: $VITIS_DIR/vitis_workspace/fm_demod_app/Debug/fm_demod_app.elf"
else
    rc=$?
    echo "=== Vitis build FAILED (exit code $rc) ===" >&2
    echo "--- last 40 lines of $LOGFILE ---" >&2
    tail -n 40 "$LOGFILE" >&2
    exit "$rc"
fi
