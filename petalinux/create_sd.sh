#!/bin/bash
# =============================================================================
# create_sd.sh — Prepare an SD card for booting the sdr_fm_receiver PetaLinux
# image on the Ultra96-V2.
#
# REWRITTEN to closely mirror a known-working sibling Ultra96-V2 project's
# own flash_sd.sh, after the previous single-partition (initramfs) layout
# was never confirmed to actually boot end-to-end -- direct evidence: on a
# card flashed with the old script, only ONE partition (boot) ever showed
# up when reinserted into a PC, whereas the sibling project's own script
# produces two visible partitions (boot + rootfs) on a card confirmed to
# boot. This version matches that proven architecture directly:
#   - dd's a pre-built rootfs.ext4 IMAGE FILE directly onto the second
#     partition (not tar-extracting a rootfs.tar.gz onto an empty one --
#     simpler, no extraction/permission edge cases, matches what
#     CONFIG_SUBSYSTEM_ROOTFS_EXT4 actually produces)
#   - fdisk with an EXPLICIT partition-type assignment (t -> c, W95 FAT32
#     LBA) rather than trusting parted's fat32 hint to land on the same
#     type byte -- the Ultra96-V2 boot ROM is known to specifically
#     require 0xC; a mismatch here produces "all LEDs on, no serial
#     output at all" (stuck before the FSBL is ever reached)
#
# SD card layout:
#   Partition 1: FAT32 (type 0xC), ~512 MB, labelled BOOT, bootable
#     BOOT.BIN     — FSBL + PMU firmware + bitstream + u-boot
#     boot.scr     — U-Boot script (tells U-Boot how to load image.ub) --
#                    required; U-Boot won't know how to boot without it
#     image.ub     — kernel + device tree (no rootfs -- see partition 2)
#   Partition 2: ext4, remainder of the disk, labelled rootfs
#     Raw dd of the PetaLinux-built rootfs.ext4 image
#     rds.wav      — input I/Q recording (optional, copied into /root)
#
# IMPORTANT: the Ultra96-V2 boot ROM requires an MBR/DOS partition table
# -- GPT will cause the FSBL to hang (all LEDs on, no serial output).
#
# USAGE:
#   sudo PETALINUX_PROJECT=/path/to/sdr_fm_receiver_linux \
#       bash create_sd.sh /dev/sdX [path/to/rds.wav]
#
#   (PETALINUX_PROJECT explicit assignment matters under sudo -- sudo
#   resets $HOME to root's home by default, so this script's own $HOME-
#   based default below resolves to the wrong path unless overridden.)
#
# WARNING: THIS SCRIPT WILL ERASE AND REPARTITION THE TARGET DEVICE.
# Double-check the device path before running. /dev/sdX must be your
# SD card, NOT your system disk.
# =============================================================================

set -e

# ---- Configuration ----------------------------------------------------------
PETALINUX_PROJECT="${PETALINUX_PROJECT:-$HOME/mono_fm_receiver/petalinux/sdr_fm_receiver_linux}"
IMAGES_DIR="${PETALINUX_PROJECT}/images/linux"
BOOT_SIZE_MB=512       # FAT32 boot partition size

