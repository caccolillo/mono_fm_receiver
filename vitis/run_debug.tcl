connect
targets -set -filter {name =~ "APU*"}
rst -system
after 3000
targets -set -filter {name =~ "ARM*#0"}
stop
ps7_init
ps7_post_config
fpga -file /home/caccolillo/fm_zybo_parkair/mono_fm_receiver/vitis/fm_sd_card_prj/_ide/bitstream/sdr_fm_receiver.bit
dow /home/caccolillo/fm_zybo_parkair/mono_fm_receiver/vitis/fm_sd_card_prj/Debug/fm_sd_card_prj.elf
bpadd -addr &main
con
