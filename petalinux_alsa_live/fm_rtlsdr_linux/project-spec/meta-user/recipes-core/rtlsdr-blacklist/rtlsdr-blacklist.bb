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
