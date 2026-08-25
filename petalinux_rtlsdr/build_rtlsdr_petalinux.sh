#!/usr/bin/env bash
#
# build_rtlsdr_petalinux.sh
#
# Creates a COMPLETE, STANDALONE PetaLinux project for live FM reception
# on a Zybo Z7-10: RTL-SDR Blog V3 -> PS USB -> ping-pong DDR -> PL demod
# chain -> WAV file.
#
# This does not touch, depend on, or share state with any existing
# PetaLinux project. It builds its own from scratch in ./PROJECT_NAME.
#
# ---------------------------------------------------------------------
# WHAT THIS SCRIPT ENCODES
# ---------------------------------------------------------------------
# Every setting here was arrived at by hitting the corresponding failure
# during bring-up. The comments say which failure, because a bare config
# line tells you nothing about why it must not be changed back:
#
#   --template zynq        Zynq-7000, not zynqMP. Wrong template gives a
#                          64-bit ARM project that will not boot on an A9.
#   no machine name        There is no Zybo BSP installed. Setting a board
#                          machine name fails at device-tree generation.
#                          DTG derives everything it needs from the XSA.
#   USER_CMDLINE           NOT "CONFIG_SUBSYSTEM_BOOTARGS" -- that symbol
#                          does not exist. Writing it produces an EMPTY
#                          kernel command line, no root=, and a VFS panic
#                          on an otherwise perfectly good boot.
#   ext4 rootfs            initramfs was never confirmed working here and
#                          embeds the rootfs in image.ub, which makes it
#                          large and awkward to modify on the target.
#   ROOTFS_SIZE 512MB      the default came out at 56 MB and filled up
#                          during the very first capture.
#   zynq_fsbl.elf          not zynqmp_fsbl.elf, and NO --pmufw: Zynq-7000
#                          has no PMU firmware and the flag is rejected.
#   0x1F000000 buffers     the original 0x3E000000 addresses collide with
#                          U-Boot's own relocation area near the top of a
#                          1 GB DDR, giving "Reading file would overwrite
#                          reserved memory" and a failed image.ub load.
#
# ---------------------------------------------------------------------
# PREREQUISITES
# ---------------------------------------------------------------------
#   - PetaLinux 2022.2 settings sourced
#   - An XSA exported from a Vivado build with PS USB0 ENABLED
#     (MIO 28..39). Without USB0 in the hardware there is no USB host
#     controller and the SDR cannot enumerate -- no amount of software
#     configuration recovers from that.
#   - The three source files in ./src/
#
# ---------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------
#   mkdir -p src
#   cp .../fmdemod-rtlsdr.c .../resample_50k_to_48k.c \
#      .../resample_coeffs.h src/
#   cp .../sdr_fm_receiver.xsa .
#   source /path/to/petalinux/settings.sh
#   ./build_rtlsdr_petalinux.sh
#

set -euo pipefail

# ====================================================================
# Configuration
# ====================================================================
PROJECT_NAME="${PROJECT_NAME:-fm_rtlsdr_linux}"
XSA_FILE="${XSA_FILE:-sdr_fm_receiver.xsa}"
SRC_DIR="${SRC_DIR:-src}"
APP_NAME="fmdemod-rtlsdr"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="${SCRIPT_DIR}/${PROJECT_NAME}"
XSA_ABS="${SCRIPT_DIR}/${XSA_FILE}"
LOG_FILE="${SCRIPT_DIR}/build_${PROJECT_NAME}.log"

# DDR map -- MUST match bd.tcl's xlconstants and fmdemod-rtlsdr.c.
# Five places have to agree on these; they have disagreed before.
IQ_PING_ADDR="0x1F000000"
IQ_PONG_ADDR="0x1F100000"
AUDIO_PING_ADDR="0x1F200000"
AUDIO_PONG_ADDR="0x1F300000"
AUDIO_DEST_ADDR="0x1F400000"

# ====================================================================
# Helpers
# ====================================================================
step() { echo "" | tee -a "${LOG_FILE}"; echo "=== $* ===" | tee -a "${LOG_FILE}"; }
info() { echo "  $*" | tee -a "${LOG_FILE}"; }
warn() { echo "  WARNING: $*" | tee -a "${LOG_FILE}" >&2; }
die()  { echo "  ERROR: $*" | tee -a "${LOG_FILE}" >&2; exit 1; }

