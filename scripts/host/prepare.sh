#!/bin/bash
# Prepare Linux_for_Tegra 35.6.5 on an x86-64 Ubuntu host for flashing a Xavier NX.
# Needs about 30 GB free. Run as a normal user with sudo rights.
set -e
mkdir -p ~/jetson && cd ~/jetson
B=https://developer.nvidia.com/downloads/embedded/l4t/r35_release_v6.5/release
BSP=jetson_linux_r35.6.5_aarch64.tbz2
ROOTFS=tegra_linux_sample-root-filesystem_r35.6.5_aarch64.tbz2
[ -f $BSP ] || wget "$B/$BSP"
[ -f $ROOTFS ] || wget "$B/$ROOTFS"
sudo apt-get -y install lbzip2 sshpass        # tar cannot unpack .tbz2 without lbzip2
[ -d Linux_for_Tegra ] || tar xf $BSP
sudo tar xpf $ROOTFS -C Linux_for_Tegra/rootfs/
cd Linux_for_Tegra
sudo DEBIAN_FRONTEND=noninteractive ./tools/l4t_flash_prerequisites.sh
sudo ./apply_binaries.sh
echo "Ready: $(pwd)"
