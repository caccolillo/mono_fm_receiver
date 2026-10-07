#!/bin/bash
# =============================================================================
# build_rtlsdr_petalinux.sh — Build a STANDALONE PetaLinux image for live FM
# reception on the Zybo Z7-10 using an RTL-SDR Blog V3.
#
# Signal path: RTL-SDR -> PS USB -> ping-pong DDR buffers -> PL demod chain
#              -> audio back to DDR -> WAV file.
#
# Modelled directly on build_petalinux.sh from the file-based project, and
# carries ALL of its hard-won workarounds -- the --silentconfig hang, the
# ext4 rootfs switch, the USER_CMDLINE symbol, the Zynq-7000 packaging.
# Each of those was found by hitting the failure; none should be "cleaned
# up" without reproducing the failure first.
#
# WHAT DIFFERS FROM THE FILE-BASED PROJECT
#   - No rds.wav. The I/Q source is a live USB dongle, so the app needs a
#     ring buffer and a reader thread rather than a synchronous file read.
#   - librtlsdr in the rootfs, plus a modprobe blacklist to stop the DVB
#     driver claiming the dongle first.
#   - USB host node in the device tree. DTG generates the controller node
#     from the XSA but knows nothing about the board-level ULPI PHY, so
#     that has to be declared by hand.
#   - Reserved memory at 0x1F000000-0x1F4FFFFF, NOT 0x3E000000. On a 1 GB
#     board the original addresses collide with U-Boot's own relocation
#     area, giving "** Reading file would overwrite reserved memory **"
#     and a failure to load image.ub at all.
#   - Rootfs sized at 512 MB. The default came out 56 MB and filled during
#     the very first capture.
#
# HARDWARE PREREQUISITE THIS SCRIPT CANNOT SATISFY
#   PS USB0 must be enabled in the block design (MIO 28..39). Without it
#   there is no USB host controller and the dongle cannot enumerate --
#   symptom is usbcore registering normally but /sys/bus/usb/devices/
#   being EMPTY. No software configuration recovers from that.
#
# EXPECTED LAYOUT
#   <this directory>/
#   ├── build_rtlsdr_petalinux.sh
#   ├── create_sd.sh
#   ├── sdr_fm_receiver.xsa          (exported from Vivado, with bitstream)
#   └── src/
#       ├── fmdemod-rtlsdr.c
#       ├── resample_50k_to_48k.c
#       ├── resample_coeffs.h
#       ├── pl_rates.h               (measured PL rate + derived coefficients)
#       ├── alsa_live.c              (live ALSA playback, -A flag)
#       ├── alsa_live.h
#       └── gpio_rate_test.c         (standalone GPIO toggle-rate diagnostic)
#
# USAGE
#   source /path/to/petalinux/settings.sh
#   ./build_rtlsdr_petalinux.sh
# =============================================================================

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
LOG_FILE="${SCRIPT_DIR}/build_rtlsdr_petalinux.log"
echo "=== Started: $(date) ===" > "${LOG_FILE}"

# ---- Colours / helpers -------------------------------------------------------
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GRN}[INFO]${NC}  $*" | tee -a "${LOG_FILE}"; }
warn()  { echo -e "${YLW}[WARN]${NC}  $*" | tee -a "${LOG_FILE}"; }
error() { echo -e "${RED}[ERROR]${NC} $*" | tee -a "${LOG_FILE}"; exit 1; }
step()  { echo -e "\n${YLW}========================================${NC}" | tee -a "${LOG_FILE}"; \
          echo -e "${YLW} $*${NC}" | tee -a "${LOG_FILE}"; \
          echo -e "${YLW}========================================${NC}" | tee -a "${LOG_FILE}"; }

# ---- Configuration -- adjust these for your environment ---------------------
PROJECT_NAME="${PROJECT_NAME:-fm_rtlsdr_linux}"
XSA_PATH="${XSA_PATH:-./sdr_fm_receiver.xsa}"
# Resolve to absolute path NOW, before any cd changes the working directory.
XSA_ABS="$(readlink -f "${XSA_PATH}")"
APP_NAME="fmdemod-rtlsdr"
APP_SRC_DIR="${SCRIPT_DIR}/src"

# ---- 1. Validate -------------------------------------------------------------
step "1/8  Validating prerequisites"

if [ ! -f "${XSA_ABS}" ]; then
    error "XSA not found at ${XSA_ABS} -- export it from Vivado first \
(File -> Export -> Export Hardware, include bitstream), then point \
XSA_PATH at the resulting .xsa."
fi

