#!/usr/bin/env bash
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
# OUTPUT ARCHITECTURE NOTE: earlier revisions of this script wrapped the
# ENTIRE script's output through one blanket `exec > >(tee ...) 2>&1`
# redirect at the top. That works, but funnels every single subprocess's
# stdout through one pipe stage, and several tools (petalinux-config in
# particular) detect a non-tty stdout and switch to fully-buffered
# output internally -- meaning real progress can sit invisible in a
# buffer for a long time even though work is genuinely happening.
# Restructured to pipe only the specific long-running commands directly
# at their own call site instead (matching a working pattern from a
# sibling project's build script), which avoids that extra buffering
# layer, plus stdbuf as a second line of defense on the two config steps
# that are still expected to be quiet by design.
#
# ----------------------------------------------------------------------
# CRITICAL PREREQUISITE THIS SCRIPT CANNOT VERIFY OR FIX:
#
# Ethernet (GEM) and USB support can only exist in the resulting Linux
# image if those PS peripherals were actually enabled at the hardware
# level, in Vivado's Zynq UltraScale+ PS "Customize IP" dialog
# (PS-PL Configuration / MIO Configuration -- ENET0/1, USB0/1). This was
# NOT confirmed anywhere in this project's bd.tcl during earlier work on
# the Ultra96-V2 port (only PL0 clock / AXI HP0/GP0 config was reviewed,
# not the full MIO/peripheral enable list). PetaLinux only builds
# device-tree/driver support for what's actually present in the
# imported XSA -- it cannot add hardware peripherals that were never
# enabled in Vivado. If GEM0/USB0 aren't in the XSA, this whole script
# will still run successfully and just silently produce an image
# without working Ethernet/USB. Before running this: re-open the PS IP
# in Vivado, confirm ENET0 and USB0 are enabled, regenerate the
# bitstream, and re-export the XSA.
# ----------------------------------------------------------------------

set -euo pipefail

# ---- Guard against being sourced (the #1 cause of bitbake being stopped) ----
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    echo "ERROR: Do not source this script. Run it directly:"
    echo "  bash $(basename "${BASH_SOURCE[0]}")"
    echo "or:  ./$(basename "${BASH_SOURCE[0]}")"
    echo "Sourcing causes bitbake to be stopped by the shell's job control."
    return 1 2>/dev/null || exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/build_petalinux.log"
echo "=== Started: $(date) ===" > "${LOG_FILE}"

# ---- Colours / helpers (adopted from a sibling project's build script) -----
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GRN}[INFO]${NC}  $*" | tee -a "${LOG_FILE}"; }
warn()  { echo -e "${YLW}[WARN]${NC}  $*" | tee -a "${LOG_FILE}"; }
error() { echo -e "${RED}[ERROR]${NC} $*" | tee -a "${LOG_FILE}"; exit 1; }
step()  { echo -e "\n${YLW}========================================${NC}" | tee -a "${LOG_FILE}"; \
          echo -e "${YLW} $*${NC}" | tee -a "${LOG_FILE}"; \
          echo -e "${YLW}========================================${NC}" | tee -a "${LOG_FILE}"; }

# ---- Configuration -- adjust these for your environment -------------
PROJECT_NAME="${PROJECT_NAME:-sdr_fm_receiver_linux}"
XSA_PATH="${XSA_PATH:-./sdr_fm_receiver_wrapper.xsa}"   # exported from Vivado
# Resolve to absolute path NOW, before any cd changes the working directory.
XSA_ABS="$(readlink -f "${XSA_PATH}")"
APP_NAME="fmdemod-linux"
APP_SRC_DIR="${SCRIPT_DIR}/app"
DTSI_SRC="${SCRIPT_DIR}/reserved-memory.dtsi"
# Also accept it from the app/ subdirectory
if [ ! -f "${DTSI_SRC}" ]; then
    DTSI_SRC="${SCRIPT_DIR}/app/reserved-memory.dtsi"
