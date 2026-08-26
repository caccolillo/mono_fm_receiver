#!/bin/bash
# =============================================================================
# create_sd.sh — Prepare an SD card for the RTL-SDR FM receiver PetaLinux
# image on the Zybo Z7-10.
#
# Adapted from the Ultra96-V2 version. Note that several of the original
# script's justifications were board-specific and do NOT transfer, even
# where the resulting action is the same:
#
#   - MBR partition table, FAT32 type 0x0C, first partition bootable:
#     STILL REQUIRED, but for a different reason. The original cited the
#     Ultra96-V2 boot ROM specifically. The Zynq-7000 BootROM has its own
#     equivalent requirement: it reads the first primary partition as
#     FAT16/FAT32 from an MBR table. GPT is not understood at all. So the
#     explicit `t -> c` in fdisk stays, and parted's fat32 hint is still
#     not trusted to land on the same type byte.
#
#   - "all LEDs on, no serial output" as the failure signature: that was
#     the Ultra96 symptom. On the Zybo the equivalent failure is simply
#     nothing on the UART at all, with the red PGOOD LED lit (PGOOD only
#     tells you the power rails came up, not that anything booted).
#
#   - dd of a prebuilt rootfs.ext4 rather than mkfs + tar-extract:
#     carried over unchanged. This is what CONFIG_SUBSYSTEM_ROOTFS_EXT4
#     actually produces and avoids extraction/permission edge cases.
#
# NO rds.wav HANDLING. This project captures live from an RTL-SDR; there
# is no input file. The optional third argument copies an arbitrary file
# into /home/root instead, which is occasionally useful for test data.
#
# SD card layout:
#   Partition 1: FAT32 (type 0x0C), 512 MB, label BOOT, bootable
#     BOOT.BIN   — FSBL + bitstream + u-boot  (NO PMU firmware: Zynq-7000
#                  has none, unlike ZynqMP)
#     boot.scr   — U-Boot script; without it U-Boot does not know how to
#                  load image.ub and drops to a prompt
#     image.ub   — kernel + device tree (rootfs is on partition 2)
#   Partition 2: ext4, remainder of the card, label rootfs
#     Raw dd of the PetaLinux-built rootfs.ext4
#
# CARD SIZE: the rootfs image is configured at 512 MB in
# build_rtlsdr_petalinux.sh (the default 56 MB filled during the first
# capture). With a 512 MB boot partition that means a 2 GB card is the
# practical minimum, and captures want more — a 30 s capture is ~3 MB at
# 50 kHz mono, so budget accordingly for longer runs.
#
# USAGE:
#   sudo PETALINUX_PROJECT=/path/to/fm_rtlsdr_linux \
#       bash create_sd.sh /dev/sdX [optional-file-to-copy]
#
#   PETALINUX_PROJECT must be set EXPLICITLY on the sudo command line.
#   sudo resets $HOME to root's home, so any $HOME-based default in this
#   script resolves to the wrong path when run under sudo.
#
# WARNING: THIS ERASES AND REPARTITIONS THE TARGET DEVICE.
# =============================================================================

set -e

# ---- Configuration ----------------------------------------------------------
PETALINUX_PROJECT="${PETALINUX_PROJECT:-$HOME/petalinux_rtlsdr/fm_rtlsdr_linux}"
IMAGES_DIR="${PETALINUX_PROJECT}/images/linux"
BOOT_SIZE_MB=512