# ---- Colour output ----------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---- Argument parsing -------------------------------------------------------
if [ $# -lt 1 ]; then
    echo "Usage: sudo PETALINUX_PROJECT=/path/to/project bash $(basename "$0") /dev/sdX [path/to/rds.wav]"
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
ROOT_DEV=$(df / | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//')
if [ "${DEV}" = "${ROOT_DEV}" ] || [ "${DEV}" = "/dev/sda" ]; then
    error "Refusing to operate on ${DEV} — looks like the system disk. " \
          "Specify the SD card device explicitly."
fi

# Confirm required image files exist -- rootfs.ext4 replaces the old
# initramfs-embedded-in-image.ub check, matching the ext4 rootfs switch
# in build_petalinux.sh.
for f in BOOT.BIN image.ub rootfs.ext4; do
    [ -f "${IMAGES_DIR}/${f}" ] || \
        error "${IMAGES_DIR}/${f} not found. Run petalinux-build first."
done

if [ -f "${IMAGES_DIR}/boot.scr" ]; then
    HAVE_BOOT_SCR=1
else
    HAVE_BOOT_SCR=0
    warn "boot.scr NOT found in ${IMAGES_DIR}"
    warn "This is a likely cause of 'BOOT.BIN looks right but board never"
    warn "boots' -- U-Boot needs this file to know how to load image.ub."
    warn "Proceeding anyway, but the resulting card may not boot without it."
fi

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

# ---- Wipe and partition the card --------------------------------------------
info "Wiping existing filesystem/partition-table signatures on ${DEV}..."
wipefs -a "${DEV}" || true
dd if=/dev/zero of="${DEV}" bs=512 count=2048 2>/dev/null || true
sync

info "Partitioning ${DEV}..."
# fdisk with an EXPLICIT partition type assignment (t -> c) rather than
# parted's fat32 inference -- see the header comment for why this
# specific detail matters on this board.
printf 'o\nn\np\n1\n\n+%dM\nt\nc\na\n1\nn\np\n2\n\n\nw\n' \
    "${BOOT_SIZE_MB}" | fdisk "${DEV}"
sync

# Give the kernel a moment to re-read the partition table
sleep 2
partprobe "${DEV}" 2>/dev/null || true
sleep 1

# ---- Identify partition device names ----------------------------------------
if [ -b "${DEV}1" ]; then
    BOOT_PART="${DEV}1"
    ROOTFS_PART="${DEV}2"
elif [ -b "${DEV}p1" ]; then
    BOOT_PART="${DEV}p1"
    ROOTFS_PART="${DEV}p2"
else
    error "Could not identify partition device after partitioning ${DEV}"
fi

# ---- Format boot partition ---------------------------------------------------
info "Formatting ${BOOT_PART} as FAT32 (label: BOOT)..."
mkfs.vfat -F 32 -n BOOT "${BOOT_PART}"

# ---- Copy boot files ---------------------------------------------------------
MOUNT_BOOT=$(mktemp -d /tmp/sd_boot_XXXXX)
info "Mounting ${BOOT_PART} at ${MOUNT_BOOT}..."
mount "${BOOT_PART}" "${MOUNT_BOOT}"

info "Copying BOOT.BIN ($(du -h "${IMAGES_DIR}/BOOT.BIN" | cut -f1))..."
cp "${IMAGES_DIR}/BOOT.BIN" "${MOUNT_BOOT}/"

info "Copying image.ub ($(du -h "${IMAGES_DIR}/image.ub" | cut -f1))..."
cp "${IMAGES_DIR}/image.ub" "${MOUNT_BOOT}/"

if [ "${HAVE_BOOT_SCR}" -eq 1 ]; then
    info "Copying boot.scr ($(du -h "${IMAGES_DIR}/boot.scr" | cut -f1))..."
    cp "${IMAGES_DIR}/boot.scr" "${MOUNT_BOOT}/"
fi

sync
umount "${MOUNT_BOOT}"
rmdir "${MOUNT_BOOT}"
info "Boot partition written"

# ---- Flash rootfs -------------------------------------------------------------
# Raw dd of the pre-built ext4 image -- NOT mkfs + tar-extract. This
# matches CONFIG_SUBSYSTEM_ROOTFS_EXT4's actual output (a ready-to-write
# filesystem image), and is what the sibling project's proven-working
# flash_sd.sh does.
info "Flashing rootfs.ext4 (this may take a few minutes)..."
ROOTFS_SIZE=$(stat -c%s "${IMAGES_DIR}/rootfs.ext4")
info "rootfs size: $(( ROOTFS_SIZE / 1024 / 1024 )) MB"

dd if="${IMAGES_DIR}/rootfs.ext4" \
   of="${ROOTFS_PART}" \
   bs=4M \
   status=progress \
   conv=fsync
sync

# ---- Copy rds.wav if provided -------------------------------------------------
if [ -n "${WAV_SRC}" ]; then
    if [ -f "${WAV_SRC}" ]; then
        MOUNT_ROOTFS=$(mktemp -d /tmp/sd_rootfs_XXXXX)
        info "Mounting ${ROOTFS_PART} at ${MOUNT_ROOTFS} to copy $(basename "${WAV_SRC}")..."
        mount "${ROOTFS_PART}" "${MOUNT_ROOTFS}"
        mkdir -p "${MOUNT_ROOTFS}/root"
        info "Copying $(basename "${WAV_SRC}") ($(du -h "${WAV_SRC}" | cut -f1)) to /root/rds.wav..."
        cp "${WAV_SRC}" "${MOUNT_ROOTFS}/root/rds.wav"
        sync
        umount "${MOUNT_ROOTFS}"
        rmdir "${MOUNT_ROOTFS}"
    else
        warn "${WAV_SRC} not found — skipping WAV copy."
    fi
else
    warn "No rds.wav specified. Copy it to the board over the network instead:"
    warn "  scp rds.wav root@<board-ip>:/root/"
fi

info "SD card prepared successfully."
echo ""
echo "  Boot partition  : ${BOOT_PART} (FAT32, BOOT)"
echo "  Rootfs partition: ${ROOTFS_PART} (ext4, rootfs)"
echo ""
echo "Next steps:"
echo "  1. Set Ultra96-V2 boot mode switch SW6 to SD card boot:"
echo "       SW6:  1=ON  2=OFF  3=OFF  4=OFF"
echo "     (if it's currently set to JTAG boot, change this first)"
echo "  2. Insert SD card into the Ultra96-V2 (slot is on the underside)"
echo "  3. Connect USB-UART: sudo minicom -D /dev/ttyUSB1 -b 115200"
echo "  4. Power on — Linux will boot in ~30 seconds"
echo "  5. Login as root (no password)"
echo "  6. Run: gpiodetect && gpioinfo  (confirm GPIO chip/line numbers)"
echo "  7. Run: fmdemod-linux"
echo ""
if [ -z "${WAV_SRC}" ]; then
    echo "  NOTE: Copy rds.wav to the board before step 7:"
    echo "    scp rds.wav root@<board-ip>:/root/"
fi