fi

step "1/7  Validating prerequisites"

if [ ! -f "${XSA_ABS}" ]; then
    error "XSA not found at ${XSA_ABS} -- export it from Vivado first \
(File -> Export -> Export Hardware, include bitstream), then point \
XSA_PATH at the resulting .xsa."
fi

# Preflight: check app source files exist before starting any petalinux work,
# so a missing file fails immediately rather than halfway through a long build.
for f in "fmdemod-linux.c" "resample_50k_to_48k.c" "resample_coeffs.h"; do
    if [ ! -f "${APP_SRC_DIR}/${f}" ]; then
        error "App source file not found: ${APP_SRC_DIR}/${f}\n\
Expected directory layout:\n\
  $(dirname "${APP_SRC_DIR}")/\n\
  ├── build_petalinux.sh\n\
  ├── reserved-memory.dtsi\n\
  └── app/\n\
      ├── fmdemod-linux.c\n\
      ├── resample_50k_to_48k.c\n\
      └── resample_coeffs.h"
    fi
done

if ! command -v petalinux-create >/dev/null 2>&1; then
    error "petalinux-create not found. Source your PetaLinux settings.sh \
first (e.g. 'source /tools/Xilinx/PetaLinux/2022.2/settings.sh')."
fi

info "XSA:     ${XSA_ABS}"
info "Project: ${SCRIPT_DIR}/${PROJECT_NAME}"
info "Log:     ${LOG_FILE}"

# ---- 2. Create the project -------------------------------------------
step "2/7  Creating PetaLinux project"
if [ ! -d "${PROJECT_NAME}" ]; then
    # BUG FOUND (found via a much deeper investigation than it should
    # have taken): this was previously --template zynq, which scaffolds
    # a Zynq-7000/Cortex-A9 project. The Ultra96-V2 is Zynq
    # UltraScale+/Cortex-A53 -- confirmed directly by inspecting the
    # generated project-spec/configs/config, which showed
    # CONFIG_SUBSYSTEM_PROCESSOR_PS7_CORTEXA9_0_SELECT=y and a
    # PS7-specific u-boot defconfig despite a real ZU+ XSA being
    # imported into the same project. That fundamental family mismatch
    # -- a PS7/Cortex-A9 Kconfig tree base, with a genuine ZU+ hardware
    # description merged into it via --get-hw-description -- is almost
    # certainly what caused an unrelated-looking infinite Kconfig
    # reprompt loop (SUBSYSTEM_UBOOT_DEVICETREE_OFFSET) further down:
    # pre-seeding that one symbol's value didn't help, because the real
    # problem was the two halves of the config disagreeing about which
    # CPU exists in the first place, not that one symbol specifically.
    petalinux-create -t project --template zynq -n "${PROJECT_NAME}"
    info "Project created: ${SCRIPT_DIR}/${PROJECT_NAME}"
else
    warn "Project ${PROJECT_NAME} already exists, reusing it"
fi

cd "${PROJECT_NAME}"

