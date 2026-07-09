#!/bin/bash
#
# build_petalinux.sh - Scaffold and build a PetaLinux project for the
# sdr_fm_receiver design (Zybo Z7-10, xc7z010clg400-1), including the
# fmdemod-linux userspace C app.
#
# TARGETS PetaLinux 2022.2 CLI conventions (matching the Vivado/Vitis
# version used throughout this project). Minor flag renames between
# PetaLinux releases are common -- if any petalinux-* command below
# errors on "unrecognized option", check `petalinux-<cmd> --help` on
# your installed version first.
#
# ----------------------------------------------------------------------
# CRITICAL PREREQUISITE THIS SCRIPT CANNOT VERIFY OR FIX:
#
# Ethernet (GEM) and USB support can only exist in the resulting Linux
# image if those PS7 peripherals were actually enabled at the hardware
# level, in Vivado's PS7 "Customize IP" dialog (Peripheral I/O Pins /
# MIO Configuration tab -- ENET0, USB0). This was NOT confirmed
# anywhere in this project's bd.tcl during earlier work on this design
# (only PCW_FPGA0_PERIPHERAL_FREQMHZ / clock-related PS7 config was
# reviewed, not the full MIO/peripheral enable list). PetaLinux only
# builds device-tree/driver support for what's actually present in the
# imported XSA -- it cannot add hardware peripherals that were never
# enabled in Vivado. If GEM0/USB0 aren't in the XSA, this whole script
# will still run successfully and just silently produce an image
# without working Ethernet/USB. Before running this: re-open the PS7
# IP in Vivado, confirm ENET0 and USB0 are enabled under MIO
# Configuration, regenerate the bitstream, and re-export the XSA.
# ----------------------------------------------------------------------

set -e

# ---- Guard against being sourced (the #1 cause of bitbake being stopped) ----
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    echo "ERROR: Do not source this script. Run it directly:"
    echo "  bash $(basename "${BASH_SOURCE[0]}")"
    echo "or:  ./$(basename "${BASH_SOURCE[0]}")"
    echo "Sourcing causes bitbake to be stopped by the shell's job control."
    return 1 2>/dev/null || exit 1
fi

# ---- Log file: everything goes to build_petalinux.log alongside this script --
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/build_petalinux.log"
echo "=== PetaLinux build log: ${LOG_FILE} ==="
echo "=== Started: $(date) ===" | tee "${LOG_FILE}"
# Redirect all subsequent stdout and stderr through tee into the log file,
# while still printing to the terminal.
exec > >(tee -a "${LOG_FILE}") 2>&1

# ---- Configuration -- adjust these for your environment -------------
PROJECT_NAME="${PROJECT_NAME:-sdr_fm_receiver_linux}"
XSA_PATH="${XSA_PATH:-./sdr_fm_receiver_wrapper.xsa}"   # exported from Vivado
# Resolve to absolute path NOW, before any cd changes the working directory.
# petalinux-config --get-hw-description accepts either the .xsa file directly
# or its containing directory; passing the absolute .xsa path works in both
# PetaLinux 2022.1 and 2022.2 without ambiguity.
XSA_ABS="$(readlink -f "${XSA_PATH}")"
APP_NAME="fmdemod-linux"
APP_SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/app"
DTSI_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/reserved-memory.dtsi"
# Also accept it from the app/ subdirectory
if [ ! -f "${DTSI_SRC}" ]; then
    DTSI_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/app/reserved-memory.dtsi"
fi

echo "=== PetaLinux build for ${PROJECT_NAME} ==="

if [ ! -f "${XSA_ABS}" ]; then
    echo "ERROR: XSA not found at ${XSA_ABS}"
    echo "Export it from Vivado first: File -> Export -> Export Hardware"
    echo "(include bitstream), then point XSA_PATH at the resulting .xsa."
    exit 1
fi

