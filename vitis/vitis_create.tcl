#*****************************************************************************************
# vitis_create.tcl
#
# Headless XSCT script: creates the Vitis platform + standalone application project
# for the sdr_fm_receiver design, builds it to an ELF.
#
# Run with:
#   xsct vitis_create.tcl
# or
#   vitis -s vitis_create.tcl
#
# Companion to prj.tcl (Vivado project + bitstream + XSA export) - run that first.
#*****************************************************************************************

# ---------------------------------------------------------------------------
# Paths - adjust if your directory layout differs
# ---------------------------------------------------------------------------
set xsa_path      "../vivado/end_system/sdr_fm_receiver/sdr_fm_receiver.export/sdr_fm_receiver.xsa"
set workspace_dir "./vitis_workspace"
set src_dir       "./sw_src"   ;# put main.c, resample_50k_to_48k.c, resample_coeffs.h here

set platform_name "sdr_fm_receiver_platform"
set domain_name   "standalone_domain"
set app_name      "fm_demod_app"
set proc_name     "ps7_cortexa9_0"   ;# Zynq-7000 PS7, Cortex-A9 core 0

if { ![file exists $xsa_path] } {
  error "ERROR: XSA not found at $xsa_path - run prj.tcl (Vivado) first to generate it."
}

if { [file exists $workspace_dir] } {
  puts "=== Removing existing workspace $workspace_dir for a clean rebuild ==="
  file delete -force $workspace_dir
}
file mkdir $workspace_dir
setws $workspace_dir

# ---------------------------------------------------------------------------
# Platform: standalone (bare metal) targeting the PS7 Cortex-A9
# ---------------------------------------------------------------------------
puts "=== Creating platform '$platform_name' from $xsa_path ==="
platform create -name $platform_name -hw $xsa_path -out $workspace_dir

domain create -name $domain_name -display-name $domain_name \
    -os standalone -proc $proc_name -runtime cpp -arch {32-bit} \
    -support-app {empty_application}

# NOTE: no explicit heap/stack sizing here. Unlike memory-constrained
# targets (e.g. MicroBlaze with small on-chip memory), this app runs on
# the PS7 with DDR behind it - the standalone BSP's heap just grows via
# sbrk() until it meets the stack, with no fixed "heap size" domain
# setting to configure. With ~1GB of DDR on the Zybo Z7-20 and the
# resampler's malloc() only needing a few MB for typical WAV files, the
# defaults are more than sufficient. If you ever do need to cap or
# relocate the heap/stack (e.g. to reserve a DDR region for something
# else), that's done by hand-editing the generated lscript.ld in the
# app project after platform generate, not via a domain/bsp command.

platform generate

# ---------------------------------------------------------------------------
# Application project
# ---------------------------------------------------------------------------
puts "=== Creating application '$app_name' ==="
if { [catch {
    app create -name $app_name -platform $platform_name -domain $domain_name \
        -template {Empty Application(C)}
} err] } {
    if { [string match "*already exists*" $err] } {
        puts "WARNING: app '$app_name' already exists in the workspace - reusing it instead of failing."
    } else {
        error $err
    }
}

if { ![file exists $src_dir] } {
  error "ERROR: source directory $src_dir not found - put main.c, \
resample_50k_to_48k.c, and resample_coeffs.h there before running this script."
}

if { [catch { importsources -name $app_name -path $src_dir } err] } {
    if { [string match "*already exist*" $err] } {
        puts "WARNING: sources already imported into '$app_name' - continuing."
    } else {
        error $err
    }
}

# resample_50k_to_48k.c uses lround() from <math.h> - needs libm linked in.
puts "=== Adding libm to link libraries (for lround/math functions) ==="
app config -name $app_name -add libraries {m}

# ---------------------------------------------------------------------------
# BSP: explicitly enable xilffs + SD interface rather than relying on
# Vitis's auto-selection to guess it. xaxidma is unambiguous (there's only
# one DMA IP in the design) and auto-selects reliably; xilffs is not
# guaranteed to, so it's set explicitly here.
#
# fs_interface: 1 = SD/eMMC (via XSdPs), 2 = RAM disk. 1 is what we want,
# and is also the xilffs library default - set explicitly anyway rather
# than depending on that default silently doing the right thing.
# ---------------------------------------------------------------------------
puts "=== Configuring BSP: xilffs + SD interface ==="
domain active -name $domain_name
bsp setlib -name xilffs
bsp config fs_interface 1
bsp regenerate

# IMPORTANT: bsp regenerate rebuilds the library sources internally, but
# does NOT re-export the updated header set into
# sw/<platform>/<domain>/bspinclude/include - that export is specifically
# what `platform generate` does. Without calling it again here, the app
# would still compile against the pre-xilffs header snapshot from the
# earlier platform generate call (right after domain create) and fail
# with "ff.h: No such file or directory".
puts "=== Re-generating platform to export updated BSP headers (ff.h etc.) ==="
platform generate

# NOTE - hardware-side prerequisite this script CANNOT fix:
# xilffs/XSdPs only works if the PS7's SD controller (ps7_sdio) is present
# and enabled in the hardware design itself - i.e. enabled in the Zynq PS7
# configuration in your Vivado block design (bd.tcl), with the SDIO0 MIO
# pins assigned. If that wasn't turned on when the PS7 was customized
# (commonly done via the Zybo Z7-20 board preset, which usually does
# enable it - but that's a fact about your bd.tcl, not something visible
# from here), no Vitis-side scripting can add it after the fact. If the
# build below succeeds but you get an XSdPs/CfgInitialize error at
# runtime, or f_mount fails immediately, that's the first thing to check
# back in Vivado: PS7 Customization -> Peripheral I/O Pins -> SD 0 enabled,
# then regenerate the bitstream and XSA and re-run prj.tcl + this script.

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
puts "=== Building '$app_name' ==="
app build -name $app_name

set elf_path "$workspace_dir/$app_name/Debug/$app_name.elf"
if { [file exists $elf_path] } {
  puts "=== Build succeeded: $elf_path ==="
} else {
  error "ERROR: build did not produce the expected ELF at $elf_path - check the build log above."
}