# Preflight the app sources before starting any petalinux work, so a
# missing file fails immediately rather than halfway through a long build.
for f in "fmdemod-rtlsdr.c" "resample_50k_to_48k.c" "resample_coeffs.h" \
         "pl_rates.h" "alsa_live.c" "alsa_live.h" "gpio_rate_test.c"; do
    if [ ! -f "${APP_SRC_DIR}/${f}" ]; then
        error "App source file not found: ${APP_SRC_DIR}/${f}\n\
Expected directory layout:\n\
  ${SCRIPT_DIR}/\n\
  ├── build_rtlsdr_petalinux.sh\n\
  ├── create_sd.sh\n\
  ├── sdr_fm_receiver.xsa\n\
  └── src/\n\
      ├── fmdemod-rtlsdr.c\n\
      ├── resample_50k_to_48k.c\n\
      ├── resample_coeffs.h\n\
      ├── pl_rates.h\n\
      ├── alsa_live.c\n\
      └── alsa_live.h"
    fi
done

if ! command -v petalinux-create >/dev/null 2>&1; then
    error "petalinux-create not found. Source your PetaLinux settings.sh \
first (e.g. 'source /tools/Xilinx/PetaLinux/2022.2/settings.sh')."
fi

# Best-effort check that the XSA actually has USB0. This is the single
# prerequisite the script cannot fix for you, and discovering it is
# missing AFTER a multi-hour build is an expensive way to find out. The
# check greps the .hwh inside the XSA archive, so treat it as indicative
# rather than authoritative -- verify in Vivado if it warns.
if command -v unzip >/dev/null 2>&1; then
    if unzip -p "${XSA_ABS}" '*.hwh' 2>/dev/null | \
         grep -qi 'PCW_USB0_PERIPHERAL_ENABLE.*>1<\|PCW_EN_USB0.*>1<'; then
        info "XSA reports PS USB0 enabled"
    else
        warn "Could not confirm PS USB0 is enabled in this XSA."
        warn "If /sys/bus/usb/devices/ is empty on the target, this is why."
        warn "Fix in vivado/end_system/bd.tcl:"
        warn "  CONFIG.PCW_USB0_PERIPHERAL_ENABLE {1}"
        warn "  CONFIG.PCW_USB0_USB0_IO {MIO 28 .. 39}"
        warn "then rebuild end_system and re-export."
        read -r -p "  Continue anyway? [y/N] " reply
        [ "${reply}" = "y" ] || [ "${reply}" = "Y" ] || exit 1
    fi
fi

if [ -d "${SCRIPT_DIR}/${PROJECT_NAME}" ]; then
    warn "${SCRIPT_DIR}/${PROJECT_NAME} already exists."
    read -r -p "  Delete and recreate? [y/N] " reply
    if [ "${reply}" = "y" ] || [ "${reply}" = "Y" ]; then
        rm -rf "${SCRIPT_DIR:?}/${PROJECT_NAME}"
    else
        error "Aborting rather than clobbering an existing project."
    fi
fi

info "XSA:     ${XSA_ABS}"
info "Project: ${SCRIPT_DIR}/${PROJECT_NAME}"
info "Log:     ${LOG_FILE}"

# ---- 2. Create the project ---------------------------------------------------
step "2/8  Creating PetaLinux project"

# --template zynq: Zynq-7000 / Cortex-A9. NOT zynqMP -- that scaffolds a
# 64-bit project expecting an ATF and PMU firmware that do not exist on
# this part, and fails late and confusingly.
cd "${SCRIPT_DIR}"
petalinux-create -t project --template zynq -n "${PROJECT_NAME}" 2>&1 | tee -a "${LOG_FILE}"
cd "${SCRIPT_DIR}/${PROJECT_NAME}"
info "Project created"

# ---- WORKAROUND for a confirmed --silentconfig infinite-loop bug ------
#
# Carried over verbatim from build_petalinux.sh, where this cost a
# multi-hour hang and a 97 GB config.log before being diagnosed.
#
# Root cause: SUBSYSTEM_UBOOT_DEVICETREE_OFFSET has an empty ([]) default
# in this project's u-boot Kconfig. --silentconfig is supposed to
# auto-accept the bracketed default for every prompt without asking a
# human -- but it cannot resolve an EMPTY default for this specific
# string-type option, so instead of accepting it or failing cleanly it
# re-prints the identical prompt forever:
#   "Devicetree offset (SUBSYSTEM_UBOOT_DEVICETREE_OFFSET) [] (NEW)"
#
# Fix: pre-seed a real value BEFORE the first petalinux-config call.
# --silentconfig reuses whatever is already on record for a symbol
# rather than treating it as new, so the broken empty-default path never
# triggers. 0x0 (no offset beyond U-Boot's own default placement) is the
# inert choice unless you specifically need something else.
#
# The config file does not exist until the first petalinux-config call
# generates it, so create a minimal one by hand here; petalinux-config
# merges it with everything else it derives from the XSA.
mkdir -p project-spec/configs
CONFIG_FILE="project-spec/configs/config"
if ! grep -q "^CONFIG_SUBSYSTEM_UBOOT_DEVICETREE_OFFSET=" "${CONFIG_FILE}" 2>/dev/null; then
    echo 'CONFIG_SUBSYSTEM_UBOOT_DEVICETREE_OFFSET="0x0"' >> "${CONFIG_FILE}"
    info "Pre-seeded SUBSYSTEM_UBOOT_DEVICETREE_OFFSET=0x0 (works around the"
    info "--silentconfig infinite-loop bug -- do not remove this)"
