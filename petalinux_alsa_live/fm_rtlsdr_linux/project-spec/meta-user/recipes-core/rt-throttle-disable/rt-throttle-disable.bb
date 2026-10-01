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