# Preflight: check app source files exist before starting any petalinux work,
# so a missing file fails immediately rather than halfway through a long build.
for f in "fmdemod-linux.c" "resample_50k_to_48k.c" "resample_coeffs.h"; do
    if [ ! -f "${APP_SRC_DIR}/${f}" ]; then
        echo "ERROR: App source file not found: ${APP_SRC_DIR}/${f}"
        echo "Expected directory layout:"
        echo "  $(dirname "${APP_SRC_DIR}")/"
        echo "  ├── build_petalinux.sh"
        echo "  ├── reserved-memory.dtsi"
        echo "  └── app/"
        echo "      ├── fmdemod-linux.c"
        echo "      ├── resample_50k_to_48k.c"
        echo "      └── resample_coeffs.h"
        exit 1
    fi
done

if ! command -v petalinux-create >/dev/null 2>&1; then
    echo "ERROR: petalinux-create not found. Source your PetaLinux"
    echo "settings.sh first (e.g. 'source /tools/Xilinx/PetaLinux/2022.2/settings.sh')."
    exit 1
fi

# ---- 1. Create the project -------------------------------------------
if [ ! -d "${PROJECT_NAME}" ]; then
    echo "--- Creating project ---"
    petalinux-create -t project --template zynq -n "${PROJECT_NAME}"
else
    echo "--- Project ${PROJECT_NAME} already exists, reusing it ---"
fi

cd "${PROJECT_NAME}"

# ---- 2. Import the hardware description (device tree, PS7 config) ----
echo "--- Importing hardware description from ${XSA_ABS} ---"
petalinux-config --get-hw-description="${XSA_ABS}" \
                  --silentconfig

# ---- 3. Reserved-memory device-tree overlay for the ppdma DDR buffers
#
# The audio_ppdma_0/iq_ppdma_0 ping/pong/dest buffers live at fixed
# physical addresses (0x3E000000-0x3E4FFFFF, matching the xlconstant
# values in bd.tcl) that userspace accesses directly via /dev/mem.
# Without this reserved-memory/no-map node, the kernel's own memory
# allocator is free to also hand out pages in this range to unrelated
# processes/drivers, corrupting whatever the PL cores are doing there.
# See reserved-memory.dtsi (delivered alongside this script) for the
# actual node definition.
# ----------------------------------------------------------------------
DT_USER_DIR="project-spec/meta-user/recipes-bsp/device-tree/files"
mkdir -p "${DT_USER_DIR}"
if [ -f "${DTSI_SRC}" ]; then
    echo "--- Installing reserved-memory device-tree overlay ---"
    cp "${DTSI_SRC}" "${DT_USER_DIR}/system-user.dtsi"
else
    echo "WARNING: ${DTSI_SRC} not found -- reserved-memory overlay NOT"
    echo "installed. The ppdma DDR buffers are unprotected from the"
    echo "kernel's allocator until you add this manually."
fi

# ---- 4. rootfs packages: libgpiod (+ CLI tools for debugging) --------
# Preset non-interactively by appending CONFIG_ lines to rootfs_config.
# NOTE: do NOT add openssh -- petalinux-image-minimal already includes
# packagegroup-core-ssh-dropbear which pulls in dropbear. openssh and
# dropbear both provide sshd and CONFLICT -- openssh cannot be added.
# Keep dropbear (the PetaLinux default) and use dropbear-scp for file
# transfer instead of openssh-sftp-server.
ROOTFS_CONFIG="project-spec/configs/rootfs_config"
echo "--- Enabling libgpiod (+ tools), dropbear-scp, dhcp client in rootfs ---"
for pkg in \
    CONFIG_libgpiod \
    CONFIG_gpiod-tools \
    CONFIG_dropbear-scp \
    CONFIG_udhcpc \
    CONFIG_i2c-tools
do
    if ! grep -q "^${pkg}=y" "${ROOTFS_CONFIG}" 2>/dev/null; then
        echo "${pkg}=y" >> "${ROOTFS_CONFIG}"
    fi
done
petalinux-config -c rootfs --silentconfig

# ---- 5. Scaffold the userspace app, then overwrite with our source ---
if [ ! -d "project-spec/meta-user/recipes-apps/${APP_NAME}" ]; then
    echo "--- Creating app recipe ${APP_NAME} ---"
    petalinux-create -t apps --name "${APP_NAME}" --enable --template c
fi