# ---- WORKAROUND for a confirmed --silentconfig infinite-loop bug ------
#
# Root cause found the hard way: SUBSYSTEM_UBOOT_DEVICETREE_OFFSET has
# an empty ([]) default in this project's u-boot Kconfig. --silentconfig
# is supposed to auto-accept the bracketed default for every prompt
# without asking a human -- but it can't resolve an EMPTY default for
# this specific string-type option, so instead of accepting it or
# failing cleanly, it re-prints the identical prompt forever. Confirmed
# directly: a multi-hour hang produced a 97 GB, then later a 6+ GB,
# config.log consisting of nothing but this one repeated line:
#   "Devicetree offset (SUBSYSTEM_UBOOT_DEVICETREE_OFFSET) [] (NEW)"
#
# Fix: pre-seed a real value for this symbol in project-spec/configs/
# config BEFORE the first petalinux-config call. Per PetaLinux's own
# docs, --silentconfig reuses whatever's already on record for a symbol
# rather than treating it as new -- so if this already has a valid
# answer on file, the broken empty-default prompt path never triggers.
# 0x0 (no additional offset beyond U-Boot's own default placement) is
# the safe/inert choice unless you specifically need a non-default
# devicetree load offset for this hardware.
#
# The config file doesn't exist until the FIRST petalinux-config call
# generates it -- so create a minimal one by hand here, seeded with
# just this one symbol; petalinux-config will merge it with everything
# else it generates from the XSA rather than needing a complete file.
mkdir -p project-spec/configs
CONFIG_FILE="project-spec/configs/config"
if ! grep -q "^CONFIG_SUBSYSTEM_UBOOT_DEVICETREE_OFFSET=" "${CONFIG_FILE}" 2>/dev/null; then
    echo 'CONFIG_SUBSYSTEM_UBOOT_DEVICETREE_OFFSET="0x0"' >> "${CONFIG_FILE}"
    info "Pre-seeded SUBSYSTEM_UBOOT_DEVICETREE_OFFSET=0x0 (works around the"
    info "confirmed --silentconfig infinite-reprompt bug on this symbol's"
    info "empty default -- change this value first if your hardware needs"
    info "a non-zero devicetree load offset)"
fi

# ---- SECOND, MORE FUNDAMENTAL FIX ----
#
# CONFIRMED BUG (found via a known-working sibling Ultra96-V2 project's
# own build script): this project's project-spec/configs/config was
# generated with CONFIG_SUBSYSTEM_MACHINE_NAME="template" -- literally
# the generic Kconfig placeholder value, never actually set to the real
# board. Per the sibling project's own comment on the equivalent line:
#   "tells DTG to use the Ultra96-V2 board device tree. Without this
#    PetaLinux generates a generic DTS that lacks the SD 1.8V signalling
#    config -- the board hangs reading the SD card after FSBL."
# This is very likely the actual foundational cause of "all LEDs stuck,
# nothing on UART at all" -- more fundamental than the SD partition-type
# fix or the no-1-8-v dtsi override, both of which are still correct and
# still needed, but sit on top of a device tree that was never actually
# board-specific to begin with.
# ZYBO Z7-10 NOTE: the Ultra96 reasoning above does NOT apply here.
# That failure was caused by missing SD 1.8V (UHS-I) signalling config,
# which is a ZynqMP concern -- Zynq-7000's SDIO controller has no 1.8V
# signalling mode at all. There is also no Zybo BSP installed in this
# PetaLinux (checked: no zybo machine conf under meta-xilinx-bsp), so
# setting a board machine name would fail at device-tree generation.
#
# For a custom block design the correct approach is to leave the machine
# name at the generic template and let DTG derive the device tree from
# the XSA. The reserved-memory overlay in app/reserved-memory.dtsi
# supplies the only board-specific binding this application depends on.
info "Leaving CONFIG_SUBSYSTEM_MACHINE_NAME at default -- DTG will derive"
info "the device tree from the XSA (no Zybo BSP installed, and none needed"
info "for this design)."

# ---- ARCHITECTURE SWITCH: initramfs -> ext4 two-partition rootfs ----
#
# Switching from CONFIG_SUBSYSTEM_ROOTFS_INITRD (rootfs embedded in
# image.ub) to CONFIG_SUBSYSTEM_ROOTFS_EXT4 (separate ext4 partition),
# matching a known-working sibling Ultra96-V2 project's proven boot
# architecture exactly, rather than continuing to debug an unproven one.
# Direct evidence this project's initramfs path was never actually
# confirmed working end-to-end: after flashing with the previous
# single-partition create_sd.sh, only ONE partition (boot) ever showed
# up when the card was reinserted into a PC -- expected for that layout,
# but the sibling project's own flash script produces two visible
# partitions (boot + rootfs) on a card that's confirmed to actually
# boot. Matching that architecture directly, rather than patching the
# unproven one fix at a time.
if ! grep -q "^CONFIG_SUBSYSTEM_ROOTFS_EXT4=y" "${CONFIG_FILE}" 2>/dev/null; then
    cat >> "${CONFIG_FILE}" << 'ROOTFSCFG'
