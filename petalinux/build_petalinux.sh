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

# ---- Configuration -- adjust these for your environment -------------
PROJECT_NAME="${PROJECT_NAME:-sdr_fm_receiver_linux}"
XSA_PATH="${XSA_PATH:-./sdr_fm_receiver_wrapper.xsa}"   # exported from Vivado
APP_NAME="fmdemod-linux"
APP_SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/app"
DTSI_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/reserved-memory.dtsi"

echo "=== PetaLinux build for ${PROJECT_NAME} ==="

if [ ! -f "${XSA_PATH}" ]; then
    echo "ERROR: XSA not found at ${XSA_PATH}"
    echo "Export it from Vivado first: File -> Export -> Export Hardware"
    echo "(include bitstream), then point XSA_PATH at the resulting .xsa."
    exit 1
fi

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
echo "--- Importing hardware description from ${XSA_PATH} ---"
petalinux-config --get-hw-description="$(dirname "$(readlink -f "${XSA_PATH}")")" \
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
# Preset non-interactively by appending CONFIG_ lines to rootfs_config,
# then re-running config in silent mode to apply them. This is the
# standard non-interactive equivalent of `petalinux-config -c rootfs`.
ROOTFS_CONFIG="project-spec/configs/rootfs_config"
echo "--- Enabling libgpiod (+ tools), openssh, dhcp client in rootfs ---"
for pkg in \
    CONFIG_libgpiod \
    CONFIG_gpiod-tools \
    CONFIG_openssh \
    CONFIG_openssh-sftp-server \
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
# petalinux-create's C template names the generated source after the
# app: fmdemod-linux.c. Overwrite it with our real implementation.
cp "${APP_SRC_DIR}/fmdemod-linux.c" "${APP_FILES_DIR}/${APP_NAME}.c"

# The scaffolded Makefile already builds ${APP_NAME}.c by default --
# but our app links against libgpiod, so the Makefile and recipe .bb
# need that dependency added. Patch both if not already present.
APP_MAKEFILE="${APP_FILES_DIR}/Makefile"
if [ -f "${APP_MAKEFILE}" ] && ! grep -q "lgpiod" "${APP_MAKEFILE}"; then
    echo "--- Adding -lgpiod to app Makefile ---"
    sed -i 's/^LDFLAGS.*/& -lgpiod/' "${APP_MAKEFILE}" || \
        echo "LDFLAGS += -lgpiod" >> "${APP_MAKEFILE}"
fi

APP_BB="${APP_RECIPE_DIR}/${APP_NAME}.bb"
if [ -f "${APP_BB}" ] && ! grep -q "libgpiod" "${APP_BB}"; then
    echo "--- Adding libgpiod DEPENDS to app recipe ---"
    echo 'DEPENDS += "libgpiod"' >> "${APP_BB}"
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
