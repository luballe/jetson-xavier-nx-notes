#!/bin/bash
# Run with sudo on the Jetson, booted from the NVMe. Everything on the card is replaced.
# Write the image to the microSD and compare what was written with the image.
set -eu
IMG=${1:?usage: write_backup_image.sh <image>}; SD=${SD:-/dev/mmcblk0}
[ "$(findmnt -no SOURCE /)" = /dev/nvme0n1p1 ] || { echo "root is not the NVMe"; exit 1; }
grep -q "^$SD" /proc/mounts && { echo "card is mounted"; exit 1; }
echo "START $(date -Is) $IMG -> $SD"
dd if=$IMG of=$SD bs=4M conv=fsync status=none
sync; echo 3 > /proc/sys/vm/drop_caches
echo "written $(date -Is); verifying"
cmp -n $(stat -c %s $IMG) $IMG $SD && echo "VERIFY OK: card matches the image"
sgdisk -e $SD >/dev/null; partprobe $SD; sleep 2
sgdisk -v $SD | tail -1
lsblk -o NAME,SIZE,PARTLABEL $SD | head -3
echo "END $(date -Is)"