APP_RECIPE_DIR="project-spec/meta-user/recipes-apps/${APP_NAME}"
APP_FILES_DIR="${APP_RECIPE_DIR}/files"

echo "--- Installing fmdemod-linux source into the app recipe ---"
mkdir -p "${APP_FILES_DIR}"
cp "${APP_SRC_DIR}/fmdemod-linux.c"        "${APP_FILES_DIR}/${APP_NAME}.c"
cp "${APP_SRC_DIR}/resample_50k_to_48k.c" "${APP_FILES_DIR}/resample_50k_to_48k.c"
cp "${APP_SRC_DIR}/resample_coeffs.h"     "${APP_FILES_DIR}/resample_coeffs.h"

# Write a known-correct Makefile rather than trying to patch the
# scaffolded one, whose exact structure varies between PetaLinux versions
# and whose variable names can't be reliably sed-patched.
# This Makefile:
#   - compiles both .c files explicitly
#   - links against -lgpiod (libgpiod character device API)
#   - links against -lm (lroundf in resample_50k_to_48k.c)
APP_MAKEFILE="${APP_FILES_DIR}/Makefile"
echo "--- Writing app Makefile (replacing scaffolded version) ---"
cat > "${APP_MAKEFILE}" << 'MAKEFILE_EOF'
APP = fmdemod-linux

OBJS = fmdemod-linux.o resample_50k_to_48k.o

# Do NOT override CFLAGS or LDFLAGS — Yocto injects the correct sysroot
# paths, security flags, and library search paths via the environment.
# We only append what we specifically need on top of what Yocto provides.
CFLAGS  += -Wall -O2 -I.
LDFLAGS += -lgpiod -lm

.PHONY: all clean

all: $(APP)

$(APP): $(OBJS)
	$(CC) $(OBJS) $(LDFLAGS) -o $@

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

resample_50k_to_48k.o: resample_50k_to_48k.c resample_coeffs.h
fmdemod-linux.o: fmdemod-linux.c resample_coeffs.h

clean:
	rm -f $(APP) $(OBJS)
MAKEFILE_EOF

APP_BB="${APP_RECIPE_DIR}/${APP_NAME}.bb"
if [ -f "${APP_BB}" ]; then
    if ! grep -q "libgpiod" "${APP_BB}"; then
        echo "--- Adding libgpiod DEPENDS/RDEPENDS to app recipe ---"
        # DEPENDS: ensures libgpiod headers+library are staged before compile
        echo 'DEPENDS += "libgpiod"' >> "${APP_BB}"
        # RDEPENDS: ensures libgpiod.so is installed on the rootfs at runtime
        echo 'RDEPENDS:${PN} += "libgpiod"' >> "${APP_BB}"
    fi
    if ! grep -q "resample_50k_to_48k" "${APP_BB}"; then
        echo "--- Adding companion sources to app recipe SRC_URI ---"
        echo 'SRC_URI += "file://resample_50k_to_48k.c file://resample_coeffs.h"' >> "${APP_BB}"
    fi
fi

# ---- 6. Build --------------------------------------------------------
echo "--- Building (this takes a while the first time) ---"
petalinux-build

# ---- 7. Package the boot image ----------------------------------------
# TODO: confirm these paths match your actual build output -- FSBL/
# bitstream/u-boot filenames can vary by project layout.
echo "--- Packaging BOOT.BIN ---"
petalinux-package --boot \
    --fsbl images/linux/zynq_fsbl.elf \
    --fpga images/linux/system.bit \
    --u-boot images/linux/u-boot.elf \
    --force

echo "=== Done ==="
echo "Boot image: images/linux/BOOT.BIN"
echo "Kernel image + rootfs: images/linux/image.ub (or Image + rootfs.cpio.gz.u-boot, depending on config)"
echo ""
echo "REMINDER: verify Ethernet/USB actually came up on target with"
echo "'ip link' / 'lsusb' -- this script cannot confirm those peripherals"
echo "were enabled in the PS7 hardware config it imported."
echo ""
echo "=== Finished: $(date) ==="
echo "Full build log saved to: ${LOG_FILE}"
