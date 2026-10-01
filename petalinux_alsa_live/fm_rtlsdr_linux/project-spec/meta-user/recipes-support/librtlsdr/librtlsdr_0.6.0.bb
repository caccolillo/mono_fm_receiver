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