CONFIG_SUBSYSTEM_ROOTFS_EXT4=y
CONFIG_SUBSYSTEM_SDROOT_DEV="/dev/mmcblk0p2"
CONFIG_SUBSYSTEM_RFS_FORMATS="ext4 ext4.gz"
CONFIG_SUBSYSTEM_BOOTARGS_AUTO=n
CONFIG_SUBSYSTEM_USER_CMDLINE="earlycon console=ttyPS0,115200 root=/dev/mmcblk0p2 rw rootwait"
ROOTFSCFG
    info "Pre-seeded ext4 two-partition rootfs config (was initramfs/"
    info "CONFIG_SUBSYSTEM_ROOTFS_INITRD, embedded in image.ub -- never"
    info "confirmed working end-to-end on this project). Produces a"
    info "separate rootfs.ext4 image file for create_sd.sh to dd onto a"
    info "second partition, matching the sibling project's proven layout."
fi

# ---- 3. Import the hardware description (device tree, PS config) ----
step "3/7  Importing hardware description"
info "Quiet for a while even when working (--silentconfig suppresses the"
info "usual interactive menu output). stdbuf forces whatever it DOES"
info "print to appear live rather than sitting buffered."
stdbuf -oL -eL petalinux-config --get-hw-description="${XSA_ABS}" \
                  --silentconfig 2>&1 | tee -a "${LOG_FILE}"
info "Hardware description imported"

# ---- 4. Reserved-memory device-tree overlay for the ppdma DDR buffers
#
# The audio_ppdma_0/iq_ppdma_0 ping/pong/dest buffers live at fixed
# physical addresses (0x10000000-0x104FFFFF, matching the xlconstant
# values in bd.tcl) that userspace accesses directly via /dev/mem.
# Without this reserved-memory/no-map node, the kernel's own memory
# allocator is free to also hand out pages in this range to unrelated
# processes/drivers, corrupting whatever the PL cores are doing there.
# See reserved-memory.dtsi (delivered alongside this script) for the
# actual node definition.
# ----------------------------------------------------------------------
step "4/7  Installing device tree overlay + rootfs packages"
DT_USER_DIR="project-spec/meta-user/recipes-bsp/device-tree/files"
mkdir -p "${DT_USER_DIR}"
if [ -f "${DTSI_SRC}" ]; then
    cp "${DTSI_SRC}" "${DT_USER_DIR}/system-user.dtsi"
    info "Installed reserved-memory device-tree overlay"
else
    warn "${DTSI_SRC} not found -- reserved-memory overlay NOT installed."
    warn "The ppdma DDR buffers are unprotected from the kernel's"
    warn "allocator until you add this manually."
fi

# rootfs packages: libgpiod (+ CLI tools for debugging), preset
# non-interactively by appending CONFIG_ lines to rootfs_config.
# NOTE: do NOT add openssh -- petalinux-image-minimal already includes
# packagegroup-core-ssh-dropbear which pulls in dropbear. openssh and
# dropbear both provide sshd and CONFLICT -- openssh cannot be added.
# Keep dropbear (the PetaLinux default) and use dropbear-scp for file
# transfer instead of openssh-sftp-server.
ROOTFS_CONFIG="project-spec/configs/rootfs_config"
for pkg in \
    CONFIG_libgpiod \
    CONFIG_gpiod-tools \
    CONFIG_dropbear-scp \
    CONFIG_udhcpc \
    CONFIG_i2c-tools
do
    if ! grep -q "^${pkg}=y" "${ROOTFS_CONFIG}" 2>/dev/null; then
        echo "${pkg}=y" >> "${ROOTFS_CONFIG}"
        info "Enabled package: ${pkg}"
    fi