# ---- Colour output ----------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---- Argument parsing -------------------------------------------------------
if [ $# -lt 1 ]; then
    echo "Usage: sudo PETALINUX_PROJECT=/path/to/fm_rtlsdr_linux \\"
    echo "            bash $(basename "$0") /dev/sdX [file-to-copy]"
    echo ""
    echo "  /dev/sdX      SD card block device (e.g. /dev/sdb, /dev/mmcblk0)"
    echo "  file-to-copy  optional: any file to place in /home/root"
    echo ""
    echo "  This project captures LIVE from an RTL-SDR -- no input WAV is"
    echo "  needed. The optional file argument is for test data only."
    exit 1
fi

DEV="$1"
EXTRA_FILE="${2:-}"

# ---- Safety checks ----------------------------------------------------------
[ "$(id -u)" -eq 0 ] || error "This script must be run as root (sudo)."
[ -b "${DEV}" ] || error "${DEV} is not a block device. Check the device path."

ROOT_DEV=$(df / | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//')
if [ "${DEV}" = "${ROOT_DEV}" ] || [ "${DEV}" = "/dev/sda" ]; then
    error "Refusing to operate on ${DEV} — looks like the system disk. " \
          "Specify the SD card device explicitly."
fi

for f in BOOT.BIN image.ub rootfs.ext4; do
    [ -f "${IMAGES_DIR}/${f}" ] || \
        error "${IMAGES_DIR}/${f} not found. Run build_rtlsdr_petalinux.sh first. " \
              "(PETALINUX_PROJECT is currently ${PETALINUX_PROJECT})"
done

if [ -f "${IMAGES_DIR}/boot.scr" ]; then
    HAVE_BOOT_SCR=1
else
    HAVE_BOOT_SCR=0
    warn "boot.scr NOT found in ${IMAGES_DIR}"
    warn "Without it U-Boot loads, prints its banner, and then drops to a"
    warn "'Zynq>' prompt instead of booting -- it has no instructions for"
    warn "finding image.ub. Proceeding, but expect to boot manually."
fi

# ---- Sanity check: is this actually a Zynq-7000 BOOT.BIN? -------------------
# A ZynqMP BOOT.BIN on a Zynq-7000 board produces a completely silent
# UART, which is an expensive thing to diagnose. The FSBL name in the
# build directory is the cheapest available signal.
if [ -f "${IMAGES_DIR}/zynqmp_fsbl.elf" ] && [ ! -f "${IMAGES_DIR}/zynq_fsbl.elf" ]; then
    error "Found zynqmp_fsbl.elf but no zynq_fsbl.elf -- this looks like a " \
          "ZynqMP build. The Zybo Z7-10 is Zynq-7000. Check that the project " \
          "was created with '--template zynq'."
fi

# ---- User confirmation ------------------------------------------------------
DEVSIZE=$(blockdev --getsize64 "${DEV}" 2>/dev/null || echo "unknown")
if [ "${DEVSIZE}" != "unknown" ]; then
    DEVSIZE_GB=$(awk "BEGIN {printf \"%.1f\", ${DEVSIZE}/1024/1024/1024}")
    echo ""
    warn "TARGET DEVICE: ${DEV}  (${DEVSIZE_GB} GB)"
    MIN_BYTES=$(( (BOOT_SIZE_MB + 600) * 1024 * 1024 ))
    if [ "${DEVSIZE}" -lt "${MIN_BYTES}" ]; then
        error "Card is too small. Need at least $(( MIN_BYTES / 1024 / 1024 )) MB " \
              "for a ${BOOT_SIZE_MB} MB boot partition plus the 512 MB rootfs."
    fi
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

# ---- Wipe and partition ------------------------------------------------------
info "Wiping existing signatures on ${DEV}..."
wipefs -a "${DEV}" || true
dd if=/dev/zero of="${DEV}" bs=512 count=2048 2>/dev/null || true
sync

info "Partitioning ${DEV} (MBR, FAT32 type 0x0C, bootable)..."
# Explicit type assignment (t -> c) rather than relying on a tool's
# fat32 hint. The Zynq-7000 BootROM reads the first primary partition of
# an MBR table as FAT; a GPT card or a wrong type byte gives a silent
# UART with no indication of why.
printf 'o\nn\np\n1\n\n+%dM\nt\nc\na\n1\nn\np\n2\n\n\nw\n' \
    "${BOOT_SIZE_MB}" | fdisk "${DEV}"
sync

sleep 2
partprobe "${DEV}" 2>/dev/null || true
sleep 1

# ---- Identify partition names ------------------------------------------------
if [ -b "${DEV}1" ]; then
    BOOT_PART="${DEV}1"
    ROOTFS_PART="${DEV}2"
elif [ -b "${DEV}p1" ]; then
    BOOT_PART="${DEV}p1"
    ROOTFS_PART="${DEV}p2"
else
    error "Could not identify partition devices after partitioning ${DEV}"
fi

# ---- Boot partition ----------------------------------------------------------
info "Formatting ${BOOT_PART} as FAT32 (label: BOOT)..."
mkfs.vfat -F 32 -n BOOT "${BOOT_PART}"

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

# ---- Rootfs -------------------------------------------------------------------
info "Flashing rootfs.ext4 (this may take a few minutes)..."
ROOTFS_SIZE=$(stat -c%s "${IMAGES_DIR}/rootfs.ext4")
info "rootfs image size: $(( ROOTFS_SIZE / 1024 / 1024 )) MB"

dd if="${IMAGES_DIR}/rootfs.ext4" \
   of="${ROOTFS_PART}" \
   bs=4M \
   status=progress \
   conv=fsync
sync

# ---- Optional extra file -----------------------------------------------------
if [ -n "${EXTRA_FILE}" ]; then
    if [ -f "${EXTRA_FILE}" ]; then
        MOUNT_ROOTFS=$(mktemp -d /tmp/sd_rootfs_XXXXX)
        info "Mounting ${ROOTFS_PART} to copy $(basename "${EXTRA_FILE}")..."
        mount "${ROOTFS_PART}" "${MOUNT_ROOTFS}"
        mkdir -p "${MOUNT_ROOTFS}/home/root"
        cp "${EXTRA_FILE}" "${MOUNT_ROOTFS}/home/root/"
        sync
        umount "${MOUNT_ROOTFS}"
        rmdir "${MOUNT_ROOTFS}"
        info "Copied to /home/root/$(basename "${EXTRA_FILE}")"
    else
        warn "${EXTRA_FILE} not found — skipping."
    fi
fi

info "SD card prepared successfully."

cat << 'NEXTSTEPS'

====================================================================
  Next steps
====================================================================

 1. Set the Zybo Z7 boot mode jumper JP5 to SD.
    (If it is still on JTAG from bare-metal debugging, the board will
    not boot from the card at all.)

 2. Insert the card, connect USB to J12 (PROG/UART -- NOT J13, the
    host port), and open the console:

        picocom -b 115200 /dev/ttyUSB1

    The FT2232 presents two interfaces: ttyUSB0 is JTAG, ttyUSB1 is
    the UART. If ttyUSB1 does not exist, check the cable is a DATA
    cable -- charge-only micro-USB cables enumerate nothing.

 3. Plug the RTL-SDR into J13 (USB HOST) and power on.

 4. Log in as root (no password), then VERIFY IN THIS ORDER. Each
    step isolates a different failure; skipping ahead just makes the
    eventual error harder to attribute:

        ls /sys/bus/usb/devices/
            Non-empty => the USB host controller exists.
            EMPTY => the problem is HARDWARE: PS USB0 is not enabled
            in the block design, or the ULPI PHY node is missing from
            the device tree. No software fix applies.

        lsusb
            Expect 0bda:2838 (Realtek RTL2838).

        rtl_test -t
            Proves librtlsdr can claim the device. Should report
            R820T2 for a Blog V3. "device is busy" means the DVB
            driver got there first -- check
            /etc/modprobe.d/blacklist-rtl28xxu.conf exists.

        gpiodetect
            Confirm which chip is 40000000.gpio (the PL one, ngpio=2).
            fmdemod-rtlsdr assumes gpiochip0. Enumeration order is
            probe-dependent and can shift between kernels.

 5. Capture:

        cd /home/root
        fmdemod-rtlsdr -f 100000000 -d 30

    Output lands in the CURRENT DIRECTORY:
        audio_50k.wav   native 50 kHz from the PL chain
        audio_out.wav   resampled to 48 kHz -- this is the one to play

    There is no audio hardware on this board (dmesg says "No soundcards
    found"), so playback means copying the WAV to a host:

        scp root@<board-ip>:/home/root/audio_out.wav .

 6. Tuning is per-invocation; there is no runtime retune, because the
    NCO in the fabric is fixed at 10 kHz and the only tunable element
    is the dongle's own LO:

        fmdemod-rtlsdr -f 88500000        # 88.5 MHz
        fmdemod-rtlsdr -f 98300000 -g 30  # 98.3 MHz, 30 dB manual gain
        fmdemod-rtlsdr -f 100000000 -d 0  # run until Ctrl-C

    -f  station centre frequency in Hz   (default 100000000)
    -g  tuner gain in dB, -1 for AGC     (default -1)
    -d  duration in seconds, 0 = forever (default 30)
    -p  frequency correction in ppm      (default 0)

    Capture writes ~100 KB/s. With -d 0 it runs until stopped and will
    eventually fill the card.

====================================================================
NEXTSTEPS
