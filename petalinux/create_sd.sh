#!/bin/bash
# =============================================================================
# create_sd.sh — Prepare an SD card for booting the sdr_fm_receiver PetaLinux
# image on the Zybo Z7-10.
#
# SD card layout (standard PetaLinux / Zynq boot layout):
#   Partition 1: FAT32, ~256 MB, labelled BOOT
#     BOOT.BIN     — FSBL + bitstream + u-boot
#     image.ub     — FIT image: kernel + device tree + rootfs (initramfs)
#     rds.wav      — input I/Q recording (optional, copied if found)
#
# This script only supports the single-partition FIT image layout
# (petalinux-image-minimal default). If you configured a separate ext4
# rootfs partition, the layout differs — set EXT4_ROOTFS=1 below.
#
# USAGE:
#   sudo bash create_sd.sh /dev/sdX [path/to/rds.wav]
#
# WARNING: THIS SCRIPT WILL ERASE AND REPARTITION THE TARGET DEVICE.
# Double-check the device path before running. /dev/sdX must be your
# SD card, NOT your system disk.
# =============================================================================

set -e

# ---- Configuration ----------------------------------------------------------
PETALINUX_PROJECT="${PETALINUX_PROJECT:-$HOME/mono_fm_receiver/petalinux/sdr_fm_receiver_linux}"
IMAGES_DIR="${PETALINUX_PROJECT}/images/linux"
EXT4_ROOTFS=0          # set to 1 if you built a separate ext4 rootfs partition
BOOT_SIZE_MB=256       # FAT32 boot partition size
ROOTFS_SIZE_MB=1024    # ext4 rootfs partition size (only used if EXT4_ROOTFS=1)