fi

# ---- Machine name: leave at the default -------------------------------------
# The Ultra96 project set CONFIG_SUBSYSTEM_MACHINE_NAME to pick up a board
# BSP device tree, because the Avnet BSP was installed and the board
# needed SD 1.8V signalling config that only the BSP DTS provided.
#
# Neither applies here. There is no Zybo BSP installed (checked: no zybo
# machine conf under meta-xilinx-bsp), so setting a board machine name
# fails at device-tree generation. And SD 1.8V signalling is a ZynqMP
# concern -- Zynq-7000's SDIO controller has no 1.8V mode at all.
#
# For a custom block design the right answer is to let DTG derive the
# device tree from the XSA. The reserved-memory and USB overlays below
# supply the only board-specific bindings this application needs.
info "Leaving CONFIG_SUBSYSTEM_MACHINE_NAME at default -- DTG will derive"
info "the device tree from the XSA (no Zybo BSP installed, none needed)"

# ---- ext4 two-partition rootfs, and an EXPLICIT kernel command line ----
#
# CONFIG_SUBSYSTEM_USER_CMDLINE is the real Kconfig symbol. An earlier
# revision of the sibling script wrote CONFIG_SUBSYSTEM_BOOTARGS, which
# is NOT a symbol -- Kconfig silently discarded it, left USER_CMDLINE
# empty, and the kernel booted all the way to
#   "VFS: Cannot open root device (null) ... Kernel panic"
# on an otherwise perfectly good boot. CONFIG_SUBSYSTEM_BOOTARGS_AUTO is
# real and must stay unset, or it regenerates and overwrites this.
#
# ROOTFS_SIZE: the default produced a 56 MB filesystem that filled during
# the first capture (df showed 100% with 0 available). A live stream
# writes ~100 KB/s continuously, so this needs real room.
if ! grep -q "^CONFIG_SUBSYSTEM_ROOTFS_EXT4=y" "${CONFIG_FILE}" 2>/dev/null; then
    cat >> "${CONFIG_FILE}" << 'ROOTFSCFG'
CONFIG_SUBSYSTEM_ROOTFS_EXT4=y
CONFIG_SUBSYSTEM_SDROOT_DEV="/dev/mmcblk0p2"
CONFIG_SUBSYSTEM_RFS_FORMATS="ext4 ext4.gz"
CONFIG_SUBSYSTEM_BOOTARGS_AUTO=n
CONFIG_SUBSYSTEM_USER_CMDLINE="earlycon console=ttyPS0,115200 root=/dev/mmcblk0p2 rw rootwait"
CONFIG_SUBSYSTEM_ROOTFS_SIZE=524288
ROOTFSCFG
    info "Pre-seeded ext4 rootfs (512 MB) with an explicit root= cmdline"
fi

# ---- 3. Import the hardware description -------------------------------------
step "3/8  Importing hardware description"
info "Quiet for a while even when working (--silentconfig suppresses the"
info "usual interactive menu output). stdbuf forces whatever it DOES"
info "print to appear live rather than sitting buffered."
stdbuf -oL -eL petalinux-config --get-hw-description="${XSA_ABS}" \
    --silentconfig 2>&1 | tee -a "${LOG_FILE}"
info "Hardware description imported"

# ---- 4. Device tree overlays + rootfs packages -------------------------------
step "4/8  Installing device tree overlays and selecting rootfs packages"

DT_USER_DIR="project-spec/meta-user/recipes-bsp/device-tree/files"
mkdir -p "${DT_USER_DIR}"

cat >> "${DT_USER_DIR}/system-user.dtsi" << 'DTSI_EOF'

/* ==================================================================
 * Reserved memory for the ping-pong DDR buffers
 * ==================================================================
 * The PL DMA engines write these physical addresses directly, with no
 * IOMMU and no knowledge of Linux. Carving them out of the kernel's
 * allocator is what stops Linux handing the same pages to a process.
 *
 * 0x1F000000-0x1F4FFFFF, NOT the original 0x3E000000. On a 1 GB board
 * the old addresses collide with U-Boot's own relocation area near the
 * top of DDR, which produces
 *     ** Reading file would overwrite reserved memory **
 *     Failed to load 'image.ub'
 * and the board never reaches the kernel at all.
 *
 * MUST match the xlconstant values in vivado/end_system/bd.tcl and the
 * #defines in fmdemod-rtlsdr.c. Three places, all of which have to
 * agree, and which have disagreed before.
 * ================================================================== */