: > "${LOG_FILE}"

# ====================================================================
step "0/9  Preflight"
# ====================================================================
command -v petalinux-create >/dev/null 2>&1 || \
    die "petalinux-create not on PATH. Source PetaLinux settings.sh first."

info "PetaLinux: $(petalinux-util --webtalk off >/dev/null 2>&1; \
    petalinux-create --version 2>&1 | head -1 || echo 'version unknown')"

[ -f "${XSA_ABS}" ] || die "XSA not found: ${XSA_ABS}"
info "XSA: ${XSA_ABS}"

for f in fmdemod-rtlsdr.c resample_50k_to_48k.c resample_coeffs.h; do
    [ -f "${SCRIPT_DIR}/${SRC_DIR}/${f}" ] || \
        die "Missing source: ${SRC_DIR}/${f}"
done
info "Sources present in ${SRC_DIR}/"

# The XSA must contain a USB0 node or the whole exercise is pointless.
# Checking now costs a second; discovering it after a 2 hour build does
# not. The XSA is a zip; the .hwh inside lists the PS peripherals.
if command -v unzip >/dev/null 2>&1; then
    if unzip -p "${XSA_ABS}" '*.hwh' 2>/dev/null | grep -qi "USB0_PERIPHERAL_ENABLE.*1\|PCW_EN_USB0.*1"; then
        info "XSA reports PS USB0 enabled -- good"
    else
        warn "Could not confirm PS USB0 is enabled in the XSA."
        warn "If /sys/bus/usb/devices/ is empty on the target, this is why:"
        warn "  set PCW_USB0_PERIPHERAL_ENABLE {1} and PCW_USB0_USB0_IO"
        warn "  {MIO 28 .. 39} in the block design, rebuild, re-export."
        read -r -p "  Continue anyway? [y/N] " reply
        [ "${reply}" = "y" ] || [ "${reply}" = "Y" ] || exit 1
    fi
fi

if [ -d "${PROJ_DIR}" ]; then
    warn "${PROJ_DIR} already exists."
    read -r -p "  Delete and recreate? [y/N] " reply
    if [ "${reply}" = "y" ] || [ "${reply}" = "Y" ]; then
        rm -rf "${PROJ_DIR}"
    else
        die "Aborting to avoid clobbering an existing project."
    fi
fi

# ====================================================================
step "1/9  Create project"
# ====================================================================
# --template zynq: Zynq-7000 / Cortex-A9. NOT zynqMP -- that scaffolds a
# 64-bit project with an ATF and PMU firmware that do not exist on this
# part, and fails late and confusingly.
cd "${SCRIPT_DIR}"
petalinux-create -t project --template zynq -n "${PROJECT_NAME}" 2>&1 | tee -a "${LOG_FILE}"
info "Created ${PROJ_DIR}"

CONFIG_FILE="${PROJ_DIR}/project-spec/configs/config"

# ====================================================================
step "2/9  Import hardware description"
# ====================================================================
# Quiet for a while even when working. --silentconfig suppresses the
# interactive menu; stdbuf forces what it does print to appear live
# rather than sitting in a pipe buffer for two minutes.
cd "${PROJ_DIR}"
stdbuf -oL -eL petalinux-config --get-hw-description="${XSA_ABS}" \
    --silentconfig 2>&1 | tee -a "${LOG_FILE}"
info "Hardware description imported"