done
info "Running rootfs config (quiet for a bit, same reason as step 3)"
stdbuf -oL -eL petalinux-config -c rootfs --silentconfig 2>&1 | tee -a "${LOG_FILE}"
info "Rootfs config complete"

# ---- 5. Scaffold the userspace app, then overwrite with our source ---
step "5/7  Creating fmdemod-linux app recipe"
if [ ! -d "project-spec/meta-user/recipes-apps/${APP_NAME}" ]; then
    petalinux-create -t apps --name "${APP_NAME}" --enable --template c
    info "App recipe scaffolded: ${APP_NAME}"
fi

APP_RECIPE_DIR="project-spec/meta-user/recipes-apps/${APP_NAME}"
APP_FILES_DIR="${APP_RECIPE_DIR}/files"

mkdir -p "${APP_FILES_DIR}"
cp "${APP_SRC_DIR}/fmdemod-linux.c"       "${APP_FILES_DIR}/${APP_NAME}.c"
cp "${APP_SRC_DIR}/resample_50k_to_48k.c" "${APP_FILES_DIR}/resample_50k_to_48k.c"
cp "${APP_SRC_DIR}/resample_coeffs.h"     "${APP_FILES_DIR}/resample_coeffs.h"
info "Installed fmdemod-linux source into the app recipe"

# Write a known-correct Makefile rather than trying to patch the
# scaffolded one, whose exact structure varies between PetaLinux versions
# and whose variable names can't be reliably sed-patched.
# This Makefile:
#   - compiles both .c files explicitly
#   - links against -lgpiod (libgpiod character device API)
#   - links against -lm (lroundf in resample_50k_to_48k.c)
APP_MAKEFILE="${APP_FILES_DIR}/Makefile"
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
info "Wrote app Makefile (replacing scaffolded version)"

APP_BB="${APP_RECIPE_DIR}/${APP_NAME}.bb"
if [ -f "${APP_BB}" ]; then
    if ! grep -q "libgpiod" "${APP_BB}"; then
        # DEPENDS: ensures libgpiod headers+library are staged before compile
        echo 'DEPENDS += "libgpiod"' >> "${APP_BB}"
        # RDEPENDS: ensures libgpiod.so is installed on the rootfs at runtime
        echo 'RDEPENDS:${PN} += "libgpiod"' >> "${APP_BB}"
        info "Added libgpiod DEPENDS/RDEPENDS to app recipe"
    fi
    if ! grep -q "resample_50k_to_48k" "${APP_BB}"; then
        echo 'SRC_URI += "file://resample_50k_to_48k.c file://resample_coeffs.h"' >> "${APP_BB}"
        info "Added companion sources to app recipe SRC_URI"
    fi
fi

# ---- 6. Build --------------------------------------------------------
step "6/7  Building (this takes a while the first time)"
info "Commonly 30 min to a few hours depending on your machine and"
info "whether sstate-cache/downloads are already warm from a prior build."
info "Shows one line per task as it starts/finishes (recipe name +"
info "do_fetch/do_configure/do_compile/do_install/...), without the full"
info "raw command output underneath each one -- if you want that level"
info "of detail later, rerun with -v added to the petalinux-build line."

BUILD_START=$(date +%s)

# No -v: plain bitbake output already prints one line per task as it
# starts and finishes (e.g. "NOTE: recipe foo-1.0-r0: task do_compile:
# Started"/"Succeeded"), which is the actual "what recipe, what's it
# doing" visibility that was wanted -- -v additionally dumps the full
# raw shell/compiler command output underneath every single task, which
# turned out to be too much. This is the middle ground: recipe/task
# names visible, without the firehose of command output.
petalinux-build 2>&1 | tee -a "${LOG_FILE}"
BUILD_EXIT=${PIPESTATUS[0]}

BUILD_END=$(date +%s)
BUILD_ELAPSED=$(( BUILD_END - BUILD_START ))
info "Build step took $(( BUILD_ELAPSED / 60 ))m $(( BUILD_ELAPSED % 60 ))s"

