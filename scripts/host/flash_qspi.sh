#!/bin/bash
# Flash only the QSPI boot firmware (UEFI). About 2.5 minutes.
# The Jetson must be in recovery mode (lsusb shows 0955:7e19).
# Argument: the root device the firmware should expect, mmcblk0p1 (microSD) or nvme0n1p1.
# Also the fix for "L4TLauncher: Attempting Recovery Boot" after repeated failed boots.
ROOTDEV=${1:-mmcblk0p1}
cd ~/jetson/Linux_for_Tegra || exit 1
sudo ./flash.sh jetson-xavier-nx-devkit-qspi "$ROOTDEV"