/ {
    reserved-memory {
        #address-cells = <1>;
        #size-cells = <1>;
        ranges;

        iq_ping_reserved: buffer@1f000000 {
            no-map;
            reg = <0x1F000000 0x00100000>; /* 1 MB */
        };
        iq_pong_reserved: buffer@1f100000 {
            no-map;
            reg = <0x1F100000 0x00100000>; /* 1 MB */
        };
        audio_ping_reserved: buffer@1f200000 {
            no-map;
            reg = <0x1F200000 0x00100000>; /* 1 MB */
        };
        audio_pong_reserved: buffer@1f300000 {
            no-map;
            reg = <0x1F300000 0x00100000>; /* 1 MB */
        };
        audio_dest_reserved: buffer@1f400000 {
            no-map;
            reg = <0x1F400000 0x00100000>; /* 1 MB */
        };
    };
};

/* ==================================================================
 * PS USB0 host mode
 * ==================================================================
 * Zynq-7000's USB is a ChipIdea core driving an EXTERNAL ULPI PHY
 * (USB3320 on the Zybo). DTG generates the controller node from the
 * XSA, but the PHY is a board-level part the XSA knows nothing about,
 * so its node has to be declared here by hand.
 *
 * Symptom when this is missing: dmesg shows usbcore and ehci_hcd
 * registering normally, but /sys/bus/usb/devices/ is EMPTY -- there is
 * no host controller instance for anything to attach to. That was the
 * exact state on the first Linux boot of this design.
 *
 * This fragment alone is NOT sufficient: it references a usb0 node that
 * only exists if PCW_USB0_PERIPHERAL_ENABLE is set in the block design.
 * ================================================================== */
/ {
    usb_phy0: usb_phy@0 {
        compatible = "ulpi-phy";
        #phy-cells = <0>;
        reg = <0xe0002000 0x1000>;
        view-port = <0x0170>;
        drv-vbus;
    };
};

&usb0 {
    status = "okay";
    dr_mode = "host";
    usb-phy = <&usb_phy0>;
};
DTSI_EOF
info "system-user.dtsi written (reserved memory + USB host)"

# ---- Rootfs package selection ------------------------------------------------
# rootfs_config + petalinux-config -c rootfs is the PetaLinux-native
# mechanism, and keeps the selection visible in the project config rather
# than buried in a bbappend.
#
# Keep dropbear (the PetaLinux default) and use dropbear-scp for file
# transfer rather than openssh-sftp-server. You WILL want scp: there is
# no audio hardware on this board, so listening to a capture means
# copying the WAV off to a host.
#
# gpiod-tools and usbutils are bring-up instrumentation rather than
# runtime dependencies, and they earn their space: the AXI GPIO chip
# index was guessed wrong once already, and having no gpiodetect on the
# target to check it cost real time. Same for lsusb -- proving the
# dongle enumerated before blaming the application is the first useful
# step. resize2fs is there because the rootfs filled mid-capture with no
# way to grow it in place.
ROOTFS_CONFIG="project-spec/configs/rootfs_config"
for pkg in \
    CONFIG_librtlsdr \
    CONFIG_libgpiod \
    CONFIG_gpiod-tools \
    CONFIG_e2fsprogs-resize2fs \
    CONFIG_usbutils \
    CONFIG_dropbear-scp \
    CONFIG_udhcpc \
    CONFIG_i2c-tools \
    CONFIG_alsa-lib \
    CONFIG_alsa-utils \
    CONFIG_alsa-utils-aplay \
    CONFIG_alsa-utils-amixer
do
    if ! grep -q "^${pkg}=y" "${ROOTFS_CONFIG}" 2>/dev/null; then
        echo "${pkg}=y" >> "${ROOTFS_CONFIG}"
        info "Enabled package: ${pkg}"
    fi
done

# ---- USB audio (UGREEN-class USB Audio Class DAC dongle) ---------------------
# CONFIG_SND_USB_AUDIO is NOT part of the default kernel config here -- the
# earlier USB0 host bring-up only needed CONFIG_USB_CHIPIDEA and friends
# (already on by default), not the ALSA sound subsystem, which this board
# never used before. dmesg reported "No soundcards found" throughout the
# whole RTL-SDR bring-up specifically because CONFIG_SND was never enabled,
# not because of any hardware limitation -- this is a real USB Audio Class
# device (audio travels as USB data, not through the 3.5mm cable the way
# most cheap "USB speakers" work -- see project notes on that distinction),
# so once the driver is present it needs no kernel-side quirks at all.
#
# CONFIRMED BUG (found the hard way): PetaLinux itself auto-generates
# project-spec/meta-user/recipes-kernel/linux/linux-xlnx_%.bbappend the
# moment step 3's petalinux-config --get-hw-description runs (it uses this
# to apply the board's own bsp.cfg fragment). An earlier version of this
# script created a SECOND, differently-pathed bbappend
# (recipes-kernel/linux-xlnx/linux-xlnx_%.bbappend) for the audio fragment.
# Two files with the IDENTICAL bbappend filename ("linux-xlnx_%.bbappend")
# existing anywhere in the same layer is a silent collision in bitbake --
# one wins, one is dropped, with NO error or warning printed anywhere. The
# audio fragment was the one silently dropped: do_kernel_configcheck
# succeeded with zero mention of CONFIG_SND_USB_AUDIO, and "no soundcards
# found" persisted through an entire rebuild that reported success.
#
# Fix: locate and APPEND TO PetaLinux's own auto-generated bbappend rather
# than creating a second one. FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"
# in that file means Yocto looks for files.uri="file://..." entries in a
# subdirectory literally named linux-xlnx (the package name) next to the
# bbappend itself -- so the fragment goes in
# recipes-kernel/linux/linux-xlnx/, the SAME directory as PetaLinux's own
# bsp.cfg, not a new one.
info "Adding USB Audio Class kernel config fragment (CONFIG_SND_USB_AUDIO)"

