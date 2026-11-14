#!/bin/bash
# Build a microSD image for the Xavier NX developer kit from the prepared BSP.
OUT=${1:-$HOME/jetson/sd-blob-35.6.5.img}
cd ~/jetson/Linux_for_Tegra/tools || exit 1
sudo ./jetson-disk-image-creator.sh -o "$OUT" -b jetson-xavier-nx-devkit -d SD
