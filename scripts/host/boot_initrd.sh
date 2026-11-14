#!/bin/bash
# Boot the flashing initrd over USB without writing anything, to get a root shell
# on the Jetson for diagnosis. The Jetson must be in recovery mode.
# Afterwards:  sshpass -p root ssh root@fc00:1:1:0::2
# Inside the initrd the microSD is /dev/mmcblk1 and the fan runs at 100 %.
cd ~/jetson/Linux_for_Tegra || exit 1
sudo ./tools/kernel_flash/l4t_initrd_flash.sh --initrd --showlogs --network usb0 \
    jetson-xavier-nx-devkit-qspi internal