PETALINUX_KERNEL_BBAPPEND="project-spec/meta-user/recipes-kernel/linux/linux-xlnx_%.bbappend"
PETALINUX_KERNEL_CFG_DIR="project-spec/meta-user/recipes-kernel/linux/linux-xlnx"

if [ -f "${PETALINUX_KERNEL_BBAPPEND}" ]; then
    info "Found PetaLinux's own linux-xlnx bbappend -- appending to it"
    mkdir -p "${PETALINUX_KERNEL_CFG_DIR}"
    cat > "${PETALINUX_KERNEL_CFG_DIR}/usb-audio.cfg" << 'USBAUDIO_CFG_EOF'
# USB Audio Class support for a UGREEN-class USB-to-3.5mm DAC dongle
# (Amazon ASIN B01N905VOY or equivalent). Green jack = playback (the
# one this project actually uses -- aplay audio_out.wav), red jack =
# mic-level input (not line-level; not suitable for feeding the RTL-SDR
# or anything else that isn't an actual microphone).
CONFIG_SOUND=y
CONFIG_SND=y
CONFIG_SND_USB=y
CONFIG_SND_USB_AUDIO=y
USBAUDIO_CFG_EOF

    if ! grep -q "usb-audio.cfg" "${PETALINUX_KERNEL_BBAPPEND}" 2>/dev/null; then
        echo 'SRC_URI += "file://usb-audio.cfg"' >> "${PETALINUX_KERNEL_BBAPPEND}"
        info "Appended usb-audio.cfg to PetaLinux's own bbappend"
    else
        info "usb-audio.cfg already referenced in the bbappend -- skipping"
    fi
else
    # Defensive fallback: some PetaLinux/kernel version combinations may
    # not pre-create the bbappend at this point in the flow. In that case
    # (and ONLY in that case) it's safe to create our own, since nothing
    # else exists yet to collide with.
    warn "PetaLinux's own linux-xlnx bbappend not found at the expected"
    warn "path -- creating a fresh one. If this warning appears on a"
    warn "PetaLinux version where it normally DOES pre-exist, something"
    warn "changed upstream and this fallback path should be re-checked."
    mkdir -p "${PETALINUX_KERNEL_CFG_DIR}"
    cat > "${PETALINUX_KERNEL_CFG_DIR}/usb-audio.cfg" << 'USBAUDIO_CFG_EOF2'
CONFIG_SOUND=y
CONFIG_SND=y
CONFIG_SND_USB=y
CONFIG_SND_USB_AUDIO=y
USBAUDIO_CFG_EOF2
    cat > "${PETALINUX_KERNEL_BBAPPEND}" << 'USBAUDIO_BBAPPEND_EOF'
FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"
SRC_URI += "file://usb-audio.cfg"
USBAUDIO_BBAPPEND_EOF
fi
info "USB Audio Class kernel fragment in place"

# ---- 5. librtlsdr and the DVB blacklist --------------------------------------
step "5/8  librtlsdr recipe and DVB driver blacklist"

# PetaLinux bundles meta-openembedded, which may already provide
# librtlsdr. Two recipes for one package is a hard build failure, not a
# warning, so check before adding ours.
if bitbake-layers show-recipes 2>/dev/null | grep -qi "^librtlsdr"; then
    info "librtlsdr already provided by an existing layer -- not adding ours"
else
    info "librtlsdr not found in existing layers -- adding a recipe"
    RTLSDR_DIR="project-spec/meta-user/recipes-support/librtlsdr"
    mkdir -p "${RTLSDR_DIR}"
    cat > "${RTLSDR_DIR}/librtlsdr_0.6.0.bb" << 'RTLSDR_EOF'
SUMMARY = "Userspace driver for RTL2832U-based SDR receivers"
HOMEPAGE = "https://osmocom.org/projects/rtl-sdr/wiki"
SECTION = "libs"
LICENSE = "GPL-2.0-or-later"
LIC_FILES_CHKSUM = "file://COPYING;md5=751419260aa954499f7abaabaa882bbe"

DEPENDS = "libusb1"

# Pinned revision rather than a moving branch, so the build is
# reproducible. Needs network access to gitea.osmocom.org at build time;
# mirror the tarball and change SRC_URI if your build host is offline.
SRC_URI = "git://gitea.osmocom.org/sdr/rtl-sdr.git;protocol=https;branch=master"
SRCREV = "0847e93e0869feab50fd27c7afeb85d78ca04631"

