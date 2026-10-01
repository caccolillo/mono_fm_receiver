SUMMARY = "Live FM demodulator: RTL-SDR -> PL demod chain -> WAV"
SECTION = "PETALINUX/apps"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://fmdemod-rtlsdr.c \
    file://resample_50k_to_48k.c \
    file://resample_coeffs.h \
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