# ====================================================================
step "3/9  Root filesystem and boot arguments"
# ====================================================================
# CONFIG_SUBSYSTEM_USER_CMDLINE is the real Kconfig symbol. An earlier
# script wrote CONFIG_SUBSYSTEM_BOOTARGS, which is NOT a symbol -- Kconfig
# silently discarded it, left USER_CMDLINE empty, and the kernel booted
# all the way to "VFS: Cannot open root device (null)" before failing.
# CONFIG_SUBSYSTEM_BOOTARGS_AUTO is real and defaults to unset, which is
# what we want -- setting it would regenerate and overwrite our cmdline.
{
    echo 'CONFIG_SUBSYSTEM_ROOTFS_EXT4=y'
    echo 'CONFIG_SUBSYSTEM_SDROOT_DEV="/dev/mmcblk0p2"'
    echo 'CONFIG_SUBSYSTEM_RFS_FORMATS="ext4 ext4.gz"'
    echo '# CONFIG_SUBSYSTEM_BOOTARGS_AUTO is not set'
    echo 'CONFIG_SUBSYSTEM_USER_CMDLINE="earlycon console=ttyPS0,115200 root=/dev/mmcblk0p2 rw rootwait"'
    # 56 MB was the default and it filled during the first capture. A
    # live stream writes continuously, so give it real room.
    echo 'CONFIG_SUBSYSTEM_ROOTFS_SIZE=524288'
} >> "${CONFIG_FILE}"
info "ext4 rootfs, 512 MB, explicit kernel cmdline with root="

# ====================================================================
step "4/9  Device tree: reserved memory + USB host"
# ====================================================================
DT_DIR="${PROJ_DIR}/project-spec/meta-user/recipes-bsp/device-tree/files"
mkdir -p "${DT_DIR}"

cat >> "${DT_DIR}/system-user.dtsi" << 'DTSI_EOF'