S = "${WORKDIR}/git"

inherit cmake pkgconfig

# DETACH_KERNEL_DRIVER lets librtlsdr kick dvb_usb_rtl28xxu off the
# device if the kernel claimed it first. Belt and braces alongside the
# modprobe blacklist below -- either alone usually suffices, both
# together survives an image rebuild that drops the blacklist file.
EXTRA_OECMAKE = " \
    -DDETACH_KERNEL_DRIVER=ON \
    -DINSTALL_UDEV_RULES=ON \
"

FILES:${PN} += "${libdir}/librtlsdr.so.* ${sysconfdir}/udev/rules.d"
FILES:${PN}-dev += "${libdir}/librtlsdr.so ${includedir}/rtl-sdr*.h"
RTLSDR_EOF
    info "librtlsdr recipe written"
fi

# dvb_usb_rtl28xxu claims the RTL2832U as a DVB-T receiver the instant it
# enumerates, and librtlsdr then cannot open it (rtl_test reports "device
# is busy"). Blacklisting avoids the race rather than relying on
# DETACH_KERNEL_DRIVER to win it.
BL_DIR="project-spec/meta-user/recipes-core/rtlsdr-blacklist"
mkdir -p "${BL_DIR}/files"
cat > "${BL_DIR}/files/blacklist-rtl28xxu.conf" << 'BL_EOF'
# Keep the DVB-T stack off the RTL2832U so librtlsdr can claim it.
blacklist dvb_usb_rtl28xxu
blacklist rtl2832
blacklist rtl2830
BL_EOF

cat > "${BL_DIR}/rtlsdr-blacklist.bb" << 'BLREC_EOF'
SUMMARY = "modprobe blacklist so librtlsdr can claim the RTL2832U"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://blacklist-rtl28xxu.conf"
S = "${WORKDIR}"

do_install() {
    install -d ${D}${sysconfdir}/modprobe.d
    install -m 0644 ${WORKDIR}/blacklist-rtl28xxu.conf \
        ${D}${sysconfdir}/modprobe.d/blacklist-rtl28xxu.conf
}

FILES:${PN} = "${sysconfdir}/modprobe.d/blacklist-rtl28xxu.conf"
BLREC_EOF
info "DVB blacklist recipe written"

# The blacklist package is ours, not a known OE package, so it has no
# Kconfig entry and goes in via IMAGE_INSTALL rather than rootfs_config.
BSPCONF="project-spec/meta-user/conf/petalinuxbsp.conf"
mkdir -p "$(dirname "${BSPCONF}")"
if ! grep -q "rtlsdr-blacklist" "${BSPCONF}" 2>/dev/null; then
    echo 'IMAGE_INSTALL:append = " rtlsdr-blacklist"' >> "${BSPCONF}"
fi

# ---- RT throttle disable -----------------------------------------------------
# fmdemod-rtlsdr runs SCHED_FIFO priority 99. The kernel's default RT
# throttle caps SCHED_FIFO/SCHED_RR processes to 95% of CPU time per
# second (kernel.sched_rt_runtime_us = 950000 of 1000000), reserving the
# remaining 5% for normal processes regardless of priority. During each
# throttled window nothing drains the I/Q ring buffer while capture
# keeps filling it. Measured on hardware: 8.2% sample loss with
# throttling on, dropping to 0.5% with it disabled (the iq_ppdma pacing
# fix, RING_PAIRS doubling, and this throttle disable are three
# independent fixes -- none alone closed the loss to negligible, all
# three together did).
#
# This is a /proc/sys/ runtime value with NO persistent on-disk form --
# it resets to the kernel default on every reboot, so it needs an init
# script that re-applies it at boot, not a config file that would
# silently stop taking effect the moment the board is power-cycled.
info "Adding RT throttle disable (init script, applied every boot --"
info "this is a /proc/sys runtime value with no persistent form)"
RT_DIR="project-spec/meta-user/recipes-core/rt-throttle-disable"
mkdir -p "${RT_DIR}/files"

cat > "${RT_DIR}/files/disable-rt-throttle" << 'RT_EOF'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          disable-rt-throttle
# Required-Start:
# Required-Stop:
# Default-Start:     S
# Default-Stop:
# Short-Description: Disable the kernel's RT scheduling throttle
### END INIT INFO
#
# See rt-throttle-disable.bb for the full rationale. Runtime-only
# kernel value, no persistent on-disk form -- must re-run every boot.
case "$1" in
  start)
    echo -1 > /proc/sys/kernel/sched_rt_runtime_us
    ;;
  stop|restart|reload|status)
    # nothing to do
    ;;
  *)
    echo "Usage: $0 start"
    exit 1
    ;;
esac
exit 0
RT_EOF
chmod +x "${RT_DIR}/files/disable-rt-throttle"