# ---- Colour output ----------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---- Argument parsing -------------------------------------------------------
if [ $# -lt 1 ]; then
    echo "Usage: sudo bash $(basename "$0") /dev/sdX [path/to/rds.wav]"
    echo "  /dev/sdX    — SD card block device (e.g. /dev/sdb, /dev/mmcblk0)"
    echo "  rds.wav     — optional: I/Q recording to copy onto the card"
    exit 1
fi

DEV="$1"
WAV_SRC="${2:-}"

# ---- Safety checks ----------------------------------------------------------
[ "$(id -u)" -eq 0 ] || error "This script must be run as root (sudo)."

[ -b "${DEV}" ] || error "${DEV} is not a block device. Check the device path."

# Refuse to touch any device that looks like a system disk.
# Heuristic: system disk is usually the one containing the root filesystem.
ROOT_DEV=$(df / | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//')
if [ "${DEV}" = "${ROOT_DEV}" ] || [ "${DEV}" = "/dev/sda" ]; then
    error "Refusing to operate on ${DEV} — looks like the system disk. " \
          "Specify the SD card device explicitly."
fi

# Confirm required image files exist
for f in BOOT.BIN image.ub; do
    [ -f "${IMAGES_DIR}/${f}" ] || \
        error "${IMAGES_DIR}/${f} not found. Run petalinux-build first."
done

# ---- User confirmation ------------------------------------------------------
DEVSIZE=$(blockdev --getsize64 "${DEV}" 2>/dev/null || echo "unknown")
if [ "${DEVSIZE}" != "unknown" ]; then
    DEVSIZE_GB=$(awk "BEGIN {printf \"%.1f\", ${DEVSIZE}/1024/1024/1024}")
    echo ""
    warn "TARGET DEVICE: ${DEV}  (${DEVSIZE_GB} GB)"
else
    warn "TARGET DEVICE: ${DEV}"
fi
warn "ALL DATA ON ${DEV} WILL BE ERASED."
echo ""
read -rp "Type YES to continue: " CONFIRM
[ "${CONFIRM}" = "YES" ] || { info "Aborted."; exit 0; }

# ---- Unmount any mounted partitions -----------------------------------------
info "Unmounting any partitions on ${DEV}..."
for part in "${DEV}"[0-9]* "${DEV}"p[0-9]*; do
    [ -b "${part}" ] && umount "${part}" 2>/dev/null || true
done
sleep 1

# ---- Partition the card -----------------------------------------------------
info "Partitioning ${DEV}..."

if [ "${EXT4_ROOTFS}" -eq 1 ]; then
    # Two-partition layout: FAT32 boot + ext4 rootfs
    parted -s "${DEV}" \
        mklabel msdos \
        mkpart primary fat32  1MiB $((BOOT_SIZE_MB + 1))MiB \
        mkpart primary ext4   $((BOOT_SIZE_MB + 1))MiB $((BOOT_SIZE_MB + ROOTFS_SIZE_MB + 1))MiB \
        set 1 boot on
else
    # Single-partition layout: FAT32 boot only (FIT image = kernel + initramfs)
    parted -s "${DEV}" \
        mklabel msdos \
        mkpart primary fat32 1MiB $((BOOT_SIZE_MB + 1))MiB \
        set 1 boot on
fi

# Give the kernel a moment to re-read the partition table
sleep 2
partprobe "${DEV}" 2>/dev/null || true
sleep 1

# ---- Identify partition device names ----------------------------------------
# Handle both /dev/sdX1 and /dev/mmcblkXp1 naming conventions
if [ -b "${DEV}1" ]; then
    BOOT_PART="${DEV}1"
    ROOTFS_PART="${DEV}2"
elif [ -b "${DEV}p1" ]; then
    BOOT_PART="${DEV}p1"
    ROOTFS_PART="${DEV}p2"
else
    error "Could not identify partition device after partitioning ${DEV}"
fi

# ---- Format partitions ------------------------------------------------------
info "Formatting ${BOOT_PART} as FAT32 (label: BOOT)..."
mkfs.vfat -F 32 -n BOOT "${BOOT_PART}"

if [ "${EXT4_ROOTFS}" -eq 1 ]; then
    info "Formatting ${ROOTFS_PART} as ext4 (label: rootfs)..."
    mkfs.ext4 -L rootfs "${ROOTFS_PART}"
fi

# ---- Mount and copy files ---------------------------------------------------
MOUNT_BOOT=$(mktemp -d /tmp/sd_boot_XXXXX)
info "Mounting ${BOOT_PART} at ${MOUNT_BOOT}..."
mount "${BOOT_PART}" "${MOUNT_BOOT}"

info "Copying BOOT.BIN ($(du -h "${IMAGES_DIR}/BOOT.BIN" | cut -f1))..."
cp "${IMAGES_DIR}/BOOT.BIN" "${MOUNT_BOOT}/"

info "Copying image.ub ($(du -h "${IMAGES_DIR}/image.ub" | cut -f1))..."
cp "${IMAGES_DIR}/image.ub" "${MOUNT_BOOT}/"

if [ "${EXT4_ROOTFS}" -eq 1 ] && [ -f "${IMAGES_DIR}/rootfs.tar.gz" ]; then
    MOUNT_ROOTFS=$(mktemp -d /tmp/sd_rootfs_XXXXX)
    info "Mounting ${ROOTFS_PART} at ${MOUNT_ROOTFS}..."
    mount "${ROOTFS_PART}" "${MOUNT_ROOTFS}"
    info "Extracting rootfs.tar.gz..."
    tar -xf "${IMAGES_DIR}/rootfs.tar.gz" -C "${MOUNT_ROOTFS}" --no-same-owner
fi

# ---- Copy rds.wav if provided -----------------------------------------------
if [ -n "${WAV_SRC}" ]; then
    if [ -f "${WAV_SRC}" ]; then
        info "Copying $(basename "${WAV_SRC}") ($(du -h "${WAV_SRC}" | cut -f1))..."
        if [ "${EXT4_ROOTFS}" -eq 1 ] && [ -d "${MOUNT_ROOTFS}/home/root" ]; then
            cp "${WAV_SRC}" "${MOUNT_ROOTFS}/home/root/rds.wav"
        else
            cp "${WAV_SRC}" "${MOUNT_BOOT}/rds.wav"
        fi
    else
        warn "${WAV_SRC} not found — skipping WAV copy."
    fi
else
    warn "No rds.wav specified. Copy it to the SD card manually before running fmdemod-linux."
    warn "  scp rds.wav root@<board-ip>:/home/root/"
    warn "  or mount the SD card and copy to BOOT/ or home/root/"
fi

# ---- Sync and unmount -------------------------------------------------------
info "Syncing..."
sync

info "Unmounting..."
umount "${MOUNT_BOOT}"
rmdir "${MOUNT_BOOT}"
if [ "${EXT4_ROOTFS}" -eq 1 ] && [ -d "${MOUNT_ROOTFS}" ]; then
    umount "${MOUNT_ROOTFS}"
    rmdir "${MOUNT_ROOTFS}"
fi

# ---- Done -------------------------------------------------------------------
echo ""
info "SD card prepared successfully."
echo ""
echo "  Boot partition : ${BOOT_PART} (FAT32, BOOT)"
[ "${EXT4_ROOTFS}" -eq 1 ] && echo "  Rootfs partition: ${ROOTFS_PART} (ext4, rootfs)"
echo ""
echo "Next steps:"
echo "  1. Set Zybo Z7 jumper JP5 to SD card boot (pins 1-2)"
echo "  2. Insert SD card into the Zybo"
echo "  3. Connect USB-UART: sudo minicom -D /dev/ttyUSB0 -b 115200"
echo "  4. Power on — Linux will boot in ~30 seconds"
echo "  5. Login as root (no password)"
echo "  6. Run: gpiodetect && gpioinfo  (confirm GPIO chip/line numbers)"
echo "  7. Run: fmdemod-linux"
echo ""
if [ -z "${WAV_SRC}" ]; then
    echo "  NOTE: Copy rds.wav to the board before step 7:"
    echo "    scp rds.wav root@<board-ip>:/home/root/"
fi