if [ "${BUILD_EXIT}" -ne 0 ]; then
    error "petalinux-build failed (exit ${BUILD_EXIT}). Check ${LOG_FILE}."
fi

# ---- 7. Package the boot image ----------------------------------------
step "7/7  Packaging BOOT.BIN"
# Same PS7-vs-ZU+ mismatch as the template fix above, carried through to
# the packaging step: zynq_fsbl.elf is the Zynq-7000 FSBL name, and this
# also omitted --pmufw entirely, a file that has no Zynq-7000 equivalent
# at all but is MANDATORY on Zynq UltraScale+ -- FSBL hangs at startup
# without it (confirmed pattern from a sibling ZU+ project's build
# script). TODO: still worth confirming these exact filenames against
# your actual build output once it completes -- exact names can vary by
# project layout/PetaLinux version even within the same SoC family.
for f in zynq_fsbl.elf system.bit u-boot.elf; do
    if [ ! -f "images/linux/${f}" ]; then
        error "Missing build artifact: images/linux/${f}"
    fi
done
petalinux-package --boot \
    --fsbl images/linux/zynq_fsbl.elf \
    --fpga images/linux/system.bit \
    --u-boot images/linux/u-boot.elf \
    --force 2>&1 | tee -a "${LOG_FILE}"

info "Done."
info "Boot image: images/linux/BOOT.BIN"
info "Kernel image + rootfs: images/linux/image.ub (or Image + rootfs.cpio.gz.u-boot, depending on config)"
warn "REMINDER: verify Ethernet/USB actually came up on target with"
warn "'ip link' / 'lsusb' -- this script cannot confirm those peripherals"
warn "were enabled in the PS hardware config it imported."
echo "=== Finished: $(date) ===" | tee -a "${LOG_FILE}"
info "Full build log saved to: ${LOG_FILE}"

# ---- Optional SD card creation -----------------------------------------
# Deliberately NOT automatic -- create_sd.sh erases and repartitions
# whatever device it's pointed at, needs root, and asks its own
# interactive "type YES" confirmation. Offering it here (matching the
# same safe pattern as a sibling project's build script) rather than
# just invoking it saves a manual step without ever silently touching a
# disk on your behalf.
CREATE_SD="${SCRIPT_DIR}/create_sd.sh"
if [ -f "${CREATE_SD}" ]; then
    echo ""
    warn "Would you like to prepare an SD card now?"
    echo "  Insert the micro SD card into your PC first."
    echo ""
    lsblk -d -o NAME,SIZE,TYPE,MODEL 2>/dev/null | grep -v loop || lsblk
    echo ""
    read -r -p "Enter SD card device (e.g. /dev/sdb), or press Enter to skip: " SD_DEV
    if [ -n "${SD_DEV}" ]; then
        if [ -b "${SD_DEV}" ]; then
            read -r -p "Path to rds.wav to copy onto the card (optional, press Enter to skip): " WAV_PATH
            # PETALINUX_PROJECT explicitly passed through -- create_sd.sh
            # defaults this off $HOME, which sudo resets to /root by
            # default (not your actual home), so without this it looks
            # for the built images in the wrong place entirely and fails
            # with a confusing "BOOT.BIN not found" even though the build
            # genuinely succeeded.
            sudo PETALINUX_PROJECT="${SCRIPT_DIR}/${PROJECT_NAME}" \
                bash "${CREATE_SD}" "${SD_DEV}" "${WAV_PATH}"
        else
            warn "Device ${SD_DEV} not found -- skipping. Prepare it manually with:"
            warn "  sudo ./create_sd.sh /dev/sdX [path/to/rds.wav]"
        fi
    else
        info "Skipping SD card creation. Run manually when ready:"
        info "  sudo ./create_sd.sh /dev/sdX [path/to/rds.wav]"
    fi
fi