cat > "${RT_DIR}/rt-throttle-disable.bb" << 'RT_BB_EOF'
SUMMARY = "Disable the kernel's RT scheduling throttle at boot"
DESCRIPTION = "fmdemod-rtlsdr runs SCHED_FIFO priority 99. The kernel's \
default RT throttle (95% cap per second) causes periodic scheduling \
gaps large enough to overflow the I/Q ring buffer during sustained \
capture -- measured 8.2% sample loss with throttling on, 0.5% with it \
off. This is a /proc/sys/ runtime setting with no persistent on-disk \
form, so it is applied by an init script rather than a config file \
that would silently stop taking effect after a reboot."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://disable-rt-throttle"
S = "${WORKDIR}"

inherit update-rc.d

INITSCRIPT_NAME = "disable-rt-throttle"
# Priority 01: as early as practical, well before fmdemod-rtlsdr could
# ever be launched, manually or otherwise.
INITSCRIPT_PARAMS = "start 01 S ."

do_install() {
    install -d ${D}${sysconfdir}/init.d
    install -m 0755 ${WORKDIR}/disable-rt-throttle ${D}${sysconfdir}/init.d/disable-rt-throttle
}

FILES:${PN} = "${sysconfdir}/init.d/disable-rt-throttle"
RT_BB_EOF

# No Kconfig entry (ours, not a known OE package), same as the
# blacklist recipe above -- goes in via IMAGE_INSTALL.
if ! grep -q "rt-throttle-disable" "${BSPCONF}" 2>/dev/null; then
    echo 'IMAGE_INSTALL:append = " rt-throttle-disable"' >> "${BSPCONF}"
fi
info "RT throttle disable recipe written"

info "Running rootfs config (quiet for a bit, same reason as step 3)"
stdbuf -oL -eL petalinux-config -c rootfs --silentconfig 2>&1 | tee -a "${LOG_FILE}"
info "Rootfs config complete"

# ---- 6. Application recipe ---------------------------------------------------
step "6/8  Creating ${APP_NAME} app recipe"

APP_RECIPE_DIR="project-spec/meta-user/recipes-apps/${APP_NAME}"
APP_FILES_DIR="${APP_RECIPE_DIR}/files"
mkdir -p "${APP_FILES_DIR}"

cp "${APP_SRC_DIR}/fmdemod-rtlsdr.c"      "${APP_FILES_DIR}/"
cp "${APP_SRC_DIR}/resample_50k_to_48k.c" "${APP_FILES_DIR}/"
cp "${APP_SRC_DIR}/resample_coeffs.h"     "${APP_FILES_DIR}/"
cp "${APP_SRC_DIR}/pl_rates.h"            "${APP_FILES_DIR}/"
cp "${APP_SRC_DIR}/alsa_live.c"           "${APP_FILES_DIR}/"
cp "${APP_SRC_DIR}/alsa_live.h"           "${APP_FILES_DIR}/"
cp "${APP_SRC_DIR}/gpio_rate_test.c"      "${APP_FILES_DIR}/"
info "Installed app sources into the recipe"

cat > "${APP_FILES_DIR}/Makefile" << 'MAKE_EOF'
# Three translation units: the capture/demod driver, the resampler,
# and the optional live-ALSA-playback module (-A flag; a safe no-op
# throughout if never enabled).
#   -lgpiod    ping-pong handshake lines
#   -lrtlsdr   the dongle
#   -lpthread  the librtlsdr async reader runs on its own thread
#   -lm        lround() in the resampler and in alsa_live's filters
#   -lasound   ALSA playback (alsa_live.c) -- requires alsa-lib in
#              DEPENDS below so the cross-compile sysroot has the
#              headers; requires CONFIG_alsa-lib in rootfs_config so
#              libasound.so.2 is actually present on the target at
#              runtime (dev headers are NOT needed on the target --
#              nothing compiles code on the board itself).
CFLAGS  += -O2 -Wall -Wextra
LDLIBS  += -lgpiod -lrtlsdr -lpthread -lm -lasound

OBJS = fmdemod-rtlsdr.o resample_50k_to_48k.o alsa_live.o

all: fmdemod-rtlsdr gpio_rate_test

fmdemod-rtlsdr: $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $(OBJS) $(LDLIBS)

# Standalone diagnostic -- shares no object files with fmdemod-rtlsdr,
# links only against libgpiod. See gpio_rate_test.c's own header for
# why this exists: measuring the REAL iq_ppdma active_buf toggle rate
# independent of the main app's own ring/refill accounting, to check
# an assumption (100 Hz on real silicon) that was previously only
# confirmed via a static HLS synthesis report, never measured directly.
gpio_rate_test: gpio_rate_test.o
	$(CC) $(LDFLAGS) -o $@ $< -lgpiod

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f $(OBJS) gpio_rate_test.o fmdemod-rtlsdr gpio_rate_test

.PHONY: all clean
MAKE_EOF
info "Wrote app Makefile"

cat > "${APP_RECIPE_DIR}/${APP_NAME}.bb" << 'APP_EOF'
SUMMARY = "Live FM demodulator: RTL-SDR -> PL demod chain -> WAV"
SECTION = "PETALINUX/apps"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://fmdemod-rtlsdr.c \
    file://resample_50k_to_48k.c \
    file://resample_coeffs.h \
    file://pl_rates.h \
    file://alsa_live.c \
    file://alsa_live.h \
    file://gpio_rate_test.c \
    file://Makefile \