/* ==================================================================
 * Reserved memory for the ping-pong DDR buffers
 * ==================================================================
 * The PL DMA engines write these physical addresses directly, with no
 * IOMMU and no knowledge of Linux. Carving them out of the kernel's
 * allocator is what stops Linux handing the same pages to a process.
 *
 * Addresses are 0x1F000000-0x1F4FFFFF, i.e. near the top of the first
 * 512 MB. NOT the original 0x3E000000 -- on a 1 GB board that region
 * collides with U-Boot's own relocation area, which produces
 * "** Reading file would overwrite reserved memory **" and a failure to
 * load image.ub at all.
 *
 * MUST match the xlconstant values in bd.tcl and the #defines in
 * fmdemod-rtlsdr.c. All three have to agree.
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
 * so its node has to be declared by hand here.
 *
 * Symptom if this is missing: dmesg shows usbcore and ehci_hcd
 * registering normally, but /sys/bus/usb/devices/ is EMPTY -- there is
 * no host controller instance for anything to attach to.
 *
 * Requires PCW_USB0_PERIPHERAL_ENABLE in the block design. This
 * fragment alone is not enough; it references a usb0 node that only
 * exists if the hardware enabled it.
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

# ====================================================================
step "5/9  librtlsdr"
# ====================================================================
# PetaLinux bundles meta-openembedded, which may already provide
# librtlsdr. Two recipes for one package is a hard build failure, not a
# warning, so check before adding ours.
cd "${PROJ_DIR}"
HAVE_LIBRTLSDR=0
if bitbake-layers show-recipes 2>/dev/null | grep -qi "^librtlsdr"; then
    HAVE_LIBRTLSDR=1
    info "librtlsdr already provided by an existing layer -- not adding ours"
else
    info "librtlsdr not found in existing layers -- adding a recipe"
    RECIPE_DIR="${PROJ_DIR}/project-spec/meta-user/recipes-support/librtlsdr"
    mkdir -p "${RECIPE_DIR}"
    cat > "${RECIPE_DIR}/librtlsdr_0.6.0.bb" << 'RTLSDR_EOF'
SUMMARY = "Userspace driver for RTL2832U-based SDR receivers"
HOMEPAGE = "https://osmocom.org/projects/rtl-sdr/wiki"
SECTION = "libs"
LICENSE = "GPL-2.0-or-later"
LIC_FILES_CHKSUM = "file://COPYING;md5=751419260aa954499f7abaabaa882bbe"

DEPENDS = "libusb1"

# Pinned revision rather than a moving branch, so the build is
# reproducible. Needs network access to gitea.osmocom.org at build time.
SRC_URI = "git://gitea.osmocom.org/sdr/rtl-sdr.git;protocol=https;branch=master"
SRCREV = "0847e93e0869feab50fd27c7afeb85d78ca04631"

S = "${WORKDIR}/git"

inherit cmake pkgconfig

# DETACH_KERNEL_DRIVER lets librtlsdr kick dvb_usb_rtl28xxu off the
# device if the kernel claimed it first. Belt and braces alongside the
# modprobe blacklist -- either alone usually suffices, both together
# survives an image rebuild that drops the blacklist file.
EXTRA_OECMAKE = " \
    -DDETACH_KERNEL_DRIVER=ON \
    -DINSTALL_UDEV_RULES=ON \
"

FILES:${PN} += "${libdir}/librtlsdr.so.* ${sysconfdir}/udev/rules.d"
FILES:${PN}-dev += "${libdir}/librtlsdr.so ${includedir}/rtl-sdr*.h"
RTLSDR_EOF
    info "Recipe written to recipes-support/librtlsdr/"
fi

# ====================================================================
step "6/9  Blacklist the DVB-T driver"
# ====================================================================
# dvb_usb_rtl28xxu claims the RTL2832U as a DVB-T receiver the instant it
# enumerates, and librtlsdr then cannot open it. Blacklisting avoids the
# race entirely rather than relying on DETACH_KERNEL_DRIVER to win it.
BL_DIR="${PROJ_DIR}/project-spec/meta-user/recipes-core/rtlsdr-blacklist"
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
info "Blacklist recipe written"

# ====================================================================
step "7/9  Application recipe"
# ====================================================================
APP_DIR="${PROJ_DIR}/project-spec/meta-user/recipes-apps/${APP_NAME}"
mkdir -p "${APP_DIR}/files"

cp "${SCRIPT_DIR}/${SRC_DIR}/fmdemod-rtlsdr.c"     "${APP_DIR}/files/"
cp "${SCRIPT_DIR}/${SRC_DIR}/resample_50k_to_48k.c" "${APP_DIR}/files/"
cp "${SCRIPT_DIR}/${SRC_DIR}/resample_coeffs.h"     "${APP_DIR}/files/"

cat > "${APP_DIR}/files/Makefile" << 'MAKE_EOF'
# Two translation units: the capture/demod driver and the resampler.
# -lpthread is needed for the librtlsdr reader thread, -lm for lround()
# in the resampler.
CFLAGS  += -O2 -Wall -Wextra
LDLIBS  += -lgpiod -lrtlsdr -lpthread -lm

OBJS = fmdemod-rtlsdr.o resample_50k_to_48k.o

all: fmdemod-rtlsdr

fmdemod-rtlsdr: $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $(OBJS) $(LDLIBS)

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f $(OBJS) fmdemod-rtlsdr

.PHONY: all clean
MAKE_EOF

cat > "${APP_DIR}/${APP_NAME}.bb" << 'APP_EOF'
SUMMARY = "Live FM demodulator: RTL-SDR -> PL demod chain -> WAV"
SECTION = "PETALINUX/apps"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://fmdemod-rtlsdr.c \
    file://resample_50k_to_48k.c \
    file://resample_coeffs.h \
    file://Makefile \
"

S = "${WORKDIR}"

# libgpiod for the ping-pong handshake lines, librtlsdr for the dongle.
DEPENDS = "libgpiod librtlsdr"
RDEPENDS:${PN} = "libgpiod librtlsdr"

do_compile() {
    oe_runmake
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${S}/fmdemod-rtlsdr ${D}${bindir}/fmdemod-rtlsdr
}

FILES:${PN} = "${bindir}/fmdemod-rtlsdr"
APP_EOF
info "App recipe written with both source files"

# ====================================================================
step "8/9  Rootfs package selection"
# ====================================================================
BSPCONF="${PROJ_DIR}/project-spec/meta-user/conf/petalinuxbsp.conf"
mkdir -p "$(dirname "${BSPCONF}")"

cat >> "${BSPCONF}" << 'BSP_EOF'

# ---- FM receiver runtime and bring-up tooling ----
#
# fmdemod-rtlsdr      the application
# rtlsdr-blacklist    keeps dvb_usb_rtl28xxu off the dongle
# libgpiod-tools      gpiodetect/gpioinfo. The AXI GPIO chip index was
#                     guessed wrong once already; not having the tools on
#                     the target to check it cost real time.
# e2fsprogs-resize2fs the rootfs filled up mid-capture and there was no
#                     way to grow it in place.
# usbutils            lsusb, to prove the dongle enumerated before
#                     blaming the application.
IMAGE_INSTALL:append = " \
    fmdemod-rtlsdr \
    rtlsdr-blacklist \
    librtlsdr \
    libgpiod \
    libgpiod-tools \
    e2fsprogs-resize2fs \
    usbutils \
"
BSP_EOF
info "Runtime packages and bring-up tools added"

# ====================================================================
step "9/9  Build and package"
# ====================================================================
cd "${PROJ_DIR}"
info "This takes 1-3 hours on a first build. Logging to ${LOG_FILE}"
stdbuf -oL -eL petalinux-build 2>&1 | tee -a "${LOG_FILE}"

# Zynq-7000 boot image: FSBL + bitstream + U-Boot. NO --pmufw -- that is
# a ZynqMP-only file and the flag is rejected here. FSBL is zynq_fsbl.elf,
# not zynqmp_fsbl.elf.
for f in zynq_fsbl.elf system.bit u-boot.elf; do
    [ -f "images/linux/${f}" ] || die "images/linux/${f} missing after build"
done

petalinux-package --boot \
    --fsbl images/linux/zynq_fsbl.elf \
    --fpga images/linux/system.bit \
    --u-boot images/linux/u-boot.elf \
    --force 2>&1 | tee -a "${LOG_FILE}"

# ====================================================================
echo ""
echo "===================================================================="
echo "  Build complete"
echo "===================================================================="
cat << FINAL_EOF

Images in ${PROJ_DIR}/images/linux/ :
    BOOT.BIN        -> SD partition 1 (FAT32)
    image.ub        -> SD partition 1 (FAT32)
    boot.scr        -> SD partition 1 (FAT32)
    rootfs.ext4     -> dd onto SD partition 2

SD card layout (two partitions):
    p1  FAT32,  ~1 GB,  bootable
    p2  ext4,   rest of the card

    sudo dd if=images/linux/rootfs.ext4 of=/dev/sdXn bs=4M status=progress
    sync

--------------------------------------------------------------------
VERIFY ON TARGET IN THIS ORDER
--------------------------------------------------------------------
Each step isolates a different failure. Skipping ahead just makes the
eventual error harder to attribute.

  1. ls /sys/bus/usb/devices/
       Non-empty => the USB host controller exists. If EMPTY, the
       problem is the HARDWARE, not Linux: PS USB0 is not enabled in
       the block design. No software fix applies.

  2. lsusb
       Expect 0bda:2838 (Realtek RTL2838). If absent, check the cable
       and that the dongle is in J13, the host port.

  3. rtl_test -t
       Proves librtlsdr can claim the device and identifies the tuner.
       Should report R820T2 for a Blog V3. If it reports "device is
       busy", the blacklist did not take -- check
       /etc/modprobe.d/blacklist-rtl28xxu.conf exists.

  4. gpiodetect
       Confirm which gpiochip is 40000000.gpio (the PL one, ngpio=2).
       fmdemod-rtlsdr assumes gpiochip0. Enumeration order is
       probe-dependent and can change between kernels.

  5. fmdemod-rtlsdr -f 100000000 -d 30

--------------------------------------------------------------------
READING THE OUTPUT
--------------------------------------------------------------------
The per-second progress line reports ring occupancy and loss:

    [ 12s] refills=1200 blocks=24000 ring=79800/160000 under=0 over=0

  ring hovering near half full   healthy
  ring pinned at 0               fabric consuming faster than the SDR
                                 delivers; expect underruns and gaps
  ring pinned at maximum         SDR faster than the fabric, or the poll
                                 loop is blocked (SD write stalls will
                                 do it)
  steady under=/over= growth     the two sample rates genuinely differ.
                                 Jitter causes occasional single-digit
                                 counts; a steady climb is a real rate
                                 mismatch and worth measuring.

--------------------------------------------------------------------
IF THE AUDIO IS MISTUNED
--------------------------------------------------------------------
The tuner is offset by NCO_OFFSET_HZ (+10 kHz) so the station lands
where the PL's fixed 10 kHz NCO expects it. That sign was derived from
the freq_corr RTL, NOT measured on hardware. If audio is distorted or
tuned to the wrong place, flip the sign in fmdemod-rtlsdr.c and rebuild
before investigating anything else -- it is one character and the
fastest hypothesis to eliminate.

FINAL_EOF