"

S = "${WORKDIR}"

# alsa-lib provides both libasound (linked at build time, DEPENDS) and
# the runtime libasound.so.2 the app needs on the target at execution
# time (RDEPENDS). CONFIG_alsa-lib in rootfs_config (step 4, above)
# additionally ensures the runtime .so lands in the ROOTFS IMAGE, not
# just the recipe's own dependency graph -- both are needed, they cover
# different things (this recipe's build/runtime deps vs. what actually
# ships in the final image).
DEPENDS = "libgpiod librtlsdr alsa-lib"
RDEPENDS:${PN} = "libgpiod librtlsdr alsa-lib"

do_compile() {
    oe_runmake
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${S}/fmdemod-rtlsdr  ${D}${bindir}/fmdemod-rtlsdr
    install -m 0755 ${S}/gpio_rate_test  ${D}${bindir}/gpio_rate_test
}

FILES:${PN} = "${bindir}/fmdemod-rtlsdr ${bindir}/gpio_rate_test"
APP_EOF

if ! grep -q "${APP_NAME}" "${BSPCONF}" 2>/dev/null; then
    echo "IMAGE_INSTALL:append = \" ${APP_NAME}\"" >> "${BSPCONF}"
fi
info "App recipe written and added to IMAGE_INSTALL"

# ---- 7. Build ----------------------------------------------------------------
step "7/8  Building (this takes a while the first time)"
info "Commonly 30 min to a few hours depending on your machine and"
info "whether sstate-cache/downloads are already warm from a prior build."
info "librtlsdr is fetched from git during this step, so the build host"
info "needs network access the first time through."

BUILD_START=$(date +%s)

# No -v: plain bitbake output already prints one line per task as it
# starts and finishes, which is the useful "what recipe, what's it doing"
# visibility. -v additionally dumps the full raw command output under
# every single task, which turned out to be too much.
petalinux-build 2>&1 | tee -a "${LOG_FILE}"
BUILD_EXIT=${PIPESTATUS[0]}

BUILD_END=$(date +%s)
BUILD_ELAPSED=$(( BUILD_END - BUILD_START ))
info "Build step took $(( BUILD_ELAPSED / 60 ))m $(( BUILD_ELAPSED % 60 ))s"

if [ "${BUILD_EXIT}" -ne 0 ]; then
    error "petalinux-build failed (exit ${BUILD_EXIT}). Check ${LOG_FILE}."
fi

# ---- 8. Package the boot image ----------------------------------------------
step "8/8  Packaging BOOT.BIN"
# zynq_fsbl.elf is the Zynq-7000 FSBL name, and there is deliberately NO
# --pmufw: PMU firmware has no Zynq-7000 equivalent at all, but is
# MANDATORY on ZynqMP. Passing it here is rejected outright; omitting it
# on a ZU+ board gives an FSBL that hangs at startup.
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
info "Boot image:  images/linux/BOOT.BIN"
info "Kernel + DT: images/linux/image.ub"
info "Rootfs:      images/linux/rootfs.ext4"
warn "REMINDER: this script cannot confirm PS USB0 was actually enabled in"
warn "the hardware it imported. On the target, the first check that matters"
warn "is 'ls /sys/bus/usb/devices/' -- if that is EMPTY, go back to the"
warn "block design; no software change will help."
echo "=== Finished: $(date) ===" | tee -a "${LOG_FILE}"
info "Full build log saved to: ${LOG_FILE}"

# ---- Optional SD card creation -----------------------------------------------
# Deliberately NOT automatic -- create_sd.sh erases and repartitions
# whatever device it is pointed at, needs root, and asks its own
# interactive "type YES" confirmation. Offering it here rather than just
# invoking it saves a manual step without ever silently touching a disk.
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
            # PETALINUX_PROJECT explicitly passed through -- create_sd.sh
            # defaults it off $HOME, which sudo resets to /root (not your
            # actual home), so without this it looks for the built images
            # in the wrong place entirely and fails with a confusing
            # "BOOT.BIN not found" even though the build genuinely
            # succeeded.
            sudo PETALINUX_PROJECT="${SCRIPT_DIR}/${PROJECT_NAME}" \
                bash "${CREATE_SD}" "${SD_DEV}"
        else
            warn "Device ${SD_DEV} not found -- skipping. Prepare it manually:"
            warn "  sudo PETALINUX_PROJECT=${SCRIPT_DIR}/${PROJECT_NAME} \\"
            warn "      bash create_sd.sh /dev/sdX"
        fi
    else
        info "Skipping SD card creation. Run manually when ready:"
        info "  sudo PETALINUX_PROJECT=${SCRIPT_DIR}/${PROJECT_NAME} \\"
        info "      bash create_sd.sh /dev/sdX"
    fi
fi
